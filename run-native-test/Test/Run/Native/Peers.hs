-- | The two-instance composition on a real device (LFE-25, #540 requirements 1, 3 and 4): one UI VM with two
-- engine-owned instances of the shipped quad content, and an independent logical owner, composed through the public
-- Haskell interfaces over the real host, texture adapter, window provider and scene publisher.
--
-- A public @runSession@ has one instance per role, so the second instance of a role is composed through the facade
-- directly, the way the session composes a role and the way the headless two-instance rig does (that rig is another
-- component's spec and is not imported: this module is its real-device counterpart, written here). Nothing is
-- replaced: the content root, inventory and fingerprint come from the launcher's own preparation
-- ('Hetoimasia.Run.Boot.withPrepared'), the read pool, texture pipeline, texture backend, window port, window
-- provider, scene publisher and request policy are the production ones. The only additions are observation and
-- explicit gates around public handoffs, each released on every way out:
--
-- * the pool's reader, which can hold the read of a named path (a gated read still opens and hashes a real file when
--   it is let go), and
-- * the production window port, whose creation outcome can be withheld until the gate is opened.
--
-- The host is composed here, not by the production composition, so it is the one place this suite enables the
-- validation layer and synchronization validation through the public 'VulkanHostConfig' fields; the diagnostic
-- verdict, read after the owner application's last teardown, must be clean or the case fails.
--
-- = Who owns what
--
-- The process main thread owns GLFW and serves the owner's loop; every native window operation is its. The
-- scenario runs on the session thread ('serveSpawned') with the texture adapter, the pool, the pipeline, the window
-- provider and both Lua owners as its scopes, which it ends itself, windows first. Jobs for the main thread (a
-- genuine native close) are handed to it through 'onMain'.
module Test.Run.Native.Peers
  ( Peers (..)
  , Spawned (..)
  , PeerFailure (..)
  , ScenarioCancelled (..)
  , CreationHold (..)
  , withPeers
  , onMain
  , admitUi
  , stopUi
  , instanceStoppedCleanly
  , forgetEnded
  , instancePhaseOf
  , awaitLine
  , awaitLinePrefix
  , readsHeld
  , holdNextReads
  , releaseReadsOf
  , readsEntered
  , withholdNextCreations
  , releaseCreations
  , creationsWithheld
  , refuseNextStandings
  , instanceFailureText
  , verdictCleanOrFail
  , teardownProblems
  , judgeTeardown
  , cancellationProblems
  , judgeCancellation
  , applicationLabel
  , withOwnedLoop
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Concurrent (forkIOWithUnmask, killThread, myThreadId, threadDelay, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryReadMVar)
import Control.Exception (Exception, ExceptionWithContext (..), SomeException, finally, fromException, mask, onException, rethrowIO, throwIO, tryWithContext, uninterruptibleMask_)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Control.Monad (forM_, forever, join, unless, when)
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (isJust, isNothing)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.Identity (contentKeyPath, logicalPathBytes, parseReference)
import Hetoimasia.Content.Inventory (inventoryIdentityLimits, inventoryLimitsOf, inventoryRootKey, readVerified)
import Hetoimasia.Content.ReadPool (ReadPool, poolSpec, withReadPoolUsing)
import Hetoimasia.Foundation.Log (LogFilter (..), Logger, callbackSink, defaultLogFilter, mkLogger, unsafeComponent)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (RequirePositive), durationFromNanoseconds, monotonicSource)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , DiagnosticVerdict
  , defaultCaptureConfig
  , diagnosticVerdictInContext
  , finalizationEvidenceInContext
  , verdictIssues
  )
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent
  , NativeObserver (..)
  , Readiness (..)
  , ValidationFeature (SynchronizationValidation)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , readReadiness
  , runVulkanOwnerLoop
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.LuaEngine.Behavior (behaviorRequest)
import Hetoimasia.LuaEngine.Data (dataService, newByteBankFor)
import Hetoimasia.LuaEngine.Facade
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
  , configurationBudgets
  , configurationFor
  , configureHost
  , withTextureGraphics
  )
import Hetoimasia.LuaEngine.Graphics.Window.Configuration (configureWindows, windowSlots)
import Hetoimasia.LuaEngine.Graphics.Window.Host (PortReading, newHostPort)
import Hetoimasia.LuaEngine.Graphics.Window.Port (CreateIssue (..), CreateOutcome (..), CreateToken, Fatal, Port (..), Standing (..), WindowToken)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), windowMainStep, withWindowProvider)
import Hetoimasia.LuaEngine.Manifest (Role (Gameplay, Presentation))
import Hetoimasia.LuaEngine.Modules
  ( BootOutcome (BootReady)
  , ModuleSpec (..)
  , attachLoader
  , awaitBoot
  , bootModule
  , coordinatorPlan
  , moduleIdentity
  , withModuleCoordinator
  )
import Hetoimasia.LuaEngine.Profile (Count (Count), CountLimit (IoWorkers), countLimit, fixedM1Profile)
import Hetoimasia.LuaEngine.Request (m1Requests)
import Hetoimasia.LuaEngine.Texture (specIoWorkers, textureSpec, withTexturePipeline)
import Hetoimasia.Run.Boot (Prepared (..), withPrepared)
import Hetoimasia.Run.Serve (Owner (..), serveSpawned, runOwned)
import Hetoimasia.Run.Settle (answering, combine, isAsynchronous, rememberingInterruption)
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , UpdateSchedule (NoUpdateDemand)
  , defaultHostConfig
  , defaultScheduledHooks
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner
  , wakeGraphicsHost
  )
