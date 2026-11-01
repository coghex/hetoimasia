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
  , hostConfiguration
  , reportResolution
  , validationFields
  , droppedItems
  ) where

import Control.Concurrent.STM (STM, atomically, retry)
import Control.Exception (finally)
import Control.Monad (join, unless)
import Data.List (partition)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Component, logInfo, logWarning, unsafeComponent)
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
  , ValidationChoice
  , ValidationDisposition (..)
  , ValidationResolution (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , readReadiness
  , readValidationResolution
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
import Hetoimasia.Run.Boot (Prepared (..))
import Hetoimasia.Run.Serve (Owner (..), Spawned, runOwned, serveSpawned)
import Hetoimasia.Run.Settle (diagnostic, reportDiagnostic)
import Hetoimasia.Run.Output (reportText)
import Hetoimasia.Run.Session
  ( Environment
  , Graphics (..)
  , SessionLink
  , linkFailure
  , linkStop
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
import Hetoimasia.Runtime.Supervision (RuntimeControl, withSupervision)

-- | What the native suite watches of the production composition, and nothing else it could change: the host's own
-- frame events, and the composed host and adapter once they exist, with an action to run on every turn of the
-- main thread's owner loop (where a native operation such as a genuine close belongs). Production observes
-- nothing ('noObservation'); an observation reads and never writes, publishes or stands in for a provider.
data Observation = Observation
  { observeFrame ∷ FrameEvent → IO ()
  , observeComposed ∷ VulkanHost GraphicsScene → TextureGraphics → IO (IO ())
  , observeDrain ∷ IO ()
  -- ^ Run on every turn of the drain loop that serves the owner after its ordinary loop failed: where an example makes
  -- that loop fail too.
  }

noObservation ∷ Observation
noObservation = Observation (\_ → pure ()) (\_ _ → pure (pure ())) (pure ())

-- | 'runNativeWith' 'noObservation': the command's own.
runNative ∷ Environment → ValidationChoice → LoggingLifetime → STM Bool → SessionLink → Prepared → IO SessionOutcome
runNative = runNativeWith noObservation

-- | Run the prepared folder with the production native graphics, from the process main thread. Returns the
-- session's outcome after every role has retired, the windows are destroyed, the textures proved retired and
-- the owner application has torn down; raises what any of those raised, or an unclean diagnostic verdict.
--
-- /Optional validation (LFE-28)./ The choice is a plain value ('ValidationOff' requests nothing and leaves the
-- instance exactly as it was). It reaches the host's configuration as 'vulkanOptionalValidation' and is resolved
-- in the owner's startup, where the loader's offer is known, so the strict layers and features of the
-- configuration, which stay empty here, are untouched. The typed resolution is written by that startup the moment
-- it is known and is logged once, by the main thread, as soon as the owner reports its startup finished or failed
-- and before the session (and so any window) exists ('awaitReadiness'). A run that never reaches the loader's
-- offer (a usage error, a boot refusal) has no record: none is made up.
runNativeWith ∷ Observation → Environment → ValidationChoice → LoggingLifetime → STM Bool → SessionLink → Prepared → IO SessionOutcome
runNativeWith observation environment choice lifetime stop link prepared = do
  textureConfiguration ← either (\refused → ioError (userError ("the profile cannot be mapped to the native graphics: " <> show refused))) pure (configurationFor (preparedProfile prepared))
  scenes ← newSceneSession
  let config = hostConfiguration observation choice textureConfiguration scenes
  verdictCell ← newIORef Nothing
  slot ← newIORef Nothing
  -- The application, the capture of whatever ends it, the stop of the session and its join are one masked sequence
  -- ('runOwned'): the application and the device are torn down by the time it answers, whatever the way out, and a
  -- session left to settle against that teardown has been joined, its failure kept beside the application's.
  outcome ←
    runOwned slot (linkStop link StopInterrupt) $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          ($ lifetime)
          "hetoimasia"
          ( \_ use → do
              (answer, verdict) ← withVulkanOwnerHost logger integration config use
              writeIORef verdictCell (Just verdict)
              pure answer
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → body slot scenes textureConfiguration config vulkan control)
  verdict ← readIORef verdictCell
  checkVerdict lifetime verdict
  pure outcome
  where
    logger = lifetimeLogger lifetime

    body ∷ IORef (Maybe (Spawned SessionOutcome)) → SceneSession → TextureGraphicsConfiguration → VulkanHostConfig GraphicsScene → VulkanHost GraphicsScene → RuntimeControl → IO SessionOutcome
    body slot scenes textureConfiguration config vulkan control = do
      awaitReadiness lifetime vulkan
      _ ← superviseGraphicsOwner control (vulkanGraphicsOwner vulkan)
      providerStep ← newIORef (pure ())
      observedStep ← newIORef (pure ())
      let profile = preparedProfile prepared
          finish over = over >>= \finished → pure (if finished then FinishWith () else ContinueWith NoUpdateDemand)
          loop checkpoints turn' = runVulkanOwnerLoop vulkan checkpoints (defaultScheduledHooks logger turn')
          owner =
            Owner
              { ownerServe = \turn over → loop control (\_ → turn >> finish over)
                -- The drain makes its own supervision: the application's may have latched the very failure that
                -- ended the ordinary loop, and its checkpoints would end the drain before it served anything.
              , ownerDrain = \over → withSupervision lifetime $ \fresh → loop fresh (\_ → observeDrain observation >> finish over)
              , ownerWake = wakeGraphicsHost (vulkanGraphicsOwner vulkan)
              }
          -- Everything the session uses is the session thread's own: the texture adapter, the pipeline, the window
          -- provider and the roles. The main thread keeps the native owner and serves it.
          session = withTextureGraphics scenes textureConfiguration config vulkan $ \graphics → do
            (port, _) ← newHostPort vulkan
            observed ← observeComposed observation vulkan graphics
            writeIORef observedStep observed
            let production =
                  Graphics
                    { graphicsTextureBackend = graphicsBackend graphics
                    , graphicsMount = \pipeline link' continue →
                        withWindowProvider (linkWindowConfig link') port $ \provider → do
                          writeIORef providerStep (windowMainStep provider)
                          let publisher = scenePublisher (graphicsTextures graphics) provider
                              injection = graphicsInjection (GraphicsFacade profile pipeline provider publisher noPublishHooks defaultIssuedMemory)
                          continue injection `finally` writeIORef providerStep (pure ())
                    }
            runPrepared environment lifetime stop link prepared (Just production) (\_ → pure ())
              `finally` writeIORef observedStep (pure ())
      -- The session is started, recorded and served in one masked step, so nothing between the thread's creation and
      -- the loop's guard can be cancelled.
      serveSpawned lifetime owner (writeIORef slot . Just) (linkStop link StopInterrupt) (join (readIORef providerStep) >> join (readIORef observedStep)) session

-- | The production host's configuration: the strict layers and features stay empty, so nothing is asked of the
-- loader as a requirement, and the optional validation is the choice and nothing else. A pure function of its
-- arguments, so the request of an unvalidated run is an example's subject and not a reading of the code.
--
-- The capture keeps 16 KiB of a message, as the native suites do, so a long driver message is not truncated.
hostConfiguration ∷ Observation → ValidationChoice → TextureGraphicsConfiguration → SceneSession → VulkanHostConfig GraphicsScene
hostConfiguration observation choice textureConfiguration scenes =
  (configureScenes scenes (configureWindows (configureHost textureConfiguration base)))
    { vulkanFrameObserver = observeFrame observation
    , vulkanOptionalValidation = choice
    }
  where
    capture = defaultCaptureConfig {captureTextBudget = 16384}
    base = vulkanHostConfig (defaultHostConfig []) capture (configurationBudgets textureConfiguration) (scenesInitial scenes)

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

-- | Wait for the owner's startup, which creates the device with no surface, and report what the optional validation
-- resolved to.
--
-- The record is read after the startup has finished or failed, so it is whole: it is written by the startup on the
-- owner's thread before the plan is checked, which precedes both outcomes. It is reported here, on the main thread,
-- once and before the session starts, so before any window; on a failed startup it is reported best effort ahead of
-- the failure, which stays the failure of the run. A startup that never reached the loader's offer has none.
awaitReadiness ∷ LoggingLifetime → VulkanHost scene → IO ()
awaitReadiness lifetime vulkan = do
  readiness ← atomically $
    readReadiness (vulkanController vulkan) >>= \case
      RootsPending → retry
      other → pure other
  resolution ← atomically (readValidationResolution (vulkanController vulkan))
  case readiness of
    RootsFailed reason → do
      mapM_ (reportDiagnostic . reportResolution lifetime) resolution
      ioError (userError ("the graphics owner did not start: " <> Text.unpack reason))
    _ → mapM_ (diagnostic . reportResolution lifetime) resolution

-- | The one record of requested versus resolved optional validation, then a warning for each item dropped. The
-- record says what was selected into the instance's create info, not that the loader kept the layer or that it is
-- active.
reportResolution ∷ LoggingLifetime → ValidationResolution → IO ()
reportResolution lifetime resolution = do
  logInfo logger component "vulkan validation resolved" (validationFields resolution)
  mapM_ dropped (droppedItems resolution)
  where
    logger = lifetimeLogger lifetime
    dropped (item, reason) = logWarning logger component "vulkan validation item dropped" [("item", item), ("reason", reason)]

-- | The fields of the one record: whether validation was requested, and what became of the layer and of the feature.
-- Each is @not-requested@, @enabled@ (selected into the instance's create info) or @dropped@ (requested, and not
-- offered).
validationFields ∷ ValidationResolution → [(Text.Text, Text.Text)]
validationFields resolution =
  [ ("requested", if requested then "true" else "false")
  , ("layer", dispositionText (resolvedLayer resolution))
  , ("feature", dispositionText (resolvedFeature resolution))
  ]
  where
    requested = resolvedLayer resolution /= DispositionNotRequested || resolvedFeature resolution /= DispositionNotRequested
    dispositionText = \case
      DispositionNotRequested → "not-requested"
      DispositionEnabled → "enabled"
      DispositionDropped → "dropped"

-- | Each dropped item with the reason, which is what the warning says.
droppedItems ∷ ValidationResolution → [(Text.Text, Text.Text)]
droppedItems resolution =
  [("VK_LAYER_KHRONOS_validation", "the loader does not offer the layer") | resolvedLayer resolution == DispositionDropped]
    <> [("synchronization-validation", "no enabled layer offers VK_EXT_validation_features") | resolvedFeature resolution == DispositionDropped]

-- | The diagnostic capture's verdict after the last teardown.
--
-- A run fails when the capture saw an error (a validation or driver error message), when the capture itself
-- failed or was left unproven (a callback could still be on its way), or when its consumer or counters cannot be
-- trusted. Diagnostics that were only lost (dropped, truncated, undelivered or unaccounted records) are evidence
-- that some message did not reach the log, not a fault of the run: they are reported as a warning, at once and
-- once, and fail nothing.
checkVerdict ∷ LoggingLifetime → Maybe DiagnosticVerdict → IO ()
checkVerdict lifetime = \case
  Nothing → ioError (userError "no diagnostic verdict was reached")
  Just verdict → do
    let (fatal, lost) = partition fatalIssue (verdictIssues verdict)
    unless (null lost) $
      reportDiagnostic (logWarning (lifetimeLogger lifetime) component "diagnostic records were lost" [("issues", reportText (Text.pack (show lost)))])
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
