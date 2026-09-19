-- | Owner progress: bounded work per turn, round-robin service across targets,
-- the absolute deadline of the next turn, and what resets the idle backoff.
--
-- Every instant here comes from the scripted clock, so the backoff is proved by
-- the deadlines the model computes rather than by waiting for them.
module Test.GPU.Model.Progress (spec) where

import Data.List (nub)
import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest)
import Hetoimasia.GPU.Model.Identity
import Numeric.Natural (Natural)
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldSatisfy)

spec ∷ Spec
spec = describe "owner progress" $ do
  it "does at most its configured number of actions in one turn" $ do
    model ← freshModelWith defaultBudgetRequest {requestedProgressActions = 2, requestedFrameSlots = 4}
    (active, target, _) ← activeTarget 4 model
    (loaded, submissions) ← enqueueFrames target 4 active
    usageSubmissions (usage loaded) `shouldBe` 4

    let source = silentEvidence {submissionEvidence = const True}
        (first, firstReport) = runProgressTurn source (atMilliseconds 1) loaded
    turnActions firstReport `shouldBe` 2
    turnFacts firstReport `shouldBe` 2
    usageSubmissions (usage first) `shouldBe` 2

    let (second, secondReport) = runProgressTurn source (atMilliseconds 2) first
    turnActions secondReport `shouldBe` 2
    usageSubmissions (usage second) `shouldBe` 0

    let (_, idle) = runProgressTurn source (atMilliseconds 3) second
    turnActions idle `shouldBe` 0
    length submissions `shouldBe` 4

  it "serves targets round-robin, leading with a different one each turn" $ do
    model ← freshModelWith defaultBudgetRequest {requestedProgressActions = 1}
    (one, targetOne, _) ← activeTarget 2 model
    (two, targetTwo, _) ← activeTarget 2 one
    (three, targetThree, _) ← activeTarget 2 two
    (loadedOne, _) ← enqueueFrames targetOne 1 three
    (loadedTwo, _) ← enqueueFrames targetTwo 1 loadedOne
    (loaded, _) ← enqueueFrames targetThree 1 loadedTwo

    let source = silentEvidence {submissionEvidence = const True}
        (afterFirst, firstReport) = runProgressTurn source (atMilliseconds 1) loaded
        (afterSecond, secondReport) = runProgressTurn source (atMilliseconds 2) afterFirst
        (_, thirdReport) = runProgressTurn source (atMilliseconds 3) afterSecond

    -- One action per turn, and the lead rotates, so no target starves behind a
    -- busy neighbour.
    map turnActions [firstReport, secondReport, thirdReport] `shouldBe` [1, 1, 1]
    let leads = map (take 1 . turnServed) [firstReport, secondReport, thirdReport]
    length (nub leads) `shouldBe` 3
    concat leads `shouldContain` [targetOne]
    concat leads `shouldContain` [targetTwo]
    concat leads `shouldContain` [targetThree]

  it "walks the idle backoff schedule while nothing progresses, and restarts it on demand" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 1}
    (active, target, _) ← activeTarget 2 model
    (loaded, _) ← enqueueFrames target 1 active

    -- The obligation itself schedules the first poll five milliseconds out.
    nextDeadline (atMilliseconds 0) loaded `shouldBe` Just (atMilliseconds 5)

    -- Each poll that finds nothing moves one step along 5, 10, 20, 40, 80,
    -- 100 ms, and the last step is the steady state it stays at.
    let poll (current, announced) at =
          let (next, report) = runProgressTurn silentEvidence at current
           in (next, announced ++ [turnNextDeadline report])
        (_, deadlines) = foldl poll (loaded, []) (map atMilliseconds [5, 15, 35, 75, 155, 255, 355])
    deadlines `shouldBe` map (Just . atMilliseconds) [15, 35, 75, 155, 255, 355, 455]

    -- New render demand schedules an immediate opportunity and starts over.
    let (stepped, _) = runProgressTurn silentEvidence (atMilliseconds 0) loaded
        (steppedAgain, _) = runProgressTurn silentEvidence (atMilliseconds 0) stepped
    nextDeadline (atMilliseconds 0) steppedAgain `shouldBe` Just (atMilliseconds 20)
    demanded ← admitted_ "requesting a render" (requestRender target steppedAgain)
    nextDeadline (atMilliseconds 0) demanded `shouldBe` Just (atMilliseconds 0)
    let (served, _) = runProgressTurn silentEvidence (atMilliseconds 0) demanded
    nextDeadline (atMilliseconds 0) served `shouldBe` Just (atMilliseconds 0)

  it "restarts the backoff on a new obligation, an observed completion and a close" $ do
    -- Two frames are submitted and only one of them completes, so a pending
    -- obligation survives every step below and the deadline is never absent for
    -- a reason other than the one being tested.
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 3}
    (active, target, _) ← activeTarget 2 model
    (loaded, submissions) ← enqueueFrames target 2 active
    submission ← case submissions of
      identity : _ → pure identity
      [] → fail "the fixture should have made two submissions" 

    let backedOff = walk 3 loaded
    nextDeadline (atMilliseconds 0) backedOff `shouldBe` Just (atMilliseconds 40)

    -- A new obligation.
    (obliged, _) ← admitted "reserving another frame" (reserveFrame target backedOff)
    nextDeadline (atMilliseconds 0) obliged `shouldBe` Just (atMilliseconds 5)

    -- An observed completion.
    let backedOffAgain = walk 3 obliged
    nextDeadline (atMilliseconds 0) backedOffAgain `shouldBe` Just (atMilliseconds 40)
    completed ← admitted_ "completing" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) backedOffAgain)
    nextDeadline (atMilliseconds 0) completed `shouldBe` Just (atMilliseconds 5)

    -- A close transition.
    let backedOffOnceMore = walk 3 completed
    nextDeadline (atMilliseconds 0) backedOffOnceMore `shouldBe` Just (atMilliseconds 40)
    closed ← admitted_ "closing" (closeTarget target backedOffOnceMore)
    nextDeadline (atMilliseconds 0) closed `shouldBe` Just (atMilliseconds 5)

  it "restarts the backoff for retirement work, whoever created it" $ do
    -- Requirement 7's reset is about new work existing, not about who made it.
    -- A target that retires a generation while the session has backed off to its
    -- idle interval must not wait that interval out before the owner looks.
    -- One submission stays pending throughout, so there is always something to
    -- have a deadline for and the example is about when it fires.
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (loaded, _) ← enqueueFrames target 1 active
    (resourced, resource) ← aResource 1024 loaded

    let backedOff = walk 3 resourced
    nextDeadline (atMilliseconds 0) backedOff `shouldBe` Just (atMilliseconds 40)
    retired ← admitted_ "retiring a generation" (retireGeneration generation backedOff)
    nextDeadline (atMilliseconds 0) retired `shouldBe` Just (atMilliseconds 5)

    -- Certifying that a generation's CPU use has ended can make it disposable,
    -- which is new work for the same reason.
    let backedOffAgain = walk 3 retired
    nextDeadline (atMilliseconds 0) backedOffAgain `shouldBe` Just (atMilliseconds 40)
    ended ← admitted_ "ending the generation's CPU use" (endGenerationCpuUse generation backedOffAgain)
    nextDeadline (atMilliseconds 0) ended `shouldBe` Just (atMilliseconds 5)

    -- And so can releasing a managed resource, or ending its CPU use.
    let backedOffOnceMore = walk 3 ended
    nextDeadline (atMilliseconds 0) backedOffOnceMore `shouldBe` Just (atMilliseconds 40)
    released ← admitted_ "releasing a resource" (releaseResource resource backedOffOnceMore)
    nextDeadline (atMilliseconds 0) released `shouldBe` Just (atMilliseconds 5)
    let backedOffLast = walk 3 released
    nextDeadline (atMilliseconds 0) backedOffLast `shouldBe` Just (atMilliseconds 40)
    settled ← admitted_ "ending the resource's CPU use" (endResourceCpuUse resource backedOffLast)
    nextDeadline (atMilliseconds 0) settled `shouldBe` Just (atMilliseconds 5)

  it "restarts the backoff when a construction fails or is superseded" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (loaded, _) ← enqueueFrames target 1 active
    (constructing, candidate) ← admitted "constructing a replacement" (beginGeneration target (Just generation) loaded)

    let backedOff = walk 3 constructing
    nextDeadline (atMilliseconds 0) backedOff `shouldBe` Just (atMilliseconds 40)
    failed ← admitted_ "failing the construction" (failGenerationConstruction candidate backedOff)
    nextDeadline (atMilliseconds 0) failed `shouldBe` Just (atMilliseconds 5)

    -- A superseded publication leaves the same kind of work behind.
    (second, secondTarget, secondGeneration) ← activeTarget 2 model
    (secondLoaded, _) ← enqueueFrames secondTarget 1 second
    (secondConstructing, secondCandidate) ←
      admitted "constructing another replacement" (beginGeneration secondTarget (Just secondGeneration) secondLoaded)
    closed ← admitted_ "closing the target" (closeTarget secondTarget secondConstructing)
    let secondBackedOff = walk 3 closed
    nextDeadline (atMilliseconds 0) secondBackedOff `shouldBe` Just (atMilliseconds 40)
    (superseded, answer) ← admitted "publishing after the close" (publishGeneration secondCandidate 2 secondBackedOff)
    answer `shouldBe` PublicationSuperseded
    nextDeadline (atMilliseconds 0) superseded `shouldBe` Just (atMilliseconds 5)

  it "drops a suspended target's render deadline while keeping its retirement demand" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 2}
    (active, target, _) ← activeTarget 2 model
    (loaded, _) ← enqueueFrames target 1 active
    demanded ← admitted_ "requesting a render" (requestRender target loaded)
    nextDeadline (atMilliseconds 0) demanded `shouldBe` Just (atMilliseconds 0)

    suspended ← admitted_ "suspending" (suspendTarget target demanded)
    fmap viewTargetRenderDemand (targetView target suspended) `shouldBe` Just False
    -- No immediate render opportunity any more, but the target still owes its
    -- outstanding work and the owner still comes back for it.
    fmap viewTargetRetirementDemand (targetView target suspended) `shouldBe` Just True
    pendingObligations suspended `shouldSatisfy` (> 0)
    nextDeadline (atMilliseconds 0) suspended `shouldBe` Just (atMilliseconds 5)

    resumed ← admitted_ "resuming" (resumeTarget target suspended)
    fmap viewTargetRenderDemand (targetView target resumed) `shouldBe` Just True
    nextDeadline (atMilliseconds 0) resumed `shouldBe` Just (atMilliseconds 0)

  it "advertises a recovery retry deadline on an otherwise idle target" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    -- Nothing is pending at all: no frame, no record, no retired generation.
    pendingObligations active `shouldBe` 0
    nextDeadline (atMilliseconds 0) active `shouldBe` Nothing

    (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    -- While the attempt is in flight the model is waiting on the boundary, not
    -- on a clock, so it commits to no instant.
    nextDeadline (atMilliseconds 0) begun `shouldBe` Nothing

    failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target begun)
    -- The retry is 100 ms away and there is no obligation to poll for, so a
    -- schedule built from obligations alone would have advertised nothing and
    -- the owner would never come back to make the attempt.
    pendingObligations failed `shouldSatisfy` (> 0)
    nextDeadline (atMilliseconds 0) failed `shouldBe` Just (atMilliseconds 100)
    -- It is an absolute instant, not an interval, so reading later does not move it.
    nextDeadline (atMilliseconds 50) failed `shouldBe` Just (atMilliseconds 100)

    -- Once the attempt is admitted the deadline is gone again.
    (again, _) ← admitted "the second attempt" (beginTargetRecovery (atMilliseconds 100) target failed)
    nextDeadline (atMilliseconds 100) again `shouldBe` Nothing

  it "advertises the healthy-progress deadline that resets a recovery episode" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 2}
    (active, target, _) ← activeTarget 2 model
    -- Spend the whole episode, so no retry deadline remains and the healthy
    -- period is the only instant the model is committed to.
    spent ← spendEpisode target active 3 0
    fmap viewTargetRecoveryAttempts (targetView target spent) `shouldBe` Just 3
    nextDeadline (atMilliseconds 3000) spent `shouldBe` Nothing

    -- A full presentation-retirement cycle starts the healthy second.
    cycled ← completeCycle target (atMilliseconds 3000) spent
    pendingObligations cycled `shouldSatisfy` (> 0)
    -- Without this deadline the owner is never woken to observe the reset, so a
    -- later recovery would start from a budget that should have come back.
    nextDeadline (atMilliseconds 3000) cycled `shouldBe` Just (atMilliseconds 4000)

    let (tooSoon, _) = runProgressTurn silentEvidence (atMilliseconds 3999) cycled
    fmap viewTargetRecoveryAttempts (targetView target tooSoon) `shouldBe` Just 3
    let (healthy, _) = runProgressTurn silentEvidence (atMilliseconds 4000) tooSoon
    fmap viewTargetRecoveryAttempts (targetView target healthy) `shouldBe` Just 0
    -- With the episode reset and nothing else outstanding, the schedule is empty.
    nextDeadline (atMilliseconds 4000) healthy `shouldBe` Nothing

  it "has no deadline at all once nothing is pending" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    retired ← admitted_ "retiring" (retireGeneration generation active)
    ended ← admitted_ "ending CPU use" (endGenerationCpuUse generation retired)
    pendingObligations ended `shouldSatisfy` (> 0)

    let (disposed, report) = runProgressTurn (silentEvidence {disposalEvidence = const DisposalCompleted}) (atMilliseconds 1) ended
    turnDisposed report `shouldBe` [GenerationSubject generation]
    pendingObligations disposed `shouldBe` 0
    nextDeadline (atMilliseconds 1) disposed `shouldBe` Nothing
    turnNextDeadline report `shouldBe` Nothing
    fmap viewTargetRetirementDemand (targetView target disposed) `shouldBe` Just False

  it "keeps a failed disposal's subject owned and accounted, and escalates it to the session" $ do
    model ← freshModel
    (active, _, generation) ← activeTarget 2 model
    retired ← admitted_ "retiring" (retireGeneration generation active)
    ended ← admitted_ "ending CPU use" (endGenerationCpuUse generation retired)
    let before = usageObjects (usage ended)
        (broken, report) = runProgressTurn (silentEvidence {disposalEvidence = const DisposalFailed}) (atMilliseconds 1) ended

    turnDisposalFailures report `shouldBe` [GenerationSubject generation]
    turnDisposed report `shouldBe` []
    -- A cleanup failure is never permission to proceed as though rollback
    -- succeeded: the subject is still here and still accounted for.
    disposalEligible (GenerationSubject generation) broken `shouldBe` True
    usageObjects (usage broken) `shouldBe` before
    sessionState broken `shouldBe` SessionFailed CleanupFailed
    escalations broken `shouldContain` [SessionEscalated CleanupFailed]
  where
    walk count model = iterate step model !! (count ∷ Int)
      where
        step current = fst (runProgressTurn silentEvidence (atMilliseconds 0) current)
    -- Burn `count` of an episode's attempts, each one failing.
    spendEpisode target model count now
      | count <= (0 ∷ Int) = pure model
      | otherwise = do
          (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds now) target model)
          failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds now) target begun)
          spendEpisode target failed (count - 1) (now + 1000)
    -- One full acquire / submit / present / retire cycle, which is what a
    -- recovery episode's healthy period is measured from.
    completeCycle target now model = do
      (framed, frame) ← acquiredFrame target model
      (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
      submission ← case submitAnswer of
        SubmissionRecorded value → pure value
        other → fail ("expected a submission record, got " ++ show other)
      (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
      presentation ← case presentAnswer of
        PresentationTracked value → pure value
        other → fail ("expected a presentation record, got " ++ show other)
      completed ← admitted_ "completing" (recordCompletion now (SubmissionCompleted submission) presented)
      admitted_ "retiring the presentation" (recordCompletion now (PresentationRetired presentation) completed)
    -- Drive `count` frames to a submitted state whose records stay pending.
    enqueueFrames target count model = go model (count ∷ Natural) []
      where
        go current 0 made = pure (current, reverse made)
        go current remaining made = do
          (framed, frame) ← acquiredFrame target current
          (submitted, answer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
          identity ← case answer of
            SubmissionRecorded value → pure value
            other → fail ("expected a submission record, got " ++ show other)
          go submitted (remaining - 1) (identity : made)