import Hetoimasia.Runtime.Logging (LoggingLifetime, withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , RuntimeControl
  , WorkerPolicy (..)
  , WorkerStatus (..)
  , awaitSupervised
  , withSupervision
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance hiding (forgetInstance)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider (RequestGrant (..), RequestTiming (SettleAtAssignedTick, SettleOnArrival))
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)

-- | Everything a scenario drives.
data Peers = Peers
  { peHost ∷ !(VulkanHost GraphicsScene)
  , peGraphics ∷ !TextureGraphics
  , peFacade ∷ !Facade
  , peOwner ∷ !ScheduledOwner
  , pePrepared ∷ !Prepared
  , peControl ∷ !RuntimeControl
  , peOut ∷ !(TVar [Text])
  -- ^ What the scripts printed, oldest last.
  , peStops ∷ !(TVar Int)
  -- ^ How many times a genuine native close was routed to the session's stop endpoint (a user close, never the
  -- cleanup destruction of an ended instance).
  , peFatals ∷ !(TVar [Fatal])
  -- ^ The provider's fatal endpoint: expected empty.
  , peQuits ∷ !(TVar Int)
  -- ^ How many times a script asked to quit through the facade's quit endpoint.
  , peFrames ∷ !(TVar (Int, [FrameEvent]))
  -- ^ The host's frame events, newest first, bounded, with the total count.
  , peDisposals ∷ !(TVar [(Text, Int)])
  -- ^ The native disposals the host's observer saw, oldest first: the call's Vulkan name and how many frame events had
  -- been recorded when the call began. Both are written on the graphics owner's thread, the frame events' own, so the
  -- position is the call's place in the events' order.
  , peReading ∷ !(STM PortReading)
  , peCreationHold ∷ !(TVar CreationHold)
  -- ^ Which window creation outcomes are withheld from the provider.
  , peReadHold ∷ !(TVar (Map.Map ByteString Int))
  -- ^ How many of the next reads of each path the pool's reader holds.
  , peReadsHeldNow ∷ !(TVar [(Int, ByteString)])
  -- ^ The reads held at the reader now, by their order of arrival.
  , peReadsEntered ∷ !(TVar [ByteString])
  , peReadsFinished ∷ !(TVar [ByteString])
  , peJobs ∷ !(TVar [IO ()])
  , peAdmit ∷ !(IO Spawned)
  , peLogicalOwner ∷ !ScheduledOwner
  -- ^ The independent logical owner: its own VM, scheduled on its own timer, running the shipped gameplay behavior.
  , peLogical ∷ !Spawned
  -- ^ Its one instance, admitted before any UI instance and alive for the length of the scenario.
  }

-- | An instance admitted to the UI VM.
data Spawned = Spawned
  { spIdentity ∷ !Text
  , spInstance ∷ !InstanceId
  , spTicket ∷ !InstanceTicket
  }

-- | The scenario was stopped from outside (its caller was cancelled, or the owner loop failed). An ordinary exception,
-- not an asynchronous-typed one: it ends the scenario's thread through its own scopes, and the application's failure it
-- becomes is a failure like any other, so the production job helper does not take it for a cancellation of the main thread.
data ScenarioCancelled = ScenarioCancelled
  deriving (Show)

instance Exception ScenarioCancelled

-- | Why a harness could not even be set up.
newtype PeerFailure = PeerFailure Text
  deriving (Show)

instance Exception PeerFailure

-- | The label under which 'withPeers' retains the end of the application beside a cancellation.
applicationLabel ∷ Text
applicationLabel = "the harness application, which had to be stopped and joined"

