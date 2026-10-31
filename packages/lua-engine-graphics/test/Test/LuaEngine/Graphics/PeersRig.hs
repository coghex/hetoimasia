{-# LANGUAGE OverloadedStrings #-}

-- | The two-instance composition of the graphics facade, shared by the examples that admit two presentation instances of one
-- VM through the /production/ graphics injection over the real texture pipeline, window provider and scene publisher, with the
-- texture owner, the windows and the host's ledger as the fakes and the model (injected evidence).
--
-- A public @runSession@ composition has one instance of a role; the second instance of a role is the session harness's
-- private seam, so these examples compose the facade directly, the way the session does, and admit and end the instances
-- themselves through the owner's public endpoints.
module Test.LuaEngine.Graphics.PeersRig
  ( Peers (..)
  , Spawned (..)
  , withPeersWith
  , withPeersHooked
  , withPeersConfigured
  , mainLoop
  , retireAndAwait
  , stop
  , awaitLine
  , awaitLinePrefix
  , retarget
  , quietLogger
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (finally, onException)
import System.IO (hPutStrLn, stderr)
import Control.Monad (forM_, forever, unless)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import Data.Text (Text)
import Hetoimasia.Content.Identity (parseReference)
import Hetoimasia.Content.Inventory (inventoryIdentityLimits, inventoryLimitsOf, inventoryRootKey)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith, unsafeComponent)
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.LuaEngine.Behavior (behaviorRequest)
import Hetoimasia.LuaEngine.Data (dataService, newByteBankFor)
import Hetoimasia.LuaEngine.Facade
import Hetoimasia.LuaEngine.Graphics.Facade (GraphicsFacade (..), graphicsInjection)
import Hetoimasia.LuaEngine.Graphics.Scene (noPublishHooks, scenePublisherOver)
import Hetoimasia.LuaEngine.Graphics.Window.Port (Port (..), WindowToken (..))
import Hetoimasia.LuaEngine.Graphics.Window.Provider
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
import Hetoimasia.LuaEngine.Request (m1Requests)
import Hetoimasia.Render.TwoD.Vulkan.Textures (newTextures)
import Hetoimasia.Runtime.Supervision (Recognition (Unrecognized), RuntimeControl, WorkerPolicy (..), WorkerStatus (..), awaitSupervised)
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance hiding (forgetInstance)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider (RequestGrant (..), RequestTiming (SettleOnArrival))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Test.HUnit.Lang (assertFailure)
import Test.LuaEngine.Graphics.Composition (Composition (..), compositionProfile, releaseAllReads, withComposition)
import Test.LuaEngine.Graphics.Fake (fakeLedger, setBarrier)
import qualified Test.LuaEngine.Graphics.Fake as Fake
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.Rig (Rig (..), bounded, openEveryHold, withRig)
import Test.LuaEngine.Graphics.SceneHost
import qualified Test.LuaEngine.Graphics.Window.Fake as WF

-- | Everything an example drives.
data Peers = Peers
  { peFacade ∷ !Facade
  , peOwner ∷ !ScheduledOwner
  , peModel ∷ !Model
  , peProvider ∷ !(WindowProvider Int)
  , peOut ∷ !(TVar [Text])
  , peSignal ∷ !(TVar Bool)
  -- ^ What the fake session's status says is stopping: the example's one-way word to the survivor.
  , peAdmit ∷ !(IO Spawned)
  , peFake ∷ !Fake.Fake
  , peWindows ∷ !WF.Fake
  , peComposition ∷ !Composition
  }

-- | An instance admitted to the VM.
data Spawned = Spawned
  { spIdentity ∷ !Text
  , spInstance ∷ !InstanceId
  , spTicket ∷ !InstanceTicket
  }

-- | The same composition with the given entry module and the given number of issued handles remembered.
withPeersWith ∷ ByteString → Int → (Peers → IO a) → IO a
withPeersWith = withPeersHooked noProviderHooks WF.defaultFakeConfig

-- | The same composition with the given window-provider hooks and window fake: the places an example holds a step of the
-- provider, and the stages of the fake windows it holds back.
withPeersHooked ∷ ProviderHooks → WF.FakeConfig → ByteString → Int → (Peers → IO a) → IO a
withPeersHooked = withPeersConfigured Fake.defaultFakeConfig

-- | The same with the given configuration of the texture owner's fake: the stages it holds from the start.
withPeersConfigured ∷ Fake.FakeConfig → ProviderHooks → WF.FakeConfig → ByteString → Int → (Peers → IO a) → IO a
withPeersConfigured fakeConfig hooks windowConfig entry issuedMemory body = bounded . withRig fakeConfig $ \rig → do
  let fake = rigFake rig
  model ← newModel (fakeLedger fake)
  setBarrier fake (modelCapture model)
  forM_ [1 .. 8] (modelWindow model)
  windows ← WF.newFake windowConfig
  textures ← newTextures
  let config = WindowConfig 2 (pure ()) (\_ → pure ())
      files = [("lua/main.lua", entry), ("lua/share.lua", "return {apis = {}, handles = {}}"), ("images/quad.png", Png.solid 2 2 (200, 100, 50, 255))]
  withComposition compositionProfile files (rigPort rig) $ \composition control runtime →
    withWindowProviderWith hooks config (retarget (WF.fakePort windows)) $ \provider →
      ( do
          let publisher = scenePublisherOver textures provider (\window scene → fst (modelTarget model window) scene) (\window → snd (modelTarget model window))
              injection = graphicsInjection (GraphicsFacade compositionProfile (cpPipeline composition) provider publisher noPublishHooks issuedMemory)
              profile = compositionProfile
              inventory = cpInventory composition
          handles ← newRequestHandles
          requests ← either (\refused → assertFailure ("the request policy was refused: " <> show refused)) pure (m1Requests profile handles)
          phase ← newModulePhase
          out ← newTVarIO []
          signal ← newTVarIO False
          let moduleSpec =
                ModuleSpec
                  { specRequests = requests
                  , specInventory = inventory
                  , specPool = cpPool composition
                  , specResolve = inventoryResolver inventory ["graphics-test"]
                  , specLogger = quietLogger
                  , specRole = "presentation"
                  , specSlots = 4
                  , specBootWaiters = 2
                  , specPhase = Just phase
                  }
              sink = OutputSink {sinkLine = \line → atomically (modifyTVar' out (<> [line])), sinkFlush = pure ()}
          withOutput sink sink $ \output → withModuleCoordinator moduleSpec $ \coordinator → do
            bank ← newByteBankFor profile
            service ← either (\refused → assertFailure ("the data service was refused: " <> show refused)) pure (dataService requests inventory (cpPool composition) bank)
            ids ← newInstanceIds
            services ← injectGraphics injection (GraphicsVm Presentation requests (pure True))
            let endpoints =
                  FacadeEndpoints
                    { endpointAdmission = pure AdmissionOpen
                    , endpointFailure = \_ → pure ()
                    , endpointClock = monotonicSource
                    , endpointTick = pure 0
                    }
                session =
                  SessionEndpoints
                    { endpointStatus = (\stopping → StatusSample stopping Nothing (Just (RoleSample True "running" Nothing))) <$> readTVar signal
                    , endpointQuit = pure ()
                    , endpointTerminal = \_ → pure False
                    }
            facade ←
              newFacade
                FacadeSpec
                  { fsRole = Presentation
                  , fsRequests = requests
                  , fsCoordinator = coordinator
                  , fsData = service
                  , fsInventory = inventory
                  , fsOutput = output
                  , fsEndpoints = endpoints
                  , fsSession = session
                  , fsPhase = phase
                  , fsRoots = ["graphics-test"]
                  , fsIds = ids
                  , fsTickDuration = Nothing
                  , fsGraphics = Just services
                  }
                >>= either (\refused → assertFailure ("the facade was refused: " <> show refused)) pure
            let base = (vmProfileConfig LibraryProfileM1) {vmOwnerName = "peers"}
            installed ← either (\refused → assertFailure ("the facade was not installed: " <> show refused)) pure (installFacade facade [] [] base)
            let instances = facadeInstanceConfig facade (defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8})
                owned =
                  (scheduledSpec installed policy bounds)
                    { scheduledInstances = Just instances
                    , scheduledRequestHandles = Just handles
                    , scheduledLending = Just (gsLending services)
                    , scheduledLeases = Just (gsLeases services)
                    , scheduledRequests = Just (RequestGrant (facadeRequestEndpoints facade) 64 SettleOnArrival)
                    , scheduledLoader = Just (coordinatorPlan coordinator)
                    , scheduledClock = monotonicSource
                    , scheduledTimer = systemTimerBackend
                    , scheduledRefusedWait = facadeRefusedWait facade
                    }
            started ← startScheduledOwner runtime owned
            owner ← case started of
              ScheduledStarted found → pure found
              other → assertFailure ("the owner did not start: " <> take 100 (show (const () <$> Just other)))
            endpoint ← maybe (assertFailure "the owner has no loader endpoint") pure (scheduledLoaderEndpoint owner)
            attachLoader coordinator endpoint
            let key = either (error . show) id (parseReference (inventoryIdentityLimits (inventoryLimitsOf inventory)) (inventoryRootKey inventory) "lua/main.lua")
                admit = do
                  booted ← bootModule coordinator key >>= either (\refused → assertFailure ("the boot load was refused: " <> show refused)) pure
                  atomically (awaitBoot booted) >>= \outcome → case outcome of
                    BootReady → pure ()
                    other → assertFailure ("the entry module did not evaluate: " <> show other)
                  declared ← declareInstance facade "graphics-test" >>= either (\refused → assertFailure ("declaring was refused: " <> show refused)) pure
                  let request = behaviorRequest Presentation (moduleIdentity key) "lua/main.lua" (declaredFacade declared) (Just (declaredId declared)) OrdinaryClass
                  admitBehaviorInstance (scheduledEndpoint owner) request >>= \case
                    InstanceAccepted identity ticket → pure (Spawned (declaredId declared) identity ticket)
                    other → assertFailure ("expected the instance accepted, found " <> take 100 (show other))
            ( mainLoop provider (body (Peers facade owner model provider out signal admit fake windows composition))
                -- (however the body ended, the host model lets go of every adoption first, so that the instances' textures can retire)
                `finally` (openEveryHold fake >> releaseAllReads composition >> dissolve model >> WF.releaseAll windows >> retireAndAwait control owner)
              )
      )
        `finally` (WF.releaseAll windows >> dissolve model >> endWindows provider)
  where
    policy = WorkerPolicy Supervision.Service Supervision.Required (unsafeComponent "test.luaengine.graphics.peers") (\_ → pure Unrecognized)
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

-- | Serve the provider's main-thread steps for the length of the body, on a thread that is ended and waited for.
mainLoop ∷ WindowProvider Int → IO a → IO a
mainLoop provider action = do
  ended ← newEmptyMVar
  thread ← forkIO (forever (atomically (windowMainReady provider >>= \ready → unless ready retry) >> windowMainStep provider) `finally` putMVar ended ())
  action `finally` (killThread thread >> takeMVar ended)

-- | Ask the owner to retire and wait, under supervision, until it is no longer live.
retireAndAwait ∷ RuntimeControl → ScheduledOwner → IO ()
retireAndAwait control owner = do
  retireScheduled owner
  awaitSupervised control $
    scheduledStatus owner >>= \case
      WorkerLive → retry
      _ → pure ()

stop ∷ Peers → Spawned → IO ()
stop peers found =
  requestInstanceControl (scheduledEndpoint (peOwner peers)) (spInstance found) InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → assertFailure ("expected the stop accepted, found " <> take 100 (show other))

-- | Block until a script printed exactly this line. Bounded: a line that never comes fails the example with what the
-- scripts did print, so the first broken invariant is in the log.
awaitLine ∷ Peers → Text → IO ()
awaitLine peers wanted =
  bounded (atomically (readTVar (peOut peers) >>= \seen → unless (wanted `elem` seen) retry))
    `onException` (readTVarIO (peOut peers) >>= \seen → hPutStrLn stderr ("waiting for " <> show wanted <> "; printed: " <> show seen))

awaitLinePrefix ∷ Peers → Text → IO ()
awaitLinePrefix peers wanted =
  bounded (atomically (readTVar (peOut peers) >>= \seen → unless (any (Text.isPrefixOf wanted) seen) retry))
    `onException` (readTVarIO (peOut peers) >>= \seen → hPutStrLn stderr ("waiting for a line starting " <> show wanted <> "; printed: " <> show seen))

retarget ∷ Port () → Port Int
retarget port =
  Port
    { portIssueCreate = portIssueCreate port
    , portCreateOutcome = portCreateOutcome port
    , portAttach = portAttach port
    , portStanding = portStanding port
    , portCloseRequest = portCloseRequest port
    , portBeginClose = portBeginClose port
    , portRetirement = portRetirement port
    , portTarget = \token@(WindowToken number) → fmap (fmap (const (fromIntegral number))) (portTarget port token)
    , portOwnerFailure = portOwnerFailure port
    , portQueueRoom = portQueueRoom port
    , portWakeMain = portWakeMain port
    }

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

