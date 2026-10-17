-- | The vocabulary the scheduling machinery speaks in: the work an application
-- admits, the policy that orders it, what a segment reports, how waits resume,
-- the answers to admission, grants and control, the reports a turn and a stop
-- produce, the aggregate diagnostics, and the configuration.
--
-- Nothing here runs anything. "Hetoimasia.Scripting.Lua.Scheduler" owns the
-- operations; this module is what they take and answer.
module Hetoimasia.Scripting.Lua.Scheduler.Types
  ( -- * Work
    TaskKind (..)
  , TaskSpec (..)
  , TaskPhase (..)

    -- * Policy
  , Candidate (..)
  , PolicyView (..)
  , Policy (..)
  , servable

    -- * Segments and waits
  , SegmentReport (..)
  , TaskRun (..)
  , TaskHost (..)
  , Resume (..)
  , WaitRefusal (..)

    -- * Admission and grants
  , AdmitAnswer (..)
  , AdmitRefusal (..)
  , GrantId (..)
  , GrantAnswer (..)

    -- * Control
  , ControlRequest (..)
  , ControlAnswer (..)
  , ControlResult (..)
  , CloseReport (..)
  , ControlSettlement (..)
  , ControlTicket (..)

    -- * Reports
  , TurnEnd (..)
  , TurnReport (..)
  , StopReport (..)

    -- * Diagnostics
  , Diagnostics (..)
  , Overrun (..)

    -- * Configuration
  , SchedulerBounds (..)
  , ConfigViolation (..)
  , SchedulerRefused (..)
  , SchedulerConfig (..)
  ) where

import Control.Concurrent.STM (STM)
import Control.Exception (Exception, SomeException)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, MonotonicSource)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (BehaviorId, Ordinal, SessionKey, TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (LimitName, LimitViolation, Quanta, ServiceClass)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session (ExitRecord)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure, TaskOutcome)
import Hetoimasia.Scripting.Lua.Scheduler.Timer (TimerBackend)

-- Work -------------------------------------------------------------------------

-- | Whether work is repeating or runs once.
--
-- The kind is a declaration the policy can read, not something the scheduler
-- enforces: a looped task stays resident because its segments keep yielding, a
-- one-shot task runs across as many segments as it needs and then completes.
-- Where a newly admitted one-shot is placed belongs to the policy and nowhere
-- else.
data TaskKind
  = -- | Repeating work that remains resident and keeps being serviced.
    Looped
  | -- | Work that runs once to completion.
    OneShot
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | What an application admits.
--
-- The engine issues the task's identity. The optional name is the application's
-- own readable label for it: neither the identity nor the name grants
-- authority, and no operation accepts a name in place of an identity.
data TaskSpec v = TaskSpec
  { specBehavior ∷ !BehaviorId
    -- ^ The shared behaviour many tasks reuse.
  , specEntry ∷ !Text
    -- ^ The entry point the task runs: what an overrun is attributed to.
  , specName ∷ !(Maybe Text)
  , specClass ∷ !ServiceClass
  , specKind ∷ !TaskKind
  , specCursor ∷ v
    -- ^ The application state the first segment resumes from.
  }

-- | Where a task is, as the application sees it.
data TaskPhase
  = -- | Admitted and waiting for an active slot.
    PhaseQueued
  | PhaseReady
  | PhaseRunning
  | -- | Waiting for a logical tick or an elapsed deadline.
    PhaseWaiting
  | -- | Paused: it runs no segment and occupies no turn. A task paused while
    -- it was waiting is paused until it is resumed, and then waits again.
    PhasePaused
  | PhaseEnded !TaskOutcome
  deriving (Eq, Show)

-- Policy -----------------------------------------------------------------------

-- | One ready task as a policy sees it.
data Candidate = Candidate
  { candidateTask ∷ !TaskId
  , candidateClass ∷ !ServiceClass
  , candidateKind ∷ !TaskKind
  , candidateOrdinal ∷ !Ordinal
    -- ^ The task's place among its ready peers: issued at admission and again
    -- on every re-entry to the ready set, so a lower one has waited longer.
  , candidateSegments ∷ !Int
    -- ^ How many segments the task has run.
  }
  deriving (Eq, Show)

-- | What a policy chooses from.
data PolicyView = PolicyView
  { viewServing ∷ !ServiceClass
    -- ^ The class whose opportunity this is.
  , viewReady ∷ !(NonEmpty Candidate)
    -- ^ Every ready task, of every class, in ascending 'Ordinal' order. There
    -- is always at least one: an opportunity is offered only to a class that has
    -- a ready task.
  }
  deriving (Eq, Show)

