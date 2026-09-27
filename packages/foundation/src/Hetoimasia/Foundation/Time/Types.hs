-- | The time values: instants, durations, the requirement a duration from
-- caller input states, rejections, conversion results, overflow, sources, and
-- elapsed baselines, each with its instances.
--
-- __Ownership.__ The foundation owns these values. This hidden module of the
-- foundation's main library holds their representations and constructors;
-- "Hetoimasia.Foundation.Time.Arithmetic" owns the validated conversions,
-- constants and arithmetic over them, and "Hetoimasia.Foundation.Time" owns
-- reading a clock and is the only module a client imports. It re-exports
-- 'Duration', 'Instant', 'MonotonicSource' and 'ElapsedBaseline' without their
-- constructors, so they stay abstract outside the package.
--
-- __Dependencies.__ This module imports only @base@: no clock, logging, or
-- failure module, and nothing else from the time family.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.Time.Types
  ( -- * Durations
    Duration (..)

    -- * Validated construction
  , DurationRequirement (..)
  , DurationRejected (..)
  , SecondsConversion (..)

    -- * Instants
  , Instant (..)

    -- * Arithmetic
  , TimeOverflow (..)

    -- * Sources
  , MonotonicSource (..)

    -- * Elapsed sampling
  , ElapsedBaseline (..)
  ) where

import Data.Word (Word64)

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
    -- ^ Above 'Hetoimasia.Foundation.Time.maximumDuration' after rounding.
  deriving (Eq, Show)

-- | A duration converted from seconds, and the rounding the conversion applied.
data SecondsConversion = SecondsConversion
  { convertedDuration ∷ !Duration
  , convertedRounding ∷ !Rational
    -- ^ The converted duration minus the exact input, in nanoseconds. Its
    -- magnitude is at most one half; zero when the input was already a whole
    -- number of nanoseconds.
  }
  deriving (Eq, Show)

-- | An arithmetic result that does not fit the representation.
data TimeOverflow = TimeOverflow
  deriving (Eq, Show)

-- | An injected monotonic clock.
newtype MonotonicSource = MonotonicSource (IO Instant)

-- | The latest raw sample, if any, an elapsed measurement continues from.
newtype ElapsedBaseline = ElapsedBaseline (Maybe Instant)
  deriving (Eq, Show)
