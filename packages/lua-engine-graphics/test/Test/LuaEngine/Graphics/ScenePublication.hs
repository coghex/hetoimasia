-- | Publishing a scene (LFE-20) through the real Lua composition: real instances in a real supervised owner, the real
-- request admission and leases, the real texture pipeline and window provider, and the library's publication
-- binding, installed under this suite's own name (LFE-21 installs the facade's later).
--
-- Injected, and it says so: the texture owner (the fake owner), the windows (the window fake) and the host's answer
-- to a publication and its ledger (the scene host model). The evidence is the publication boundary's ordering, its
-- refusals and its ownership, never a frame.
module Test.LuaEngine.Graphics.ScenePublication (spec) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO)
import Control.Exception (finally)
import Control.Monad (forM_)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Scene (SceneContent (..), SceneRect (..), SceneSprite (..))
import Hetoimasia.LuaEngine.Graphics.Window.Port (Port (..), WindowToken (..))
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), endWindows)
import Hetoimasia.Render.TwoD.Vulkan.Textures (newTextures)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Fake (fakeLedger, setBarrier)
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.Rig (Rig (..), withRig)
import qualified Test.LuaEngine.Graphics.Fake as Fake
import Test.LuaEngine.Graphics.SceneComp
import Test.LuaEngine.Graphics.SceneHost
import qualified Test.LuaEngine.Graphics.Window.Fake as WF

-- | Everything an example needs.
data Pub = Pub
  { pubComp ∷ SceneComp Int
  , pubVm ∷ SceneVm Int
  , pubModel ∷ Model
  , pubRig ∷ Rig
  }

