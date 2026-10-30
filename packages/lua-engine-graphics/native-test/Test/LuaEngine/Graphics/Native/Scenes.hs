-- | Scene retention on a real device (LFE-20): the production host, the production window port, the production
-- texture backend and the real scene lifecycle, with real windows, real uploads and real frames.
--
-- What these examples add to the controlled lifecycle suite's matrix is the other side of the seams: that the
-- real host adopts the scene the adapter published, that the texture stays protected and is recorded again later
-- Lua released it, that a publication naming the released lease is refused, and that replacing the scene is what
-- lets the texture retire, on the table's own evidence and not before the frames that used it completed. Two
-- instances share the host, and ending one leaves the other's scene adopted and recorded.
--
-- /No pixel is captured or read back/ and none is claimed: the order of the host's own frame events (a frame
-- recorded with the revision, submitted, completed) and the scene state it publishes (the adopted revision, what
-- awaits release) is the evidence. Offscreen pixel proof is LFE-24's and visible output qualification LFE-25's.
--
-- The windows open on whatever the run's consent selected, and every example ends with its windows destroyed.
module Test.LuaEngine.Graphics.Native.Scenes (spec) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Monad (unless)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent (..)
  , VulkanHost (..)
  , VulkanSceneState (..)
  , WindowSceneStanding (..)
  , readVulkanSceneState
  )
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Graphics.Window.Host (WindowTarget (..), newHostPort)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), windowMainStep)
import Hetoimasia.Runtime.GLFW (attachmentWindow, hostWindowClient, hostWindowIdentities)
import Numeric.Natural (Natural)
import System.Timeout (timeout)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.FrameLog (eventsSince, frameLogMark)
import Test.LuaEngine.Graphics.Native.Session
import Test.LuaEngine.Graphics.SceneComp

-- | The window capability the production port yields.
type Target = WindowTarget GraphicsScene

