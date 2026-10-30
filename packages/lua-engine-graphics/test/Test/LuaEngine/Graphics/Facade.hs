{-# LANGUAGE OverloadedStrings #-}

-- | The graphics facade (LFE-21) on a real @runSession@: the production injection ('graphicsInjection') installs the
-- UI-only graphics calls into the roles' VMs of a real session, with @noHarness@, over a real content root, manifest,
-- boot checkpoint, read pool, supervised owners, request admission, instance leases, texture pipeline and window
-- provider.
--
-- Injected, and it says so: the texture owner (the fake owner), the windows (the window fake) and the host's answer to
-- a publication and its ledger (the scene host model). The evidence is ordering, ownership and the session's
-- own policy, never a frame; the real GPU is the native suite's subgroup of the same name.
--
-- Nothing sleeps. A scenario knows what has happened by blocking in STM on a reading, and every thread it starts
-- terminates before the example returns, a failed assertion in it included.
module Test.LuaEngine.Graphics.Facade (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (forM_, forever, unless, void)
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith)
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.LuaEngine.Boot (bootCheckpoint)
import Hetoimasia.LuaEngine.Facade (OutputSink (..), withOutput)
import Hetoimasia.LuaEngine.Graphics.Facade (GraphicsFacade (..), graphicsInjection)
import Hetoimasia.LuaEngine.Graphics.Scene (GraphicsScene (..), PublishHooks (..), noPublishHooks, scenePublisherOver)
import Hetoimasia.LuaEngine.Graphics.Window.Port (CreateOutcome (..), Port (..), WindowToken (..), fatalText)
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.LuaEngine.Manifest (Role (Presentation))
import Hetoimasia.LuaEngine.Profile (Count (Count), CountLimit (RequestsPerInstance, TextureLeasesPerUiInstance), Profile, ProfileSpec (..), profileSpec, validateProfile)
import Hetoimasia.LuaEngine.Scene (SceneContent (..), SceneRect (..), SceneSprite (..), TextureUse (..))
import Hetoimasia.LuaEngine.Texture (TextureView (..))
import qualified Data.Set as Set
import Hetoimasia.LuaEngine.Session
import Hetoimasia.Render.TwoD.Vulkan.Textures (newTextures)
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)
import System.Timeout (timeout)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition (Composition (..), compositionProfile, withComposition)
import Test.LuaEngine.Graphics.Fake (fakeLedger, setBarrier)
import Test.LuaEngine.Graphics.FacadeScripts (isClear, manifestFor, quadExample)
import qualified Test.LuaEngine.Graphics.Fake as Fake
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.Rig (Rig (..), bounded, withRig)
import Test.LuaEngine.Graphics.SceneHost
import qualified Test.LuaEngine.Graphics.Window.Fake as WF

-- | Everything a scenario drives.
data FS = FS
  { fsSession ∷ !Session
  , fsRig ∷ !Rig
  , fsWindows ∷ !WF.Fake
  , fsModel ∷ !Model
  , fsProvider ∷ !(WindowProvider Int)
  , fsOut ∷ !(TVar [Text])
  -- ^ What the roles printed, oldest first.
  , fsGate ∷ !(MVar ())
  -- ^ Held by the output sink's first line when the example asked for it: the authored output parks the role's @init@.
  }

-- | How an example shapes the session.
data Shape = Shape
  { shapeEntry ∷ !ByteString
  , shapeBoth ∷ !Bool
  , shapeParkOutput ∷ !Bool
  , shapeWindow ∷ !WF.FakeConfig
  , shapeTexture ∷ !Fake.FakeConfig
  , shapeProfile ∷ !Profile
  , shapeCreateScript ∷ ![CreateOutcome]
  -- ^ What the window fake's creations answer, in order, set before the session starts.
  , shapeHooks ∷ !PublishHooks
  }

defaultShape ∷ ByteString → Shape
defaultShape entry = Shape entry True False WF.defaultFakeConfig Fake.defaultFakeConfig compositionProfile [] noPublishHooks

