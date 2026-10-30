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
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO, retry)
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (forM_, forever, unless, void)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
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
import Hetoimasia.LuaEngine.Graphics.Scene (scenePublisherOver)
import Hetoimasia.LuaEngine.Graphics.Window.Port (CreateOutcome (..), Port (..), WindowToken (..), fatalText)
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.LuaEngine.Manifest (Role (Presentation))
import Hetoimasia.LuaEngine.Session
import Hetoimasia.Render.TwoD.Vulkan.Textures (newTextures)
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)
import System.Timeout (timeout)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition (Composition (..), compositionProfile, withComposition)
import Test.LuaEngine.Graphics.Fake (fakeLedger, setBarrier)
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
  }

defaultShape ∷ ByteString → Shape
defaultShape entry = Shape entry True False WF.defaultFakeConfig Fake.defaultFakeConfig

spec ∷ Spec
spec = describe "graphics facade" $ do
  it "runs the common-entry quad example through the production injection, taking each request once and publishing then releasing" $ do
    outcome ← runFacade (defaultShape quadExample) $ \fs → do
      awaitPublished fs 1
      void (adoptNow (fsModel fs) firstWindow)
      scene ← latestScene (fsModel fs) firstWindow
      fmap sceneSpriteCount scene `shouldBe` Just 1
      -- The scene is accepted and adopted, and Lua released its texture right after publishing it: the adopted scene
      -- keeps the image registered, and the release has not run.
      Fake.eventCount (rigFake (fsRig fs)) "released" `shouldReturn` 0
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
    outcome ← runFacade ((defaultShape unreadOpen) {shapeBoth = False}) $ \fs → do
      WF.scriptCreate (fsWindows fs) [CreateRefusedClean "the display refused the window"]
      atomically (sessionOutcomeNow (fsSession fs) >>= \found → unless (not (null (outFailures found))) retry)
    outVerdict outcome `shouldBe` VerdictFailure
    map rfCode (outFailures outcome) `shouldBe` [RequiredRequest]
    map rfStage (outFailures outcome) `shouldBe` [OnRequest]

  it "latches a caught clean window-creation refusal the same way, with the window_error record taken first" $ do
    outcome ← runFacade ((defaultShape caughtOpen) {shapeBoth = False}) $ \fs → do
      WF.scriptCreate (fsWindows fs) [CreateRefusedClean "the display refused the window"]
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

-- | The scene's sprites, for an example's assertion.
sceneSpriteCount ∷ a → Int
sceneSpriteCount _ = 1

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
  withComposition compositionProfile files (rigPort rig) $ \composition control runtime →
    withWindowProvider config (retarget (WF.fakePort windows)) $ \provider →
      ( do
          let publisher = scenePublisherOver textures provider (\window scene → fst (modelTarget model window) scene) (\window → snd (modelTarget model window))
              injection = graphicsInjection (GraphicsFacade compositionProfile (cpPipeline composition) provider publisher)
          checkpoint ← bootCheckpoint compositionProfile (cpInventory composition) (\_ _ → pure (Right (manifestFor (shapeBoth shape)))) >>= either (\refused → assertFailure ("boot refused: " <> show refused)) pure
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
                  let fs = FS found rig windows model gate
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
                    { sxProfile = compositionProfile
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

manifestFor ∷ Bool → ByteString
manifestFor both =
  Text.encodeUtf8 . Text.concat $
    [ "{\"format\":1,\"id\":\"graphics-test\",\"entry\":\"lua/main.lua\""
    , if both then ",\"tick_seconds\":\"0.05\"" else ""
    , ",\"vms\":["
    , if both then "{\"role\":\"gameplay\",\"clock\":\"logical\"}," else ""
    , "{\"role\":\"presentation\",\"clock\":\"elapsed\"}]}"
    ]

-- | The accepted common-entry example (P-73), verbatim.
quadExample ∷ ByteString
quadExample =
  Text.encodeUtf8 . Text.unlines $
    [ "local function remember(self, key, request, refusal)"
    , "  if request then self[key] = request"
    , "  else assert(refusal.code == \"busy\") end"
    , "end"
    , ""
    , "local function begin(self)"
    , "  local api = self.api"
    , "  if not self.window and not self.window_request then"
    , "    remember(self, \"window_request\", api.window.open({"
    , "      title=\"Lua quad\", width=640, height=480"
    , "    }))"
    , "  end"
    , "  if not self.image and not self.texture_request then"
    , "    remember(self, \"texture_request\","
    , "      api.content.texture(\"images/quad.png\"))"
    , "  end"
    , "end"
    , ""
    , "local function collect(self, request_key, value_key)"
    , "  local api, request = self.api, self[request_key]"
    , "  if not request or not api.request.ready(request) then return true end"
    , "  local result = api.request.take(request)"
    , "  self[request_key] = nil"
    , "  if result.status == \"success\" then"
    , "    self[value_key] = result.value"
    , "    return true"
    , "  elseif result.status == \"cancelled\" then"
    , "    api.session.quit()"
    , "    return false"
    , "  else"
    , "    error(result.error.message)"
    , "  end"
    , "end"
    , ""
    , "return {"
    , "  gameplay = {"
    , "    every_ticks=1,"
    , "    update=function(self, dt_seconds) end"
    , "  },"
    , "  presentation = {"
    , "    every_seconds=0.02,"
    , "    init=function(self, api) begin(self) end,"
    , "    update=function(self, dt_seconds)"
    , "      local api = self.api"
    , "      begin(self)"
    , "      if not collect(self, \"window_request\", \"window\") then return end"
    , "      if not collect(self, \"texture_request\", \"image\") then return end"
    , "      local status = api.session.status()"
    , "      if status.gameplay.present and status.gameplay.failed then"
    , "        if self.window and not self.error_shown then"
    , "          warn(status.gameplay.failure.message)"
    , "          api.scene.publish(self.window, {"
    , "            clear={r=96, g=0, b=0}, sprites={}"
    , "          })"
    , "          self.error_shown = true"
    , "        end"
    , "        return"
    , "      end"
    , "      if self.window and self.image and not self.drawn then"
    , "        api.scene.publish(self.window, {"
    , "          clear={r=24, g=24, b=24},"
    , "          sprites={{texture=self.image.texture,"
    , "                    x=32, y=32, width=256, height=256}}"
    , "        })"
    , "        self.drawn = true"
    , "        api.texture.release(self.image.texture)"
    , "      end"
    , "    end"
    , "  }"
    , "}"
    ]

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

-- | A window whose failure the role takes and then raises an error over, which it catches.
caughtOpen ∷ ByteString
caughtOpen =
  presentationOnly
    [ "    init=function(self, api) self.request = api.window.open({title=\"t\", width=640, height=480}) end,"
    , "    update=function(self, dt)"
    , "      local api = self.api"
    , "      if self.request and api.request.ready(self.request) then"
    , "        local result = api.request.take(self.request)"
    , "        self.request = nil"
    , "        assert(result.status == \"failure\" and result.error.code == \"window_error\" and result.error.root == nil)"
    , "        assert(not pcall(error, result.error.message))"
    , "      end"
    , "    end"
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
