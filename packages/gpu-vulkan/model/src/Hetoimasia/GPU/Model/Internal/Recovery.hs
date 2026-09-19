-- | Recovery accounting and the idle polling backoff.
--
-- A recovery episode belongs to its target and survives owner turns. Nothing
-- in this module can raise the attempts a spent episode has left: a nested
-- helper, a changed framebuffer observation and an allocation sub-retry all
-- reach the same 'attemptRecovery', which only ever counts up. The one path
-- back to a fresh budget is 'observeHealthyProgress', and it demands two
-- separate things — a completed presentation-retirement cycle and a full
-- 'healthyProgressPeriod' of monotonic progress after it — so neither the
-- passage of time alone nor one successful present resets anything.
--
-- An allocation attempt carries its own stable identity and exactly one spent
-- retry bit. It may retry only after a reclamation pass confirmed a successful
-- disposal: finding eligible work, or asking for a disposal that then failed,
-- is not progress. If the attempt's construction already passed a generation
-- as @oldSwapchain@, that retirement is irreversible, so the retry cannot
-- replay the same creation arguments and is refused as well.
module Hetoimasia.GPU.Model.Internal.Recovery
  ( -- * Recovery episodes
    RecoveryEpisode (..)
  , freshEpisode
  , RecoveryProgress (..)
  , attemptRecovery
  , recordAttemptFailure
  , recordAttemptSuccess
  , noteRetirementCycle
  , observeHealthyProgress

    -- * Allocation attempts
  , AllocationAttempt (..)
  , newAllocationAttempt
  , RetryVerdict (..)
  , judgeRetry

    -- * The idle polling backoff
  , BackoffState (..)
  , freshBackoff
  , resetBackoff
  , currentBackoff
  , advanceBackoff
  ) where

import Hetoimasia.Foundation.Time
  ( Duration
  , Instant
  , addDuration
  , deadlineReached
  )