spec ∷ Spec
spec = describe "scene publication" $ do
  it "publishes the caller's ready window one complete value naming its live ready textures, once each" $
    withPublication $ \pub → do
      ready pub "a"
      loaded pub "a" "a" "a.png"
      _ ← run pub "a" "publish" "a" (Just "a,a")
      publishedRevision (pubModel pub) winA `shouldReturn` 1
      scene ← latest pub winA
      length (sceneSprites (graphicsContent scene)) `shouldBe` 2
      Set.size (graphicsReferences scene) `shouldBe` 1
      map (rectX . spriteRect) (sceneSprites (graphicsContent scene)) `shouldBe` [0, 4]

  it "refuses an invalid scene whole as an ordinary error, keeps the previous one, and goes on to the next valid publication" $
    withPublication $ \pub → do
      ready pub "a"
      loaded pub "a" "a" "a.png"
      _ ← run pub "a" "publish" "a" (Just "a")
      previous ← latest pub winA
      forM_ ["extra", "hole", "many", "meta", "nan"] $ \bad → do
        line ← run pub "a" "pbad" "a" (Just bad)
        line `shouldSatisfy` Text.isInfixOf "error"
        publishedRevision (pubModel pub) winA `shouldReturn` 1
        latest pub winA `shouldReturn` previous
      -- A caught refusal leaves the instance healthy, and the next valid publication works.
      _ ← run pub "a" "publish" "a" (Just "a,a")
      publishedRevision (pubModel pub) winA `shouldReturn` 2

  it "refuses a released texture, keeps the old scene, and does not make the handle usable again" $
    withPublication $ \pub → do
      ready pub "a"
      loaded pub "a" "a" "a.png"
      loaded pub "a" "b" "b.png"
      _ ← run pub "a" "publish" "a" (Just "a,b")
      _ ← run pub "a" "release" "b" Nothing
      line ← run pub "a" "ppublish" "a" (Just "a,b")
      line `shouldSatisfy` Text.isInfixOf "error"
      publishedRevision (pubModel pub) winA `shouldReturn` 1
      -- The accepted scene still names both textures.
      scene ← latest pub winA
      Set.size (graphicsReferences scene) `shouldBe` 2
      again ← run pub "a" "ppublish" "a" (Just "a")
      again `shouldSatisfy` Text.isInfixOf "published"
      publishedRevision (pubModel pub) winA `shouldReturn` 2

  it "refuses a peer's texture and a peer's window, even in one VM" $
    withPublication $ \pub → do
      ready pub "a"
      ready pub "c"
      loaded pub "a" "a" "a.png"
      loaded pub "c" "a" "a.png"
      _ ← run pub "a" "share" "a" Nothing
      -- c's window with a's texture, and a's window with c's texture.
      foreignTexture ← run pub "c" "pforeign_texture" "a" Nothing
      foreignTexture `shouldSatisfy` Text.isInfixOf "error"
      foreignWindow ← run pub "c" "pforeign_window" "a" (Just "a")
      foreignWindow `shouldSatisfy` Text.isInfixOf "error"
      forM_ [winA, winC] $ \window → publishedRevision (pubModel pub) window `shouldReturn` 0

  it "copies the scene it is given: later edits to the source tables change nothing" $
    withPublication $ \pub → do
      ready pub "a"
      loaded pub "a" "a" "a.png"
      _ ← run pub "a" "mutate" "a" (Just "a")
      scene ← latest pub winA
      length (sceneSprites (graphicsContent scene)) `shouldBe` 1
      map (rectX . spriteRect) (sceneSprites (graphicsContent scene)) `shouldBe` [0]

  it "refuses a window that is not the admitted incarnation, and a stopped provider, as ordinary errors" $
    withPublication $ \pub → do
      ready pub "a"
      loaded pub "a" "a" "a.png"
      setUsable (pubModel pub) winA False
      notReady ← run pub "a" "ppublish" "a" (Just "a")
      notReady `shouldSatisfy` Text.isInfixOf "not ready"
      publishedRevision (pubModel pub) winA `shouldReturn` 0
      setUsable (pubModel pub) winA True
      _ ← run pub "a" "publish" "a" (Just "a")
      publishedRevision (pubModel pub) winA `shouldReturn` 1
      endWindows (scProvider (pubComp pub))
      stopped ← run pub "a" "ppublish" "a" (Just "a")
      stopped `shouldSatisfy` Text.isInfixOf "stopped"
      publishedRevision (pubModel pub) winA `shouldReturn` 1

  describe "a fact that changes while the publication is in flight" $ do
    it "leaves the previous scene when the window stops being the admitted one before the boundary is checked" $
      withPublication $ \pub → do
        ready pub "a"
        loaded pub "a" "a" "a.png"
        armGate (pubVm pub) "before-boundary"
        held ← runHeld pub "a" "publish" "a" (Just "a")
        awaitGate (pubVm pub) "before-boundary"
        setUsable (pubModel pub) winA False
        openGate (pubVm pub) "before-boundary"
        _ ← held
        publishedRevision (pubModel pub) winA `shouldReturn` 0

    it "leaves the previous scene when the host closes after the final check and before the commit" $
      withPublication $ \pub → do
        ready pub "a"
        loaded pub "a" "a" "a.png"
        armGate (pubVm pub) "before-commit"
        held ← runHeld pub "a" "publish" "a" (Just "a")
        awaitGate (pubVm pub) "before-commit"
        closeHost (pubModel pub)
        openGate (pubVm pub) "before-commit"
        _ ← held
        publishedRevision (pubModel pub) winA `shouldReturn` 0

    it "keeps an accepted scene when the provider stops, or the instance is asked to end, after the commit" $
      withPublication $ \pub → do
        ready pub "a"
        loaded pub "a" "a" "a.png"
        armGate (pubVm pub) "after-commit"
        held ← runHeld pub "a" "publish" "a" (Just "a")
        awaitGate (pubVm pub) "after-commit"
        endWindows (scProvider (pubComp pub))
        stopScene (pubComp pub) (pubVm pub) "a"
        openGate (pubVm pub) "after-commit"
        _ ← held
        -- The scene is the window's, owned by the host from the commit, whatever came after it.
        publishedRevision (pubModel pub) winA `shouldReturn` 1
        scene ← latest pub winA
        Set.size (graphicsReferences scene) `shouldBe` 1

  it "keeps a released texture drawable after adoption, and retires it once the scene is replaced and its use is over" $
    withPublication $ \pub → do
      ready pub "a"
      loaded pub "a" "a" "a.png"
      _ ← run pub "a" "publish" "a" (Just "a")
      scene ← latest pub winA
      identity ← case Set.toList (graphicsReferences scene) of
        [found] → pure found
        other → assertFailure ("expected one texture, found " <> show other)
      released ← run pub "a" "release" "a" Nothing
      released `shouldSatisfy` Text.isInfixOf "retiring"
      -- Adopted after the release: the scene still names the texture and the ledger protects it.
      adoptNow (pubModel pub) winA `shouldReturn` Adopted 1
      heldNow pub identity `shouldReturn` True
      beginUse (pubModel pub) winA 1 1
      _ ← run pub "a" "publish" "a" Nothing
      adoptNow (pubModel pub) winA `shouldReturn` Adopted 2
      releasePass (pubModel pub) `shouldReturn` []
      heldNow pub identity `shouldReturn` True
      endUse (pubModel pub) winA 1 1
      releasePass (pubModel pub) `shouldReturn` [(winA, 1)]
      heldNow pub identity `shouldReturn` False

