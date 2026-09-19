-- | One logical task and its state machine.
--
-- A task is a record, not a thread: identity, session epoch (inside that
-- identity), behaviour identity, application state or cursor, service class,
-- readiness, and an optional pending request or subscription. Many small tasks
-- share one behaviour and one VM per domain; nothing here is per-entity.
--
-- = The states
--
-- 'Ready', 'Running', 'Waiting' with its exact cause, 'Paused', and the three
-- terminal states 'Completed', 'Cancelled', and 'Failed'. 'terminalOutcome'
-- names the terminal ones; every other state is live.
--
-- = The transitions
--
-- Each transition is a pure function that answers either the next task or a
-- typed 'TransitionRejection'. A rejection leaves the task exactly as it was —
-- the function returns the original value untouched, so there is no partially
-- applied transition to observe. Every transition takes the 'SessionKey' the
-- caller believes it is acting in and checks it against the scope inside the
-- task's own identity, which is what makes a resume from an old epoch, or from
-- another mod entirely, a rejection rather than a surprise.
--
-- A terminal task rejects every transition, including another terminal one, so
-- no task reaches two terminal outcomes. That is checked before the state the
-- transition wanted, so completing an already cancelled task reports
-- 'AlreadyTerminal' rather than 'WrongState': the reason it cannot happen is
-- that the task is finished, not that it is not running.
--
-- = The cursor
--
-- 'applySegment' is the only function in this module that writes
-- 'taskCursor', and it requires 'Running'. A task's application state
-- therefore advances only by running a segment, and a cancellation, a failure,
-- a pause, or a wake carries whatever cursor the last segment left.
--
-- = Ordinals
--
-- Re-entering the ready set takes a fresh 'Ordinal', supplied by the caller
-- because ordinals are issued by the session, not by the task. 'applySegment'
-- consumes one only for 'SegmentYielded'; a completed or waiting task is not
-- joining the ready set and keeps the ordinal it had. That is what puts a
-- yielded task behind its ready peers instead of at the head forever.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( -- * Readiness
    Readiness (..)

    -- * States
  , WaitCause (..)
  , TaskOutcome (..)
  , TaskState (..)
  , terminalOutcome
  , isTerminal
  , TaskFailure (..)

    -- * The record
  , Task (..)
  , Pending (..)
  , newTask

    -- * Segments
  , SegmentOutcome (..)

    -- * Rejections
  , ExpectedState (..)
  , TransitionRejection (..)

    -- * Transitions
  , checkScope
  , startTask
  , applySegment
  , wakeTask
  , pauseTask
  , resumeTask
  , cancelTask
  , failTask
  ) where

