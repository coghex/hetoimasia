-- | Owner progress: bounded work per turn, round-robin service across targets,
-- the absolute deadline of the next turn, and what resets the idle backoff.
--
-- Every instant here comes from the scripted clock, so the backoff is proved by
-- the deadlines the model computes rather than by waiting for them.
module Test.GPU.Model.Progress (spec) where

import Data.List (nub)
import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget (BudgetKind (GenerationBudget, TargetRecordBudget), BudgetRequest (..), defaultBudgetRequest)
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

    -- The obligation asks for an opportunity now: the transition that created it
    -- carried no clock reading to anchor an instant to.
    nextDeadline loaded `shouldBe` TurnNow

    -- Each turn anchors the next poll at the instant it ran, moving one step
    -- along 5, 10, 20, 40, 80, 100 ms; the last step is the steady state.
    let poll (current, announced) at =
          let (next, report) = runProgressTurn silentEvidence at current
           in (next, announced ++ [turnNextDeadline report])
        (_, deadlines) = foldl poll (loaded, []) (map atMilliseconds [0, 5, 15, 35, 75, 155, 255])
    deadlines `shouldBe` map (TurnAt . atMilliseconds) [5, 15, 35, 75, 155, 255, 355]

    -- And the answer is a property of the model alone. Reading it again later
    -- gives the same instant, so an unrelated observation cannot postpone the
    -- poll it is asking about.
    let (polled, _) = runProgressTurn silentEvidence (atMilliseconds 0) loaded
    nextDeadline polled `shouldBe` TurnAt (atMilliseconds 5)
    nextDeadline polled `shouldBe` TurnAt (atMilliseconds 5)

    -- New render demand schedules an immediate opportunity and starts over.
    let (stepped, _) = runProgressTurn silentEvidence (atMilliseconds 0) loaded
        (steppedAgain, _) = runProgressTurn silentEvidence (atMilliseconds 0) stepped
    nextDeadline steppedAgain `shouldBe` TurnAt (atMilliseconds 10)
    demanded ← admitted_ "requesting a render" (requestRender target steppedAgain)
    nextDeadline demanded `shouldBe` TurnNow
    let (served, _) = runProgressTurn silentEvidence (atMilliseconds 0) demanded
    nextDeadline served `shouldBe` TurnNow

  it "answers the same deadline however long after the model last changed it is read" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 2}
    (active, target, _) ← activeTarget 2 model
    (loaded, _) ← enqueueFrames target 1 active
    let (polled, _) = runProgressTurn silentEvidence (atMilliseconds 0) loaded

    -- The poll is due five milliseconds after the turn that anchored it. Reading
    -- the unchanged model again — at four milliseconds, at four hundred — is an
    -- observation, and an observation must not move a deadline. Recomputing it
    -- from the reading instant would push the poll away every time anything
    -- happened to ask.
    nextDeadline polled `shouldBe` TurnAt (atMilliseconds 5)
    replicate 5 (nextDeadline polled) `shouldBe` replicate 5 (TurnAt (atMilliseconds 5))

    -- The same holds with a recovery deadline in play. This model's second idle
    -- turn anchored its poll ten milliseconds out, which is sooner than the
    -- hundred-millisecond retry, and repeated reads keep answering that.
    (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target polled)
    failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target begun)
    let (anchored, _) = runProgressTurn silentEvidence (atMilliseconds 0) failed
    replicate 3 (nextDeadline anchored) `shouldBe` replicate 3 (TurnAt (atMilliseconds 10))

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
    nextDeadline backedOff `shouldBe` TurnAt (atMilliseconds 20)

    -- A new obligation.
    (obliged, _) ← admitted "reserving another frame" (reserveFrame target backedOff)
    nextDeadline obliged `shouldBe` TurnNow

    -- An observed completion.
    let backedOffAgain = walk 3 obliged
    nextDeadline backedOffAgain `shouldBe` TurnAt (atMilliseconds 20)
    completed ← admitted_ "completing" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) backedOffAgain)
    nextDeadline completed `shouldBe` TurnNow

    -- A close transition.
    let backedOffOnceMore = walk 3 completed
    nextDeadline backedOffOnceMore `shouldBe` TurnAt (atMilliseconds 20)
    closed ← admitted_ "closing" (closeTarget target backedOffOnceMore)
    nextDeadline closed `shouldBe` TurnNow

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
    nextDeadline backedOff `shouldBe` TurnAt (atMilliseconds 20)
    retired ← admitted_ "retiring a generation" (retireGeneration generation backedOff)
    nextDeadline retired `shouldBe` TurnNow

    -- Certifying that a generation's CPU use has ended can make it disposable,
    -- which is new work for the same reason.
    let backedOffAgain = walk 3 retired
    nextDeadline backedOffAgain `shouldBe` TurnAt (atMilliseconds 20)
    ended ← admitted_ "ending the generation's CPU use" (endGenerationCpuUse generation backedOffAgain)
    nextDeadline ended `shouldBe` TurnNow

    -- And so can releasing a managed resource, or ending its CPU use.
    let backedOffOnceMore = walk 3 ended
    nextDeadline backedOffOnceMore `shouldBe` TurnAt (atMilliseconds 20)
    released ← admitted_ "releasing a resource" (releaseResource resource backedOffOnceMore)
    nextDeadline released `shouldBe` TurnNow
    let backedOffLast = walk 3 released
    nextDeadline backedOffLast `shouldBe` TurnAt (atMilliseconds 20)
    settled ← admitted_ "ending the resource's CPU use" (endResourceCpuUse resource backedOffLast)
    nextDeadline settled `shouldBe` TurnNow

  it "restarts the backoff when a construction fails or is superseded" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (loaded, _) ← enqueueFrames target 1 active
    (constructing, candidate) ← admitted "constructing a replacement" (beginGeneration target (Just generation) loaded)

    let backedOff = walk 3 constructing
    nextDeadline backedOff `shouldBe` TurnAt (atMilliseconds 20)
    failed ← admitted_ "failing the construction" (failGenerationConstruction candidate backedOff)
    nextDeadline failed `shouldBe` TurnNow

    -- A superseded publication leaves the same kind of work behind.
    (second, secondTarget, secondGeneration) ← activeTarget 2 model
    (secondLoaded, _) ← enqueueFrames secondTarget 1 second
    (secondConstructing, secondCandidate) ←
      admitted "constructing another replacement" (beginGeneration secondTarget (Just secondGeneration) secondLoaded)
    closed ← admitted_ "closing the target" (closeTarget secondTarget secondConstructing)
    let secondBackedOff = walk 3 closed
    nextDeadline secondBackedOff `shouldBe` TurnAt (atMilliseconds 20)
    (superseded, answer) ← admitted "publishing after the close" (publishGeneration secondCandidate 2 secondBackedOff)
    answer `shouldBe` PublicationSuperseded
    nextDeadline superseded `shouldBe` TurnNow

  it "drops a suspended target's render deadline while keeping its retirement demand" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 2}
    (active, target, _) ← activeTarget 2 model
    (loaded, _) ← enqueueFrames target 1 active
    demanded ← admitted_ "requesting a render" (requestRender target loaded)
    nextDeadline demanded `shouldBe` TurnNow

    suspended ← admitted_ "suspending" (suspendTarget target demanded)
    fmap viewTargetRenderDemand (targetView target suspended) `shouldBe` Just False
    -- No immediate render opportunity any more, but the target still owes its
    -- outstanding work and the owner still comes back for it.
    fmap viewTargetRetirementDemand (targetView target suspended) `shouldBe` Just True
    pendingObligations suspended `shouldSatisfy` (> 0)
    nextDeadline suspended `shouldBe` TurnNow

    resumed ← admitted_ "resuming" (resumeTarget target suspended)
    fmap viewTargetRenderDemand (targetView target resumed) `shouldBe` Just True
    nextDeadline resumed `shouldBe` TurnNow

  it "advertises a recovery retry deadline on an otherwise idle target" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    -- Nothing is pending at all: no frame, no record, no retired generation.
    pendingObligations active `shouldBe` 0
    nextDeadline active `shouldBe` NoTurnNeeded

    (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    -- While the attempt is in flight the model is waiting on the boundary, not
    -- on a clock, so it commits to no instant.
    nextDeadline begun `shouldBe` NoTurnNeeded

    failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target begun)
    -- The retry is 100 ms away and there is no obligation to poll for, so a
    -- schedule built from obligations alone would have advertised nothing and
    -- the owner would never come back to make the attempt.
    pendingObligations failed `shouldSatisfy` (> 0)
    nextDeadline failed `shouldBe` TurnAt (atMilliseconds 100)
    -- It is an absolute instant, not an interval, so reading later does not move it.
    nextDeadline failed `shouldBe` TurnAt (atMilliseconds 100)

    -- Once the attempt is admitted the deadline is gone again.
    (again, _) ← admitted "the second attempt" (beginTargetRecovery (atMilliseconds 100) target failed)
    nextDeadline again `shouldBe` NoTurnNeeded

  it "advertises the healthy-progress deadline that resets a recovery episode" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 2}
    (active, target, _) ← activeTarget 2 model
    (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target begun)
    (second, _) ← admitted "the second attempt" (beginTargetRecovery (atMilliseconds 100) target failed)
    succeeded ← admitted_ "recording the success" (recordRecoverySuccess target second)

    -- Two attempts spent, none outstanding and no retry owed, so the model is
    -- committed to nothing at all until a cycle completes.
    fmap viewTargetRecoveryAttempts (targetView target succeeded) `shouldBe` Just 2
    nextDeadline succeeded `shouldBe` NoTurnNeeded

    cycled ← completeCycle target (atMilliseconds 1000) succeeded
    -- Without this deadline the owner is never woken to observe the reset, so a
    -- later recovery would start from a budget that should have come back.
    nextDeadline cycled `shouldBe` TurnAt (atMilliseconds 2000)

    let (tooSoon, _) = runProgressTurn silentEvidence (atMilliseconds 1999) cycled
    fmap viewTargetRecoveryAttempts (targetView target tooSoon) `shouldBe` Just 2
    let (healthy, _) = runProgressTurn silentEvidence (atMilliseconds 2000) tooSoon
    fmap viewTargetRecoveryAttempts (targetView target healthy) `shouldBe` Just 0
    nextDeadline healthy `shouldBe` NoTurnNeeded

  it "completes a retirement cycle only when both of its facts have arrived" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 2}
    (active, target, _) ← activeTarget 2 model
    (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target begun)
    (second, _) ← admitted "the second attempt" (beginTargetRecovery (atMilliseconds 100) target failed)
    succeeded ← admitted_ "recording the success" (recordRecoverySuccess target second)

    -- Retire the presentation first. Retirement is explicitly allowed before the
    -- submission completes, so on its own it is half a cycle: the frame still
    -- owes the rendering it submitted.
    (framed, frame) ← acquiredFrame target succeeded
    (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    submission ← submissionOf submitAnswer
    (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
    presentation ← presentationOf presentAnswer
    retired ← admitted_ "retiring the presentation" (recordCompletion (atMilliseconds 1000) (PresentationRetired presentation) presented)
    maybe [] viewOutstanding (holdView (GenerationSubject (generationOf target retired)) retired)
      `shouldContain` [SubmittedUseOwed]

    -- A second passes. Nothing may reset, because no cycle has completed: the
    -- episode would otherwise hand its budget back on half a fact.
    nextDeadline retired `shouldSatisfy` (/= NoTurnNeeded)
    let (waited, _) = runProgressTurn silentEvidence (atMilliseconds 2000) retired
    fmap viewTargetRecoveryAttempts (targetView target waited) `shouldBe` Just 2

    -- The submission completing is the other half. Only now does the healthy
    -- second start, and only after it does the episode reset.
    completed ← admitted_ "completing the submission" (recordCompletion (atMilliseconds 2000) (SubmissionCompleted submission) waited)
    nextDeadline completed `shouldBe` TurnAt (atMilliseconds 3000)
    let (tooSoon, _) = runProgressTurn silentEvidence (atMilliseconds 2999) completed
    fmap viewTargetRecoveryAttempts (targetView target tooSoon) `shouldBe` Just 2
    let (reset, _) = runProgressTurn silentEvidence (atMilliseconds 3000) tooSoon
    fmap viewTargetRecoveryAttempts (targetView target reset) `shouldBe` Just 0

  it "does not let evidence gathered before an attempt replenish the episode" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 2}
    (active, target, _) ← activeTarget 2 model
    -- A full cycle first, so healthy evidence exists before any recovery.
    cycled ← completeCycle target (atMilliseconds 0) active

    (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 500) target cycled)
    succeeded ← admitted_ "recording the success" (recordRecoverySuccess target begun)
    -- A second after the cycle has now passed, but that cycle was interrupted by
    -- the very attempt whose budget it would be handing back.
    let (later, _) = runProgressTurn silentEvidence (atMilliseconds 1000) succeeded
    fmap viewTargetRecoveryAttempts (targetView target later) `shouldBe` Just 1
    nextDeadline later `shouldBe` NoTurnNeeded

    -- A cycle after the attempt, and a second after that one, does reset it.
    afterwards ← completeCycle target (atMilliseconds 1000) later
    nextDeadline afterwards `shouldBe` TurnAt (atMilliseconds 2000)
    let (reset, _) = runProgressTurn silentEvidence (atMilliseconds 2000) afterwards
    fmap viewTargetRecoveryAttempts (targetView target reset) `shouldBe` Just 0

  it "reports an unschedulable turn rather than none when the deadline arithmetic overflows" $ do
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 2}
    (active, target, _) ← activeTarget 2 model
    (loaded, _) ← enqueueFrames target 1 active
    pendingObligations loaded `shouldSatisfy` (> 0)

    -- A turn at the last representable instant cannot anchor its next poll: the
    -- interval does not fit. There is certainly work, so saying no turn is
    -- needed would be a lie about the model rather than a fact about the clock.
    let (overflowed, report) = runProgressTurn silentEvidence lastInstant loaded
    turnNextDeadline report `shouldBe` TurnUnschedulable
    nextDeadline overflowed `shouldBe` TurnUnschedulable
    -- The same turn earlier in the range anchors normally, so this is the
    -- arithmetic and not the work.
    let (ordinary, _) = runProgressTurn silentEvidence (atMilliseconds 0) loaded
    nextDeadline ordinary `shouldBe` TurnAt (atMilliseconds 5)

    -- An overflowing healthy-progress deadline is reported the same way.
    (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    succeeded ← admitted_ "recording the success" (recordRecoverySuccess target begun)
    cycled ← completeCycle target lastInstant succeeded
    nextDeadline cycled `shouldBe` TurnUnschedulable

    -- But an overflow never hides a deadline that is both representable and
    -- sooner: the retry below is finite and overdue, and it is the answer even
    -- though this model's poll cannot be anchored.
    (mixedBegun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target loaded)
    mixedFailed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target mixedBegun)
    let (mixed, _) = runProgressTurn silentEvidence lastInstant mixedFailed
    nextDeadline mixed `shouldBe` TurnAt (atMilliseconds 100)

    -- Render demand still answers at once: that answer needs no arithmetic.
    demanded ← admitted_ "requesting a render" (requestRender target overflowed)
    nextDeadline demanded `shouldBe` TurnNow

  it "schedules the turn that frees a closed target's record, so its capacity comes back" $ do
    -- One target record in the whole configuration, so a record that is never
    -- freed is a session that can never render again.
    model ← freshModelWith defaultBudgetRequest {requestedTargetRecords = 1}
    (withTarget, target) ← admitted "admitting a target" (admitTarget OptionalTarget model)
    backpressured "admitting a second" (admitTarget OptionalTarget withTarget)
      >>= (`shouldBe` TargetRecordBudget)

    closed ← admitted_ "closing it" (closeTarget target withTarget)
    -- Only a turn removes the record, so the schedule has to ask for one. Saying
    -- no turn was needed would strand the record and the budget with it.
    pendingObligations closed `shouldSatisfy` (> 0)
    nextDeadline closed `shouldBe` TurnNow

    let (freed, _) = runProgressTurn silentEvidence (atMilliseconds 1) closed
    targetView target freed `shouldBe` Nothing
    nextDeadline freed `shouldBe` NoTurnNeeded
    (reused, _) ← admitted "admitting again on the freed record" (admitTarget OptionalTarget freed)
    usageTargets (usage reused) `shouldBe` 1

  it "schedules a replacement nobody is building yet" $ do
    model ← freshModelWith defaultBudgetRequest {requestedGenerations = 2}
    (active, target, generation) ← activeTarget 2 model
    nextDeadline active `shouldBe` NoTurnNeeded

    -- An out-of-date acquisition gives its reservation back and creates no
    -- obligation, so the request it raises is the only thing left to act on.
    (reserved, frame) ← admitted "reserving" (reserveFrame target active)
    (requested, answer) ← admitted "acquiring" (acquireImage frame AcquireOutOfDate reserved)
    answer `shouldBe` ReplacementRequested
    frameView frame requested `shouldBe` Nothing
    fmap viewTargetReplacementRequested (targetView target requested) `shouldBe` Just True
    pendingObligations requested `shouldSatisfy` (> 0)
    nextDeadline requested `shouldBe` TurnNow

    -- Turns alone do not satisfy it: the owner has to build something.
    let (turned, _) = runProgressTurn silentEvidence (atMilliseconds 1) requested
        (turnedAgain, _) = runProgressTurn silentEvidence (atMilliseconds 2) turned
    nextDeadline turnedAgain `shouldSatisfy` (/= NoTurnNeeded)
    fmap viewTargetReplacementRequested (targetView target turnedAgain) `shouldBe` Just True

    -- A construction begun to serve it covers the demand while it is in flight.
    (constructing, replacement) ← admitted "constructing the replacement" (beginGeneration target (Just generation) turnedAgain)
    let (constructingTurn, _) = runProgressTurn silentEvidence (atMilliseconds 3) constructing
        (constructingAgain, _) = runProgressTurn silentEvidence (atMilliseconds 4) constructingTurn
    -- The retired predecessor is still work, but the replacement demand is not
    -- double-counted while something is building it.
    fmap viewTargetReplacementRequested (targetView target constructingAgain) `shouldBe` Just True

    (published, _) ← admitted "publishing it" (publishGeneration replacement 2 constructing)
    fmap viewTargetReplacementRequested (targetView target published) `shouldBe` Just False

  it "keeps a replacement scheduled while generation capacity is exhausted, and after it returns" $ do
    -- Two live generations per target, so a retired one that cannot yet be
    -- disposed of is enough to refuse the replacement its own request asked for.
    model ← freshModelWith defaultBudgetRequest {requestedGenerations = 2}
    (active, target, first) ← activeTarget 2 model

    -- Settle the first generation's image through the unpresented path, which
    -- leaves no presentation record and completes no cycle.
    (framed, frame) ← acquiredFrame target active
    skipped ← admitted_ "skipping the frame" (skipUnsubmittedFrame frame framed)
    settled ← admitted_ "settling it" (recordCompletion (atMilliseconds 1) (UnpresentedFrameSettled frame) skipped)

    -- Replace it once, so the target now holds a retired generation beside its
    -- active one and has no capacity left.
    (constructing, second) ← admitted "replacing the generation" (beginGeneration target (Just first) settled)
    (published, _) ← admitted "publishing the replacement" (publishGeneration second 2 constructing)
    fmap viewTargetGenerations (targetView target published) `shouldBe` Just 2
    fmap viewTargetReplacementRequested (targetView target published) `shouldBe` Just False

    -- A lost surface asks for another replacement, and the budget refuses to
    -- start one.
    (reserved, lost) ← admitted "reserving" (reserveFrame target published)
    (requested, answer) ← admitted "losing the surface" (acquireImage lost AcquireSurfaceLost reserved)
    answer `shouldBe` ReplacementRequested
    fmap viewTargetReplacementRequested (targetView target requested) `shouldBe` Just True
    backpressured "constructing while at capacity" (beginGeneration target (Just second) requested)
      >>= (`shouldBe` GenerationBudget)

    -- Backpressure is not a refusal of the demand. It is still owed, and the
    -- owner is still asked to come back for it — otherwise the request would be
    -- stranded exactly when the target most needs rebuilding.
    fmap viewTargetReplacementRequested (targetView target requested) `shouldBe` Just True
    nextDeadline requested `shouldSatisfy` (/= NoTurnNeeded)

    -- Free the capacity by disposing the generation that was blocking it.
    ended ← admitted_ "ending the retired generation's CPU use" (endGenerationCpuUse first requested)
    disposalEligible (GenerationSubject first) ended `shouldBe` True
    let (freed, report) = runProgressTurn (silentEvidence {disposalEvidence = const DisposalCompleted}) (atMilliseconds 2) ended
    turnDisposed report `shouldContain` [GenerationSubject first]
    fmap viewTargetGenerations (targetView target freed) `shouldBe` Just 1

    -- The demand survived the disposal that made room for it, and is still
    -- scheduled rather than reported as nothing to do.
    fmap viewTargetReplacementRequested (targetView target freed) `shouldBe` Just True
    pendingObligations freed `shouldSatisfy` (> 0)
    nextDeadline freed `shouldSatisfy` (/= NoTurnNeeded)

    -- And now it can be served.
    (retrying, third) ← admitted "constructing once capacity returned" (beginGeneration target (Just second) freed)
    (servedModel, _) ← admitted "publishing it" (publishGeneration third 2 retrying)
    fmap viewTargetReplacementRequested (targetView target servedModel) `shouldBe` Just False

  it "has no deadline at all once nothing is pending" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    retired ← admitted_ "retiring" (retireGeneration generation active)
    ended ← admitted_ "ending CPU use" (endGenerationCpuUse generation retired)
    pendingObligations ended `shouldSatisfy` (> 0)

    let (disposed, report) = runProgressTurn (silentEvidence {disposalEvidence = const DisposalCompleted}) (atMilliseconds 1) ended
    turnDisposed report `shouldBe` [GenerationSubject generation]
    pendingObligations disposed `shouldBe` 0
    nextDeadline disposed `shouldBe` NoTurnNeeded
    turnNextDeadline report `shouldBe` NoTurnNeeded
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
    submissionOf = \case
      SubmissionRecorded identity → pure identity
      other → fail ("expected a submission record, got " ++ show other)
    presentationOf = \case
      PresentationTracked identity → pure identity
      other → fail ("expected a presentation record, got " ++ show other)
    -- The target's active generation, for an example that needs to name it.
    generationOf target model =
      case targetView target model >>= viewTargetActive of
        Just generation → generation
        Nothing → error "the fixture's target should have an active generation"
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
