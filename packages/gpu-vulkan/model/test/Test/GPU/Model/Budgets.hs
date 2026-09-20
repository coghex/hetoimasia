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
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldSatisfy)

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

    it "answers backpressure for the presentation pool a retired generation shares with the active one" $ do
      -- Three tracked images and two frame slots give a pool of five. A new
      -- generation consumes the target's existing pool, including the records a
      -- retired generation still owes retirements on, rather than receiving one
      -- of its own. That sharing is one way the derived pool binds; the example
      -- below reaches the same bound within a single generation.
      model ← freshModelWith smallRequest {requestedFrameSlots = 2, requestedAggregateFrameSlots = 4, requestedImageTracking = 3}
      (active, target, first) ← activeTarget 3 model
      retiring ← leaveEnqueued target 3 active
      fmap viewTargetPoolRecords (targetView target retiring) `shouldBe` Just 3

      (replacing, replacement) ← admitted "replacing the generation" (beginGeneration target (Just first) retiring)
      (published, _) ← admitted "publishing the replacement" (publishGeneration replacement 3 replacing)
      -- The retired generation's three records are still pending, so the
      -- replacement starts with two of the five left.
      next ← leaveEnqueued target 1 published
      fmap viewTargetPoolRecords (targetView target next) `shouldBe` Just 4

      (reserved, frame) ← admitted "reserving the pool's last record" (reserveFrame target next)
      (acquired, _) ← admitted "acquiring" (acquireImage frame (AcquiredImage 1) reserved)
      fmap viewTargetPoolRecords (targetView target acquired) `shouldBe` Just 5
      -- A slot is still free, so this is the pool answering and not the slots.
      fmap viewTargetFrames (targetView target acquired) `shouldBe` Just 1
      backpressured "reserving beyond the pool" (reserveFrame target acquired)
        >>= (`shouldBe` PresentationPoolBudget)

      -- The refusal took nothing from the admitted frame: its cleanup record is
      -- still there, so it can still be abandoned safely.
      skipped ← admitted_ "skipping the admitted frame" (skipUnsubmittedFrame frame acquired)
      settled ← admitted_ "settling it" (recordCompletion (atMilliseconds 1) (UnpresentedFrameSettled frame) skipped)
      fmap viewTargetPoolRecords (targetView target settled) `shouldBe` Just 4

    it "answers backpressure for a pool one generation exhausted by repeated acquisition" $ do
      -- One tracked image and two frame slots give a pool of three. A new
      -- acquisition of that image is admitted while each older record is still
      -- presenting it, so one generation reaches the pool bound on its own and
      -- the reacquisition that finds no free record is ordinary backpressure.
      model ← freshModelWith smallRequest {requestedFrameSlots = 2, requestedAggregateFrameSlots = 4, requestedImageTracking = 1}
      (active, target, _) ← activeTarget 1 model
      exhausted ← leaveEnqueued target 3 active
      fmap viewTargetPoolRecords (targetView target exhausted) `shouldBe` Just 3
      -- One generation, and every record of it took the target's only image.
      fmap viewTargetGenerations (targetView target exhausted) `shouldBe` Just 1
      -- No slot is in use either, so this is the pool answering and nothing else.
      fmap viewTargetFrames (targetView target exhausted) `shouldBe` Just 0
      backpressured "reserving a record for a fourth acquisition" (reserveFrame target exhausted)
        >>= (`shouldBe` PresentationPoolBudget)

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

    it "reads no more records in one reclamation pass than its budget allows, and reaches the rest later" $ do
      -- Two records the pass must skip and one it can dispose of, with a window
      -- of one. Deciding that a record is ineligible is itself an examination,
      -- so a pass that filtered first would read all three while reporting that
      -- it had read almost nothing.
      model ← freshModelWith smallRequest {requestedReclaimExamination = 1, requestedBytes = 8192}
      (one, held) ← aResource 1024 model
      (two, alsoHeld) ← aResource 1024 one
      (three, disposable) ← aResource 1024 two
      settled ← settleResource disposable three
      usageResources (usage settled) `shouldBe` 3

      -- Each pass reads exactly one record, whether or not that record is
      -- eligible, and the cursor moves on.
      let passes 0 current examined disposed' = pure (current, reverse examined, reverse disposed')
          passes count current examined disposed' =
            let (next, report) = reclaimPass disposing current
             in passes (count - 1 ∷ Int) next (reclaimExamined report : examined) (length (reclaimDisposed report) : disposed')
      (final, examinedCounts, disposedCounts) ← passes 3 settled [] []
      examinedCounts `shouldBe` [1, 1, 1]
      -- Only one of the three is eligible, and the rotation reaches it within
      -- three passes rather than reading the same record for ever.
      sum disposedCounts `shouldBe` 1
      usageResources (usage final) `shouldBe` 2
      disposalEligible (ResourceSubject held) final `shouldBe` False
      disposalEligible (ResourceSubject alsoHeld) final `shouldBe` False

    it "commits a submission whose object was reserved with its frame, even with the budget full" $ do
      -- One tracked image and three objects: the published generation's image,
      -- and the two a reserved frame takes for the pool record and the
      -- submission record it may need.
      model ←
        freshModelWith
          smallRequest {requestedImageTracking = 1, requestedFrameSlots = 1, requestedObjects = 3}
      (active, target, generation) ← activeTarget 1 model
      (framed, frame) ← acquiredFrame target active
      usageObjects (usage framed) `shouldBe` 3

      -- The budget is now full. The native call has already happened by the time
      -- an outcome is reported, so a refusal here would drop the holds for work
      -- that really was submitted. It cannot happen: the object was reserved
      -- before the call, and committing only consumes it.
      (submitted, answer) ← admitted "committing the submission" (submitFrames [frame] SubmissionAccepted framed)
      answer `shouldSatisfy` \case
        SubmissionRecorded _ → True
        _ → False
      usageObjects (usage submitted) `shouldBe` 3
      maybe [] viewOutstanding (holdView (GenerationSubject generation) submitted)
        `shouldContain` [SubmittedUseOwed]

    it "refuses an allocation attempt that reserves neither bytes nor objects" $ do
      model ← freshModelWith smallRequest
      rejected "reserving nothing" (beginAllocation 0 0 model) >>= (`shouldBe` EmptyAllocation)
      -- Such an attempt would be a record that costs nothing and therefore
      -- bounds nothing. Refusing it is what keeps the attempt map finite.
      let before = liveRecordCount model
          attempt current _ = case beginAllocation 0 0 current of
            Admitted (next, _) → next
            _ → current
      liveRecordCount (foldl attempt model [1 .. 200 ∷ Int]) `shouldBe` before

    it "forgets a logical resource once its last generation is disposed of, while still calling it stale" $ do
      model ← freshModelWith smallRequest {requestedBytes = 65536, requestedObjects = 64}
      -- Twenty create/release/dispose cycles. Every record is gone each time, so
      -- the count the model carries is the count it started with rather than one
      -- entry per resource it has ever owned.
      (final, lastResource) ← repeatCycles model (20 ∷ Int)
      liveRecordCount final `shouldBe` liveRecordCount model
      usageResources (usage final) `shouldBe` 0
      usageObjects (usage final) `shouldBe` usageObjects (usage model)
      -- The identity of a resource this session issued is still stale rather
      -- than unknown, decided by the counter rather than by remembering it.
      rejected_ "releasing a disposed resource" (releaseResource lastResource final)
        >>= (`shouldBe` StaleIdentity ResourceIdentity)

    it "keeps the escalation window finite under optional-target churn" $ do
      -- One target record, admitted and lost over and over. Each incarnation is
      -- a distinct notice, so deduplication alone would let the list grow for
      -- ever while no record at all is retained.
      model ← freshModelWith smallRequest {requestedTargetRecords = 1}
      churned ← churn model (40 ∷ Int)
      liveRecordCount churned `shouldBe` 0
      sessionState churned `shouldBe` SessionRunning
      length (escalations churned) `shouldSatisfy` (<= 2)
      -- Nothing vanishes unaccounted: what the window dropped is counted.
      escalationsDropped churned `shouldSatisfy` (> 0)
      fromIntegral (length (escalations churned)) + escalationsDropped churned `shouldBe` (40 ∷ Natural)

      -- A boundary that drains each turn never reaches the bound at all.
      drained ← churnDraining model (40 ∷ Int) 0
      drained `shouldBe` (40 ∷ Int)

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
    -- Admit an optional target, exhaust its recovery, and let the turn forget
    -- the unavailable record so the number is reissued next time round.
    loseOne model = do
      (withTarget, target) ← admitted "admitting an optional target" (admitTarget OptionalTarget model)
      spent ← spend target withTarget (3 ∷ Int) 0
      escalations spent `shouldContain` [OptionalTargetUnavailable target]
      pure (fst (runProgressTurn silentEvidence (atMilliseconds 99999) spent))
    spend target model count now
      | count <= 0 = pure model
      | otherwise = do
          (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds now) target model)
          failed ← admitted_ "failing it" (recordRecoveryFailure (atMilliseconds now) target begun)
          spend target failed (count - 1) (now + 1000)
    churn model count
      | count <= 0 = pure model
      | otherwise = loseOne model >>= \next → churn next (count - 1)
    churnDraining model count seen
      | count <= 0 = pure seen
      | otherwise = do
          next ← loseOne model
          let (emptied, taken) = takeEscalations next
          churnDraining emptied (count - 1) (seen + length taken)
    -- One create / release / end-CPU-use / dispose cycle, answering the model
    -- and the identity the cycle disposed of.
    oneCycle current = do
      (created, resource) ← aResource 1024 current
      released ← admitted_ "releasing" (releaseResource resource created)
      ended ← admitted_ "ending CPU use" (endResourceCpuUse resource released)
      let (reclaimed, report) = reclaimPass disposing ended
      reclaimDisposed report `shouldContain` [ResourceSubject resource]
      pure (reclaimed, resource)
    repeatCycles start count
      | count <= 0 = fail "the fixture ran no cycle at all"
      | otherwise = do
          (next, resource) ← oneCycle start
          if count == 1 then pure (next, resource) else repeatCycles next (count - 1)
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
