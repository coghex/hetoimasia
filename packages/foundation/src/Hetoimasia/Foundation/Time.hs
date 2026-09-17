-- | Monotonic instants, non-negative durations, and deadline arithmetic.
--
-- __Ownership.__ The foundation owns the values in this module and the pure
-- arithmetic over them: an injected 'MonotonicSource', opaque 'Instant' and
-- 'Duration' values, validated construction, deadline arithmetic, and elapsed
-- sampling. It chooses no simulation rate and applies no policy. The runtime
-- owns update policy — capping a long sample, turning elapsed time into steps,
-- and pausing — and GLFW owns converting a 'Duration' into a native timed wait.
--
-- __Units and range.__ Both values are whole nanoseconds held in an unsigned
-- 64-bit integer, so neither can be negative. The smallest positive duration is
-- one nanosecond ('minimumPositiveDuration') and the largest representable
-- duration or instant is @2^64 - 1@ nanoseconds, about 584 years
-- ('maximumDuration'). Nothing here is a wall-clock timestamp, a calendar value,
-- or a portable save-file value, and no 'Read', 'UTCTime', or serializable
-- representation exists. 'Show' is diagnostic output only.
--
-- __Validation.__ A duration built from caller input states what it requires.
-- 'AllowZero' is for elapsed durations and remainders; 'RequirePositive' is for
-- a configured period, cap, or timed wait. A rejected input is reported as a
-- 'DurationRejected' reason and never clamped: negative, zero where a positive
-- value is required, non-finite, a positive value below one nanosecond, and a
-- value above 'maximumDuration' are each refused. 'durationFromNanoseconds' is
-- exact. 'durationFromSeconds' takes a 'Double' and rounds to the nearest
-- nanosecond (ties to even); the rounding it applied is returned beside the
-- duration rather than discarded, and a positive input that would round to zero
-- is rejected rather than accepted as zero.
--
-- __Arithmetic.__ 'addDuration' and 'addDurations' report 'TimeOverflow' instead
-- of wrapping or saturating. 'elapsedBetween' and 'remainingUntil' are zero when
-- the later instant is not after the earlier one; that is the specified meaning
-- of elapsed time on a repeated or backward sample and of a remaining duration
-- once a deadline has passed, not an overflow. Deadlines are compared with the
-- 'Ord' instance on 'Instant'.
--
-- __Clock domains.__ Comparing, subtracting, or sampling instants is meaningful
-- only for instants from the same clock domain, and this is the caller's
-- obligation: the types do not distinguish domains. Every 'monotonicSource'
-- reading shares the process's monotonic clock and its epoch, which no source
-- resets, so independently obtained production sources are comparable. A
-- 'scriptedSource' belongs to the domain its script defines, whose instants are
-- built with 'scriptedInstant' as offsets from that script's own origin; they
-- are never comparable with production instants.
--
-- __Sampling.__ 'advanceBaseline' is the pure elapsed-time rule and
-- 'sampleElapsed' reads a source and applies it. The first sample establishes
-- the baseline and reports zero; a sample equal to or earlier than the stored
-- instant reports zero and replaces the baseline, so no time is ever replayed;
-- a later sample reports the full raw difference, uncapped. The stored instant
-- is always the latest raw sample, so after a long pause only the first sample
-- measures the pause and the next one measures only the interval since it.
--
-- __Failure.__ 'readInstant' attributes a failure of the source to
-- 'timeComponent' and 'readClockOperation' through
-- "Hetoimasia.Foundation.Failure": a synchronous failure keeps its own type,
-- payload, and annotations, gains an engine origin if it had none, and always
-- gains the clock's operation context. No instant is fabricated. Cancellation
-- propagates unannotated.
--
-- __State.__ The module owns none. A 'MonotonicSource' is an action;
-- an 'ElapsedBaseline' is an immutable value the caller threads and owns.
--
-- See @docs/time.md@ for the same contract in prose.
module Hetoimasia.Foundation.Time
  ( -- * Durations
    Duration
  , durationNanoseconds
  , zeroDuration
  , minimumPositiveDuration
  , maximumDuration

    -- * Validated construction
  , DurationRequirement (..)
  , DurationRejected (..)
  , durationFromNanoseconds
  , SecondsConversion (..)
  , durationFromSeconds

    -- * Instants
  , Instant
  , scriptedInstant

    -- * Arithmetic
  , TimeOverflow (..)
  , addDuration
  , addDurations
  , elapsedBetween
  , remainingUntil
  , deadlineReached

    -- * Sources
  , MonotonicSource
  , monotonicSource
  , scriptedSource
  , readInstant
  , timeComponent
  , readClockOperation

    -- * Elapsed sampling
  , ElapsedBaseline
  , noBaseline
  , baselineInstant
  , advanceBaseline
  , sampleElapsed
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , evaluate
  , fromException
  , rethrowIO
  , tryWithContext
  )
