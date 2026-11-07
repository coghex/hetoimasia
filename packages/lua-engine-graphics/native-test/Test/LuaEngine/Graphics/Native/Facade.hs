{-# LANGUAGE OverloadedStrings #-}

-- | The graphics facade on a real device (LFE-21): the accepted common-entry quad example, as ordinary Lua in the
-- roles of a real @runSession@, through the production injection ('graphicsInjection'), a real verified PNG read and
-- decoded by the pipeline, a GPU-ready texture, a ready native window and the scene publication, all on the
-- production host.
--
-- /No pixel is captured or read back/ and none is claimed (offscreen pixel proof is LFE-24's, visible output
-- qualification LFE-25's). The evidence is what the R2D-8 and scene-retention examples use: the order of the host's own
-- frame events and its scene state (the revision published, the revision adopted) and the backend's reading of the
-- texture's stage and the ledger's holds. It shows that the accepted scene is adopted; that its texture stays held and
-- is recorded again after Lua's immediate release; that recording continues with no further publication from Lua; and that
-- the texture retires only once the window has closed and the frames that used it completed. A second example raises in the
-- logical update after startup and shows the UI's failure status and its empty red-clear scene published and adopted
-- through the same bindings. Both end through the session's quit path.
module Test.LuaEngine.Graphics.Native.Facade (spec, cancelProbe, latchProbe) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Concurrent (throwTo)
import Control.Exception (AsyncException (UserInterrupt), SomeException, throwIO, try)
import Control.Monad (unless, void, when)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith, unsafeComponent)
import Hetoimasia.Foundation.Worker (awaitCompletion, workerDefinition)
import Hetoimasia.Runtime.Supervision (Recognition (Unrecognized), SupervisedStart (WorkerStarted), WorkerPolicy (..), startSupervised, supervisedWorker)
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.GLFW.Command (clientInputControl, clientInputReader)
import qualified Hetoimasia.GLFW.Input as Glfw
import Hetoimasia.GLFW.Window (WindowId)
import qualified Data.Map.Strict as Map
import Hetoimasia.GPU.Vulkan.GLFW (VulkanHost (..), VulkanSceneState (..), readVulkanSceneState)
import System.Timeout (timeout)
import Hetoimasia.LuaEngine.Boot (bootCheckpoint)
import Hetoimasia.LuaEngine.Facade (OutputSink (..), withOutput)
import Hetoimasia.LuaEngine.Graphics.Facade (GraphicsFacade (..), defaultIssuedMemory, graphicsInjection)
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Graphics.Input (glfwInputHost)
import Hetoimasia.LuaEngine.Graphics.Window.Host (HostPorts (..), newHostPorts, targetUsable)
import Hetoimasia.LuaEngine.Graphics.Window.Port (fatalText)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), windowMainStep, withWindowProvider)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.LuaEngine.Manifest (Role (Gameplay, Presentation))
import Hetoimasia.LuaEngine.Scene (SceneContent (..), SceneRect (..), SceneSprite (..), TextureUse (..))
import Hetoimasia.LuaEngine.Texture (TextureView (..))
import Numeric.Natural (Natural)
import Hetoimasia.LuaEngine.Session
import Hetoimasia.Runtime.GLFW (hostWindowClient, hostWindowIdentities)
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition (Composition (..), compositionProfile, withComposition)
import Test.LuaEngine.Graphics.FacadeScripts (failingLogicalExample, isClear, manifestFor, quadExample)
import Test.LuaEngine.Graphics.FrameLog (frameLogMark)
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.Native.Scenes hiding (spec)
import Test.LuaEngine.Graphics.Native.Session (Env (..), noteWindows, serveMain)
import Test.Support.Owned (withOwnedThread)