spec ∷ Env → Spec
spec env = describe "scene retention" $ do
  it "adopts a published scene, keeps its texture protected and recorded after Lua released it, refuses a publication naming the released lease, and retires it only after the scene is replaced" $
    within 180 . withScenes env $ \comp vm _ → do
      admitScene comp vm "a"
      window ← openWindow env comp vm "a"
      loadTexture comp vm "a" "a" "a.png"
      earlier ← frameLogMark <$> readTVarIO (envFrames env)
      _ ← run comp vm "a" "publish" "a" (Just "a")
      -- The real owner adopts the published revision and records a frame with it.
      awaitAdopted env window 1
      awaitFrame env window 1 earlier
      released ← run comp vm "a" "release" "a" Nothing
      released `shouldSatisfy` Text.isInfixOf "retiring"
      awaitHeld env
      -- A frame recorded after the release, with the same adopted scene: the texture was still drawable.
      mark ← frameLogMark <$> readTVarIO (envFrames env)
      demandFrame env window
      awaitFrame env window 1 mark
      expectHeld env
      -- A new publication naming the released lease is refused as an ordinary error and changes nothing.
      refused ← run comp vm "a" "ppublish" "a" (Just "a")
      refused `shouldSatisfy` Text.isInfixOf "error"
      published env window >>= (`shouldBe` Just 1)
      -- Replaced by an empty scene: once the frames that used revision 1 completed, the texture retires.
      replaced ← frameLogMark <$> readTVarIO (envFrames env)
      _ ← run comp vm "a" "publish" "a" Nothing
      awaitAdopted env window 2
      awaitFrame env window 2 replaced
      atomically (graphicsReading (envGraphics env) >>= \reading → unless (readingLiveTextures reading == 0) retry)
      atomically (readVulkanSceneState (envHost env) >>= \state → unless (all (null . windowAwaitingRelease) (Map.elems (sceneWindows state))) retry)
      held ← atomically (ledgerReading (graphicsLedger (envGraphics env)))
      readingHeld held `shouldSatisfy` null
      readingDefects held `shouldBe` 0
      evidence env "scene retention: the adopted revision 1 was recorded after the Lua release (texture held), the publication naming the released lease was refused, and replacement by an empty revision 2 let the texture retire after the frames of revision 1 completed"
      stopScene comp vm "a"
      awaitWindowCount env 0

  it "keeps the texture of a scene released straight after it was published, before the owner adopted it: adopted, recorded, refused for a new publication, retired only after replacement" $
    within 180 . withScenes env $ \comp vm _ → do
      admitScene comp vm "a"
      window ← openWindow env comp vm "a"
      loadTexture comp vm "a" "a" "a.png"
      earlier ← frameLogMark <$> readTVarIO (envFrames env)
      -- One command, no wait between: the scene is accepted and the lease released before any adoption or frame.
      released ← run comp vm "a" "prelease" "a" (Just "a")
      released `shouldSatisfy` Text.isInfixOf "retiring"
      -- The release waited behind the host's barrier for the accepted revision; the owner then adopts it and records
      -- it with the texture still alive.
      awaitAdopted env window 1
      awaitFrame env window 1 earlier
      awaitHeld env
      expectHeld env
      held ← atomically (ledgerReading (graphicsLedger (envGraphics env)))
      length (readingHeld held) `shouldBe` 1
      -- A new publication naming the released lease is refused and changes nothing.
      refused ← run comp vm "a" "ppublish" "a" (Just "a")
      refused `shouldSatisfy` Text.isInfixOf "error"
      published env window >>= (`shouldBe` Just 1)
      -- Replaced by an empty scene: once the frames that used revision 1 completed, the texture retires.
      replaced ← frameLogMark <$> readTVarIO (envFrames env)
      _ ← run comp vm "a" "publish" "a" Nothing
      awaitAdopted env window 2
      awaitFrame env window 2 replaced
      atomically (graphicsReading (envGraphics env) >>= \reading → unless (readingLiveTextures reading == 0) retry)
      atomically (readVulkanSceneState (envHost env) >>= \state → unless (all (null . windowAwaitingRelease) (Map.elems (sceneWindows state))) retry)
      remaining ← atomically (ledgerReading (graphicsLedger (envGraphics env)))
      readingHeld remaining `shouldSatisfy` null
      readingDefects remaining `shouldBe` 0
      evidence env "a scene released straight after publication, before adoption: the owner adopted revision 1 and recorded it with the texture alive, a publication naming the released lease was refused, and the texture retired only after replacement and the frames of revision 1 completed"
      stopScene comp vm "a"
      awaitWindowCount env 0

  it "ends one instance with its scene outstanding and leaves its peer's scene adopted, retained and recorded, with no session stop" $
    within 180 . withScenes env $ \comp vm stops → do
      admitScene comp vm "a"
      admitScene comp vm "b"
      first ← openWindow env comp vm "a"
      second ← openWindow env comp vm "b"
      loadTexture comp vm "a" "a" "a.png"
      loadTexture comp vm "b" "a" "b.png"
      _ ← run comp vm "a" "publish" "a" (Just "a")
      _ ← run comp vm "b" "publish" "a" (Just "a,a")
      awaitAdopted env first 1
      awaitAdopted env second 1
      noteWindows env 2
      -- The first instance ends while its scene is adopted: its window and texture retire, protected, and only then.
      stopScene comp vm "a"
      awaitWindowCount env 1
      atomically (graphicsReading (envGraphics env) >>= \reading → unless (readingLiveTextures reading == 1) retry)
      -- The peer's scene is still adopted, still holds its texture, and is recorded again.
      published env second >>= (`shouldBe` Just 1)
      held ← atomically (ledgerReading (graphicsLedger (envGraphics env)))
      length (readingHeld held) `shouldBe` 1
      mark ← frameLogMark <$> readTVarIO (envFrames env)
      demandFrame env second
      awaitFrame env second 1 mark
      atomically (readTVar stops) >>= (`shouldBe` (0 ∷ Int))
      readingDefects held `shouldBe` 0
      evidence env "two instances on one host: the first ended with its scene adopted and its window and texture retired; the peer's revision stayed adopted, its texture held, and a frame was recorded with it afterwards; no session stop was requested"
      stopScene comp vm "b"
      awaitWindowCount env 0

  it "publishes the largest legal scene, 4,096 sprites of one texture, and the real renderer records it" $
    within 180 . withScenes env $ \comp vm _ → do
      admitScene comp vm "a"
      window ← openWindow env comp vm "a"
      loadTexture comp vm "a" "a" "a.png"
      earlier ← frameLogMark <$> readTVarIO (envFrames env)
      _ ← run comp vm "a" "publish" "a" (Just (Text.intercalate "," (replicate 4096 "a")))
      awaitAdopted env window 1
      awaitFrame env window 1 earlier
      held ← atomically (ledgerReading (graphicsLedger (envGraphics env)))
      -- One hold for the one texture, however many sprites name it.
      length (readingHeld held) `shouldBe` 1
      evidence env "the largest legal scene (4,096 sprites naming one texture) was adopted and a frame was recorded with it through the configured ring"
      stopScene comp vm "a"
      awaitWindowCount env 0

