-- | The validated admission configuration, and the schedules derived from it.
--
-- Every bound the model enforces is finite and stated here. There is no
-- unbounded sentinel: a configuration either names a positive, representable
-- limit for each budget or is rejected, and rejection happens once, before a
-- model exists, rather than at the first call that would have overflowed.
--
-- Requested values are 'Integer' precisely so that zero and negative inputs are
-- rejectable rather than unrepresentable. A validated 'Budgets' holds
-- 'Numeric.Natural.Natural's, so nothing downstream has to re-check a sign.
--
-- The per-target presentation pool is /derived/, not configured: it is the
-- checked sum of the swapchain-image tracking limit and the frame-slot count,
-- so raising frame capacity raises the pool with it instead of leaving a frozen
-- constant behind. With the default limit of 16 images and 2 frame slots the
-- pool holds 18 records.
module Hetoimasia.GPU.Model.Internal.Budget
  ( -- * What a budget is about
    BudgetKind (..)

    -- * Requesting a configuration
  , BudgetRequest (..)
  , defaultBudgetRequest
  , budgetCeiling

    -- * The validated configuration
  , Budgets
  , BudgetRejected (..)
  , validateBudgets
  , targetRecordLimit
  , frameSlotLimit
  , aggregateFrameSlotLimit
  , generationLimit
  , imageTrackingLimit
  , presentationPoolCapacity
  , byteLimit
  , objectLimit
  , reclaimExaminationLimit
  , progressActionLimit
  , idleBackoffCap

    -- * Fixed schedules
  , backoffSchedule
  , recoveryAttemptLimit
  , recoveryRetryDelays
  , healthyProgressPeriod
  , milliseconds
  ) where

import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRejected
  , DurationRequirement (RequirePositive)
  , durationFromNanoseconds
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- What a budget is about

-- | Which budget an answer is about. A backpressure answer names one of these,
-- which is what distinguishes exhaustion from failure at the call site.
data BudgetKind
  = TargetRecordBudget
    -- ^ Target records, counting targets that are retiring.
  | FrameSlotBudget
    -- ^ Frame slots of one target.
  | AggregateFrameSlotBudget
    -- ^ Frame slots across every target of the session.
  | GenerationBudget
    -- ^ Live generations of one target, counting active, constructing and
    -- retired generations together.
  | ImageTrackingBudget
    -- ^ Tracked image records of one swapchain generation.
  | PresentationPoolBudget
    -- ^ The target's derived presentation-record pool, shared by its active
    -- and retired generations.
  | ByteBudget
    -- ^ Accounted backend bytes, counting recorded-but-unsubmitted and retired
    -- allocations.
  | ObjectBudget
    -- ^ Accounted backend object records, on the same counting rule.
  | ReclaimExaminationBudget
    -- ^ Records one reclamation pass may examine.
  | ProgressActionBudget
    -- ^ Completion or disposal actions one owner turn may perform.
  | IdleBackoffBudget
    -- ^ The configured finite cap of the idle polling backoff.
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Requesting a configuration

-- | A configuration as the application states it, before validation.
data BudgetRequest = BudgetRequest
  { requestedTargetRecords ∷ !Integer
  , requestedFrameSlots ∷ !Integer
  , requestedAggregateFrameSlots ∷ !Integer
  , requestedGenerations ∷ !Integer
  , requestedImageTracking ∷ !Integer
  , requestedBytes ∷ !Integer
  , requestedObjects ∷ !Integer
  , requestedReclaimExamination ∷ !Integer
  , requestedProgressActions ∷ !Integer
  , requestedIdleBackoffMilliseconds ∷ !Integer
  }
  deriving (Eq, Show)

-- | The starter values P-15 proposes: 16 target records, 2 frame slots per
-- target within an aggregate of 32, 2 live generations per target, 16 tracked
-- images per generation, 256 MiB and 4,096 accounted objects, 64 examined
-- records per reclaim pass, 32 progress actions per turn, and a 100 ms idle
-- backoff cap.
defaultBudgetRequest ∷ BudgetRequest
defaultBudgetRequest =
  BudgetRequest
    { requestedTargetRecords = 16
    , requestedFrameSlots = 2
    , requestedAggregateFrameSlots = 32
    , requestedGenerations = 2
    , requestedImageTracking = 16
    , requestedBytes = 256 * 1024 * 1024
    , requestedObjects = 4096
    , requestedReclaimExamination = 64
    , requestedProgressActions = 32
    , requestedIdleBackoffMilliseconds = 100
    }

-- | The largest value any single budget may take, and the largest value a
-- derived sum may reach. It exists so that a configuration naming a limit no
-- accounting could ever represent is refused at validation rather than
-- wrapping in the arithmetic that derives the presentation pool.
budgetCeiling ∷ Integer
budgetCeiling = 2 ^ (32 ∷ Int) - 1

-- ---------------------------------------------------------------------------
-- The validated configuration