-- | The fixed M1 profile with these counts changed, so that a bank is full after a few requests.
profileWith ∷ [(CountLimit, Word64)] → Profile
profileWith changes = either (error . ("the profile was refused: " <>) . show) id (validateProfile edited)
  where
    base = profileSpec compositionProfile
    edited = base {specCounts = \limit → maybe (specCounts base limit) Count (lookup limit changes)}

spec ∷ Spec
spec = describe "graphics facade" $ do
  it "runs the common-entry quad example through the production injection, taking each request once and publishing then releasing" $ do
    outcome ← runFacade (defaultShape quadExample) $ \fs → do
      awaitPublished fs 1
      void (adoptNow (fsModel fs) firstWindow)
      scene ← latestScene (fsModel fs) firstWindow >>= maybe (assertFailure "no scene was published") pure
      expectQuad scene
      -- The scene is accepted and adopted, and Lua released its texture right after publishing it: the adopted scene
      -- keeps the image registered, and the release has not run.
      releasedCount fs `shouldReturn` 0
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outQuit outcome `shouldBe` True
    outRetired outcome `shouldBe` True
    outFailures outcome `shouldBe` []

  it "completes the example when the texture completes before the window" $ do
    outcome ← runFacade ((defaultShape quadExample) {shapeWindow = WF.defaultFakeConfig {WF.fcHolds = [WF.HoldAdmit]}}) $ \fs → do
      Fake.awaitEvent (rigFake (fsRig fs)) "upload completed 0"
      WF.release (fsWindows fs) WF.HoldAdmit
      awaitPublished fs 1
      void (adoptNow (fsModel fs) firstWindow)
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "completes the example when the window completes before the texture" $ do
    outcome ← runFacade ((defaultShape quadExample) {shapeTexture = Fake.defaultFakeConfig {Fake.fcInitialHolds = [Fake.HoldUploadFinish]}}) $ \fs → do
      WF.awaitFake (fsWindows fs) ((>= 1) . WF.readingAttached)
      Fake.release (rigFake (fsRig fs)) Fake.HoldUploadFinish
      awaitPublished fs 1
      void (adoptNow (fsModel fs) firstWindow)
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "latches an unread clean window-creation refusal as required_request at the request stage, from a real session role" $ do
    outcome ← runFacade ((defaultShape unreadOpen) {shapeBoth = False, shapeCreateScript = [CreateRefusedClean "the display refused the window"]}) $ \fs →
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [RequiredRequest]
    map rfStage (outFailures outcome) `shouldBe` [OnRequest]

  it "latches a caught clean window-creation refusal the same way: the role, parked in its authored output, takes the exact window_error record after the refusal settled, catches the error it raises over it, and the instance still fails" $ do
    outcome ←
      runFacade
        ( (defaultShape caughtOpen)
            { shapeBoth = False
            , shapeParkOutput = True
            , shapeWindow = WF.defaultFakeConfig {WF.fcHolds = [WF.HoldCreate]}
            , shapeCreateScript = [CreateRefusedClean "the display refused the window"]
            }
        )
        $ \fs → do
          -- The role is parked in its authored output with the creation command held: let the refusal settle while the
          -- invocation is still running, wait for the provider to have answered and retired it, and resume that segment.
          WF.awaitEvent (fsWindows fs) "issue create"
          WF.release (fsWindows fs) WF.HoldCreate
          atomically (providerReading (fsProvider fs) >>= \found → unless (readingAcquisitions found == 0) retry)
          void (tryPutMVar (fsGate fs) ())
          -- The acknowledgement is the role's own print after it took and caught: the whole record, no root or path.
          awaitLine fs "caught\tfalse\twindow_error\ttrue\ttrue\tthe display refused the window"
          atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [RequiredRequest]
    map rfStage (outFailures outcome) `shouldBe` [OnRequest]

  it "routes a genuine native close with the startup gate closed to the session's stop, which Lua cannot veto" $ do
    outcome ← runFacade ((defaultShape parkedOpen) {shapeBoth = False, shapeParkOutput = True}) $ \fs → do
      -- The role's init is parked in its authored output, so the startup gate is closed; its window is pending.
      WF.awaitFake (fsWindows fs) ((>= 1) . WF.readingAttached)
      WF.nativeClose (fsWindows fs) 1
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (outQuit found) retry)
      void (tryPutMVar (fsGate fs) ())
    outQuit outcome `shouldBe` True
    outFailures outcome `shouldBe` []
    outRetired outcome `shouldBe` True

  it "refuses a publication a stop overtakes between its check and its commit, whole, and keeps the previous scene" $ do
    entered ← newEmptyMVar
    proceed ← newEmptyMVar
    calls ← newIORef (0 ∷ Int)
    let hooks =
          noPublishHooks
            { hookBeforeCommit = do
                -- The first publication passes; the second is held with its authority checked and every pin taken.
                n ← atomicModifyIORef' calls (\held → (held + 1, held + 1))
                if n >= 2 then putMVar entered () >> readMVar proceed else pure ()
            }
    outcome ← runFacade ((defaultShape publishRace) {shapeBoth = False, shapeHooks = hooks}) $ \fs → do
      awaitLine fs "first"
      void (adoptNow (fsModel fs) firstWindow)
      previous ← latestScene (fsModel fs) firstWindow
      -- The second publication is inside its commit's seam: the stop is requested now, and only then let go.
      takeMVar entered
      requestStop (fsSession fs) StopQuit
      putMVar proceed ()
      awaitLine fs "second\tfalse\ttrue"
      publishedRevision (fsModel fs) firstWindow `shouldReturn` 1
      latestScene (fsModel fs) firstWindow `shouldReturn` previous
      fmap graphicsContent previous `shouldSatisfy` maybe False (\content -> length (sceneSprites content) == 1)
    outVerdict outcome `shouldBe` VerdictSuccess
    outQuit outcome `shouldBe` True
    outFailures outcome `shouldBe` []

  it "answers busy from a full texture bank while the window, whose own slot is free, is accepted, starts no native work for the refused request, and accepts the explicit retry after actual reclamation" $ do
    outcome ← runFacade ((defaultShape textureBank) {shapeBoth = False, shapeProfile = profileWith [(TextureLeasesPerUiInstance, 2)]}) $ \fs → do
      awaitLine fs "banks\ttrue\tbusy\ttrue\ttrue"
      awaitLine fs "retry\ttrue\ttrue"
      -- Three requests ever reached the native owner: the two accepted and the retry; the refused one started nothing.
      Fake.awaitEvent (rigFake (fsRig fs)) "allocated 2 "
      allocated ← length . filter (Text.isPrefixOf "allocated ") <$> Fake.events (rigFake (fsRig fs))
      allocated `shouldBe` 3
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "answers busy from the common request places for a window request whose own slot is free, with no native window made, and accepts the explicit retry once a place is returned" $ do
    outcome ← runFacade ((defaultShape requestBank) {shapeBoth = False, shapeProfile = profileWith [(RequestsPerInstance, 2)]}) $ \fs → do
      awaitLine fs "window\ttrue\tbusy"
      WF.events (fsWindows fs) >>= (`shouldBe` [])
      awaitLine fs "retried\ttrue"
      WF.awaitEvent (fsWindows fs) "issue create"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "ends an instance whose init failed after starting both requests, with the window and the texture retired and the failure preserved" $ do
    outcome ← runFacade ((defaultShape failedInit) {shapeBoth = False}) $ \fs →
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [LuaError]
    map rfStage (outFailures outcome) `shouldBe` [OnInit]
    outRetired outcome `shouldBe` True

  it "retires a window and a texture when the role's shutdown raises, keeping that failure" $ do
    outcome ← runFacade ((defaultShape throwingShutdown) {shapeBoth = False}) $ \fs → do
      awaitLine fs "ready"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [LuaError]
    map rfStage (outFailures outcome) `shouldBe` [OnShutdown]
    outRetired outcome `shouldBe` True

  it "settles requests the script cancelled in the segment that started them, and retires what the providers had begun" $ do
    outcome ← runFacade ((defaultShape cancelAtOnce) {shapeBoth = False}) $ \fs → do
      awaitLine fs "cancel\tcancelled\tcancelled"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "refuses a second window request of an instance as an ordinary error, caught, with the first window unharmed" $ do
    outcome ← runFacade ((defaultShape secondWindow) {shapeBoth = False}) $ \fs → do
      awaitLine fs "second\tfalse\ttrue"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "answers a repeated texture release retiring and then already_released, without repeating the cleanup" $ do
    outcome ← runFacade ((defaultShape repeatedRelease) {shapeBoth = False, shapeTexture = Fake.defaultFakeConfig {Fake.fcInitialHolds = [Fake.HoldReclaim]}}) $ \fs → do
      awaitLine fs "release\tretiring"
      releasedCount fs >>= (`shouldSatisfy` (<= 1))
      Fake.release (rigFake (fsRig fs)) Fake.HoldReclaim
      awaitLine fs "release\talready_released"
      releasedCount fs `shouldReturn` 1
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "refuses new acquisition after quit in the same segment while quit stays idempotent, and the session still ends as a quit" $ do
    outcome ← runFacade ((defaultShape afterQuit) {shapeBoth = False}) $ \fs → awaitLine fs "after\tfalse\tfalse\ttrue\ttrue"
    outVerdict outcome `shouldBe` VerdictSuccess
    outQuit outcome `shouldBe` True
    outFailures outcome `shouldBe` []

  it "delivers an optional missing texture as structured data with its root and path, and leaves the instance healthy" $ do
    outcome ← runFacade ((defaultShape missingOptional) {shapeBoth = False}) $ \fs → do
      awaitLine fs "missing\tfailure\tnot_found\tgraphics-test\tnope.png\ttrue"
      requestStop (fsSession fs) StopQuit
    outVerdict outcome `shouldBe` VerdictSuccess
    outFailures outcome `shouldBe` []

  it "latches a required missing texture as required_request even though the script never polls it" $ do
    outcome ← runFacade ((defaultShape missingRequired) {shapeBoth = False}) $ \fs →
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [RequiredRequest]