import Hetoimasia.GPU.Model.Internal.Budget
  ( Budgets
  , backoffSchedule
  , healthyProgressPeriod
  , recoveryAttemptLimit
  , recoveryRetryDelays
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Recovery episodes

-- | One target's recovery accounting.
data RecoveryEpisode = RecoveryEpisode
  { episodeAttempts ∷ !Natural
    -- ^ Attempts already begun in this episode. Never decreases except through
    -- a complete reset.
  , episodeNextAttemptAt ∷ !(Maybe Instant)
    -- ^ The absolute instant the next attempt may begin, set when the previous
    -- one failed.
  , episodeRetirementCycle ∷ !Bool
    -- ^ Whether a normal presentation-retirement cycle has completed since the
    -- last failure.
  , episodeHealthySince ∷ !(Maybe Instant)
    -- ^ When that cycle completed; the healthy period is measured from here.
  , episodeOutstanding ∷ !Bool
    -- ^ Whether an admitted attempt is still in flight. An episode holds at most
    -- one: a second 'attemptRecovery' before the first is settled would spend a
    -- second attempt for one construction, and a failure reported with none
    -- outstanding would spend one for a construction that never began.
  }
  deriving (Eq, Show)

-- | An episode with its full budget and no attempt outstanding.
freshEpisode ∷ RecoveryEpisode
freshEpisode =
  RecoveryEpisode
    { episodeAttempts = 0
    , episodeNextAttemptAt = Nothing
    , episodeRetirementCycle = False
    , episodeHealthySince = Nothing
    , episodeOutstanding = False
    }

-- | What an attempt request may answer.
data RecoveryProgress
  = AttemptAdmitted !Natural
    -- ^ The attempt number, counting from one.
  | AttemptDeferredUntil !Instant
    -- ^ The budget is not spent, but the retry delay has not elapsed.
  | AttemptBudgetExhausted
    -- ^ Three attempts have been made in this episode.
  | AttemptStillOutstanding
    -- ^ The previous attempt has neither failed nor succeeded yet.
  deriving (Eq, Show)

-- | Ask to begin the next construction attempt of this episode.
attemptRecovery ∷ Instant → RecoveryEpisode → (RecoveryEpisode, RecoveryProgress)
attemptRecovery now episode
  | episodeOutstanding episode = (episode, AttemptStillOutstanding)
  | episodeAttempts episode >= recoveryAttemptLimit = (episode, AttemptBudgetExhausted)
  | Just at ← episodeNextAttemptAt episode
  , not (deadlineReached now at) =
      (episode, AttemptDeferredUntil at)
  | otherwise =
      ( episode {episodeAttempts = attempt, episodeNextAttemptAt = Nothing, episodeOutstanding = True}
      , AttemptAdmitted attempt
      )
  where
    attempt = episodeAttempts episode + 1

-- | Record that the attempt just made failed, scheduling the next one after
-- this episode's delay: 100 ms after the first failure and 500 ms after the
-- second. A third failure schedules nothing, because the budget is spent.
--
-- A failure also clears any healthy-progress evidence: a target that has just
-- failed again has not been healthy, however long the previous quiet spell was.
-- Reporting it also settles the attempt, so the next one may be admitted once
-- its delay has elapsed.
recordAttemptFailure ∷ Instant → RecoveryEpisode → RecoveryEpisode
recordAttemptFailure now episode =
  episode
    { episodeNextAttemptAt = delayFor (episodeAttempts episode) >>= schedule
    , episodeRetirementCycle = False
    , episodeHealthySince = Nothing
    , episodeOutstanding = False
    }
  where
    delayFor attempts
      | attempts == 0 = Nothing
      | otherwise = lookupDelay (attempts - 1) recoveryRetryDelays
    lookupDelay _ [] = Nothing
    lookupDelay index (delay : rest)
      | index == 0 = Just delay
      | otherwise = lookupDelay (index - 1) rest
    schedule ∷ Duration → Maybe Instant
    schedule delay = either (const Nothing) Just (addDuration now delay)

-- | Record that the attempt just made succeeded. It settles the attempt without
-- returning it: the budget an episode has spent is spent, and only a completed
-- retirement cycle plus a healthy period gives any of it back.
recordAttemptSuccess ∷ RecoveryEpisode → RecoveryEpisode
recordAttemptSuccess episode = episode {episodeOutstanding = False}

-- | A normal presentation-retirement cycle completed on this target. This is
-- the first of the two conditions a reset needs; on its own it resets nothing.
noteRetirementCycle ∷ Instant → RecoveryEpisode → RecoveryEpisode
noteRetirementCycle now episode
  | episodeRetirementCycle episode = episode
  | otherwise = episode {episodeRetirementCycle = True, episodeHealthySince = Just now}

-- | Reset the episode if, and only if, a retirement cycle has completed and a
-- full healthy period has elapsed since it did without another failure.
--
-- An attempt still in flight blocks the reset, because a reset would settle it
-- by forgetting it: the construction would then be free to report a failure
-- against a budget that had already been handed back.
observeHealthyProgress ∷ Instant → RecoveryEpisode → RecoveryEpisode
observeHealthyProgress now episode
  | episodeOutstanding episode = episode
  | not (episodeRetirementCycle episode) = episode
  | Just since ← episodeHealthySince episode
  , Right healthy ← addDuration since healthyProgressPeriod
  , deadlineReached now healthy =
      freshEpisode
  | otherwise = episode

-- ---------------------------------------------------------------------------
-- Allocation attempts

-- | One native allocation attempt and its single retry bit.
data AllocationAttempt = AllocationAttempt
  { attemptBytes ∷ !Natural
  , attemptObjects ∷ !Natural
  , attemptFailed ∷ !Bool
  , attemptRetrySpent ∷ !Bool
  , attemptReclaimedSince ∷ !Bool
    -- ^ Whether a reclamation pass confirmed a successful disposal since the
    -- failure. Examining records or requesting a disposal does not set it.
  , attemptRetiredOldSwapchain ∷ !Bool
    -- ^ Whether this attempt's construction already retired a generation by
    -- passing it as @oldSwapchain@.
  }
  deriving (Eq, Show)

newAllocationAttempt ∷ Natural → Natural → AllocationAttempt
newAllocationAttempt bytes objects =
  AllocationAttempt
    { attemptBytes = bytes
    , attemptObjects = objects
    , attemptFailed = False
    , attemptRetrySpent = False
    , attemptReclaimedSince = False
    , attemptRetiredOldSwapchain = False
    }

-- | Whether this attempt may retry, and if not, why not.
data RetryVerdict
  = RetryPermitted
  | RetryNotFailed
    -- ^ The attempt has not failed, so there is nothing to retry.
  | RetryAlreadySpent
    -- ^ Its one retry has been used.
  | RetryWithoutReclamation
    -- ^ No disposal has been confirmed successful since the failure.
  | RetryAfterOldSwapchainRetirement
    -- ^ The attempt retired a generation as @oldSwapchain@. That retirement is
    -- irreversible, so the previous creation arguments no longer describe the
    -- state; a fresh construction path is required instead of a retry.
  deriving (Eq, Show)

judgeRetry ∷ AllocationAttempt → RetryVerdict
judgeRetry attempt
  | not (attemptFailed attempt) = RetryNotFailed
  | attemptRetrySpent attempt = RetryAlreadySpent
  | attemptRetiredOldSwapchain attempt = RetryAfterOldSwapchainRetirement
  | not (attemptReclaimedSince attempt) = RetryWithoutReclamation
  | otherwise = RetryPermitted

-- ---------------------------------------------------------------------------
-- The idle polling backoff

-- | Where the session is in its idle polling schedule.
data BackoffState = BackoffState
  { backoffStep ∷ !Natural
    -- ^ The index into 'backoffSchedule'; it stops advancing at the last entry,
    -- which is the steady state.
  }
  deriving (Eq, Show)

freshBackoff ∷ BackoffState
freshBackoff = BackoffState {backoffStep = 0}

-- | New demand, a new obligation, an observed completion or a close transition
-- all schedule an immediate opportunity and start the schedule over.
resetBackoff ∷ BackoffState → BackoffState
resetBackoff = const freshBackoff

-- | The interval the session currently waits between idle polls.
currentBackoff ∷ Budgets → BackoffState → Duration
currentBackoff budgets state = entry (backoffStep state) (backoffSchedule budgets)
  where
    entry _ [] = error "Hetoimasia.GPU.Model: the backoff schedule is never empty"
    entry _ [final] = final
    entry index (step : rest)
      | index == 0 = step
      | otherwise = entry (index - 1) rest

-- | A turn that found no progress and no demand moves one step along the
-- schedule, stopping at its last entry.
advanceBackoff ∷ Budgets → BackoffState → BackoffState
advanceBackoff budgets state
  | backoffStep state + 1 >= fromIntegral (length (backoffSchedule budgets)) =
      state {backoffStep = fromIntegral (length (backoffSchedule budgets)) - 1}
  | otherwise = state {backoffStep = backoffStep state + 1}
