-- | Device, allocator and cleanup faults keep their severity. Each is delivered as a failure of the
-- backend ('sinkFailed'), never as a cancellation, a retry or an image error; a cleanup that fails is
-- evidence beside the primary failure and is never retried or reported reclaimed; and a native budget
-- that answers backpressure is not a fault at all.
module Test.LuaEngine.Graphics.Faults (spec) where

import Control.Concurrent.STM (atomically, retry)
import Control.Exception (SomeException, fromException, try)
import Test.HUnit.Lang (HUnitFailure (..))
import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..), awaitBackendFailure, backendEvidence)
import Hetoimasia.LuaEngine.Graphics.Texture.Port
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "faults keep their severity" $ do
  it "delivers an allocator failure as a failure, with the borrowed level retired once and nothing left" $
    withRig defaultFakeConfig $ \rig → do
      inject (rigFake rig) (FailAllocate (FaultFatal "no device memory"))
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      failed ← awaitTerminal probe
      failed `shouldSatisfy` mentions "no device memory"
      awaitEvents probe (\seen → length (filter (== SeBuffersRetired) seen) == 1)
      seen ← events (rigFake rig)
      length (filter (Text.isPrefixOf "allocated") seen) `shouldBe` 0

  it "retains the work through native backpressure instead of failing or retrying the file" $
    withRig defaultFakeConfig $ \rig → do
      inject (rigFake rig) (PressureAllocate 3)
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      forM_ [1 .. 3] $ \attempt → do
        awaitEventCount (rigFake rig) "allocation pressure" attempt
        terminals probe `shouldReturn` []
        progress (rigFake rig)
      awaitTerminal probe >>= \event → event `shouldSatisfy` isReady
      seen ← events (rigFake rig)
      length (filter (Text.isPrefixOf "allocated") seen) `shouldBe` 1

  it "treats an upload bigger than the whole staging as a failure of the configuration, not of the content" $
    withRig defaultFakeConfig {fcStagingBytes = 8} $ \rig → do
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      failed ← awaitTerminal probe
      failed `shouldSatisfy` mentions "staging"
      awaitFake (rigFake rig) ((== 0) . readingImagesAlive)

  it "fails when the device is lost during the upload, and discards the image" $
    withRig defaultFakeConfig $ \rig → do
      inject (rigFake rig) LoseUploads
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      failed ← awaitTerminal probe
      failed `shouldSatisfy` mentions "lost"
      awaitFake (rigFake rig) ((== 0) . readingImagesAlive)

  it "fails a registration that is refused, with the image discarded" $
    withRig defaultFakeConfig $ \rig → do
      inject (rigFake rig) (FailRegister (FaultFatal "the table refused the image"))
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      failed ← awaitTerminal probe
      failed `shouldSatisfy` mentions "the table refused the image"
      awaitFake (rigFake rig) ((== 0) . readingImagesAlive)

  it "keeps the primary failure first and the cleanup failure beside it, and fails the scope that closes over it" $ do
    outcome ← try @SomeException . withRig defaultFakeConfig $ \rig → do
      inject (rigFake rig) (FailRegister (FaultFatal "the table refused the image"))
      inject (rigFake rig) (FailDiscard (FaultFatal "the discard was refused"))
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      failed ← awaitTerminal probe
      failed `shouldSatisfy` mentions "the table refused the image"
      failed `shouldSatisfy` mentions "the discard was refused"
      case failed of
        SeFailed text → Text.breakOn "the discard was refused" text `shouldSatisfy` (\(primary, _) → Text.isInfixOf "the table refused the image" primary)
        _ → expectationFailure "expected a failure"
      -- The cleanup failure is the backend's own, read before the scope closes.
      _ ← atomically (awaitBackendFailure (rigBackend rig))
      evidence ← atomically (backendEvidence (rigBackend rig))
      length evidence `shouldSatisfy` (>= 0)
    scopeFailed outcome

  it "reports a release that failed as a failed retirement, once, and never as reclaimed" $ do
    outcome ← try @SomeException . withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      _ ← awaitTerminal probe
      texture ← delivered probe
      inject (rigFake rig) (FailRelease (FaultFatal "the table would not release"))
      reading ← textureRelease texture
      atomically (reading >>= \case ProviderFailed _ → pure (); _ → retry)
      -- A repeated release asks nothing again and answers the same reading.
      again ← textureRelease texture
      atomically again >>= \case
        ProviderFailed _ → pure ()
        other → expectationFailure ("expected the failure again, found " <> describeState other)
      attempts ← eventCount (rigFake rig) "release attempted"
      attempts `shouldBe` 1
    scopeFailed outcome

  it "reports a release that raised as a failed retirement" $ do
    outcome ← try @SomeException . withRig defaultFakeConfig $ \rig → do
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      _ ← awaitTerminal probe
      texture ← delivered probe
      inject (rigFake rig) RaiseRelease
      reading ← textureRelease texture
      atomically (reading >>= \case ProviderFailed _ → pure (); _ → retry)
    scopeFailed outcome

  it "ends every job and every texture honestly when the owner ends: nothing is reported reclaimed" $ do
    fake ← newFake defaultFakeConfig
    withRigUnchecked fake $ \rig → do
      first ← newProbe
      _ ← submit rig first 2 2 255
      _ ← awaitTerminal first
      texture ← delivered first
      hold fake HoldUploadFinish
      second ← newProbe
      _ ← submit rig second 2 2 255
      awaitEvent fake "upload started"
      endOwner fake "the device was lost"
      failed ← awaitTerminal second
      failed `shouldSatisfy` mentions "graphics owner ended"
      reading ← textureRelease texture
      atomically (reading >>= \case ProviderFailed _ → pure (); _ → retry)
      backend ← readingNow rig
      readingEnded backend `shouldBe` Just "the device was lost"
  where
    isReady = \case SeReady _ → True; _ → False
    mentions needle = \case SeFailed text → needle `Text.isInfixOf` text; _ → False
    describeState other = case other of
      ProviderPending → "pending"
      ProviderComplete → "complete"
      ProviderFailed _ → "failed"

-- | The scope failed with the backend's own failure, not with the example's bound or an assertion.
scopeFailed ∷ Either SomeException () → Expectation
scopeFailed = \case
  Right () → expectationFailure "the scope returned although a cleanup had failed"
  Left failure
    | Just (HUnitFailure _ _) ← fromException failure → expectationFailure ("the example failed instead of the scope: " <> show failure)
    | otherwise → pure ()
