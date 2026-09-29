-- | The scheduled owner loop's pacing decisions, as pure functions.
--
-- Nothing here reads a clock, captures demand, or makes a native call: the
-- scheduled loop in "Hetoimasia.Runtime.GLFW.Internal.Host.Loop" samples the
-- instant and captures the request on the owner thread and hands both here,
-- and applies the answer. So every decision can be checked without a host, a
-- session, or a thread.
module Hetoimasia.Runtime.GLFW.Internal.Host.Pacing
  ( UpdateSchedule (..)
  , TurnPacing (..)
  , pacingWaited
  , scheduleDeadline
  , earliestDeadline
  , earlierOf
  , choosePacing
  ) where

import Hetoimasia.Foundation.Time (Duration, Instant, deadlineReached, remainingUntil)
import Hetoimasia.GLFW.Internal.Demand (CapturedDemand (..), demandDeadline)

-- | The application's own ongoing schedule: what its update opportunity last
-- answered, which the loop stores until the next answer replaces it.
--
-- It is never combined with an earlier answer and never with a captured
-- request, so an old request can never become permanent work and finishing an
-- update implies no immediate demand for another.
data UpdateSchedule
  = NoUpdateDemand
    -- ^ Continue with no deadline of its own.
  | UpdateImmediately
    -- ^ Continue, wanting the next turn now.
  | UpdateBy !Instant
    -- ^ Continue, wanting an opportunity by this absolute instant, in
    -- 'hostClock'\'s domain.
  deriving (Eq, Show)

-- | How a scheduled turn's native step was chosen.
data TurnPacing
  = PolledForWork
    -- ^ Work was ready at the inspection: a command queued, an application
    -- event ready, or immediate demand from the schedule or the captured
    -- request.
  | PolledForDeadline
    -- ^ Nothing was ready and the earliest deadline had been reached, so the
    -- turn polled rather than waiting no time at all.
  | WaitedForDeadline !Duration
    -- ^ The wait was the remaining time to the earliest deadline, which was
    -- nearer than the fallback bound.
  | WaitedForFallback !Duration
    -- ^ The wait was the configured fallback bound, because no deadline was
    -- nearer and none may extend it.
  deriving (Eq, Show)

-- | Whether a pacing made a finite native wait.
pacingWaited ∷ TurnPacing → Bool
pacingWaited = \case
  WaitedForDeadline _ → True
  WaitedForFallback _ → True
  PolledForWork → False
  PolledForDeadline → False

-- | The deadline of a schedule, if it named one.
scheduleDeadline ∷ UpdateSchedule → Maybe Instant
scheduleDeadline = \case
  UpdateBy due → Just due
  UpdateImmediately → Nothing
  NoUpdateDemand → Nothing

-- | The earlier of the application's own deadline and the captured request's.
earliestDeadline ∷ UpdateSchedule → Maybe CapturedDemand → Maybe Instant
earliestDeadline schedule captured =
  earlierOf (scheduleDeadline schedule) (demandDeadline . capturedRequest =<< captured)

-- | The earlier of two optional deadlines.
earlierOf ∷ Maybe Instant → Maybe Instant → Maybe Instant
earlierOf Nothing later = later
earlierOf earlier Nothing = earlier
earlierOf (Just earlier) (Just later) = Just (min earlier later)

-- | Choose the turn's native step from the sampled instant, the earliest
-- deadline, and whether work is ready.
choosePacing ∷ Duration → Instant → Maybe Instant → Bool → TurnPacing
choosePacing bound now deadline ready
  | ready = PolledForWork
  | Just due ← deadline =
      if deadlineReached now due
        then PolledForDeadline
        else
          let remaining = remainingUntil now due
           in if remaining < bound then WaitedForDeadline remaining else WaitedForFallback bound
  | otherwise = WaitedForFallback bound