-- | Compose the two-instance harness over a real host for the length of the scenario.
--
-- The scenario runs on the session thread; whatever it raises is raised here, with its context (the diagnostic verdict
-- the capture attached, the cleanup failures the scopes retained), after everything has unwound. This function owns the
-- scenario across a cancellation of its caller too: the application is run on the process main thread (queued through
-- @start@), so a caller that is cancelled while it waits (an example's bound expiring, say) cannot simply walk away.
-- It then stops the scenario (a cancellation delivered to the session thread, which releases every gate and retires
-- everything on its way out), waits without a bound for the application to have ended, and only then raises the
-- cancellation, with the application's own failure (and its verdict and cleanup failures) retained beside it. The
-- folder the caller prepared is therefore never removed under a scenario that still borrows it.
--
-- The folder is the owned copy of the content the caller prepared.
withPeers ∷ (∀ x. IO x → IO (IO x)) → FilePath → (Peers → IO a) → IO a
withPeers start folder scenario = mask $ \restore → do
  textureConfiguration ← either (\refused → ioError (userError ("the profile cannot be mapped to the native graphics: " <> show refused))) pure (configurationFor fixedM1Profile)
  scenes ← newSceneSession
  frames ← newTVarIO (0, [])
  disposals ← newTVarIO []
  jobs ← newTVarIO []
  abort ← newTVarIO False
  sessionThread ← newIORef Nothing
  ended ← newEmptyMVar
  verdictCell ← newIORef Nothing
  slot ← newIORef Nothing
  let capture = defaultCaptureConfig {captureTextBudget = 16384}
      base = vulkanHostConfig (defaultHostConfig []) capture (configurationBudgets textureConfiguration) (scenesInitial scenes)
      config =
        (configureScenes scenes (configureWindows (configureHost textureConfiguration base)))
          { vulkanFrameObserver = \event → atomically (modifyTVar' frames (\(count, events) → (count + 1, take 4096 (event : events))))
          , vulkanObserver = \diagnostics → tracingDisposals frames disposals (vulkanObserver base diagnostics)
          , vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = [SynchronizationValidation]
          }
      -- Stop the scenario: latch the request first, then deliver it to the session thread if that already exists; a
      -- session that starts later reads the latch before it runs the scenario. Either order reaches it.
      cancelScenario = do
        atomically (writeTVar abort True)
        readIORef sessionThread >>= mapM_ (\thread → throwTo thread ScenarioCancelled)
      -- The application's outcome travels as /data/, context included. The suite's own plumbing for a main-thread job
      -- re-throws a failure as a fresh exception, which would drop the capture's verdict and the cleanup evidence it
      -- attached; a failure that is data is raised again by 'rethrowIO' in the caller with all of it. A cancellation of the
      -- main thread itself is still raised on it.
      run = (`finally` putMVar ended ()) $ do
        result ← tryWithContext @SomeException application
        case result of
          Left failure | isAsynchronous failure → rethrowIO failure
          _ → pure result
      application = withLoggingLifetime quietLogger $ \lifetime → do
        outcome ←
          runOwned slot cancelScenario $
            withLoaderIntegration $ \integration →
              runGraphicsOwnerApplication
                ($ lifetime)
                "hetoimasia-native-milestone"
                ( \_ use → do
                    (answer, verdict) ← withVulkanOwnerHost quietLogger integration config use
                    writeIORef verdictCell (Just verdict)
                    pure answer
                )
                vulkanWindowHost
                (\vulkan _ → pure vulkan)
                (\vulkan control → body lifetime slot cancelScenario abort sessionThread scenes textureConfiguration config vulkan control frames disposals jobs)
        verdict ← readIORef verdictCell
        verdictCleanOrFail verdict
        pure outcome
  waitMain ← start run
  outcome ← tryWithContext @SomeException (restore waitMain)
  stillRunning ← isNothing <$> tryReadMVar ended
  if not stillRunning
    then either rethrowIO (either rethrowIO pure) outcome
    else do
      -- The wait was interrupted before the application ended: it still owns the scenario, the gates, the windows and
      -- the borrowed folder. Stop it, join it, and keep what it ends with beside the interruption.
      cancelScenario
      interruption ← rememberingInterruption (readMVar ended)
      applicationEnd ← tryWithContext @SomeException waitMain
      let ended' = case applicationEnd of
            Left failure → [failure]
            Right (Left failure) → [failure]
            Right (Right _) → []
      case outcome of
        Left primary →
          rethrowIO
            =<< combine
              (maybe primary id interruption)
              ([(applicationLabel, failure) | failure ← ended'] <> [("the wait that was interrupted", primary) | Just _ ← [interruption]])
        Right (Left failure) → rethrowIO failure
        Right (Right value) → maybe (pure value) rethrowIO interruption
  where
    body lifetime slot cancelScenario abort sessionThread scenes textureConfiguration config vulkan control frames disposals jobs = do
      awaitReadiness vulkan
      _ ← superviseGraphicsOwner control (vulkanGraphicsOwner vulkan)
      providerStep ← newIORef (pure ())
      let finish over = over >>= \finished → pure (if finished then FinishWith () else ContinueWith NoUpdateDemand)
          turnJobs = do
            pending ← atomically (readTVar jobs >>= \queued → writeTVar jobs [] >> pure queued)
            sequence_ pending
          loop checkpoints turn' = runVulkanOwnerLoop vulkan checkpoints (defaultScheduledHooks quietLogger turn')
          owner =
            Owner
              { ownerServe = \turn over → loop control (\_ → turn >> finish over)
              , ownerDrain = \over → withSupervision lifetime $ \fresh → loop fresh (\_ → finish over)
              , ownerWake = wakeGraphicsHost (vulkanGraphicsOwner vulkan)
              }
          session = do
            -- Registered before the latch is read, so a cancellation latched earlier is seen here and one delivered
            -- later reaches this thread.
            myThreadId >>= writeIORef sessionThread . Just
            readTVarIO abort >>= \stopped → when stopped (throwIO ScenarioCancelled)
            withTextureGraphics scenes textureConfiguration config vulkan $ \graphics →
              compose lifetime folder graphics vulkan frames disposals jobs providerStep scenario
      serveSpawned
        lifetime
        owner
        (writeIORef slot . Just)
        cancelScenario
        (turnJobs >> join (readIORef providerStep))
        session

-- | The host's native-call observer with the disposals of a window's graphics recorded in the order of the frame events:
-- the call's place among them is read, on the graphics owner's thread that makes both, just before the call runs. The
-- call itself is the configured observer's, run exactly once, so the diagnostic capture sees it as before.
tracingDisposals ∷ TVar (Int, [FrameEvent]) → TVar [(Text, Int)] → NativeObserver → NativeObserver
tracingDisposals frames disposals (NativeObserver observe) =
  NativeObserver $ \name call → do
    when (name `elem` ["vkDestroySwapchainKHR", "vkDestroyImageView", "vkDestroySurfaceKHR"]) . atomically $ do
      (count, _) ← readTVar frames
      modifyTVar' disposals (<> [(name, count)])
    observe name call

-- | The composition on the session thread, inside the texture adapter.
compose
  ∷ ∀ a
   . LoggingLifetime
  → FilePath
  → TextureGraphics
  → VulkanHost GraphicsScene
  → TVar (Int, [FrameEvent])
  → TVar [(Text, Int)]
  → TVar [IO ()]
  → IORef (IO ())
  → (Peers → IO a)
  → IO a
compose lifetime folder graphics vulkan frames disposals jobs providerStep scenario = do
  stops ← newTVarIO 0
  fatals ← newTVarIO []
  quits ← newTVarIO 0
  out ← newTVarIO []
  creationHold ← newTVarIO noHold
  toHold ← newTVarIO Map.empty
  heldNow ← newTVarIO []
  entered ← newTVarIO []
  finished ← newTVarIO []
  (port0, reading) ← newHostPort vulkan
  let port = gateCreation port0 creationHold
      profile = fixedM1Profile
      Count ioWorkerCount = countLimit profile IoWorkers
      ioWorkers = fromIntegral ioWorkerCount
  pool ← either (\refused → ioError (userError ("the read pool was refused: " <> show refused))) pure (poolSpec ioWorkers 16)
  spec ← either (\refused → ioError (userError ("the texture pipeline was refused: " <> show refused))) pure (textureSpec profile 16)
  when (specIoWorkers spec /= ioWorkers) $ ioError (userError "the pipeline and the pool disagree on the I/O workers")
  prepared' ←
    withPrepared quietLogger profile (pure False) folder $ \prepared → do
      let inventory = preparedInventory prepared
          root = preparedRoot prepared
          gated key allowance = do
            let path = logicalPathBytes (contentKeyPath key)
            -- Arrival and the decision to hold this read are one transaction, so the order of arrival is the order
            -- the holds are given in.
            serial ← atomically $ do
              seen ← readTVar entered
              modifyTVar' entered (<> [path])
              holds ← readTVar toHold
              case Map.lookup path holds of
                Just n | n > 0 → do
                  writeTVar toHold (Map.insert path (n - 1) holds)
                  modifyTVar' heldNow ((length seen, path) :)
                  pure (Just (length seen))
                _ → pure Nothing
            forM_ serial $ \mine → atomically (readTVar heldNow >>= \now → when (mine `elem` map fst now) retry)
            readVerified inventory root key allowance
              `finally` atomically (modifyTVar' finished (<> [path]))
      withReadPoolUsing pool gated $ \readPool →
        withTexturePipeline spec (graphicsBackend graphics) readPool inventory $ \pipeline →
          withSupervision lifetime $ \control → do
            runtime ← newLuaRuntime control
            let windowConfig =
                  WindowConfig
                    { windowRecords = windowSlots
                    , windowStop = atomically (modifyTVar' stops (+ 1))
                    , windowFatal = \found → atomically (modifyTVar' fatals (found :))
                    }
                sink = OutputSink {sinkLine = \line → atomically (modifyTVar' out (<> [line])), sinkFlush = pure ()}
            withWindowProvider windowConfig port $ \provider → do
              writeIORef providerStep (windowMainStep provider)
              let publisher = scenePublisher (graphicsTextures graphics) provider
                  injection = graphicsInjection (GraphicsFacade profile pipeline provider publisher noPublishHooks defaultIssuedMemory)
              statusRef ← newTVarIO (pure (StatusSample False Nothing Nothing))
              tickDuration ← either (\refused → ioError (userError ("the tick duration was refused: " <> show refused))) pure (durationFromNanoseconds RequirePositive 10000000)
              let status = join (readTVar statusRef)
              withOutput sink sink $ \output → do
                let context = VmContext prepared readPool control runtime output quits status
                -- The independent logical owner: its own VM, ticking on its own timer from the shipped manifest's
                -- 10 ms, running the shipped gameplay behavior. It is admitted first and kept alive for the whole
                -- scenario; the UI's status is read from its real instance, never fabricated.
                withVm context Gameplay Nothing (Just tickDuration) $ \logical → do
                  logicalInstance ← vmAdmit logical
                  -- The session's own pacing driver is not part of the public composition, so the harness grants the
                  -- logical owner exact manifest ticks itself, one after the previous is accounted for, paced by the
                  -- system clock; the pump is owned here and ended and joined before the instance is stopped.
                  value ← withTickPump control (vmOwner logical) tickDuration $
                   withVm context Presentation (Just injection) Nothing $ \ui → do
                    let roleSample endpoint identity = do
                          found ← inspectInstance endpoint identity
                          pure $ case snapshotPhase <$> found of
                            Nothing → Nothing
                            Just Initializing → Just (RoleSample False "starting" Nothing)
                            Just Active → Just (RoleSample True "running" Nothing)
                            Just Paused → Just (RoleSample True "running" Nothing)
                            Just Stopping → Just (RoleSample True "stopping" Nothing)
                            Just _ → Just (RoleSample True "retired" Nothing)
                        presentationSample = do
                          live ← scheduledStatus (vmOwner ui)
                          pure $ case live of
                            WorkerLive → Just (RoleSample True "running" Nothing)
                            _ → Just (RoleSample True "retired" Nothing)
                    atomically . writeTVar statusRef $ do
                      gameplay ← roleSample (scheduledEndpoint (vmOwner logical)) (spInstance logicalInstance)
                      presentation ← presentationSample
                      stopping ← (>= 1) <$> readTVar stops
                      pure (StatusSample stopping gameplay presentation)
                    let peers =
                          Peers
                            { peHost = vulkan
                            , peGraphics = graphics
                            , peFacade = vmFacade ui
                            , peOwner = vmOwner ui
                            , pePrepared = prepared
                            , peControl = control
                            , peOut = out
                            , peStops = stops
                            , peFatals = fatals
                            , peQuits = quits
                            , peFrames = frames
                            , peDisposals = disposals
                            , peReading = reading
                            , peCreationHold = creationHold
                            , peReadHold = toHold
                            , peReadsHeldNow = heldNow
                            , peReadsEntered = entered
                            , peReadsFinished = finished
                            , peJobs = jobs
                            , peAdmit = vmAdmit ui
                            , peLogicalOwner = vmOwner logical
                            , peLogical = logicalInstance
                            }
                    -- However the scenario ended, every gate it closed is opened first: a held read or a withheld
                    -- creation is a handoff the unwinding below waits for.
                    scenario peers
                      `finally` ( atomically (writeTVar creationHold noHold >> writeTVar toHold Map.empty >> writeTVar heldNow [])
                                    `finally` writeIORef providerStep (pure ())
                                )
                  -- The scenario returned and the pump has ended: the logical owner's instance retires in order, after
                  -- every UI instance and window has gone, and says it stopped cleanly.
                  requestInstanceControl (scheduledEndpoint (vmOwner logical)) (spInstance logicalInstance) InstanceStop >>= \case
                    InstanceControlAccepted _ → pure ()
                    other → ioError (userError ("the logical instance's stop was not accepted: " <> take 100 (show other)))
                  cleanly ← instanceStoppedCleanly logicalInstance
                  unless cleanly (ioError (userError "the logical instance did not retire as stopped"))
                  pure value
  case prepared' of
    Left refused → ioError (userError ("the shipped content was not prepared: " <> show refused))
    Right value → pure value

-- | Which creations the production port withholds from the provider: how many of the next ones to withhold, and the
-- tokens already withheld.
data CreationHold = CreationHold
  { holdRemaining ∷ !Int
  , holdTokens ∷ !(Set CreateToken)
  , holdRefuse ∷ !Int
  -- ^ How many of the next created windows have their standing refused (an injected clean refusal).
  , holdRefused ∷ !(Set WindowToken)
  }

noHold ∷ CreationHold
noHold = CreationHold 0 Set.empty 0 Set.empty

-- | Withhold the outcomes of the next @n@ window creations from the provider until 'releaseCreations'. The native
-- windows are still created by the host (so they exist and are tracked); only the provider's collection of the
-- result waits, which is the public handoff the pending-work cases need.
withholdNextCreations ∷ Peers → Int → IO ()
withholdNextCreations peers n = atomically (modifyTVar' (peCreationHold peers) (\held → held {holdRemaining = holdRemaining held + n}))

-- | Let every withheld creation outcome through, and withhold no more.
releaseCreations ∷ Peers → IO ()
releaseCreations peers = atomically (modifyTVar' (peCreationHold peers) (\held → held {holdRemaining = 0, holdTokens = Set.empty}))

-- | INJECTED: have the production port answer the graphics owner's standing of each of the next @n@ created windows as a
-- clean, verified refusal (the owner's own rollback evidence, which is what a @window_error@ is), instead of the
-- owner's real answer. The window the host really created is then closed and destroyed by the provider's ordinary
-- retirement, which is the cleanup this injection exists to exercise; no real refusal is claimed, and the exit status of
-- a session that meets one is the owning tests' (the session's failure policy), not observable here.
refuseNextStandings ∷ Peers → Int → IO ()
refuseNextStandings peers n = atomically (modifyTVar' (peCreationHold peers) (\held → held {holdRefuse = holdRefuse held + n}))

-- | How many creation outcomes are withheld now.
creationsWithheld ∷ Peers → STM Int
creationsWithheld peers = Set.size . holdTokens <$> readTVar (peCreationHold peers)

-- | The production port with the chosen creation outcomes withheld: the public handoff between the host's real
-- creation and the provider's collection of its result. The token is recorded before the provider ever sees it.
gateCreation ∷ Port target → TVar CreationHold → Port target
gateCreation port hold =
  port
    { portIssueCreate = \title width height → do
        issued ← portIssueCreate port title width height
        case issued of
          CreateIssued token →
            atomically . modifyTVar' hold $ \held →
              if holdRemaining held > 0 then held {holdRemaining = holdRemaining held - 1, holdTokens = Set.insert token (holdTokens held)} else held
          _ → pure ()
        pure issued
    , portCreateOutcome = \token → do
        held ← readTVar hold
        if token `Set.member` holdTokens held
          then pure Nothing
          else do
            outcome ← portCreateOutcome port token
            case outcome of
              Just (Created window) | holdRefuse held > 0 →
                writeTVar hold held {holdRefuse = holdRefuse held - 1, holdRefused = Set.insert window (holdRefused held)}
              _ → pure ()
            pure outcome
    , portStanding = \window → do
        held ← readTVar hold
        if window `Set.member` holdRefused held
          then pure (StandingRefusedClean "injected clean refusal (LFE-25 native milestone)")
          else portStanding port window
    }

-- | Hold the next @n@ reads of this path at the pool's reader (a held read starts and waits there).
holdNextReads ∷ Peers → ByteString → Int → IO ()
holdNextReads peers path n = atomically (modifyTVar' (peReadHold peers) (Map.insertWith (+) path n))

-- | Let the reads of this path go, and hold no more of them.
releaseReadsOf ∷ Peers → ByteString → IO ()
releaseReadsOf peers path = atomically $ do
  modifyTVar' (peReadHold peers) (Map.delete path)
  modifyTVar' (peReadsHeldNow peers) (filter ((/= path) . snd))

-- | Block until this many reads of this path have reached the pool's reader.
readsEntered ∷ Peers → ByteString → Int → IO ()
readsEntered peers path wanted = atomically (readTVar (peReadsEntered peers) >>= \seen → unless (length (filter (== path) seen) >= wanted) retry)

-- | How many reads of this path are held at the reader now.
readsHeld ∷ Peers → ByteString → STM Int
readsHeld peers path = length . filter ((== path) . snd) <$> readTVar (peReadsHeldNow peers)

-- | What the pieces of one VM need from the composition.
data VmContext = VmContext
  { vcPrepared ∷ !Prepared
  , vcPool ∷ !ReadPool
  , vcControl ∷ !RuntimeControl
  , vcRuntime ∷ !LuaRuntime
  , vcOutput ∷ !Output
  , vcQuits ∷ !(TVar Int)
  , vcStatus ∷ !(STM StatusSample)
  -- ^ What the facade's status endpoint answers: derived from the real instances, never fixed.
  }

-- | One role's VM: its facade, its scheduled owner and the way to admit an instance of the content's behavior.
data Vm = Vm
  { vmFacade ∷ !Facade
  , vmOwner ∷ !ScheduledOwner
  , vmAdmit ∷ !(IO Spawned)
  }

-- | A VM for a role over the composition's pool: a module coordinator, the data service, a facade made with the
-- injection's services (UI only), a supervised scheduled owner. Retired, and waited for, however the body ends.
withVm ∷ ∀ a. VmContext → Role → Maybe GraphicsInjection → Maybe Duration → (Vm → IO a) → IO a
withVm context role injection tick body = do
  let prepared = vcPrepared context
      inventory = preparedInventory prepared
      contentId = preparedContentId prepared
      profile = fixedM1Profile
  handles ← newRequestHandles
  requests ← either (\refused → ioError (userError ("the request policy was refused: " <> show refused))) pure (m1Requests profile handles)
  phase ← newModulePhase
  let moduleSpec =
        ModuleSpec
          { specRequests = requests
          , specInventory = inventory
          , specPool = vcPool context
          , specResolve = inventoryResolver inventory [contentId]
          , specLogger = quietLogger
          , specRole = if role == Presentation then "presentation" else "gameplay"
          , specSlots = 4
          , specBootWaiters = 2
          , specPhase = Just phase
          }
  withModuleCoordinator moduleSpec $ \coordinator → do
    bank ← newByteBankFor profile
    service ← either (\refused → ioError (userError ("the data service was refused: " <> show refused))) pure (dataService requests inventory (vcPool context) bank)
    ids ← newInstanceIds
    services ← traverse (\found → injectGraphics found (GraphicsVm role requests (pure True))) injection
    holder ← newIORef (pure 0)
    let endpoints =
          FacadeEndpoints
            { endpointAdmission = pure AdmissionOpen
            , endpointFailure = \_ → pure ()
            , endpointClock = monotonicSource
            , endpointTick = join (readIORef holder)
            }
        session =
          SessionEndpoints
            { endpointStatus = vcStatus context
            , endpointQuit = atomically (modifyTVar' (vcQuits context) (+ 1))
            , endpointTerminal = \_ → pure False
            }
    facade ←
      newFacade
        FacadeSpec
          { fsRole = role
          , fsRequests = requests
          , fsCoordinator = coordinator
          , fsData = service
          , fsInventory = inventory
          , fsOutput = vcOutput context
          , fsEndpoints = endpoints
          , fsSession = session
          , fsPhase = phase
          , fsRoots = [contentId]
          , fsIds = ids
          , fsTickDuration = tick
          , fsGraphics = services
          }
        >>= either (\refused → ioError (userError ("the facade was refused: " <> show refused))) pure
    let base = (vmProfileConfig LibraryProfileM1) {vmOwnerName = "native-milestone-" <> Text.pack (show role)}
    installed ← either (\refused → ioError (userError ("the facade was not installed: " <> show refused))) pure (installFacade facade [] [] base)
    let instances = facadeInstanceConfig facade (defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8, instanceTickDuration = tick})
        owned =
          (scheduledSpec installed policy bounds)
            { scheduledInstances = Just instances
            , scheduledRequestHandles = Just handles
            , scheduledLending = gsLending <$> services
            , scheduledLeases = gsLeases <$> services
            , scheduledRequests = Just (RequestGrant (facadeRequestEndpoints facade) 64 (if role == Gameplay then SettleAtAssignedTick Nothing else SettleOnArrival))
            , scheduledLoader = Just (coordinatorPlan coordinator)
            , scheduledClock = monotonicSource
            , scheduledTimer = systemTimerBackend
            , scheduledRefusedWait = facadeRefusedWait facade
            }
    started ← startScheduledOwner (vcRuntime context) owned
    owner ← case started of
      ScheduledStarted found → pure found
      _ → ioError (userError "the owner did not start")
    writeIORef holder (atomically (scheduledTick (scheduledEndpoint owner)))
    endpoint ← maybe (ioError (userError "the owner has no loader endpoint")) pure (scheduledLoaderEndpoint owner)
    attachLoader coordinator endpoint
    let key = either (error . show) id (parseReference (inventoryIdentityLimits (inventoryLimitsOf inventory)) (inventoryRootKey inventory) "lua/main.lua")
        admit = do
          booted ← bootModule coordinator key >>= either (\refused → ioError (userError ("the boot load was refused: " <> show refused))) pure
          atomically (awaitBoot booted) >>= \case
            BootReady → pure ()
            other → ioError (userError ("the entry module did not evaluate: " <> show other))
          declared ← declareInstance facade contentId >>= either (\refused → ioError (userError ("declaring was refused: " <> show refused))) pure
          let request = behaviorRequest role (moduleIdentity key) "lua/main.lua" (declaredFacade declared) (Just (declaredId declared)) OrdinaryClass
          admitBehaviorInstance (scheduledEndpoint owner) request >>= \case
            InstanceAccepted identity ticket → pure (Spawned (declaredId declared) identity ticket)
            other → ioError (userError ("expected the instance accepted, found " <> take 100 (show other)))
    body (Vm facade owner admit) `finally` retireAndAwait (vcControl context) owner
  where
    policy = WorkerPolicy Supervision.Service Supervision.Required (unsafeComponent "native.milestone") (\_ → pure Unrecognized)
    bounds =
      SchedulerBounds
        { boundActiveTasks = 16
        , boundQueuedAdmissions = 16
        , boundRetainedResults = 32
        , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
        , boundOutstandingGrants = 4
        , boundControlRequests = 8
        , boundServiceBudget = Nothing
        }

-- | Grant the logical owner exact ticks, one after the previous has been accounted for, paced by the system clock, for the
-- length of the body. The thread is owned here: it is ended and joined on every way out, before the caller goes on.
withTickPump ∷ RuntimeControl → ScheduledOwner → Duration → IO a → IO a
withTickPump control owner tick = withOwnedLoop (forever (grantScheduledStep (scheduledEndpoint owner) tick >> awaitTicksComplete control owner >> threadDelay 10000))

-- | Run a loop on its own thread for the length of the body. Acquiring the thread and registering its stop and join are
-- one masked step, so a cancellation cannot land between the two and abandon the loop; the body runs with the caller's
-- interruptibility restored; the stop and the join of the loop are not interruptible, so no way out of the body returns
-- before the loop has ended. The loop runs unmasked and its end is announced however it ended.
withOwnedLoop ∷ IO () → IO a → IO a
withOwnedLoop loop body = mask $ \restore → do
  done ← newEmptyMVar
  thread ← forkIOWithUnmask $ \unmask → unmask loop `finally` putMVar done ()
  restore body `finally` uninterruptibleMask_ (killThread thread >> takeMVar done)

-- | Ask the owner to retire and wait, under supervision, until it is no longer live.
retireAndAwait ∷ RuntimeControl → ScheduledOwner → IO ()
retireAndAwait control owner = do
  retireScheduled owner
  awaitSupervised control $
    scheduledStatus owner >>= \case
      WorkerLive → retry
      _ → pure ()

-- | Admit one UI instance of the content's behavior, which opens its window and requests its texture by itself.
admitUi ∷ Peers → IO Spawned
admitUi = peAdmit

-- | End an instance through the public Haskell lifecycle control: its cleanup closes its window and releases its
-- holdings, and it is never a user close.
stopUi ∷ Peers → Spawned → IO ()
stopUi peers found =
  requestInstanceControl (scheduledEndpoint (peOwner peers)) (spInstance found) InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → ioError (userError ("expected the stop accepted, found " <> take 100 (show other)))

-- | Wait for the instance's settlement and answer whether it ended as stopped, its shutdown not failed.
instanceStoppedCleanly ∷ Spawned → IO Bool
instanceStoppedCleanly found =
  waitInstance (spTicket found) >>= \settlement → pure $ case resultOutcome settlement of
    InstanceStopped → True
    _ → False

-- | Tell the facade an instance has settled, as the session does once it has seen the settlement, so its place is
-- free for the next declaration.
forgetEnded ∷ Peers → Spawned → IO ()
forgetEnded peers found = forgetInstance (peFacade peers) (spIdentity found)

-- | How the instance failed, as text, when it did; 'Nothing' when it did not fail.
instanceFailureText ∷ Spawned → IO (Maybe String)
instanceFailureText found =
  waitInstance (spTicket found) >>= \settlement → pure $ case resultOutcome settlement of
    InstanceFailed failure → Just (show (failureError failure))
    _ → Nothing

-- | The phase the instance is in now, or 'Nothing' once it is no longer inspectable.
instancePhaseOf ∷ Peers → Spawned → STM (Maybe InstancePhase)
instancePhaseOf peers found = fmap snapshotPhase <$> inspectInstance (scheduledEndpoint (peOwner peers)) (spInstance found)

-- | Run an action on the process main thread's next turn of the owner loop, and answer what it returned or raised.
onMain ∷ Peers → IO b → IO b
onMain peers action = do
  answer ← newEmptyMVar
  -- The capture of the outcome and its answer are one masked step ('answering'), so a cancellation of the main thread
  -- cannot land between them and leave this waiter blocked.
  atomically (modifyTVar' (peJobs peers) (<> [answering answer action]))
  wakeGraphicsHost (vulkanGraphicsOwner (peHost peers))
  takeMVar answer >>= either (\failure → throwIO (failure ∷ SomeException)) pure

-- | Block until a script printed exactly this line; a line that never comes fails with what was printed.
awaitLine ∷ Peers → Text → IO ()
awaitLine peers wanted =
  boundedWait "a script line" (atomically (readTVar (peOut peers) >>= \seen → unless (wanted `elem` seen) retry))
    `onException` (readTVarIO (peOut peers) >>= \seen → hPutStrLn stderr ("waiting for " <> show wanted <> "; printed: " <> show seen))

-- | Block until a script printed a line starting with this.
awaitLinePrefix ∷ Peers → Text → IO ()
awaitLinePrefix peers wanted =
  boundedWait "a script line" (atomically (readTVar (peOut peers) >>= \seen → unless (any (Text.isPrefixOf wanted) seen) retry))
    `onException` (readTVarIO (peOut peers) >>= \seen → hPutStrLn stderr ("waiting for a line starting " <> show wanted <> "; printed: " <> show seen))

-- | A wait that names itself when it does not end within the harness's bound.
boundedWait ∷ String → IO () → IO ()
boundedWait label action =
  timeout (40 * 1000000) action >>= \case
    Just () → pure ()
    Nothing → ioError (userError ("no " <> label <> " within 40 seconds"))

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

-- | The diagnostic verdict after the owner application's last teardown must exist and carry no issue at all: a
-- validation or driver error, a failed or unproven capture, an untrustworthy consumer or counter, and also dropped,
-- truncated, undelivered or unaccounted records. The production composition only warns about lost records; this
-- receipt does not (LFE-25, amendment 6558851696): a run that lost diagnostics is not evidence the layer was heard.
verdictCleanOrFail ∷ Maybe DiagnosticVerdict → IO ()
verdictCleanOrFail = \case
  Nothing → ioError (userError "no diagnostic verdict was reached")
  Just verdict → do
    let issues = verdictIssues verdict
    unless (null issues) $ ioError (userError ("the diagnostic capture was not clean: " <> show issues))

-- | What a failed run's teardown left to say, from the exception the failure reached the caller as: nothing when the
-- capture's verdict is attached and clean and no scope retained a cleanup failure or a finalization observation beside
-- the failure. A failure with no verdict attached is reported too: the host's teardown must have spoken.
-- | What a caller cancelled while it waited for the harness should find beside the cancellation: the application's own end
-- retained under 'applicationLabel' (and at most the interrupted wait itself besides), that end being the scenario's
-- cancellation with a clean attached verdict and no cleanup failure of its own.
cancellationProblems ∷ ExceptionWithContext e → [String]
cancellationProblems (ExceptionWithContext context _) =
  let retained = cleanupFailuresInContext context
      ends = [cleanupFailureException failure | failure ← retained, cleanupFailureLabel failure == applicationLabel]
   in judgeCancellation (length retained) [(teardownProblems end, isScenarioCancelled end) | end ← ends]
  where
    isScenarioCancelled (ExceptionWithContext _ failure) = isJust (fromException failure ∷ Maybe ScenarioCancelled)

-- | The judgement itself over what was found: how many failures were retained beside the cancellation, and for each end of
-- the application retained under its label, what its teardown said and whether it ended by the scenario's cancellation.
judgeCancellation ∷ Int → [([String], Bool)] → [String]
judgeCancellation retained ends =
  ["the application's end is not retained beside the cancellation" | null ends]
    <> ["the application's end is retained more than once" | length ends > 1]
    <> concat [["the application's teardown: " <> problem | problem ← problems] <> ["the application did not end by the scenario's cancellation" | not cancelled] | (problems, cancelled) ← ends]
    <> ["an unexpected failure is retained beside the cancellation" | retained > length ends + 1]

teardownProblems ∷ ExceptionWithContext e → [String]
teardownProblems (ExceptionWithContext context _) =
  judgeTeardown (diagnosticVerdictInContext context) (length (cleanupFailuresInContext context)) (maybe False (const True) (finalizationEvidenceInContext context))

-- | The judgement itself, over what the accessors found, so that it can be examined without a device.
judgeTeardown ∷ Maybe DiagnosticVerdict → Int → Bool → [String]
judgeTeardown verdict cleanupFailures finalizationObserved =
  maybe ["no diagnostic verdict is attached to the failure: the host's teardown did not report"] (\attached → ["the attached verdict has an issue: " <> show issue | issue ← verdictIssues attached]) verdict
    <> ["a cleanup failure was retained beside the failure (" <> show cleanupFailures <> ")" | cleanupFailures > 0]
    <> ["the capture's finalization observed a cancellation or a group-closing failure beside the failure" | finalizationObserved]

quietLogger ∷ Logger
quietLogger = mkLogger defaultLogFilter {filterEnabled = False} (callbackSink (\_ → pure ()))
