{-# LANGUAGE OverloadedStrings #-}

-- | Two presentation instances of one VM, through the /production/ graphics injection ('graphicsInjection') over the
-- real texture pipeline, window provider and scene publisher (the texture owner, the windows and the host's ledger
-- are the fakes and the model: injected evidence, as in the session examples).
--
-- A public @runSession@ composition has one instance of a role; the second instance of a role is the session harness's
-- private seam, so these examples compose the facade directly, the way the session does (a module coordinator, the data
-- service, a facade made with the injection's services, a supervised scheduled owner), and drive the instances' lives
-- themselves. They show that ending one instance through Haskell leaves its peer's window and texture usable and
-- publishable, that the owner map is cleaned for exactly the instance that ended, and that a peer's handle, facade or
-- retired texture is refused.
module Test.LuaEngine.Graphics.Peers (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, retry)
import Control.Exception (finally)
import Control.Monad (forM_, forever, unless, void)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
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
import Test.Hspec
import Test.LuaEngine.Graphics.Composition (Composition (..), compositionProfile, withComposition)
import Test.LuaEngine.Graphics.Fake (fakeLedger, setBarrier)
import qualified Test.LuaEngine.Graphics.Fake as Fake
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.Rig (Rig (..), bounded, withRig)
import Test.LuaEngine.Graphics.SceneHost
import qualified Test.LuaEngine.Graphics.Window.Fake as WF

-- | Everything an example drives.
data Peers = Peers
  { peFacade ∷ !Facade
  , peOwner ∷ !ScheduledOwner
  , peModel ∷ !Model
  , peProvider ∷ !(WindowProvider Int)
  , peOut ∷ !(TVar [Text])
  , peAdmit ∷ !(IO Spawned)
  }

-- | An instance admitted to the VM.
data Spawned = Spawned
  { spIdentity ∷ !Text
  , spInstance ∷ !InstanceId
  , spTicket ∷ !InstanceTicket
  }

spec ∷ Spec
spec = describe "graphics facade, two instances of one VM" $
  it "leaves a surviving instance's window and texture usable and publishable when its peer ends, cleans the owner map for the one that ended, and refuses the peer's handle, even once its texture has retired" $
    withPeers $ \peers → do
      first ← peAdmit peers
      second ← peAdmit peers
      -- Each instance opened a window and loaded a texture, took them and published a scene to its own window.
      awaitLine peers "published\t1"
      awaitLine peers "published\t2"
      forM_ [2, 4] $ \window → awaitRevision (peModel peers) window 1 >> void (adoptNow (peModel peers) window)
      atomically (providerReading (peProvider peers)) >>= \found → readingAcquisitions found `shouldBe` 2
      -- The first instance ends through Haskell, and the facade is told, as the session tells it once the settlement is seen.
      stop peers first
      -- Its window's target ends with it: the host releases what its adopted scene held, so its texture can retire.
      removeWindow (peModel peers) 2
      _ ← waitInstance (spTicket first)
      forgetInstance (peFacade peers) (spIdentity first)
      -- Its window retires; the survivor's stays, and the survivor publishes again to it and releases its texture.
      atomically (providerReading (peProvider peers) >>= \found → unless (readingAcquisitions found == 1) retry)
      awaitLinePrefix peers "republished\t2\t"
      awaitRevision (peModel peers) 4 2
      -- Its handle, kept in the shared export, is refused to the survivor, as is its facade, and the refusal is an
      -- ordinary error (the survivor goes on).
      awaitLine peers "foreign\tfalse\ttrue"
      -- The survivor's published scene is released by the host (its target ends), so its texture can retire with it.
      dissolve (peModel peers)
      stop peers second
      _ ← waitInstance (spTicket second)
      forgetInstance (peFacade peers) (spIdentity second)

withPeers ∷ (Peers → IO a) → IO a
withPeers body = bounded . withRig Fake.defaultFakeConfig $ \rig → do
  let fake = rigFake rig
  model ← newModel (fakeLedger fake)
  setBarrier fake (modelCapture model)
  forM_ [1 .. 8] (modelWindow model)
  windows ← WF.newFake WF.defaultFakeConfig
  textures ← newTextures
  let config = WindowConfig 2 (pure ()) (\_ → pure ())
      files = [("lua/main.lua", peersEntry), ("lua/share.lua", "return {apis = {}, handles = {}}"), ("images/quad.png", Png.solid 2 2 (200, 100, 50, 255))]
  withComposition compositionProfile files (rigPort rig) $ \composition control runtime →
    withWindowProvider config (retarget (WF.fakePort windows)) $ \provider →
      ( do
          let publisher = scenePublisherOver textures provider (\window scene → fst (modelTarget model window) scene) (\window → snd (modelTarget model window))
              injection = graphicsInjection (GraphicsFacade compositionProfile (cpPipeline composition) provider publisher noPublishHooks)
              profile = compositionProfile
              inventory = cpInventory composition
          handles ← newRequestHandles
          requests ← either (\refused → assertFailure ("the request policy was refused: " <> show refused)) pure (m1Requests profile handles)
          phase ← newModulePhase
          out ← newTVarIO []
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
                    { endpointStatus = pure (StatusSample False Nothing (Just (RoleSample True "running" Nothing)))
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
            ( mainLoop provider (body (Peers facade owner model provider out admit))
                -- (however the body ended, the host model lets go of every adoption first, so that the instances' textures can retire)
                `finally` (dissolve model >> WF.releaseAll windows >> retireAndAwait control owner)
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

awaitLine ∷ Peers → Text → IO ()
awaitLine peers wanted = atomically $ readTVar (peOut peers) >>= \seen → unless (wanted `elem` seen) retry

awaitLinePrefix ∷ Peers → Text → IO ()
awaitLinePrefix peers wanted = atomically $ readTVar (peOut peers) >>= \seen → unless (any (Text.isPrefixOf wanted) seen) retry

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

-- | One entry for both instances: open a window and load a texture in init, take both, publish a scene to the
-- instance's own window; when the first instance's shutdown says it ended, publish again and release the texture; and
-- try the first instance's handle and facade, kept in the shared export.
peersEntry ∷ ByteString
peersEntry =
  Text.encodeUtf8 . Text.unlines $
    [ "local share = import('lua/share.lua')"
    , "return {"
    , "  presentation = {"
    , "    every_seconds = 0.02,"
    , "    init = function(self, api)"
    , "      self.my = #share.apis + 1"
    , "      share.apis[self.my] = api"
    , "      self.w = api.window.open({title = 't', width = 64, height = 64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update = function(self, dt)"
    , "      local api = self.api"
    , "      if not self.win and api.request.ready(self.w) then self.win = api.request.take(self.w).value end"
    , "      if not self.img and api.request.ready(self.t) then"
    , "        self.img = api.request.take(self.t).value"
    , "        share.handles[self.my] = self.img.texture"
    , "      end"
    , "      if not (self.win and self.img) then return end"
    , "      if not self.a then"
    , "        self.a = true"
    , "        api.scene.publish(self.win, {clear = {r = self.my, g = 0, b = 0}, sprites = {{texture = self.img.texture, x = 0, y = 0, width = 2, height = 2}}})"
    , "        print('published', self.my)"
    , "        return"
    , "      end"
    , "      if self.my == 2 and share.ended and not self.b then"
    , "        self.b = true"
    , "        api.scene.publish(self.win, {clear = {r = 9, g = 0, b = 0}, sprites = {{texture = self.img.texture, x = 0, y = 0, width = 2, height = 2}}})"
    , "        print('republished', self.my, api.texture.release(self.img.texture))"
    , "        local ok1, e1 = pcall(api.texture.release, share.handles[1])"
    , "        local ok2, e2 = pcall(share.apis[1].window.open, {title = 't', width = 1, height = 1})"
    , "        print('foreign', ok1, tostring(e1):find('belongs to another instance') ~= nil and tostring(e2):find('belongs to another instance') ~= nil)"
    , "      end"
    , "    end,"
    , "    shutdown = function(self, reason) if self.my == 1 then share.ended = true end end"
    , "  }"
    , "}"
    ]