spec ∷ Env → Spec
spec env = describe "graphics facade" $ do
  it "runs the common-entry quad example from real Lua: the accepted scene is adopted, its texture stays held and recorded after Lua's immediate release, recording needs no further publish, and the texture retires after the window closes" $
    within 180 . withFacadeSession env quadExample succeeded $ \_ accepted window → do
      earlier ← frameLogMark <$> readTVarIO (envFrames env)
      awaitAdopted env window 1
      awaitFrame env window 1 earlier
      -- The scene the host accepted is exactly the example's: one sprite of the decoded texture and the clear colour.
      atomically (readTVar accepted) >>= \seen → case seen of
        [scene] → case sceneSprites (graphicsContent scene) of
          [sprite] → do
            spriteRect sprite `shouldBe` SceneRect 32 32 256 256
            (viewWidth (useView (spriteTexture sprite)), viewHeight (useView (spriteTexture sprite))) `shouldBe` (8, 4)
            sceneClear (graphicsContent scene) `shouldSatisfy` isClear 24 24 24
          other → expectationFailure ("expected one sprite, found " <> show (length other))
        other → expectationFailure ("expected one accepted publication, found " <> show (length other))
      -- Lua released the texture right after publishing: the adopted scene keeps it, held by the ledger.
      awaitHeld env
      expectHeld env
      -- Recording continues from the adopted scene alone: another frame with the same revision, and Lua published
      -- nothing more.
      mark ← frameLogMark <$> readTVarIO (envFrames env)
      demandFrame env window
      awaitFrame env window 1 mark
      published env window >>= (`shouldBe` Just 1)
      expectHeld env
      evidence env "graphics facade: the example's scene (revision 1) was adopted, recorded again after the immediate Lua release with its texture held by the ledger, and no second publication was made while recording continued"

  it "shows a logical update that raises after startup as the UI's failure status, and its exact empty red-clear scene published and adopted through the same bindings" $
    within 180 . withFacadeSession env failingLogicalExample logicalFailed $ \errLines accepted window → do
      started ← frameLogMark <$> readTVarIO (envFrames env)
      -- The UI warns with the failure's message and publishes the empty red clear once it reads the failure in its status:
      -- a scene it may have drawn first is superseded by it.
      step env "the UI's warning" $ atomically (readTVar errLines >>= \seen → unless (any (Text.isInfixOf "logical failure") seen) retry)
      -- The scene the host accepted last is the exact empty red clear; its revision is the number of accepted publications
      -- (a window's initial scene is revision 0 and is no publication). A scene the UI may have drawn first is superseded.
      revision ← step env "the red clear accepted" . atomically $ do
        seen ← readTVar accepted
        case reverse seen of
          scene : _
            | null (sceneSprites (graphicsContent scene))
            , isClear 96 0 0 (sceneClear (graphicsContent scene))
            , null (graphicsReferences scene) → pure (fromIntegral (length seen) ∷ Natural)
          _ → retry
      revision `shouldSatisfy` (>= 1)
      step env "the adoption of the red clear" $ awaitAdopted env window revision
      step env "a frame recorded with the red clear" $ awaitFrame env window revision started
      step env "the end of every hold" $ atomically (ledgerReading (graphicsLedger (envGraphics env)) >>= \held → unless (null (readingHeld held)) retry)
      published env window >>= (`shouldBe` Just revision)
      evidence env ("graphics facade: the logical update raised after startup; the UI warned with the failure message and published the empty red-clear scene (revision " <> Text.pack (show revision) <> "), which the owner adopted and recorded holding no texture")

  it "polls a real window's feed through the production host: the first poll enables admission, the public suspension is a reset the script acknowledges, an acknowledged feed is paused, and the instance's end strands nothing" $
    within 180 . withFacadeSessionWith True env inputExample succeeded $ \errLines _ window → do
      client ← atomically (hostWindowClient (vulkanWindowHost (envHost env)) window) >>= maybe (assertFailure "the window has no client") pure
      let reader = clientInputReader client
          control = clientInputControl client
          -- a wait that names itself, with what the script has warned so far, when it does not end
          warned wanted =
            timeout (40 * 1000000) (atomically (readTVar errLines >>= \seen → unless (any (Text.isInfixOf wanted) seen) retry)) >>= \case
              Just () → pure ()
              Nothing → readTVarIO errLines >>= \seen → assertFailure ("no line containing " <> show wanted <> " within 40 seconds; the script warned " <> show seen)
      -- the adapter's consumer opened admission at the script's first poll, and nothing else did
      warned "input\trunning\t1\t"
      opened ← atomically (Glfw.inputStatistics reader)
      (Glfw.statisticsAdmission opened, Glfw.statisticsPhase opened) `shouldBe` (Glfw.InputEnabled, Glfw.InputRunning)
      -- the public suspension begins a reset of reason suspension, in the next epoch, that the script reads and acknowledges
      atomically (Glfw.suspendInput control) >>= \case
        Glfw.AdmissionReset token → (Glfw.resetReason token, Glfw.epochNumber (Glfw.resetEpoch token)) `shouldBe` (Glfw.AdmissionSuspended, 2)
        other → expectationFailure ("expected a suspension reset, found " <> show other)
      warned "reset\tsuspended\t2"
      warned "ack\tacknowledged"
      -- acknowledged is not resumed: the application's admission is suspended, and the script sees the feed paused
      warned "input\tpaused\t1\t"
      held ← atomically (Glfw.inputStatistics reader)
      (Glfw.statisticsPhase held, Glfw.statisticsAdmission held) `shouldBe` (Glfw.InputResetAcknowledged, Glfw.InputSuspended)
      seen ← readTVarIO errLines
      evidence env ("graphics facade: a real window's feed was polled from real Lua through the production host; the script's first poll enabled admission, the public suspension reset was read as reason suspended in epoch 2 and acknowledged, the feed stayed paused with admission suspended, and the instance's end then retired the window with the reset acknowledged but not resumed; the script reported " <> Text.intercalate " | " [Text.takeWhileEnd (/= ':') line | line ← seen, "input\t" `Text.isInfixOf` line])

-- | A presentation instance that polls its window's feed and reports each change of what it sees, and acknowledges the first
-- reset it is shown.
inputExample ∷ ByteString
inputExample =
  Text.encodeUtf8 . Text.unlines $
    [ "return {"
    , "  presentation = {"
    , "    every_seconds = 0.05,"
    , "    init = function(self, api)"
    , "      self.w = api.window.open({title = 'input', width = 64, height = 64})"
    , "    end,"
    , "    update = function(self, dt)"
    , "      local api = self.api"
    , "      if not self.win then"
    , "        if not api.request.ready(self.w) then return end"
    , "        self.win = api.request.take(self.w).value"
    , "        return"
    , "      end"
    , "      local p = api.input.poll(self.win, 8)"
    , "      local o = p.observation"
    , "      local sig = p.disposition .. ' ' .. tostring(p.exhausted)"
    , "      if sig ~= self.sig then"
    , "        self.sig = sig"
    , "        warn('input', p.disposition, p.epoch, tostring(p.exhausted), #p.events, math.type(o.revision), o.logical and (o.logical.width .. 'x' .. o.logical.height) or 'nil', o.framebuffer and (o.framebuffer.width .. 'x' .. o.framebuffer.height) or 'nil')"
    , "      end"
    , "      if p.disposition == 'reset_required' and not self.acked then"
    , "        self.acked = true"
    , "        warn('reset', p.reset.reason, p.reset.epoch)"
    , "        warn('ack', api.input.acknowledgeReset(self.win, p.reset.token))"
    , "      end"
    , "    end"
    , "  }"
    , "}"
    ]

-- | The cancellation probe (#599), run by @--probe-cancel-loop@ on its own and never as part of the profile: the quad example's
-- window is live and holds its texture, and the process main thread, which serves the owner loop, is cancelled right there. The
-- run must end by itself, with the window retired and the texture released through the loop served again, before the texture
-- backend's drain; a shutdown that waits for the window while the loop stays stopped never returns. The session's own
-- cancellation is the run's expected failure ('Main' judges the rest from the facts).
cancelProbe ∷ Env → Spec
cancelProbe env = describe "cancelling the owner loop while a window holds a texture" $
  it "is cancelled with the quad example's window live and its texture held" $
    within 180 . withFacadeSession env quadExample (\_ → pure ()) $ \_ _ window → do
      awaitAdopted env window 1
      awaitHeld env
      expectHeld env
      evidence env "cancellation probe: the main thread is cancelled while the quad example's window is live and its texture held"
      throwTo (envMain env) UserInterrupt
      -- the profile thread is killed by the settling run of the loop; this wait only keeps the scenario here until it is
      newEmptyMVar >>= takeMVar

-- | The same probe with the failure a latched supervision gives (#599), run by @--probe-latch-loop@: a required supervised worker
-- fails while the quad example's window is live and its texture held, so the application's supervision latches a fatal
-- failure and the owner loop, which checks its supervision before it serves anything, is left by it. Serving it again under the
-- same supervision would end at once and the window could never retire; the settling run makes a fresh supervision, as the
-- shipped owner drain does, and the run must end by itself.
latchProbe ∷ Env → Spec
latchProbe env = describe "leaving the owner loop by a latched supervision failure while a window holds a texture" $
  it "latches the supervision with the quad example's window live and its texture held" $
    within 180 . withFacadeSession env quadExample (\_ → pure ()) $ \_ _ window → do
      awaitAdopted env window 1
      awaitHeld env
      expectHeld env
      evidence env "latch probe: a required supervised worker fails while the quad example's window is live and its texture held"
      gate ← newEmptyMVar
      started ←
        startSupervised
          (envControl env)
          (WorkerPolicy Supervision.Service Supervision.Required (unsafeComponent "test.luaengine.graphics.native.latch") (\_ → pure Unrecognized))
          (workerDefinition "test.luaengine.graphics.native.latch" (\_ → pure ()) (\_ () → (readMVar gate >> ioError (userError "LatchingProbe") ∷ IO ())))
      handle ← case started of
        WorkerStarted found → pure found
        _ → assertFailure "the latching worker did not start"
      putMVar gate ()
      void (atomically (awaitCompletion (supervisedWorker handle)))
      -- the profile thread is killed by the settling run of the loop; this wait only keeps the scenario here until it is
      newEmptyMVar >>= takeMVar

succeeded ∷ SessionOutcome → Expectation
succeeded outcome = do
  outVerdict outcome `shouldBe` VerdictSuccess
  outFailures outcome `shouldBe` []

-- | The failing variant ends as a failure of the logical role alone: the presentation role went on to the end.
logicalFailed ∷ SessionOutcome → Expectation
logicalFailed outcome = do
  outVerdict outcome `shouldBe` VerdictFailure
  map rfRole (outFailures outcome) `shouldBe` [Gameplay]
  map rfCode (outFailures outcome) `shouldBe` [LuaError]

-- | A wait that names itself when it does not end.
step ∷ Env → String → IO a → IO a
step env label action =
  timeout (40 * 1000000) action >>= \case
    Just value → pure value
    Nothing → do
      held ← atomically (ledgerReading (graphicsLedger (envGraphics env)))
      state ← atomically (readVulkanSceneState (envHost env))
      assertFailure ("no " <> label <> " within 40 seconds; the ledger holds " <> show (readingHeld held) <> "; scene state " <> show (Map.elems (sceneWindows state)))

-- | Run the entry as the roles of a real session over the production host, hand the scenario the lines the roles
-- warned and the identity of the one native window the example opens, and end the session by a normal stop once the
-- scenario returned. The scenario's failures are raised here after the session has ended.
withFacadeSession ∷ Env → ByteString → (SessionOutcome → Expectation) → (TVar [Text] → TVar [GraphicsScene] → WindowId → IO ()) → IO ()
withFacadeSession = withFacadeSessionWith False

-- | The same, with the window integration's input injected from the production host when asked to (TRA-6).
withFacadeSessionWith ∷ Bool → Env → ByteString → (SessionOutcome → Expectation) → (TVar [Text] → TVar [GraphicsScene] → WindowId → IO ()) → IO ()
withFacadeSessionWith withInput env entry judge scenario = do
  earlier ← atomically (hostWindowIdentities (vulkanWindowHost (envHost env)))
  ports ← newHostPorts (envHost env)
  let port = hostPortsPort ports
  providerStep ← newIORef (pure ())
  sessionRef ← newIORef Nothing
  let config =
        WindowConfig
          { windowRecords = 2
          , windowStop = readIORef sessionRef >>= mapM_ (\found → requestStop found StopQuit)
          , windowFatal = \failure → readIORef sessionRef >>= mapM_ (\found → void (latchTerminalFailure found (newRoleFailure HostFailure OnEngine Presentation (fatalText failure))))
          }
      files =
        [ ("hetoimasia.json", manifestFor True)
        , ("lua/main.lua", entry)
        , ("images/quad.png", Png.asymmetric 8 4)
        ]
  serveMain env (readIORef providerStep >>= id) $
    withComposition compositionProfile files (graphicsBackend (envGraphics env)) $ \composition control runtime →
      withWindowProvider config port $ \provider → do
        writeIORef providerStep (windowMainStep provider)
        -- The publisher is the production one, over the production window capability; the only addition is a tap that
        -- records the exact scene of every publication the host accepted, in the transaction that accepts it.
        accepted ← newTVarIO []
        let tap target scene = do
              answer ← targetAnswer target scene
              when (answer == HostAccepted) (modifyTVar' accepted (<> [preparedValue scene]))
              pure answer
            publisher = scenePublisherOver (graphicsTextures (envGraphics env)) provider tap targetUsable
            injection = graphicsInjection (GraphicsFacade compositionProfile (cpPipeline composition) provider publisher noPublishHooks defaultIssuedMemory (if withInput then Just (glfwInputHost (hostPortsInput ports)) else Nothing))
        checkpoint ← bootCheckpoint compositionProfile (cpInventory composition) (\_ _ → pure (Right (manifestFor True))) >>= either (\refused → assertFailure ("boot refused: " <> show refused)) pure
        errLines ← newTVarIO []
        let outSink = OutputSink {sinkLine = \_ → pure (), sinkFlush = pure ()}
            errSink = OutputSink {sinkLine = \line → atomically (modifyTVar' errLines (<> [line])), sinkFlush = pure ()}
        withOutput outSink errSink $ \output → do
          handle ← newEmptyMVar
          result ← newEmptyMVar
          let scenarioAction = do
                found ← readMVar handle
                writeIORef sessionRef (Just found)
                attempted ← try @SomeException $ do
                  window ← awaitNewWindow earlier
                  noteWindows env 1
                  scenario errLines accepted window
                -- However the scenario ended, the session stops normally.
                requestStop found StopQuit
                putMVar result attempted
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
          -- The scenario's thread is owned by the call (#599): ended and joined however the session's run ends, a cancellation
          -- delivered before the scenario started included.
          outcome ←
            withOwnedThread scenarioAction $ \_ terminated → do
              ran ← runSession sessionSpec (putMVar handle)
              terminated
              takeMVar result >>= either throwIO pure
              pure ran
          judge outcome
          outRetired outcome `shouldBe` True
  -- Everything the session made is gone: the window is destroyed and the texture retired on the table's own evidence.
  awaitWindowCount env 0
  atomically (graphicsReading (envGraphics env) >>= \reading → unless (readingLiveTextures reading == 0) retry)
  where
    awaitNewWindow earlier = atomically $ do
      later ← hostWindowIdentities (vulkanWindowHost (envHost env))
      case filter (`notElem` earlier) later of
        [window] → pure window
        _ → retry

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }
