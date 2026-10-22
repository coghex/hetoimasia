-- | Scheduled Lua owners under runtime supervision.
--
-- A scheduled owner is one supervised worker running one VM, like the owners of
-- "Hetoimasia.Scripting.Lua.Runtime", but it serves /tasks/ instead of finite
-- calls: a module's entry point run as a coroutine, a segment at a time, under
-- the scheduling machinery of "Hetoimasia.Scripting.Lua.Scheduler". This is
-- LUA-6. It hosts the host library's task execution (LUA-20) and the scheduler
-- (LUA-21) on a supervised worker and adds no scheduling of its own: which task
-- runs next, what a tick or a deadline is, how a budget ends a turn and how pause,
-- resume and stop apply are the scheduler's, and its module documents them.
--
-- The finite-call owners are unchanged and stay the way to run a call. An
-- application opts into a scheduled owner, which admits all executable work as
-- tasks; finite work there is a task that completes in one segment. A finite-call
-- owner and a scheduled owner never run the same VM, and any number of each can be
-- created and retired while the others run.
--
-- = Script instances
--
-- An owner created with a 'scheduledInstances' configuration also hosts script
-- instances, which "Hetoimasia.Scripting.Lua.Instance" documents: modules' behavior
-- with a @self@ of their own, hooks and event callbacks, whose invocations are tasks
-- of this owner's scheduler and so are ordered by its policy among its tasks. An
-- owner without the configuration loads nothing for them and behaves as it did.
--
-- = Lifecycle services
--
-- An owner created with a 'scheduledLifecycle' grant gives its scripts control and
-- inspection of the script instances of the owners the grant covers, and of its own,
-- as "Hetoimasia.Scripting.Lua.Lifecycle" documents. The grant is the whole of the
-- authority, and an owner created without one keeps the not-yet-supported fault every
-- lifecycle operation answered. The grant is checked against the owners it names before
-- anything starts and refused, naming every reason, as 'LifecycleRefused'. The owner's
-- exit abandons the receipts its scripts held, which undoes no request they had made.
--
-- = Creation and readiness
--
-- 'startScheduledOwner' validates the scheduler's configuration (the caps and the
-- quanta, through the protocol model's own validation, the grant and control
-- bounds, and the budget) before anything starts, raising
-- 'Hetoimasia.Scripting.Lua.Scheduler.SchedulerRefused' naming every violation,
-- and then starts exactly one worker through 'startSupervised'. The VM is
-- constructed, its bindings installed, its initial chunks run and its modules
-- loaded inside 'withVmOwner' on the worker's own thread. Only then does the body
-- publish readiness, and only then does creation return an endpoint. Readiness is
-- awaited through 'awaitSupervised' composed with the worker's terminal outcome,
-- never through the startup acknowledgement, so a failure of initialization ends
-- creation under the owner's 'WorkerPolicy'. A creator whose wait fails or is abandoned
-- asks the owner to stop and leaves nothing behind: creation returns or raises only once
-- the worker it started has ended (its raw completion, which supervision's latch of
-- another worker's failure does not shorten), however many times the wait is interrupted
-- meanwhile, and then raises what happened in order, a cancellation as itself and the
-- rest as evidence beside it. A script held in a module's top level keeps creation
-- pending, as a held segment keeps the worker (D-27).
--
-- = Identity
--
-- An owner has the 'OwnerId' its 'LuaRuntime' issues, from the one counter the
-- finite-call owners use, so no two owners of a runtime share one and none is
-- reissued. A task is named by a 'ScheduledTaskId': the owner's identity and the
-- owner's number for the task, which it issues from a counter that never rewinds.
-- It is unique within the runtime and never reissued, not after the task settles
-- and is observed and not after its owner retires. It is never an OS thread, a
-- @ThreadId@ or a coroutine. Neither it nor the application's optional name for
-- the task grants authority. The model's two execution domains limit neither the
-- number of owners nor of tasks: the model's identity is scoped by the owner's
-- identity, and this wraps it.
--
-- = Admitting tasks
--
-- 'admitScheduledTask' admits a task with a module entry point, bounded
-- arguments, a service class, a kind and an optional name. It never blocks, from
-- any thread, a binding's action included, and answers 'TaskAccepted' with the
-- task's identity and its ticket, 'TaskQueueFull' or 'TaskAdmissionClosed'. The arguments are
-- evaluated, checked against the owner's value limits and copied on the producer's
-- thread, as a finite call's are; arguments over the limits are accepted and the
-- task settles as the refusal the argument check raises, running nothing. Queued
-- admissions, active tasks and settled-but-unobserved results are each bounded, by
-- the scheduler's bounds, and a task's result is reserved when it is admitted.
--
-- = Settlement
--
-- Every accepted task settles exactly once, as a 'ScheduledOutcome':
--
-- * 'SettledReturned', with the entry point's 'CallResult';
-- * 'SettledFaulted', a fault of the task returned as data: a refused value, a script
--   error (a memory failure included), a call to a binding that is not yet
--   supported, a missing entry point or a module the owner did not load, in a
--   segment of any number. The owner goes on serving its other tasks and this is
--   never a worker failure;
-- * 'SettledRefused', when the scheduler refused what a segment asked for (a wait for
--   no ticks, or one it cannot represent), a recoverable failure of that task;
-- * 'SettledCancelled', when a stop request cancelled it;
-- * 'SettledDiscarded', when the owner exited before the task settled, recording how
--   the owner exited and whether the task had begun.
--
-- No path settles a task twice, loses an accepted task or lets a late outcome
-- overwrite a settlement, including admission, control and stop racing each other.
--
-- = Observing results
--
-- Reading and waiting work as for the finite-call tickets. 'pollTask' reads a
-- settlement without blocking, and reading it is observing it: the first read that
-- finds the task finished takes its result and gives its reservation back, and
-- every later read, on any thread, answers the same settlement and gives nothing
-- back. 'forgetTask' withdraws interest: a finished task gives its reservation
-- back at once, an unfinished one when the owner next sweeps after it finishes, and
-- the ticket still reads its settlement. A ticket nobody observes or forgets keeps
-- its reservation, which is what bounds the unobserved results; the engine keeps no
-- other history of terminal results. 'waitTask' and 'awaitTask' block, the latter
-- composed with 'awaitSupervised'.
--
-- = Waiting from a callback
--
-- A thread that is running any Lua callback may submit and request but may not
-- wait: it would be a synchronous call into a thread that may be waiting for it. So
-- 'startScheduledOwner', 'waitTask', 'awaitTask', 'waitControl', 'awaitControl' and
-- 'awaitTicksComplete' and 'awaitScheduledAccounting' are each refused at once, when they execute, with
-- 'CallbackWaitRefused', and an action built earlier outside the callback is
-- refused the same way. A task waits by yielding to its owner's scheduler, never
-- by blocking its owner's thread.
--
-- = Time and control
--
-- 'grantScheduledStep' grants a logical step, 'requestTaskControl' requests that a
-- task pause, resume or stop, and 'awaitTicksComplete' is the supervised wait for
-- tick completion (scheduler progress), and 'awaitScheduledAccounting' the one for the
-- owner's accounting of what that work caused. The scheduler's module says what each
-- means. A script waits by
-- calling a wait operation the application registered ('waitOperation'): its first
-- argument, an integer, is the number of ticks of a 'WaitLogical' wait or the
-- nanoseconds of a 'WaitElapsed' one; anything else is read as none and refused as
-- a wait for nothing, so the operation's schema should require one integer.
--
-- A resumed coroutine receives no value, so what the wait that ended earned (the
-- tick reached and the logical duration granted since it began, or the time
-- elapsed) is told to the application, on the owner's thread, before the segment
-- that follows it ('scheduledObserve'). A binding that should answer a script's
-- question about its tick keeps what it was told there where it reads it.
--
-- = Idle
--
-- An owner whose tasks are all paused, or waiting for an ungranted tick or a future
-- deadline, enters no Lua and does no periodic work. It blocks in one STM wait
-- until one of: a stop request, an admission, a control request, a grant, or its
-- timer's deadline. A stop request wakes it whatever its tasks are waiting for.
--
-- = Lending a collection
--
-- An owner the application gave a 'Lending' handle ('scheduledLending') holds a
-- resource collection that is owned by a capability and not by a thread, on its
-- own thread around the VM's lifetime, and lends it to each synchronous callback of
-- its VM for exactly the callback's duration, so a binding's action can acquire,
-- borrow and retire members on the owner's behalf even though it runs on a thread
-- of its own. The bindings reach it through the handle they were built over.
-- "Hetoimasia.Scripting.Lua.Lending" says what a binding asks for, and when and
-- from where the loan is refused: after the callback has
-- returned, from a thread it started, from another VM's callback. The collection
-- holds at most 'scheduledMemberLimit' members. It stays open while the VM closes,
-- so a coroutine's closing handlers and a finalizer-eligible binding still find
-- it, and it closes after the VM, on the owner's thread, releasing what remains
-- newest first.
--
-- = Leases
--
-- An owner that hosts instances and lends a collection may also be given a
-- 'Hetoimasia.Scripting.Lua.Lease.Leases' ('scheduledLeases'): each instance then has a scope
-- of engine-held leases on the resources the application's bindings acquire for it,
-- built on that collection, released when the instance ends and awaited until the
-- providers have retired what they were handed. The handle must be made over the
-- handle the owner lends through, and the collection must be able to hold every live
-- instance at the handle's capacity; a configuration that does not fit is refused before
-- anything starts ('Hetoimasia.Scripting.Lua.Lease.LeasesRefused'). The owner stays live
-- while a provider's retirement is pending. See "Hetoimasia.Scripting.Lua.Lease".
--
-- = Host failures
--
-- A Haskell failure raised by a binding's action, or by the application's liveness
-- check or observer, or any other exception escaping the owner, ends that owner's
-- worker as it does a finite-call owner's: it is the worker's primary outcome with
-- its own type and context, unconverted, and what follows is the owner's
-- 'WorkerPolicy'. A failure is a host failure by where it was raised, not by its
-- type. The VM's close failures and the failures of closing suspended coroutines
-- are retained beside it as cleanup evidence, and a retained cleanup failure is
-- fatal under any policy.
--
-- = Stop and exit
--
-- Stopping the owner ('retireScheduled', 'stopSupervised', or the boundary
-- closing) closes admission, grants and control at once. The owner lets a running
-- segment return (nothing is preempted, and a stuck segment keeps the worker, the
-- VM and the binding dependencies live), settles every ticket, cancels its timer,
-- discards the admissions that had not begun, and closes every suspended coroutine
-- on its own thread, attempting each whatever another does, keeping their failures
-- as cleanup evidence. The VM is then closed, and then the owner's collection
-- releases the members still live, a release that fails being cleanup evidence
-- as well, fatal under any policy. The same retirement runs
-- when the owner fails or is cancelled, with the way it exited recorded. The
-- 'ExitRecord' names the owner and counts the tasks it discarded, started and not
-- started separately; it is the finite-call adapter's record, and it carries no
-- cleanup evidence, which supervision does.
--
-- = Determinism
--
-- On one owner with a fixed policy and configuration, the same admitted tasks,
-- grants and control requests, each made at the same logical point (while the owner
-- awaits the next grant), give the same sequence of segments, the same logical
-- durations to each task and the same order of effects recorded through a binding,
-- however long the segments take, whenever timers fire, and whether budgets expire.
-- That is the scheduler's documented ordering, and nothing in this module can
-- change it. It holds for logical-time workloads: elapsed waits legitimately change
-- readiness, and arbitrary elapsed-time workloads are not promised the same trace.
-- A control request that arrives in the middle of a step is not ordered logically
-- here; deterministic logical admission of controls is the script-instance layer's.
module Hetoimasia.Scripting.Lua.Scheduled
  ( -- * Creating owners
    ScheduledSpec (..)
  , scheduledSpec
  , defaultMemberLimit
  , ScheduledStart (..)
  , startScheduledOwner

    -- * An owner
  , ScheduledOwner
  , scheduledIdentity
  , scheduledEndpoint
  , scheduledSupervised
  , retireScheduled
  , cancelScheduled
  , scheduledStatus
  , scheduledExitRecord

    -- * Admitting tasks
  , ScheduledEndpoint
  , scheduledEndpointOwner
  , scheduledEndpointLabel
  , TaskRequest (..)
  , TaskAdmission (..)
  , admitScheduledTask
  , ScheduledTaskId (..)

    -- * Observing results
  , ScheduledTicket
  , ticketTask
  , pollTask
  , waitTask
  , awaitTask
  , forgetTask
  , ScheduledSettlement (..)
  , ScheduledOutcome (..)

    -- * Control
  , TaskControlAnswer (..)
  , ControlReceipt
  , requestTaskControl
  , pollControl
  , waitControl
  , awaitControl
  , forgetControl

    -- * Time
  , grantScheduledStep
  , TickWait (..)
  , awaitTicksComplete
  , AccountingWait (..)
  , awaitScheduledAccounting
  , scheduledTick
  , ticksOutstanding

    -- * What the application is told
  , SegmentContext (..)
  , scheduledDiagnostics

    -- * From the scheduler
  , Policy (..)
  , fifoPolicy
  , SchedulerBounds (..)
  , ServiceClass (..)
  , Quanta (..)
  , Quantum (..)
  , TaskKind (..)
  , ControlRequest (..)
  , ControlResult (..)
  , ControlSettlement (..)
  , CloseReport (..)
  , GrantAnswer (..)
  , GrantId (..)
  , Resume (..)
  , Diagnostics (..)
  , Overrun (..)
  , SchedulerRefused (..)
  , ExecutionDomain (..)

    -- * Refused waits
  , CallbackWaitRefused (..)
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', newTVar, newTVarIO, orElse, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (ExceptionWithContext, SomeException, evaluate, finally, mask, mask_, rethrowIO, tryWithContext)
import Control.Monad (forM, forM_, join, unless, when)
import Data.Foldable (toList, traverse_)
import Data.Maybe (isJust)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Resource (allocResource)
import Hetoimasia.Foundation.Resource.OwnedCollection (OwnedCollectionError (OwnedInvalidMemberLimit))
import Hetoimasia.Foundation.Time (Duration, MonotonicSource, monotonicSource)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Foundation.Worker (stopRequested, workerDefinition)
import Hetoimasia.Runtime.Supervision
  ( RuntimeControl
  , SupervisedStart (WorkerStartRejected, WorkerStartUnavailable, WorkerStarted)
  , SupervisedWorker
  , WorkerPolicy
  , WorkerStatus (WorkerLive, WorkerUnavailable)
  , awaitSupervised
  , cancelSupervised
  , startSupervised
  , stopSupervised
  , workerStatus
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( BehaviorId (BehaviorId)
  , ExecutionDomain (..)
  , ModId (ModId)
  , Owner (Owner)
  , SessionId (SessionId)
  , SessionKey (SessionKey)
  , firstEpoch
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (Quanta (..), Quantum (..), ServiceClass (..))
import Hetoimasia.Scripting.Lua.Internal.Value (checkLimits)
import Hetoimasia.Scripting.Lua.Instance.Driver (connectNamespace, driverNamespaceName, driverSource)
import Hetoimasia.Scripting.Lua.Instance.Run (gateOf)
import Hetoimasia.Scripting.Lua.Instance.State (isInstanceTask)
import Hetoimasia.Scripting.Lua.Lifecycle (LifecycleGrant, LifecycleRefused (LifecycleRefused), lifecycleContextOf, newLifecycleState, resolveGrant)
import Hetoimasia.Scripting.Lua.Instance.Types
  ( InstanceBounds (boundLiveInstances)
  , InstanceConfig (instanceBounds, instanceEscalate, instanceSources)
  , InstanceViolation (RegistrationRefused)
  , Instances (insRunning)
  , InstancesRefused (InstancesRefused)
  , newInstances
  , validateInstanceConfig
  )
import Hetoimasia.Scripting.Lua.Owner (ModuleRef (moduleRefName), VmConfig (vmLifecycle, vmModules, vmOwnerName, vmPolicy, vmRegistration, vmRequests, vmValueLimits))
import Hetoimasia.Scripting.Lua.Registration (registration, registrationCapabilityTypes, registrationNamespaces)
import Hetoimasia.Scripting.Lua.Runtime.Shared
import Hetoimasia.Scripting.Lua.Runtime.Types
  ( CallbackWaitRefused (..)
  , ExitKind (ExitFailed)
  , ExitRecord
  , OwnerId
  , Payload (OverBound, WithinBounds)
  , ownerSequence
  )
import Hetoimasia.Scripting.Lua.Lease.State (LeasesRefused (LeasesRefused), LeasesViolation (..), Leases (leasesCapacity, leasesLending), bindLeasesHandle)
import Hetoimasia.Scripting.Lua.Provider.State (newProviderState, validateGrant, validateSubscriptions)
import Hetoimasia.Scripting.Lua.Provider.Types (EventEndpoint (..), RequestGrant, RequestGrantRefused (RequestGrantRefused), SubscriptionGrant (grantEvents), SubscriptionGrantRefused (SubscriptionGrantRefused), Ticks (..))
import Hetoimasia.Scripting.Lua.Provider.Call (RequestHandles, RequestHandlesRefused (RequestHandlesRefused), bindRequestHandles)
import Hetoimasia.Scripting.Lua.Request (requestContextOf)
import Hetoimasia.Scripting.Lua.Lending.Loan (Lending, bindLending, sameLending)
import Hetoimasia.Scripting.Lua.Scheduled.Run (runScheduledOwner)
import Hetoimasia.Scripting.Lua.Scheduled.Shared (awaitWorkerEnded, propagateAll)
import Hetoimasia.Scripting.Lua.Scheduled.Types
import Hetoimasia.Scripting.Lua.Scheduler
  ( AdmitAnswer (Admitted, AdmitRefused)
  , AdmitRefusal (AdmitClosed, AdmitFull)
  , CloseReport (..)
  , ControlAnswer (ControlAccepted, ControlClosed, ControlFull, ControlUnknownTarget)
  , ControlRequest (..)
  , ControlResult (..)
  , ControlSettlement (..)
  , ControlTicket (ControlTicket)
  , Diagnostics (..)
  , GrantAnswer (..)
  , GrantId (..)
  , Overrun (..)
  , Policy (..)
  , Resume (..)
  , Scheduler
  , SchedulerBounds (..)
  , SchedulerConfig (..)
  , SchedulerRefused (..)
  , TaskKind (..)
  , TaskPhase (PhaseEnded)
  , TaskSpec (..)
  , TimerBackend
  , admitTask
  , awaitStepsComplete
  , fifoPolicy
  , grantStep
  , holdTick
  , newScheduler
  , readDiagnostics
  , readTick
  , releaseTick
  , requestControl
  , requestWaiting
  , schedulerClosed
  , stepsOutstanding
  , systemTimerBackend
  , taskPhase
  , wakeRequestWaiters
  , wakeRequestWaitersOrdered
  , watchTick
  )

-- | What one scheduled owner is created from.
data ScheduledSpec = ScheduledSpec
  { scheduledVm ∷ VmConfig
    -- ^ The host configuration: libraries, initial chunks, label, registration,
    -- policy, value limits and modules. The owner grants nothing beyond its policy.
  , scheduledWorker ∷ WorkerPolicy
    -- ^ What supervision does when the owner's worker ends.
  , scheduledDomain ∷ ExecutionDomain
    -- ^ The domain the model's identities are scoped to.
  , scheduledPolicy ∷ Policy
    -- ^ The scheduling policy, fixed for the owner's life.
  , scheduledBounds ∷ SchedulerBounds
    -- ^ The scheduler's validated limits.
  , scheduledClock ∷ MonotonicSource
    -- ^ The one clock: TIME-1's.
  , scheduledTimer ∷ TimerBackend
    -- ^ What sleeps.
  , scheduledObserve ∷ SegmentContext → IO ()
    -- ^ Told, on the owner's thread, what each segment is about to be handed. An
    -- exception it raises is a failure of the host.
  , scheduledInstances ∷ Maybe InstanceConfig
    -- ^ Script instances, when the owner hosts any: their bounds, the event
    -- sources it offers and the application's decision about an instance's
    -- failure. 'Nothing' for an owner that serves tasks only, which loads no driver
    -- and installs no binding for them.
  , scheduledLending ∷ Maybe Lending
    -- ^ The handle the owner lends its collection through, if the application's
    -- bindings use one. A handle serves one owner. Without it the owner holds no
    -- collection. See "Hetoimasia.Scripting.Lua.Lending".
  , scheduledLeases ∷ Maybe Leases
    -- ^ The handle the owner's instances hold their leases through, if the
    -- application's bindings use one: it must be made over the handle the owner lends
    -- through, and the owner must host instances. A handle serves one owner. See
    -- "Hetoimasia.Scripting.Lua.Lease".
  , scheduledMemberLimit ∷ Int
    -- ^ The most members the owner's collection holds live at once. At least one:
    -- a lower limit is refused when the owner is created.
  , scheduledLifecycle ∷ Maybe LifecycleGrant
    -- ^ The lifecycle control and inspection the owner's scripts are granted, naming the
    -- owners they cover and what each permits. 'Nothing', the default, leaves every
    -- lifecycle operation refused as not yet supported. See
    -- "Hetoimasia.Scripting.Lua.Lifecycle".
  , scheduledRequests ∷ Maybe RequestGrant
    -- ^ The asynchronous requests the owner's scripts may make of providers, and when their
    -- settlements reach Lua. 'Nothing', the default, leaves every asynchronous request, and a
    -- wait for one, refused as not yet supported. See "Hetoimasia.Scripting.Lua.Provider".
  , scheduledRequestHandles ∷ Maybe RequestHandles
    -- ^ The registry the owner answers the liveness of its opt-in requests' handles through, if
    -- the application's bindings use one ("Hetoimasia.Scripting.Lua.Admission"): made before the
    -- owner, closed over by the handle type the registration declares, and taken by the owner
    -- when it is created. The owner must be granted a request service. A registry serves one
    -- owner. 'Nothing', the default, leaves every opt-in handle dead.
  , scheduledSubscriptions ∷ Maybe SubscriptionGrant
    -- ^ The provider events the owner's instances may subscribe functions to (LUA-26), made over
    -- the request service: the owner must be granted one, and host instances. 'Nothing', the
    -- default, leaves @api.subscribe@ refused as not yet supported. See
    -- "Hetoimasia.Scripting.Lua.Provider".
  }

-- | A configuration with the supplied defaults: the FIFO policy, the production
-- clock and timer, the gameplay domain, nothing observing segments, no lending
-- handle, room for 'defaultMemberLimit' members when there is one, no
-- lifecycle grant and no request service.
scheduledSpec ∷ VmConfig → WorkerPolicy → SchedulerBounds → ScheduledSpec
scheduledSpec config worker bounds =
  ScheduledSpec
    { scheduledVm = config
    , scheduledWorker = worker
    , scheduledDomain = GameplayDomain
    , scheduledPolicy = fifoPolicy
    , scheduledBounds = bounds
    , scheduledClock = monotonicSource
    , scheduledTimer = systemTimerBackend
    , scheduledObserve = \_ → pure ()
    , scheduledInstances = Nothing
    , scheduledLending = Nothing
    , scheduledLeases = Nothing
    , scheduledMemberLimit = defaultMemberLimit
    , scheduledLifecycle = Nothing
    , scheduledRequests = Nothing
    , scheduledRequestHandles = Nothing
    , scheduledSubscriptions = Nothing
    }

-- | How many live members an owner's collection holds by default.
defaultMemberLimit ∷ Int
defaultMemberLimit = 256

-- | How creating a scheduled owner ended.
data ScheduledStart
  = -- | Ready, admitting, and usable from now on.
    ScheduledStarted !ScheduledOwner
  | -- | An optional owner failed with a recognized failure before it could be
    -- handed out. Its status is committed, and the run continues without it.
    ScheduledUnavailable !(ExceptionWithContext SomeException)
  | -- | The boundary had closed registration. Nothing was forked.
    ScheduledRejected
  | -- | The owner ended without failing before creation could hand it out.
    ScheduledEnded

-- | A ready, supervised scheduled owner.
data ScheduledOwner = ScheduledOwner
  { ownerWorker ∷ !(SupervisedWorker ())
  , ownerControl ∷ !Control
  }

instance Show ScheduledOwner where
  show owner = "scheduled " <> show (scheduledIdentity owner)

-- | Create one scheduled owner: one supervised worker running one VM.
--
-- Raises 'SchedulerRefused', before anything starts, for a configuration the
-- scheduler refuses, 'OwnedInvalidMemberLimit' for a collection limit below one,
-- and 'CallbackWaitRefused' from a thread running a Lua callback. A failure of initialization, a cancellation of the creator and another
-- worker's fatal outcome propagate as supervision decides. See 'ScheduledStart' for
-- the other endings.
startScheduledOwner ∷ HasCallStack ⇒ LuaRuntime → ScheduledSpec → IO ScheduledStart
startScheduledOwner runtime spec = do
  refuseCallbackWait "start-scheduled-owner"
  when (scheduledMemberLimit spec < 1) $
    throwFailure runtimeComponent (operation "start-scheduled-owner") [] (OwnedInvalidMemberLimit (scheduledMemberLimit spec))
  owner ← issueOwnerId runtime
  tokenStop ← newTVarIO (pure False)
  closing ← newTVarIO False
  let base = scheduledVm spec
      label = vmOwnerName base
      stopping = (||) <$> join (readTVar tokenStop) <*> readTVar closing
      scope = SessionKey (Owner (ModId label) (scheduledDomain spec)) (SessionId (ownerSequence owner)) firstEpoch
  -- The owner's instances, when it hosts any: refused before anything starts if the
  -- configuration does not fit the scheduler's own bounds, and given the driver, the
  -- binding its @api@ reaches the owner through and a namespace to install it in.
  -- A subscription grant is made over the request service and the instances, and is refused,
  -- naming every reason, before anything starts.
  subscriptions ← forM (scheduledSubscriptions spec) $ \grant →
    case validateSubscriptions (isJust (scheduledRequests spec)) (isJust (scheduledInstances spec)) (maybe 0 (length . instanceSources) (scheduledInstances spec)) grant of
      Right endpoints → pure (grant, endpoints)
      Left refused → throwFailure runtimeComponent (operation "start-scheduled-owner") [] (SubscriptionGrantRefused refused)
  hosted ← forM (scheduledInstances spec) $ \instanceConfig → do
    let bounds = scheduledBounds spec
        violations = validateInstanceConfig (boundRetainedResults bounds) (boundQueuedAdmissions bounds) instanceConfig
    forM_ (NonEmpty.nonEmpty violations) $ \refused →
      throwFailure runtimeComponent (operation "start-scheduled-owner") [] (InstancesRefused refused)
    instances ← newInstances instanceConfig
    let registered = vmRegistration base
    merged ←
      case registration (registrationCapabilityTypes registered) (registrationNamespaces registered <> [connectNamespace instances]) of
        Right whole → pure whole
        Left refusal →
          throwFailure runtimeComponent (operation "start-scheduled-owner") [] . InstancesRefused $
            RegistrationRefused (Text.pack (show refusal)) NonEmpty.:| []
    pure (instances, instanceConfig, merged)
  let config = case hosted of
        Nothing → base
        Just (_, instanceConfig, merged) →
          base
            { vmRegistration = merged
            , vmPolicy = vmPolicy base <> [driverNamespaceName]
            , vmModules = vmModules base <> [driverSource (instanceSources instanceConfig) [(eventName endpoint, eventPayload endpoint) | (grant, _) ← toList subscriptions, endpoint ← grantEvents grant]]
            }
  scheduler ←
    newScheduler
      SchedulerConfig
        { schedLabel = label
        , schedScope = scope
        , schedPolicy = scheduledPolicy spec
        , schedBounds = scheduledBounds spec
        , schedClock = scheduledClock spec
        , schedTimer = scheduledTimer spec
        , schedStopRequested = stopping
        }
      >>= either (throwFailure runtimeComponent (operation "start-scheduled-owner") []) pure
  -- The leases are refused, before anything starts, for a configuration they cannot
  -- be used with: an owner that hosts no instances, or lends no collection, or lends
  -- another one, or whose collection cannot hold every instance at its capacity.
  forM_ (scheduledLeases spec) $ \leases → do
    let live = maybe 0 (\(_, instanceConfig, _) → boundLiveInstances (instanceBounds instanceConfig)) hosted
        violations =
          [LeasesNeedInstances | null hosted]
            <> [LeasesNeedLending | null (scheduledLending spec)]
            <> [LeasesLendingMismatch | Just lending ← [scheduledLending spec], not (sameLending lending (leasesLending leases))]
            <> [LeasesMembersTooFew (scheduledMemberLimit spec) (live * leasesCapacity leases) | scheduledMemberLimit spec < live * leasesCapacity leases]
    forM_ (NonEmpty.nonEmpty violations) $ \refused →
      throwFailure runtimeComponent (operation "start-scheduled-owner") [] (LeasesRefused refused)
  -- The owner's control, without its lifecycle services: what the owner's own gate reads
  -- is the scheduler and whether it is stopping, which it already has.
  let ownInstances = fmap (\(instances, _, _) → instances) hosted
  cells ← newTVarIO Map.empty
  faults ← newTVarIO Map.empty
  begun ← newTVarIO mempty
  exited ← newTVarIO Nothing
  -- A request service is granted against the endpoints it names before anything starts, and
  -- refused naming every reason.
  provider ← forM (scheduledRequests spec) $ \grant →
    case validateGrant (vmValueLimits config) grant of
      Right endpoints → newProviderState owner label scope (vmValueLimits config) grant endpoints subscriptions (ticksFor scheduler stopping) ownInstances (scheduledLeases spec)
      Left refused → throwFailure runtimeComponent (operation "start-scheduled-owner") [] (RequestGrantRefused refused)
  -- The registry that answers whether a handle is live is taken once the service exists, and
  -- refused, before anything starts, if there is none or another owner has it.
  forM_ (scheduledRequestHandles spec) $ \handles → case provider of
    Nothing → throwFailure runtimeComponent (operation "start-scheduled-owner") [] (RequestHandlesRefused "the owner is granted no request service")
    Just service → do
      taken ← bindRequestHandles handles service
      unless taken (throwFailure runtimeComponent (operation "start-scheduled-owner") [] (RequestHandlesRefused "the registry already serves an owner"))
  hooks ← newTVarIO Map.empty
  accounting ← newTVarIO newAccounting
  let bare = Control owner label (vmValueLimits config) scheduler cells faults begun closing exited stopping ownInstances Nothing provider hooks accounting
  -- A lifecycle grant is resolved against the owners it names before anything starts, and
  -- refused naming every reason.
  lifecycle ← forM (scheduledLifecycle spec) $ \grant →
    case resolveGrant owner label ((\instances → (instances, gateOf bare)) <$> ownInstances) grant of
      Right targets → newLifecycleState owner label (vmValueLimits config) ownInstances targets grant
      Left refused → throwFailure runtimeComponent (operation "start-scheduled-owner") [] (LifecycleRefused refused)
  -- The handle is taken once the configuration is known to be acceptable and
  -- before anything starts.
  traverse_ bindLending (scheduledLending spec)
  forM_ ((,) <$> scheduledLeases spec <*> hosted) $ \(leases, (instances, _, _)) →
    bindLeasesHandle leases (readTVarIO (insRunning instances))
  let control = bare {controlLifecycle = lifecycle}
  handoff ← newTVarIO Nothing
  let definition =
        workerDefinition
          ("lua scheduled owner " <> label <> " #" <> Text.pack (show (ownerSequence owner)))
          ( \token →
              allocResource
                (atomically (writeTVar tokenStop (stopRequested token)) >> pure control)
                -- The last word on what an exit left, after the run action:
                -- everything that already ended the owner has done this.
                (\held → atomically (settleAll held ExitFailed))
          )
          (\_ held → runScheduledOwner stopping held handoff (scheduledObserve spec) (fmap (\(_, instanceConfig, _) → instanceEscalate instanceConfig) hosted) (scheduledLending spec) (scheduledLeases spec) (scheduledMemberLimit spec) config {vmLifecycle = lifecycleContextOf <$> lifecycle, vmRequests = requestContextOf <$> provider})
  -- Acquisition is masked from the worker's start to the endpoint's handoff, and
  -- only the readiness wait is restored, exactly as for a finite-call owner.
  mask $ \restore → do
    started ← startSupervised (runtimeControl runtime) (scheduledWorker spec) definition
    case started of
      WorkerStartRejected → pure ScheduledRejected
      WorkerStartUnavailable _ failure → pure (ScheduledUnavailable failure)
      WorkerStarted worker → do
        waited ← tryWithContext @SomeException (restore (awaitSupervised (runtimeControl runtime) (readiness handoff worker)))
        -- A wait that failed or was abandoned leaves nothing behind: the worker is asked to stop and
        -- waited for until it has ended, whatever interrupts that wait, as the retirement of an owner is,
        -- before the failure that abandoned the wait propagates. A creator cannot be handed back an
        -- exception while the worker it started still runs Lua, with what it was created over.
        ready ← case waited of
          Right found → pure found
          Left failure → do
            stopSupervised worker
            interruptions ← awaitWorkerEnded restore worker
            propagateAll (failure : interruptions)
            rethrowIO failure
        case ready of
          Just held → do
            live ← atomically (admitting held)
            if live then pure (ScheduledStarted (ScheduledOwner worker held)) else ended worker
          Nothing → ended worker
  where
    ended worker =
      atomically (workerStatus worker) >>= \case
        WorkerUnavailable failure → pure (ScheduledUnavailable failure)
        _ → pure ScheduledEnded

-- | What a request service needs of the owner's scheduler, and nothing more: the tick, the
-- hold a request puts on its due tick, the owner's watch on it, whether producers are admitted,
-- whether a task is gone, and waking the tasks that wait for a request.
ticksFor ∷ Scheduler Cursor → STM Bool → Ticks
ticksFor scheduler stopping =
  Ticks
    { ticksNow = readTick scheduler
    , ticksHold = holdTick scheduler
    , ticksRelease = releaseTick scheduler
    , ticksWatch = watchTick scheduler
    , ticksOpen = do
        closed ← schedulerClosed scheduler
        asked ← stopping
        pure (not closed && not asked)
    , ticksTaskGone = \task →
        taskPhase scheduler task <&> \case
          Nothing → True
          Just (PhaseEnded _) → True
          Just _ → False
    , ticksWaiting = requestWaiting scheduler
    , ticksWakeSettled = wakeRequestWaiters scheduler
    , ticksWakeOrdered = wakeRequestWaitersOrdered scheduler
    }
  where
    (<&>) = flip fmap

-- | The owner's identity.
scheduledIdentity ∷ ScheduledOwner → OwnerId
scheduledIdentity = controlOwner . ownerControl

-- | Where tasks are admitted, grants made and control requested.
scheduledEndpoint ∷ ScheduledOwner → ScheduledEndpoint
scheduledEndpoint = ScheduledEndpoint . ownerControl

-- | The supervised worker, for what supervision offers.
scheduledSupervised ∷ ScheduledOwner → SupervisedWorker ()
scheduledSupervised = ownerWorker

-- | Retire the owner: ask its worker to stop, recording that its owner asked. It
-- returns at once; see the module header for what the worker then does.
retireScheduled ∷ ScheduledOwner → IO ()
retireScheduled = stopSupervised . ownerWorker

-- | Request the owner's cancellation, recording that its owner asked.
cancelScheduled ∷ ScheduledOwner → IO ()
cancelScheduled = cancelSupervised . ownerWorker

-- | What supervision has decided about the owner's worker.
scheduledStatus ∷ ScheduledOwner → STM WorkerStatus
scheduledStatus = workerStatus . ownerWorker

-- | What the owner's exit discarded: 'Nothing' until it has exited.
scheduledExitRecord ∷ ScheduledOwner → STM (Maybe ExitRecord)
scheduledExitRecord = readTVar . controlExit . ownerControl

-- | Whether the owner admits: it is ready and nothing has asked it to stop.
admitting ∷ Control → STM Bool
admitting control = not <$> schedulerClosed (controlScheduler control)

-- | The identity of the owner an endpoint belongs to.
scheduledEndpointOwner ∷ ScheduledEndpoint → OwnerId
scheduledEndpointOwner (ScheduledEndpoint control) = controlOwner control

-- | The application's label of the owner an endpoint belongs to.
scheduledEndpointLabel ∷ ScheduledEndpoint → Text
scheduledEndpointLabel (ScheduledEndpoint control) = controlLabel control

-- | What admitting a task answered.
data TaskAdmission
  = -- | Accepted, with the task's identity and the ticket its settlement is read
    -- through.
    TaskAccepted !ScheduledTaskId !ScheduledTicket
  | -- | A bound is reached: the queue of admissions or the stored results. Nothing
    -- changed.
    TaskQueueFull
  | -- | The owner has stopped admitting. Nothing changed.
    TaskAdmissionClosed
  deriving (Show)

-- | Admit a task, without waiting, from any thread.
--
-- The arguments are evaluated completely and checked against the owner's value
-- limits on this thread, and what is kept is copied. An exception nested in a lazy
-- argument is raised here, with its own type and context.
admitScheduledTask ∷ ScheduledEndpoint → TaskRequest → IO TaskAdmission
admitScheduledTask (ScheduledEndpoint control) request = do
  within ← evaluate (checkLimits (controlLimits control) (requestArguments request))
  let payload = case within of
        Right () → WithinBounds (map compact (requestArguments request))
        Left rule → OverBound rule
  prepared ← prepare (Pending (compactRef (requestModule request)) (compactName (requestEntry request)) payload)
  cursor ← evaluate (preparedValue prepared)
  let entry = compactName (requestEntry request)
      wanted =
        TaskSpec
          { specBehavior = BehaviorId (Text.copy (moduleRefName (compactRef (requestModule request)) <> "/" <> entry))
          , specEntry = entry
          , specName = requestName request
          , specClass = requestClass request
          , specKind = requestKind request
          , specCursor = cursor
          }
  -- Nothing is interruptible between the commit and the answer, so an accepted
  -- task is never one whose ticket was never made.
  mask_ . atomically $
    admitTask (controlScheduler control) wanted >>= \case
      Admitted identity → do
        outcome ← newTVar Nothing
        forgotten ← newTVar False
        let cell = Cell identity outcome forgotten
        modifyTVar' (controlCells control) (Map.insert identity cell)
        pure (TaskAccepted (ScheduledTaskId (controlOwner control) identity) (ScheduledTicket control cell))
      AdmitRefused (AdmitFull _ _) → pure TaskQueueFull
      AdmitRefused AdmitClosed → pure TaskAdmissionClosed

-- | The place an accepted task's settlement is read.
data ScheduledTicket = ScheduledTicket !Control !Cell

instance Show ScheduledTicket where
  show (ScheduledTicket control cell) = "scheduled task ticket of " <> show (controlOwner control) <> " " <> show (cellTask cell)

-- | The task a ticket belongs to.
ticketTask ∷ ScheduledTicket → ScheduledTaskId
ticketTask (ScheduledTicket control cell) = ScheduledTaskId (controlOwner control) (cellTask cell)

-- | The task's settlement if it has one, without waiting. Observes it.
pollTask ∷ ScheduledTicket → IO (Maybe ScheduledSettlement)
pollTask (ScheduledTicket control cell) = atomically (observeCell control cell)

-- | Wait for the task's settlement, on any thread but a Lua callback's.
--
-- Every accepted task settles, so this returns once the task has finished or the
-- owner has exited. Refused with 'CallbackWaitRefused' from a Lua callback.
waitTask ∷ HasCallStack ⇒ ScheduledTicket → IO ScheduledSettlement
waitTask (ScheduledTicket control cell) = do
  refuseCallbackWait "wait-task"
  atomically (observeCell control cell >>= maybe retry pure)

-- | Wait for the task's settlement on the application thread, composed with
-- 'awaitSupervised': a worker's terminal outcome is handled first, so a fatal one
-- is raised here rather than waited out. Refused with 'CallbackWaitRefused' from a
-- Lua callback.
awaitTask ∷ HasCallStack ⇒ RuntimeControl → ScheduledTicket → IO ScheduledSettlement
awaitTask supervision (ScheduledTicket control cell) = do
  refuseCallbackWait "await-task"
  awaitSupervised supervision (observeCell control cell >>= maybe retry pure)

-- | Withdraw interest in a task's result. See the module header.
forgetTask ∷ ScheduledTicket → IO ()
forgetTask (ScheduledTicket control cell) = atomically (forgetCell control cell)

-- | What requesting control of a task answered.
data TaskControlAnswer
  = -- | Taken. Its settlement is read through the receipt.
    TaskControlAccepted !ControlReceipt
  | -- | Every result reservation is held. Nothing changed.
    TaskControlFull
  | TaskControlClosed
  | -- | No live task of this owner has this identity.
    TaskControlUnknown
  deriving (Show)

-- | The place an accepted control request's settlement is read.
newtype ControlReceipt = ControlReceipt ControlTicket

instance Show ControlReceipt where
  show _ = "<control receipt>"

-- | Request that a task pause, resume or stop. Never blocks, from any thread; the
-- scheduler's module says how it is applied. An identity another owner issued is
-- unknown here.
requestTaskControl ∷ ScheduledEndpoint → ScheduledTaskId → ControlRequest → IO TaskControlAnswer
requestTaskControl (ScheduledEndpoint control) task request
  | taskOwner task /= controlOwner control = pure TaskControlUnknown
  | otherwise =
      atomically (guarded (requestControl (controlScheduler control) (taskLocal task) request)) <&> \case
        ControlAccepted ticket → TaskControlAccepted (ControlReceipt ticket)
        ControlFull → TaskControlFull
        ControlClosed → TaskControlClosed
        ControlUnknownTarget → TaskControlUnknown
  where
    (<&>) = flip fmap
    -- A script instance's invocation is the instance layer's, whatever a hook or an
    -- observer told the application of its identity: a task of this kind is unknown here.
    guarded asked = case controlInstances control of
      Nothing → asked
      Just instances → isInstanceTask instances (taskLocal task) >>= \case
        True → pure ControlUnknownTarget
        False → asked

-- | The settlement if there is one, without waiting. Observes it.
pollControl ∷ ControlReceipt → IO (Maybe ControlSettlement)
pollControl (ControlReceipt (ControlTicket poll _ _)) = atomically poll

-- | Wait for the settlement, on any thread but a Lua callback's. Refused with
-- 'CallbackWaitRefused' from a Lua callback.
waitControl ∷ HasCallStack ⇒ ControlReceipt → IO ControlSettlement
waitControl (ControlReceipt (ControlTicket _ await _)) = do
  refuseCallbackWait "wait-control"
  atomically await

-- | Wait for the settlement on the application thread, composed with
-- 'awaitSupervised'. Refused with 'CallbackWaitRefused' from a Lua callback.
awaitControl ∷ HasCallStack ⇒ RuntimeControl → ControlReceipt → IO ControlSettlement
awaitControl supervision (ControlReceipt (ControlTicket _ await _)) = do
  refuseCallbackWait "await-control"
  awaitSupervised supervision await

-- | Withdraw interest in the settlement.
forgetControl ∷ ControlReceipt → IO ()
forgetControl (ControlReceipt (ControlTicket _ _ forget)) = atomically forget

-- | Grant a logical step. Never blocks, from any thread.
grantScheduledStep ∷ ScheduledEndpoint → Duration → IO GrantAnswer
grantScheduledStep (ScheduledEndpoint control) duration = atomically (grantStep (controlScheduler control) duration)

-- | How a wait for tick completion ended.
data TickWait
  = -- | Every accepted grant has been applied, and every task it woke has stopped
    -- being ready or running: by waiting again, completing, failing (a wait the
    -- scheduler refused included), being paused or being stopped. That is the
    -- scheduler's progress, and it is all this promises. It does not promise that
    -- the owner has accounted for an instance ending the work caused: the instance's
    -- @shutdown@, the drain of what it held, a retirement a provider still owes, its
    -- settlement and the application's escalation may all still lie ahead on the
    -- owner's thread. 'awaitScheduledAccounting' waits for those.
    TicksCompleted
  | -- | The owner exited first. The ticks outstanding did not complete: they were
    -- discarded with the owner.
    TickOwnerEnded
  deriving (Eq, Show)

-- | Wait, on the application thread and composed with 'awaitSupervised', until
-- every accepted grant has completed, or the owner has exited.
--
-- A grant completes when every task it woke has stopped being ready or running,
-- which is scheduler progress and not the owner's accounting of the instance endings
-- that work caused; see 'TicksCompleted' and 'awaitScheduledAccounting'.
--
-- An owner that stops or fails with a tick outstanding ends the wait with
-- 'TickOwnerEnded' and never with a false completion. Refused with
-- 'CallbackWaitRefused' from a Lua callback.
awaitTicksComplete ∷ HasCallStack ⇒ RuntimeControl → ScheduledOwner → IO TickWait
awaitTicksComplete supervision owner = do
  refuseCallbackWait "await-ticks-complete"
  awaitSupervised supervision $ do
    closed ← schedulerClosed (controlScheduler (ownerControl owner))
    if closed
      then pure TickOwnerEnded
      else
        (awaitStepsComplete (controlScheduler (ownerControl owner)) >> pure TicksCompleted)
          `orElse` ( workerStatus (ownerWorker owner) >>= \case
                       WorkerLive → retry
                       _ → pure TickOwnerEnded
                   )

-- | How a wait for the owner's accounting ended.
data AccountingWait
  = -- | The owner has accounted for every grant the wait captured and for every
    -- instance ending it covers: see 'awaitScheduledAccounting'.
    AccountingComplete
  | -- | The owner exited, was stopped, cancelled or failed first, and supervision
    -- handled that without latching a fatal failure. Nothing was accounted for: this is
    -- never a completion. A fatal failure is not an answer: the wait rethrows it.
    AccountingOwnerEnded
  deriving (Eq, Show)

-- | Wait, on the application thread and composed with 'awaitSupervised', until the
-- owner has accounted for every grant accepted so far, and for the instance endings
-- that work caused, and so the application can decide a tick's commit, or a stop's
-- outcome, on complete evidence.
--
-- = What it waits for
--
-- The wait captures the grants accepted when it begins: one committed snapshot of the
-- owner's grant accounting, taken once and kept across retries of the wait and across
-- supervision's handling of outcomes, never taken again. A grant is in it if
-- 'grantScheduledStep' had committed its acceptance before that snapshot. It returns
-- 'AccountingComplete' only when all of these hold, each a condition of its own:
--
-- 1. every captured grant has been applied and has finished, as for 'TicksCompleted';
-- 2. the owner has ended the boundary at which the last of them was found finished,
--    which includes the closes it ran there and the instance layer's accounting of the
--    invocations that ended; and
-- 3. every instance ending begun by the end of that boundary, whatever began it (a failed
--    hook, a refused wait, a faulted invocation, a delivery failure, a stop, a one-shot
--    completing, an instance stopping itself, and a grant accepted after the snapshot
--    that was applied in that same boundary), has run its @shutdown@ or had it skipped,
--    released and drained what it held, completed every retirement a provider owes it
--    (including one that completes later), settled and, if it failed, had the
--    application's escalation called and /returned/.
--
-- With no grant outstanding, or none ever accepted, the wait covers the endings already
-- begun, and needs nothing further from the application to return: the owner is woken
-- to account for them. It also works for an owner that hosts no instances.
--
-- It does not wait for grants accepted after the snapshot to be applied or finished, for
-- any boundary after the captured grants' final one, for healthy instances' future ticks,
-- for idle peers, or for an ordinary task's fault, which stays a ticket result the
-- application consumes.
--
-- = What can delay it
--
-- The owner has one thread and nothing is preempted, so later work can still delay an
-- earlier wait: a later grant entering a blocking callback while an earlier ending is
-- parked awaiting retirement holds the thread the ending needs to settle. A retirement a
-- provider owes holds the wait for as long as it holds the instance's stop completion;
-- there is no timeout. The wait completes on an acknowledgement
-- the owner's thread writes after the wait's cut was fixed, as the last step of an iteration of its
-- loop that has kept every failure it caught, found nothing it holds, and swept what the providers
-- and the leases have yet to hand it; an iteration cut short by a failure writes none. A wait begun
-- while the owner is in the middle of a batch (the disposals a retirement owes, the providers being
-- told) therefore waits for the end of that iteration, and cannot complete between a failure being
-- caught and being kept. Returning is evidence about the owner's accounting. It is not
-- permission to advance or to commit a tick that failed.
--
-- = Who may call it
--
-- It is a supervised wait like 'awaitTicksComplete' and every other: called on the
-- application thread that owns the 'RuntimeControl', so one is pending at a time. Pending
-- worker outcomes are handled first, and a latched fatal failure is rethrown by the wait
-- and wins over a ready completion. It must not be called from the owner's own thread
-- (an escalation callback, a segment observer): it would wait for its own return. Refused
-- with 'CallbackWaitRefused' from a Lua callback.
--
-- = What it costs the owner
--
-- It takes no task, control or result slot and creates no ticket; it works with every
-- one of those bounds exhausted, and the owner keeps a constant amount of state for it
-- whatever number of waits were made. Cancelling a pending wait (an asynchronous
-- exception on the application thread, while it is blocked or while supervision handles
-- an outcome) abandons only that wait and leaves nothing behind for a later wait, the
-- owner's bounds, its diagnostics or its progress to observe. A wait changes nothing the
-- owner does.
--
-- = When the owner ends
--
-- An owner that exits, is stopped, cancelled or fails before the wait is called or while
-- it is pending ends the wait with 'AccountingOwnerEnded' once it has ended and
-- supervision has handled the outcome without latching a fatal failure, and never with
-- 'AccountingComplete' unless the accounting was complete before the owner began to exit.
-- An owner that is exiting but has not ended (a stop waiting for a provider's retirement,
-- say) neither completes the wait nor ends it: the wait is for the exit. Nor does an owner
-- that holds cleanup evidence that will end it as a failure (the failure of closing a
-- coroutine, of a release, of a settlement), even one whose every ending is accounted for: the
-- wait is for the exit and the failure supervision then handles. An @Escalate@
-- answer, an escalation callback that raises and a failed retirement end the owner as a
-- failure, and the wait follows the severity supervision gives that outcome: a fatal one
-- is rethrown, and a tolerated one ends the wait.
awaitScheduledAccounting ∷ HasCallStack ⇒ RuntimeControl → ScheduledOwner → IO AccountingWait
awaitScheduledAccounting supervision owner = do
  refuseCallbackWait "await-scheduled-accounting"
  let control = ownerControl owner
  -- The snapshot is committed once, before the supervised wait, so a retry of the wait
  -- or the handling of an outcome inside it cannot move it. The watch is cleared however
  -- the wait ends, in the cleanup of the same masked region that registered it.
  mask $ \restore → do
    atomically (watchAccounting control)
    restore (awaitSupervised supervision (accounted control))
      `finally` atomically (unwatchAccounting control)
  where
    -- Only the owner's termination ends the wait with 'AccountingOwnerEnded', and supervision
    -- handles an owner's outcome, a fatal one rethrown, before this transaction runs: so an owner
    -- that is exiting (stopped, or failing with an outcome not yet published) neither completes
    -- the wait nor ends it. It waits for the exit. Completion is the owner's acknowledgement,
    -- written by the owner's thread after it has kept every failure it caught: the wait decides
    -- nothing about failures in flight.
    accounted control = do
      status ← workerStatus (ownerWorker owner)
      case status of
        WorkerLive → do
          exiting ← (||) <$> schedulerClosed (controlScheduler control) <*> controlStopping control
          if exiting
            then retry
            else accountingReady control >> pure AccountingComplete
        _ → pure AccountingOwnerEnded

-- | The logical tick reached.
scheduledTick ∷ ScheduledEndpoint → STM Word64
scheduledTick (ScheduledEndpoint control) = readTick (controlScheduler control)

-- | How many accepted grants have not completed.
ticksOutstanding ∷ ScheduledEndpoint → STM Int
ticksOutstanding (ScheduledEndpoint control) = stepsOutstanding (controlScheduler control)

-- | A snapshot of the scheduler's bounded counters and gauges. Borrows nothing
-- from a Lua state.
scheduledDiagnostics ∷ ScheduledEndpoint → STM Diagnostics
scheduledDiagnostics (ScheduledEndpoint control) = readDiagnostics (controlScheduler control)