import Data.Maybe (isJust)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Numeric.Natural (Natural)

-- | A non-negative span of monotonic time, in whole nanoseconds.
newtype Duration = Duration Word64
  deriving (Eq, Ord)

instance Show Duration where
  showsPrec precedence (Duration nanoseconds) =
    showParen (precedence > 10) $ showString "Duration " . shows nanoseconds . showString "ns"

-- | A point on a monotonic clock, in whole nanoseconds from that clock domain's
-- origin. It is not a wall-clock or calendar timestamp.
newtype Instant = Instant Word64
  deriving (Eq, Ord)

instance Show Instant where
  showsPrec precedence (Instant nanoseconds) =
    showParen (precedence > 10) $ showString "Instant " . shows nanoseconds . showString "ns"

-- | The duration in whole nanoseconds.
durationNanoseconds ∷ Duration → Natural
durationNanoseconds (Duration nanoseconds) = fromIntegral nanoseconds

-- | No time.
zeroDuration ∷ Duration
zeroDuration = Duration 0

-- | One nanosecond, the smallest positive duration.
minimumPositiveDuration ∷ Duration
minimumPositiveDuration = Duration 1

-- | @2^64 - 1@ nanoseconds, the largest representable duration.
maximumDuration ∷ Duration
maximumDuration = Duration maxBound

-- | Whether a duration built from caller input may be zero.
data DurationRequirement
  = AllowZero
    -- ^ An elapsed duration or a remainder.
  | RequirePositive
    -- ^ A configured period, cap, or timed wait.
  deriving (Eq, Show)

-- | Why caller input was refused as a duration.
data DurationRejected
  = DurationNegative
  | DurationZero
    -- ^ Zero where 'RequirePositive' was stated.
  | DurationNotFinite
  | DurationBelowResolution
    -- ^ Positive, but it rounds to zero nanoseconds.
  | DurationAboveMaximum
    -- ^ Above 'maximumDuration' after rounding.
  deriving (Eq, Show)

-- | A duration of exactly the given number of nanoseconds.
durationFromNanoseconds ∷ DurationRequirement → Integer → Either DurationRejected Duration
durationFromNanoseconds requirement nanoseconds
  | nanoseconds < 0 = Left DurationNegative
  | nanoseconds == 0 = case requirement of
      AllowZero → Right zeroDuration
      RequirePositive → Left DurationZero
  | nanoseconds > toInteger (maxBound ∷ Word64) = Left DurationAboveMaximum
  | otherwise = Right (Duration (fromInteger nanoseconds))

-- | A duration converted from seconds, and the rounding the conversion applied.
data SecondsConversion = SecondsConversion
  { convertedDuration ∷ !Duration
  , convertedRounding ∷ !Rational
    -- ^ The converted duration minus the exact input, in nanoseconds. Its
    -- magnitude is at most one half; zero when the input was already a whole
    -- number of nanoseconds.
  }
  deriving (Eq, Show)

-- | A duration from a number of seconds, rounded to the nearest nanosecond.
--
-- The input is converted exactly before rounding, so the reported rounding is
-- the whole difference between the 'Double' given and the duration returned.
-- Negative zero is zero.
durationFromSeconds ∷ DurationRequirement → Double → Either DurationRejected SecondsConversion
durationFromSeconds requirement seconds
  | isNaN seconds || isInfinite seconds = Left DurationNotFinite
  | exact < 0 = Left DurationNegative
  | exact > 0 && rounded == 0 = Left DurationBelowResolution
  | otherwise = do
      duration ← durationFromNanoseconds requirement rounded
      pure (SecondsConversion duration (fromInteger rounded - exact))
  where
    exact = toRational seconds * 1000000000
    -- 'round' on a 'Rational' is exact and rounds ties to even.
    rounded = round exact ∷ Integer

-- | An instant in a script's own clock domain: the given duration after that
-- script's origin. Use it only to script a 'scriptedSource' and to state what a
-- script expects; it is never comparable with a production instant.
scriptedInstant ∷ Duration → Instant
scriptedInstant (Duration nanoseconds) = Instant nanoseconds

