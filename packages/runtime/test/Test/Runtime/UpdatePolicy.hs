-- | Examples for 'Hetoimasia.Runtime.UpdatePolicy': demand queries, bounded
-- variable-step elapsed time, fixed-step accounting, and pause and resume.
--
-- Every instant comes from a script's own clock domain through
-- 'scriptedInstant', and the resume example samples a 'scriptedSource'. Nothing
-- reads the process clock or sleeps, so each example asserts exact values.
module Test.Runtime.UpdatePolicy (spec) where

import Data.IORef (atomicModifyIORef', newIORef)
import Data.Ratio ((%))
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (AllowZero)
  , Instant
  , TimeOverflow (TimeOverflow)
  , advanceBaseline
  , baselineInstant
  , durationFromNanoseconds
  , durationNanoseconds
  , maximumDuration
  , minimumPositiveDuration
  , noBaseline
  , readInstant
  , sampleElapsed
  , scriptedInstant
  , scriptedSource
  , zeroDuration
  )
import Hetoimasia.Runtime.UpdatePolicy
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Update policy" $ do
  describe "demand" $ do
    it "reports no demand with no deadline and no remaining interval" $ do
      queryDemand (at 5) NoDemand `shouldBe` NotDemanded
      demandRemaining (at 5) NoDemand `shouldBe` Nothing

    it "reports a future deadline as pending with the time left" $ do
      queryDemand (at 4) (DeadlineDemand (at 10)) `shouldBe` DemandPending (ms 6)
      demandRemaining (at 4) (DeadlineDemand (at 10)) `shouldBe` Just (ms 6)

    it "reports a deadline at or before the query instant as due, never as a zero or negative wait" $ do
      queryDemand (at 10) (DeadlineDemand (at 10)) `shouldBe` DemandDue
      queryDemand (at 25) (DeadlineDemand (at 10)) `shouldBe` DemandDue
      demandRemaining (at 25) (DeadlineDemand (at 10)) `shouldBe` Just zeroDuration

    it "turns a removed deadline into no demand and leaves other demand unchanged" $ do
      removeDeadline (DeadlineDemand (at 10)) `shouldBe` NoDemand
      queryDemand (at 25) (removeDeadline (DeadlineDemand (at 10))) `shouldBe` NotDemanded
      removeDeadline ImmediateDemand `shouldBe` ImmediateDemand
      removeDeadline NoDemand `shouldBe` NoDemand

    it "reports immediate demand as due at every instant, the busy loop a consumer chose" $
      mapM_
        ( \instant → do
            queryDemand instant ImmediateDemand `shouldBe` DemandDue
            demandRemaining instant ImmediateDemand `shouldBe` Just zeroDuration
        )
        [at 0, at 0, at 1, at 1000, scriptedInstant maximumDuration]

  describe "configuration" $ do
    it "rejects a zero step duration" $
      fixedStepConfig zeroDuration (ms 70) 3 `shouldBe` Left StepDurationNotPositive

    it "rejects a zero elapsed cap" $ do
      fixedStepConfig (ms 10) zeroDuration 3 `shouldBe` Left ElapsedCapNotPositive
      variableStepConfig zeroDuration `shouldBe` Left ElapsedCapNotPositive

    it "rejects a zero or negative step budget" $ do
      fixedStepConfig (ms 10) (ms 70) 0 `shouldBe` Left StepBudgetNotPositive
      fixedStepConfig (ms 10) (ms 70) (-1) `shouldBe` Left StepBudgetNotPositive
      fixedStepConfig (ms 10) (ms 70) minBound `shouldBe` Left StepBudgetNotPositive

    it "accepts the smallest positive values and reports what it was given" $ do
      config ← expectRight (fixedStepConfig minimumPositiveDuration minimumPositiveDuration 1)
      fixedStepDuration config `shouldBe` minimumPositiveDuration
      fixedStepElapsedCap config `shouldBe` minimumPositiveDuration
      fixedStepBudget config `shouldBe` 1
      variable ← expectRight (variableStepConfig minimumPositiveDuration)
      variableStepElapsedCap variable `shouldBe` minimumPositiveDuration

  describe "variable step" $ do
    it "delivers elapsed time below the cap in full" $
      checkVariable (ms 70) (ms 20) (VariableStep (ms 20) zeroDuration)

    it "delivers elapsed time at the cap in full" $
      checkVariable (ms 70) (ms 70) (VariableStep (ms 70) zeroDuration)

    it "clips elapsed time above the cap and reports exactly what was clipped" $
      checkVariable (ms 70) (ms 85) (VariableStep (ms 70) (ms 15))

    it "delivers zero elapsed time as zero" $
      checkVariable (ms 70) zeroDuration (VariableStep zeroDuration zeroDuration)

    it "clips the largest representable sample without wrapping" $
      checkVariable minimumPositiveDuration maximumDuration (VariableStep minimumPositiveDuration (ns (maxNs - 1)))

  describe "fixed step" $ do
    it "runs nothing for zero elapsed time and keeps the remainder" $ do
      (turn, policy) ← advanced (ms 10) (ms 70) 3 [(at 0, ms 4)]
      let (next, policy') = advanceFixedStep (at 0) zeroDuration policy
      stepsToRun next `shouldBe` 0
      retainedRemainder next `shouldBe` ms 4
      discardedTime next `shouldBe` zeroDuration
      nextStepDue next `shouldBe` Right (at 6)
      fixedStepRemainder policy' `shouldBe` retainedRemainder turn

    it "runs exactly one step for exactly one step of elapsed time" $ do
      (turn, _) ← advanced (ms 10) (ms 70) 3 [(at 10, ms 10)]
      turn `shouldBe` expectedTurn 1 (ms 0) zeroDuration zeroDuration (at 20)

    it "runs nothing for a fraction of a step and carries it" $ do
      (turn, policy) ← advanced (ms 10) (ms 70) 3 [(at 7, ms 7)]
      turn `shouldBe` expectedTurn 0 (ms 7) zeroDuration zeroDuration (at 10)
      interpolationFraction policy `shouldBe` 7 % 10

    it "clips and drops steps on a long jump, keeping no replay debt" $ do
      (turn, policy) ← advanced (ms 10) (ms 70) 3 [(at 3, ms 3), (at 5003, ms 5000)]
      turn `shouldBe` expectedTurn 3 (ms 3) (ms 4930) (ms 40) (at 5010)
      discardedTime turn `shouldBe` ms 4970
      let (next, _) = advanceFixedStep (at 5010) (ms 7) policy
      next `shouldBe` expectedTurn 1 zeroDuration zeroDuration zeroDuration (at 5020)

    it "holds the design's worked example exactly" $ do
      config ← expectRight (fixedStepConfig (ms 10) (ms 70) 3)
      let (_, primed) = advanceFixedStep (at 0) (ms 4) (fixedStepPolicy config)
          (turn, policy) = advanceFixedStep (at 100) (ms 85) primed
      fixedStepRemainder primed `shouldBe` ms 4
      stepsToRun turn `shouldBe` 3
      stepTime config turn `shouldBe` nanosecondsOf (ms 30)
      retainedRemainder turn `shouldBe` ms 4
      clippedTime turn `shouldBe` ms 15
      droppedStepTime turn `shouldBe` ms 40
      discardedTime turn `shouldBe` ms 55
      nextStepDue turn `shouldBe` Right (at 106)
      fixedStepRemainder policy `shouldBe` ms 4

    it "accounts exactly over a sequence of samples" $ do
      config ← expectRight (fixedStepConfig (ms 10) (ms 70) 3)
      let samples = [ms 0, ms 4, ms 85, ms 9, ms 1, ms 200, ms 10, ms 33, ms 70, ms 71]
          go policy [] = pure policy
          go policy (elapsed : rest) = do
            let (turn, policy') = advanceFixedStep (at 0) elapsed policy
            nanosecondsOf (fixedStepRemainder policy) + nanosecondsOf elapsed
              `shouldBe` stepTime config turn + nanosecondsOf (retainedRemainder turn) + nanosecondsOf (discardedTime turn)
            nanosecondsOf (discardedTime turn)
              `shouldBe` nanosecondsOf (clippedTime turn) + nanosecondsOf (droppedStepTime turn)
            stepsToRun turn `shouldSatisfy` (<= 3)
            retainedRemainder turn `shouldSatisfy` (< ms 10)
            go policy' rest
      final ← go (fixedStepPolicy config) samples
      fixedStepRemainder final `shouldBe` ms 7

    it "accounts exactly at the limits of the representation without wrapping" $ do
      let half = ns (2 ^ (63 ∷ Int))
      config ← expectRight (fixedStepConfig half maximumDuration 3)
      let (_, primed) = advanceFixedStep (at 0) (ns (2 ^ (63 ∷ Int) - 1)) (fixedStepPolicy config)
          (turn, policy) = advanceFixedStep (at 0) maximumDuration primed
      stepsToRun turn `shouldBe` 2
      stepTime config turn `shouldBe` 2 ^ (64 ∷ Int)
      nanosecondsOf (fixedStepRemainder primed) + maxNs
        `shouldBe` stepTime config turn + nanosecondsOf (retainedRemainder turn) + nanosecondsOf (discardedTime turn)
      retainedRemainder turn `shouldBe` ns (2 ^ (63 ∷ Int) - 2)
      interpolationFraction policy `shouldSatisfy` (< 1)
      interpolationFraction policy `shouldBe` (2 ^ (63 ∷ Int) - 2) % 2 ^ (63 ∷ Int)

    it "reports an unrepresentable next-step instant as an overflow" $ do
      (turn, _) ← advanced (ms 10) (ms 70) 3 [(scriptedInstant maximumDuration, ms 1)]
      nextStepDue turn `shouldBe` Left TimeOverflow
      retainedRemainder turn `shouldBe` ms 1

    it "places the next step absolutely, so work consumes or exceeds the interval" $ do
      (turn, _) ← advanced (ms 10) (ms 70) 3 [(at 100, ms 4), (at 185, ms 85)]
      next ← expectRight (nextStepDue turn)
      queryDemand (at 185) (DeadlineDemand next) `shouldBe` DemandPending (ms 6)
      queryDemand (at 189) (DeadlineDemand next) `shouldBe` DemandPending (ms 2)
      queryDemand (at 191) (DeadlineDemand next) `shouldBe` DemandDue
      queryDemand (at 250) (DeadlineDemand next) `shouldBe` DemandDue
      demandRemaining (at 250) (DeadlineDemand next) `shouldBe` Just zeroDuration

    it "reports interpolation from zero to just below one" $ do
      config ← expectRight (fixedStepConfig (ms 10) (ms 70) 3)
      let policyAfter elapsed = snd (advanceFixedStep (at 0) elapsed (fixedStepPolicy config))
      interpolationFraction (fixedStepPolicy config) `shouldBe` 0
      interpolationFraction (policyAfter (ms 10)) `shouldBe` 0
      interpolationFraction (policyAfter (ns (10000000 - 1))) `shouldBe` 9999999 % 10000000
      big ← expectRight (fixedStepConfig maximumDuration maximumDuration 1)
      let nearOne = snd (advanceFixedStep (at 0) (ns (maxNs - 1)) (fixedStepPolicy big))
      interpolationFraction nearOne `shouldBe` toInteger (maxNs - 1) % toInteger maxNs
      interpolationFraction nearOne `shouldSatisfy` (< 1)

  describe "pause and resume" $ do
    it "clears the remainder and simulates none of the paused interval" $ do
      config ← expectRight (fixedStepConfig (ms 10) (ms 70) 3)
      let (_, running) = advanceFixedStep (at 0) (ms 8) (fixedStepPolicy config)
      fixedStepRemainder running `shouldBe` ms 8
      reading ← scriptedReadings [at 0, at 1000, at 1004]
      let source = scriptedSource reading
      (_, pausedBaseline) ← sampleElapsed source noBaseline
      resumedAt ← readInstant source
      let paused = pauseFixedStep running
          (resumed, resumedBaseline) = resumeFixedStep resumedAt paused
      fixedStepRemainder resumed `shouldBe` zeroDuration
      fixedStepPolicyConfig resumed `shouldBe` config
      baselineInstant resumedBaseline `shouldBe` Just (at 1000)
      baselineInstant (resumeBaseline (at 1000)) `shouldBe` Just (at 1000)
      (elapsed, _) ← sampleElapsed source resumedBaseline
      elapsed `shouldBe` ms 4
      fst (advanceBaseline (at 1004) pausedBaseline) `shouldBe` ms 1004
      let (turn, _) = advanceFixedStep (at 1004) elapsed resumed
      turn `shouldBe` expectedTurn 0 (ms 4) zeroDuration zeroDuration (at 1010)

    it "clears no remainder through any other operation" $ do
      config ← expectRight (fixedStepConfig (ms 10) (ms 70) 3)
      let (_, running) = advanceFixedStep (at 0) (ms 8) (fixedStepPolicy config)
          (_, idle) = advanceFixedStep (at 50) zeroDuration running
      fixedStepRemainder idle `shouldBe` ms 8
      fixedStepRemainder (fixedStepPolicy (fixedStepPolicyConfig idle)) `shouldBe` zeroDuration

-- | Milliseconds as a duration.
ms ∷ Natural → Duration
ms count = ns (count * 1000000)

-- | Nanoseconds as a duration.
ns ∷ Natural → Duration
ns count = case durationFromNanoseconds AllowZero (toInteger count) of
  Right duration → duration
  Left reason → error ("test duration out of range: " <> show reason)

-- | The scripted instant this many milliseconds after the script's origin.
at ∷ Natural → Instant
at = scriptedInstant . ms

maxNs ∷ Natural
maxNs = nanosecondsOf maximumDuration

nanosecondsOf ∷ Duration → Natural
nanosecondsOf = durationNanoseconds

stepTime ∷ FixedStepConfig → FixedStepTurn → Natural
stepTime config turn = fromIntegral (stepsToRun turn) * nanosecondsOf (fixedStepDuration config)

checkVariable ∷ Duration → Duration → VariableStep → IO ()
checkVariable cap raw expected = do
  config ← expectRight (variableStepConfig cap)
  let bounded = boundElapsed config raw
  bounded `shouldBe` expected
  nanosecondsOf (deliveredElapsed bounded) + nanosecondsOf (clippedElapsed bounded) `shouldBe` nanosecondsOf raw

-- | The last turn and policy after applying each sample to a new policy.
advanced ∷ Duration → Duration → Int → [(Instant, Duration)] → IO (FixedStepTurn, FixedStepPolicy)
advanced step cap budget samples = do
  config ← expectRight (fixedStepConfig step cap budget)
  case samples of
    [] → fail "no samples"
    first : rest → do
      let apply (_, policy) (instant, elapsed) = advanceFixedStep instant elapsed policy
          start = uncurry advanceFixedStep first (fixedStepPolicy config)
      pure (foldl apply start rest)

expectedTurn ∷ Int → Duration → Duration → Duration → Instant → FixedStepTurn
expectedTurn steps remainder clipped dropped next =
  FixedStepTurn
    { stepsToRun = steps
    , retainedRemainder = remainder
    , clippedTime = clipped
    , droppedStepTime = dropped
    , discardedTime = ns (nanosecondsOf clipped + nanosecondsOf dropped)
    , nextStepDue = Right next
    }

-- | An action returning each reading in turn.
scriptedReadings ∷ [Instant] → IO (IO Instant)
scriptedReadings readings = do
  remaining ← newIORef readings
  pure $ atomicModifyIORef' remaining $ \case
    next : rest → (rest, next)
    [] → ([], error "scripted source exhausted")

expectRight ∷ Show e ⇒ Either e a → IO a
expectRight = either (fail . show) pure