-- | How many native releases of a table handle the texture owner ran.
releasedCount ∷ FS → IO Int
releasedCount fs = length . filter (Text.isPrefixOf "released ") <$> Fake.events (rigFake (fsRig fs))

-- | Block until the roles printed exactly this line.
awaitLine ∷ FS → Text → IO ()
awaitLine fs wanted = atomically $ do
  seen ← readTVar (fsOut fs)
  unless (wanted `elem` seen) retry

-- | The quad example's published scene, exactly: the sprite's rectangle, the texture it names (the one decoded from the
-- fixture, 2 by 2) and the clear colour the sRGB bytes (24, 24, 24) convert to.
expectQuad ∷ GraphicsScene → Expectation
expectQuad scene = do
  sceneClear content `shouldSatisfy` isClear 24 24 24
  case sceneSprites content of
    [sprite] → do
      spriteRect sprite `shouldBe` SceneRect 32 32 256 256
      let view = useView (spriteTexture sprite)
      (viewWidth view, viewHeight view) `shouldBe` (2, 2)
      graphicsReferences scene `shouldBe` Set.singleton (viewIdentity view)
    other → expectationFailure ("expected one sprite, found " <> show (length other))
  where
    content = graphicsContent scene

-- | The host model's key of the session's first window (the provider issues even tokens).
firstWindow ∷ Int
firstWindow = 2