-- | The ready tasks of the class being served, in ascending 'Ordinal' order.
-- The only tasks a choice may name.
servable ∷ PolicyView → [Candidate]
servable view = [candidate | candidate ← NonEmpty.toList (viewReady view), candidateClass candidate == viewServing view]

-- | A scheduling policy: which ready task runs next.
--
-- That is all a policy decides. The runtime keeps admission and capacity, the
-- class pass and its quanta, control and stop, timers, the settlement of
-- results and ownership, under every policy, and none of them can be bypassed
-- from here. A choice of anything but a ready task of the class being served is
-- refused, counted, and answered by the oldest ready task of that class.
data Policy = Policy
  { policyName ∷ !Text
  , policyChoose ∷ PolicyView → TaskId
  }

-- Segments and waits -----------------------------------------------------------

-- | What a segment reports when it returns.
data SegmentReport v
  = -- | Finished. The value becomes the task's terminal result.
    ReportCompleted v
  | -- | Yielded with a new cursor: back to the tail of its class.
    ReportYielded v
  | -- | Wait for this many logical ticks, which must be positive.
    ReportWaitTicks v !Word64
  | -- | Wait for this much elapsed time on the owner's monotonic source, which
    -- must be positive.
    ReportWaitElapsed v !Duration
  | -- | Failed, with a handled failure. It stays the task's own: whether it also
    -- ends a session is the integrating owner's decision, from 'TaskFailure'.
    ReportFailed !TaskFailure

deriving instance Show v ⇒ Show (SegmentReport v)

-- | What the scheduler hands the host to run one segment.
data TaskRun v = TaskRun
  { runTask ∷ !TaskId
  , runBehavior ∷ !BehaviorId
  , runEntry ∷ !Text
  , runName ∷ !(Maybe Text)
  , runClass ∷ !ServiceClass
  , runKind ∷ !TaskKind
  , runCursor ∷ v
  , runResume ∷ !(Maybe Resume)
    -- ^ What the wait that just ended earned, on the segment that follows it.
  , runSegmentNumber ∷ !Int
    -- ^ How many segments the task had run before this one.
  }

-- | What the host provides, and nothing else: it runs a segment and closes a
-- task's continuation. Both are called on the thread that drives the scheduler,
-- which is the owner's thread, and never inside a state transaction.
data TaskHost v = TaskHost
  { hostRun ∷ TaskRun v → IO (SegmentReport v)
    -- ^ Run one segment. An exception that escapes it is a failure of the host
    -- and propagates out of the turn, to supervision; it is not the task's.
  , hostClose ∷ TaskId → IO ()
    -- ^ Close the task's suspended continuation, once. A synchronous exception
    -- is the closing failure: it is retained as evidence beside the settlement
    -- and never discarded, and the task is cancelled all the same.
  }

-- | What a wait that ended hands the task on its next segment. Fixed when the
-- wait is satisfied: later grants and delayed dispatch cannot change it.
data Resume
  = -- | The tick the wait reached, and the logical duration granted since it
    -- began. Both come from grants alone.
    ResumedLogical
      { resumedTick ∷ !Word64
      , resumedGranted ∷ !Duration
      }
  | -- | The time elapsed on the owner's monotonic source since the wait began,
    -- as measured when its deadline was found reached.
    ResumedElapsed
      { resumedElapsed ∷ !Duration
      }
  deriving (Eq, Show)

-- | Why a wait was refused. The task whose segment asked for it fails with a
-- typed, recoverable failure and nothing waits.
data WaitRefusal
  = -- | A wait for no ticks.
    WaitTicksNotPositive
  | -- | The tick the wait would end at is not representable.
    WaitTicksOverflow
  | -- | An elapsed wait of no time.
    WaitDurationNotPositive
  | -- | The deadline is not representable on the source's timeline.
    WaitDeadlineOverflow
  deriving (Bounded, Enum, Eq, Show)

-- Admission and grants ---------------------------------------------------------

-- | The answer to admitting a task.
data AdmitAnswer
  = Admitted !TaskId
  | AdmitRefused !AdmitRefusal
  deriving (Eq, Show)

-- | Why admission was refused. A refusal changes nothing but a counter.
data AdmitRefusal
  = -- | A cap, and its value: the queue of admissions or the stored results.
    AdmitFull !LimitName !Int
  | -- | The scheduler has stopped or been asked to.
    AdmitClosed
  deriving (Eq, Show)

-- | A grant's number, from zero, in the order grants were accepted.
newtype GrantId = GrantId {grantNumber ∷ Word64}
  deriving (Eq, Ord, Show)

