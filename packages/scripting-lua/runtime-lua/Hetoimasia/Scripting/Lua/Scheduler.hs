-- | Scheduling machinery for Lua tasks, reusable and independent of any VM.
--
-- This is LUA-21: what one owner needs to choose, under a policy, which of its
-- ready tasks runs next; to give each service class a bounded turn; to keep
-- logical time that only the application advances and elapsed deadlines on
-- TIME-1's monotonic source behind one owned timer; to apply pause, resume and
-- stop at safe boundaries; and to count what it did. It runs a task's segments
-- and closes a task's continuation through the two actions of a 'TaskHost', so
-- everything here is exercised against scripted segment outcomes. It starts no
-- thread, owns no VM and supervises nothing: the scheduled owner that hosts it
-- on a supervised worker, with a real VM and real coroutines, is LUA-6's, and
-- the finite-call adapter in "Hetoimasia.Scripting.Lua.Runtime" is unchanged.
--
-- = The shape of use
--
-- An application makes a 'Scheduler' ('newScheduler') and calls its producer
-- operations from any thread: 'admitTask', 'grantStep', 'requestControl'. Each
-- is a transaction that never blocks and answers at once. The owner's thread
-- loops: wait for work ('awaitWork', which composes admissions, control
-- requests, grants, the timer's wake and the owner's stop request), then
-- 'serviceTurn', and on its way out, under mask, 'stopScheduler'. Only that
-- thread calls 'awaitWork', 'serviceTurn' and 'stopScheduler'; a turn is not
-- reentrant, and an owner that exits without stopping leaves its timer armed
-- until it fires.
--
-- The waits that are for other threads ('awaitStepsComplete', 'awaitControl') are
-- transactions an application composes with @awaitSupervised@. They are the
-- application's: nothing here is reachable from Lua, and a Lua callback must not
-- call them, for the reason the finite-call adapter refuses a reply wait from
-- one. A task waits by yielding to its owner's scheduler, never by blocking its
-- owner's thread.
--
-- The protocol model's 'ExitRecord' is re-exported here because 'StopReport'
-- carries one; the finite-call adapter has an 'ExitRecord' of its own, so import
-- one of the two modules qualified.
--
-- = Policies
--
-- Each scheduler takes a 'Policy' at creation and keeps it for its life. A policy
-- chooses which ready task runs next, and nothing else: admission and capacity,
-- the class pass and its quanta, control and stop, the timer, the settlement of
-- results and ownership all stay with the runtime, under every policy.
-- 'fifoPolicy' is the supplied default; the rest of the interface is
-- 'PolicyView' and 'Candidate'. There is no other built-in policy and no way to
-- change a policy while a scheduler runs.
--
-- The runtime offers a policy an opportunity for one class at a time, and a
-- choice must be a ready task of that class. Anything else is refused, counted
-- in 'diagRefusedChoices', and never run: the oldest ready task of the class
-- runs instead. That is how a policy that tries to starve a class cannot: the
-- pass moves to the next class when a class has used its quantum or has nothing
-- ready, whatever was chosen, and control requests and stop are served between
-- segments, before the policy is asked again. What a policy can still do is
-- order the tasks of one class, which includes starving a peer in it; that is
-- the policy's choice and is bounded only by the class's quantum.
--
-- = Service classes, quanta and turns
--
-- Every task belongs to 'ControlClass', 'OrdinaryClass' or 'BackgroundClass'.
-- Each has a finite quantum of segments, validated with the other caps at
-- creation ('validateLimits': a quantum below one is refused, before anything
-- starts). The /pass/ visits the classes in that order; each class with a ready
-- task runs at most its quantum of segments before the pass moves on, and no
-- task, of any class, gets more than its class's quantum while a peer in
-- another class is ready. A /turn/ ('serviceTurn') runs the pass until it
-- completes, the owner is idle, the budget has expired or stop was requested.
--
-- The position in the pass, and how much of the current class's quantum is
-- used, belong to the scheduler and persist across turns. A turn that ends
-- early, at the budget, continues the same pass in the next: it never restarts at
-- the control class or replenishes a quantum, so where a budget cuts a pass
-- moves where turns end and nothing else. The pass starts afresh when it
-- completes and when nothing at all is ready.
--
-- Under 'fifoPolicy' a class's ready tasks run in order of their 'Ordinal',
-- which is issued at admission and again whenever a task rejoins the ready set:
-- a yielded, woken or resumed task is behind everything already ready.
--
-- = Looped and one-shot work
--
-- Admission records a 'TaskKind'. The kind is visible to a policy and to the
-- diagnostics and is never acted on by the runtime, so where a one-shot is placed
-- is the selected policy's, and the default policy appends it at its class's
-- tail like any other.
--
-- = Logical time
--
-- The scheduler's logical tick advances only when the application grants a step
-- ('grantStep') with a positive TIME-1 'Duration'. A round of scheduling, an
-- elapsed deadline and an expired budget never advance it.
--
-- Accepted grants are applied in the order they were accepted, one tick each,
-- and none is skipped or coalesced. A grant is applied only when every earlier
-- one has finished, so the logical timeline is strictly sequential and what runs
-- depends on the grants, never on when they arrived. Applying one adds its
-- duration to every task waiting for ticks and wakes those whose wait it
-- reaches, in the order their waits began; the policy then serves them. A grant
-- is /finished/, and its slot in the bound on outstanding grants is free again,
-- when every task it woke has stopped being ready or running: by waiting again,
-- completing, failing, being paused or being stopped. The bound
-- ('boundOutstandingGrants') counts grants accepted and not yet finished, and a
-- grant past it answers 'GrantFull' and changes nothing.
--
-- A task that waits ('ReportWaitTicks') for /n/ ticks wakes when the tick reaches
-- the one it was at when its wait began plus /n/. It resumes with the tick
-- reached and the logical duration granted since its wait began
-- ('ResumedLogical'), both fixed when the grant that satisfied it was applied, so
-- a later grant or a delayed dispatch cannot change them. A duration that cannot
-- be represented fails that task with a typed failure; nothing wraps.
--
-- 'awaitStepsComplete' is the STM condition "every accepted grant is applied and
-- finished": composed with 'Hetoimasia.Runtime.Supervision.awaitSupervised' it is
-- how an application observes tick completion without blocking a thread of its
-- own.
--
-- = Elapsed time
--
-- A task that waits ('ReportWaitElapsed') for a positive duration wakes once the
-- scheduler's monotonic source ('schedClock', TIME-1's) reaches its deadline, the
-- source's reading when the wait began plus the duration; arithmetic uses
-- TIME-1's, and a deadline that is not representable refuses the wait
-- ('WaitDeadlineOverflow'). It resumes with the time elapsed on that source
-- ('ResumedElapsed'). Elapsed deadlines are looked at once at the start of each
-- turn, so how often turns start can move when an elapsed wait wakes, which is
-- why elapsed waits are the one thing that legitimately changes readiness with
-- real time.
--
-- = The timer
--
-- One owned registration ("Hetoimasia.Scripting.Lua.Scheduler.Timer") is armed
-- for the earliest elapsed deadline and re-armed as it changes; it is cancelled
-- when nothing waits and at stop. Its wake is a flag 'awaitWork' composes with
-- the owner's other conditions; there is no polling, no per-task timer and no
-- thread of its own. A wake is a prompt to look at the clock, never proof that a
-- deadline passed.
--
-- = Budgets and overruns
--
-- A scheduler may be configured with an elapsed service budget per turn
-- ('boundServiceBudget'). When the clock shows it expired as a segment returns, no
-- further segment starts in that turn; control and stop are served at that
-- boundary and the pass continues in the next turn. A turn always starts at
-- least one segment, so a small budget cannot stop progress, and a budget so large
-- that its deadline is not representable never expires. The budget
-- never interrupts a running segment and never changes which task runs next or
-- the order tasks run in. A segment that ends after the budget's deadline is an
-- /overrun/, attributed to its owner, its kind and its entry point. The budget is
-- a service target, not a limit: no instruction hook is installed and a segment
-- that never returns is not stopped.
--
-- = Control
--
-- A caller holding a task's identity can request that it pause, resume or stop
-- ('requestControl'). The request never blocks, is usable from any thread
-- including a binding's action, and answers 'ControlAccepted', 'ControlFull',
-- 'ControlClosed' or 'ControlUnknownTarget' (a refusal changes nothing but a
-- counter). A reservation for its result is taken as it is accepted, bounded by
-- 'boundControlRequests', and held until the settlement is observed or
-- abandoned through its 'ControlTicket', once. Every accepted request settles
-- exactly once, as 'ControlApplied', 'ControlAlreadyInState' or
-- 'ControlNoLongerApplicable', including one overtaken by the task's end or by
-- the scheduler's stop.
--
-- Requests are applied between segments, in the order accepted, except that a
-- stop comes first: a stop takes precedence over any pause or resume accepted
-- beside it, so a stop is never undone by a resume. A request about the running
-- task is applied when its segment returns or yields. Pause freezes a task: it
-- runs nothing and occupies no turn. A task paused while it was waiting stays
-- waiting; if its wait is satisfied it earns the wake, keeps it, and runs
-- nothing, and resuming it then puts it at the tail of its class with that
-- wake, while resuming it before the wait is satisfied returns it to waiting. A
-- stop closes the task's continuation on the owner's thread, once, through
-- 'hostClose' and then cancels it; a failure of the close is retained in the
-- settlement and the turn report and is never reported as a clean close.
--
-- None of this is reachable from Lua here: the lifecycle bindings still answer
-- not-yet-supported.
--
-- = Stopping
--
-- 'stopScheduler' is the whole scheduler's stop, distinct from stopping a task.
-- It closes admission, grants and control, closes every live continuation once,
-- records each task's disposition and the discards in the model's
-- 'ExitRecord', settles every unapplied control request, discards unfinished
-- grants and cancels the timer, which stays disposed.
--
-- = Determinism
--
-- Given the same configuration, policy, admitted tasks, segment outcomes and
-- grants, the same tasks run in the same order whatever the budget and whenever
-- a turn is cut. Elapsed waits are the exception, since a deadline reached
-- changes readiness; the order among tasks already ready is unaffected. The proof
-- on a real VM is LUA-6's.
--
-- = Diagnostics
--
-- 'readDiagnostics' is a snapshot of bounded counters and gauges, readable
-- without borrowing Lua state: admitted and rejected work, queue and active
-- high-water marks, completed, yielded, waiting, failed, cancelled and discarded
-- counts, segments by class, overruns by site and refused policy choices. There
-- is no per-task history and no per-segment record.
module Hetoimasia.Scripting.Lua.Scheduler
  ( -- * The scheduler
    Scheduler
  , newScheduler
  , SchedulerConfig (..)
  , SchedulerBounds (..)
  , SchedulerRefused (..)
  , ConfigViolation (..)

    -- * Policy
  , Policy (..)
  , PolicyView (..)
  , Candidate (..)
  , servable
  , fifoPolicy

    -- * Admitting work
  , TaskKind (..)
  , TaskSpec (..)
  , AdmitAnswer (..)
  , AdmitRefusal (..)
  , admitTask
  , admissionAvailable
  , observeTask
  , taskPhase
  , TaskPhase (..)

    -- * Cadences
  , CadenceKey (..)
  , CadenceFault (..)
  , CadenceFiring (..)
  , startLogicalCadence
  , startElapsedCadence
  , armLogicalCadence
  , armElapsedCadence
  , disarmCadence
  , stopCadence
  , takeCadenceFirings
  , takeNextCadenceFiring
  , cadenceFiringsPending
  , watchKey
  , watchTick
  , setWatch
  , releaseWatch
  , releaseCadenceHold
  , cadenceHeld
  , cadenceAccrued
  , resetCadenceAccrued
  , tasksReady
  , schedulerClock

    -- * Logical time
  , GrantId (..)
  , GrantAnswer (..)
  , grantStep
  , grantComplete
  , stepsOutstanding
  , awaitStepsComplete
  , readTick

    -- * Control
  , ControlRequest (..)
  , ControlAnswer (..)
  , ControlResult (..)
  , ControlSettlement (..)
  , ControlTicket (..)
  , CloseReport (..)
  , requestControl

    -- * Driving the owner's thread
  , TaskHost (..)
  , TaskRun (..)
  , SegmentReport (..)
  , Resume (..)
  , WaitRefusal (..)
  , awaitWork
  , serviceTurn
  , serviceTurnWith
  , ownerControl
  , TurnReport (..)
  , TurnEnd (..)
  , stopScheduler
  , StopReport (..)
  , schedulerClosed

    -- * The timer seam
  , TimerBackend (..)
  , systemTimerBackend
  , maxRegistration
  , registrationMicroseconds

    -- * Diagnostics
  , Diagnostics (..)
  , Overrun (..)
  , readDiagnostics
  , maxOverrunSites

    -- * From the protocol model
  , TaskId
  , BehaviorId (..)
  , Ordinal
  , ServiceClass (..)
  , serviceClasses
  , Quantum (..)
  , Quanta (..)
  , LimitName (..)
  , LimitViolation (..)
  , SessionKey (..)
  , Owner (..)
  , ModId (..)
  , ExecutionDomain (..)
  , SessionId (..)
  , Epoch
  , firstEpoch
  , TaskOutcome (..)
  , TaskFailure (..)
  , RecoverySafety (..)
  , ReasonCode (..)
  , FailureReason
  , failureReason
  , reasonCode
  , reasonDetail
  , TerminalResult (..)
  , ExitRecord (..)
  , TaskDisposition (..)
  , DiscardCounts (..)
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVar
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (SomeAsyncException, SomeException, catch, fromException, mask, mask_, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Data.List (partition)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Sequence ((|>))
import qualified Data.Sequence as Seq
import Data.Word (Word64)
import Hetoimasia.Foundation.Time
  ( Duration
  , Instant
  , MonotonicSource
  , addDuration
  , deadlineReached
  , readInstant
  , zeroDuration
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( FailureReason
  , ReasonCode (..)
  , RecoverySafety (..)
  , failureReason
  , reasonCode
  , reasonDetail
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( BehaviorId (..)
  , Epoch
  , ExecutionDomain (..)
  , ModId (..)
  , Ordinal
  , Owner (..)
  , SessionId (..)
  , SessionKey (..)
  , TaskId
  , firstEpoch
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( LimitName (..)
  , LimitViolation (..)
  , Limits (..)
  , Quanta (..)
  , Quantum (..)
  , ServiceClass (..)
  , serviceClasses
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( DiscardCounts (..)
  , ExitRecord (..)
  , TaskDisposition (..)
  , TerminalResult (..)
  , newSession
  , observeResult
  , stopSession
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (TaskFailure (..), TaskOutcome (..))
import Hetoimasia.Scripting.Lua.Scheduler.Policy (fifoPolicy)
import Hetoimasia.Scripting.Lua.Scheduler.State
import Hetoimasia.Scripting.Lua.Scheduler.Timer
  ( Timer
  , TimerBackend (..)
  , clearTimerWake
  , disposeTimer
  , timerCancelFailure
  , maxRegistration
  , newTimer
  , registrationMicroseconds
  , syncTimer
  , systemTimerBackend
  , timerWoken
  )
import Hetoimasia.Scripting.Lua.Scheduler.Types

-- The scheduler ----------------------------------------------------------------

-- | One owner's scheduling machinery over tasks that carry values of type @v@.
data Scheduler v = Scheduler
  { schedConfig ∷ !SchedulerConfig
  , schedState ∷ !(TVar (SchedState v))
  , schedTimerOf ∷ !Timer
  }

-- | Make a scheduler.
--
-- Every bound is checked first, every violation at once: the caps and the three
-- quanta through the protocol model's own validation, the grant and control
-- bounds, and a configured budget, which must be positive. A refused
-- configuration makes nothing: no timer, no state. This is the validation that
-- happens before a scheduled owner starts a worker.
newScheduler ∷ SchedulerConfig → IO (Either SchedulerRefused (Scheduler v))
newScheduler config = case (NonEmpty.nonEmpty violations, built) of
  (Nothing, Right session) → do
    state ← newTVarIO (initialState (schedLabel config) session)
    timer ← newTimer (schedTimer config)
    pure (Right (Scheduler config state timer))
  (Just refused, _) → pure (Left (SchedulerRefused refused))
  (Nothing, Left refused) → pure (Left (SchedulerRefused (fmap LimitRefused refused)))
  where
    bounds = schedBounds config
    limits =
      Limits
        { maxActiveTasks = boundActiveTasks bounds
        , maxQueuedAdmissions = boundQueuedAdmissions bounds
        , maxSubscriptions = 1
        , maxSubscriptionQueue = 1
        , maxOutstandingRequests = 1
        , maxPayloadBytes = 1
        , maxRetainedResults = boundRetainedResults bounds
        , limitQuanta = boundQuanta bounds
        }
    built = newSession (schedScope config) limits
    violations =
      either (map LimitRefused . NonEmpty.toList) (const []) built
        <> [GrantBoundBelowOne (boundOutstandingGrants bounds) | boundOutstandingGrants bounds < 1]
        <> [ControlBoundBelowOne (boundControlRequests bounds) | boundControlRequests bounds < 1]
        <> [BudgetNotPositive | boundServiceBudget bounds == Just zeroDuration]

-- | Whether producers are admitted: the scheduler is open and the owner has not
-- been asked to stop.
isOpen ∷ Scheduler v → SchedState v → STM Bool
isOpen scheduler state = case ssPhase state of
  Open → not <$> schedStopRequested (schedConfig scheduler)
  _ → pure False

-- | Whether the scheduler has stopped.
schedulerClosed ∷ Scheduler v → STM Bool
schedulerClosed scheduler = do
  state ← readTVar (schedState scheduler)
  pure $ case ssPhase state of
    Closed _ → True
    _ → False

-- Producers ---------------------------------------------------------------------

-- | Admit a task. Never blocks: it answers the task's identity, or why not.
--
-- The identity is the engine's, issued here and never again, not after the
-- task's result has been observed. A name in the spec grants nothing.
admitTask ∷ Scheduler v → TaskSpec v → STM AdmitAnswer
admitTask scheduler spec = do
  state ← readTVar (schedState scheduler)
  open ← isOpen scheduler state
  let (next, answer) = admitIn open spec state
  writeTVar (schedState scheduler) next
  pure answer

-- | Whether admitting a task like this one would be accepted now: the scheduler is
-- open and neither its queue of admissions nor its stored results is full. Reads
-- and changes nothing, so an owner can wait for room.
admissionAvailable ∷ Scheduler v → TaskSpec v → STM Bool
admissionAvailable scheduler spec = do
  state ← readTVar (schedState scheduler)
  open ← isOpen scheduler state
  pure $ open && case snd (admitIn open spec state) of
    Admitted _ → True
    AdmitRefused _ → False

-- | Take a finished task's terminal result, if it has one, and give back the
-- result storage its admission reserved. A task that has not finished, and one
-- whose result was already taken, answer 'Nothing' and change nothing.
observeTask ∷ Scheduler v → TaskId → STM (Maybe (TerminalResult v))
observeTask scheduler identity = do
  state ← readTVar (schedState scheduler)
  case observeResult identity (ssSession state) of
    (session, Right result) → do
      writeTVar (schedState scheduler) state {ssSession = session}
      pure (Just result)
    (_, Left _) → pure Nothing

-- | Where a task is, or 'Nothing' for an identity that names no task here.
taskPhase ∷ Scheduler v → TaskId → STM (Maybe TaskPhase)
taskPhase scheduler identity = phaseOf identity <$> readTVar (schedState scheduler)

-- | Grant a logical step of this positive duration. Never blocks.
--
-- Accepted grants are applied in order, and the grant is finished when the work
-- it made due has. See the module header.
grantStep ∷ Scheduler v → Duration → STM GrantAnswer
grantStep scheduler duration = do
  state ← readTVar (schedState scheduler)
  open ← isOpen scheduler state
  let (next, answer) = grantIn open (boundOutstandingGrants (schedBounds (schedConfig scheduler))) duration state
  writeTVar (schedState scheduler) next
  pure answer

-- Cadences -----------------------------------------------------------------------

-- | Register a logical cadence, due at this tick, with nothing accrued. Never blocks.
-- 'False' for a key already registered and for a scheduler that has stopped or been
-- asked to.
--
-- A cadence is the owner's periodic demand on logical time. The scheduler adds the
-- duration of every grant it applies to what the cadence has accrued, and when a
-- grant is applied that reaches the tick the cadence is due at, it holds that grant:
-- the grant is not finished, and no later one is applied, until the owner releases the
-- hold ('releaseCadenceHold'), exactly as a task the grant woke holds it until the task
-- stops being ready or running. The point is taken ('takeCadenceFirings') on the owner's
-- thread at the boundary that follows, before any task the grant woke is chosen, and
-- the cadence is not due at anything until the owner arms it again.
startLogicalCadence ∷ Scheduler v → CadenceKey → Word64 → STM Bool
startLogicalCadence scheduler key target = startCadence scheduler (cadenceStartLogical key target)

-- | Register an elapsed cadence, due at this deadline on the scheduler's clock. Like a
-- waiter's deadline it is placed behind the owner's one timer and looked at once at
-- the start of each turn; the point is taken at the boundary that follows.
startElapsedCadence ∷ Scheduler v → CadenceKey → Instant → STM Bool
startElapsedCadence scheduler key deadline = startCadence scheduler (cadenceStartElapsed key deadline)

startCadence ∷ Scheduler v → (SchedState v → Maybe (SchedState v)) → STM Bool
startCadence scheduler step = do
  state ← readTVar (schedState scheduler)
  open ← isOpen scheduler state
  case (open, step state) of
    (True, Just next) → True <$ writeTVar (schedState scheduler) next
    _ → pure False

-- | Arm a registered logical cadence for a tick, keeping what it has accrued.
armLogicalCadence ∷ Scheduler v → CadenceKey → Word64 → STM ()
armLogicalCadence scheduler key target = modifyTVar' (schedState scheduler) (cadenceArmLogical key target)

-- | Arm a registered elapsed cadence for a deadline.
armElapsedCadence ∷ Scheduler v → CadenceKey → Instant → STM ()
armElapsedCadence scheduler key deadline = modifyTVar' (schedState scheduler) (cadenceArmElapsed key deadline)

-- | Make a cadence due at nothing. It keeps what it has accrued.
disarmCadence ∷ Scheduler v → CadenceKey → STM ()
disarmCadence scheduler key = modifyTVar' (schedState scheduler) (cadenceDisarm key)

-- | Take a cadence away: its demand is cancelled, a point it reached and nobody took
-- is dropped and a grant it held is released.
stopCadence ∷ Scheduler v → CadenceKey → STM ()
stopCadence scheduler key = modifyTVar' (schedState scheduler) (cadenceStop key)

-- | The cadence points reached since they were last taken, in the order they were
-- reached. Taking them does not release the grants they hold.
takeCadenceFirings ∷ Scheduler v → STM [(CadenceKey, CadenceFiring)]
takeCadenceFirings scheduler = do
  state ← readTVar (schedState scheduler)
  let (taken, next) = cadenceTake state
  writeTVar (schedState scheduler) next
  pure taken

-- | The first cadence point reached and not taken. A point taken one at a time leaves the
-- ones behind it where a pause, a resume or an ending can still invalidate them.
takeNextCadenceFiring ∷ Scheduler v → STM (Maybe (CadenceKey, CadenceFiring))
takeNextCadenceFiring scheduler = do
  state ← readTVar (schedState scheduler)
  let (taken, next) = cadenceTakeNext state
  writeTVar (schedState scheduler) next
  pure taken

-- | Ask to be held at a tick, if it is earlier than the one already asked for. A grant that
-- reaches it is held, and not finished, and no later one is applied, until the owner releases
-- it ('releaseWatch'), exactly as a cadence point holds one: the point is first among those the
-- grant reached, under 'watchKey', and is taken on the owner's thread at the boundary that
-- follows, before any task the grant woke is chosen. A scheduler that has stopped keeps nothing.
watchTick ∷ Scheduler v → Word64 → STM ()
watchTick scheduler tick = modifyTVar' (schedState scheduler) (watchTickIn tick)

-- | Set the tick the owner asks to be held at, replacing any.
setWatch ∷ Scheduler v → Maybe Word64 → STM ()
setWatch scheduler target = modifyTVar' (schedState scheduler) (setWatchIn target)

-- | Give back the grant the watch holds, once the owner has done what the tick asked of it.
releaseWatch ∷ Scheduler v → STM ()
releaseWatch scheduler = modifyTVar' (schedState scheduler) releaseWatchIn

-- | Whether a cadence point has been reached and not taken.
cadenceFiringsPending ∷ Scheduler v → STM Bool
cadenceFiringsPending scheduler = not . Seq.null . ssFirings <$> readTVar (schedState scheduler)

-- | Give back the grant a cadence holds, once the owner's work for its point is done
-- or can no longer happen in its tick.
releaseCadenceHold ∷ Scheduler v → CadenceKey → STM ()
releaseCadenceHold scheduler key = modifyTVar' (schedState scheduler) (cadenceRelease key)

-- | Whether a cadence holds a grant.
cadenceHeld ∷ Scheduler v → CadenceKey → STM Bool
cadenceHeld scheduler key = cadenceHeldBy key <$> readTVar (schedState scheduler)

-- | The logical duration a cadence has accrued, 'Nothing' for a key that is not
-- registered.
cadenceAccrued ∷ Scheduler v → CadenceKey → STM (Maybe Duration)
cadenceAccrued scheduler key = cadenceAccruedOf key <$> readTVar (schedState scheduler)

-- | Begin a cadence's accrual again from nothing.
resetCadenceAccrued ∷ Scheduler v → CadenceKey → STM ()
resetCadenceAccrued scheduler key = modifyTVar' (schedState scheduler) (cadenceResetAccrued key)

-- | Whether any task is ready to run a segment: whether anything can still make
-- progress without a grant, a deadline or a request.
tasksReady ∷ Scheduler v → STM Bool
tasksReady scheduler = not . null . readyCandidates <$> readTVar (schedState scheduler)

-- | The clock the scheduler was made with.
schedulerClock ∷ Scheduler v → MonotonicSource
schedulerClock = schedClock . schedConfig

-- | Whether this grant has been applied and its work has finished.
grantComplete ∷ Scheduler v → GrantId → STM Bool
grantComplete scheduler (GrantId number) = do
  state ← readTVar (schedState scheduler)
  pure (number < ssNextGrant state - fromIntegral (outstandingGrants state))

-- | How many accepted grants have not finished.
stepsOutstanding ∷ Scheduler v → STM Int
stepsOutstanding scheduler = outstandingGrants <$> readTVar (schedState scheduler)

-- | Retry until every accepted grant has been applied and has finished. Compose
-- it with @awaitSupervised@ to observe tick completion without blocking a
-- thread of your own.
awaitStepsComplete ∷ Scheduler v → STM ()
awaitStepsComplete scheduler = do
  outstanding ← stepsOutstanding scheduler
  when (outstanding > 0) retry

-- | The logical tick reached.
readTick ∷ Scheduler v → STM Word64
readTick scheduler = ssTick <$> readTVar (schedState scheduler)

-- | Request that a task pause, resume or stop. Never blocks.
--
-- Accepted, a request takes a reservation for its result and is applied at the
-- next safe boundary. The answer says nothing of what will become of it: that is
-- the settlement the ticket yields.
requestControl ∷ Scheduler v → TaskId → ControlRequest → STM ControlAnswer
requestControl scheduler identity request = do
  state ← readTVar (schedState scheduler)
  open ← isOpen scheduler state
  let refuse answer = do
        writeTVar (schedState scheduler) $
          state {ssCounts = (ssCounts state) {diagControlRefused = diagControlRefused (ssCounts state) + 1}}
        pure answer
  if not open
    then refuse ControlClosed
    else
      if not (liveTarget identity state)
        then refuse ControlUnknownTarget
        else
          if ssReserved state >= boundControlRequests (schedBounds (schedConfig scheduler))
            then refuse ControlFull
            else do
              slot ← Slot <$> newTVar Nothing <*> newTVar False <*> newTVar False
              writeTVar (schedState scheduler) $
                state
                  { ssControl = ssControl state |> PendingControl identity request slot
                  , ssReserved = ssReserved state + 1
                  , ssCounts = (ssCounts state) {diagControlAccepted = diagControlAccepted (ssCounts state) + 1}
                  }
              pure (ControlAccepted (ticketFor (schedState scheduler) slot))

-- | The ticket for a slot.
ticketFor ∷ TVar (SchedState v) → Slot → ControlTicket
ticketFor reference slot =
  ControlTicket
    { pollControl = observeSlot reference slot
    , awaitControl = observeSlot reference slot >>= maybe retry pure
    , forgetControl = forgetSlot reference slot
    }

-- | Write a slot's settlement, once. One that its caller has already abandoned
-- gives its reservation back as it settles.
settleSlot ∷ TVar (SchedState v) → Slot → ControlSettlement → STM ()
settleSlot reference slot settlement =
  readTVar (slotSettlement slot) >>= \case
    Just _ → pure ()
    Nothing → do
      writeTVar (slotSettlement slot) (Just settlement)
      forgotten ← readTVar (slotForgotten slot)
      when forgotten (releaseSlot reference slot)

-- | Give a slot's reservation back, once.
releaseSlot ∷ TVar (SchedState v) → Slot → STM ()
releaseSlot reference slot = do
  released ← readTVar (slotReleased slot)
  unless released $ do
    writeTVar (slotReleased slot) True
    modifyTVar' reference (\state → state {ssReserved = ssReserved state - 1})

observeSlot ∷ TVar (SchedState v) → Slot → STM (Maybe ControlSettlement)
observeSlot reference slot =
  readTVar (slotSettlement slot) >>= \case
    Nothing → pure Nothing
    Just settlement → Just settlement <$ releaseSlot reference slot

forgetSlot ∷ TVar (SchedState v) → Slot → STM ()
forgetSlot reference slot = do
  writeTVar (slotForgotten slot) True
  readTVar (slotSettlement slot) >>= \case
    Just _ → releaseSlot reference slot
    Nothing → pure ()

-- Diagnostics -------------------------------------------------------------------

-- | A snapshot of the scheduler's counters and gauges.
readDiagnostics ∷ Scheduler v → STM Diagnostics
readDiagnostics scheduler = diagnosticsOf <$> readTVar (schedState scheduler)

-- The owner's thread ------------------------------------------------------------

-- | Retry until a turn has something to do: a ready task, an admission an active
-- slot is free for, a control request, a grant to apply, a timer wake, or the
-- owner's stop request. That is the one place an idle owner sleeps, and nothing
-- polls. A turn that finds the stop request ends at once, and the owner then
-- calls 'stopScheduler'.
awaitWork ∷ Scheduler v → STM ()
awaitWork scheduler = do
  state ← readTVar (schedState scheduler)
  woken ← timerWoken (schedTimerOf scheduler)
  stopping ← schedStopRequested (schedConfig scheduler)
  unless (workPending state || woken || stopping) retry

-- | What a turn has accumulated.
data Turn = Turn
  { turnCount ∷ !Int
  , turnFailed ∷ ![(TaskId, TaskFailure)]
  , turnRefused ∷ ![(TaskId, WaitRefusal)]
  }

-- | Run one service turn, on the owner's thread.
--
-- At the start the elapsed waiters whose deadlines the clock has reached are
-- woken. Then, at each safe boundary (before the first segment and after every
-- segment) grants are applied and queued admissions activated, control requests
-- are applied, the owner's stop request is looked at, and the budget is looked
-- at; if none of those ends the turn, the pass chooses the next segment and the
-- host runs it. An exception from 'hostRun' is a failure of the host and
-- propagates; the task stays running, which a later 'stopScheduler' records as an
-- outstanding segment. At the end the timer is brought in line with the earliest
-- deadline.
--
-- The clock is read only when something needs it: at the start of a turn that has
-- elapsed waiters or a budget, as a segment returns when there is a budget or the
-- segment waits for elapsed time.
serviceTurn ∷ Scheduler v → TaskHost v → IO TurnReport
serviceTurn = serviceTurnWith (pure False)

-- | 'serviceTurn', running an action of the owner's at each safe boundary: before
-- the first segment and after every segment, when no task is running. It is how an
-- owner that serves more than tasks looks at what it was asked, and at what the
-- scheduler released, at the same boundaries the scheduler does. What it raises is
-- a failure of the host and propagates out of the turn.
--
-- The action runs after what the scheduler does at the boundary: after the
-- activations, controls and closes that freed room, so what waited for that room is
-- tried then and not at the start of the next turn. It answers whether it released
-- or used anything the scheduler's own work depends on (it observed a result, which
-- gives back an active slot and a place, it applied a control, it admitted), and
-- while it does the boundary is done again, so a boundary ends only where neither the
-- scheduler nor the owner has anything more to do with what is there. That is why
-- where a turn is cut changes nothing: the next turn's first boundary finds what this
-- one's last left.
serviceTurnWith ∷ IO Bool → Scheduler v → TaskHost v → IO TurnReport
serviceTurnWith atBoundary scheduler host = do
  phaseOpen ← atomically (isStillOpen scheduler)
  if not phaseOpen
    then pure (TurnReport 0 TurnClosed [] [] [])
    else do
      atomically (clearTimerWake (schedTimerOf scheduler))
      atomically (modifyTVar' (schedState scheduler) acknowledgeEvidence)
      waiting ← elapsedDemand <$> readTVarIO (schedState scheduler)
      started ←
        if waiting || budget /= Nothing
          then Just <$> readInstant (schedClock config)
          else pure Nothing
      forM_ started $ \now →
        when waiting (atomically (modifyTVar' (schedState scheduler) (wakeDueElapsed now)))
      let deadline = do
            limit ← budget
            now ← started
            either (const Nothing) Just (addDuration now limit)
      report ← loop deadline started (Turn 0 [] [])
      -- The timer is brought in line first, and only then are the failures of the
      -- closes made so far handed to the report, so one that throws leaves them in
      -- the scheduler for the next report or the stop.
      syncTimerFor scheduler
      evidence ← atomically $ do
        state ← readTVar (schedState scheduler)
        let (kept, delivered) = deliverEvidence state
        writeTVar (schedState scheduler) delivered
        pure kept
      pure report {turnCloseFailures = evidence}
  where
    config = schedConfig scheduler
    budget = boundServiceBudget (schedBounds config)

    done turn end =
      pure
        TurnReport
          { turnSegments = turnCount turn
          , turnEnd = end
          , turnFailures = reverse (turnFailed turn)
          , turnRefusedWaits = reverse (turnRefused turn)
          , turnCloseFailures = []
          }

    loop ∷ Maybe Instant → Maybe Instant → Turn → IO TurnReport
    loop deadline reading turn0 = do
      turn ← boundary atBoundary scheduler host turn0
      stopping ← atomically (schedStopRequested config)
      -- The boundary can close continuations and so take time: look at the clock
      -- again before judging the budget, once a segment has run.
      fresh ←
        if budget /= Nothing && turnCount turn > 0
          then Just <$> readInstant (schedClock config)
          else pure reading
      let expired = case (fresh, deadline) of
            (Just now, Just limit) → deadlineReached now limit
            _ → False
      if stopping
        then idleAndDone turn TurnStopRequested
        else
          if expired && turnCount turn > 0
            then idleAndDone turn TurnBudgetExpired
            else do
              chosen ← atomically (chooseNext scheduler)
              case chosen of
                Nothing → done turn TurnIdle
                Just Nothing
                  | turnCount turn > 0 → done turn TurnPassComplete
                  | otherwise → loop deadline fresh turn
                Just (Just run) → do
                  (events, after) ← runSegment deadline run
                  loop
                    deadline
                    (after <|> fresh)
                    (record events turn {turnCount = turnCount turn + 1})

    -- A turn that ends before it chooses leaves the pass as the next choice would
    -- have: afresh if nothing is ready.
    idleAndDone turn end = do
      atomically (modifyTVar' (schedState scheduler) resetPassIfIdle)
      done turn end

    -- Run a segment and apply its report. The report is applied, so the task is
    -- no longer running and its continuation is stop's to close, before anything
    -- that can fail or be interrupted: the transition is masked from the moment
    -- the host returns. Only an elapsed wait needs the clock to be placed, and if
    -- reading it fails that wait is applied as a yield, which leaves the task
    -- ready and closable.
    runSegment deadline run = mask $ \restore → do
      report ← restore (hostRun host run)
      let identity = runTask run
          reference = schedState scheduler
          apply reading = atomically $ do
            state ← readTVar reference
            let (next, found) = applyReport identity reading report state
            writeTVar reference next
            pure (siteOf identity state, found)
      (site, events, after) ← case report of
        ReportWaitElapsed value _ → do
          now ←
            readInstant (schedClock config)
              `onException` atomically (modifyTVar' reference (fst . applyReport identity Nothing (ReportYielded value)))
          (found, applied) ← apply (Just now)
          pure (found, applied, Just now)
        _ → do
          (found, applied) ← apply Nothing
          now ← if budget /= Nothing then Just <$> readInstant (schedClock config) else pure Nothing
          pure (found, applied, now)
      let overran = case (after, deadline) of
            (Just now, Just limit) → now > limit
            _ → False
      when overran (atomically (modifyTVar' reference (recordOverrunAt site)))
      closeOwed scheduler host
      pure (events, after)

    record events turn = foldl' note turn events
    note turn = \case
      Failed identity failure → turn {turnFailed = (identity, failure) : turnFailed turn}
      WaitRefused identity why → turn {turnRefused = (identity, why) : turnRefused turn}

-- | Whether the scheduler is open, for the owner's own thread: stop requested is
-- not a reason to refuse the turn, it ends at the next boundary.
isStillOpen ∷ Scheduler v → STM Bool
isStillOpen scheduler = do
  state ← readTVar (schedState scheduler)
  pure $ case ssPhase state of
    Open → True
    _ → False

-- | Choose and begin the next segment. 'Nothing' is nothing ready; @Just Nothing@
-- is the end of the pass.
chooseNext ∷ Scheduler v → STM (Maybe (Maybe (TaskRun v)))
chooseNext scheduler = do
  state ← readTVar (schedState scheduler)
  let (chosen, selection) = selectNext (schedPolicy (schedConfig scheduler)) state
  case selection of
    NothingReady → Nothing <$ writeTVar (schedState scheduler) chosen
    PassEnded → Just Nothing <$ writeTVar (schedState scheduler) chosen
    Selected identity → case beginSegment identity chosen of
      Just (next, run) → Just (Just run) <$ writeTVar (schedState scheduler) next
      Nothing → Just Nothing <$ writeTVar (schedState scheduler) chosen

-- | A safe boundary: apply grants and activate queued admissions, apply control
-- requests, and settle what that freed, then let the owner use what it freed, and
-- again for what that freed in turn.
boundary ∷ IO Bool → Scheduler v → TaskHost v → Turn → IO Turn
boundary atBoundary scheduler host = settle
  where
    settle turn = do
      first ← reconcile
      applyControls scheduler host
      second ← reconcile
      closeOwed scheduler host
      again ← atBoundary
      let next = foldl' absorb turn (first <> second)
      if again then settle next else pure next
    reconcile = atomically $ do
      state ← readTVar (schedState scheduler)
      let (next, events) = settleGrants (activateQueued state)
      writeTVar (schedState scheduler) next
      pure events
    absorb turn = \case
      Failed identity failure → turn {turnFailed = (identity, failure) : turnFailed turn}
      WaitRefused identity why → turn {turnRefused = (identity, why) : turnRefused turn}

-- | Close the continuations that tasks left suspended when they ended. A failure
-- of a close is kept in the scheduler's state, in the same step that takes the
-- obligation off, until a turn's report or the stop's takes it. Each close and its
-- record are masked together; one interrupted inside the host stays owed, and the
-- scheduler's stop makes it.
closeOwed ∷ Scheduler v → TaskHost v → IO ()
closeOwed scheduler host = do
  owed ← closeObligations <$> readTVarIO (schedState scheduler)
  mapM_ close owed
  where
    close identity = mask_ $ do
      closed ← tryClose (hostClose host identity)
      atomically . modifyTVar' (schedState scheduler) $
        retainEvidence [(identity, failure) | CloseFailed failure ← [closed]] . closedObligation identity

-- | Apply the accepted control requests, stops first.
--
-- A request leaves the queue in the transaction that settles it, so an exception
-- that interrupts the batch leaves every request not yet settled queued, and the
-- scheduler's stop settles it. A close that completed is recorded before any
-- cancellation is delivered; one that was interrupted is retried by that stop.
applyControls ∷ Scheduler v → TaskHost v → IO ()
applyControls scheduler host = do
  batch ← toList . ssControl <$> readTVarIO reference
  let (stops, others) = partition ((== RequestStop) . pendingRequest) batch
  mapM_ applyOne (stops <> others)
  where
    reference = schedState scheduler

    -- Settle a request and take it out of the queue together.
    conclude pending result closing = do
      modifyTVar' reference $ \state →
        state {ssControl = Seq.filter ((/= slotSettlement (pendingSlot pending)) . slotSettlement . pendingSlot) (ssControl state)}
      settleSlot reference (pendingSlot pending) (ControlSettlement result closing)

    applyOne pending = case pendingRequest pending of
      RequestPause → immediate pending pauseIn
      RequestResume → immediate pending resumeIn
      RequestStop → do
        live ← liveTarget identity <$> readTVarIO reference
        if not live
          then atomically (conclude pending ControlNoLongerApplicable Nothing)
          else mask_ $ do
            -- Masked from the close to its record: a cancellation that arrives
            -- after the close has returned waits until the task is cancelled and
            -- the request settled, so a completed close is never repeated.
            closed ← tryClose (hostClose host identity)
            atomically $ do
              state ← readTVar reference
              let (next, result) = cancelIn identity state
              writeTVar reference (retainEvidence [(identity, failure) | CloseFailed failure ← [closed]] next)
              conclude pending result (Just closed)
      where
        identity = pendingTask pending

    immediate pending step = atomically $ do
      state ← readTVar reference
      let (next, result) = step (pendingTask pending) state
      writeTVar reference next
      conclude pending result Nothing

-- | Pause, resume or stop a task by the owner's own thread, at a boundary, at once:
-- the three operations 'requestControl' applies between segments, without a
-- reservation, a ticket or a queue to wait in, for an owner that applies requests of
-- its own at the same boundaries. A task that is running, or that is not live, is
-- no longer a target and answers 'ControlNoLongerApplicable'. A stop closes the
-- task's continuation through 'hostClose', once, and cancels it; a failure of the
-- close is kept as it is for a task's own stop. Only the owner's thread calls it, and
-- never inside a segment.
ownerControl ∷ Scheduler v → TaskHost v → TaskId → ControlRequest → IO ControlResult
ownerControl scheduler host identity = \case
  RequestPause → atomically (immediate pauseIn)
  RequestResume → atomically (immediate resumeIn)
  RequestStop → do
    live ← liveTarget identity <$> readTVarIO reference
    if not live
      then pure ControlNoLongerApplicable
      else mask_ $ do
        closed ← tryClose (hostClose host identity)
        atomically $ do
          state ← readTVar reference
          let (next, result) = cancelIn identity state
          writeTVar reference (retainEvidence [(identity, failure) | CloseFailed failure ← [closed]] next)
          pure result
  where
    reference = schedState scheduler
    immediate step = do
      state ← readTVar reference
      let (next, result) = step identity state
      writeTVar reference next
      pure result

-- | Close a continuation. A synchronous failure is the report; an asynchronous
-- exception is not this action's to keep and propagates.
tryClose ∷ IO () → IO CloseReport
tryClose action =
  (CloseClean <$ action) `catch` \failure → case fromException failure of
    Just (_ ∷ SomeAsyncException) → throwIO failure
    Nothing → pure (CloseFailed failure)

-- | Bring the timer in line with the earliest elapsed deadline.
syncTimerFor ∷ Scheduler v → IO ()
syncTimerFor scheduler = do
  state ← readTVarIO (schedState scheduler)
  case ssPhase state of
    Open → syncTimer (schedTimerOf scheduler) (schedClock (schedConfig scheduler)) (earliestDeadline state)
    _ → pure ()

-- | Stop the whole scheduler, on the owner's thread, once.
--
-- Admission, grants and control close first. Every live continuation that is not
-- inside a segment is then closed once, in identity order, through 'hostClose',
-- and a failure of one close does not stop the others. The model records each
-- task's disposition and what was discarded, every accepted request not yet
-- applied settles as no longer applicable, unfinished grants are discarded and
-- the timer is cancelled and stays disposed. A second call answers the first's
-- report and closes nothing again. Everything runs masked, and every close is
-- attempted: a close that is interrupted keeps the interruption as its failure,
-- the others still run, the stop completes, and the first interruption is raised
-- again afterwards. A timer whose cancellation throws does not end the stop
-- either: that failure is in the report, and is raised once the stop has
-- completed, unless an interruption is, and a later call answers the completed
-- report in both cases.
stopScheduler ∷ Scheduler v → TaskHost v → IO StopReport
stopScheduler scheduler host = mask_ $ do
  claim ← atomically $ do
    state ← readTVar reference
    case ssPhase state of
      Closed report → pure (Left report)
      Closing → retry
      Open → Right (stoppableTasks state) <$ writeTVar reference state {ssPhase = Closing}
  case claim of
    Left report → pure report
    Right identities → do
      -- The timer is cancelled first, so no wake can arrive while continuations,
      -- which can take as long as Lua runs, are closed.
      -- A cancellation that throws is kept, and the stop goes on: the closes and
      -- the settlement of the control requests do not wait on it.
      timerFailure ← try (disposeTimer (schedTimerOf scheduler))
      failures ← newIORef []
      interrupted ← newIORef Nothing
      -- Every obligation is closed, masked: an exception that reaches a close at
      -- one of its own interruptible points is that close's failure, kept as its
      -- evidence, and the closes after it still run. The first such exception is
      -- raised again once the scheduler has stopped.
      forM_ identities $ \identity →
        try (hostClose host identity) >>= \case
          Right () → pure ()
          Left (failure ∷ SomeException) → do
            modifyIORef' failures ((identity, failure) :)
            when (isJust (fromException failure ∷ Maybe SomeAsyncException)) $
              modifyIORef' interrupted (<|> Just failure)
      collected ← reverse <$> readIORef failures
      -- What cancelling the timer raised, here or in a turn before: the stop is
      -- where the owner's cleanup is accounted for.
      cancelled ← atomically (timerCancelFailure (schedTimerOf scheduler))
      report ← atomically (settleStop collected (either Just (const Nothing) timerFailure <|> cancelled))
      readIORef interrupted >>= maybe (either (\(failure ∷ SomeException) → throwIO failure) (const (pure report)) timerFailure) throwIO
  where
    reference = schedState scheduler
    settleStop collected timerRaised = do
      before ← readTVar reference
      forM_ (ssControl before) $ \pending →
        settleSlot reference (pendingSlot pending) (ControlSettlement ControlNoLongerApplicable Nothing)
      state ← readTVar reference
      let (session, exit) = stopSession (ssSession state)
          report = StopReport exit (toList (ssDelivered state) <> toList (ssEvidence state) <> collected) (Seq.length (ssControl before)) timerRaised
          aborted = liveCount state
          discards = exitDiscards exit
          counts = ssCounts state
      writeTVar reference $
        state
          { ssSession = session
          , ssInfo = Map.empty
          , ssPass = Pass ControlClass 0
          , ssGrants = Seq.empty
          , ssNextGrant = ssNextGrant state
          , ssLogical = Map.empty
          , ssElapsed = Map.empty
          , ssCadenceLogical = Map.empty
          , ssCadenceElapsed = Map.empty
          , ssFirings = Seq.empty
          , ssWatch = Nothing
          , ssWatchHold = Nothing
          , ssControl = Seq.empty
          , ssToClose = Set.empty
          , ssEvidence = Seq.empty
          , ssDelivered = Seq.empty
          , ssPhase = Closed report
          , ssCounts =
              counts
                { diagCancelled = diagCancelled counts + aborted
                , diagDiscarded = diagDiscarded counts + discardedAdmissions discards + discardedResults discards
                }
          }
      pure report
