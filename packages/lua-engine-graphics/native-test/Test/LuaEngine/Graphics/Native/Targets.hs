-- | A surface-free offscreen scene target on a real device (LFE-27): the production host, the production texture
-- backend and its release lane, the real hold ledger and a managed offscreen colour target, with no window.
--
-- What this adds to the headless examples of "Test.GPU.Vulkan.GLFW.Targets" is the device's own evidence: that a
-- texture released through the production lane right after a target accepted a scene naming it, and before the
-- owner adopted that scene, is neither run nor failed until the owner has adopted it, stays valid for the
-- recording that reads it — drawn, read back and judged after the Lua release — and is freed only after that
-- recording has completed, with the diagnostic capture clean through the session's teardown.
--
-- The ordering that matters is established, not assumed. The example holds the graphics owner's thread inside an
-- owner-thread action on a gate it opens, so the owner cannot adopt while the scene is accepted and the release
-- is made; it then reads the host's own scene state — the revision published, the revision adopted, the release
-- request queued behind a barrier naming the target — before it lets the owner go. The lifecycle hooks never wait:
-- the gate is an action of the example's, and the hooks are the host's.
--
-- /No pixel is claimed beyond the one drawing's own judgement/: the oracle and the hand probes read the one
-- recording's readback. Pixel semantics for Lua-authored output are LFE-24's.
module Test.LuaEngine.Graphics.Native.Targets (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, check, modifyTVar', retry)
import Control.Monad (void)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GPU.Vulkan.GLFW
  ( OffscreenTargetId
  , Refusal (..)
  , SceneTargetKey (..)
  , TargetBatchRefusal (..)
  , TargetScenePublication (..)
  , VulkanAction (..)
  , VulkanHost (..)
  , VulkanSceneState (..)
  , WindowSceneStanding (..)
  , awaitVulkanAction
  , publishVulkanTargetScene
  , readVulkanSceneState
  , recordVulkanTargetBatch
  , registerVulkanSceneTarget
  , submitVulkanAction
  , unregisterVulkanSceneTarget
  )
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.Runtime.GLFW (hostWindowIdentities)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition
import Test.LuaEngine.Graphics.Native.Frame
import Test.LuaEngine.Graphics.Native.Session
import Test.LuaEngine.Graphics.Native.Spec (decoded', load, within, withLoaded)
import qualified Test.LuaEngine.Graphics.Png as Png

spec ∷ Env → Spec
spec env = describe "an offscreen scene target on a real device (LFE-27)" $
  it "keeps the texture of a scene released straight after the surface-free target accepted it, before the owner adopted it, valid for the recording that reads it, and frees it only after that recording completed, with no window" $
    within 120 . withLoaded env [("tiny.png", Png.asymmetric 8 4)] $ \comp vm → do
      let host = envHost env
          ledger = graphicsLedger (envGraphics env)
      identity ← load comp vm "a" "k" "tiny.png"
      decoded ← decoded' (Png.asymmetric 8 4)
      atomically (hostWindowIdentities (vulkanWindowHost host)) `shouldReturn` []
      target ← atomically (registerVulkanSceneTarget host) >>= either (\refusal → assertFailure ("the target was refused: " <> show refusal)) pure
      -- The owner adopts the initial scene as revision 0 on its own.
      awaitTarget host target ((== Just 0) . windowAdopted)
      -- Hold the owner inside an action, until the example lets it go.
      entered ← newEmptyMVar
      proceed ← newEmptyMVar
      gate ←
        atomically (submitVulkanAction host (VulkanAction (\_ → putMVar entered () >> takeMVar proceed)))
          >>= either (\refusal → assertFailure ("the holding action was refused: " <> show refusal)) pure
      takeMVar entered
      -- The target accepts a scene naming the texture, which the owner has not adopted.
      scene ← prepare (initialGraphicsScene {graphicsReferences = Set.singleton (fromIntegral identity)})
      accepted ← atomically (publishVulkanTargetScene host target scene)
      accepted `shouldBe` TargetScenePublished target 1
      held ← atomically (readVulkanSceneState host)
      (windowPublished <$> Map.lookup (KeyOffscreen target) (sceneWindows held), windowAdopted <$> Map.lookup (KeyOffscreen target) (sceneWindows held)) `shouldBe` (Just (Just 1), Just (Just 0))
      -- Released through the production lane right after acceptance: the request waits behind a barrier that names
      -- the target at the accepted revision, and the texture is still live.
      command comp vm "a" "release" "k"
      _ ← awaitNoteContaining comp "a release k"
      atomically $ do
        state ← readVulkanSceneState host
        check (any ((== Just 1) . Map.lookup (KeyOffscreen target)) (sceneRequests state))
      live ← atomically (graphicsReading (envGraphics env))
      readingLiveTextures live `shouldSatisfy` (> 0)
      -- The owner is let go: it adopts revision 1, which the ledger then holds the texture for.
      putMVar proceed ()
      void (atomically (awaitVulkanAction gate))
      awaitTarget host target ((== Just 1) . windowAdopted)
      atomically (ledgerReading ledger >>= \reading → check (not (Set.null (readingHeld reading))))
      -- A recording that reads that scene, made after the Lua release: the texture is drawn, read back and judged.
      -- The target's next scene is accepted before the recording's completion is awaited, so revision 1 is
      -- superseded while that recording may still be in flight, and what releases it is the recording's own ticket.
      empty ← prepare initialGraphicsScene
      shot ←
        shootWith
          host
          (recordBound host target)
          (void (atomically (publishVulkanTargetScene host target empty)))
          (graphicsRenderer (envGraphics env))
          (textureHandleOf (fromIntegral identity))
          decoded
          (Png.asymmetricTexel 8 4)
          >>= either (\failure → assertFailure ("the recording failed: " <> Text.unpack failure)) pure
      shotFailed shot `shouldBe` []
      shotDeterminate shot `shouldSatisfy` (> 20)
      -- Revision 2 is adopted, revision 1's recording has completed, and the texture is freed on that evidence.
      awaitTarget host target ((== Just 2) . windowAdopted)
      atomically $ do
        reading ← graphicsReading (envGraphics env)
        check (readingLiveTextures reading == 0)
      atomically $ do
        reading ← ledgerReading ledger
        check (Set.null (readingHeld reading))
        state ← readVulkanSceneState host
        check (all (null . windowAwaitingRelease) (Map.elems (sceneWindows state)))
      final ← atomically (ledgerReading ledger)
      readingDefects final `shouldBe` 0
      ended ← atomically (unregisterVulkanSceneTarget host target)
      ended `shouldBe` True
      atomically (hostWindowIdentities (vulkanWindowHost host)) `shouldReturn` []
      evidence env ("an offscreen scene target: the texture released straight after acceptance and before adoption was retained, drawn after the Lua release (" <> tshow (shotDeterminate shot) <> " pixels judged), and freed after the recording completed; no window opened")

-- | A line for the run's evidence record.
evidence ∷ Env → Text.Text → IO ()
evidence env line = atomically (modifyTVar' (envEvidence env) (line :))

-- | Block, in a transaction over the host's scene state, until the target's standing satisfies the condition.
awaitTarget ∷ VulkanHost scene → OffscreenTargetId → (WindowSceneStanding → Bool) → IO ()
awaitTarget host target ok = atomically $ do
  state ← readVulkanSceneState host
  case Map.lookup (KeyOffscreen target) (sceneWindows state) of
    Just standing | ok standing → pure ()
    _ → retry

-- | The batch recorded the way the host's production boundary records it for a target: bound to the scene the host
-- adopted for it, and to the batch's own ticket.
recordBound ∷ ∀ scene. VulkanHost scene → OffscreenTargetId → Recording
recordBound host target construction consumer =
  recordVulkanTargetBatch host target construction (\_ _ → consumer) >>= \case
    Right recorded → pure (Right recorded)
    Left (TargetBatchRefused refusal) → pure (Left refusal)
    Left other → pure (Left (RefusedIllegal (tshow other)))

tshow ∷ Show a ⇒ a → Text.Text
tshow = Text.pack . show