-- | A configuration every field of which is positive, representable, and
-- consistent with the sums derived from it. Only 'validateBudgets' builds one.
data Budgets = Budgets
  { targetRecordLimit ∷ !Natural
  , frameSlotLimit ∷ !Natural
  , aggregateFrameSlotLimit ∷ !Natural
  , generationLimit ∷ !Natural
  , imageTrackingLimit ∷ !Natural
  , presentationPoolCapacity ∷ !Natural
    -- ^ Derived with overflow checking as @'imageTrackingLimit' +
    -- 'frameSlotLimit'@, never configured directly.
  , byteLimit ∷ !Natural
  , objectLimit ∷ !Natural
  , reclaimExaminationLimit ∷ !Natural
  , progressActionLimit ∷ !Natural
  , idleBackoffCap ∷ !Duration
  }
  deriving (Eq, Show)

-- | Why a requested configuration is not a configuration.
data BudgetRejected
  = BudgetNotPositive !BudgetKind !Integer
    -- ^ Zero or negative. Neither is clamped to one.
  | BudgetAboveCeiling !BudgetKind !Integer
    -- ^ Above 'budgetCeiling'.
  | DerivedBudgetOverflows !BudgetKind !Integer
    -- ^ A sum this configuration derives does not fit below 'budgetCeiling'.
  | IdleBackoffRejected !DurationRejected
    -- ^ The idle cap is not a positive duration the time boundary accepts.
  deriving (Eq, Show)

-- | Validate a requested configuration, or say exactly which field is wrong.
-- Fields are checked in a fixed order so a request with several faults reports
-- the same one every time.
validateBudgets ∷ BudgetRequest → Either BudgetRejected Budgets
validateBudgets request = do
  targets ← bounded TargetRecordBudget (requestedTargetRecords request)
  slots ← bounded FrameSlotBudget (requestedFrameSlots request)
  aggregate ← bounded AggregateFrameSlotBudget (requestedAggregateFrameSlots request)
  generations ← bounded GenerationBudget (requestedGenerations request)
  images ← bounded ImageTrackingBudget (requestedImageTracking request)
  bytes ← bounded ByteBudget (requestedBytes request)
  objects ← bounded ObjectBudget (requestedObjects request)
  reclaim ← bounded ReclaimExaminationBudget (requestedReclaimExamination request)
  actions ← bounded ProgressActionBudget (requestedProgressActions request)
  backoffMilliseconds ← bounded IdleBackoffBudget (requestedIdleBackoffMilliseconds request)
  pool ← derivedSum PresentationPoolBudget (requestedImageTracking request) (requestedFrameSlots request)
  cap ←
    either
      (Left . IdleBackoffRejected)
      Right
      (durationFromNanoseconds RequirePositive (toInteger backoffMilliseconds * 1000000))
  pure
    Budgets
      { targetRecordLimit = targets
      , frameSlotLimit = slots
      , aggregateFrameSlotLimit = aggregate
      , generationLimit = generations
      , imageTrackingLimit = images
      , presentationPoolCapacity = pool
      , byteLimit = bytes
      , objectLimit = objects
      , reclaimExaminationLimit = reclaim
      , progressActionLimit = actions
      , idleBackoffCap = cap
      }
  where
    bounded ∷ BudgetKind → Integer → Either BudgetRejected Natural
    bounded kind value
      | value <= 0 = Left (BudgetNotPositive kind value)
      | value > budgetCeiling = Left (BudgetAboveCeiling kind value)
      | otherwise = Right (fromInteger value)
    derivedSum ∷ BudgetKind → Integer → Integer → Either BudgetRejected Natural
    derivedSum kind left right
      | total > budgetCeiling = Left (DerivedBudgetOverflows kind total)
      | otherwise = Right (fromInteger total)
      where
        total = left + right

-- ---------------------------------------------------------------------------
-- Fixed schedules

-- | Build a 'Duration' from whole milliseconds. Every value this module passes
-- is a positive literal, so the conversion cannot be rejected; a caller that
-- reaches the 'error' has changed one of those literals to a non-positive or
-- unrepresentable value, which is a defect in this module rather than input.
milliseconds ∷ Natural → Duration
milliseconds value =
  either
    (\reason → error ("Hetoimasia.GPU.Model: " ++ show value ++ " ms is not a duration: " ++ show reason))
    id
    (durationFromNanoseconds RequirePositive (toInteger value * 1000000))

-- | The idle polling backoff, in order: 5, 10, 20, 40, 80 ms and then the
-- configured cap. A step is kept only while it stays under the cap, so a
-- configuration with a smaller cap shortens the schedule instead of overshooting
-- it, and the default 100 ms cap yields exactly the 5, 10, 20, 40, 80, 100 ms
-- schedule. The last entry is the steady state: it repeats for as long as the
-- no-demand, no-progress conditions hold.
backoffSchedule ∷ Budgets → [Duration]
backoffSchedule budgets =
  takeWhile (< cap) (map milliseconds [5, 10, 20, 40, 80]) ++ [cap]
  where
    cap = idleBackoffCap budgets

-- | At most three construction attempts per recovery episode.
recoveryAttemptLimit ∷ Natural
recoveryAttemptLimit = 3

-- | The delays between those attempts: the first attempt is immediate, the
-- second follows 100 ms later, and the third 500 ms after the second.
recoveryRetryDelays ∷ [Duration]
recoveryRetryDelays = [milliseconds 100, milliseconds 500]

-- | How long healthy monotonic progress must continue, beside a completed
-- presentation-retirement cycle, before a recovery budget resets.
healthyProgressPeriod ∷ Duration
healthyProgressPeriod = milliseconds 1000