import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (FailureReason, RecoverySafety)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( BehaviorId
  , Ordinal
  , RequestId
  , SessionKey
  , Staleness (ScopeAhead, ScopeCurrent, ScopeForeign, ScopeStale)
  , SubscriptionId
  , TaskId
  , compareScope
  , taskScope
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (ServiceClass)
import Data.Word (Word64)

-- | An abstract readiness mark supplied by the caller.
--
-- P-6 keeps clocks out of this model: a deadline here is a number the host
-- computed from its own clock, and nothing in this package compares it to
-- anything but another mark. The model never measures time and never advances
-- one of these on its own, which is what makes a sequence of inputs replay to
-- the same states.
newtype Readiness = Readiness {readinessMark ∷ Word64}
  deriving (Eq, Ord, Show)

-- | Exactly what a waiting task is waiting on.
data WaitCause
  = -- | A request that has not settled.
    WaitingOnRequest !RequestId
  | -- | An owned subscription with nothing delivered.
    WaitingOnSubscription !SubscriptionId
  | -- | A readiness mark the host will compare against its own clock.
    WaitingUntil !Readiness
  deriving (Eq, Show)

-- | The one outcome a finished task has.
data TaskOutcome
  = OutcomeCompleted
  | OutcomeCancelled
  | OutcomeFailed
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A handled task failure: why, and whether anything it touched is still safe.
--
-- This stays inside the session as data (P-8). Whether it also ends the
-- session is the session's decision, taken from 'failureRecovery'.
data TaskFailure = TaskFailure
  { failureReasonOf ∷ !FailureReason
  , failureRecovery ∷ !RecoverySafety
  }
  deriving (Eq, Show)

-- | A task's state.
data TaskState
  = Ready
  | Running
  | Waiting !WaitCause
  | Paused
  | Completed
  | Cancelled
  | Failed !TaskFailure
  deriving (Eq, Show)

-- | The outcome of a terminal state, or 'Nothing' for a live one.
terminalOutcome ∷ TaskState → Maybe TaskOutcome
terminalOutcome Completed = Just OutcomeCompleted
terminalOutcome Cancelled = Just OutcomeCancelled
terminalOutcome (Failed _) = Just OutcomeFailed
terminalOutcome Ready = Nothing
terminalOutcome Running = Nothing
terminalOutcome (Waiting _) = Nothing
terminalOutcome Paused = Nothing

-- | Whether a state is terminal.
isTerminal ∷ TaskState → Bool
isTerminal state = case terminalOutcome state of
  Just _ → True
  Nothing → False

-- | The request or subscription a task currently holds an interest in.
data Pending
  = PendingRequest !RequestId
  | PendingSubscription !SubscriptionId
  deriving (Eq, Show)

-- | One logical task.
data Task v = Task
  { taskIdentity ∷ !TaskId
  , taskBehavior ∷ !BehaviorId
  , taskService ∷ !ServiceClass
  , taskState ∷ !TaskState
  , taskCursor ∷ v
  , taskOrdinal ∷ !Ordinal
  , taskReadiness ∷ !(Maybe Readiness)
  , taskPending ∷ !(Maybe Pending)
  , taskSegments ∷ !Int
  }
  deriving (Eq, Show)

-- | A freshly admitted task: 'Ready', at its admission ordinal, with no
-- pending interest and no segment run.
newTask
  ∷ TaskId
  → BehaviorId
  → ServiceClass
  → v
  → Ordinal
  → Maybe Readiness
  → Task v
newTask identity behavior serviceClass cursor ordinal readiness =
  Task
    { taskIdentity = identity
    , taskBehavior = behavior
    , taskService = serviceClass
    , taskState = Ready
    , taskCursor = cursor
    , taskOrdinal = ordinal
    , taskReadiness = readiness
    , taskPending = Nothing
    , taskSegments = 0
    }

-- | What a segment of author-facing work returned (P-5).
--
-- Each carries the application state the segment left, because the model never
-- constructs one: a completed segment's value is the task's terminal result, a
-- yielded segment's is the cursor it resumes from, and a waiting segment's is
-- the cursor it resumes from once its cause settles.
data SegmentOutcome v
  = -- | Finished. Its value becomes the task's terminal result.
    SegmentCompleted v
  | -- | Yielded with a new cursor. Rejoins the ready set behind its peers.
    SegmentYielded v
  | -- | Waiting on a named cause, with the cursor to resume from.
    SegmentWaiting v !WaitCause
  deriving (Eq, Show)

-- | Which state a transition needed.
data ExpectedState
  = ExpectedReady
  | ExpectedRunning
  | ExpectedWaiting
  | ExpectedPaused
  | ExpectedLive
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Why a transition was refused.
data TransitionRejection
  = -- | The task is finished; it has this outcome and will never have another.
    AlreadyTerminal !TaskOutcome
  | -- | The task was not in the state the transition needed.
    WrongState !ExpectedState !TaskState
  | -- | The offered scope is an earlier epoch of this task's own session: a
    -- stale resume of a task that has been invalidated. Carries the task's
    -- epoch and the offered one.
    StaleScope !SessionKey !SessionKey
  | -- | The offered scope claims a later epoch than the task's, which nothing
    -- may do.
    AheadOfScope !SessionKey !SessionKey
  | -- | Another owner or another session. D-8's isolation, refused.
    ForeignScope !SessionKey !SessionKey
  deriving (Eq, Show)

-- | Check an offered scope against the task's own, without changing anything.
checkScope ∷ SessionKey → Task v → Either TransitionRejection ()
checkScope offered task =
  case compareScope held offered of
    ScopeCurrent → Right ()
    ScopeStale _ _ → Left (StaleScope held offered)
    ScopeAhead _ _ → Left (AheadOfScope held offered)
    ScopeForeign _ _ → Left (ForeignScope held offered)
  where
    held = taskScope (taskIdentity task)

-- | Scope first, then terminality, then the state the caller needed.
--
-- The order is the point: a stale resume of a finished task is reported as
-- stale, because the caller's identity was wrong before its expectation was.
requiring
  ∷ SessionKey
  → ExpectedState
  → (TaskState → Bool)
  → Task v
  → Either TransitionRejection ()
requiring offered expected accepts task = do
  checkScope offered task
  case terminalOutcome (taskState task) of
    Just outcome → Left (AlreadyTerminal outcome)
    Nothing
      | accepts (taskState task) → Right ()
      | otherwise → Left (WrongState expected (taskState task))

-- | Begin a segment: 'Ready' to 'Running'.
--
-- Running a task that is not ready is refused, which is what keeps a task that
-- is waiting, paused, or already running from being run twice.
startTask ∷ SessionKey → Task v → Either TransitionRejection (Task v)
startTask offered task = do
  requiring offered ExpectedReady (== Ready) task
  pure task {taskState = Running, taskPending = Nothing}

-- | Apply a segment's outcome to a 'Running' task.
--
-- The only transition that advances 'taskCursor'. The supplied 'Ordinal' is
-- taken only by 'SegmentYielded', which is the only outcome that rejoins the
-- ready set.
applySegment
  ∷ SessionKey
  → Ordinal
  → SegmentOutcome v
  → Task v
  → Either TransitionRejection (Task v)
applySegment offered ordinal outcome task = do
  requiring offered ExpectedRunning (== Running) task
  let ran = task {taskSegments = taskSegments task + 1}
  pure $ case outcome of
    SegmentCompleted final →
      ran
        { taskState = Completed
        , taskCursor = final
        , taskPending = Nothing
        , taskReadiness = Nothing
        }
    SegmentYielded cursor →
      ran
        { taskState = Ready
        , taskCursor = cursor
        , taskOrdinal = ordinal
        , taskPending = Nothing
        }
    SegmentWaiting cursor cause →
      ran
        { taskState = Waiting cause
        , taskCursor = cursor
        , taskPending = pendingOf cause
        , taskReadiness = readinessOf cause
        }
  where
    pendingOf (WaitingOnRequest identity) = Just (PendingRequest identity)
    pendingOf (WaitingOnSubscription identity) = Just (PendingSubscription identity)
    pendingOf (WaitingUntil _) = Nothing
    readinessOf (WaitingUntil mark) = Just mark
    readinessOf _ = taskReadiness task

-- | Wake a 'Waiting' task: back to 'Ready', behind the peers already there.
wakeTask ∷ SessionKey → Ordinal → Task v → Either TransitionRejection (Task v)
wakeTask offered ordinal task = do
  requiring offered ExpectedWaiting waiting task
  pure
    task
      { taskState = Ready
      , taskOrdinal = ordinal
      , taskPending = Nothing
      , taskReadiness = Nothing
      }
  where
    waiting (Waiting _) = True
    waiting _ = False

-- | Pause a 'Ready' task.
pauseTask ∷ SessionKey → Task v → Either TransitionRejection (Task v)
pauseTask offered task = do
  requiring offered ExpectedReady (== Ready) task
  pure task {taskState = Paused}

-- | Resume a 'Paused' task, behind the peers already ready.
resumeTask ∷ SessionKey → Ordinal → Task v → Either TransitionRejection (Task v)
resumeTask offered ordinal task = do
  requiring offered ExpectedPaused (== Paused) task
  pure task {taskState = Ready, taskOrdinal = ordinal}

-- | Cancel any live task.
--
-- Its cursor is whatever its last segment left. Nothing is rolled back: this
-- model owns no application state and promises no transaction.
cancelTask ∷ SessionKey → Task v → Either TransitionRejection (Task v)
cancelTask offered task = do
  requiring offered ExpectedLive (const True) task
  pure task {taskState = Cancelled, taskPending = Nothing, taskReadiness = Nothing}

-- | Fail any live task with a handled failure.
--
-- Whether the session survives it is read off 'failureRecovery' by the
-- session, not decided here.
failTask ∷ SessionKey → TaskFailure → Task v → Either TransitionRejection (Task v)
failTask offered failure task = do
  requiring offered ExpectedLive (const True) task
  pure task {taskState = Failed failure, taskPending = Nothing, taskReadiness = Nothing}