-- | The answer to a grant of a logical step.
data GrantAnswer
  = GrantAccepted !GrantId
  | -- | The bound on outstanding grants is reached. Nothing changed.
    GrantFull
  | -- | The scheduler has stopped or been asked to.
    GrantClosed
  | -- | The duration was zero. A step is a positive logical duration.
    GrantNotPositive
  deriving (Eq, Show)

-- Control ----------------------------------------------------------------------

-- | A request about one task.
data ControlRequest
  = RequestPause
  | RequestResume
  | RequestStop
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | The answer to a request. It says whether the request was taken, never what
-- became of it: that is its settlement, later.
data ControlAnswer
  = ControlAccepted !ControlTicket
  | -- | Every result reservation is held. Nothing changed.
    ControlFull
  | ControlClosed
  | -- | No live task has this identity: it is foreign, stale, ended, never
    -- issued, or still waiting in the admission queue.
    ControlUnknownTarget
  deriving (Show)

-- | What applying an accepted request came to.
data ControlResult
  = ControlApplied
  | -- | The task was already in the state asked for.
    ControlAlreadyInState
  | -- | The task had ended, the request was superseded by a stop, or the
    -- scheduler closed first.
    ControlNoLongerApplicable
  deriving (Bounded, Enum, Eq, Show)

-- | How closing a stopped task's continuation went.
data CloseReport
  = CloseClean
  | -- | The close failed. The failure is evidence, never discarded and never
    -- reported as a clean close.
    CloseFailed !SomeException
  deriving (Show)

-- | An accepted request's settlement.
data ControlSettlement = ControlSettlement
  { settledResult ∷ !ControlResult
  , settledClose ∷ !(Maybe CloseReport)
    -- ^ Present exactly when a stop was applied: the task's continuation was
    -- closed on the owner's thread, once.
  }
  deriving (Show)

-- | The place an accepted request's settlement is read, and the reservation it
-- holds is given back. Reading or abandoning is by the ticket alone.
data ControlTicket = ControlTicket
  { pollControl ∷ STM (Maybe ControlSettlement)
    -- ^ The settlement if there is one. Reading a settlement observes it: the
    -- first read that finds one gives the reservation back, and every later
    -- read answers the same settlement and gives nothing back.
  , awaitControl ∷ STM ControlSettlement
    -- ^ Like 'pollControl', retrying until the request has settled.
  , forgetControl ∷ STM ()
    -- ^ Give up interest in the result. A settled result gives its reservation
    -- back now, an unsettled one when it settles.
  }

-- | A ticket shows as what it is, and nothing of the reservation behind it.
instance Show ControlTicket where
  show _ = "<control ticket>"

-- Reports ----------------------------------------------------------------------

-- | Why a turn ended.
data TurnEnd
  = -- | Nothing is ready in any class.
    TurnIdle
  | -- | The pass over the classes completed.
    TurnPassComplete
  | -- | The elapsed service budget had expired when a segment returned. The
    -- unfinished pass, with its remaining quanta, continues in the next turn.
    TurnBudgetExpired
  | -- | The owner was asked to stop. Nothing further started.
    TurnStopRequested
  | -- | The scheduler has stopped.
    TurnClosed
  deriving (Bounded, Enum, Eq, Show)

-- | What one service turn did.
data TurnReport = TurnReport
  { turnSegments ∷ !Int
  , turnEnd ∷ !TurnEnd
  , turnFailures ∷ ![(TaskId, TaskFailure)]
    -- ^ Tasks that failed, in the order they did, with the recovery each
    -- reported. A refused wait is among them, as a validation failure.
  , turnRefusedWaits ∷ ![(TaskId, WaitRefusal)]
  , turnCloseFailures ∷ ![(TaskId, SomeException)]
    -- ^ Continuations whose close failed since the last report, including those a
    -- turn that ended exceptionally had met, to be kept as cleanup evidence. They are
    -- kept in the scheduler until the report is handed over, and, until the next
    -- turn shows it arrived, the scheduler's stop reports them too.
  }
  deriving (Show)

-- | What a stop ended, apart from what supervision carries.
data StopReport = StopReport
  { stopRecord ∷ !ExitRecord
    -- ^ The model's record: each task's disposition and the discard counts.
  , stopCloseFailures ∷ ![(TaskId, SomeException)]
    -- ^ Continuations closed on stop whose close failed.
  , stopControlsSettled ∷ !Int
    -- ^ Accepted control requests that had not been applied, settled as no
    -- longer applicable.
  , stopTimerFailure ∷ !(Maybe SomeException)
    -- ^ What cancelling the timer raised, if it raised: the stop went on.
  }
  deriving (Show)

