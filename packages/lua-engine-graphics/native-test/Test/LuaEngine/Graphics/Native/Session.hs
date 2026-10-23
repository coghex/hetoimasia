-- | The native suite's one graphics session: the production host over the loader integration, started
-- without a surface and with no window, with the validation layer and synchronization validation enabled; the
-- adapter composed over it once (a session has one renderer and one texture table); and Hspec run inside it.
--
-- The process main thread enters GLFW through the loader integration and owns the session; Hspec runs on a
-- thread of its own, so an example that blocks cannot starve the owner's loop. Nothing in the session opens a
-- window, so the main thread has no event to serve beyond the owner's own run. The session is released only
-- once Hspec has finished, and the checks that need the roots gone — the destruction order and the capture's
-- final verdict — are applied after.
module Test.LuaEngine.Graphics.Native.Session
  ( Env (..)
  , Facts (..)
  , runSession
  , usageNow
  , awaitUsage
  , restNow
  , markRest
  ) where

import Control.Concurrent (forkOS)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, retry)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import System.IO (hPutStrLn, stderr)
import Test.Hspec (Spec)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, evalSpec, hspecWithResult, isSuccess, runSpecForest, specResultSuccess)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GLFW.Session (Backend, SessionConfig (..))
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GPU.Model (Usage, usage)
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict, defaultCaptureConfig)
import Hetoimasia.GPU.Vulkan.GLFW
  ( NativeObserver (..)
  , Readiness (..)
  , ValidationFeature
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , readReadiness
  , readVulkanModel
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.Runtime.GLFW (HostConfig (..), defaultHostConfig, runGraphicsOwnerApplication)
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)

-- | What an example is given.
data Env = Env
  { envHost ∷ !(VulkanHost ())
  , envHostConfig ∷ !(VulkanHostConfig ())
  , envGraphics ∷ !TextureGraphics
  , envControl ∷ !RuntimeControl
  , envBaseline ∷ !Usage
    -- ^ What the session's native accounting held once the table was bound and nothing else was made.
  , envRest ∷ !(IORef (Maybe Usage))
    -- ^ What it holds at rest once the renderer has built the pipeline its first drawing needs, which it keeps for
    -- the session: set by the first example that draws, and the standard the later ones return to.
  , envEvidence ∷ !(TVar [Text])
    -- ^ Lines for the run's evidence record, oldest last.
  }

-- | What the run saw, once the session is released.
data Facts = Facts
  { factsPassed ∷ !Bool
  , factsCalls ∷ ![(Text, Maybe Text)]
    -- ^ Every native call, in order, with what it raised.
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsEvidence ∷ ![Text]
  , factsFailure ∷ !(Maybe Text)
  }

-- | The model's accounting now.
usageNow ∷ Env → IO Usage
usageNow env = usage <$> atomically (readVulkanModel (vulkanController (envHost env)))

-- | The accounting a quiet session returns to: the one marked after the first drawing, or the baseline before it.
restNow ∷ Env → IO Usage
restNow env = readIORef (envRest env) >>= maybe (pure (envBaseline env)) pure

-- | Record the accounting now as the session's rest, once the examples before have released what they made.
markRest ∷ Env → IO ()
markRest env = usageNow env >>= writeIORef (envRest env) . Just

-- | Block, in STM, until the model's accounting reads like this: the owner's own evidence, not a clock.
awaitUsage ∷ Env → (Usage → Bool) → IO ()
awaitUsage env wanted = atomically $ do
  now ← usage <$> readVulkanModel (vulkanController (envHost env))
  unless (wanted now) retry

-- | Run the examples inside a session that requests this backend, or the platform's own.
runSession ∷ Bool → Maybe Backend → [ValidationFeature] → TextureGraphicsConfiguration → (Env → Spec) → IO Facts
runSession complete backend features configuration examples = do
  recorded ← newIORef []
  verdictCell ← newIORef Nothing
  passedCell ← newIORef False
  evidence ← newTVarIO []
  initial ← prepare ()
  let host = requestingBackend backend (defaultHostConfig [])
      base = vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} (configurationBudgets configuration) initial
      config =
        (configureHost configuration base)
          { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = features
          , vulkanObserver = const (observer recorded)
          }
  outcome ←
    try @SomeException $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          (withLoggingLifetime quietLogger)
          "lua-engine-graphics-native"
          ( \_ use → do
              (result, verdict) ← withVulkanOwnerHost quietLogger integration config use
              writeIORef verdictCell (Just verdict)
              pure result
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → body vulkan control config evidence passedCell)
  calls ← reverse <$> readIORef recorded
  verdict ← readIORef verdictCell
  passed ← readIORef passedCell
  lines' ← reverse <$> readTVarIO evidence
  pure
    Facts
      { factsPassed = passed && either (const False) (const True) outcome
      , factsCalls = calls
      , factsVerdict = verdict
      , factsEvidence = lines'
      , factsFailure = either (Just . Text.pack . displayException) (const Nothing) outcome
      }
  where
    body vulkan control config evidence passedCell = do
      progressNote "the owner is starting"
      readiness ← atomically $
        readReadiness (vulkanController vulkan) >>= \case
          RootsPending → retry
          other → pure other
      case readiness of
        RootsFailed why → ioError (userError ("the owner's startup failed: " <> Text.unpack why))
        _ → pure ()
      progressNote "the owner is ready; composing the adapter"
      withTextureGraphics configuration config vulkan $ \graphics → do
        progressNote "the adapter is composed; waiting for the table to bind"
        -- The adapter is composed; wait for the table to bind, so the baseline is the session at rest.
        atomically $ do
          reading ← graphicsReading graphics
          unless (readingBound reading) retry
        progressNote "the table is bound; running the examples"
        now ← usage <$> atomically (readVulkanModel (vulkanController vulkan))
        rest ← newIORef Nothing
        let env = Env vulkan config graphics control now rest evidence
        done ← newEmptyMVar
        _ ← forkOS $ do
          -- The complete profile is run with Hspec's configuration reading left out, so no argument,
          -- @~/.hspec@, @./.hspec@ or @HSPEC_*@ can narrow what the catalog group's receipt speaks for.
          result ←
            try @SomeException $
              if complete
                then do
                  (cfg, forest) ← evalSpec defaultConfig {configFailOnEmpty = True} (examples env)
                  specResultSuccess <$> runSpecForest forest cfg
                else isSuccess <$> hspecWithResult defaultConfig {configFailOnEmpty = True} (examples env)
          putMVar done result
        takeMVar done >>= \case
          Left failure → throwIO failure
          Right success → writeIORef passedCell success

-- | A line on stderr as the session reaches each stage, so a run that stops says where.
progressNote ∷ String → IO ()
progressNote line = hPutStrLn stderr ("lua-engine-graphics-native-tests: " <> line)

observer ∷ IORef [(Text, Maybe Text)] → NativeObserver
observer recorded = NativeObserver $ \name call → do
  outcome ← try @SomeException call
  atomicModifyIORef' recorded (\calls → ((name, either (Just . Text.pack . displayException) (const Nothing) outcome) : calls, ()))
  either throwIO pure outcome

quietLogger ∷ Logger
quietLogger =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink (\_ → pure ()))

-- | A host whose session requests the backend named.
requestingBackend ∷ Maybe Backend → HostConfig → HostConfig
requestingBackend backend host = host {hostSessionConfig = (hostSessionConfig host) {requestedBackend = backend}}
