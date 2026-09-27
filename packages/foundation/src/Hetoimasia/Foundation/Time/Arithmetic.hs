-- | Validated conversions, duration constants, and non-wrapping arithmetic over
-- the time values, including the pure elapsed-baseline rule.
--
-- __Ownership.__ The foundation owns this arithmetic. This hidden module of the
-- foundation's main library defines it over the representations in
-- "Hetoimasia.Foundation.Time.Types"; "Hetoimasia.Foundation.Time" re-exports
-- every name here and is the only module a client imports. Reading a clock and
-- attributing its failures belong to that module, not this one.
--
-- __Dependencies.__ This module imports only
-- "Hetoimasia.Foundation.Time.Types" and @base@: no clock, logging, or failure
-- module. Everything here is pure.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.Time.Arithmetic
  ( -- * Durations
    durationNanoseconds
  , zeroDuration
  , minimumPositiveDuration
  , maximumDuration

    -- * Validated construction
  , durationFromNanoseconds
  , durationFromSeconds

    -- * Instants
  , scriptedInstant

    -- * Arithmetic
  , addDuration
  , addDurations
  , elapsedBetween
  , remainingUntil
  , deadlineReached

    -- * Elapsed sampling
  , noBaseline
  , baselineInstant
  , advanceBaseline
  ) where

import Data.Word (Word64)
import Hetoimasia.Foundation.Time.Types
  ( Duration (Duration)
  , DurationRejected (..)
  , DurationRequirement (..)
  , ElapsedBaseline (ElapsedBaseline)
  , Instant (Instant)
  , SecondsConversion (SecondsConversion)
  , TimeOverflow (TimeOverflow)
  )
import Numeric.Natural (Natural)

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

-- | A duration of exactly the given number of nanoseconds.
durationFromNanoseconds ∷ DurationRequirement → Integer → Either DurationRejected Duration
durationFromNanoseconds requirement nanoseconds
  | nanoseconds < 0 = Left DurationNegative
  | nanoseconds == 0 = case requirement of
      AllowZero → Right zeroDuration
      RequirePositive → Left DurationZero
  | nanoseconds > toInteger (maxBound ∷ Word64) = Left DurationAboveMaximum
  | otherwise = Right (Duration (fromInteger nanoseconds))

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
-- script's origin. Use it only to script a
-- 'Hetoimasia.Foundation.Time.scriptedSource' and to state what a script
-- expects; it is never comparable with a production instant.
scriptedInstant ∷ Duration → Instant
scriptedInstant (Duration nanoseconds) = Instant nanoseconds

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
