-- | Recovery accounting: the bounded attempts of an episode, the delays between
-- them, what may and may not replenish them, and the separate single retry an
-- allocation attempt carries.
module Test.GPU.Model.Recovery (spec) where

import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget (BudgetRequest (requestedFrameSlots, requestedGenerations), defaultBudgetRequest)
import Hetoimasia.GPU.Model.Identity
import Numeric.Natural (Natural)
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "recovery" $ do
  it "allows three construction attempts in an episode, at 100 ms and then 500 ms" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model

    (firstBegun, first) ← admitted "the first attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    first `shouldBe` RecoveryAttempt 1
    firstFailed ← admitted_ "failing the first attempt" (recordRecoveryFailure (atMilliseconds 0) target firstBegun)

    -- The second attempt waits 100 ms, and asking early reports the deadline
    -- rather than spending an attempt.
    (_, early) ← admitted "asking too early" (beginTargetRecovery (atMilliseconds 99) target firstFailed)
    early `shouldBe` RecoveryDeferred (atMilliseconds 100)
    (secondBegun, second) ← admitted "the second attempt" (beginTargetRecovery (atMilliseconds 100) target firstFailed)
    second `shouldBe` RecoveryAttempt 2
    secondFailed ← admitted_ "failing the second attempt" (recordRecoveryFailure (atMilliseconds 100) target secondBegun)

    -- The third waits 500 ms after the second failure.
    (_, stillEarly) ← admitted "asking too early again" (beginTargetRecovery (atMilliseconds 599) target secondFailed)
    stillEarly `shouldBe` RecoveryDeferred (atMilliseconds 600)
    (thirdBegun, third) ← admitted "the third attempt" (beginTargetRecovery (atMilliseconds 600) target secondFailed)
    third `shouldBe` RecoveryAttempt 3
    fmap viewTargetRecoveryAttempts (targetView target thirdBegun) `shouldBe` Just 3
    thirdFailed ← admitted_ "failing the third attempt" (recordRecoveryFailure (atMilliseconds 600) target thirdBegun)

    -- The last failure of an episode is where recovery is exhausted. Leaving it
    -- to whoever next asks for an attempt would leave the target admitted,
    -- unescalated and unscheduled — and on an idle target nobody ever asks.
    fmap viewTargetPhase (targetView target thirdFailed) `shouldBe` Just TargetUnavailable
    escalations thirdFailed `shouldBe` [OptionalTargetUnavailable target]
    fmap viewTargetRenderDemand (targetView target thirdFailed) `shouldBe` Just False
    -- The record is work until it is gone, and only a turn takes it away, so the
    -- owner is asked for one rather than told there is nothing to do.
    nextDeadline thirdFailed `shouldBe` TurnNow
    (_, exhausted) ← admitted "asking for a fourth attempt" (beginTargetRecovery (atMilliseconds 10000) target thirdFailed)
    exhausted `shouldBe` RecoveryClosed

  it "refuses the next attempt when its delay cannot be expressed, rather than skipping the delay" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    -- At the very end of the clock's range, adding the 100 ms delay overflows.
    -- Reading that as no delay would hand the second attempt the instant the
    -- first failed at, which is precisely the delay the episode enforces.
    (begun, first) ← admitted "the first attempt" (beginTargetRecovery lastInstant target active)
    first `shouldBe` RecoveryAttempt 1
    failed ← admitted_ "failing it" (recordRecoveryFailure lastInstant target begun)
    fmap viewTargetRecoveryAttempts (targetView target failed) `shouldBe` Just 1

    (unchanged, answer) ← admitted "asking for the second attempt" (beginTargetRecovery lastInstant target failed)
    answer `shouldBe` RecoveryUnschedulable
    -- No attempt was spent on it either.
    fmap viewTargetRecoveryAttempts (targetView target unchanged) `shouldBe` Just 1

    -- The owner is told there is work it cannot be given an instant for, rather
    -- than told there is nothing to do.
    nextDeadline failed `shouldBe` TurnUnschedulable

  it "is not replenished by a nested helper, by another turn, or by an allocation sub-retry" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    spent ← spendEpisode target active

    -- A nested helper is just another caller of the same accounting.
    (_, nested) ← admitted "a nested helper asking again" (beginTargetRecovery (atMilliseconds 10000) target spent)
    nested `shouldSatisfy` isSpent
    fmap viewTargetRecoveryAttempts (targetView target spent) `shouldBe` Just 3

    -- Turns pass; the budget does not come back.
    let (turned, _) = runProgressTurn silentEvidence (atMilliseconds 20000) spent
        (turnedAgain, _) = runProgressTurn silentEvidence (atMilliseconds 30000) turned
    (_, afterTurns) ← admitted "asking after two turns" (beginTargetRecovery (atMilliseconds 40000) target turnedAgain)
    afterTurns `shouldSatisfy` isSpent
    fmap viewTargetRecoveryAttempts (targetView target turnedAgain) `shouldBe` Just 3

    -- An allocation attempt's own retry is separate accounting and does not
    -- touch the target's episode.
    (allocated, allocation) ← admitted "reserving an allocation" (beginAllocation 1024 1 spent)
    failedAllocation ← admitted_ "failing it" (recordAllocationFailure allocation allocated)
    let (reclaimed, _) = reclaimPass (silentEvidence {disposalEvidence = const DisposalCompleted}) failedAllocation
    (retried, verdict) ← admitted "retrying the allocation" (retryAllocation allocation reclaimed)
    verdict `shouldSatisfy` (`elem` [RetryPermitted, RetryWithoutReclamation])
    (_, afterSubRetry) ← admitted "asking after the sub-retry" (beginTargetRecovery (atMilliseconds 50000) target retried)
    afterSubRetry `shouldSatisfy` isSpent

  it "resets the episode only after a retirement cycle and a full second of healthy progress" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target begun)
    fmap viewTargetRecoveryAttempts (targetView target failed) `shouldBe` Just 1

    -- Time alone does nothing: a quiet hour with no completed cycle is not
    -- healthy progress.
    let (quiet, _) = runProgressTurn silentEvidence (atMilliseconds 3600000) failed
    fmap viewTargetRecoveryAttempts (targetView target quiet) `shouldBe` Just 1

    -- One completed presentation-retirement cycle starts the clock.
    cycled ← completeRetirementCycle target (atMilliseconds 3600000) quiet
    fmap viewTargetRecoveryAttempts (targetView target cycled) `shouldBe` Just 1
    let (tooSoon, _) = runProgressTurn silentEvidence (atMilliseconds 3600999) cycled
    fmap viewTargetRecoveryAttempts (targetView target tooSoon) `shouldBe` Just 1
    let (healthy, _) = runProgressTurn silentEvidence (atMilliseconds 3601000) tooSoon
    fmap viewTargetRecoveryAttempts (targetView target healthy) `shouldBe` Just 0

  it "lets close win over a pending retry and over publishing a completed replacement" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (replacing, replacement) ← admitted "constructing a replacement" (beginGeneration target (Just generation) active)
    closed ← admitted_ "closing the target" (closeTarget target replacing)

    -- The construction succeeded after the close was observed. It is retired,
    -- not published back into active rendering.
    (published, answer) ← admitted "publishing after the close" (publishGeneration replacement 2 closed)
    answer `shouldBe` PublicationSuperseded
    fmap viewTargetActive (targetView target published) `shouldBe` Just Nothing

    (_, retry) ← admitted "asking to retry after the close" (beginTargetRecovery (atMilliseconds 1) target published)
    retry `shouldBe` RecoveryClosed

  it "lets close win over the failure of an attempt that was already outstanding" $ do
    -- A required target, so that exhausting it would fail the whole session —
    -- the loudest thing a late outcome could wrongly cause.
    model ← freshModel
    (active, target, _) ← activeTargetWith RequiredTarget 2 model
    (firstBegun, _) ← admitted "the first attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    firstFailed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target firstBegun)
    (secondBegun, _) ← admitted "the second attempt" (beginTargetRecovery (atMilliseconds 100) target firstFailed)
    secondFailed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 100) target secondBegun)
    (thirdBegun, third) ← admitted "the third attempt" (beginTargetRecovery (atMilliseconds 600) target secondFailed)
    third `shouldBe` RecoveryAttempt 3

    -- Close arrives while that attempt is still in flight.
    closed ← admitted_ "closing the target" (closeTarget target thirdBegun)
    fmap viewTargetPhase (targetView target closed) `shouldBe` Just TargetRetiring

    -- The attempt then fails. It still has to be settled, but its outcome
    -- decides nothing: a retiring target is not one recovery can be exhausted
    -- on, and the session it belongs to is not its to fail.
    late ← admitted_ "the late failure" (recordRecoveryFailure (atMilliseconds 700) target closed)
    sessionState late `shouldBe` SessionRunning
    escalations late `shouldBe` []
    fmap viewTargetPhase (targetView target late) `shouldBe` Just TargetRetiring
    fmap viewTargetRecoveryAttempts (targetView target late) `shouldBe` Just 3
    -- And the attempt really was settled, so nothing is left outstanding.
    (_, afterwards) ← admitted "asking again" (beginTargetRecovery (atMilliseconds 800) target late)
    afterwards `shouldBe` RecoveryClosed

    -- An optional target closed the same way keeps its close rather than being
    -- overwritten as unavailable.
    optionalModel ← freshModel
    (optionalActive, optionalTarget, _) ← activeTarget 2 optionalModel
    optionalSpent ← twoFailures optionalTarget optionalActive
    (optionalThird, _) ← admitted "the third attempt" (beginTargetRecovery (atMilliseconds 600) optionalTarget optionalSpent)
    optionalClosed ← admitted_ "closing it" (closeTarget optionalTarget optionalThird)
    optionalLate ← admitted_ "the late failure" (recordRecoveryFailure (atMilliseconds 700) optionalTarget optionalClosed)
    escalations optionalLate `shouldBe` []
    fmap viewTargetPhase (targetView optionalTarget optionalLate) `shouldBe` Just TargetRetiring

  it "keeps a closed target while its attempt is still in flight, across an owner turn" $ do
    model ← freshModel
    (withTarget, target) ← admitted "admitting a target" (admitTarget OptionalTarget model)
    (begun, first) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target withTarget)
    first `shouldBe` RecoveryAttempt 1
    closed ← admitted_ "closing the target" (closeTarget target begun)

    -- The target holds no frame, generation or pool record, so nothing else
    -- would keep it. The attempt does: forgetting the target would leave its
    -- outcome with nothing to be reported against, and the close-wins rule would
    -- then hold only for as long as no turn happened to run.
    let (turned, _) = runProgressTurn silentEvidence (atMilliseconds 1) closed
    fmap viewTargetPhase (targetView target turned) `shouldBe` Just TargetRetiring

    late ← admitted_ "the late failure" (recordRecoveryFailure (atMilliseconds 2) target turned)
    sessionState late `shouldBe` SessionRunning
    escalations late `shouldBe` []

    -- Settled at last, so the next turn does forget it and its number comes back.
    let (forgotten, _) = runProgressTurn silentEvidence (atMilliseconds 3) late
    targetView target forgotten `shouldBe` Nothing
    (readmitted, again) ← admitted "readmitting" (admitTarget OptionalTarget forgotten)
    targetNumber again `shouldBe` targetNumber target
    targetIncarnation again `shouldBe` targetIncarnation target + 1
    usageTargets (usage readmitted) `shouldBe` 1

  it "retires a generation passed as oldSwapchain even when the replacement construction fails" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (replacing, replacement) ← admitted "constructing a replacement" (beginGeneration target (Just generation) active)
    -- The retirement happened when the old generation was handed over, before
    -- anything could be known about the new one.
    fmap viewTargetActive (targetView target replacing) `shouldBe` Just Nothing

    failed ← admitted_ "failing the construction" (failGenerationConstruction replacement replacing)
    fmap viewTargetActive (targetView target failed) `shouldBe` Just Nothing
    -- Retirement is irreversible: the old generation cannot be handed over a
    -- second time, and it is not resurrected as the active one.
    rejected "handing the retired generation over again" (beginGeneration target (Just generation) failed)
      >>= (`shouldBe` AlreadyConsumed GenerationIdentity)

  it "hands over only the target's published active generation as oldSwapchain" $ do
    model ← freshModelWith defaultBudgetRequest {requestedGenerations = 3}
    (active, target, generation) ← activeTarget 2 model
    (constructing, candidate) ← admitted "constructing a replacement" (beginGeneration target (Just generation) active)

    -- The candidate has nothing to retire: it was never published, and it is not
    -- the target's active generation. Handing it over would record an
    -- irreversible retirement of something that never rendered.
    rejected "handing over a still-constructing candidate" (beginGeneration target (Just candidate) constructing)
      >>= (`shouldBe` WrongPhase GenerationIdentity)
    -- And the refusal wrote nothing: the candidate is still constructing, so it
    -- can still be published.
    fmap viewTargetGenerations (targetView target constructing) `shouldBe` Just 2
    (published, answer) ← admitted "publishing the candidate" (publishGeneration candidate 2 constructing)
    answer `shouldSatisfy` \case
      GenerationPublished _ → True
      _ → False
    fmap viewTargetActive (targetView target published) `shouldBe` Just (Just candidate)

    -- The already-retired predecessor is refused as consumed rather than as a
    -- phase error, because it really was handed over once.
    rejected "handing over the retired predecessor" (beginGeneration target (Just generation) published)
      >>= (`shouldBe` AlreadyConsumed GenerationIdentity)

  it "marks an optional target unavailable and fails the session for a required one" $ do
    optionalModel ← freshModel
    (optionalActive, optionalTarget, _) ← activeTarget 2 optionalModel
    exhaustedModel ← spendEpisode optionalTarget optionalActive
    -- The optional target is isolated: it is unavailable and the session runs on.
    fmap viewTargetPhase (targetView optionalTarget exhaustedModel) `shouldBe` Just TargetUnavailable
    sessionState exhaustedModel `shouldBe` SessionRunning
    escalations exhaustedModel `shouldBe` [OptionalTargetUnavailable optionalTarget]

    requiredModel ← freshModel
    (requiredActive, requiredTarget, _) ← activeTargetWith RequiredTarget 2 requiredModel
    failedModel ← spendEpisode requiredTarget requiredActive
    sessionState failedModel `shouldBe` SessionFailed RequiredTargetUnrecoverable
    escalations failedModel `shouldSatisfy` elem (RequiredTargetFailedSession requiredTarget)

  it "admits one attempt at a time, and only a settled one lets the next begin" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (begun, first) ← admitted "the first attempt" (beginTargetRecovery (atMilliseconds 0) target active)
    first `shouldBe` RecoveryAttempt 1

    -- One construction, one attempt. Asking again while it is in flight would
    -- otherwise spend a second of the episode's three on the same construction.
    (unchanged, again) ← admitted "asking while one is outstanding" (beginTargetRecovery (atMilliseconds 0) target begun)
    again `shouldBe` RecoveryOutstanding
    fmap viewTargetRecoveryAttempts (targetView target unchanged) `shouldBe` Just 1
    (_, andAgain) ← admitted "asking a third time" (beginTargetRecovery (atMilliseconds 0) target unchanged)
    andAgain `shouldBe` RecoveryOutstanding

    -- A success settles it without giving the attempt back, and the next one is
    -- admitted with no delay, because delays follow failures.
    settled ← admitted_ "recording the success" (recordRecoverySuccess target begun)
    fmap viewTargetRecoveryAttempts (targetView target settled) `shouldBe` Just 1
    (second, secondAnswer) ← admitted "the second attempt" (beginTargetRecovery (atMilliseconds 0) target settled)
    secondAnswer `shouldBe` RecoveryAttempt 2
    fmap viewTargetRecoveryAttempts (targetView target second) `shouldBe` Just 2

  it "refuses a failure report with no attempt outstanding, and any recovery once the session has failed" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    -- Accepting this would spend an attempt on a construction that never began,
    -- and install a retry delay out of nowhere.
    rejected_ "reporting a failure with nothing outstanding" (recordRecoveryFailure (atMilliseconds 0) target active)
      >>= (`shouldBe` WrongPhase TargetIdentity)
    rejected_ "reporting a success with nothing outstanding" (recordRecoverySuccess target active)
      >>= (`shouldBe` WrongPhase TargetIdentity)
    fmap viewTargetRecoveryAttempts (targetView target active) `shouldBe` Just 0

    -- Device loss is terminal to the session. A target cannot construct its way
    -- out of it, so no new episode work is admitted.
    let lost = escalateSession DeviceLost active
    rejected "beginning recovery in a failed session" (beginTargetRecovery (atMilliseconds 0) target lost)
      >>= (`shouldBe` SessionAlreadyFailed)

  it "retires rather than publishes a construction that finished after the session failed" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (constructing, replacement) ← admitted "constructing a replacement" (beginGeneration target (Just generation) active)
    let lost = escalateSession DeviceLost constructing
    let accounted = usageObjects (usage lost)

    -- The native construction already happened, so its result has to be owned
    -- for retirement rather than refused at the call or published into a session
    -- that is finished.
    (answered, answer) ← admitted "publishing after device loss" (publishGeneration replacement 2 lost)
    answer `shouldBe` PublicationSuperseded
    fmap viewTargetActive (targetView target answered) `shouldBe` Just Nothing
    disposalEligible (GenerationSubject replacement) answered `shouldBe` False
    usageObjects (usage answered) `shouldBe` accounted
    sessionState answered `shouldBe` SessionFailed DeviceLost

  it "clears a replacement request with the publication that served it, and keeps a newer one pending" $ do
    -- Three live generations, because this example replaces twice and each
    -- superseded generation still owes the presentation obligation of the frame
    -- whose suboptimal acquisition asked for the replacement.
    model ← freshModelWith defaultBudgetRequest {requestedGenerations = 3, requestedFrameSlots = 3}
    (active, target, generation) ← activeTarget 2 model
    fmap viewTargetReplacementRequested (targetView target active) `shouldBe` Just False

    (reserved, frame) ← admitted "reserving" (reserveFrame target active)
    (suboptimal, _) ← admitted "acquiring suboptimally" (acquireImage frame (AcquiredSuboptimalImage 0) reserved)
    fmap viewTargetReplacementRequested (targetView target suboptimal) `shouldBe` Just True

    (constructing, replacement) ← admitted "constructing the replacement" (beginGeneration target (Just generation) suboptimal)
    (published, _) ← admitted "publishing it" (publishGeneration replacement 2 constructing)
    -- The request this construction was begun for is served, so the target no
    -- longer reports one pending.
    fmap viewTargetReplacementRequested (targetView target published) `shouldBe` Just False

    -- A request raised while a replacement is constructing is a different
    -- request, and publishing that replacement does not answer it.
    (secondFrame, second) ← admitted "reserving again" (reserveFrame target published)
    (requested, _) ← admitted "acquiring suboptimally again" (acquireImage second (AcquiredSuboptimalImage 1) secondFrame)
    (constructingAgain, another) ← admitted "constructing again" (beginGeneration target (Just replacement) requested)
    (thirdFrame, third) ← admitted "reserving during construction" (reserveFrame target constructingAgain)
    (later, _) ← admitted "an out-of-date acquisition during construction" (acquireImage third AcquireOutOfDate thirdFrame)
    (publishedAgain, _) ← admitted "publishing the second replacement" (publishGeneration another 2 later)
    fmap viewTargetReplacementRequested (targetView target publishedAgain) `shouldBe` Just True

  describe "allocation attempts" $ do
    it "refuses a retry until a reclamation pass has actually disposed of something" $ do
      model ← freshModel
      (active, _, _) ← activeTarget 2 model
      (allocated, allocation) ← admitted "reserving an allocation" (beginAllocation 1024 1 active)
      failed ← admitted_ "failing it" (recordAllocationFailure allocation allocated)

      (_, tooSoon) ← admitted "retrying before reclaiming" (retryAllocation allocation failed)
      tooSoon `shouldBe` RetryWithoutReclamation

      -- A pass that examines records but disposes of none is not progress.
      (resourced, resource) ← aResource 2048 failed
      released ← admitted_ "releasing" (releaseResource resource resourced)
      ended ← admitted_ "ending CPU use" (endResourceCpuUse resource released)
      let (refusing, refusedReport) = reclaimPass (silentEvidence {disposalEvidence = const DisposalRefused}) ended
      reclaimExamined refusedReport `shouldSatisfy` (> 0)
      reclaimDisposed refusedReport `shouldBe` []
      (_, stillTooSoon) ← admitted "retrying after a pass that disposed of nothing" (retryAllocation allocation refusing)
      stillTooSoon `shouldBe` RetryWithoutReclamation

      -- A pass that failed a disposal is not progress either; it escalates, and
      -- a terminal session then admits no retry at all — permitting one would
      -- invite a native construction whose result the model would refuse to
      -- record.
      let (broken, failureReport) = reclaimPass (silentEvidence {disposalEvidence = const DisposalFailed}) ended
      reclaimFailures failureReport `shouldBe` [ResourceSubject resource]
      sessionState broken `shouldBe` SessionFailed CleanupFailed
      rejected "retrying after a failed disposal" (retryAllocation allocation broken)
        >>= (`shouldBe` SessionAlreadyFailed)

      -- A confirmed disposal is.
      let (reclaimed, report) = reclaimPass (silentEvidence {disposalEvidence = const DisposalCompleted}) ended
      reclaimDisposed report `shouldBe` [ResourceSubject resource]
      (spentRetry, permitted) ← admitted "retrying after real reclamation" (retryAllocation allocation reclaimed)
      permitted `shouldBe` RetryPermitted

      -- And the bit is spent: the same attempt never retries twice.
      retried ← admitted_ "failing the retry" (recordAllocationFailure allocation spentRetry)
      (again, second) ← admitted "retrying a second time" (retryAllocation allocation retried)
      second `shouldBe` RetryAlreadySpent
      (_, third) ← admitted "retrying a third time" (retryAllocation allocation again)
      third `shouldBe` RetryAlreadySpent

    it "refuses a retry in a terminal session, whatever ended it" $ do
      let refusedAfter cause = do
            model ← freshModel
            (active, _, _) ← activeTarget 2 model
            (allocated, allocation) ← admitted "reserving an allocation" (beginAllocation 1024 1 active)
            failed ← admitted_ "failing it" (recordAllocationFailure allocation allocated)
            (resourced, resource) ← aResource 2048 failed
            settled ← settleResource resource resourced
            let (reclaimed, _) = reclaimPass (silentEvidence {disposalEvidence = const DisposalCompleted}) settled
            -- With reclamation credit in hand the retry would otherwise be
            -- permitted, so the session state is the only thing refusing it.
            (_, permitted) ← admitted "retrying while running" (retryAllocation allocation reclaimed)
            permitted `shouldBe` RetryPermitted
            rejected "retrying in a terminal session" (retryAllocation allocation (escalateSession cause reclaimed))
              >>= (`shouldBe` SessionAlreadyFailed)
      refusedAfter DeviceLost
      refusedAfter ValidationError
      refusedAfter UnknownSubmissionEffect
      refusedAfter CleanupFailed

    it "refuses a retry whose attempt already retired a generation as oldSwapchain" $ do
      model ← freshModel
      (active, target, generation) ← activeTarget 2 model
      (allocated, allocation) ← admitted "reserving an allocation" (beginAllocation 1024 1 active)
      (replacing, replacement) ← admitted "constructing a replacement" (beginGeneration target (Just generation) allocated)
      noted ← admitted_ "recording the oldSwapchain retirement" (noteOldSwapchainRetired allocation generation replacing)
      failedConstruction ← admitted_ "failing the construction" (failGenerationConstruction replacement noted)
      failed ← admitted_ "failing the allocation" (recordAllocationFailure allocation failedConstruction)

      -- Even with real reclamation progress behind it, the retry is refused:
      -- the retirement cannot be undone, so the previous creation arguments no
      -- longer describe the state to construct from.
      (resourced, resource) ← aResource 2048 failed
      settled ← settleResource resource resourced
      let (reclaimed, report) = reclaimPass (silentEvidence {disposalEvidence = const DisposalCompleted}) settled
      reclaimDisposed report `shouldSatisfy` elem (ResourceSubject resource)
      (_, verdict) ← admitted "retrying after an irreversible retirement" (retryAllocation allocation reclaimed)
      verdict `shouldBe` RetryAfterOldSwapchainRetirement

    it "refuses to record an oldSwapchain retirement for a generation that was not retired that way" $ do
      model ← freshModel
      (active, target, generation) ← activeTarget 2 model
      (allocated, allocation) ← admitted "reserving an allocation" (beginAllocation 1024 1 active)
      retired ← admitted_ "retiring without handing it over" (retireGeneration generation allocated)
      rejected_ "claiming an oldSwapchain retirement that did not happen" (noteOldSwapchainRetired allocation generation retired)
        >>= (`shouldBe` WrongPhase GenerationIdentity)
      fmap viewTargetActive (targetView target retired) `shouldBe` Just Nothing
  where
    -- Whatever the answer, it is not the admission of a fresh attempt.
    isSpent = \case
      RecoveryAttempt _ → False
      _ → True
    settleResource resource model = do
      released ← admitted_ "releasing" (releaseResource resource model)
      admitted_ "ending CPU use" (endResourceCpuUse resource released)
    -- Two failed attempts, leaving the third available once its delay elapses.
    twoFailures target model = do
      (firstBegun, _) ← admitted "the first attempt" (beginTargetRecovery (atMilliseconds 0) target model)
      firstFailed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 0) target firstBegun)
      (secondBegun, _) ← admitted "the second attempt" (beginTargetRecovery (atMilliseconds 100) target firstFailed)
      admitted_ "failing it" (recordRecoveryFailure (atMilliseconds 100) target secondBegun)
    -- Burn an episode's whole budget: three attempts, each failing.
    spendEpisode target model = go 0 (0 ∷ Natural) model
      where
        go _ 3 current = pure current
        go now count current = do
          (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds now) target current)
          failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds now) target begun)
          go (now + 1000) (count + 1) failed
    -- One full presentation-retirement cycle on the target, which is the first
    -- of the two conditions a recovery reset needs.
    completeRetirementCycle target now model = do
      (framed, frame) ← acquiredFrame target model
      (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
      submission ← case submitAnswer of
        SubmissionRecorded identity → pure identity
        other → fail ("expected a submission record, got " ++ show other)
      (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
      presentation ← case presentAnswer of
        PresentationTracked identity → pure identity
        other → fail ("expected a presentation record, got " ++ show other)
      completed ← admitted_ "completing" (recordCompletion now (SubmissionCompleted submission) presented)
      admitted_ "retiring the presentation" (recordCompletion now (PresentationRetired presentation) completed)
