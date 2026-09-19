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
  , NextAttempt (..)
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
  , DueAt (..)
  , freshBackoff
  , resetBackoff
  , currentBackoff
  , advanceBackoff
  , scheduleNextPoll
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
  , episodeNextAttemptAt ∷ !NextAttempt
    -- ^ When the next attempt may begin, set when the previous one failed.
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

-- | When an episode's next attempt may begin.
data NextAttempt
  = AttemptUnscheduled
    -- ^ Nothing is waiting on a delay: either no attempt has failed yet, or the
    -- budget is spent and there is no next attempt to schedule.
  | AttemptAt !Instant
  | AttemptUnschedulable
    -- ^ The delay after this failure does not fit the clock's representation.
    -- It is kept as its own answer rather than collapsed into
    -- 'AttemptUnscheduled', because the two mean opposite things: one says no
    -- delay is owed and the other says a delay is owed that cannot be expressed.
    -- Treating the second as the first would admit the next attempt immediately,
    -- which is exactly the delay the episode exists to enforce.
  deriving (Eq, Show)

-- | An episode with its full budget and no attempt outstanding.
freshEpisode ∷ RecoveryEpisode
freshEpisode =
  RecoveryEpisode
    { episodeAttempts = 0
    , episodeNextAttemptAt = AttemptUnscheduled
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
  | AttemptDelayUnrepresentable
    -- ^ The delay this episode owes cannot be expressed on this clock, so the
    -- attempt cannot be admitted without shortening it.
  deriving (Eq, Show)

-- | Ask to begin the next construction attempt of this episode.
attemptRecovery ∷ Instant → RecoveryEpisode → (RecoveryEpisode, RecoveryProgress)
attemptRecovery now episode
  | episodeOutstanding episode = (episode, AttemptStillOutstanding)
  | episodeAttempts episode >= recoveryAttemptLimit = (episode, AttemptBudgetExhausted)
  | AttemptUnschedulable ← episodeNextAttemptAt episode = (episode, AttemptDelayUnrepresentable)
  | AttemptAt at ← episodeNextAttemptAt episode
  , not (deadlineReached now at) =
      (episode, AttemptDeferredUntil at)
  | otherwise =
      ( episode
          { episodeAttempts = attempt
          , episodeNextAttemptAt = AttemptUnscheduled
          , episodeOutstanding = True
          , -- Evidence gathered before this attempt says nothing about a target
            -- that has just had to be reconstructed again. Carrying it forward
            -- would let a cycle that the attempt itself interrupted hand the
            -- episode its budget back.
            episodeRetirementCycle = False
          , episodeHealthySince = Nothing
          }
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
    { episodeNextAttemptAt = maybe AttemptUnscheduled schedule (delayFor (episodeAttempts episode))
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
    -- An overflowing delay is recorded as one that cannot be scheduled. Reading
    -- it as no delay would hand the next attempt the instant this one failed at.
    schedule ∷ Duration → NextAttempt
    schedule delay = either (const AttemptUnschedulable) AttemptAt (addDuration now delay)

-- | Record that the attempt just made succeeded. It settles the attempt without
-- returning it: the budget an episode has spent is spent, and only a completed
-- retirement cycle plus a healthy period gives any of it back.
recordAttemptSuccess ∷ RecoveryEpisode → RecoveryEpisode
recordAttemptSuccess episode = episode {episodeOutstanding = False}

-- | A normal presentation-retirement cycle completed on this target. This is
-- the first of the two conditions a reset needs; on its own it resets nothing.
--
-- It is credited only to an episode that has something to give back and nothing
-- in flight. A cycle completed while an attempt is outstanding is a cycle that
-- attempt is in the middle of interrupting, and one credited to an episode with
-- no spent attempts is evidence for a reset nobody is waiting for — which would
-- only put a healthy-period deadline on the schedule of a target that is
-- perfectly well.
noteRetirementCycle ∷ Instant → RecoveryEpisode → RecoveryEpisode
noteRetirementCycle now episode
  | episodeOutstanding episode = episode
  | episodeAttempts episode == 0 = episode
  | episodeRetirementCycle episode = episode
  | otherwise = episode {episodeRetirementCycle = True, episodeHealthySince = Just now}

-- | Reset the episode if, and only if, a retirement cycle has completed since
-- the last attempt and a full healthy period has elapsed since it did, without
-- another failure.
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

-- | When the next idle poll falls due.
data DueAt
  = DueImmediately
    -- ^ Something has been scheduled since the last turn — new demand, a new
    -- obligation, an observed completion or a close — and the owner is asked for
    -- an opportunity now. It is an answer in its own right rather than an
    -- instant, because the transitions that set it carry no clock reading, and
    -- inventing one at each observation is what would let repeated reads of an
    -- unchanged model push the poll further away.
  | DueAt !Instant
    -- ^ The absolute instant the last turn anchored. Reading it again does not
    -- move it.
  | DueUnschedulable
    -- ^ That instant does not fit the clock's representation.
  deriving (Eq, Show)

-- | Where the session is in its idle polling schedule, and when its next poll is
-- due.
data BackoffState = BackoffState
  { backoffStep ∷ !Natural
    -- ^ The index into 'backoffSchedule'; it stops advancing at the last entry,
    -- which is the steady state.
  , backoffDueAt ∷ !DueAt
  }
  deriving (Eq, Show)

freshBackoff ∷ BackoffState
freshBackoff = BackoffState {backoffStep = 0, backoffDueAt = DueImmediately}

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

-- | Anchor the next poll at the instant this turn ran, and move the schedule on.
--
-- A turn is the only place an instant reaches the backoff, so it is the only
-- place the deadline can be anchored. The interval announced is the one the
-- schedule is currently at; the advance applies to the turn after it, so a turn
-- that made progress starts again at the first interval rather than carrying the
-- idle one forward.
scheduleNextPoll ∷ Budgets → Instant → Bool → BackoffState → BackoffState
scheduleNextPoll budgets now progressed state
  | progressed = BackoffState {backoffStep = 0, backoffDueAt = anchored (currentBackoff budgets freshBackoff)}
  | otherwise =
      BackoffState
        { backoffStep = backoffStep (advanceBackoff budgets state)
        , backoffDueAt = anchored (currentBackoff budgets state)
        }
  where
    anchored interval = either (const DueUnschedulable) DueAt (addDuration now interval)
