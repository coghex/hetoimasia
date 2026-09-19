-- | The validated admission configuration a GPU model runs under.
--
-- A configuration is stated as a 'BudgetRequest' of plain 'Integer's and
-- validated once. Zero, negative and unrepresentable limits are rejected and
-- never clamped, and the per-target presentation pool is derived from the
-- configuration with overflow checking rather than frozen as a constant. Only
-- 'validateBudgets' builds a 'Budgets', so every downstream bound is known to
-- be positive and finite.
--
-- See @docs/gpu_model.md@ for the same contract in prose.
module Hetoimasia.GPU.Model.Budget
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
  ) where

import Hetoimasia.GPU.Model.Internal.Budget
