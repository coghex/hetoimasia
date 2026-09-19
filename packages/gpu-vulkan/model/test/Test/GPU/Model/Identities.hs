-- | Typed identities, and the misuse answers that reject a stale, foreign,
-- duplicated or already-consumed one.
--
-- Every example here also asserts that the model is unchanged afterwards. That
-- is the point of the contract: a rejected call is not a partially applied one,
-- so the answer and the state can never disagree about whether something
-- happened.
module Test.GPU.Model.Identities (spec) where

import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Identity
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe, shouldSatisfy)

spec ∷ Spec
spec = describe "identities" $ do
  it "issues a distinct identity for every record a session makes" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (framed, frame) ← acquiredFrame target resourced
    (recordedBatch, batch) ← admitted "recording" (recordBatch frame [resource] framed)
    (submittedFrame, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted recordedBatch)
    submission ← submissionOf submitAnswer
    (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submittedFrame)
    presentation ← presentationOf presentAnswer

    -- Each identity names the record it belongs to, and each is anchored in the
    -- one above it, so nothing can be read as belonging to another target.
    generationTarget generation `shouldBe` target
    frameTarget frame `shouldBe` target
    batchTarget batch `shouldBe` target
    presentationTarget presentation `shouldBe` target
    submissionSession submission `shouldBe` modelSessionIdentity presented
    resourceSession resource `shouldBe` modelSessionIdentity presented
    deviceSession (modelDeviceId presented) `shouldBe` modelSessionIdentity presented
    targetIncarnation target `shouldBe` 1
    frameUse frame `shouldBe` 1

  it "rejects another session's target as foreign and changes nothing" $ do
    mine ← freshModel
    theirs ← freshModel
    (_, foreign', _) ← activeTarget 2 theirs
    rejected "reserving a frame of another session's target" (reserveFrame foreign' mine)
      `shouldReturn'` ForeignIdentity TargetIdentity
    outcomeModel (reserveFrame foreign' mine) `shouldBe` Rejected (ForeignIdentity TargetIdentity)

  it "rejects another session's resource, submission and allocation as foreign" $ do
    mine ← freshModel
    theirs ← freshModel
    (active, target, _) ← activeTarget 2 mine
    (framed, frame) ← acquiredFrame target active
    (theirResourced, theirResource) ← aResource 1024 theirs
    (theirFramed, theirTarget, _) ← activeTarget 2 theirResourced
    (theirAcquired, theirFrame) ← acquiredFrame theirTarget theirFramed
    (theirSubmitted, theirAnswer) ← admitted "their submission" (submitFrames [theirFrame] SubmissionAccepted theirAcquired)
    theirSubmission ← submissionOf theirAnswer
    (_, theirAllocation) ← admitted "their allocation" (beginAllocation 1 1 theirSubmitted)

    rejected "recording another session's resource" (recordBatch frame [theirResource] framed)
      `shouldReturn'` ForeignIdentity ResourceIdentity
    rejected_ "completing another session's submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted theirSubmission) framed)
      `shouldReturn'` ForeignIdentity SubmissionIdentity
    rejected "retrying another session's allocation" (retryAllocation theirAllocation framed)
      `shouldReturn'` ForeignIdentity AllocationIdentity

  it "names the identity it was handed, not the parent it resolved through" $ do
    mine ← freshModel
    theirs ← freshModel
    (active, target, generation) ← activeTarget 2 theirs
    (framed, frame) ← acquiredFrame target active
    (resourced, resource) ← aResource 1024 framed
    (recordedBatch, batch) ← admitted "recording" (recordBatch frame [resource] resourced)
    (submitted, _) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted recordedBatch)
    (_, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
    presentation ← presentationOf presentAnswer

    -- Each of these resolves through its target, and each is foreign to this
    -- model. Reporting the parent's kind would describe a value the caller never
    -- passed, and would read as though a target had been supplied.
    rejected "publishing another session's generation" (publishGeneration generation 2 mine)
      `shouldReturn'` ForeignIdentity GenerationIdentity
    rejected_ "resetting another session's recorder" (resetRecorder frame mine)
      `shouldReturn'` ForeignIdentity FrameIdentity
    rejected_ "discarding another session's batch" (discardBatch batch mine)
      `shouldReturn'` ForeignIdentity BatchIdentity
    rejected_ "retiring another session's presentation" (recordCompletion (atMilliseconds 1) (PresentationRetired presentation) mine)
      `shouldReturn'` ForeignIdentity PresentationIdentity

  it "calls a generation offered to a target that does not own it a wrong parent, not a foreigner" $ do
    model ← freshModel
    (first, one, generationOfOne) ← activeTarget 2 model
    (both, two, _) ← activeTarget 2 first

    -- Both identities are this model's, so nothing here is foreign: the mistake
    -- is the association between them.
    rejected "handing one target's generation to another" (beginGeneration two (Just generationOfOne) both)
      `shouldReturn'` WrongParent GenerationIdentity
    -- And it changed nothing: the generation is still the first target's active
    -- one, and the second target has gained no construction.
    fmap viewTargetActive (targetView one both) `shouldBe` Just (Just generationOfOne)
    fmap viewTargetGenerations (targetView two both) `shouldBe` Just 1

  it "rejects an identity for a target whose number has been reissued" $ do
    model ← freshModel
    (withTarget, first) ← admitted "admitting" (admitTarget OptionalTarget model)
    closed ← admitted_ "closing" (closeTarget first withTarget)
    let (forgotten, _) = runProgressTurn silentEvidence (atMilliseconds 1) closed
    targetView first forgotten `shouldBe` Nothing

    (readmitted, second) ← admitted "readmitting" (admitTarget OptionalTarget forgotten)
    -- The number came back; the incarnation did not.
    targetNumber second `shouldBe` targetNumber first
    targetIncarnation second `shouldBe` targetIncarnation first + 1
    second `shouldNotBe` first
    rejected "reserving a frame of the retired incarnation" (reserveFrame first readmitted)
      `shouldReturn'` StaleIdentity TargetIdentity

  it "rejects a generation identity once that generation has been disposed of" $ do
    model ← freshModel
    (active, _, generation) ← activeTarget 2 model
    retired ← admitted_ "retiring" (retireGeneration generation active)
    ended ← admitted_ "ending CPU use" (endGenerationCpuUse generation retired)
    disposalEligible (GenerationSubject generation) ended `shouldBe` True
    let (reclaimed, report) = reclaimPass (silentEvidence {disposalEvidence = const DisposalCompleted}) ended
    reclaimDisposed report `shouldBe` [GenerationSubject generation]
    rejected_ "ending CPU use on a disposed generation" (endGenerationCpuUse generation reclaimed)
      `shouldReturn'` StaleIdentity GenerationIdentity

  it "rejects a second settlement of a batch, a submission and a presentation record" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (framedOne, frameOne) ← acquiredFrame target resourced
    (recordedBatch, batch) ← admitted "recording" (recordBatch frameOne [resource] framedOne)
    dropped ← admitted_ "discarding" (discardBatch batch recordedBatch)
    rejected_ "discarding the same batch twice" (discardBatch batch dropped)
      `shouldReturn'` AlreadyConsumed BatchIdentity

    (submittedFrame, submitAnswer) ← admitted "submitting" (submitFrames [frameOne] SubmissionAccepted dropped)
    submission ← submissionOf submitAnswer
    (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frameOne PresentationEnqueued submittedFrame)
    presentation ← presentationOf presentAnswer
    completed ← admitted_ "completing" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) presented)
    rejected_ "completing the same submission twice" (recordCompletion (atMilliseconds 2) (SubmissionCompleted submission) completed)
      `shouldReturn'` AlreadyConsumed SubmissionIdentity

    settled ← admitted_ "retiring the presentation" (recordCompletion (atMilliseconds 3) (PresentationRetired presentation) completed)
    rejected_ "retiring the same presentation twice" (recordCompletion (atMilliseconds 4) (PresentationRetired presentation) settled)
      `shouldReturn'` AlreadyConsumed PresentationIdentity

  it "rejects a duplicated subject in one call, and an empty submission, before any effect" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (framed, frame) ← acquiredFrame target resourced

    outcomeModel (recordBatch frame [resource, resource] framed)
      `shouldBe` Rejected (DuplicateSubject ResourceIdentity)
    outcomeModel (submitFrames [frame, frame] SubmissionAccepted framed)
      `shouldBe` Rejected (DuplicateSubject FrameIdentity)
    outcomeModel (submitFrames [] SubmissionAccepted framed) `shouldBe` Rejected EmptySubmission
    -- Nothing was recorded, nothing was submitted, and the frame is where it was.
    fmap viewFramePhase (frameView frame framed) `shouldBe` Just FrameAcquired
    usageBatches (usage framed) `shouldBe` 0
    usageSubmissions (usage framed) `shouldBe` 0

  it "rejects an image index the tracked generation does not carry" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (reserved, frame) ← admitted "reserving" (reserveFrame target active)
    outcomeModel (acquireImage frame (AcquiredImage 2) reserved)
      `shouldBe` Rejected (UnknownIdentity ImageIdentity)
    -- The frame is still reserved and still holds its pool record.
    fmap viewFramePhase (frameView frame reserved) `shouldBe` Just FrameReserved

  it "rejects every admission once the session has failed, and says so as misuse" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    let failed = escalateSession ValidationError active
    sessionState failed `shouldBe` SessionFailed ValidationError
    escalations failed `shouldSatisfy` elem (SessionEscalated ValidationError)
    rejected "reserving a frame after the session failed" (reserveFrame target failed)
      `shouldReturn'` SessionAlreadyFailed
    rejected "admitting a target after the session failed" (admitTarget RequiredTarget failed)
      `shouldReturn'` SessionAlreadyFailed
    rejected "reserving an allocation after the session failed" (beginAllocation 1 1 failed)
      `shouldReturn'` SessionAlreadyFailed
  where
    shouldReturn' action expected = action >>= (`shouldBe` expected)
    submissionOf = \case
      SubmissionRecorded identity → pure identity
      other → fail ("expected a submission record, got " ++ show other)
    presentationOf = \case
      PresentationTracked identity → pure identity
      other → fail ("expected a presentation record, got " ++ show other)
