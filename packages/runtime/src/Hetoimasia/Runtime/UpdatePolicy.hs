-- | Demand, variable-step, and fixed-step update policies over monotonic time.
--
-- __Ownership.__ The runtime owns update policy: whether a consumer wants a
-- turn and by when, how much of a raw elapsed sample a consumer is handed, how
-- elapsed time becomes whole fixed steps, what is discarded after a long pause,
-- and how an explicit simulation pause is resumed. The foundation owns the
-- 'Duration' and 'Instant' values and elapsed sampling this module builds on;
-- GLFW owns converting a duration into a native wait. This module owns no
-- rendering decision, and window visibility is never a pause.
--
-- __State.__ The module owns none. A 'FixedStepPolicy' and a 'PausedFixedStep'
-- are immutable values the caller owns and threads from one turn to the next.
-- Nothing here reads a clock, sleeps, starts a thread, or holds a global: the
-- caller samples its own source and passes the instant and elapsed duration in.
--
-- __Demand.__ A 'Demand' is no current demand, immediate demand, or an absolute
-- deadline. 'queryDemand' reports no demand, due, or pending with a strictly
-- positive remaining duration; an immediate demand and a deadline at or before
-- the query instant are due, never pending with a zero or negative wait.
-- 'demandRemaining' is the same answer as a duration: none for no demand, zero
-- once due. A zero there is query evidence, not a native wait instruction.
-- Removing a deadline yields no demand. A consumer that returns immediate
-- demand every turn has explicitly chosen a busy loop.
--
-- __Variable step.__ 'boundElapsed' hands a consumer at most its configured cap
-- of a raw elapsed sample and reports exactly how much was clipped, so delivered
-- plus clipped is always the raw sample.
--
-- __Fixed step.__ 'advanceFixedStep' adds the capped elapsed time to the
-- retained remainder, runs at most the configured budget of whole steps, drops
-- whole overdue steps beyond it, keeps only the sub-step remainder, and reports
-- the clipped and dropped time separately and as a total. For every input,
-- in nanoseconds, old remainder + raw elapsed = steps × step + new remainder +
-- discarded time. The next step is due at the sample instant plus the step
-- minus the new remainder, so time the caller then spends executing steps
-- consumes that interval rather than resetting it. No replay queue grows with
-- an interruption. The arithmetic is carried out on unbounded naturals, so no
-- intermediate value wraps; only the next-step instant can fail to fit, and it
-- then reports 'TimeOverflow'.
--
-- __Pause.__ 'pauseFixedStep' and 'resumeFixedStep' are the only operations that
-- discard a remainder. Resuming at an instant clears the remainder and returns
-- an elapsed baseline stored at that instant, so the next sample contributes
-- only the time since the resume and none of the paused interval. There is no
-- in-place reconfiguration: a new rate or budget is a new policy built from a
-- new configuration, which starts from no remainder rather than reinterpreting
-- the old one.
--
-- See @docs/scheduling.md@ for the same contract in prose.
module Hetoimasia.Runtime.UpdatePolicy
  ( -- * Demand
    Demand (..)
  , removeDeadline
  , DemandQuery (..)
  , queryDemand
  , demandRemaining

    -- * Configuration
  , PolicyRejected (..)
  , VariableStepConfig
  , variableStepConfig
  , variableStepElapsedCap
  , FixedStepConfig
  , fixedStepConfig
  , fixedStepDuration
  , fixedStepElapsedCap
  , fixedStepBudget

    -- * Variable step
  , VariableStep (..)
  , boundElapsed

    -- * Fixed step
  , FixedStepPolicy
  , fixedStepPolicy
  , fixedStepPolicyConfig
  , fixedStepRemainder
  , FixedStepTurn (..)
  , advanceFixedStep
  , interpolationFraction

    -- * Pause and resume
  , PausedFixedStep
  , pauseFixedStep
  , resumeFixedStep
  , resumeBaseline
  ) where

import Data.Ratio ((%))
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (AllowZero)
  , ElapsedBaseline
  , Instant
  , TimeOverflow
  , addDuration
  , advanceBaseline
  , durationFromNanoseconds
  , durationNanoseconds
  , noBaseline
  , remainingUntil
  )
import Numeric.Natural (Natural)

-- | Whether a consumer currently wants a turn, and by when.
data Demand
  = NoDemand
  | ImmediateDemand
  | DeadlineDemand !Instant
    -- ^ Absolute: due at and after this instant.
  deriving (Eq, Show)

