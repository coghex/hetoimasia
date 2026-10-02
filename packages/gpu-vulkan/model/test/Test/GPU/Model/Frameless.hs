-- | Frame-less batches (GRS-12): admission into the session's frame-less
-- slots under their own budget, the objects reserved before any native call,
-- holds discharged exactly by discard, reset, submission and completion, the
-- slot freed only by a discard or a completion, identities resolved without
-- any target, initialization published only by an accepted submission, and
-- release on device loss without completion.
module Test.GPU.Model.Frameless (spec) where

import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Access (Contents (..))
import Hetoimasia.GPU.Model.Budget
import Hetoimasia.GPU.Model.Identity
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "frame-less batches" $ do
  describe "admission and its budget" $ do
    it "defaults the budget to four and validates it like every other, never clamping it" $ do
      fmap framelessBatchLimit (validateBudgets defaultBudgetRequest) `shouldBe` Right 4
      validateBudgets defaultBudgetRequest {requestedFramelessBatches = 0}
        `shouldBe` Left (BudgetNotPositive FramelessBatchBudget 0)
      validateBudgets defaultBudgetRequest {requestedFramelessBatches = -3}
        `shouldBe` Left (BudgetNotPositive FramelessBatchBudget (-3))
      validateBudgets defaultBudgetRequest {requestedFramelessBatches = budgetCeiling + 1}
        `shouldBe` Left (BudgetAboveCeiling FramelessBatchBudget (budgetCeiling + 1))

    it "admits batches that belong to no frame, in the lowest free slots, up to the budget, then answers backpressure naming it" $ do
      model ← freshModelWith defaultBudgetRequest {requestedFramelessBatches = 2}
      (one, (first, firstSlot)) ← admitted "the first" (openFramelessBatch [] model)
      (two, (second, secondSlot)) ← admitted "the second" (openFramelessBatch [] one)
      (firstSlot, secondSlot) `shouldBe` (0, 1)
      (batchTarget first, batchTarget second) `shouldBe` (Nothing, Nothing)
      batchSession first `shouldBe` modelSessionIdentity model
      backpressured "a third" (openFramelessBatch [] two) >>= (`shouldBe` FramelessBatchBudget)
      usageFramelessSlots (usage two) `shouldBe` 2
      framelessSlots two `shouldBe` [(0, FramelessRecording first), (1, FramelessRecording second)]

    it "admits a frame-less batch in a session with no target at all, and refuses one once the session has failed" $ do
      model ← freshModel
      _ ← admitted "with no target" (openFramelessBatch [] model)
      rejected "after failure" (openFramelessBatch [] (escalateSession DeviceLost model)) >>= (`shouldBe` SessionAlreadyFailed)

    it "reserves the batch's record and its submission's before any native call, answering object backpressure with nothing changed" $ do
      model ← freshModelWith defaultBudgetRequest {requestedObjects = 3}
      (opened, _) ← admitted "a batch" (openFramelessBatch [] model)
      usageObjects (usage opened) `shouldBe` 2
      backpressured "a second" (openFramelessBatch [] opened) >>= (`shouldBe` ObjectBudget)
      usageFramelessSlots (usage opened) `shouldBe` 1

    it "gives back both reserved objects on a discard, one on submission and the other on completion" $ do
      model ← freshModel
      let base = usageObjects (usage model)
      (opened, (batch, _)) ← admitted "a batch" (openFramelessBatch [] model)
      discarded ← admitted_ "a discard" (discardBatch batch opened)
      usageObjects (usage discarded) `shouldBe` base
      (again, (other, _)) ← admitted "another" (openFramelessBatch [] discarded)
      (submitted, submission) ← submittedAs other again
      usageObjects (usage submitted) `shouldBe` base + 1
      completed ← admitted_ "the completion" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) submitted)
      usageObjects (usage completed) `shouldBe` base

  describe "holds" $ do
    it "discharges exactly a batch's own references on discard, reset, submission and completion" $ do
      model ← freshModel
      (active, target, _) ← activeTarget 2 model
      (framed, frame) ← acquiredFrame target active
      (withShared, shared) ← aResource 64 framed
      (withOwn, own) ← aResource 64 withShared
      -- A frame batch and two frame-less ones share a resource.
      (recorded, frameBatch) ← admitted "the frame batch" (recordBatch frame [shared] withOwn)
      (opened, (discarding, _)) ← admitted "a frame-less batch to discard" (openFramelessBatch [shared] recorded)
      (both, (submitting, _)) ← admitted "a frame-less batch to submit" (openFramelessBatch [shared, own] opened)
      recordedOn both shared `shouldBe` [frameBatch, discarding, submitting]
      discarded ← admitted_ "the discard" (discardBatch discarding both)
      recordedOn discarded shared `shouldBe` [frameBatch, submitting]
      reset ← admitted_ "the frame's reset" (resetRecorder frame discarded)
      recordedOn reset shared `shouldBe` [submitting]
      (submitted, submission) ← submittedAs submitting reset
      (recordedOn submitted shared, recordedOn submitted own) `shouldBe` ([], [])
      (submittedOn submitted shared, submittedOn submitted own) `shouldBe` ([submission], [submission])
      completed ← admitted_ "the completion" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) submitted)
      (submittedOn completed shared, submittedOn completed own) `shouldBe` ([], [])

    it "gives each frame-less submission a record of its own that carries no frame" $ do
      model ← freshModel
      (one, (first, _)) ← admitted "the first" (openFramelessBatch [] model)
      (two, (second, _)) ← admitted "the second" (openFramelessBatch [] one)
      (firstDone, a) ← submittedAs first two
      (secondDone, b) ← submittedAs second firstDone
      a `shouldSatisfy` (/= b)
      (submissionCarries a first secondDone, submissionCarries a second secondDone) `shouldBe` (Just True, Just False)
      usageSubmissions (usage secondDone) `shouldBe` 2

  describe "slots" $ do
    it "keeps a submitted batch's slot until its completion is recorded, and a discarded one's not at all" $ do
      model ← freshModelWith defaultBudgetRequest {requestedFramelessBatches = 1}
      (opened, (batch, slot)) ← admitted "a batch" (openFramelessBatch [] model)
      (submitted, submission) ← submittedAs batch opened
      framelessSlots submitted `shouldBe` [(slot, FramelessSubmitted submission)]
      backpressured "a second before completion" (openFramelessBatch [] submitted) >>= (`shouldBe` FramelessBatchBudget)
      completed ← admitted_ "the completion" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) submitted)
      framelessSlots completed `shouldBe` []
      (reopened, (other, reused)) ← admitted "the slot again" (openFramelessBatch [] completed)
      reused `shouldBe` slot
      other `shouldSatisfy` (/= batch)
      discarded ← admitted_ "a discard" (discardBatch other reopened)
      framelessSlots discarded `shouldBe` []

    it "keeps the batch held and its slot taken after a no-effect failure, and records it on the retry" $ do
      model ← freshModel
      (opened, (batch, slot)) ← admitted "a batch" (openFramelessBatch [] model)
      (failed, answer) ← admitted "a no-effect failure" (submitFramelessBatch batch SubmissionFailedWithoutEffect opened)
      answer `shouldBe` AcquisitionRetained
      framelessSlots failed `shouldBe` [(slot, FramelessRecording batch)]
      (retried, submission) ← submittedAs batch failed
      framelessSlots retried `shouldBe` [(slot, FramelessSubmitted submission)]

    it "retains an uncertain submission's slot and holds for ever, and fails the session" $ do
      model ← freshModel
      (withResource, resource) ← aResource 64 model
      (opened, (batch, slot)) ← admitted "a batch" (openFramelessBatch [resource] withResource)
      (uncertain, answer) ← admitted "an unknown effect" (submitFramelessBatch batch SubmissionEffectUncertain opened)
      answer `shouldBe` EffectUncertain
      sessionState uncertain `shouldBe` SessionFailed UnknownSubmissionEffect
      case framelessSlots uncertain of
        [(held, FramelessSubmitted submission)] → do
          held `shouldBe` slot
          submittedOn uncertain resource `shouldBe` [submission]
          rejected_ "its completion" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) uncertain)
            >>= (`shouldBe` WrongPhase SubmissionIdentity)
        other → expectationFailure ("the slots were " <> show other)

    it "completes a ready frame-less submission in a one-action turn even behind one that has not signalled" $ do
      model ← freshModelWith defaultBudgetRequest {requestedProgressActions = 1}
      (one, (first, _)) ← admitted "the first" (openFramelessBatch [] model)
      (two, (second, _)) ← admitted "the second" (openFramelessBatch [] one)
      (firstDone, stalled) ← submittedAs first two
      (secondDone, ready) ← submittedAs second firstDone
      let source = silentEvidence {submissionEvidence = (== ready)}
          (after, report) = runProgressTurn source (atMilliseconds 1) secondDone
      turnFacts report `shouldBe` 1
      framelessSlots after `shouldBe` [(0, FramelessSubmitted stalled)]

  describe "identities" $ do
    it "resolves a frame-less batch through its session alone, refusing a stranger's, a consumed one and a frame batch" $ do
      model ← freshModel
      other ← freshModel
      (active, target, _) ← activeTarget 2 model
      (framed, frame) ← acquiredFrame target active
      (recorded, frameBatch) ← admitted "a frame batch" (recordBatch frame [] framed)
      (opened, (batch, _)) ← admitted "a frame-less batch" (openFramelessBatch [] recorded)
      (_, (stranger, _)) ← admitted "another session's" (openFramelessBatch [] other)
      rejected_ "a stranger's discard" (discardBatch stranger opened) >>= (`shouldBe` ForeignIdentity BatchIdentity)
      rejected "a frame batch submitted as frame-less" (submitFramelessBatch frameBatch SubmissionAccepted opened) >>= (`shouldBe` WrongParent BatchIdentity)
      discarded ← admitted_ "the discard" (discardBatch batch opened)
      rejected_ "a second discard" (discardBatch batch discarded) >>= (`shouldBe` AlreadyConsumed BatchIdentity)
      rejected "a consumed submission" (submitFramelessBatch batch SubmissionAccepted discarded) >>= (`shouldBe` AlreadyConsumed BatchIdentity)

    it "extends a frame-less batch's references exactly as a frame batch's" $ do
      model ← freshModel
      (withResource, resource) ← aResource 64 model
      (opened, (batch, _)) ← admitted "a batch" (openFramelessBatch [] withResource)
      extended ← admitted_ "an extension" (extendBatch batch [resource] opened)
      recordedOn extended resource `shouldBe` [batch]

  describe "initialization" $ do
    it "publishes a frame-less batch's initialization only on its accepted submission, before completion, never on a discard or a no-effect failure" $ do
      model ← freshModel
      (withImage, image) ← aResource 64 model
      awaiting ← admitted_ "requiring initialization" (requireInitialization image withImage)
      let initializing current = do
            (opened, (batch, _)) ← admitted "an initializing batch" (openFramelessBatch [image] current)
            entered ← admitted_ "its first touch" (enterResource batch image DiscardsContents opened)
            pure (entered, batch)
      (first, discarding) ← initializing awaiting
      resourceInitialization image first `shouldBe` Just (InitializingIn discarding)
      discarded ← admitted_ "the discard" (discardBatch discarding first)
      resourceInitialization image discarded `shouldBe` Just Uninitialized
      (second, batch) ← initializing discarded
      (failed, _) ← admitted "a no-effect failure" (submitFramelessBatch batch SubmissionFailedWithoutEffect second)
      resourceInitialization image failed `shouldBe` Just (InitializingIn batch)
      (submitted, _) ← submittedAs batch failed
      resourceInitialization image submitted `shouldBe` Just Initialized
      -- A later batch may use it before that submission completes.
      (later, (user, _)) ← admitted "a later batch" (openFramelessBatch [image] submitted)
      _ ← admitted_ "its use" (enterResource user image KeepsContents later)
      pure ()

  describe "device loss" $ do
    it "releases frame-less submissions and frees their slots without recording any completion, leaving unsubmitted batches to be discarded" $ do
      model ← freshModel
      (withResource, resource) ← aResource 64 model
      (one, (submittedBatch, _)) ← admitted "a batch" (openFramelessBatch [resource] withResource)
      (two, (unsubmitted, waiting)) ← admitted "an unsubmitted batch" (openFramelessBatch [resource] one)
      (submitted, submission) ← submittedAs submittedBatch two
      let lost = noteDeviceLoss submitted
      (released, report) ← admitted "the release" (releaseToDeviceLoss lost)
      releasedSubmissions report `shouldBe` [submission]
      submittedOn released resource `shouldBe` []
      framelessSlots released `shouldBe` [(waiting, FramelessRecording unsubmitted)]
      -- Released, never completed: the record is gone, not completed.
      rejected_ "a completion after the release" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) released)
        >>= (`shouldBe` AlreadyConsumed SubmissionIdentity)
      discarded ← admitted_ "the unsubmitted batch's discard" (discardBatch unsubmitted released)
      (framelessSlots discarded, recordedOn discarded resource) `shouldBe` ([], [])
  where
    recordedOn model resource = maybe [] viewRecorded (holdView (ResourceSubject resource) model)
    submittedOn model resource = maybe [] viewSubmitted (holdView (ResourceSubject resource) model)

-- | Submit a frame-less batch, accepted, answering its submission.
submittedAs ∷ BatchId → GpuModel → IO (GpuModel, SubmissionId)
submittedAs batch model =
  admitted "the submission" (submitFramelessBatch batch SubmissionAccepted model) >>= \case
    (next, SubmissionRecorded submission) → pure (next, submission)
    (_, other) → fail ("the submission answered " <> show other)
