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
import Hetoimasia.GPU.Model.Identity
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
    submissionOf = \case
      SubmissionRecorded identity → pure identity
      other → fail ("expected a submission record, got " ++ show other)
    rejectedAs outcome expected = outcomeModel outcome `shouldBe` Rejected expected
    rejectedAs' outcome expected = outcome `shouldBe` Rejected expected
