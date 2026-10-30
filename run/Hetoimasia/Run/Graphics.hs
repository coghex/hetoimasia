-- | The production native graphics of @hetoimasia run@: the process main thread's GLFW session and surface-free
-- graphics owner, the texture backend and window provider over them, and the session run on a thread of its own
-- while the main thread serves the owner's loop (LFE-22 requirement 4).
--
-- = Who runs where
--
-- * The /process main thread/ owns GLFW: it enters the loader integration, runs the owner application and then
--   serves the owner's loop ('runVulkanOwnerLoop') until the session has ended. Window creation, surfaces,
--   native events and the destruction of a window are its operations. It never waits for a VM, an @init@, a
--   tick or a result, and it runs no Lua.
-- * The /session thread/ ('runPrepared') owns the supervision control the session's waits need. It runs the roles'
--   VMs, which are Lua; no native or worker callback enters Lua.
-- * The /graphics owner's own thread/ (started by the host) executes the bounded owner actions: allocation,
--   upload, registration and release.
-- * The /pumps/ of the texture backend and the window provider are workers of their scopes. They wait only in STM.
--
-- A window is requested by Lua, asked of the provider asynchronously, created by the host's queue and attached
-- by the provider's main step ('windowMainStep'), which this module's loop runs on every turn. The launcher creates
-- no window of its own, preloads no image, publishes no scene and waits for nothing on the event path.
--
-- = Order of scopes, and why
--
-- Outermost first: the loader integration; the owner application (the host and its owner: the device starts
-- /without a surface/, so a texture can reach GPU readiness before any window exists); the texture adapter
-- ('withTextureGraphics': the renderer, the one texture table and the backend); the session's pool and pipeline
-- ("Hetoimasia.Run.Session"); and, inside them, the window provider. The provider's scope ends every window
-- before the pipeline and backend drain, because a texture an adopted scene holds retires only when that scene is
-- released, which for a static scene is its window's end. A stop at any point unwinds the same way.
--
-- = Stop and failure
--
-- A genuine native close (the window's own newest close request, never a close the provider itself began) is the
-- session's idempotent normal stop, latched in the link when it arrives before the session is bound. A fatal
-- provider fault is the session's terminal failure. If the main thread's loop fails, the session is asked to stop
-- and is joined before any scope it borrows unwinds. The diagnostic capture's verdict, read after the owner
-- application's last teardown, must be clean: an unclean one fails the run.
module Hetoimasia.Run.Graphics
  ( runNative
  , runNativeWith
  , Observation (..)
  , noObservation
  ) where

import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Concurrent.STM (STM, atomically, retry)
import Control.Exception (ExceptionWithContext, SomeException, displayException, finally, mask, rethrowIO, tryWithContext)
import Control.Monad (join, unless, void)
import Data.Maybe (isJust)
import Data.List (partition)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Component, Logger, logError, logWarning, unsafeComponent)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , DiagnosticVerdict
  , VerdictIssue (..)
  , defaultCaptureConfig
  , verdictIssues
  )
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent
  , Readiness (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , readReadiness
  , runVulkanOwnerLoop
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.LuaEngine.Graphics.Facade (GraphicsFacade (..), defaultIssuedMemory, graphicsInjection)
import Hetoimasia.LuaEngine.Graphics.Scene
  ( GraphicsScene
  , SceneSession (..)
  , configureScenes
  , newSceneSession
  , noPublishHooks
  , scenePublisher
  )
import Hetoimasia.LuaEngine.Graphics.Texture
  ( TextureGraphics (..)
  , TextureGraphicsConfiguration
  , configurationBudgets
  , configurationFor
  , configureHost
  , withTextureGraphics
  )
import Hetoimasia.LuaEngine.Graphics.Window.Configuration (configureWindows, windowSlots)
import Hetoimasia.LuaEngine.Graphics.Window.Host (newHostPort)
import Hetoimasia.LuaEngine.Graphics.Window.Port (Fatal (..), fatalText)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), windowMainStep, withWindowProvider)
import Hetoimasia.LuaEngine.Manifest (Role (Presentation))
import Hetoimasia.LuaEngine.Session
  ( FailureCode (CleanupFailure, HostFailure)
  , FailureStage (OnEngine)
  , SessionOutcome
  , StopKind (StopInterrupt, StopQuit)
  , newRoleFailure
  )
import Hetoimasia.Run.Boot (Prepared (..), remembering)
import Hetoimasia.Run.Output (reportText)
import Hetoimasia.Run.Session
  ( Environment
  , Graphics (..)
  , SessionLink
  , linkFailure
  , linkStop
  , newSessionLink
  , runPrepared
  )
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , UpdateSchedule (NoUpdateDemand)
  , defaultHostConfig
  , defaultScheduledHooks
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner
  , wakeGraphicsHost
  )
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger)
import Hetoimasia.Runtime.Supervision (RuntimeControl)

