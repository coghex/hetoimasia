-- | Explicit release and retirement. A release revokes authority at once and never waits; the table's
-- release runs on the owner's thread only when the scene holds allow it; what a batch's version still maps
-- keeps the texture unretired; a repeated release asks nothing again; and a release requested is not a
-- texture retired.
module Test.LuaEngine.Graphics.Release (spec) where

import Control.Concurrent.STM (atomically, retry)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (TextureRef (..), textureRefOf)
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "release and retirement" $ do
  it "revokes at once, waits for the scene's holds, then for the batches' versions, and only then retires" $
    withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      _ ← awaitTerminal probe
      texture ← delivered probe
      setVersionHolders (rigFake rig) 1
      hold (rigFake rig) HoldReclaim
      holdBarrier (rigFake rig)
      reading ← textureRelease texture
      -- Authority is gone at once: the logical release is marked while nothing was released natively.
      awaitFake (rigFake rig) (\r → not (null (readingMarkedNow r)))
      atomically reading >>= (`shouldBe'` "pending")
      eventCount (rigFake rig) "release attempted" `shouldReturn` 0
      -- The scene adopted what held it: the table releases, but a batch's version still maps the slot.
      release (rigFake rig) HoldAdoption
      awaitEvent (rigFake rig) "released"
      -- The release ran; the backend now waits for the table's evidence, and a batch's version still maps the slot.
      awaitBackend rig (elem "retiring" . readingTextureStages)
      atomically reading >>= (`shouldBe'` "pending")
      -- The batch completed and the slot is reclaimed: now, and only now, it is retired.
      setVersionHolders (rigFake rig) 0
      release (rigFake rig) HoldReclaim
      atomically (reading >>= \case ProviderComplete → pure (); _ → retry)

  it "asks the table once however often it is released" $
    withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      _ ← awaitTerminal probe
      texture ← delivered probe
      -- The first release waits in the lane for the scene's adoption, and the repeats find it asked.
      holdBarrier (rigFake rig)
      first ← textureRelease texture
      awaitBackend rig (elem "releasing" . readingTextureStages)
      -- The repeats find the release asked and in the lane, and ask nothing again.
      repeats ← mapM (const (textureRelease texture)) [1 .. 3 ∷ Int]
      awaitBackend rig (elem "releasing" . readingTextureStages)
      awaitFake (rigFake rig) ((== 1) . readingReleasesQueued)
      let readings = first : repeats
      release (rigFake rig) HoldAdoption
      forM' readings $ \reading → atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
      eventCount (rigFake rig) "release attempted" `shouldReturn` 1
      eventCount (rigFake rig) "released 0 slot 1" `shouldReturn` 1

  it "treats a release that arrives while the pipeline's answer is still in flight as the texture's own" $
    withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      gateReady probe
      _ ← submit rig probe 2 2 255
      texture ← delivered probe
      reading ← textureRelease texture
      openReady probe
      atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
      eventCount (rigFake rig) "release attempted" `shouldReturn` 1

  it "reuses a slot under a new generation, so a stale identity never names the new texture" $
    withRig defaultFakeConfig {fcSlots = 1} $ \rig → do
      first ← newProbe
      _ ← submit rig first 1 1 255
      _ ← awaitTerminal first
      oldTexture ← delivered first
      reading ← textureRelease oldTexture
      atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
      second ← newProbe
      _ ← submit rig second 1 1 255
      _ ← awaitTerminal second
      newTexture ← delivered second
      let old = textureRefOf (textureIdentity oldTexture)
          new = textureRefOf (textureIdentity newTexture)
      refIndex old `shouldBe` refIndex new
      refGeneration old `shouldNotBe` refGeneration new
      textureIdentity oldTexture `shouldNotBe` textureIdentity newTexture
  where
    shouldBe' state expected = case (state, expected ∷ String) of
      (ProviderPending, "pending") → pure ()
      (ProviderComplete, "complete") → pure ()
      _ → expectationFailure ("expected the retirement " <> expected)
    forM' xs f = mapM_ f xs
