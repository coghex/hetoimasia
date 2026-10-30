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
module Test.LuaEngine.Graphics.Native.Facade (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith)
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Vulkan.GLFW (VulkanHost (..))
import Hetoimasia.LuaEngine.Boot (bootCheckpoint)
import Hetoimasia.LuaEngine.Facade (OutputSink (..), withOutput)
import Hetoimasia.LuaEngine.Graphics.Facade (GraphicsFacade (..), graphicsInjection)
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Graphics.Window.Host (newHostPort)
import Hetoimasia.LuaEngine.Graphics.Window.Port (fatalText)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), windowMainStep, withWindowProvider)
import Hetoimasia.LuaEngine.Manifest (Role (Presentation))
import Hetoimasia.LuaEngine.Session
import Hetoimasia.Runtime.GLFW (hostWindowIdentities)
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition (Composition (..), compositionProfile, withComposition)
import Test.LuaEngine.Graphics.FacadeScripts (failingLogicalExample, manifestFor, quadExample)
import Test.LuaEngine.Graphics.FrameLog (frameLogMark)
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.Native.Scenes hiding (spec)
import Test.LuaEngine.Graphics.Native.Session (Env (..), serveMain)

spec ∷ Env → Spec
spec env = describe "graphics facade" $ do
  it "runs the common-entry quad example from real Lua: the accepted scene is adopted, its texture stays held and recorded after Lua's immediate release, recording needs no further publish, and the texture retires after the window closes" $
    within 180 . withFacadeSession env quadExample $ \_ window → do
      earlier ← frameLogMark <$> readTVarIO (envFrames env)
      awaitAdopted env window 1
      awaitFrame env window 1 earlier
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
    within 180 . withFacadeSession env failingLogicalExample $ \errLines window → do
      awaitAdopted env window 1
      published env window >>= (`shouldBe` Just 1)
      atomically (readTVar errLines >>= \seen → unless (any (Text.isInfixOf "logical failure") seen) retry)
      -- The scene holds no texture: it is the empty red clear.
      held ← atomically (ledgerReading (graphicsLedger (envGraphics env)))
      readingHeld held `shouldSatisfy` null
      evidence env "graphics facade: the logical update raised after startup; the UI warned with the failure message and published the empty red-clear scene (revision 1), which the owner adopted holding no texture"

-- | Run the entry as the roles of a real session over the production host, hand the scenario the lines the roles
-- warned and the identity of the one native window the example opens, and end the session by a normal stop once the
-- scenario returned. The scenario's failures are raised here after the session has ended.
withFacadeSession ∷ Env → ByteString → (TVar [Text] → WindowId → IO ()) → IO ()
withFacadeSession env entry scenario = do
  earlier ← atomically (hostWindowIdentities (vulkanWindowHost (envHost env)))
  (port, _) ← newHostPort (envHost env)
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
        let publisher = scenePublisher (graphicsTextures (envGraphics env)) provider
            injection = graphicsInjection (GraphicsFacade compositionProfile (cpPipeline composition) provider publisher)
        checkpoint ← bootCheckpoint compositionProfile (cpInventory composition) (\_ _ → pure (Right (manifestFor True))) >>= either (\refused → assertFailure ("boot refused: " <> show refused)) pure
        errLines ← newTVarIO []
        let outSink = OutputSink {sinkLine = \_ → pure (), sinkFlush = pure ()}
            errSink = OutputSink {sinkLine = \line → atomically (modifyTVar' errLines (<> [line])), sinkFlush = pure ()}
        withOutput outSink errSink $ \output → do
          handle ← newEmptyMVar
          result ← newEmptyMVar
          terminated ← newEmptyMVar
          _ ← forkIO $
            ( do
                found ← readMVar handle
                writeIORef sessionRef (Just found)
                attempted ← try @SomeException $ do
                  window ← awaitNewWindow earlier
                  scenario errLines window
                -- However the scenario ended, the session stops normally.
                requestStop found StopQuit
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
          outcome ← runSession sessionSpec (putMVar handle)
          takeMVar terminated
          takeMVar result >>= either throwIO pure
          outVerdict outcome `shouldBe` VerdictSuccess
          outFailures outcome `shouldBe` []
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