-- | What the native suite watches of the production composition, and nothing else it could change: the host's own
-- frame events, and the composed host and adapter once they exist, with an action to run on every turn of the
-- main thread's owner loop (where a native operation such as a genuine close belongs). Production observes
-- nothing ('noObservation'); an observation reads and never writes, publishes or stands in for a provider.
data Observation = Observation
  { observeFrame ∷ FrameEvent → IO ()
  , observeComposed ∷ VulkanHost GraphicsScene → TextureGraphics → IO (IO ())
  }

noObservation ∷ Observation
noObservation = Observation (\_ → pure ()) (\_ _ → pure (pure ()))

-- | 'runNativeWith' 'noObservation': the command's own.
runNative ∷ Environment → LoggingLifetime → STM Bool → Prepared → IO SessionOutcome
runNative = runNativeWith noObservation

-- | Run the prepared folder with the production native graphics, from the process main thread. Returns the
-- session's outcome after every role has retired, the windows are destroyed, the textures proved retired and
-- the owner application has torn down; raises what any of those raised, or an unclean diagnostic verdict.
runNativeWith ∷ Observation → Environment → LoggingLifetime → STM Bool → Prepared → IO SessionOutcome
runNativeWith observation environment lifetime stop prepared = do
  textureConfiguration ← either (\refused → ioError (userError ("the profile cannot be mapped to the native graphics: " <> show refused))) pure (configurationFor (preparedProfile prepared))
  scenes ← newSceneSession
  -- The capture keeps 16 KiB of a message, as the native suites do, so a long driver message is not truncated.
  let capture = defaultCaptureConfig {captureTextBudget = 16384}
      base = vulkanHostConfig (defaultHostConfig []) capture (configurationBudgets textureConfiguration) (scenesInitial scenes)
      config = (configureScenes scenes (configureWindows (configureHost textureConfiguration base))) {vulkanFrameObserver = observeFrame observation}
  verdictCell ← newIORef Nothing
  outcome ←
    withLoaderIntegration $ \integration →
      runGraphicsOwnerApplication
        ($ lifetime)
        "hetoimasia"
        ( \_ use → do
            (result, verdict) ← withVulkanOwnerHost logger integration config use
            writeIORef verdictCell (Just verdict)
            pure result
        )
        vulkanWindowHost
        (\vulkan _ → pure vulkan)
        (\vulkan control → body scenes textureConfiguration config vulkan control)
  verdict ← readIORef verdictCell
  checkVerdict logger verdict
  pure outcome
  where
    logger = lifetimeLogger lifetime

    body ∷ SceneSession → TextureGraphicsConfiguration → VulkanHostConfig GraphicsScene → VulkanHost GraphicsScene → RuntimeControl → IO SessionOutcome
    body scenes textureConfiguration config vulkan control = do
      awaitReadiness vulkan
      _ ← superviseGraphicsOwner control (vulkanGraphicsOwner vulkan)
      withTextureGraphics scenes textureConfiguration config vulkan $ \graphics → do
        link ← newSessionLink
        providerStep ← newIORef (pure ())
        (port, _) ← newHostPort vulkan
        let profile = preparedProfile prepared
            production =
              Graphics
                { graphicsTextureBackend = graphicsBackend graphics
                , graphicsMount = \pipeline link' continue →
                    withWindowProvider (linkWindowConfig link') port $ \provider → do
                      writeIORef providerStep (windowMainStep provider)
                      let publisher = scenePublisher (graphicsTextures graphics) provider
                          injection = graphicsInjection (GraphicsFacade profile pipeline provider publisher noPublishHooks defaultIssuedMemory)
                      continue injection `finally` writeIORef providerStep (pure ())
                }
        observed ← observeComposed observation vulkan graphics
        serve vulkan control logger link providerStep observed $
          runPrepared environment lifetime stop link prepared (Just production) (\_ → pure ())

-- | The window provider's stop and fatal endpoints, through the link: a genuine native close is the session's
-- idempotent normal stop, a failure of retirement a @cleanup_failure@ and any other fatal fault a
-- @host_failure@, both of the presentation role at the engine stage. A close or a fault that arrives before the
-- session is bound is applied when it is.
linkWindowConfig ∷ SessionLink → WindowConfig
linkWindowConfig link =
  WindowConfig
    { windowRecords = windowSlots
    , windowStop = linkStop link StopQuit
    , windowFatal = \found → linkFailure link (newRoleFailure (codeOf found) OnEngine Presentation (fatalText found))
    }
  where
    codeOf = \case
      CleanupFatal _ → CleanupFailure
      Fatal _ → HostFailure

-- | Run the session on a thread of its own and serve the owner's loop on this one until it has ended. The
-- session's failure is raised here, with the context it carries, after the loop has stopped.
--
-- If the loop itself fails (or this thread is cancelled in it) the session is asked to stop and the loop is
-- served /again/ until the session has settled: its cleanup closes windows and waits for their native
-- destruction, which only this thread's loop performs, so joining it without serving would deadlock. The loop's
-- failure stays primary and is raised with its context once the session has settled; a failure of the second
-- loop is logged and the join still completes. Every wait here remembers a cancellation delivered meanwhile
-- and raises it afterwards, never instead of the join.
serve ∷ VulkanHost GraphicsScene → RuntimeControl → Logger → SessionLink → IORef (IO ()) → IO () → IO SessionOutcome → IO SessionOutcome
serve vulkan control logger link providerStep observed session = mask $ \restore → do
  done ← newEmptyMVar ∷ IO (MVar (Either (ExceptionWithContext SomeException) SessionOutcome))
  -- The session thread exists from here on, so everything below is inside the guard that stops and joins it.
  _ ← forkIOWithUnmask $ \unmask → do
    result ← unmask (tryWithContext session)
    putMVar done result
    wakeGraphicsHost (vulkanGraphicsOwner vulkan)
  let finished = isJust <$> tryReadMVar done
      loop turn = runVulkanOwnerLoop vulkan control (defaultScheduledHooks logger turn)
      update _ = do
        join (readIORef providerStep)
        observed
        finished >>= \over → pure (if over then FinishWith () else ContinueWith NoUpdateDemand)
      -- Serving only what retirement needs: no provider step, no observation, which may be what failed.
      drainUpdate _ = finished >>= \over → pure (if over then FinishWith () else ContinueWith NoUpdateDemand)
  tryWithContext (restore (loop update)) >>= \case
    Right () → pure ()
    Left failure → do
      linkStop link StopInterrupt
      remembering $
        tryWithContext (loop drainUpdate) >>= \case
          Right () → pure ()
          Left (again ∷ ExceptionWithContext SomeException) →
            logError logger component "the owner loop failed again while the session was draining" [("reason", reportText (Text.pack (displayException again)))]
      remembering (void (readMVar done))
      rethrowIO (failure ∷ ExceptionWithContext SomeException)
  remembering (void (readMVar done))
  readMVar done >>= either rethrowIO pure

-- | Wait for the owner's startup, which creates the device with no surface.
awaitReadiness ∷ VulkanHost scene → IO ()
awaitReadiness vulkan = do
  readiness ← atomically $
    readReadiness (vulkanController vulkan) >>= \case
      RootsPending → retry
      other → pure other
  case readiness of
    RootsFailed reason → ioError (userError ("the graphics owner did not start: " <> Text.unpack reason))
    _ → pure ()

-- | The diagnostic capture's verdict after the last teardown.
--
-- A run fails when the capture saw an error (a validation or driver error message), when the capture itself
-- failed or was left unproven (a callback could still be on its way), or when its consumer or counters cannot be
-- trusted. Diagnostics that were only lost (dropped, truncated, undelivered or unaccounted records) are evidence
-- that some message did not reach the log, not a fault of the run: they are reported as a warning, at once and
-- once, and fail nothing.
checkVerdict ∷ Logger → Maybe DiagnosticVerdict → IO ()
checkVerdict logger = \case
  Nothing → ioError (userError "no diagnostic verdict was reached")
  Just verdict → do
    let (fatal, lost) = partition fatalIssue (verdictIssues verdict)
    unless (null lost) $
      logWarning logger component "diagnostic records were lost" [("issues", reportText (Text.pack (show lost)))]
    unless (null fatal) $
      ioError (userError (Text.unpack (reportText ("the diagnostic capture was not clean: " <> Text.pack (show fatal)))))

-- | Whether a verdict issue is a failure of the run rather than lost diagnostics.
fatalIssue ∷ VerdictIssue → Bool
fatalIssue = \case
  ErrorLatched → True
  CaptureFailureLatched → True
  CaptureFailures _ → True
  CounterSaturated → True
  ConsumerUnsuccessful → True
  QuiescenceUnproven → True
  StorageRetained → True
  RecordsDropped _ → False
  RecordsTruncated _ → False
  RecordsUndelivered _ → False
  RecordsUnaccounted _ _ → False

component ∷ Component
component = unsafeComponent "run.graphics"
