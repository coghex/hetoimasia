-- | Monotonic instants, non-negative durations, and deadline arithmetic.
--
-- __Ownership.__ The foundation owns the values this module exports and the
-- pure arithmetic over them: an injected 'MonotonicSource', opaque 'Instant' and
-- 'Duration' values, validated construction, deadline arithmetic, and elapsed
-- sampling. It chooses no simulation rate and applies no policy. The runtime
-- owns update policy — capping a long sample, turning elapsed time into steps,
-- and pausing — and GLFW owns converting a 'Duration' into a native timed wait.
--
-- __Module structure.__ This is the only time module a client imports. Inside
-- the foundation, the values and their instances are defined in
-- "Hetoimasia.Foundation.Time.Types", and the validated conversions, constants,
-- arithmetic, and the pure baseline rule in
-- "Hetoimasia.Foundation.Time.Arithmetic"; both are hidden modules of the main
-- library, and this module re-exports what clients may use from them without
-- the representations' constructors. This module itself defines only reading a
-- clock, sampling, and the component and operation a clock failure names, and
-- is the only time module that imports the failure and logging modules.
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
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Time.Arithmetic
  ( addDuration
  , addDurations
  , advanceBaseline
  , baselineInstant
  , deadlineReached
  , durationFromNanoseconds
  , durationFromSeconds
  , durationNanoseconds
  , elapsedBetween
  , maximumDuration
  , minimumPositiveDuration
  , noBaseline
  , remainingUntil
  , scriptedInstant
  , zeroDuration
  )
import Hetoimasia.Foundation.Time.Types
  ( Duration
  , DurationRejected (..)
  , DurationRequirement (..)
  , ElapsedBaseline
  , Instant (Instant)
  , MonotonicSource (MonotonicSource)
  , SecondsConversion (..)
  , TimeOverflow (..)
  )

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

-- | Read the source and apply the reading with 'advanceBaseline'. A failed
-- reading raises as 'readInstant' does and yields no baseline.
sampleElapsed ∷ HasCallStack ⇒ MonotonicSource → ElapsedBaseline → IO (Duration, ElapsedBaseline)
sampleElapsed source baseline = do
  sample ← readInstant source
  pure (advanceBaseline sample baseline)
