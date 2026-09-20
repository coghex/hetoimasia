-- | Frame ownership: what each phase retains, and which exits are legal from
-- it.
--
-- The distinctions these examples draw are the ones that lose synchronization
-- obligations when they are collapsed: a not-ready acquisition against a
-- suboptimal one, a skipped unsubmitted frame against a submitted one closed
-- before presentation, and a submission that had no effect against one whose
-- effect is unknown.
module Test.GPU.Model.Frames (spec) where

import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget (BudgetRequest (requestedImageTracking), defaultBudgetRequest)
import Hetoimasia.GPU.Model.Identity
import Numeric.Natural (Natural)
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "frame ownership" $ do
  it "returns a not-ready acquisition's reservation whole, creating no image and no obligation" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (reserved, frame) ← admitted "reserving" (reserveFrame target active)
    poolRecords target reserved `shouldBe` 1

    (returned, answer) ← admitted "acquiring" (acquireImage frame AcquireNotReady reserved)
    answer `shouldBe` ReservationReturned
    -- The slot, the pool record and the object it charged all went back, and the
    -- generation was never given an obligation to discharge.
    frameView frame returned `shouldBe` Nothing
    poolRecords target returned `shouldBe` 0
    usageObjects (usage returned) `shouldBe` usageObjects (usage active)
    fmap viewOutstanding (holdView (GenerationSubject generation) returned)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]

  it "keeps a suboptimal acquisition's image and asks for a replacement beside it" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (reserved, frame) ← admitted "reserving" (reserveFrame target active)
    (acquired, answer) ← admitted "acquiring" (acquireImage frame (AcquiredSuboptimalImage 1) reserved)
    case answer of
      ImageOwned image suboptimal → do
        suboptimal `shouldBe` True
        imageIndex image `shouldBe` 1
        imageGeneration image `shouldBe` generation
      other → fail ("a suboptimal acquisition should own its image, but the answer was " ++ show other)

    fmap viewFramePhase (frameView frame acquired) `shouldBe` Just FrameAcquired
    fmap viewFrameSuboptimal (frameView frame acquired) `shouldBe` Just True
    fmap viewTargetReplacementRequested (targetView target acquired) `shouldBe` Just True
    -- The image index is never discarded, and the frame can still be finished.
    (submitted, _) ← admitted "submitting the suboptimal frame" (submitFrames [frame] SubmissionAccepted acquired)
    fmap viewFramePhase (frameView frame submitted) `shouldBe` Just FrameSubmitted

  it "creates no acquisition obligation for an out-of-date result and leaves older ones alone" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (older, olderFrame) ← acquiredFrame target active
    (submitted, _) ← admitted "submitting the older frame" (submitFrames [olderFrame] SubmissionAccepted older)
    (reserved, frame) ← admitted "reserving" (reserveFrame target submitted)
    (answered, answer) ← admitted "acquiring" (acquireImage frame AcquireOutOfDate reserved)

    answer `shouldBe` ReplacementRequested
    frameView frame answered `shouldBe` Nothing
    fmap viewTargetReplacementRequested (targetView target answered) `shouldBe` Just True
    -- The frame that was already submitted still owns everything it owned.
    fmap viewFramePhase (frameView olderFrame answered) `shouldBe` Just FrameSubmitted

  it "keeps a skipped unsubmitted frame's image obligation until settlement evidence arrives" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (framed, frame) ← acquiredFrame target resourced
    (recordedBatch, _) ← admitted "recording" (recordBatch frame [resource] framed)

    skipped ← admitted_ "skipping" (skipUnsubmittedFrame frame recordedBatch)
    fmap viewFramePhase (frameView frame skipped) `shouldBe` Just FrameRetiring
    -- The unsubmitted recording went; the image and its synchronization did not,
    -- and the pool record is still held against them.
    fmap viewRecorded (holdView (ResourceSubject resource) skipped) `shouldBe` Just []
    fmap viewOutstanding (holdView (GenerationSubject generation) skipped)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed, PresentationObligationOwed]
    poolRecords target skipped `shouldBe` 1
    usageSubmissions (usage skipped) `shouldBe` 0

    settled ← admitted_ "settling" (recordCompletion (atMilliseconds 1) (UnpresentedFrameSettled frame) skipped)
    frameView frame settled `shouldBe` Nothing
    poolRecords target settled `shouldBe` 0
    fmap viewOutstanding (holdView (GenerationSubject generation) settled)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]

  it "keeps both obligations of a submitted frame closed before presentation, and settles each on its own evidence" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    (submitted, answer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    submission ← submissionOf answer
    closed ← admitted_ "closing before presentation" (closeSubmittedFrame frame submitted)

    fmap viewFramePhase (frameView frame closed) `shouldBe` Just FrameRetiring
    -- This is not a skip: the submission happened and is still owed.
    fmap viewOutstanding (holdView (GenerationSubject generation) closed)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed, SubmittedUseOwed, PresentationObligationOwed]

    settled ← admitted_ "settling the image" (recordCompletion (atMilliseconds 1) (UnpresentedFrameSettled frame) closed)
    fmap viewOutstanding (holdView (GenerationSubject generation) settled)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed, SubmittedUseOwed]
    -- The frame is still here, because its own rendering has not completed.
    fmap viewFramePhase (frameView frame settled) `shouldBe` Just FrameRetiring

    completed ← admitted_ "completing the submission" (recordCompletion (atMilliseconds 2) (SubmissionCompleted submission) settled)
    frameView frame completed `shouldBe` Nothing
    fmap viewOutstanding (holdView (GenerationSubject generation) completed)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]

  it "leaves a no-effect submission failure owning its acquisition and pending nothing" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (framed, frame) ← acquiredFrame target resourced
    (recordedBatch, batch) ← admitted "recording" (recordBatch frame [resource] framed)
    fenced ← admitted_ "resetting the submission fence" (resetSubmissionFence frame recordedBatch)
    fmap viewFrameFenceReset (frameView frame fenced) `shouldBe` Just True

    (failed, answer) ← admitted "submitting" (submitFrames [frame] SubmissionFailedWithoutEffect fenced)
    answer `shouldBe` AcquisitionRetained
    sessionState failed `shouldBe` SessionRunning
    -- Nothing is pending: no submission record exists, and the fence that was
    -- reset is not evidence of work, so no drain may wait on it.
    usageSubmissions (usage failed) `shouldBe` 0
    fmap viewFrameFenceReset (frameView frame failed) `shouldBe` Just False
    fmap viewFrameSubmission (frameView frame failed) `shouldBe` Just Nothing
    -- The acquisition and its recording stay owned, and the frame may be
    -- finished or abandoned from where it is.
    fmap viewFramePhase (frameView frame failed) `shouldBe` Just FrameAcquired
    fmap viewRecorded (holdView (ResourceSubject resource) failed) `shouldBe` Just [batch]
    (retried, retryAnswer) ← admitted "resubmitting" (submitFrames [frame] SubmissionAccepted failed)
    retryAnswer `shouldSatisfy` \case
      SubmissionRecorded _ → True
      _ → False
    usageSubmissions (usage retried) `shouldBe` 1

  it "puts an uncertain-effect submission into a state that retains its parents and stops admission" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (framed, frame) ← acquiredFrame target resourced
    (recordedBatch, _) ← admitted "recording" (recordBatch frame [resource] framed)

    (uncertain, answer) ← admitted "submitting" (submitFrames [frame] SubmissionEffectUncertain recordedBatch)
    answer `shouldBe` EffectUncertain
    fmap viewFramePhase (frameView frame uncertain) `shouldBe` Just FrameUncertainEffect
    -- The record exists and is never discharged, so the parents it names can
    -- never become eligible for disposal.
    usageSubmissions (usage uncertain) `shouldBe` 1
    fmap viewOutstanding (holdView (ResourceSubject resource) uncertain)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed, SubmittedUseOwed]
    disposalEligible (GenerationSubject generation) uncertain `shouldBe` False

    -- It escalates to the session rather than to the target, and admission stops.
    sessionState uncertain `shouldBe` SessionFailed UnknownSubmissionEffect
    rejectedAs (reserveFrame target uncertain) SessionAlreadyFailed
    -- And the owner cannot talk its way out of it with a completion fact.
    let (worked, report) =
          runProgressTurn
            ( silentEvidence
                { submissionEvidence = const True
                , disposalEvidence = const DisposalCompleted
                }
            )
            (atMilliseconds 1)
            uncertain
    turnFacts report `shouldBe` 0
    usageSubmissions (usage worked) `shouldBe` 1
    disposalEligible (GenerationSubject generation) worked `shouldBe` False

  it "keeps the exact image on the record that outlives the frame, in either completion order" $ do
    let enqueued = do
          model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
          (active, target, generation) ← activeTarget 2 model
          (reserved, frame) ← admitted "reserving" (reserveFrame target active)
          (acquired, acquireAnswer) ← admitted "acquiring" (acquireImage frame (AcquiredImage 1) reserved)
          image ← case acquireAnswer of
            ImageOwned owned _ → pure owned
            other → fail ("the fixture should own an image, got " ++ show other)
          (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted acquired)
          submission ← submissionOf submitAnswer
          (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
          presentation ← presentationOf presentAnswer
          pure (presented, target, generation, frame, image, submission, presentation)

    -- The submission completes first, so the slot is reusable while the
    -- presentation is still owed. The image must not go with the slot: the
    -- record that outlives the frame is what still owns it.
    (presented, target, _, frame, image, submission, presentation) ← enqueued
    slotFree ← admitted_ "completing the submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) presented)
    frameView frame slotFree `shouldBe` Nothing
    presentationImage presentation slotFree `shouldBe` Just image

    -- A second frame may take the image while that record is still presenting
    -- it, and the record keeps naming it regardless.
    (reserved, other) ← admitted "reserving another frame" (reserveFrame target slotFree)
    (elsewhere, _) ← admitted "reacquiring the enqueued image" (acquireImage other (AcquiredImage 1) reserved)
    fmap viewFramePhase (frameView other elsewhere) `shouldBe` Just FrameAcquired
    fmap viewFrameImage (frameView other elsewhere) `shouldBe` Just (Just image)
    presentationImage presentation elsewhere `shouldBe` Just image

    -- Retirement is what ends the record, and it ends that record alone.
    retired ← admitted_ "retiring the presentation" (recordCompletion (atMilliseconds 2) (PresentationRetired presentation) elsewhere)
    presentationImage presentation retired `shouldBe` Nothing
    fmap viewFrameImage (frameView other retired) `shouldBe` Just (Just image)

    -- The other order: the presentation retires while the submission is still
    -- pending. The record goes, and the frame stays until its own work ends.
    (alsoPresented, _, otherGeneration, otherFrame, _, otherSubmission, otherPresentation) ← enqueued
    retiredFirst ←
      admitted_ "retiring the presentation first" (recordCompletion (atMilliseconds 1) (PresentationRetired otherPresentation) alsoPresented)
    presentationImage otherPresentation retiredFirst `shouldBe` Nothing
    fmap viewFramePhase (frameView otherFrame retiredFirst) `shouldBe` Just FramePresentationEnqueued
    completedLast ←
      admitted_ "completing the submission last" (recordCompletion (atMilliseconds 2) (SubmissionCompleted otherSubmission) retiredFirst)
    frameView otherFrame completedLast `shouldBe` Nothing
    fmap viewOutstanding (holdView (GenerationSubject otherGeneration) completedLast)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]

  it "admits a reacquisition of an image whose presentation is already enqueued" $ do
    -- The reported reproduction: publish two images, take image zero through an
    -- enqueued presentation, record only the submission's completion, and ask
    -- for image zero again from a second frame with its own pool record. P-2
    -- makes that legal — the second acquisition has its own synchronization, so
    -- nothing about it needs the older present fence to have retired.
    model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
    (active, target, generation) ← activeTarget 2 model
    (enqueued, first, image, submission, presentation) ← imageEnqueued target 0 PresentationEnqueued active
    completed ← admitted_ "completing the first submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) enqueued)
    frameView first completed `shouldBe` Nothing

    (reserved, second) ← admitted "reserving a second frame" (reserveFrame target completed)
    (reacquired, answer) ← admitted "reacquiring the enqueued image" (acquireImage second (AcquiredImage 0) reserved)
    answer `shouldBe` ImageOwned image False
    fmap viewFrameImage (frameView second reacquired) `shouldBe` Just (Just image)

    -- The older record is untouched: it still names the image, it is still one
    -- of the target's two live pool records, and the generation now owes two
    -- separate presentation obligations rather than one shared one.
    presentationImage presentation reacquired `shouldBe` Just image
    poolRecords target reacquired `shouldBe` 2
    fmap (length . viewPresentations) (holdView (GenerationSubject generation) reacquired) `shouldBe` Just 2
    fmap (elem presentation . viewPresentations) (holdView (GenerationSubject generation) reacquired) `shouldBe` Just True

  it "admits the reacquisition before the earlier submission's completion is recorded" $ do
    -- The completed submission above is a regression example, not a prerequisite:
    -- a free frame slot and a free pool record are the whole admission condition.
    model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
    (active, target, _) ← activeTarget 2 model
    (enqueued, first, image, submission, presentation) ← imageEnqueued target 0 PresentationEnqueued active
    fmap viewFramePhase (frameView first enqueued) `shouldBe` Just FramePresentationEnqueued

    (reserved, second) ← admitted "reserving a second frame" (reserveFrame target enqueued)
    (reacquired, answer) ← admitted "reacquiring before the old submission completed" (acquireImage second (AcquiredImage 0) reserved)
    answer `shouldBe` ImageOwned image False

    -- Neither older obligation was discharged by the acquisition.
    usageSubmissions (usage reacquired) `shouldBe` 1
    fmap viewFramePhase (frameView first reacquired) `shouldBe` Just FramePresentationEnqueued
    presentationImage presentation reacquired `shouldBe` Just image

    -- And each still settles on its own fact, in the order the owner observes it.
    completed ← admitted_ "completing the old submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) reacquired)
    frameView first completed `shouldBe` Nothing
    fmap viewFrameImage (frameView second completed) `shouldBe` Just (Just image)
    retired ← admitted_ "retiring the old presentation" (recordCompletion (atMilliseconds 2) (PresentationRetired presentation) completed)
    presentationImage presentation retired `shouldBe` Nothing
    fmap viewFramePhase (frameView second retired) `shouldBe` Just FrameAcquired

  it "settles the two uses of one image independently, in either retirement order" $ do
    let bothOwners = do
          model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
          (active, target, generation) ← activeTarget 2 model
          (enqueued, _, image, submission, presentation) ← imageEnqueued target 0 PresentationEnqueued active
          completed ← admitted_ "completing the first submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) enqueued)
          (second, newer, _, newerSubmission, newerPresentation) ← imageEnqueued target 0 PresentationEnqueued completed
          pure (second, target, generation, newer, image, presentation, newerSubmission, newerPresentation)

    -- The older record retires first. That discharges its obligation alone: the
    -- newer one is still owed, so the generation is not disposable yet.
    (older, target, generation, newer, image, presentation, newerSubmission, newerPresentation) ← bothOwners
    presentationImage newerPresentation older `shouldBe` Just image
    olderGone ← admitted_ "retiring the older presentation" (recordCompletion (atMilliseconds 2) (PresentationRetired presentation) older)
    presentationImage presentation olderGone `shouldBe` Nothing
    presentationImage newerPresentation olderGone `shouldBe` Just image
    poolRecords target olderGone `shouldBe` 1
    fmap viewOutstanding (holdView (GenerationSubject generation) olderGone)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed, SubmittedUseOwed, PresentationObligationOwed]
    -- The newer frame is still its own frame, and its own submission is its own.
    fmap viewFramePhase (frameView newer olderGone) `shouldBe` Just FramePresentationEnqueued
    newerDone ←
      admitted_ "completing the newer submission" (recordCompletion (atMilliseconds 3) (SubmissionCompleted newerSubmission) olderGone)
        >>= \completedNewer →
          admitted_ "retiring the newer presentation" (recordCompletion (atMilliseconds 4) (PresentationRetired newerPresentation) completedNewer)
    frameView newer newerDone `shouldBe` Nothing
    poolRecords target newerDone `shouldBe` 0
    fmap viewOutstanding (holdView (GenerationSubject generation) newerDone)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]

    -- The other order: the newer record retires while the older one is still
    -- owed, and the older one is exactly as owed as it was.
    (also, otherTarget, otherGeneration, _, otherImage, olderPresentation, otherSubmission, otherPresentation) ← bothOwners
    newerFirst ←
      admitted_ "completing the newer submission" (recordCompletion (atMilliseconds 2) (SubmissionCompleted otherSubmission) also)
        >>= \completedNewer →
          admitted_ "retiring the newer presentation" (recordCompletion (atMilliseconds 3) (PresentationRetired otherPresentation) completedNewer)
    presentationImage otherPresentation newerFirst `shouldBe` Nothing
    presentationImage olderPresentation newerFirst `shouldBe` Just otherImage
    poolRecords otherTarget newerFirst `shouldBe` 1
    fmap viewOutstanding (holdView (GenerationSubject otherGeneration) newerFirst)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed, PresentationObligationOwed]
    settled ←
      admitted_ "retiring the older presentation last" (recordCompletion (atMilliseconds 4) (PresentationRetired olderPresentation) newerFirst)
    poolRecords otherTarget settled `shouldBe` 0
    fmap viewOutstanding (holdView (GenerationSubject otherGeneration) settled)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]

  it "frees the image on every enqueued result, and admits a suboptimal reacquisition of it" $ do
    let freed outcome = do
          model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
          (active, target, _) ← activeTarget 2 model
          (enqueued, _, image, _, presentation) ← imageEnqueued target 0 outcome active
          (reserved, second) ← admitted "reserving a second frame" (reserveFrame target enqueued)
          (reacquired, answer) ← admitted "reacquiring the enqueued image" (acquireImage second (AcquiredImage 0) reserved)
          answer `shouldBe` ImageOwned image False
          -- Whatever the presentation engine said about the surface, the record
          -- it established still owes its own retirement on its own image.
          presentationImage presentation reacquired `shouldBe` Just image
          -- And the replacement the result asked for is still asked for.
          fmap viewTargetReplacementRequested (targetView target reacquired) `shouldBe` Just True

    mapM_ freed [PresentationEnqueuedSuboptimal, PresentationEnqueuedOutOfDate, PresentationEnqueuedSurfaceLost]

    -- A suboptimal acquisition takes the same path, so it reacquires the same
    -- way and keeps asking for a replacement beside the image it owns.
    model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
    (active, target, _) ← activeTarget 2 model
    (enqueued, _, image, _, presentation) ← imageEnqueued target 0 PresentationEnqueued active
    fmap viewTargetReplacementRequested (targetView target enqueued) `shouldBe` Just False
    (reserved, second) ← admitted "reserving a second frame" (reserveFrame target enqueued)
    (reacquired, answer) ← admitted "reacquiring suboptimally" (acquireImage second (AcquiredSuboptimalImage 0) reserved)
    answer `shouldBe` ImageOwned image True
    fmap viewFrameSuboptimal (frameView second reacquired) `shouldBe` Just True
    fmap viewTargetReplacementRequested (targetView target reacquired) `shouldBe` Just True
    presentationImage presentation reacquired `shouldBe` Just image

  it "refuses a second acquisition in every phase before the presentation is enqueued" $ do
    model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
    (active, target, _) ← activeTarget 2 model
    (reserved, first) ← admitted "reserving the first frame" (reserveFrame target active)
    (acquired, _) ← admitted "acquiring image zero" (acquireImage first (AcquiredImage 0) reserved)
    (waiting, second) ← admitted "reserving a second frame" (reserveFrame target acquired)

    -- Acquired, and nothing has been submitted: the frame owns the image outright.
    refusesImageZero second waiting
    -- Submitted, and still unpresented.
    (submitted, submitAnswer) ← admitted "submitting" (submitFrames [first] SubmissionAccepted waiting)
    submission ← submissionOf submitAnswer
    refusesImageZero second submitted
    -- A presentation call that enqueued nothing leaves the image exactly where
    -- it was, so the refusal has to survive it.
    (unenqueued, presentAnswer) ← admitted "failing to enqueue" (enqueuePresentation first PresentationFailedWithoutEnqueue submitted)
    presentAnswer `shouldBe` PresentationNotEnqueued
    refusesImageZero second unenqueued
    -- Closed before presenting: the record is awaiting explicit settlement, and
    -- an image awaiting settlement was never handed to the presentation engine.
    closed ← admitted_ "closing before presenting" (closeSubmittedFrame first unenqueued)
    refusesImageZero second closed
    -- The completion settles the submission, not the image: a record that never
    -- presented is still awaiting its own explicit settlement. An *enqueued*
    -- record's image is reacquirable without observing that completion at all,
    -- through a distinct free frame and pool record, and the new acquisition's
    -- own synchronization stays mandatory before it touches the image.
    completed ← admitted_ "completing the submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) closed)
    refusesImageZero second completed

    -- Explicit settlement is what releases it.
    settled ← admitted_ "settling the unpresented frame" (recordCompletion (atMilliseconds 2) (UnpresentedFrameSettled first) completed)
    (released, _) ← admitted "acquiring the released image" (acquireImage second (AcquiredImage 0) settled)
    fmap viewFrameImage (frameView second released) `shouldSatisfy` \case
      Just (Just image) → imageIndex image == 0
      _ → False

  it "refuses a second acquisition of a skipped frame's image until it is settled" $ do
    model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
    (active, target, _) ← activeTarget 2 model
    (reserved, first) ← admitted "reserving the first frame" (reserveFrame target active)
    (acquired, _) ← admitted "acquiring image zero" (acquireImage first (AcquiredImage 0) reserved)
    (waiting, second) ← admitted "reserving a second frame" (reserveFrame target acquired)

    skipped ← admitted_ "skipping the unsubmitted frame" (skipUnsubmittedFrame first waiting)
    fmap viewFramePhase (frameView first skipped) `shouldBe` Just FrameRetiring
    refusesImageZero second skipped

    settled ← admitted_ "settling the skipped frame" (recordCompletion (atMilliseconds 1) (UnpresentedFrameSettled first) skipped)
    (released, answer) ← admitted "acquiring the released image" (acquireImage second (AcquiredImage 0) settled)
    answer `shouldSatisfy` \case
      ImageOwned image _ → imageIndex image == 0
      _ → False
    fmap viewFramePhase (frameView second released) `shouldBe` Just FrameAcquired

  it "answers session failure rather than image ownership once an uncertain effect stopped admission" $ do
    model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
    (active, target, _) ← activeTarget 2 model
    (reserved, first) ← admitted "reserving the first frame" (reserveFrame target active)
    (acquired, _) ← admitted "acquiring image zero" (acquireImage first (AcquiredImage 0) reserved)
    -- Reserved before the failure, because reservation is refused after it.
    (waiting, second) ← admitted "reserving a second frame" (reserveFrame target acquired)

    (uncertain, answer) ← admitted "submitting" (submitFrames [first] SubmissionEffectUncertain waiting)
    answer `shouldBe` EffectUncertain
    sessionState uncertain `shouldBe` SessionFailed UnknownSubmissionEffect
    -- The first frame does still own image zero, which is exactly why the order
    -- of the two checks matters: the session's failure is the answer, and the
    -- image's owner is never consulted.
    rejectedAs (acquireImage second (AcquiredImage 0) uncertain) SessionAlreadyFailed

  it "frees the slot when a presentation is enqueued after its submission already completed" $ do
    model ← freshModelWith defaultBudgetRequest {requestedImageTracking = 2}
    (active, target, generation) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    submission ← submissionOf submitAnswer

    -- The submission completes first. The frame is not settled by that alone:
    -- it still owns an image that no presentation record has taken over.
    completed ← admitted_ "completing the submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) submitted)
    fmap viewFramePhase (frameView frame completed) `shouldBe` Just FrameSubmitted
    usageFrames (usage completed) `shouldBe` 1

    -- Enqueuing hands the image to the record, and nothing else is owing, so the
    -- slot goes back now rather than waiting for a retirement it no longer has
    -- any part in.
    (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued completed)
    presentation ← presentationOf presentAnswer
    frameView frame presented `shouldBe` Nothing
    usageFrames (usage presented) `shouldBe` 0
    presentationImage presentation presented `shouldSatisfy` \case
      Just image → imageGeneration image == generation
      Nothing → False

    -- The generation still owes its presentation, which is the record's now.
    fmap viewOutstanding (holdView (GenerationSubject generation) presented)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed, PresentationObligationOwed]
    retired ← admitted_ "retiring the presentation" (recordCompletion (atMilliseconds 2) (PresentationRetired presentation) presented)
    fmap viewOutstanding (holdView (GenerationSubject generation) retired)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]

  it "refuses a transition that is not legal from the frame's current phase" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (reserved, frame) ← admitted "reserving" (reserveFrame target active)

    rejectedAs (submitFrames [frame] SubmissionAccepted reserved) (WrongPhase FrameIdentity)
    rejectedAs (enqueuePresentation frame PresentationEnqueued reserved) (WrongPhase FrameIdentity)
    rejectedAs' (skipUnsubmittedFrame frame reserved) (WrongPhase FrameIdentity)
    rejectedAs' (closeSubmittedFrame frame reserved) (WrongPhase FrameIdentity)

    (acquired, _) ← admitted "acquiring" (acquireImage frame (AcquiredImage 0) reserved)
    rejectedAs' (closeSubmittedFrame frame acquired) (WrongPhase FrameIdentity)
    rejectedAs (acquireImage frame (AcquiredImage 0) acquired) (WrongPhase FrameIdentity)

  it "preserves a presentation that enqueued nothing as still owning its rendering and its image" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    (submitted, _) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    (unchanged, answer) ← admitted "presenting" (enqueuePresentation frame PresentationFailedWithoutEnqueue submitted)

    answer `shouldBe` PresentationNotEnqueued
    -- No presentation record became pending, so nothing may wait on one.
    fmap viewFramePresentation (frameView frame unchanged) `shouldBe` Just Nothing
    fmap viewFramePhase (frameView frame unchanged) `shouldBe` Just FrameSubmitted
    -- The frame can still be closed down the submitted-unpresented path.
    closed ← admitted_ "closing" (closeSubmittedFrame frame unchanged)
    fmap viewFramePhase (frameView frame closed) `shouldBe` Just FrameRetiring
  where
    poolRecords target model = maybe (-1) (fromIntegral . viewTargetPoolRecords) (targetView target model) ∷ Integer
    -- One frame of that target taken all the way to an enqueued presentation on
    -- the image it names, answering everything a later example needs to talk
    -- about the record it left behind.
    imageEnqueued
      ∷ TargetId
      → Natural
      → PresentOutcome
      → GpuModel
      → IO (GpuModel, FrameSlotId, ImageId, SubmissionId, PresentationId)
    imageEnqueued target index outcome model = do
      (reserved, frame) ← admitted "reserving a frame" (reserveFrame target model)
      (acquired, acquireAnswer) ← admitted "acquiring" (acquireImage frame (AcquiredImage index) reserved)
      image ← case acquireAnswer of
        ImageOwned owned _ → pure owned
        other → fail ("the arrangement should own an image, got " ++ show other)
      (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted acquired)
      submission ← submissionOf submitAnswer
      (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame outcome submitted)
      presentation ← presentationOf presentAnswer
      pure (presented, frame, image, submission, presentation)
    -- Image zero of the active generation is owned by an unpresented frame, so
    -- this acquisition is refused and changes nothing.
    refusesImageZero slot model =
      outcomeModel (acquireImage slot (AcquiredImage 0) model)
        `shouldBe` Rejected (AlreadyConsumed ImageIdentity)
    submissionOf = \case
      SubmissionRecorded identity → pure identity
      other → fail ("expected a submission record, got " ++ show other)
    presentationOf = \case
      PresentationTracked identity → pure identity
      other → fail ("expected a presentation record, got " ++ show other)
    rejectedAs outcome expected = outcomeModel outcome `shouldBe` Rejected expected
    rejectedAs' outcome expected = outcome `shouldBe` Rejected expected