-- | The model's window numbers of the first and the second window the fake makes: it numbers its creation requests
-- and its windows from one counter, so the first window is its second token and the second window its fourth.
winA, winC ∷ Int
winA = 2
winC = 4

-- Harness -------------------------------------------------------------------------------------------------

-- | Run an example over the composition. However it ends the host's windows are dissolved, so the texture
-- backend's drain, which waits for every texture a scene holds to retire, is not left waiting for a scene that
-- nobody will release.
withPublication ∷ (Pub → IO a) → IO a
withPublication body =
  withRig Fake.defaultFakeConfig $ \rig → do
    let fake = rigFake rig
    model ← newModel (fakeLedger fake)
    setBarrier fake (modelCapture model)
    forM_ [1 .. 8] (modelWindow model)
    windows ← WF.newFake WF.defaultFakeConfig
    textures ← newTextures
    stops ← newTVarIO (0 ∷ Int)
    let config = WindowConfig 2 (atomically (modifyTVar' stops (+ 1))) (\_ → pure ())
        kit =
          SceneKit
            { kitPort = retarget (WF.fakePort windows)
            , kitTextures = textures
            , kitPublish = \window scene → fst (modelTarget model window) scene
            , kitUsable = \window → snd (modelTarget model window)
            }
        files = [("a.png", Png.solid 2 2 (200, 100, 50, 255)), ("b.png", Png.solid 2 2 (20, 100, 250, 255))]
    withSceneComp kit config files (rigPort rig) $ \comp _ runtime → do
      vm ← startSceneVm comp runtime "scene-vm"
      body (Pub comp vm model rig)
        `finally` (openAllGates vm >> WF.releaseAll windows >> dissolve model >> endWindows (scProvider comp))

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

-- | An instance of this name with a window, open and taken.
ready ∷ Pub → Text → IO ()
ready pub name = do
  admitScene (pubComp pub) (pubVm pub) name
  say pub name "open" "a" Nothing
  mainStepNow (pubComp pub)
  _ ← awaitSceneNote (pubComp pub) (name <> " open a opened")
  pure ()

-- | A texture of this file, loaded and taken by the instance under this key.
loaded ∷ Pub → Text → Text → Text → IO ()
loaded pub name key path = do
  say pub name "load" key (Just path)
  _ ← awaitSceneNote (pubComp pub) (name <> " load " <> key <> " loaded")
  pure ()

say ∷ Pub → Text → Text → Text → Maybe Text → IO ()
say pub name op key described = command (pubComp pub) (pubVm pub) name op key described

-- | Tell the instance to do this, and wait for the note it records for that command: the first one this command
-- has recorded since it was told.
run ∷ Pub → Text → Text → Text → Maybe Text → IO Text
run pub name op key described = runHeld pub name op key described >>= id

-- | The same, answering the wait instead of doing it: for an invocation an example holds at a gate.
runHeld ∷ Pub → Text → Text → Text → Maybe Text → IO (IO Text)
runHeld pub name op key described = do
  let prefix = name <> " " <> op <> " " <> key <> " "
  seen ← length . filter (Text.isPrefixOf prefix) <$> sceneNotes (pubComp pub)
  say pub name op key described
  pure $ do
    awaitSceneNoteCount (pubComp pub) prefix (seen + 1)
    noted ← filter (Text.isPrefixOf prefix) <$> sceneNotes (pubComp pub)
    pure (noted !! seen)

heldNow ∷ Pub → Word64 → IO Bool
heldNow pub identity = atomically (ledgerHeld (fakeLedger (rigFake (pubRig pub))) identity)

latest ∷ Pub → Int → IO GraphicsScene
latest pub window = latestScene (pubModel pub) window >>= maybe (assertFailure "no scene was published") pure