-- Diagnostics ------------------------------------------------------------------

-- | Segments that ran past the budget, attributed to an owner's kind of work
-- and entry point.
data Overrun = Overrun
  { overrunOwner ∷ !Text
  , overrunKind ∷ !TaskKind
  , overrunEntry ∷ !Text
  , overrunCount ∷ !Int
  }
  deriving (Eq, Show)

-- | The bounded counters and gauges of one scheduler. A snapshot: reading it
-- borrows nothing from a Lua state, and there is no per-task history behind it.
data Diagnostics = Diagnostics
  { diagOwner ∷ !Text
  , diagAdmitted ∷ !Int
  , diagRejected ∷ !Int
    -- ^ Admissions refused.
  , diagQueued ∷ !Int
    -- ^ Gauge: admissions waiting for an active slot.
  , diagQueueHighWater ∷ !Int
  , diagActive ∷ !Int
    -- ^ Gauge: tasks that are not finished and have left the queue.
  , diagActiveHighWater ∷ !Int
  , diagCompleted ∷ !Int
  , diagYielded ∷ !Int
    -- ^ Segments that ended in a yield.
  , diagWaiting ∷ !Int
    -- ^ Segments that ended in a wait.
  , diagFailed ∷ !Int
  , diagCancelled ∷ !Int
    -- ^ Tasks ended without finishing, by a stop request or by the scheduler's
    -- stop.
  , diagDiscarded ∷ !Int
    -- ^ Queued admissions and unobserved results the scheduler's stop dropped.
  , diagSegmentsByClass ∷ ![(ServiceClass, Int)]
  , diagOverruns ∷ !Int
  , diagOverrunSites ∷ ![Overrun]
    -- ^ At most 'Hetoimasia.Scripting.Lua.Scheduler.maxOverrunSites' sites.
  , diagOverrunsUnattributed ∷ !Int
    -- ^ Overruns of a site that found the table full.
  , diagRefusedChoices ∷ !Int
    -- ^ Policy choices that named anything but a ready task of the class served.
  , diagRefusedWaits ∷ !Int
  , diagControlAccepted ∷ !Int
  , diagControlRefused ∷ !Int
  , diagGrantsAccepted ∷ !Int
  , diagGrantsRefused ∷ !Int
  , diagTick ∷ !Word64
    -- ^ Gauge: the logical tick reached.
  }
  deriving (Eq, Show)

-- Configuration ----------------------------------------------------------------

-- | The bounds a scheduler is configured with. Each is at least one, and a
-- configured budget is positive; they are checked when the scheduler is made,
-- every violation at once, before anything is started.
data SchedulerBounds = SchedulerBounds
  { boundActiveTasks ∷ !Int
  , boundQueuedAdmissions ∷ !Int
  , boundRetainedResults ∷ !Int
    -- ^ Result reservations: taken at admission, given back when the result is
    -- observed.
  , boundQuanta ∷ !Quanta
  , boundOutstandingGrants ∷ !Int
  , boundControlRequests ∷ !Int
    -- ^ Control reservations: taken when a request is accepted, given back when
    -- its settlement is observed or abandoned.
  , boundServiceBudget ∷ !(Maybe Duration)
  }
  deriving (Eq, Show)

-- | A configuration problem.
data ConfigViolation
  = -- | A cap or a quantum below one, as the protocol model's own validation
    -- found it.
    LimitRefused !LimitViolation
  | GrantBoundBelowOne !Int
  | ControlBoundBelowOne !Int
  | BudgetNotPositive
  deriving (Eq, Show)

-- | A configuration was refused, and nothing was made. Every violation, not
-- the first.
newtype SchedulerRefused = SchedulerRefused (NonEmpty ConfigViolation)
  deriving (Eq, Show)

instance Exception SchedulerRefused

-- | What a scheduler is made from.
data SchedulerConfig = SchedulerConfig
  { schedLabel ∷ !Text
    -- ^ The owner's label, which an overrun is attributed to.
  , schedScope ∷ !SessionKey
    -- ^ The scope every task identity carries.
  , schedPolicy ∷ !Policy
  , schedBounds ∷ !SchedulerBounds
  , schedClock ∷ !MonotonicSource
    -- ^ The one clock: TIME-1's. Production is
    -- 'Hetoimasia.Foundation.Time.monotonicSource'; tests inject their own.
  , schedTimer ∷ !TimerBackend
    -- ^ What actually sleeps. A wake is only a notification to look at the
    -- clock again.
  , schedStopRequested ∷ STM Bool
    -- ^ Whether the owner has been asked to stop. It closes admission, grants
    -- and control at once, and ends a turn at its next safe boundary.
  }
