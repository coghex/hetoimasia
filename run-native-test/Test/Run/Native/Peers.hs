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
  , withPeers
  , onMain
  , admitUi
  , stopUi
  , awaitLine
  , awaitLinePrefix
  , readsHeld
  , holdReadsOf
  , releaseReadsOf
  , readsEntered
  , withheldCreations
  , releaseCreations
  , verdictCleanOrFail
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
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception, SomeException, finally, onException, throwIO, try)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Control.Monad (join, unless, when)
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (partition)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.Identity (contentKeyPath, logicalPathBytes, parseReference)
import Hetoimasia.Content.Inventory (inventoryIdentityLimits, inventoryLimitsOf, inventoryRootKey, readVerified)
import Hetoimasia.Content.ReadPool (ReadPool, poolSpec, withReadPoolUsing)
import Hetoimasia.Foundation.Log (LogFilter (..), Logger, callbackSink, defaultLogFilter, mkLogger, unsafeComponent)
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict, VerdictIssue (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent
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
import Hetoimasia.LuaEngine.Graphics.Window.Port (Fatal, Port (..))
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), windowMainStep, withWindowProvider)
import Hetoimasia.LuaEngine.Manifest (Role (Presentation))
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
import Hetoimasia.Scripting.Lua.Provider (RequestGrant (..), RequestTiming (SettleOnArrival))
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
  , peReading ∷ !(STM PortReading)
  , peCreationGate ∷ !(TVar Bool)
  -- ^ False while window creation outcomes are withheld from the provider.
  , peReadHold ∷ !(TVar (Set ByteString))
  , peReadsEntered ∷ !(TVar [ByteString])
  , peReadsFinished ∷ !(TVar [ByteString])
  , peJobs ∷ !(TVar [IO ()])
  , peAdmit ∷ !(IO Spawned)
  }

-- | An instance admitted to the UI VM.
data Spawned = Spawned
  { spIdentity ∷ !Text
  , spInstance ∷ !InstanceId
  , spTicket ∷ !InstanceTicket
  }

-- | Why a harness could not even be set up.
newtype PeerFailure = PeerFailure Text
  deriving (Show)

instance Exception PeerFailure

