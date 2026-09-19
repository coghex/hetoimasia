-- | Recovery accounting: the bounded attempts of an episode, the delays between
-- them, what may and may not replenish them, and the separate single retry an
-- allocation attempt carries.
module Test.GPU.Model.Recovery (spec) where

import Hetoimasia.GPU.Model
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

    (_, exhausted) ← admitted "asking for a fourth attempt" (beginTargetRecovery (atMilliseconds 10000) target thirdFailed)
    exhausted `shouldBe` RecoveryExhausted (OptionalTargetUnavailable target)

  it "is not replenished by a nested helper, by another turn, or by an allocation sub-retry" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    spent ← spendEpisode target active

    -- A nested helper is just another caller of the same accounting.
    (_, nested) ← admitted "a nested helper asking again" (beginTargetRecovery (atMilliseconds 10000) target spent)
    nested `shouldSatisfy` isExhausted

    -- Turns pass; the budget does not come back.
    let (turned, _) = runProgressTurn silentEvidence (atMilliseconds 20000) spent
        (turnedAgain, _) = runProgressTurn silentEvidence (atMilliseconds 30000) turned
    (_, afterTurns) ← admitted "asking after two turns" (beginTargetRecovery (atMilliseconds 40000) target turnedAgain)
    afterTurns `shouldSatisfy` isExhausted

    -- An allocation attempt's own retry is separate accounting and does not
    -- touch the target's episode.
    (allocated, allocation) ← admitted "reserving an allocation" (beginAllocation 1024 1 spent)
    failedAllocation ← admitted_ "failing it" (recordAllocationFailure allocation allocated)
    let (reclaimed, _) = reclaimPass (silentEvidence {disposalEvidence = const DisposalCompleted}) failedAllocation
    (retried, verdict) ← admitted "retrying the allocation" (retryAllocation allocation reclaimed)
    verdict `shouldSatisfy` (`elem` [RetryPermitted, RetryWithoutReclamation])
    (_, afterSubRetry) ← admitted "asking after the sub-retry" (beginTargetRecovery (atMilliseconds 50000) target retried)
    afterSubRetry `shouldSatisfy` isExhausted

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

  it "marks an optional target unavailable and fails the session for a required one" $ do
    optionalModel ← freshModel
    (optionalActive, optionalTarget, _) ← activeTarget 2 optionalModel
    optionalSpent ← spendEpisode optionalTarget optionalActive
    (_, optionalAnswer) ← admitted "exhausting an optional target" (beginTargetRecovery (atMilliseconds 9999) optionalTarget optionalSpent)
    exhaustedModel ← exhaust optionalTarget optionalSpent
    optionalAnswer `shouldBe` RecoveryExhausted (OptionalTargetUnavailable optionalTarget)
    sessionState exhaustedModel `shouldBe` SessionRunning
    escalations exhaustedModel `shouldBe` [OptionalTargetUnavailable optionalTarget]

    requiredModel ← freshModel
    (requiredActive, requiredTarget, _) ← activeTargetWith RequiredTarget 2 requiredModel
    requiredSpent ← spendEpisode requiredTarget requiredActive
    failedModel ← exhaust requiredTarget requiredSpent
    sessionState failedModel `shouldBe` SessionFailed RequiredTargetUnrecoverable
    escalations failedModel `shouldSatisfy` elem (RequiredTargetFailedSession requiredTarget)

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

      -- A pass that failed a disposal is not progress either; it escalates.
      let (broken, failureReport) = reclaimPass (silentEvidence {disposalEvidence = const DisposalFailed}) ended
      reclaimFailures failureReport `shouldBe` [ResourceSubject resource]
      sessionState broken `shouldBe` SessionFailed CleanupFailed
      (_, afterFailure) ← admitted "retrying after a failed disposal" (retryAllocation allocation broken)
      afterFailure `shouldBe` RetryWithoutReclamation

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
    isExhausted = \case
      RecoveryExhausted _ → True
      _ → False
    settleResource resource model = do
      released ← admitted_ "releasing" (releaseResource resource model)
      admitted_ "ending CPU use" (endResourceCpuUse resource released)
    -- Burn an episode's whole budget: three attempts, each failing.
    spendEpisode target model = go 0 (0 ∷ Natural) model
      where
        go _ 3 current = pure current
        go now count current = do
          (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds now) target current)
          failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds now) target begun)
          go (now + 1000) (count + 1) failed
    exhaust target model = do
      (exhausted, _) ← admitted "exhausting the episode" (beginTargetRecovery (atMilliseconds 99999) target model)
      pure exhausted
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
