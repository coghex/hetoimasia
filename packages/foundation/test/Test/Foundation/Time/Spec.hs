-- | Examples for 'Hetoimasia.Foundation.Time'.
--
-- Every scripted example asserts exact values and never sleeps: a scripted
-- source returns the instants its script lists, so time moves only when the
-- example says it does. Cancellation is coordinated with 'MVar's; 'bounded' only
-- stops an example that has already hung. The one example over the process's
-- monotonic clock asserts ordering alone, never an amount of elapsed time.
--
-- The external-client examples live in "Test.Foundation.Time.Opacity" and are
-- composed into this group, so @--match Time@ selects all of them.
module Test.Foundation.Time.Spec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , annotateIO
  , fromException
  , throwIO
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (getExceptionAnnotations)
import Data.IORef (atomicModifyIORef', newIORef)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , Operation
  , OperationContext (..)
  , failureEvidenceInContext
  , operation
  , throwFailure
  )
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Time
import qualified Test.Foundation.Time.Opacity as Opacity
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "Time" $ do
  describe "Duration validation" $ do
    it "accepts zero only where zero is allowed"
      testZero
    it "accepts the smallest positive and the largest representable nanosecond count"
      testNanosecondBoundaries
    it "rejects a negative count and a count above the maximum"
      testNanosecondRejections
    it "converts whole-nanosecond seconds exactly and reports rounding otherwise"
      testSecondsRounding
    it "rejects negative, non-finite, sub-resolution, and overflowing seconds"
      testSecondsRejections
    it "accepts seconds at the top of the range and rejects the next representable value"
      testSecondsMaximum

  describe "Deadline arithmetic" $ do
    it "adds zero and adds up to the maximum instant exactly"
      testAddition
    it "reports overflow instead of wrapping"
      testOverflow
    it "measures the difference forward and zero backward"
      testElapsedBetween
    it "reports the remainder until a future deadline and zero once expired"
      testDeadlines
    it "orders deadlines from one source"
      testDeadlineOrder

  describe "Elapsed sampling" $ do
    it "reports zero on the first sample and establishes the baseline"
      testFirstSample
    it "reports zero on a repeated sample"
      testRepeatedSample
    it "reports zero on a backward sample and replaces the baseline"
      testBackwardSample
    it "reports a long forward jump in full and does not recharge it"
      testLongJump
    it "samples the process monotonic clock in order"
      testProductionClock

  describe "Clock failure" $ do
    it "attributes a native source failure and keeps its type and payload"
      testNativeFailure
    it "keeps an earlier origin and annotation while adding the clock context"
      testAnnotatedFailure
    it "leaves a synchronously raised asynchronous exception unannotated"
      testSynchronousCancellation
    it "leaves a delivered cancellation unannotated and returns no instant"
      testDeliveredCancellation

  Opacity.spec

-- Fixtures -------------------------------------------------------------------

nanoseconds ∷ Integer → Duration
nanoseconds count = either (error . show) id (durationFromNanoseconds AllowZero count)

at ∷ Integer → Instant
at = scriptedInstant . nanoseconds

maximumNanoseconds ∷ Integer
maximumNanoseconds = 2 ^ (64 ∷ Int) - 1

-- | A source that returns each scripted reading in turn.
scripted ∷ [IO Instant] → IO MonotonicSource
scripted readings = do
  remaining ← newIORef readings
  pure . scriptedSource $ do
    next ← atomicModifyIORef' remaining $ \case
      reading : rest → (rest, reading)
      [] → ([], throwIO (ErrorCall "the script is exhausted"))
    next

-- | Take one sample after another, returning each elapsed duration.
samples ∷ [Integer] → IO ([Duration], ElapsedBaseline)
samples readings = do
  source ← scripted (map (pure . at) readings)
  let go baseline [] = pure ([], baseline)
      go baseline (_ : rest) = do
        (elapsed, next) ← sampleElapsed source baseline
        (more, final) ← go next rest
        pure (elapsed : more, final)
  go noBaseline readings

data SourceBroken = SourceBroken String
  deriving (Eq, Show)

instance Exception SourceBroken

newtype Marker = Marker String
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