-- | A deadline removed is no demand; any other demand is unchanged.
removeDeadline ∷ Demand → Demand
removeDeadline demand = case demand of
  DeadlineDemand _ → NoDemand
  other → other

-- | What a demand means at one instant.
data DemandQuery
  = NotDemanded
  | DemandDue
  | DemandPending !Duration
    -- ^ Strictly positive time left before the deadline.
  deriving (Eq, Show)

-- | @queryDemand now demand@. Immediate demand and a deadline at or before
-- @now@ are due; a later deadline is pending.
queryDemand ∷ Instant → Demand → DemandQuery
queryDemand now demand = case demand of
  NoDemand → NotDemanded
  ImmediateDemand → DemandDue
  DeadlineDemand deadline
    | now >= deadline → DemandDue
    | otherwise → DemandPending (remainingUntil now deadline)

-- | @demandRemaining now demand@: nothing for no demand, zero once due, and the
-- time left before a pending deadline otherwise.
demandRemaining ∷ Instant → Demand → Maybe Duration
demandRemaining now demand = case demand of
  NoDemand → Nothing
  ImmediateDemand → Just (fromNanoseconds 0)
  DeadlineDemand deadline → Just (remainingUntil now deadline)

-- | Why a configuration was refused.
data PolicyRejected
  = StepDurationNotPositive
  | ElapsedCapNotPositive
  | StepBudgetNotPositive
  deriving (Eq, Show)

-- | A validated variable-step configuration.
newtype VariableStepConfig = VariableStepConfig Duration
  deriving (Eq, Show)

-- | A variable-step configuration from the largest elapsed interval a consumer
-- is handed in one sample, which must be positive.
variableStepConfig ∷ Duration → Either PolicyRejected VariableStepConfig
variableStepConfig cap
  | isZero cap = Left ElapsedCapNotPositive
  | otherwise = Right (VariableStepConfig cap)

-- | The configured elapsed cap.
variableStepElapsedCap ∷ VariableStepConfig → Duration
variableStepElapsedCap (VariableStepConfig cap) = cap

-- | A validated fixed-step configuration. Its fields are read through
-- accessors rather than record selectors, so a record update cannot bypass
-- validation.
data FixedStepConfig = FixedStepConfig !Duration !Duration !Int
  deriving (Eq, Show)

-- | The simulated time one step advances.
fixedStepDuration ∷ FixedStepConfig → Duration
fixedStepDuration (FixedStepConfig step _ _) = step

-- | The largest raw elapsed interval one turn accepts.
fixedStepElapsedCap ∷ FixedStepConfig → Duration
fixedStepElapsedCap (FixedStepConfig _ cap _) = cap

-- | The most whole steps one turn runs.
fixedStepBudget ∷ FixedStepConfig → Int
fixedStepBudget (FixedStepConfig _ _ budget) = budget

-- | A fixed-step configuration from a step duration, an elapsed cap, and a step
-- budget, each strictly positive. The first refused field, in that order, is
-- reported.
fixedStepConfig ∷ Duration → Duration → Int → Either PolicyRejected FixedStepConfig
fixedStepConfig step cap budget
  | isZero step = Left StepDurationNotPositive
  | isZero cap = Left ElapsedCapNotPositive
  | budget <= 0 = Left StepBudgetNotPositive
  | otherwise = Right (FixedStepConfig step cap budget)

-- | One variable-step sample.
data VariableStep = VariableStep
  { deliveredElapsed ∷ !Duration
    -- ^ The elapsed time handed to the consumer, at most the cap.
  , clippedElapsed ∷ !Duration
    -- ^ The raw elapsed time beyond the cap, which the consumer is not handed.
  }
  deriving (Eq, Show)

-- | Bound a raw elapsed sample by the configured cap.
boundElapsed ∷ VariableStepConfig → Duration → VariableStep
boundElapsed (VariableStepConfig cap) raw
  | raw <= cap = VariableStep raw (fromNanoseconds 0)
  | otherwise = VariableStep cap (fromNanoseconds (nanoseconds raw - nanoseconds cap))

-- | A fixed-step policy: its configuration and the retained sub-step remainder.
data FixedStepPolicy = FixedStepPolicy !FixedStepConfig !Duration
  deriving (Eq, Show)

-- | The policy's configuration.
fixedStepPolicyConfig ∷ FixedStepPolicy → FixedStepConfig
fixedStepPolicyConfig (FixedStepPolicy config _) = config