awaitPublished ∷ FS → Word64 → IO ()
awaitPublished fs revision = awaitRevision (fsModel fs) firstWindow (fromIntegral revision)

-- | Run the real session on this thread, and a scenario on another that is handed the session as soon as it exists. If the
-- scenario raises it stops the session, and the exception is raised here once the session has ended and the scenario's
-- thread has terminated: a failed assertion in it is never swallowed.
runFacade ∷ Shape → (FS → IO ()) → IO SessionOutcome
runFacade shape scenario = bounded . withRig (shapeTexture shape) $ \rig → do
  let fake = rigFake rig
  model ← newModel (fakeLedger fake)
  setBarrier fake (modelCapture model)
  forM_ [1 .. 8] (modelWindow model)
  windows ← WF.newFake (shapeWindow shape)
  unless (null (shapeCreateScript shape)) (WF.scriptCreate windows (shapeCreateScript shape))
  textures ← newTextures
  sessionRef ← newIORef (Nothing ∷ Maybe Session)
  let config =
        WindowConfig
          { windowRecords = 2
          , windowStop = readIORef sessionRef >>= mapM_ (\found → requestStop found StopQuit)
          , windowFatal = \failure →
              readIORef sessionRef >>= mapM_ (\found → void (latchTerminalFailure found (newRoleFailure HostFailure OnEngine Presentation (fatalText failure))))
          }
      files =
        [ ("hetoimasia.json", manifestFor (shapeBoth shape))
        , ("lua/main.lua", shapeEntry shape)
        , ("images/quad.png", Png.solid 2 2 (200, 100, 50, 255))
        ]
  withComposition (shapeProfile shape) files (rigPort rig) $ \composition control runtime →
    withWindowProvider config (retarget (WF.fakePort windows)) $ \provider →
      ( do
          let publisher = scenePublisherOver textures provider (\window scene → fst (modelTarget model window) scene) (\window → snd (modelTarget model window))
              injection = graphicsInjection (GraphicsFacade (shapeProfile shape) (cpPipeline composition) provider publisher (shapeHooks shape))
          checkpoint ← bootCheckpoint (shapeProfile shape) (cpInventory composition) (\_ _ → pure (Right (manifestFor (shapeBoth shape)))) >>= either (\refused → assertFailure ("boot refused: " <> show refused)) pure
          outLines ← newTVarIO []
          errLines ← newTVarIO []
          gate ← newEmptyMVar
          firstLine ← newIORef True
          let outSink =
                OutputSink
                  { sinkLine = \line → do
                      atomically (modifyTVar' outLines (<> [line]))
                      first ← readIORef firstLine
                      writeIORef firstLine False
                      if first && shapeParkOutput shape then readMVar gate else pure ()
                  , sinkFlush = pure ()
                  }
              errSink = OutputSink {sinkLine = \line → atomically (modifyTVar' errLines (<> [line])), sinkFlush = pure ()}
          withOutput outSink errSink $ \output → do
            handle ← newEmptyMVar
            result ← newEmptyMVar
            terminated ← newEmptyMVar
            mainLoop ← forkIO (forever (mainStep provider))
            _ ← forkIO $
              ( do
                  found ← readMVar handle
                  writeIORef sessionRef (Just found)
                  let fs = FS found rig windows model provider outLines gate
                  attempted ←
                    try @SomeException $
                      timeout 8000000 (scenario fs) >>= \case
                        Just () → pure ()
                        Nothing → do
                          status ← atomically (sessionStatus found)
                          seen ← Fake.events (rigFake rig)
                          windowEvents ← WF.events windows
                          printed ← readTVarIO outLines
                          warned ← readTVarIO errLines
                          assertFailure ("the scenario did not finish: " <> show status <> "\ntexture: " <> show seen <> "\nwindows: " <> show windowEvents <> "\nout: " <> show printed <> "\nerr: " <> show warned)
                  case attempted of
                    Left _ → requestStop found StopQuit
                    Right () → pure ()
                  -- Every adoption the host model holds is released, so that the texture an adopted scene retained can
                  -- retire and the roles with it: the host's ledger is the model's.
                  dissolve model
                  putMVar result attempted
              )
                `finally` putMVar terminated ()
            let sessionSpec =
                  SessionSpec
                    { sxProfile = shapeProfile shape
                    , sxCheckpoint = checkpoint
                    , sxInventory = cpInventory composition
                    , sxPool = cpPool composition
                    , sxLogger = quietLogger
                    , sxOutput = output
                    , sxClock = monotonicSource
                    , sxTimer = systemTimerBackend
                    , sxRuntime = runtime
                    , sxControl = control
                    , sxHarness = noHarness
                    , sxGraphics = Just injection
                    }
            outcome ←
              runSession sessionSpec (putMVar handle)
                `finally` (void (tryPutMVar gate ()) >> WF.releaseAll windows >> killThread mainLoop)
            takeMVar terminated
            takeMVar result >>= either throwIO (const (pure outcome))
      )
        `finally` (WF.releaseAll windows >> dissolve model >> endWindows provider)

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- | One turn of the owner loop's main-thread step, once the provider has something for the main thread.
mainStep ∷ WindowProvider Int → IO ()
mainStep provider = do
  atomically (windowMainReady provider >>= \ready → unless ready retry)
  windowMainStep provider

-- | The window fake's port, yielding the window's token number as its capability.
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

presentationOnly ∷ [Text] → ByteString
presentationOnly body =
  Text.encodeUtf8 . Text.unlines $
    ["return {", "  presentation = {", "    every_seconds=0.02,"] <> body <> ["  }", "}"]

-- | A window requested in init and never read.
unreadOpen ∷ ByteString
unreadOpen =
  presentationOnly
    [ "    init=function(self, api) self.request = api.window.open({title=\"t\", width=640, height=480}) end,"
    , "    update=function(self, dt) end"
    ]

-- | A window whose failure the role takes and then raises an error over, which it catches. The role parks in its
-- authored output first, so that the refusal settles while the invocation runs.
caughtOpen ∷ ByteString
caughtOpen =
  presentationOnly
    [ "    init=function(self, api)"
    , "      local request = api.window.open({title=\"t\", width=640, height=480})"
    , "      print(\"parked\")"
    , "      assert(api.request.ready(request), 'the refusal had settled')"
    , "      local result = api.request.take(request)"
    , "      local ok = pcall(function()"
    , "        assert(result.status == 'failure' and result.error.code == 'window_error')"
    , "        error(result.error.message)"
    , "      end)"
    , "      print('caught', ok, result.error.code, result.error.root == nil, result.error.path == nil, result.error.message)"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | A window requested in init, which then parks in its authored output: the startup gate stays closed.
parkedOpen ∷ ByteString
parkedOpen =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.request = api.window.open({title=\"t\", width=640, height=480})"
    , "      print(\"parked\")"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | A second window request while the first is pending: an ordinary error a script catches.
secondWindow ∷ ByteString
secondWindow =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.first = api.window.open({title='a', width=64, height=64})"
    , "      local ok, err = pcall(api.window.open, {title='b', width=64, height=64})"
    , "      print('second', ok, tostring(err):find('already has a window') ~= nil)"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

-- | A texture taken and released on every update: the answer changes as the retirement proceeds.
repeatedRelease ∷ ByteString
repeatedRelease =
  presentationOnly
    [ "    init=function(self, api) self.t = api.content.texture('images/quad.png') end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if not self.tex then"
    , "        if not api.request.ready(self.t) then return end"
    , "        self.tex = api.request.take(self.t).value.texture"
    , "      end"
    , "      local answer = api.texture.release(self.tex)"
    , "      if answer ~= self.last then self.last = answer print('release', answer) end"
    , "    end"
    ]

-- | Quit, then statements in the same segment: acquisition is refused as ordinary errors, a second quit changes nothing.
afterQuit ∷ ByteString
afterQuit =
  presentationOnly
    [ "    init=function(self, api) end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.done then return end"
    , "      self.done = true"
    , "      api.session.quit()"
    , "      api.session.quit()"
    , "      local ok1, e1 = pcall(api.content.texture, 'images/quad.png')"
    , "      local ok2, e2 = pcall(api.window.open, {title='t', width=1, height=1})"
    , "      print('after', ok1, ok2, tostring(e1):find('stopping') ~= nil, tostring(e2):find('stopping') ~= nil)"
    , "    end"
    ]

-- | An optional texture the content does not hold: its failure is data.
missingOptional ∷ ByteString
missingOptional =
  presentationOnly
    [ "    init=function(self, api) self.t = api.content.texture('nope.png', {optional = true}) end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.done or not api.request.ready(self.t) then return end"
    , "      self.done = true"
    , "      local r = api.request.take(self.t)"
    , "      print('missing', r.status, r.error.code, r.error.root, r.error.path, r.value == nil)"
    , "    end"
    ]

-- | A required texture the content does not hold, which the script never reads.
missingRequired ∷ ByteString
missingRequired =
  presentationOnly
    [ "    init=function(self, api) self.t = api.content.texture('nope.png') end,"
    , "    update=function(self, dt) end"
    ]

-- | Two publications; the second is the one a stop overtakes.
publishRace ∷ ByteString
publishRace =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if not self.win and api.request.ready(self.w) then self.win = api.request.take(self.w).value end"
    , "      if not self.img and api.request.ready(self.t) then self.img = api.request.take(self.t).value end"
    , "      if not (self.win and self.img) then return end"
    , "      if not self.a then"
    , "        self.a = true"
    , "        api.scene.publish(self.win, {clear={r=24,g=24,b=24}, sprites={{texture=self.img.texture, x=1, y=2, width=3, height=4}}})"
    , "        print('first')"
    , "        return"
    , "      end"
    , "      if not self.b then"
    , "        self.b = true"
    , "        local ok, err = pcall(api.scene.publish, self.win, {clear={r=1,g=2,b=3}, sprites={}})"
    , "        print('second', ok, tostring(err):find('scene publication is stopped') ~= nil)"
    , "      end"
    , "    end"
    ]

-- | A profile of two texture slots: the third request finds the bank full while a window is accepted.
textureBank ∷ ByteString
textureBank =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.t1 = api.content.texture('images/quad.png')"
    , "      self.t2 = api.content.texture('images/quad.png')"
    , "      local t3, e = api.content.texture('images/quad.png')"
    , "      local w, we = api.window.open({title='w', width=64, height=64})"
    , "      print('banks', t3 == nil, e and e.code, w ~= nil, we == nil)"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.retried then return end"
    , "      if not self.tex then"
    , "        if not api.request.ready(self.t1) then return end"
    , "        self.tex = api.request.take(self.t1).value.texture"
    , "      end"
    , "      -- Release until the retirement is proven: only then is the slot back."
    , "      if api.texture.release(self.tex) == 'already_released' then"
    , "        self.retried = true"
    , "        local t4, e4 = api.content.texture('images/quad.png')"
    , "        print('retry', t4 ~= nil, e4 == nil)"
    , "      end"
    , "    end"
    ]

-- | A profile of two request places: two texture requests fill them and the window finds no place, its own slot free.
requestBank ∷ ByteString
requestBank =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.t1 = api.content.texture('images/quad.png')"
    , "      self.t2 = api.content.texture('images/quad.png')"
    , "      local w, e = api.window.open({title='w', width=64, height=64})"
    , "      print('window', w == nil, e and e.code)"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.retried then return end"
    , "      if self.t1 then"
    , "        if not api.request.ready(self.t1) then return end"
    , "        api.request.take(self.t1)"
    , "        self.t1 = nil"
    , "      end"
    , "      local w, e = api.window.open({title='w', width=64, height=64})"
    , "      if w then self.retried = true print('retried', true) end"
    , "    end"
    ]

failedInit ∷ ByteString
failedInit =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "      error('init fails after both requests')"
    , "    end,"
    , "    update=function(self, dt) end"
    ]

throwingShutdown ∷ ByteString
throwingShutdown =
  presentationOnly
    [ "    init=function(self, api)"
    , "      self.w = api.window.open({title='t', width=64, height=64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.said or not (api.request.ready(self.w) and api.request.ready(self.t)) then return end"
    , "      self.said = true"
    , "      print('ready')"
    , "    end,"
    , "    shutdown=function(self, reason) error('shutdown fails') end"
    ]

cancelAtOnce ∷ ByteString
cancelAtOnce =
  presentationOnly
    [ "    init=function(self, api)"
    , "      local w = api.window.open({title='t', width=64, height=64})"
    , "      local t = api.content.texture('images/quad.png')"
    , "      print('cancel', api.request.cancel(w), api.request.cancel(t))"
    , "    end,"
    , "    update=function(self, dt) end"
    ]