expectContext ∷ Exception e ⇒ IO a → IO (ExceptionWithContext e)
expectContext action = do
  outcome ← tryWithContext action
  case outcome of
    Left caught → pure caught
    Right _ → fail "expected the action to fail, but it returned"

clockContext ∷ OperationContext → (Component, Operation)
clockContext context = (contextComponent context, contextOperation context)

expectedClockContext ∷ (Component, Operation)
expectedClockContext = (timeComponent, readClockOperation)

-- Duration validation --------------------------------------------------------

testZero ∷ Expectation
testZero = do
  durationFromNanoseconds AllowZero 0 `shouldBe` Right zeroDuration
  durationFromNanoseconds RequirePositive 0 `shouldBe` Left DurationZero
  fmap convertedDuration (durationFromSeconds AllowZero 0) `shouldBe` Right zeroDuration
  fmap convertedDuration (durationFromSeconds AllowZero (-0)) `shouldBe` Right zeroDuration
  durationFromSeconds RequirePositive 0 `shouldBe` Left DurationZero
  durationNanoseconds zeroDuration `shouldBe` 0

testNanosecondBoundaries ∷ Expectation
testNanosecondBoundaries = do
  durationFromNanoseconds RequirePositive 1 `shouldBe` Right minimumPositiveDuration
  durationNanoseconds minimumPositiveDuration `shouldBe` 1
  durationFromNanoseconds RequirePositive maximumNanoseconds `shouldBe` Right maximumDuration
  toInteger (durationNanoseconds maximumDuration) `shouldBe` maximumNanoseconds

testNanosecondRejections ∷ Expectation
testNanosecondRejections = do
  durationFromNanoseconds AllowZero (-1) `shouldBe` Left DurationNegative
  durationFromNanoseconds RequirePositive (-1) `shouldBe` Left DurationNegative
  durationFromNanoseconds AllowZero (maximumNanoseconds + 1) `shouldBe` Left DurationAboveMaximum
  durationFromNanoseconds RequirePositive (maximumNanoseconds + 1) `shouldBe` Left DurationAboveMaximum

testSecondsRounding ∷ Expectation
testSecondsRounding = do
  durationFromSeconds RequirePositive 2 `shouldBe` Right (SecondsConversion (nanoseconds 2000000000) 0)
  durationFromSeconds RequirePositive 0.5 `shouldBe` Right (SecondsConversion (nanoseconds 500000000) 0)
  -- 0.1 has no exact binary representation; the rounding is surfaced exactly.
  durationFromSeconds RequirePositive 0.1
    `shouldBe` Right (SecondsConversion (nanoseconds 100000000) (100000000 - toRational (0.1 ∷ Double) * 1000000000))
  -- The smallest positive seconds value that is still one nanosecond.
  fmap convertedDuration (durationFromSeconds RequirePositive 1e-9) `shouldBe` Right minimumPositiveDuration
  fmap convertedDuration (durationFromSeconds RequirePositive 5.1e-10) `shouldBe` Right minimumPositiveDuration
  fmap convertedRounding (durationFromSeconds RequirePositive 1e-9) `shouldSatisfy` either (const False) ((<= 1 / 2) . abs)

testSecondsRejections ∷ Expectation
testSecondsRejections = do
  durationFromSeconds AllowZero (-1e-9) `shouldBe` Left DurationNegative
  durationFromSeconds RequirePositive (-1) `shouldBe` Left DurationNegative
  durationFromSeconds AllowZero (0 / 0) `shouldBe` Left DurationNotFinite
  durationFromSeconds RequirePositive (1 / 0) `shouldBe` Left DurationNotFinite
  durationFromSeconds RequirePositive (-1 / 0) `shouldBe` Left DurationNotFinite
  -- A positive input that would round to zero is never accepted as zero, even
  -- where zero itself is allowed.
  durationFromSeconds RequirePositive 4e-10 `shouldBe` Left DurationBelowResolution
  durationFromSeconds AllowZero 4e-10 `shouldBe` Left DurationBelowResolution
  durationFromSeconds RequirePositive 5e-324 `shouldBe` Left DurationBelowResolution
  durationFromSeconds RequirePositive 1e11 `shouldBe` Left DurationAboveMaximum

