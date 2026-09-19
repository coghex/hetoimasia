-- | Validated configuration, every budget's exhaustion, and the storage bound
-- that exhaustion is there to establish.
--
-- The distinction these examples hold to is that an exhausted budget is
-- backpressure and not a failure: it names the budget, changes nothing, and
-- leaves everything already admitted exactly as capable of being settled as it
-- was.
module Test.GPU.Model.Budgets (spec) where

import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget
import Hetoimasia.GPU.Model.Identity
import Numeric.Natural (Natural)
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "admission budgets" $ do
  describe "validation" $ do
    it "rejects a zero and a negative limit without clamping either" $ do
      validateBudgets defaultBudgetRequest {requestedFrameSlots = 0}
        `shouldBe` Left (BudgetNotPositive FrameSlotBudget 0)
      validateBudgets defaultBudgetRequest {requestedTargetRecords = -1}
        `shouldBe` Left (BudgetNotPositive TargetRecordBudget (-1))
      validateBudgets defaultBudgetRequest {requestedBytes = 0}
        `shouldBe` Left (BudgetNotPositive ByteBudget 0)
      validateBudgets defaultBudgetRequest {requestedProgressActions = -32}
        `shouldBe` Left (BudgetNotPositive ProgressActionBudget (-32))

    it "rejects a limit above the representable ceiling" $
      validateBudgets defaultBudgetRequest {requestedObjects = budgetCeiling + 1}
        `shouldBe` Left (BudgetAboveCeiling ObjectBudget (budgetCeiling + 1))

    it "rejects a configuration whose derived presentation pool would overflow" $
      -- Each field is individually representable; their checked sum is not.
      validateBudgets defaultBudgetRequest {requestedImageTracking = budgetCeiling}
        `shouldBe` Left (DerivedBudgetOverflows PresentationPoolBudget (budgetCeiling + 2))

    it "derives the presentation pool from the image limit and the frame slots" $ do
      budgets ← validated defaultBudgetRequest
      imageTrackingLimit budgets `shouldBe` 16
      frameSlotLimit budgets `shouldBe` 2
      presentationPoolCapacity budgets `shouldBe` 18
      -- Raising frame capacity raises the pool with it rather than leaving a
      -- frozen constant behind.
      wider ← validated defaultBudgetRequest {requestedFrameSlots = 3}
      presentationPoolCapacity wider `shouldBe` 19

    it "lays out the idle backoff schedule its cap describes" $ do
      budgets ← validated defaultBudgetRequest
      backoffSchedule budgets `shouldBe` map millisecondsDuration [5, 10, 20, 40, 80, 100]
      -- A smaller cap shortens the schedule instead of overshooting it.
      quick ← validated defaultBudgetRequest {requestedIdleBackoffMilliseconds = 25}
      backoffSchedule quick `shouldBe` map millisecondsDuration [5, 10, 20, 25]

  describe "exhaustion" $ do
    it "answers backpressure, not failure, for the target-record budget" $ do
      model ← freshModelWith smallRequest
      (one, _) ← admitted "admitting the first target" (admitTarget OptionalTarget model)
      (two, _) ← admitted "admitting the second target" (admitTarget OptionalTarget one)
      kind ← backpressured "admitting a third target" (admitTarget OptionalTarget two)
      kind `shouldBe` TargetRecordBudget
      -- Nothing failed: the session is running and the two admitted targets are
      -- untouched.
      sessionState two `shouldBe` SessionRunning
      usageTargets (usage two) `shouldBe` 2

    it "answers backpressure for the per-target and the aggregate frame-slot budgets" $ do
      model ← freshModelWith smallRequest
      (first, targetOne, _) ← activeTarget 2 model
      (second, targetTwo, _) ← activeTarget 2 first
      (oneFrame, _) ← admitted "reserving on the first target" (reserveFrame targetOne second)
      -- One slot per target: the second reservation on the same target is
      -- refused before the aggregate is even consulted.
      backpressured "reserving twice on one target" (reserveFrame targetOne oneFrame)
        >>= (`shouldBe` FrameSlotBudget)
      (twoFrames, _) ← admitted "reserving on the second target" (reserveFrame targetTwo oneFrame)
      -- Two aggregate slots, both taken. A third target does not exist, so the
      -- aggregate is proved by refusing a target that still has a free slot.
      widened ← freshModelWith smallRequest {requestedFrameSlots = 2, requestedAggregateFrameSlots = 1}
      (wideActive, wideTarget, _) ← activeTarget 2 widened
      (wideOne, _) ← admitted "reserving the aggregate's only slot" (reserveFrame wideTarget wideActive)
      backpressured "reserving beyond the aggregate" (reserveFrame wideTarget wideOne)
        >>= (`shouldBe` AggregateFrameSlotBudget)
      usageFrames (usage twoFrames) `shouldBe` 2

    it "answers backpressure for the live-generation budget, counting retired generations" $ do
      model ← freshModelWith smallRequest {requestedGenerations = 2}
      (active, target, generation) ← activeTarget 2 model
      (replacing, replacement) ← admitted "replacing the generation" (beginGeneration target (Just generation) active)
      -- The old generation is retired, not gone: it still occupies one of the
      -- two live records, so a third construction is refused.
      fmap viewTargetGenerations (targetView target replacing) `shouldBe` Just 2
      backpressured "constructing a third generation" (beginGeneration target Nothing replacing)
        >>= (`shouldBe` GenerationBudget)
      (published, _) ← admitted "publishing the replacement" (publishGeneration replacement 2 replacing)
      backpressured "constructing a third generation after publication" (beginGeneration target Nothing published)
        >>= (`shouldBe` GenerationBudget)

    it "answers backpressure for the presentation pool, without touching a record already reserved for an admitted frame" $ do
      -- Two frame slots and a two-image tracking limit give a pool of four.
      model ← freshModelWith smallRequest {requestedFrameSlots = 2, requestedAggregateFrameSlots = 4}
      (active, target, _) ← activeTarget 2 model
      filled ← leaveEnqueued target 3 active
      fmap viewTargetPoolRecords (targetView target filled) `shouldBe` Just 3

      (reserved, frame) ← admitted "reserving the pool's last record" (reserveFrame target filled)
      (acquired, _) ← admitted "acquiring" (acquireImage frame (AcquiredImage 0) reserved)
      fmap viewTargetPoolRecords (targetView target acquired) `shouldBe` Just 4
      backpressured "reserving beyond the pool" (reserveFrame target acquired)
        >>= (`shouldBe` PresentationPoolBudget)

      -- The refusal took nothing from the admitted frame: its cleanup record is
      -- still there, so it can still be abandoned safely.
      skipped ← admitted_ "skipping the admitted frame" (skipUnsubmittedFrame frame acquired)
      settled ← admitted_ "settling it" (recordCompletion (atMilliseconds 1) (UnpresentedFrameSettled frame) skipped)
      fmap viewTargetPoolRecords (targetView target settled) `shouldBe` Just 3

    it "answers backpressure for the byte and object budgets" $ do
      model ← freshModelWith smallRequest {requestedBytes = 2048, requestedObjects = 8}
      (allocated, _) ← admitted "reserving 2 KiB" (beginAllocation 2048 1 model)
      backpressured "reserving another byte" (beginAllocation 1 1 allocated)
        >>= (`shouldBe` ByteBudget)
      objectsOnly ← freshModelWith smallRequest {requestedObjects = 2}
      (first, _) ← admitted "reserving two objects" (beginAllocation 1 2 objectsOnly)
      backpressured "reserving a third object" (beginAllocation 1 1 first)
        >>= (`shouldBe` ObjectBudget)

  describe "image tracking and retired work" $ do
    it "refuses to publish a candidate whose image count exceeds the tracking limit, and retires it instead" $ do
      model ← freshModelWith smallRequest
      (withTarget, target) ← admitted "admitting" (admitTarget OptionalTarget model)
      (constructing, generation) ← admitted "constructing" (beginGeneration target Nothing withTarget)
      (answered, answer) ← admitted "publishing an over-limit candidate" (publishGeneration generation 3 constructing)
      answer `shouldBe` GenerationRefusedImageCount 3 2
      -- It is not active, the target has none, and it is still tracked and
      -- accounted until it is safely retired.
      fmap viewTargetActive (targetView target answered) `shouldBe` Just Nothing
      fmap viewTargetGenerations (targetView target answered) `shouldBe` Just 1
      disposalEligible (GenerationSubject generation) answered `shouldBe` False
      usageObjects (usage answered) `shouldSatisfy` (> 0)
      -- A driver answer of no images at all is refused the same way.
      empty' ← freshModelWith smallRequest
      (emptyTarget, otherTarget) ← admitted "admitting" (admitTarget OptionalTarget empty')
      (emptyConstructing, emptyGeneration) ← admitted "constructing" (beginGeneration otherTarget Nothing emptyTarget)
      (_, emptyAnswer) ← admitted "publishing" (publishGeneration emptyGeneration 0 emptyConstructing)
      emptyAnswer `shouldBe` GenerationRefusedImageCount 0 2

    it "keeps retired work in the accounting until it is actually disposed of" $ do
      model ← freshModelWith smallRequest
      (active, _, generation) ← activeTarget 2 model
      let published = usageObjects (usage active)
      retired ← admitted_ "retiring" (retireGeneration generation active)
      ended ← admitted_ "ending CPU use" (endGenerationCpuUse generation retired)
      -- Retirement moved nothing out of the metrics.
      usageObjects (usage ended) `shouldBe` published
      let (reclaimed, report) = reclaimPass (silentEvidence {disposalEvidence = const DisposalCompleted}) ended
      reclaimDisposed report `shouldBe` [GenerationSubject generation]
      usageObjects (usage reclaimed) `shouldBe` published - 2

    it "examines no more records in one reclamation pass than its budget allows" $ do
      model ← freshModelWith smallRequest {requestedReclaimExamination = 1, requestedBytes = 8192}
      (one, first) ← aResource 1024 model
      (two, second) ← aResource 1024 one
      settledOne ← settleResource first two
      settledTwo ← settleResource second settledOne
      let (afterFirst, firstReport) = reclaimPass disposing settledTwo
      reclaimExamined firstReport `shouldBe` 1
      length (reclaimDisposed firstReport) `shouldBe` 1
      let (_, secondReport) = reclaimPass disposing afterFirst
      reclaimExamined secondReport `shouldBe` 1
      length (reclaimDisposed secondReport) `shouldBe` 1

  describe "storage" $
    it "stays finite when no completion ever arrives" $ do
      model ← freshModelWith smallRequest
      (active, target, _) ← activeTarget 2 model
      let attempt (current, refusals) _ = case reserveFrame target current of
            Backpressure _ → (current, refusals + 1 ∷ Natural)
            Rejected _ → (current, refusals)
            Admitted (reserved, frame) → case acquireImage frame (AcquiredImage 0) reserved of
              Admitted (acquired, _) → case submitFrames [frame] SubmissionAccepted acquired of
                Admitted (submitted, _) → (submitted, refusals)
                _ → (acquired, refusals)
              _ → (reserved, refusals)
          (final, refused) = foldl attempt (active, 0) [1 .. 200 ∷ Int]
      -- Nothing ever completed, so the admitted work is stuck. The point is that
      -- the model then refuses rather than growing: almost every attempt was
      -- backpressure, and the record count is a function of the configuration,
      -- not of how many attempts were made.
      refused `shouldSatisfy` (> 190)
      liveRecordCount final `shouldSatisfy` (<= 16)
      usageSubmissions (usage final) `shouldSatisfy` (<= 1)
      sessionState final `shouldBe` SessionRunning
  where
    validated request = either (fail . show) pure (validateBudgets request)
    disposing = silentEvidence {disposalEvidence = const DisposalCompleted}
    settleResource resource model = do
      released ← admitted_ "releasing" (releaseResource resource model)
      admitted_ "ending CPU use" (endResourceCpuUse resource released)
    -- Drive `count` frames all the way to an enqueued presentation whose
    -- submission has completed, so each leaves one pool record pending while
    -- giving its slot back.
    leaveEnqueued target count model
      | count <= (0 ∷ Natural) = pure model
      | otherwise = do
          (framed, frame) ← acquiredFrame target model
          (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
          submission ← case submitAnswer of
            SubmissionRecorded identity → pure identity
            other → fail ("expected a submission record, got " ++ show other)
          (presented, _) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
          completed ← admitted_ "completing" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) presented)
          leaveEnqueued target (count - 1) completed
