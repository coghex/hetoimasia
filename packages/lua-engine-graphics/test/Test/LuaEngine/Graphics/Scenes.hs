-- | Scene retention (LFE-20) over the injected owner and the scene host model: what a texture's release waits for,
-- the multiplicity of an adoption, the six-revision limit, the release lane's pressure, and the windows a release
-- barrier names.
--
-- The scene ledger is the production one and the backend is the production backend. The owner (the fake) and the
-- host's ledger rules (the model, "Test.LuaEngine.Graphics.SceneHost") are injected, and say so: this proves the
-- adapter's ordering, ownership and cleanup under the documented rules of the host, never a frame. The real host is
-- the native scene retention subgroup's.
module Test.LuaEngine.Graphics.Scenes (spec) where

import Control.Concurrent.STM (atomically, retry)
import Control.Exception (SomeException, finally, fromException, try)
import Control.Monad (forM_)
import Data.Functor ((<&>))
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger
import Hetoimasia.LuaEngine.Graphics.Scene.Publish (HostAnswer (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Port (Fault (FaultFatal))
import Hetoimasia.LuaEngine.Scene (initialContent)
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..))
import Numeric.Natural (Natural)
import Test.HUnit.Lang (HUnitFailure (HUnitFailure))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig
import Test.LuaEngine.Graphics.SceneHost

