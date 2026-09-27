-- | Device loss: the fact that the device was lost, kept apart from why the
-- session ended, and the release of what only the lost device could have
-- discharged.
--
-- The distinctions these examples draw are the ones that would let a teardown
-- claim more than the specification's device-loss rule gives it: a release is
-- not completion, it is not available before the loss is recorded, it does not
-- touch a frame whose unsubmitted recording is still owned, and a session that
-- another cause failed first keeps that cause while its teardown still gains
-- the rule.
module Test.GPU.Model.DeviceLoss (spec) where

import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Identity
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "device loss" $ do
  it "records the loss as the session's first cause, and notifies it once" $ do
    model ← freshModel
    let lost = noteDeviceLoss model
    sessionState lost `shouldBe` SessionFailed DeviceLost
    deviceLossObserved lost `shouldBe` True
    escalations lost `shouldBe` [SessionEscalated DeviceLost]
    escalations (noteDeviceLoss lost) `shouldBe` [SessionEscalated DeviceLost]

  it "keeps an earlier cause as the session's while still recording a later loss" $ do
    model ← freshModel
    let failed = escalateSession ValidationError model
        lost = noteDeviceLoss failed
    deviceLossObserved failed `shouldBe` False
    sessionState lost `shouldBe` SessionFailed ValidationError
    deviceLossObserved lost `shouldBe` True
    -- The loss is a fact for the teardown, not a second notice of failure.
    escalations lost `shouldBe` [SessionEscalated ValidationError]

  it "records the outcome of the call that failed the session, and refuses only new work" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    -- An acquisition that raised the loss owned nothing: its reservation goes
    -- back, although the loss ended the session during the call.
    (reserved, reservation) ← admitted "reserving" (reserveFrame target active)
    misuse ← rejected "owning an image after the loss" (acquireImage reservation (AcquiredImage 0) (noteDeviceLoss reserved))
    misuse `shouldBe` SessionAlreadyFailed
    (returned, answer) ← admitted "returning the reservation" (acquireImage reservation AcquireNotReady (noteDeviceLoss reserved))
    answer `shouldBe` ReservationReturned
    frameView reservation returned `shouldBe` Nothing
    -- A submission that raised the loss has an unknown effect, recorded as
    -- such; a submission accepted after the loss would be new work.
    (framed, frame) ← acquiredFrame target active
    let lost = noteDeviceLoss framed
    refused ← rejected "accepting a submission after the loss" (submitFrames [frame] SubmissionAccepted lost)
    refused `shouldBe` SessionAlreadyFailed
    (uncertain, submitted) ← admitted "recording the uncertain submission" (submitFrames [frame] SubmissionEffectUncertain lost)
    submitted `shouldBe` EffectUncertain
    fmap viewFramePhase (frameView frame uncertain) `shouldBe` Just FrameUncertainEffect
    sessionState uncertain `shouldBe` SessionFailed DeviceLost

  it "refuses a release before the loss is recorded, changing nothing" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    (submitted, _) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    let failed = escalateSession CleanupFailed submitted
    misuse ← rejected "releasing without a loss" (releaseToDeviceLoss failed)
    misuse `shouldBe` WrongPhase DeviceIdentity

  it "releases a submission and a presentation without completing or retiring either" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    submission ← case submitAnswer of
      SubmissionRecorded identity → pure identity
      other → fail ("expected a submission record, got " ++ show other)
    (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
    presentation ← case presentAnswer of
      PresentationTracked identity → pure identity
      other → fail ("expected a presentation record, got " ++ show other)
    fmap viewOutstanding (holdView (GenerationSubject generation) presented)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed, SubmittedUseOwed, PresentationObligationOwed]
    fmap viewTargetCycles (targetView target presented) `shouldBe` Just 1

    (released, report) ← admitted "releasing" (releaseToDeviceLoss (noteDeviceLoss presented))
    releasedSubmissions report `shouldBe` [submission]
    releasedPresentations report `shouldBe` [presentation]
    releaseRemaining report `shouldBe` []
    fmap viewOutstanding (holdView (GenerationSubject generation) released)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]
    usageSubmissions (usage released) `shouldBe` 0
    fmap viewTargetPoolRecords (targetView target released) `shouldBe` Just 0
    -- Neither record was completed: the facts that would have said so are
    -- refused, and the cycle they would have completed was dropped uncredited.
    fmap viewTargetCycles (targetView target released) `shouldBe` Just 0
    fmap viewTargetRecoveryAttempts (targetView target released) `shouldBe` Just 0
    _ ← rejected "completing the released submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) released)
    _ ← rejected "retiring the released presentation" (recordCompletion (atMilliseconds 1) (PresentationRetired presentation) released)
    pure ()

  it "retains an uncertain effect's parents until the loss, and releases them under it" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    (uncertain, answer) ← admitted "submitting with an unknown effect" (submitFrames [frame] SubmissionEffectUncertain framed)
    answer `shouldBe` EffectUncertain
    sessionState uncertain `shouldBe` SessionFailed UnknownSubmissionEffect
    -- Without the loss nothing lets go of it: retiring and releasing the
    -- generation still leaves the submitted use owed.
    retired ← admitted_ "retiring the generation" (retireGeneration generation uncertain)
    ended ← admitted_ "ending its CPU use" (endGenerationCpuUse generation retired)
    fmap viewOutstanding (holdView (GenerationSubject generation) ended)
      `shouldSatisfy` maybe False (SubmittedUseOwed `elem`)
    disposalEligible (GenerationSubject generation) ended `shouldBe` False

    (released, report) ← admitted "releasing" (releaseToDeviceLoss (noteDeviceLoss ended))
    sessionState released `shouldBe` SessionFailed UnknownSubmissionEffect
    releasedFrames report `shouldBe` [frame]
    frameView frame released `shouldBe` Nothing
    disposalEligible (GenerationSubject generation) released `shouldBe` True

  it "leaves an acquired frame to be skipped first, and releases it once it has been" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (framed, frame) ← acquiredFrame target resourced
    (recordedBatch, _) ← admitted "recording" (recordBatch frame [resource] framed)
    (released, report) ← admitted "releasing" (releaseToDeviceLoss (noteDeviceLoss recordedBatch))
    releaseRemaining report `shouldBe` [frame]
    fmap viewFramePhase (frameView frame released) `shouldBe` Just FrameAcquired
    -- Its recorded reference is the recording's to invalidate, not the loss's.
    fmap viewRecorded (holdView (ResourceSubject resource) released) `shouldSatisfy` maybe False (not . null)

    skipped ← admitted_ "skipping" (skipUnsubmittedFrame frame released)
    (again, afterSkip) ← admitted "releasing again" (releaseToDeviceLoss skipped)
    releasedFrames afterSkip `shouldBe` [frame]
    releaseRemaining afterSkip `shouldBe` []
    frameView frame again `shouldBe` Nothing
    fmap viewOutstanding (holdView (GenerationSubject generation) again)
      `shouldBe` Just [LogicalReleaseOwed, CpuUseOwed]

  it "releases nothing the second time" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    (submitted, _) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    (once, _) ← admitted "releasing" (releaseToDeviceLoss (noteDeviceLoss submitted))
    (twice, report) ← admitted "releasing again" (releaseToDeviceLoss once)
    report `shouldBe` DeviceLossRelease [] [] [] []
    usage twice `shouldBe` usage once
