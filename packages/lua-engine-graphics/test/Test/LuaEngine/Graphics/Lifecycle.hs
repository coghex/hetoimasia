-- | The lifecycle paths a close, a bootstrap and an owner's end cross, each held at its seam: a texture offered to
-- the pipeline while the scope closes, an owner that ends before the table is bound, a table that cannot be read,
-- a retirement the owner can no longer prove, and an offer taken after the owner's end. Each is a regression for a
-- site of the same shape as the others: a close effect or a drain that skips a release, a wait that is never ended,
-- a write that erases what a transaction just recorded.
module Test.LuaEngine.Graphics.Lifecycle (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (AsyncException (ThreadKilled), SomeException, finally, fromException, throwIO, toException, try)
import Test.HUnit.Lang (HUnitFailure (..))
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..), awaitBound)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (Standing (..))
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..), UploadWork (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "close, bootstrap and the owner's end, at every seam" $ do
  it "releases a texture that was offered while the scope closed, once the pipeline takes it" $ do
    fake ← newFake defaultFakeConfig
    probe ← newProbe
    gateReady probe
    rigs ← newEmptyMVar
    withFakeOwner fake . bounded $ do
      forked ← forkScope $ do
        withBackendOnRaw fake $ \rig → do
          putMVar rigs rig
          _ ← submit rig probe 2 2 255
          -- The body returns while 'sinkReady' is still inside the pipeline.
          _ ← delivered probe
          pure ()
        noteEvent fake "scope returned"
      rig ← takeMVar rigs
      -- The close has marked the offer; the drain cannot end while the pipeline holds it.
      awaitBackend rig (elem "offered-released" . readingTextureStages)
      noteEvent fake "offer answered"
      openReady probe
      forkedJoin forked >>= either (\failure → expectationFailure (show failure)) pure
      assertBefore fake "offer answered" "scope returned"
      -- The taken texture was engine-owned and unconsumed: released once, and nothing is left.
      eventCount fake "release attempted" `shouldReturn` 1
      problems ← atomically (leaked fake)
      problems `shouldBe` []

  it "ends assembly with the owner's end, not with a bound table, and stops scheduling bootstrap reads" $ do
    fake ← newFake defaultFakeConfig {fcInitialHolds = [HoldBind]}
    withRigUnchecked fake $ \rig → do
      setStanding fake (Ended "gone")
      outcome ← try @SomeException (awaitBound (rigBackend rig))
      scopeFailedWith "ended" outcome
      reading ← readingNow rig
      readingBound reading `shouldBe` False
      readingEnded reading `shouldBe` Just "gone"

  it "raises a table that cannot be read as the backend's failure, keeping it, and fails the work that waited for it" $ do
    fake ← newFake defaultFakeConfig {fcInitialHolds = [HoldBind]}
    inject fake RaiseTable
    outcome ← try @SomeException . withRigUnchecked fake $ \rig → do
      assembly ← try @SomeException (awaitBound (rigBackend rig))
      scopeFailedWith "reading the table" assembly
      reading ← readingNow rig
      readingFailed reading `shouldBe` True
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      failed ← awaitTerminal probe
      failed `shouldSatisfy` (\event → case event of SeFailed text → "never bound" `Text.isInfixOf` text; _ → False)
    -- The latched failure is the scope's, too, and it is the backend's, not the example's.
    case outcome of
      Right () → expectationFailure "the scope returned although reading the table raised"
      Left failure
        | Just (HUnitFailure _ _) ← fromException failure → expectationFailure ("the example failed instead of the scope: " <> show failure)
        | otherwise → pure ()

  it "settles a retirement the owner can no longer prove as failed, not retired, and stops asking" $ do
    fake ← newFake defaultFakeConfig
    outcome ← try @SomeException . withRigUnchecked fake $ \rig → do
      hold fake HoldRegister
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitPhase rig "registering"
      awaitFake fake ((== 0) . readingActsQueued)
      setVersionHolders fake 1
      hold fake HoldReclaim
      uploadCancel work
      release fake HoldRegister
      -- The cancelled registration is released and waits for a batch's version to end.
      awaitEvent fake "released"
      awaitPhase rig "retiring"
      endOwner fake "the device was lost"
      failed ← awaitTerminal probe
      failed `shouldSatisfy` (\event → case event of SeFailed text → "ended" `Text.isInfixOf` text; _ → False)
      awaitBackend rig ((== 0) . readingJobs)
    -- The cleanup that could not be proved is the scope's failure too: nothing is reported reclaimed.
    case outcome of
      Right () → expectationFailure "the scope returned although a retirement was never proved"
      Left failure
        | Just (HUnitFailure _ _) ← fromException failure → expectationFailure ("the example failed instead of the scope: " <> show failure)
        | otherwise → pure ()

  it "fails a texture the pipeline took as the owner ended, and reports it failed, never retired" $ do
    fake ← newFake defaultFakeConfig
    probe ← newProbe
    gateReady probe
    withRigUnchecked fake $ \rig → do
      _ ← submit rig probe 2 2 255
      texture ← delivered probe
      -- The pump is the one that learns of the owner's end, and it is inside the offer.
      endOwner fake "gone"
      openReady probe
      awaitBackend rig ((== Just "gone") . readingEnded)
      reading ← textureRelease texture
      atomically (reading >>= \case ProviderFailed _ → pure (); _ → retry)
  it "settles a job whose sink raised on the offer, latches it, and releases what it made" $ do
    fake ← newFake defaultFakeConfig
    probe ← newProbe
    raiseFromReady probe (toException (userError "the pipeline's sink raised"))
    outcome ← try @SomeException . withRigUnchecked fake $ \rig → do
      _ ← submit rig probe 2 2 255
      -- 'sinkReady' recorded the texture and then raised: the job is failed, and it answers once more.
      awaitEvents probe (any (\event → case event of SeFailed text → "sink raised" `Text.isInfixOf` text; _ → False))
      awaitBackend rig ((== 0) . readingJobs)
      awaitBackend rig (null . readingTextureStages)
      -- An ordinary failure of one job's sink is that job's: the backend stays open for the next.
      readingOpen <$> readingNow rig >>= (`shouldBe` True)
    scopeRaised outcome
    problems ← atomically (leaked fake)
    problems `shouldBe` []

  it "does not swallow a cancellation of the pump that arrives inside the offer: the pump ends, and every job is told" $ do
    fake ← newFake defaultFakeConfig
    probe ← newProbe
    raiseFromReady probe (toException ThreadKilled)
    outcome ← try @SomeException . withRigUnchecked fake $ \rig → do
      _ ← submit rig probe 2 2 255
      awaitEvents probe (any (\event → case event of SeFailed _ → True; _ → False))
      -- The pump ended (it abandoned everything and closed admission); it did not carry on as if nothing had come.
      awaitBackend rig (not . readingOpen)
      reading ← readingNow rig
      readingFailed reading `shouldBe` True
    scopeRaised outcome

  it "latches a terminal event the sink raised on, and drops the job" $ do
    fake ← newFake defaultFakeConfig
    probe ← newProbe
    raiseFromTerminal probe (toException (userError "the pipeline's terminal raised"))
    outcome ← try @SomeException . withRigUnchecked fake $ \rig → do
      setStanding fake (Ended "gone")
      _ ← submit rig probe 2 2 255
      _ ← awaitTerminal probe
      awaitBackend rig ((== 0) . readingJobs)
      reading ← readingNow rig
      readingFailed reading `shouldBe` True
    scopeRaised outcome

  it "does not swallow a cancellation of the pump that arrives inside a terminal event" $ do
    fake ← newFake defaultFakeConfig
    probe ← newProbe
    raiseFromTerminal probe (toException ThreadKilled)
    outcome ← try @SomeException . withRigUnchecked fake $ \rig → do
      setStanding fake (Ended "gone")
      _ ← submit rig probe 2 2 255
      _ ← awaitTerminal probe
      awaitBackend rig readingFailed
      awaitBackend rig (not . readingOpen)
    scopeRaised outcome
  it "drains a texture the version of a batch still holds even when the body raised, and raises the body's failure" $ do
    fake ← newFake defaultFakeConfig
    withFakeOwner fake . bounded $ do
      forked ← forkScope $
        ( withBackendOnRaw fake $ \rig → do
            probe ← newProbe
            _ ← submit rig probe 2 2 255
            _ ← awaitTerminal probe
            hold fake HoldReclaim
            setVersionHolders fake 1
            throwIO (userError "the body failed")
        )
          `finally` noteEvent fake "scope left"
      awaitEvent fake "released"
      noteEvent fake "evidence supplied"
      setVersionHolders fake 0
      release fake HoldReclaim
      forkedJoin forked >>= \case
        Left failure
          | "the body failed" `Text.isInfixOf` Text.pack (show failure) → pure ()
          | otherwise → expectationFailure ("expected the body's failure, found " <> show failure)
        Right () → expectationFailure "the scope returned normally although its body raised"
      -- The body's failure left the scope through the drain: the evidence was in before it did, the texture retired.
      assertBefore fake "evidence supplied" "scope left"
      problems ← atomically (leaked fake)
      problems `shouldBe` []

  it "still releases and drains when marking a texture released raises at the close, and latches it" $ do
    fake ← newFake defaultFakeConfig
    outcome ← try @SomeException . withFakeOwner fake . bounded . withBackendOnRaw fake $ \rig → do
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      _ ← awaitTerminal probe
      inject fake RaiseMark
    scopeRaised outcome
    eventCount fake "release attempted" `shouldReturn` 1
    problems ← atomically (leaked fake)
    problems `shouldBe` []

  it "waits for the table's evidence of a cancelled registration's retirement without asking again until the owner progresses" $ do
    fake ← newFake defaultFakeConfig
    -- However the example ends, the batch's version ends too: the scope's drain waits for it.
    withRigUnchecked fake $ \rig → (`finally` setVersionHolders fake 0) $ do
      hold fake HoldRegister
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitPhase rig "registering"
      awaitFake fake ((== 0) . readingActsQueued)
      -- From here the owner runs only what the example grants, one action at a time.
      hold fake HoldOwner
      hold fake HoldReclaim
      baseline ← eventCount fake "table read"
      setVersionHolders fake 1
      uploadCancel work
      release fake HoldRegister
      awaitFake fake ((== 1) . readingActsQueued)
      grantOwner fake 1
      awaitEvent fake "released"
      -- The release ran; the job asks the table once, whether its slot is still mapped by a batch's version.
      awaitFake fake ((== 1) . readingActsQueued)
      grantOwner fake 1
      -- The answer says it is. A second job is a barrier in the pump's order: the pump takes the first job's step
      -- before it looks at this one, so when this one has been given its allocation the first has nothing more to
      -- do. A first job that asked again, wake or no wake, has queued that ask before it.
      other ← newProbe
      _ ← submit rig other 2 2 255
      awaitBackend rig (elem "allocating" . readingJobPhases)
      queued ← atomically (readingActsQueued <$> readFake fake)
      queued `shouldBe` 1
      eventCount fake "table read" `shouldReturn` baseline + 1
      -- The owner's progress is what lets it ask again: the batch's version ends, and the retirement is proved.
      setVersionHolders fake 0
      release fake HoldReclaim
      release fake HoldOwner
      _ ← awaitTerminal probe
      pure ()

  it "ends a retirement wait with the owner's end although no progress follows it" $ do
    fake ← newFake defaultFakeConfig
    outcome ← try @SomeException . withRigUnchecked fake $ \rig → (`finally` setVersionHolders fake 0) $ do
      hold fake HoldRegister
      probe ← newProbe
      work ← submit rig probe 2 2 255
      awaitPhase rig "registering"
      awaitFake fake ((== 0) . readingActsQueued)
      hold fake HoldOwner
      hold fake HoldReclaim
      baseline ← eventCount fake "table read"
      setVersionHolders fake 1
      uploadCancel work
      release fake HoldRegister
      awaitFake fake ((== 1) . readingActsQueued)
      grantOwner fake 1
      awaitEvent fake "released"
      awaitFake fake ((== 1) . readingActsQueued)
      grantOwner fake 1
      awaitEventCount fake "table read" (baseline + 1)
      -- The job waits for evidence nobody will now produce: the owner is gone, and gone without any change of the
      -- model a wake watches.
      endOwner fake "the device was lost"
      _ ← awaitTerminal probe
      awaitBackend rig ((== 0) . readingJobs)
    -- A retirement nobody could prove is the scope's failure: nothing is reported reclaimed.
    scopeRaised outcome

  it "waits for the table's evidence of a released texture's retirement without asking again until the owner progresses" $ do
    fake ← newFake defaultFakeConfig
    withRigUnchecked fake $ \rig → (`finally` setVersionHolders fake 0) $ do
      first ← newProbe
      _ ← submit rig first 2 2 255
      _ ← awaitTerminal first
      keeper ← delivered first
      second ← newProbe
      _ ← submit rig second 2 2 255
      _ ← awaitTerminal second
      barrier ← delivered second
      hold fake HoldOwner
      hold fake HoldReclaim
      setVersionHolders fake 1
      baseline ← eventCount fake "table read"
      _ ← textureRelease keeper
      awaitFake fake ((== 1) . readingReleasesQueued)
      grantOwner fake 1
      awaitEvent fake "released"
      awaitFake fake ((== 1) . readingActsQueued)
      grantOwner fake 1
      awaitEventCount fake "table read" (baseline + 1)
      -- The answer says a batch's version still maps the slot. A second texture released now is a barrier in the
      -- pump's order (textures are taken in the order they were made): when its release is queued, the first
      -- texture has nothing more to do. One that asked again, wake or no wake, has queued that ask before it.
      _ ← textureRelease barrier
      awaitFake fake ((== 1) . readingReleasesQueued)
      queued ← atomically (readingActsQueued <$> readFake fake)
      queued `shouldBe` 0
      eventCount fake "table read" `shouldReturn` baseline + 1
      setVersionHolders fake 0
      release fake HoldReclaim
      release fake HoldOwner

  where
    -- The scope itself failed, with the backend's failure: not the example's own assertion.
    scopeRaised = \case
      Right () → expectationFailure "the scope returned although the backend had latched a failure"
      Left failure
        | Just (HUnitFailure _ _) ← fromException failure → expectationFailure ("the example failed instead of the scope: " <> show failure)
        | otherwise → pure ()
    scopeFailedWith needle = \case
      Right () → expectationFailure "the wait returned although it should have failed"
      Left failure
        | needle `Text.isInfixOf` Text.pack (show failure) → pure ()
        | otherwise → expectationFailure ("expected a failure about " <> Text.unpack needle <> ", found " <> show failure)
