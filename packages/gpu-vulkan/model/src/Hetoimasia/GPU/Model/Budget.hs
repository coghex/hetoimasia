-- | The validated admission configuration a GPU model runs under.
--
-- A configuration is stated as a 'BudgetRequest' of plain 'Integer's and
-- validated once. Zero, negative and unrepresentable limits are rejected and
-- never clamped, and the per-target presentation pool is derived from the
-- configuration with overflow checking rather than frozen as a constant. Only
-- 'validateBudgets' builds a 'Budgets', so every downstream bound is known to
-- be positive and finite.
--
-- __A validated configuration is read-only to clients.__ 'BudgetRequest' is an
-- ordinary record, so a caller states a small configuration by editing one and
-- validating it; 'Budgets' is not. This module exports the type without its
-- constructor, and the eleven names below are ordinary reader functions rather
-- than field selectors, so record construction and record-update syntax reach
-- no label. There is therefore no way for a client to replace a validated
-- limit, and in particular no way to set 'presentationPoolCapacity', which is
-- derived from the image and frame-slot limits and never configured directly.
-- 'Hetoimasia.GPU.Model.newGpuModel' stores what it is handed rather than
-- re-checking it, so that closure is what keeps every bound a running model
-- enforces the one the validator accepted.
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