testSecondsMaximum ∷ Expectation
testSecondsMaximum = do
  -- The largest Double at or below the maximum, and the next one above it.
  let maximumSeconds = fromRational (toRational maximumNanoseconds / 1000000000) ∷ Double
      below = if toRational maximumSeconds * 1000000000 > toRational maximumNanoseconds then predecessor maximumSeconds else maximumSeconds
      above = successor below
      predecessor value = encodeFloat (fst (decodeFloat value) - 1) (snd (decodeFloat value))
      successor value = encodeFloat (fst (decodeFloat value) + 1) (snd (decodeFloat value))
  case durationFromSeconds RequirePositive below of
    Right conversion → do
      toInteger (durationNanoseconds (convertedDuration conversion)) `shouldSatisfy` (<= maximumNanoseconds)
      toInteger (durationNanoseconds (convertedDuration conversion)) `shouldSatisfy` (> maximumNanoseconds - 4096)
    Left rejection → expectationFailure ("expected the top of the range to be accepted: " <> show rejection)
  durationFromSeconds RequirePositive above `shouldBe` Left DurationAboveMaximum

-- Deadline arithmetic --------------------------------------------------------

testAddition ∷ Expectation
testAddition = do
  addDuration (at 7) zeroDuration `shouldBe` Right (at 7)
  addDuration (at 7) (nanoseconds 5) `shouldBe` Right (at 12)
  addDuration (at 0) maximumDuration `shouldBe` Right (at maximumNanoseconds)
  addDuration (at 1) (nanoseconds (maximumNanoseconds - 1)) `shouldBe` Right (at maximumNanoseconds)
  addDurations zeroDuration zeroDuration `shouldBe` Right zeroDuration
  addDurations (nanoseconds 3) (nanoseconds (maximumNanoseconds - 3)) `shouldBe` Right maximumDuration

testOverflow ∷ Expectation
testOverflow = do
  addDuration (at 1) maximumDuration `shouldBe` Left TimeOverflow
  addDuration (at maximumNanoseconds) minimumPositiveDuration `shouldBe` Left TimeOverflow
  addDurations maximumDuration minimumPositiveDuration `shouldBe` Left TimeOverflow
  addDurations maximumDuration maximumDuration `shouldBe` Left TimeOverflow

testElapsedBetween ∷ Expectation
testElapsedBetween = do
  elapsedBetween (at 10) (at 25) `shouldBe` nanoseconds 15
  elapsedBetween (at 10) (at 10) `shouldBe` zeroDuration
  elapsedBetween (at 25) (at 10) `shouldBe` zeroDuration
  elapsedBetween (at 0) (at maximumNanoseconds) `shouldBe` maximumDuration

testDeadlines ∷ Expectation
testDeadlines = do
  let deadline = at 100
  remainingUntil (at 40) deadline `shouldBe` nanoseconds 60
  deadlineReached (at 40) deadline `shouldBe` False
  remainingUntil (at 100) deadline `shouldBe` zeroDuration
  deadlineReached (at 100) deadline `shouldBe` True
  remainingUntil (at 250) deadline `shouldBe` zeroDuration
  deadlineReached (at 250) deadline `shouldBe` True

testDeadlineOrder ∷ Expectation
testDeadlineOrder = do
  source ← scripted [pure (at 5)]
  now ← readInstant source
  soon ← either (fail . show) pure (addDuration now (nanoseconds 10))
  later ← either (fail . show) pure (addDuration now (nanoseconds 20))
  compare soon later `shouldBe` LT
  min later soon `shouldBe` at 15
  maximum [later, soon, now] `shouldBe` at 25

-- Elapsed sampling -----------------------------------------------------------

testFirstSample ∷ Expectation
testFirstSample = do
  (elapsed, baseline) ← samples [1000]
  elapsed `shouldBe` [zeroDuration]
  baselineInstant baseline `shouldBe` Just (at 1000)
  baselineInstant noBaseline `shouldBe` Nothing

testRepeatedSample ∷ Expectation
testRepeatedSample = do
  (elapsed, baseline) ← samples [1000, 1000, 1004]
  elapsed `shouldBe` [zeroDuration, zeroDuration, nanoseconds 4]
  baselineInstant baseline `shouldBe` Just (at 1004)