-- | Compose the two-instance harness over a real host for the length of the scenario.
--
-- The scenario runs on the session thread; whatever it raises is raised here after everything has unwound, and the
-- diagnostic capture's verdict must then be clean. The folder is the owned copy of the content the caller prepared.
withPeers ∷ (∀ x. IO x → IO (IO x)) → FilePath → (Peers → IO a) → IO a
withPeers start folder scenario = do
  textureConfiguration ← either (\refused → ioError (userError ("the profile cannot be mapped to the native graphics: " <> show refused))) pure (configurationFor fixedM1Profile)
  scenes ← newSceneSession
  frames ← newTVarIO (0, [])
  jobs ← newTVarIO []
  abort ← newTVarIO False
  verdictCell ← newIORef Nothing
  slot ← newIORef Nothing
  let capture = defaultCaptureConfig {captureTextBudget = 16384}
      base = vulkanHostConfig (defaultHostConfig []) capture (configurationBudgets textureConfiguration) (scenesInitial scenes)
      config =
        (configureScenes scenes (configureWindows (configureHost textureConfiguration base)))
          { vulkanFrameObserver = \event → atomically (modifyTVar' frames (\(count, events) → (count + 1, take 4096 (event : events))))
          , vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = [SynchronizationValidation]
          }
      run = withLoggingLifetime quietLogger $ \lifetime → do
        outcome ←
          runOwned slot (atomically (writeTVar abort True)) $
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
                (\vulkan control → body lifetime slot abort scenes textureConfiguration config vulkan control frames jobs)
        verdict ← readIORef verdictCell
        verdictCleanOrFail verdict
        pure outcome
  join (start run)
  where
    body lifetime slot abort scenes textureConfiguration config vulkan control frames jobs = do
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
          session = withTextureGraphics scenes textureConfiguration config vulkan $ \graphics →
            compose lifetime folder graphics vulkan frames jobs providerStep scenario
      serveSpawned
        lifetime
        owner
        (writeIORef slot . Just)
        (atomically (writeTVar abort True))
        (turnJobs >> join (readIORef providerStep))
        session

-- | The composition on the session thread, inside the texture adapter.
compose
  ∷ ∀ a
   . LoggingLifetime
  → FilePath
  → TextureGraphics
  → VulkanHost GraphicsScene
  → TVar (Int, [FrameEvent])
  → TVar [IO ()]
  → IORef (IO ())
  → (Peers → IO a)
  → IO a
compose lifetime folder graphics vulkan frames jobs providerStep scenario = do
  stops ← newTVarIO 0
  fatals ← newTVarIO []
  quits ← newTVarIO 0
  out ← newTVarIO []
  creationGate ← newTVarIO True
  held ← newTVarIO Set.empty
  entered ← newTVarIO []
  finished ← newTVarIO []
  (port0, reading) ← newHostPort vulkan
  let port = gateCreation port0 creationGate
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
            atomically (modifyTVar' entered (<> [path]))
            atomically (readTVar held >>= \paths → when (path `Set.member` paths) retry)
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
              withOutput sink sink $ \output →
                withVm (VmContext prepared readPool control runtime output quits) Presentation (Just injection) $ \ui →
                  ( do
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
                              , peReading = reading
                              , peCreationGate = creationGate
                              , peReadHold = held
                              , peReadsEntered = entered
                              , peReadsFinished = finished
                              , peJobs = jobs
                              , peAdmit = vmAdmit ui
                              }
                      scenario peers
                    )
                    -- However the scenario ended, every gate it closed is opened first: a held read or a withheld
                    -- creation is a handoff the unwinding below waits for.
                    `finally` ( atomically (writeTVar creationGate True >> writeTVar held Set.empty)
                                  `finally` writeIORef providerStep (pure ())
                              )
  case prepared' of
    Left refused → ioError (userError ("the shipped content was not prepared: " <> show refused))
    Right value → pure value

-- | Withhold nothing from the provider again: the gate on creation outcomes opens.
releaseCreations ∷ Peers → IO ()
releaseCreations peers = atomically (writeTVar (peCreationGate peers) True)

-- | Withhold window creation outcomes from the provider until 'releaseCreations'.
withheldCreations ∷ Peers → IO ()
withheldCreations peers = atomically (writeTVar (peCreationGate peers) False)

-- | The production port with creation outcomes withheld while the gate is closed: the public handoff between the
-- host's real creation and the provider's collection of its result.
gateCreation ∷ Port target → TVar Bool → Port target
gateCreation port gate =
  port
    { portCreateOutcome = \token → do
        open ← readTVar gate
        if open then portCreateOutcome port token else pure Nothing
    }

-- | Hold every read of this path at the pool's reader (a held read starts and waits there).
holdReadsOf ∷ Peers → ByteString → IO ()
holdReadsOf peers path = atomically (modifyTVar' (peReadHold peers) (Set.insert path))

-- | Let the reads of this path go.
releaseReadsOf ∷ Peers → ByteString → IO ()
releaseReadsOf peers path = atomically (modifyTVar' (peReadHold peers) (Set.delete path))

-- | Block until this many reads of this path have reached the pool's reader.
readsEntered ∷ Peers → ByteString → Int → IO ()
readsEntered peers path wanted = atomically (readTVar (peReadsEntered peers) >>= \seen → unless (length (filter (== path) seen) >= wanted) retry)

-- | How many reads of this path are at the reader and have not returned.
readsHeld ∷ Peers → ByteString → STM Int
readsHeld peers path = do
  entered ← readTVar (peReadsEntered peers)
  finished ← readTVar (peReadsFinished peers)
  pure (length (filter (== path) entered) - length (filter (== path) finished))

-- | What the pieces of one VM need from the composition.
data VmContext = VmContext
  { vcPrepared ∷ !Prepared
  , vcPool ∷ !ReadPool
  , vcControl ∷ !RuntimeControl
  , vcRuntime ∷ !LuaRuntime
  , vcOutput ∷ !Output
  , vcQuits ∷ !(TVar Int)
  }

-- | One role's VM: its facade, its scheduled owner and the way to admit an instance of the content's behavior.
data Vm = Vm
  { vmFacade ∷ !Facade
  , vmOwner ∷ !ScheduledOwner
  , vmAdmit ∷ !(IO Spawned)
  }

-- | A VM for a role over the composition's pool: a module coordinator, the data service, a facade made with the
-- injection's services (UI only), a supervised scheduled owner. Retired, and waited for, however the body ends.
withVm ∷ ∀ a. VmContext → Role → Maybe GraphicsInjection → (Vm → IO a) → IO a
withVm context role injection body = do
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
        running = Just (RoleSample True "running" Nothing)
        session =
          SessionEndpoints
            { endpointStatus = pure (StatusSample False running running)
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
          , fsTickDuration = Nothing
          , fsGraphics = services
          }
        >>= either (\refused → ioError (userError ("the facade was refused: " <> show refused))) pure
    let base = (vmProfileConfig LibraryProfileM1) {vmOwnerName = "native-milestone-" <> Text.pack (show role)}
    installed ← either (\refused → ioError (userError ("the facade was not installed: " <> show refused))) pure (installFacade facade [] [] base)
    let instances = facadeInstanceConfig facade (defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8})
        owned =
          (scheduledSpec installed policy bounds)
            { scheduledInstances = Just instances
            , scheduledRequestHandles = Just handles
            , scheduledLending = gsLending <$> services
            , scheduledLeases = gsLeases <$> services
            , scheduledRequests = Just (RequestGrant (facadeRequestEndpoints facade) 64 SettleOnArrival)
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

-- | Run an action on the process main thread's next turn of the owner loop, and answer what it returned or raised.
onMain ∷ Peers → IO b → IO b
onMain peers action = do
  answer ← newEmptyMVar
  atomically (modifyTVar' (peJobs peers) (<> [try @SomeException action >>= putMVar answer]))
  wakeGraphicsHost (vulkanGraphicsOwner (peHost peers))
  takeMVar answer >>= either throwIO pure

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

-- | The diagnostic verdict after the owner application's last teardown must exist and be clean of every fatal issue
-- (a validation or driver error, a failed or unproven capture, an untrustworthy consumer or counter). Diagnostics that
-- were only lost are not a fault of the run; they are the case's to report if it wants to.
verdictCleanOrFail ∷ Maybe DiagnosticVerdict → IO ()
verdictCleanOrFail = \case
  Nothing → ioError (userError "no diagnostic verdict was reached")
  Just verdict → do
    let (fatal, _lost) = partition fatalIssue (verdictIssues verdict)
    unless (null fatal) $ ioError (userError ("the diagnostic capture was not clean: " <> show fatal))

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

quietLogger ∷ Logger
quietLogger = mkLogger defaultLogFilter {filterEnabled = False} (callbackSink (\_ → pure ()))