spec ∷ Spec
spec = describe "scene retention" $ do
  describe "the ledger" $ do
    it "holds what an adoption names until its release, by complete identity" $ do
      ledger ← newSceneLedger ∷ IO (SceneLedger Int)
      ledgerAdopted ledger 1 1 (naming [10, 11])
      atomically (ledgerHeld ledger 10) `shouldReturn` True
      -- The same index under another generation is another texture, and is not held.
      atomically (ledgerHeld ledger (10 + 2 ^ (32 ∷ Int))) `shouldReturn` False
      ledgerReleased ledger 1 1
      atomically (ledgerHeld ledger 10) `shouldReturn` False
      reading ← atomically (ledgerReading ledger)
      (readingDefects reading, readingRecords reading) `shouldBe` (0, [])

    it "counts adoptions of a revision, so the first release leaves the second adoption's protection" $ do
      ledger ← newSceneLedger ∷ IO (SceneLedger Int)
      ledgerAdopted ledger 1 5 (naming [10])
      ledgerAdopted ledger 1 5 (naming [10])
      atomically (ledgerHolds ledger 10) `shouldReturn` 2
      ledgerReleased ledger 1 5
      atomically (ledgerHeld ledger 10) `shouldReturn` True
      ledgerReleased ledger 1 5
      atomically (ledgerHeld ledger 10) `shouldReturn` False

    it "keeps two windows' holds apart" $ do
      ledger ← newSceneLedger ∷ IO (SceneLedger Int)
      ledgerAdopted ledger 1 1 (naming [10])
      ledgerAdopted ledger 2 1 (naming [10])
      ledgerReleased ledger 1 1
      atomically (ledgerHeld ledger 10) `shouldReturn` True
      ledgerReleased ledger 2 1
      atomically (ledgerHeld ledger 10) `shouldReturn` False

    it "counts a pairing defect, never raises, and never loses a hold" $ do
      ledger ← newSceneLedger ∷ IO (SceneLedger Int)
      ledgerReleased ledger 1 7
      ledgerAdopted ledger 1 8 (naming [10])
      ledgerAdopted ledger 1 8 (naming [11])
      first ← atomically (ledgerReading ledger)
      readingDefects first `shouldBe` 2
      readingFirstDefect first `shouldSatisfy` maybe False (not . null . show)
      -- The union is protected rather than a hold lost.
      readingHeld first `shouldBe` Set.fromList [10, 11]

  describe "the release of a published texture" $ do
    it "waits for the adoption of the scene, defers while the adopted scene holds it, and retires after the last use" $
      sceneRig defaultFakeConfig $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        (texture, identity) ← deliverTexture rig
        publishScene' model 1 (naming [identity])
        -- Released before any adoption: the request waits for the barrier, which names the published window.
        reading ← textureRelease texture
        awaitBackend rig (elem "releasing" . readingTextureStages)
        eventCount fake "release attempted" `shouldReturn` 0
        adoptNow model 1 `shouldReturn` Adopted 1
        -- The scene adopted what it names; the release action found it held and released nothing.
        awaitBackend rig (elem "held" . readingTextureStages)
        eventCount fake "release attempted" `shouldReturn` 0
        atomically (ledgerHeld (fakeLedger fake) identity) `shouldReturn` True
        pendingNow reading `shouldReturn` True
        -- A frame is in flight with the adopted scene; replacing the scene alone frees nothing.
        beginUse model 1 1 1
        publishScene' model 1 (naming [])
        adoptNow model 1 `shouldReturn` Adopted 2
        releasePass model `shouldReturn` []
        eventCount fake "release attempted" `shouldReturn` 0
        -- The frame's completion is observed: the adoption is released, and only then is the table asked.
        endUse model 1 1 1
        releasePass model `shouldReturn` [(1, 1)]
        awaitEvent fake "released"
        atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
        eventCount fake "release attempted" `shouldReturn` 1

    it "releases at once what no adopted scene holds, and never re-asks" $
      sceneRig defaultFakeConfig $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        (texture, _) ← deliverTexture rig
        reading ← textureRelease texture
        atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
        eventCount fake "release attempted" `shouldReturn` 1

    it "adopts only the latest of two publications made before the owner's step, with no hold from the first" $
      sceneRig defaultFakeConfig $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        (first, firstId) ← deliverTexture rig
        (second, secondId) ← deliverTexture rig
        publishScene' model 1 (naming [firstId])
        publishScene' model 1 (naming [secondId])
        adoptNow model 1 `shouldReturn` Adopted 2
        reading ← atomically (ledgerReading (fakeLedger fake))
        (readingRecords reading, readingHeld reading) `shouldBe` ([((1, 2), 1)], Set.fromList [secondId])
        -- The superseded publication named a texture nothing holds: its release is not deferred at all.
        firstReading ← textureRelease first
        atomically (firstReading >>= \case ProviderComplete → pure (); _ → retry)
        secondReading ← textureRelease second
        awaitBackend rig (elem "held" . readingTextureStages)
        pendingNow secondReading `shouldReturn` True

    it "keeps a texture protected by a revision adopted under a second attachment after the first is released" $
      sceneRig defaultFakeConfig $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        (texture, identity) ← deliverTexture rig
        publishScene' model 1 (naming [identity])
        adoptFor model 1 1 `shouldReturn` Adopted 1
        beginUse model 1 1 1
        -- The target is replaced: revision 1 is adopted again under attachment 2, while attachment 1's use is out.
        endTarget model 1 1
        adoptFor model 1 2 `shouldReturn` Adopted 1
        reading ← textureRelease texture
        awaitBackend rig (elem "held" . readingTextureStages)
        atomically (ledgerHolds (fakeLedger fake) identity) `shouldReturn` 2
        -- Attachment 1's use completes and its adoption is released; attachment 2's protection stands.
        endUse model 1 1 1
        releasePass model `shouldReturn` [(1, 1)]
        atomically (ledgerHolds (fakeLedger fake) identity) `shouldReturn` 1
        pendingNow reading `shouldReturn` True
        eventCount fake "release attempted" `shouldReturn` 0
        -- Attachment 2 ends: its adoption is released, but the window still retains revision 1 with no live target, so
        -- the table is not asked until the window is gone.
        endTarget model 1 2
        releasePass model `shouldReturn` [(1, 1)]
        awaitBackend rig (elem "releasing" . readingTextureStages)
        eventCount fake "release attempted" `shouldReturn` 0
        removeWindow model 1
        awaitEvent fake "released"
        atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
        eventCount fake "release attempted" `shouldReturn` 1

  describe "a window that retains its published scene between two attachments" $
    it "keeps the texture until the second attachment has adopted the scene, though the first adoption is fully released before it" $
      sceneRig defaultFakeConfig $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        (texture, identity) ← deliverTexture rig
        publishScene' model 1 (naming [identity])
        adoptFor model 1 1 `shouldReturn` Adopted 1
        reading ← textureRelease texture
        awaitBackend rig (elem "held" . readingTextureStages)
        -- The first attachment ends and its adoption is released whole before the second begins: the ledger holds
        -- nothing, but the window still retains revision 1, which names the texture.
        -- The owner is held while the pump asks again, so where the request waits can be read.
        hold fake HoldOwner
        endTarget model 1 1
        releasePass model `shouldReturn` [(1, 1)]
        atomically (ledgerHeld (fakeLedger fake) identity) `shouldReturn` False
        -- The pump asks again through the barrier lane, which names the window and waits for a live target of it, and
        -- not through the ordinary lane, which waits for nothing.
        awaitFake fake ((== 1) . readingReleasesQueued)
        atomically (readingActsQueued <$> readFake fake) `shouldReturn` 0
        release fake HoldOwner
        awaitBackend rig (elem "releasing" . readingTextureStages)
        eventCount fake "release attempted" `shouldReturn` 0
        pendingNow reading `shouldReturn` True
        -- The second attachment adopts the retained scene and holds the texture again.
        adoptFor model 1 2 `shouldReturn` Adopted 1
        awaitBackend rig (elem "held" . readingTextureStages)
        eventCount fake "release attempted" `shouldReturn` 0
        atomically (ledgerHeld (fakeLedger fake) identity) `shouldReturn` True
        -- Its end alone does not: the window still retains the scene with no live target. The window's end does.
        endTarget model 1 2
        releasePass model `shouldReturn` [(1, 1)]
        awaitBackend rig (elem "releasing" . readingTextureStages)
        eventCount fake "release attempted" `shouldReturn` 0
        removeWindow model 1
        awaitEvent fake "released"
        atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
        eventCount fake "release attempted" `shouldReturn` 1

  describe "the adopted-revision limit" $
    it "defers a seventh adoption without a seventh record, and adopts the latest once a use retires" $
      sceneRig defaultFakeConfig $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        forM_ [1 .. 6 ∷ Natural] $ \revision → do
          publishScene' model 1 (naming [])
          adoptNow model 1 `shouldReturn` Adopted revision
          beginUse model 1 revision 1
        -- A seventh and an eighth publication are latest values in one slot; the owner defers.
        publishScene' model 1 (naming [])
        adoptNow model 1 `shouldReturn` Deferred
        publishScene' model 1 (naming [])
        adoptNow model 1 `shouldReturn` Deferred
        publishedRevision model 1 `shouldReturn` 8
        length <$> adoptedRecords model 1 `shouldReturn` 6
        -- Completions in an adversarial order: nothing is released out of adoption order.
        forM_ [3, 2] $ \revision → endUse model 1 revision 1
        releasePass model `shouldReturn` []
        endUse model 1 1 1
        -- Revision 6 is still current and unreleased only because it is not superseded: 1, 2 and 3 go, in order.
        releasePass model `shouldReturn` [(1, 1), (1, 2), (1, 3)]
        adoptNow model 1 `shouldReturn` Adopted 8
        length <$> adoptedRecords model 1 `shouldReturn` 4
        reading ← atomically (ledgerReading (fakeLedger fake))
        readingDefects reading `shouldBe` 0

  describe "the release lane under pressure" $
    it "asks again for a release the full lane refused, once, with no further call, and retires after the scene is replaced" $
      sceneRig defaultFakeConfig {fcReleaseCapacity = 1} $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        (one, _) ← deliverTexture rig
        (two, identityTwo) ← deliverTexture rig
        publishScene' model 1 (naming [identityTwo])
        adoptNow model 1 `shouldReturn` Adopted 1
        -- The lane's one place is taken by a request that cannot run, so the second request is refused for room.
        holdBarrier fake
        oneReading ← textureRelease one
        awaitFake fake ((== 1) . readingReleasesQueued)
        twoReading ← textureRelease two
        awaitBackend rig ((== 2) . length . filter (`elem` ["release-requested", "releasing"]) . readingTextureStages)
        readingReleasesQueuedNow fake `shouldReturn` 1
        -- Room appears; nothing is called, and the refused request is admitted once, runs, finds the hold, and waits.
        release fake HoldAdoption
        atomically (oneReading >>= \case ProviderComplete → pure (); _ → retry)
        awaitBackend rig (elem "held" . readingTextureStages)
        eventCount fake "release attempted" `shouldReturn` 1
        -- The scene is replaced and the frame completes: the second texture retires with no second release call.
        publishScene' model 1 (naming [])
        adoptNow model 1 `shouldReturn` Adopted 2
        releasePass model `shouldReturn` [(1, 1)]
        atomically (twoReading >>= \case ProviderComplete → pure (); _ → retry)
        eventCount fake "release attempted" `shouldReturn` 2

  describe "a failed release after a hold" $
    it "is fatal for that texture, recorded, and never asked again" $ do
      outcome ← try @SomeException . sceneRig defaultFakeConfig $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        (texture, identity) ← deliverTexture rig
        publishScene' model 1 (naming [identity])
        adoptNow model 1 `shouldReturn` Adopted 1
        reading ← textureRelease texture
        awaitBackend rig (elem "held" . readingTextureStages)
        inject fake (FailRelease (FaultFatal "injected: the table refused the release"))
        publishScene' model 1 (naming [])
        adoptNow model 1 `shouldReturn` Adopted 2
        releasePass model `shouldReturn` [(1, 1)]
        atomically (reading >>= \case ProviderFailed _ → pure (); _ → retry)
        progress fake
        eventCount fake "release attempted" `shouldReturn` 1
        readingNow rig >>= (`shouldSatisfy` readingFailed)
      scopeFailed outcome

  describe "the windows a release barrier names" $ do
    it "does not wait for a window that never published" $
      sceneRig defaultFakeConfig $ \rig model → do
        modelWindow model 1
        modelWindow model 2
        (texture, _) ← deliverTexture rig
        reading ← textureRelease texture
        atomically (reading >>= \case ProviderComplete → pure (); _ → retry)

    it "waits for a published window with no live target until a target adopts it or the window is gone" $
      sceneRig defaultFakeConfig $ \rig model → do
        let fake = rigFake rig
        modelWindow model 1
        modelWindow model 2
        (texture, _) ← deliverTexture rig
        publishScene' model 2 (naming [])
        reading ← textureRelease texture
        awaitBackend rig (elem "releasing" . readingTextureStages)
        eventCount fake "release attempted" `shouldReturn` 0
        -- No frame is possible for the window, which is not a reason to call it harmless: the window goes.
        removeWindow model 2
        atomically (reading >>= \case ProviderComplete → pure (); _ → retry)

    it "treats a later published empty scene as a real revision with its own adoption" $
      sceneRig defaultFakeConfig $ \rig model → do
        modelWindow model 1
        publishScene' model 1 (naming [])
        (texture, _) ← deliverTexture rig
        reading ← textureRelease texture
        awaitBackend rig (elem "releasing" . readingTextureStages)
        adoptNow model 1 `shouldReturn` Adopted 1
        atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
  where
    -- The scope failed, as a latched cleanup failure makes it, and not the example's own assertions.
    scopeFailed ∷ Either SomeException () → Expectation
    scopeFailed = \case
      Right () → expectationFailure "the scope returned although a cleanup had failed"
      Left failure
        | Just (HUnitFailure _ _) ← fromException failure → expectationFailure ("the example failed instead of the scope: " <> show failure)
        | otherwise → pure ()

    -- A rig, with a model of the host's ledger over the fake's own, whose barrier the fake's release lane waits on.
    -- However the example ends its windows are dissolved: the backend's scope drains until every texture is proved
    -- retired, and a texture an adopted scene still holds retires only when that scene is released.
    sceneRig cfg body = withRig cfg $ \rig → do
      model ← newModel (fakeLedger (rigFake rig))
      setBarrier (rigFake rig) (modelCapture model)
      body rig model `finally` dissolve model

    naming ∷ [Word64] → GraphicsScene
    naming identities = GraphicsScene initialContent (Set.fromList identities)

    publishScene' model window scene = do
      prepared ← prepare scene
      answer ← atomically (fst (modelTarget model window) prepared)
      answer `shouldBe` HostAccepted

    deliverTexture rig = do
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      _ ← awaitTerminal probe
      texture ← delivered probe
      pure (texture, textureIdentity texture)

    pendingNow reading = atomically reading <&> \case ProviderPending → True; _ → False

    readingReleasesQueuedNow fake = atomically (readingReleasesQueued <$> readFake fake)