testBackwardSample ∷ Expectation
testBackwardSample = do
  -- The backward sample contributes nothing, and the following sample measures
  -- from it rather than from the earlier, later-valued baseline: 900 to 950,
  -- not a replayed debt from 1000.
  (elapsed, baseline) ← samples [1000, 900, 950]
  elapsed `shouldBe` [zeroDuration, zeroDuration, nanoseconds 50]
  baselineInstant baseline `shouldBe` Just (at 950)
  advanceBaseline (at 3) (snd (advanceBaseline (at 8) noBaseline))
    `shouldBe` (zeroDuration, snd (advanceBaseline (at 3) noBaseline))

testLongJump ∷ Expectation
testLongJump = do
  let hour = 3600 * 1000000000
  (elapsed, baseline) ← samples [10, 10 + hour, 10 + hour + 16]
  elapsed `shouldBe` [zeroDuration, nanoseconds hour, nanoseconds 16]
  baselineInstant baseline `shouldBe` Just (at (10 + hour + 16))

testProductionClock ∷ Expectation
testProductionClock = do
  first ← readInstant monotonicSource
  -- A second use of the production source shares the first's epoch.
  (_, baseline) ← sampleElapsed monotonicSource noBaseline
  second ← maybe (fail "expected a baseline") pure (baselineInstant baseline)
  second `shouldSatisfy` (>= first)
  (_, later) ← sampleElapsed monotonicSource baseline
  baselineInstant later `shouldSatisfy` maybe False (>= second)

-- Clock failure --------------------------------------------------------------

testNativeFailure ∷ Expectation
testNativeFailure = do
  source ← scripted [throwIO (SourceBroken "no clock")]
  ExceptionWithContext context failure ← expectContext @SourceBroken (sampleElapsed source noBaseline)
  failure `shouldBe` SourceBroken "no clock"
  let evidence = failureEvidenceInContext context
  case failureCause evidence of
    EngineOrigin origin → do
      originComponent origin `shouldBe` timeComponent
      originOperation origin `shouldBe` readClockOperation
    NativeCause → expectationFailure ("expected the clock to be the origin: " <> show evidence)
  map clockContext (failureContexts evidence) `shouldBe` [expectedClockContext]

testAnnotatedFailure ∷ Expectation
testAnnotatedFailure = do
  let driver = unsafeComponent "test.clock-driver"
      query = operation "query-counter"
  source ←
    scripted
      [annotateIO (Marker "driver note") (throwFailure driver query [("counter", "7")] (SourceBroken "stalled"))]
  ExceptionWithContext context failure ← expectContext @SourceBroken (readInstant source)
  failure `shouldBe` SourceBroken "stalled"
  (getExceptionAnnotations context ∷ [Marker]) `shouldBe` [Marker "driver note"]
  let evidence = failureEvidenceInContext context
  case failureCause evidence of
    EngineOrigin origin → do
      originComponent origin `shouldBe` driver
      originOperation origin `shouldBe` query
      originIdentifiers origin `shouldBe` [("counter", "7")]
    NativeCause → expectationFailure ("expected the earlier origin to be kept: " <> show evidence)
  map clockContext (failureContexts evidence) `shouldBe` [expectedClockContext]

testSynchronousCancellation ∷ Expectation
testSynchronousCancellation = do
  source ← scripted [throwIO ThreadKilled]
  ExceptionWithContext context failure ← expectContext @AsyncException (readInstant source)
  failure `shouldBe` ThreadKilled
  failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []

testDeliveredCancellation ∷ Expectation
testDeliveredCancellation = bounded $ do
  entered ← newEmptyMVar
  never ← newEmptyMVar
  finished ← newEmptyMVar
  let source = scriptedSource (putMVar entered () >> takeMVar never)
  worker ← forkIO $ do
    outcome ← tryWithContext @SomeException (readInstant source)
    putMVar finished outcome
  takeMVar entered
  killThread worker
  outcome ← takeMVar finished
  case outcome of
    Right instant → expectationFailure ("expected cancellation, but read " <> show instant)
    Left (ExceptionWithContext context failure) → do
      fromException failure `shouldBe` Just ThreadKilled
      failureEvidenceInContext context `shouldBe` FailureEvidence NativeCause []