-- | An arithmetic result that does not fit the representation.
data TimeOverflow = TimeOverflow
  deriving (Eq, Show)

-- | The instant a duration after another.
addDuration ∷ Instant → Duration → Either TimeOverflow Instant
addDuration (Instant start) (Duration offset)
  | offset > maxBound - start = Left TimeOverflow
  | otherwise = Right (Instant (start + offset))

-- | The sum of two durations.
addDurations ∷ Duration → Duration → Either TimeOverflow Duration
addDurations (Duration left) (Duration right)
  | right > maxBound - left = Left TimeOverflow
  | otherwise = Right (Duration (left + right))

-- | @elapsedBetween earlier later@ is the time from @earlier@ to @later@, and
-- zero when @later@ is not after @earlier@. Both must be from one clock domain.
elapsedBetween ∷ Instant → Instant → Duration
elapsedBetween (Instant earlier) (Instant later)
  | later > earlier = Duration (later - earlier)
  | otherwise = zeroDuration

-- | @remainingUntil now deadline@ is the time left before @deadline@, and zero
-- once it has been reached. Both must be from one clock domain.
remainingUntil ∷ Instant → Instant → Duration
remainingUntil = elapsedBetween

-- | @deadlineReached now deadline@ holds once @now@ is at or after @deadline@.
deadlineReached ∷ Instant → Instant → Bool
deadlineReached now deadline = now >= deadline

-- | An injected monotonic clock.
newtype MonotonicSource = MonotonicSource (IO Instant)

-- | The process's monotonic clock. Every reading shares its epoch, so instants
-- from any use of this source are comparable.
monotonicSource ∷ MonotonicSource
monotonicSource = MonotonicSource (Instant <$> getMonotonicTimeNSec)

-- | A source whose readings are the given action's results, for tests. The
-- script may repeat or move backwards, and may fail; its instants belong to the
-- script's own domain (see 'scriptedInstant').
scriptedSource ∷ IO Instant → MonotonicSource
scriptedSource = MonotonicSource

-- | The component a clock failure names.
timeComponent ∷ Component
timeComponent = unsafeComponent "foundation.time"

-- | The operation a clock failure names.
readClockOperation ∷ Operation
readClockOperation = operation "read-monotonic-clock"

-- | Read one instant.
--
-- A synchronous failure of the source propagates with its own type, payload,
-- and annotations. It gains an engine origin naming 'timeComponent' and
-- 'readClockOperation' when it carried no origin, keeps an earlier origin when
-- it did, and in both cases gains the same operation context. The instant is
-- evaluated before it is returned, so a faulting reading fails here. An
-- asynchronous exception propagates with nothing added.
readInstant ∷ HasCallStack ⇒ MonotonicSource → IO Instant
readInstant (MonotonicSource reading) =
  withOperationContext timeComponent readClockOperation [] $ do
    outcome ← tryWithContext (reading >>= evaluate)
    case outcome of
      Right instant → pure instant
      Left caught@(ExceptionWithContext _ (exception ∷ SomeException))
        | isJust (fromException exception ∷ Maybe SomeAsyncException) → rethrowIO caught
        -- The failure travels with its context: a bare 'SomeException' would
        -- be given a fresh one when it is thrown again.
        | otherwise → throwFailure timeComponent readClockOperation [] caught

-- | The latest raw sample, if any, an elapsed measurement continues from.
newtype ElapsedBaseline = ElapsedBaseline (Maybe Instant)
  deriving (Eq, Show)

-- | No sample has been taken.
noBaseline ∷ ElapsedBaseline
noBaseline = ElapsedBaseline Nothing

-- | The stored instant: the latest raw sample.
baselineInstant ∷ ElapsedBaseline → Maybe Instant
baselineInstant (ElapsedBaseline stored) = stored

-- | Apply one sample: the elapsed duration it contributes and the new baseline,
-- which is always the sample itself.
advanceBaseline ∷ Instant → ElapsedBaseline → (Duration, ElapsedBaseline)
advanceBaseline sample (ElapsedBaseline stored) =
  (maybe zeroDuration (`elapsedBetween` sample) stored, ElapsedBaseline (Just sample))

-- | Read the source and apply the reading with 'advanceBaseline'. A failed
-- reading raises as 'readInstant' does and yields no baseline.
sampleElapsed ∷ HasCallStack ⇒ MonotonicSource → ElapsedBaseline → IO (Duration, ElapsedBaseline)
sampleElapsed source baseline = do
  sample ← readInstant source
  pure (advanceBaseline sample baseline)