-- | The retained remainder, always less than one step.
fixedStepRemainder ∷ FixedStepPolicy → Duration
fixedStepRemainder (FixedStepPolicy _ remainder) = remainder

-- | A policy with no remainder.
fixedStepPolicy ∷ FixedStepConfig → FixedStepPolicy
fixedStepPolicy config = FixedStepPolicy config (fromNanoseconds 0)

-- | What one fixed-step turn does.
data FixedStepTurn = FixedStepTurn
  { stepsToRun ∷ !Int
    -- ^ Whole steps to execute now, at most the budget.
  , retainedRemainder ∷ !Duration
    -- ^ The sub-step remainder carried to the next turn.
  , clippedTime ∷ !Duration
    -- ^ Raw elapsed time beyond the cap.
  , droppedStepTime ∷ !Duration
    -- ^ Whole overdue steps beyond the budget.
  , discardedTime ∷ !Duration
    -- ^ Clipped plus dropped time, each counted once.
  , nextStepDue ∷ !(Either TimeOverflow Instant)
    -- ^ The sample instant plus the step minus the retained remainder.
  }
  deriving (Eq, Show)

-- | @advanceFixedStep sample elapsed policy@ applies one raw elapsed sample
-- taken at @sample@.
advanceFixedStep ∷ Instant → Duration → FixedStepPolicy → (FixedStepTurn, FixedStepPolicy)
advanceFixedStep sample elapsed (FixedStepPolicy config remainder) =
  (turn, FixedStepPolicy config newRemainder)
  where
    step = nanoseconds (fixedStepDuration config)
    cap = nanoseconds (fixedStepElapsedCap config)
    raw = nanoseconds elapsed
    accepted = min raw cap
    clipped = raw - accepted
    available = nanoseconds remainder + accepted
    (whole, kept) = available `quotRem` step
    budget = fromIntegral (fixedStepBudget config) ∷ Natural
    run = min whole budget
    dropped = (whole - run) * step
    newRemainder = fromNanoseconds kept
    turn =
      FixedStepTurn
        { stepsToRun = fromIntegral run
        , retainedRemainder = newRemainder
        , clippedTime = fromNanoseconds clipped
        , droppedStepTime = fromNanoseconds dropped
        , discardedTime = fromNanoseconds (clipped + dropped)
        , nextStepDue = addDuration sample (fromNanoseconds (step - kept))
        }

-- | The retained remainder divided by the step: exact, and in @[0,1)@. A
-- conversion to floating point is the caller's and may round up to one.
interpolationFraction ∷ FixedStepPolicy → Rational
interpolationFraction (FixedStepPolicy config remainder) =
  toInteger (nanoseconds remainder) % toInteger (nanoseconds (fixedStepDuration config))

-- | A fixed-step policy that cannot be advanced until it is resumed.
newtype PausedFixedStep = PausedFixedStep FixedStepConfig
  deriving (Eq, Show)

-- | Pause a policy. Its remainder is outstanding debt and is discarded.
pauseFixedStep ∷ FixedStepPolicy → PausedFixedStep
pauseFixedStep (FixedStepPolicy config _) = PausedFixedStep config

-- | @resumeFixedStep resumed paused@ rebases at @resumed@: a policy with no
-- remainder, and the elapsed baseline to sample from next ('resumeBaseline').
resumeFixedStep ∷ Instant → PausedFixedStep → (FixedStepPolicy, ElapsedBaseline)
resumeFixedStep resumed (PausedFixedStep config) =
  (fixedStepPolicy config, resumeBaseline resumed)

-- | An elapsed baseline stored at the resume instant, so the next sample
-- measures only the time since it.
resumeBaseline ∷ Instant → ElapsedBaseline
resumeBaseline resumed = snd (advanceBaseline resumed noBaseline)

nanoseconds ∷ Duration → Natural
nanoseconds = durationNanoseconds

isZero ∷ Duration → Bool
isZero duration = nanoseconds duration == 0

-- | Every caller passes a value bounded by a duration it was derived from, so
-- the conversion cannot be refused.
fromNanoseconds ∷ HasCallStack ⇒ Natural → Duration
fromNanoseconds count = case durationFromNanoseconds AllowZero (toInteger count) of
  Right duration → duration
  Left reason → error ("Hetoimasia.Runtime.UpdatePolicy: unrepresentable duration " <> show count <> ": " <> show reason)
