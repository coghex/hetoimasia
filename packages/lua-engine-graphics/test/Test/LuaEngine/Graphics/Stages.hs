-- | A request finishes only when the upload and the registration have been observed: the success path
-- withheld, one stage at a time, at the owner's admission, the allocation, the upload's start and its
-- completion, the table's bootstrap, the registration and the transfer of the result.
--
-- The owner here is the example's own ("Test.LuaEngine.Graphics.Fake"); these examples prove the
-- backend's ordering and ownership. The real-device suite proves the texels.
module Test.LuaEngine.Graphics.Stages (spec) where

import Control.Concurrent.STM (atomically, retry)
import Data.List (isPrefixOf, isSuffixOf)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..))
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "success is the observed upload and the observed registration" $ do
  it "settles only after the image, the upload, the bound table and a registration that resolves, in that order" $
    withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      _ ← submit rig probe 4 2 255
      awaitTerminal probe >>= \event → event `shouldSatisfy` isReady
      seen ← map Text.unpack <$> events (rigFake rig)
      subsequenceOf
        ["allocated 0 4x2", "upload admitted", "upload started", "upload completed", "registered 0", "sink ready"]
        seen
        `shouldBe` True
      -- The borrowed level is retired once, as soon as the copy into staging ended, before the upload completed.
      subsequenceOf ["upload admitted", "sink buffers retired", "upload completed"] seen `shouldBe` True
      length (filter (== "sink buffers retired") seen) `shouldBe` 1

  it "classifies alpha from the borrowed level and registers it with that mark" $
    withRig defaultFakeConfig $ \rig → do
      opaque ← newProbe
      _ ← submit rig opaque 2 2 255
      _ ← awaitTerminal opaque
      translucent ← newProbe
      _ ← submit rig translucent 2 2 100
      _ ← awaitTerminal translucent
      seen ← map Text.unpack <$> events (rigFake rig)
      length [() | line ← seen, "registered" `isPrefixOf` line, "alpha True" `isSuffixOf` line] `shouldBe` 1
      length [() | line ← seen, "registered" `isPrefixOf` line, "alpha False" `isSuffixOf` line] `shouldBe` 1

  it "answers nothing while the owner has not run its first action" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldOwner
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      awaitFake (rigFake rig) ((== 1) . readingActsQueued)
      terminals probe `shouldReturn` []
      imagesNow rig `shouldReturn` 0
      release (rigFake rig) HoldOwner
      awaitTerminal probe >>= \event → event `shouldSatisfy` isReady

  it "answers nothing while the allocation is withheld" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldAllocate
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      awaitPhase rig "allocating"
      awaitFake (rigFake rig) ((== 0) . readingActsQueued)
      terminals probe `shouldReturn` []
      imagesNow rig `shouldReturn` 0
      release (rigFake rig) HoldAllocate
      awaitTerminal probe >>= \event → event `shouldSatisfy` isReady

  it "answers nothing while the upload has not started, and while it has not completed" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldUploadStart
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      awaitEvent (rigFake rig) "upload admitted"
      awaitPhase rig "uploading"
      terminals probe `shouldReturn` []
      -- The level's bytes live in staging now, and the borrow of the caller's bytes is over.
      awaitEvents probe (== [SeBuffersRetired])
      stagingNow rig `shouldReturn` 16
      hold (rigFake rig) HoldUploadFinish
      release (rigFake rig) HoldUploadStart
      awaitEvent (rigFake rig) "upload started"
      terminals probe `shouldReturn` []
      release (rigFake rig) HoldUploadFinish
      awaitTerminal probe >>= \event → event `shouldSatisfy` isReady
      stagingNow rig `shouldReturn` 0

  it "answers nothing while the table's placeholder is not bound, although the upload completed" $
    withRig defaultFakeConfig {fcInitialHolds = [HoldBind]} $ \rig → do
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      awaitEvent (rigFake rig) "upload completed"
      awaitPhase rig "uploaded"
      terminals probe `shouldReturn` []
      registrationsNow rig `shouldReturn` 0
      reading ← readingNow rig
      readingBound reading `shouldBe` False
      release (rigFake rig) HoldBind
      awaitTerminal probe >>= \event → event `shouldSatisfy` isReady

  it "answers nothing while the registration has not resolved" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldRegister
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      awaitPhase rig "registering"
      awaitFake (rigFake rig) ((== 0) . readingActsQueued)
      terminals probe `shouldReturn` []
      release (rigFake rig) HoldRegister
      awaitTerminal probe >>= \event → event `shouldSatisfy` isReady

  it "keeps the texture the backend's until the pipeline took it" $
    withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      gateReady probe
      _ ← submit rig probe 2 2 255
      texture ← delivered probe
      awaitPhase rig "delivering"
      terminals probe `shouldReturn` []
      -- Offered, not delivered: it is registered, and a job still holds it.
      registrationsNow rig `shouldReturn` 1
      reading ← readingNow rig
      readingLiveTextures reading `shouldBe` 1
      openReady probe
      awaitTerminal probe >>= \event → event `shouldBe` SeReady (textureIdentity texture)
      reading' ← readingNow rig
      readingJobs reading' `shouldBe` 0

  it "names the texture by the handle's index and generation, and never by a slot alone" $
    withRig defaultFakeConfig $ \rig → do
      first ← newProbe
      _ ← submit rig first 1 1 255
      one ← awaitTerminal first
      texture ← delivered first
      reading ← textureRelease texture
      atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
      second ← newProbe
      _ ← submit rig second 1 1 255
      two ← awaitTerminal second
      one `shouldSatisfy` isReady
      two `shouldSatisfy` isReady
      -- The slot is reused; the identity is not.
      one `shouldNotBe` two
  where
    isReady = \case SeReady _ → True; _ → False
    imagesNow rig = readingImagesAlive <$> atomically (readFake (rigFake rig))
    registrationsNow rig = readingRegistrations <$> atomically (readFake (rigFake rig))
    stagingNow rig = readingStagingUsed <$> atomically (readFake (rigFake rig))

subsequenceOf ∷ [String] → [String] → Bool
subsequenceOf wanted seen = go wanted seen
  where
    go [] _ = True
    go _ [] = False
    go (w : ws) (s : ss)
      | w `isPrefixOf` s = go ws ss
      | otherwise = go (w : ws) ss
