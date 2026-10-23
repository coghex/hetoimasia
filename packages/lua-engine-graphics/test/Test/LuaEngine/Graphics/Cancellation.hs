-- | Cancellation and instance-independent end, at every boundary of one request: before the allocation was
-- issued, inside it, after it, while the upload is queued, while it copies, once it completed but before the
-- table was bound, inside the registration, and while the result is being handed over. In each, the
-- cancelled request answers one withdrawal and one retirement of the borrowed level, never a success, and
-- leaves no image, registration or upload behind; and a success that was handed over is not erased.
module Test.LuaEngine.Graphics.Cancellation (spec) where

import Control.Concurrent.STM (atomically, retry)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..))
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..), SinkAnswer (..), UploadWork (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "a cancelled request is taken apart in dependency order and never succeeds" $ do
  it "before the allocation was issued, touches nothing native" $
    withRig defaultFakeConfig {fcActCapacity = 0} $ \rig → do
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitPhase rig "new"
      uploadCancel work
      withdrawn probe
      seen ← events (rigFake rig)
      filter (Text.isPrefixOf "allocated") seen `shouldBe` []

  it "inside the allocation: the image is made, recorded by the action that made it, and discarded" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldAllocate
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitPhase rig "allocating"
      awaitFake (rigFake rig) ((== 0) . readingActsQueued)
      uploadCancel work
      terminals probe `shouldReturn` []
      release (rigFake rig) HoldAllocate
      withdrawn probe
      seen ← events (rigFake rig)
      count "allocated" seen `shouldBe` 1
      count "discarded" seen `shouldBe` 1
      count "upload admitted" seen `shouldBe` 0

  it "after the allocation, while the upload cannot be admitted" $
    withRig defaultFakeConfig $ \rig → do
      inject (rigFake rig) (AdmitPressure 1000)
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitPhase rig "allocated"
      terminals probe `shouldReturn` []
      uploadCancel work
      withdrawn probe
      seen ← events (rigFake rig)
      count "discarded" seen `shouldBe` 1
      count "upload admitted" seen `shouldBe` 0

  it "while the upload is queued: the upload is cancelled and the image discarded" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldUploadStart
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitEvent (rigFake rig) "upload admitted"
      awaitPhase rig "uploading"
      uploadCancel work
      withdrawn probe
      seen ← events (rigFake rig)
      count "upload cancelled" seen `shouldBe` 1
      count "discarded" seen `shouldBe` 1
      count "upload started" seen `shouldBe` 0

  it "while the upload copies: it cannot be recalled, so it completes, and is discarded unregistered" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldUploadFinish
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitEvent (rigFake rig) "upload started"
      uploadCancel work
      terminals probe `shouldReturn` []
      imagesAlive rig `shouldReturn` 1
      release (rigFake rig) HoldUploadFinish
      withdrawn probe
      seen ← events (rigFake rig)
      count "upload completed" seen `shouldBe` 1
      count "discarded" seen `shouldBe` 1
      count "registered" seen `shouldBe` 0

  it "after the upload completed and before the table was bound, discards and never registers" $
    withRig defaultFakeConfig {fcInitialHolds = [HoldBind]} $ \rig → do
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitPhase rig "uploaded"
      uploadCancel work
      withdrawn probe
      seen ← events (rigFake rig)
      count "registered" seen `shouldBe` 0
      count "discarded" seen `shouldBe` 1

  it "inside the registration: the registration is recorded by its action and released through the table" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldRegister
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitPhase rig "registering"
      awaitFake (rigFake rig) ((== 0) . readingActsQueued)
      uploadCancel work
      terminals probe `shouldReturn` []
      release (rigFake rig) HoldRegister
      withdrawn probe
      seen ← events (rigFake rig)
      count "registered" seen `shouldBe` 1
      count "released" seen `shouldBe` 1
      count "sink ready" seen `shouldBe` 0

  it "while the result is being handed over: a success that was taken is not erased" $
    withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      gateReady probe
      work ← submit rig probe 2 2 255
      texture ← delivered probe
      awaitPhase rig "delivering"
      uploadCancel work
      openReady probe
      awaitTerminal probe >>= \event → event `shouldBe` SeReady (textureIdentity texture)
      terminals probe >>= \found → length found `shouldBe` 1
      reading ← textureRelease texture
      atomically (reading >>= \case ProviderComplete → pure (); _ → retry)

  it "when the pipeline already ended the job, the texture it was offered is released once and no terminal event follows" $
    withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      answerReady probe SinkLate
      gateReady probe
      work ← submit rig probe 2 2 255
      _ ← delivered probe
      awaitPhase rig "delivering"
      uploadCancel work
      openReady probe
      awaitFake (rigFake rig) ((== 0) . readingRegistrations)
      awaitFake (rigFake rig) ((== 0) . readingImagesAlive)
      awaitBackend rig ((== 0) . readingJobs)
      terminals probe `shouldReturn` []
      seen ← events (rigFake rig)
      count "released" seen `shouldBe` 1

  it "answers duplicate and late cancellations without a second event or a second cleanup" $
    withRig defaultFakeConfig $ \rig → do
      hold (rigFake rig) HoldUploadStart
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitEvent (rigFake rig) "upload admitted"
      uploadCancel work
      uploadCancel work
      withdrawn probe
      uploadCancel work
      seen ← events (rigFake rig)
      count "discarded" seen `shouldBe` 1
      terminals probe >>= \found → length found `shouldBe` 1
  where
    withdrawn probe = do
      awaitTerminal probe >>= \event → event `shouldBe` SeWithdrawn
      awaitEvents probe (\events' → length (filter (== SeBuffersRetired) events') == 1)
      terminals probe `shouldReturn` [SeWithdrawn]
    count prefix = length . filter (Text.isPrefixOf prefix)
    imagesAlive rig = readingImagesAlive <$> atomically (readFake (rigFake rig))