-- | The session: the production window port and texture backend inside a scene composition, with the main thread
-- serving the provider's handovers.
withScenes ∷ Env → (SceneComp Target → SceneVm Target → TVar Int → IO a) → IO a
withScenes env body = do
  stops ← newTVarIO 0
  (port, _) ← newHostPort (envHost env)
  provider ← newIORef (Nothing ∷ Maybe (IO ()))
  let kit =
        SceneKit
          { kitPort = port
          , kitTextures = graphicsTextures (envGraphics env)
          , kitPublish = targetAnswer
          , kitUsable = targetUsable
          }
      config = WindowConfig 2 (atomically (modifyTVar' stops (+ 1))) (\_ → pure ())
      files = [("a.png", Png.solid 2 2 (200, 100, 50, 255)), ("b.png", Png.solid 2 2 (20, 100, 250, 255))]
  serveMain env (readIORef provider >>= maybe (pure ()) id) $
    withSceneComp kit config files (graphicsBackend (envGraphics env)) $ \comp _ runtime → do
      writeIORef provider (Just (windowMainStep (scProvider comp)))
      vm ← startSceneVm comp runtime "native-scene-vm"
      body comp vm stops

-- | Open a window for the instance, taken, and answer its identity.
openWindow ∷ Env → SceneComp Target → SceneVm Target → Text → IO WindowId
openWindow env comp vm name = do
  earlier ← atomically (hostWindowIdentities (vulkanWindowHost (envHost env)))
  _ ← run comp vm name "open" "a" Nothing
  later ← atomically (hostWindowIdentities (vulkanWindowHost (envHost env)))
  case filter (`notElem` earlier) later of
    [window] → pure window
    other → assertFailure ("expected one new window, found " <> show (length other))

loadTexture ∷ SceneComp Target → SceneVm Target → Text → Text → Text → IO ()
loadTexture comp vm name key path = do
  line ← run comp vm name "load" key (Just path)
  line `shouldSatisfy` Text.isInfixOf "loaded"

-- | Tell the instance to do this, and wait for the first note it records for that command since.
run ∷ SceneComp Target → SceneVm Target → Text → Text → Text → Maybe Text → IO Text
run comp vm name op key described = do
  let prefix = name <> " " <> op <> " " <> key <> " "
  seen ← length . filter (Text.isPrefixOf prefix) <$> sceneNotes comp
  command comp vm name op key described
  timeout (60 * 1000000) (awaitSceneNoteCount comp prefix (seen + 1)) >>= \case
    Just () → pure ()
    Nothing → do
      recorded ← sceneNotes comp
      failure ← timeout (5 * 1000000) (awaitSceneFailure comp name)
      assertFailure ("no note for " <> Text.unpack prefix <> " within 60 seconds; the scripts recorded " <> show recorded <> "; the instance " <> maybe "had not settled" (maybe "did not fail" (drop 560 . take 1800 . show)) failure)
  noted ← filter (Text.isPrefixOf prefix) <$> sceneNotes comp
  pure (noted !! seen)

-- | Block until the owner's scene state says a live target of this window has adopted at least this revision.
awaitAdopted ∷ Env → WindowId → Natural → IO ()
awaitAdopted env window revision = atomically $ do
  state ← readVulkanSceneState (envHost env)
  case Map.lookup window (sceneWindows state) >>= windowAdopted of
    Just adopted | adopted >= revision → pure ()
    _ → retry

-- | The latest revision published for the window.
published ∷ Env → WindowId → IO (Maybe Natural)
published env window = do
  state ← atomically (readVulkanSceneState (envHost env))
  pure (Map.lookup window (sceneWindows state) >>= windowPublished)

-- | Block until a frame was asked to be presented for this window with this revision after the first @mark@
-- events: a frame the owner recorded and submitted with that scene.
awaitFrame ∷ Env → WindowId → Natural → Int → IO ()
awaitFrame env window revision mark = atomically $ do
  fresh ← eventsSince mark <$> readTVar (envFrames env)
  unless (or [attachmentWindow attachment == window && rendered == revision | FramePresentRequested attachment _ _ rendered ← fresh]) retry

-- | Ask the window's target for another frame of what it holds.
demandFrame ∷ Env → WindowId → IO ()
demandFrame env window =
  atomically (hostWindowClient (vulkanWindowHost (envHost env)) window) >>= \case
    Nothing → assertFailure "the window has no client to publish demand to"
    Just client → () <$ publishDemand (clientDemandPublisher client) immediateDemand

-- | The backend holds exactly one texture back from retirement, and it holds it by the ledger: its stage is @held@.
-- Retention is asserted by the stage and not by a count of live textures, because a texture the table is still
-- finishing with after an unprotected release would pass a count at the instant it was sampled. On a mismatch the
-- example fails naming where every unretired texture stands, what the ledger holds and what the host's scene state says.
expectHeld ∷ Env → IO ()
expectHeld env = do
  reading ← atomically (graphicsReading (envGraphics env))
  unless (readingTextureStages reading == ["held"]) (retentionFailure env reading)

-- | Wait until the released texture's release has been asked and refused for the hold (its stage is @held@). The wait
-- ends early, and fails, when every texture has already retired: the owner let it go while its scene was adopted.
awaitHeld ∷ Env → IO ()
awaitHeld env = do
  settled ← atomically $ do
    reading ← graphicsReading (envGraphics env)
    case readingTextureStages reading of
      ["held"] → pure Nothing
      [] → pure (Just reading)
      _ → retry
  mapM_ (retentionFailure env) settled

retentionFailure ∷ Env → BackendReading → IO ()
retentionFailure env reading = do
  ledger ← atomically (ledgerReading (graphicsLedger (envGraphics env)))
  state ← atomically (readVulkanSceneState (envHost env))
  assertFailure
    ( "expected the released texture to be held by the adopted scene; stages " <> show (readingTextureStages reading)
        <> "; ledger " <> show ledger
        <> "; scene state " <> show (Map.elems (sceneWindows state))
    )

awaitWindowCount ∷ Env → Int → IO ()
awaitWindowCount env wanted = atomically $ do
  windows ← hostWindowIdentities (vulkanWindowHost (envHost env))
  unless (length windows == wanted) retry

evidence ∷ Env → Text → IO ()
evidence env line = atomically (modifyTVar' (envEvidence env) (line :))

within ∷ Int → IO a → IO a
within seconds action =
  timeout (seconds * 1000000) action >>= \case
    Just value → pure value
    Nothing → assertFailure ("the example did not finish within " <> show seconds <> " seconds")

