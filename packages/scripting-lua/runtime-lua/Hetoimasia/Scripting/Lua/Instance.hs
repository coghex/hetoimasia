-- | Script instances on scheduled Lua owners.
--
-- This is LUA-18. An /instance/ is one running copy of a module's behavior on a
-- scheduled owner's VM ("Hetoimasia.Scripting.Lua.Scheduled"): it has its own
-- @self@, hooks the module defines, functions it connects to events, and a
-- lifecycle the application controls and reads. Several instances of one module are
-- independent, and ending one removes neither the module, nor the VM, nor another
-- instance. The behavior is the accepted instance contract's
-- (@docs/lua_instance_contract.md@, D-26 and D-27).
--
-- An owner hosts instances when it is created with a 'scheduledInstances'
-- configuration ('InstanceConfig'); one without serves tasks as before and loads
-- nothing of this. The modules that host instances declare the hooks they define as
-- optional entry points ('hookEntries').
--
-- = Instances
--
-- 'admitInstance' admits an instance from a module the owner loaded and answers at
-- once, from any thread, without blocking: 'InstanceAccepted' with the instance's
-- identity and a ticket, 'InstanceFull' or 'InstanceAdmissionClosed'. An instance's
-- identity is an 'InstanceId', its TID: the owner's identity and the owner's number
-- for it, unique within the runtime and never reissued, neither after the instance
-- ends and its result is observed, nor after its owner retires. It is never an OS
-- thread, a @ThreadId@ or a coroutine, and it, like the application's name for the
-- instance, grants nothing. The live instances, and the results of the ended ones
-- that nobody has observed, are each bounded ('InstanceBounds'), and a result is
-- reserved when the instance is admitted.
--
-- The owner's thread makes the instance's @self@, a fresh empty table, before its
-- @init@ runs. The module's code is shared by its instances; a fresh @self@ does not
-- isolate mutable module globals or upvalues, and a script that shares them shares
-- them. The instance's phase ('InstancePhase') is 'Initializing' until its @init@
-- has returned, then 'Active' or 'Paused', 'Stopping' while it ends, and then one of
-- the terminal phases.
--
-- = Hooks
--
-- * @init(self, api)@ runs once, on the owner's thread, as a finite call. An absent
--   @init@ is a successful empty initialization. @api@ carries only what the
--   instance was granted: @api.connect(source, callback)@ connects a function to an
--   event source ('instanceGrants'), and is a script error for any other source.
-- * @update(self, dt)@ is part of the authoring model and is declared, but nothing
--   makes an update due until the periodic cadence (LUA-24) does, so it is never
--   called in this slice.
-- * @run(self, api)@ is a one-shot's body ('RunOnce'). It runs to completion after
--   @init@; a one-shot whose module defines none is refused before any hook runs,
--   and settles as failed, naming @run@.
-- * @shutdown(self, reason)@ runs once, with @\"stopped\"@, @\"completed\"@ or
--   @\"failed\"@, and only if @init@ succeeded and Lua may still be entered (see
--   below). It is optional: a module without one ends like any other.
--
-- @init@ and @shutdown@ are finite and cannot suspend: a wait or a yield inside one
-- is a fault of that hook, reported as any hook's fault is. @run@ and the callbacks
-- may wait and yield, cooperatively, as a task's entry point does.
--
-- = One invocation at a time
--
-- An instance has at most one invocation in flight, including one that is
-- suspended. Its callbacks and its @run@ never reenter it, and another instance may
-- run while it is suspended. An invocation is a task of the owner's scheduler
-- ("Hetoimasia.Scripting.Lua.Scheduler"), so the owner's policy orders the
-- invocations of its instances among each other and among its tasks, by the policy's
-- rules and the instance's service class ('instanceClass'): first in, first out, and
-- yielding to the tail, by default, and no policy overrides lifecycle, capacity or
-- the order an instance's own invocations were accepted in. The next invocation of an
-- instance is admitted at the boundary of the segment that ended the last, so the
-- order depends on the order of admission and on nothing about how long segments
-- take, when timers fire or whether a budget expires.
--
-- = Events
--
-- An owner offers named event sources ('EventSource'), each with the shape of the
-- payload it delivers. In this slice they are a seam for tests: only the
-- application's own threads deliver. An instance connects a function to a source
-- through its @api@, in @init@ or later, and owns the connection.
--
-- 'deliverEvent' delivers a payload to the function an instance connected to a
-- source, and answers at once, from any thread, without blocking:
-- 'DeliveryAccepted' with the sequence admission gave the event, 'DeliveryQueueFull',
-- 'DeliveryClosed', 'DeliveryUnknownTarget' (no live instance of this owner, or none
-- with a connection to that source) or 'DeliveryRefused' (the payload is over the
-- owner's limits or is not what the source declares). The payload is checked and
-- copied on the producer's thread. It is kept, with its sequence and the logical tick
-- it was admitted at, unchanged until its callback runs, however long that takes and
-- whether the instance is paused. No producer thread enters Lua. A connection made
-- during @init@ is recorded when it is made, so events can be accepted while @init@
-- runs; none is dispatched until @init@ has succeeded, and if it fails the connection
-- is revoked and the events are counted among the unstarted invocations discarded.
--
-- Each instance has one bounded first-in, first-out queue of invocations
-- ('boundInvocationQueue'), in which an accepted event waits for its turn. It is
-- built to be shared with the due updates the periodic cadence will add. A full queue
-- refuses the new delivery, counts it ('snapshotQueueFull') and never evicts an
-- accepted one. Terminal results are retained elsewhere and never use it.
--
-- A callback is handed its instance's @self@ and the event, a table with the fields
-- @source@, @sequence@, @tick@ and @payload@.
--
-- = Failure
--
-- A failed @init@ fails that instance. No @update@, @run@, callback or @shutdown@
-- ever runs on it, its connections are revoked, and its record in the VM is
-- released. Its failure ('InstanceFailure') names the instance, its owner, its source
-- module, the phase it was in, the stage, the error and the traceback, if one was
-- captured; the @init@ error is the primary one, and nothing later replaces it.
--
-- An unhandled error in @run@ or a callback fails the instance in the same way,
-- except that @shutdown@ runs, with reason @\"failed\"@: its remaining work is
-- suppressed, and its stop path is the one below. Isolation is the default: the
-- failure ends that instance and the owner's other instances run on. The engine
-- cannot tell whether state the instances share was damaged, so the application is
-- told of each failure on the owner's thread ('instanceEscalate'), after the instance
-- has ended, and decides: 'Isolate', or 'Escalate', which fails the owner as a host
-- failure does ('InstanceEscalated'), under its 'WorkerPolicy'. A host failure, an
-- exception raised by application code, is never an instance's failure: it ends the
-- owner, unconverted, as for tasks.
--
-- Cleanup is the engine's and nothing the application's escalation answers can hide
-- it. A failure of closing a coroutine, including a failure of a closing handler the
-- script defined, is cleanup evidence on the owner's outcome and is fatal under any
-- policy, as for a task.
--
-- = Control
--
-- 'requestInstanceControl' requests that an instance pause, resume or stop, and
-- answers at once, without blocking, from any thread: 'InstanceControlAccepted' with a
-- receipt, 'InstanceControlFull', 'InstanceControlClosed' or 'InstanceControlUnknown'
-- (another owner's identity, an ended or never issued instance). An accepted request
-- holds a reservation for its result, bounded by 'boundInstanceControls', until its
-- settlement is observed or abandoned through the receipt, and settles exactly once,
-- as 'ControlApplied', 'ControlAlreadyInState' or 'ControlNoLongerApplicable',
-- including a request overtaken by the instance's end or by the owner's.
--
-- Requests are applied in the order accepted, at the owner's next safe boundary: its
-- thread services them at each of the scheduler's boundaries, before the first segment
-- of a turn and after every segment, when no task is running, and never inside a
-- segment. Control of the instance whose invocation is running waits for the segment
-- to return or yield. An owner that has been asked to stop services nothing more: its
-- exit settles what was left. A request settles as it is applied, before anything that
-- can raise a failure of the host.
--
-- An invocation that has not run a segment has nothing to freeze or close, even when
-- the scheduler holds it queued behind slots that stay occupied: a pause takes it back,
-- with its event, to be started on resume, and a stop discards it as an unstarted
-- invocation. It holds its place in the instance's queue until it runs.
--
-- * __Pause__ stops new invocations from starting and freezes the invocation in
--   flight, if there is one: it is suspended where it is, and runs nothing, however
--   its wait would have ended. The accepted events stay in the queue, in order.
-- * __Resume__ lets it go on: a suspended invocation finishes before another starts,
--   then the retained events run in the order they were accepted, and new ones behind
--   them. It does not undo a stop.
-- * __Stop__ works while paused and takes precedence over every ordinary invocation.
--   It closes the instance's admission, revokes its connections, discards the
--   invocations that had not begun and counts them, closes the coroutine of the
--   invocation in flight on the owner's thread and never resumes it, and only then runs
--   @shutdown@. Its request result says the stop was taken; its completion is the
--   instance's settlement, which is written after the hook and the release. Repeated
--   requests are safe and never resurrect an instance, and never run @shutdown@ again.
--
-- Whole-owner control ('Hetoimasia.Scripting.Lua.Scheduled.retireScheduled') is a
-- different thing from controlling one instance. An orderly retirement stops each
-- live instance through the path above with reason @\"stopped\"@ before the VM is
-- closed. When the owner instead fails or is cancelled, Lua is not entered for the
-- instances again: no @shutdown@ runs, which the settlement reports
-- ('ShutdownSkippedUnsafe'), and each unended instance settles as discarded; one that
-- had failed already settles as failed, with its first failure, which nothing later
-- replaces, and the disposition its @shutdown@ came to when that was decided.
--
-- A lifecycle-operation binding a script calls still answers a typed
-- @NotYetSupported@ fault: Lua's own controls and inspection are LUA-23.
--
-- = Results and inspection
--
-- Every accepted instance settles exactly once ('InstanceSettlement'): completed,
-- stopped, failed or discarded, with what its end revoked and released
-- ('Termination'): the connections revoked, the unstarted invocations discarded, the
-- invocations that had begun and were closed, and what became of @shutdown@. A
-- failing @shutdown@ is kept and never retried, runtime cleanup still happens, and an
-- instance that would have completed or stopped is failed by it; an existing primary
-- failure stays primary.
--
-- Observing and abandoning work as for tasks: 'pollInstance' reads a settlement
-- without blocking, and reading it observes it, giving its reservation back; a ticket
-- nobody observes or forgets keeps its reservation, which is what bounds the retained
-- results.
--
-- 'inspectInstance' and 'inspectInstances' answer bounded, coherent snapshots
-- ('InstanceSnapshot'), each read in one transaction, of the identity, owner, name,
-- phase and execution detail of an instance, and of the owner's instances. They never
-- borrow a Lua table.
--
-- = Idle
--
-- Everything an instance's owner does is a response to something: an admission, an
-- event, a request, a grant, a deadline or a stop. The owner's wait is the one STM
-- wait of the scheduled owner with the instance layer's jobs added to it. An owner
-- whose instances are all paused, waiting or idle enters no Lua and does no periodic
-- work until one of those arrives.
--
-- = Determinism
--
-- On one owner with a fixed configuration and policy, the same admitted instances, grants, delivered events and
-- control requests, each made at the same logical point (while the owner awaits the next grant), give
-- the same order of invocations and the same order of effects recorded through a
-- binding, however long segments take, whenever timers fire, and whether budgets
-- expire. It holds for logical-time workloads: elapsed waits legitimately change
-- readiness. An event or a request that arrives in the middle of a step is not ordered
-- logically here; deterministic logical admission of controls is LUA-23's.
module Hetoimasia.Scripting.Lua.Instance
  ( -- * Hosting instances
    InstanceConfig (..)
  , defaultInstanceConfig
  , InstanceBounds (..)
  , defaultInstanceBounds
  , EventSource (..)
  , InstancesRefused (..)
  , InstanceViolation (..)
  , hookEntries

    -- * Admitting instances
  , InstanceKind (..)
  , InstanceRequest (..)
  , InstanceAdmission (..)
  , InstanceId (..)
  , admitInstance

    -- * Events
  , Delivery (..)
  , deliverEvent

    -- * Control
  , InstanceControl (..)
  , InstanceControlAnswer (..)
  , InstanceControlReceipt
  , requestInstanceControl
  , pollInstanceControl
  , waitInstanceControl
  , awaitInstanceControl
  , forgetInstanceControl
  , Escalation (..)
  , InstanceEscalated (..)

    -- * Results
  , InstanceTicket
  , ticketInstance
  , pollInstance
  , waitInstance
  , awaitInstance
  , forgetInstance
  , InstanceSettlement (..)
  , InstanceOutcome (..)
  , Termination (..)
  , ShutdownDisposition (..)
  , InstanceFailure (..)
  , InstanceError (..)
  , HookStage (..)

    -- * Inspection
  , InstanceSnapshot (..)
  , InstancePhase (..)
  , isTerminal
  , Execution (..)
  , inspectInstance
  , inspectInstances
  ) where

import Control.Concurrent.STM (STM, atomically, retry)
import Control.Exception (evaluate)
import qualified Data.Map.Strict as Map
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Runtime.Supervision (RuntimeControl, awaitSupervised)
import Hetoimasia.Scripting.Lua.Instance.Driver (hookEntries)
import Hetoimasia.Scripting.Lua.Instance.Run (gateOf)
import qualified Hetoimasia.Scripting.Lua.Instance.State as State
import Hetoimasia.Scripting.Lua.Instance.Types
import Hetoimasia.Scripting.Lua.Internal.Value (Context (..), VmIdentity (VmIdentity), checkLimits, conformValue)
import Hetoimasia.Scripting.Lua.Runtime.Shared (compact, compactName, compactRef, refuseCallbackWait)
import Hetoimasia.Scripting.Lua.Runtime.Types (Payload (WithinBounds))
import Hetoimasia.Scripting.Lua.Scheduled.Types (Control (controlInstances, controlLabel, controlLimits, controlOwner), ScheduledEndpoint (ScheduledEndpoint))
import Hetoimasia.Scripting.Lua.Scheduler (ControlResult)
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VRecord, VText))

-- | Admit an instance, without waiting, from any thread.
--
-- Answers 'InstanceAdmissionClosed' for an owner that does not host instances.
admitInstance ∷ ScheduledEndpoint → InstanceRequest → IO InstanceAdmission
admitInstance (ScheduledEndpoint control) request = case controlInstances control of
  Nothing → pure InstanceAdmissionClosed
  Just instances → do
    -- What the owner keeps is copied to buffers of its own, and cut as the routing
    -- strings of a task are; the grants are only the owner's own sources, once each.
    kept ← evaluate (compacted instances)
    atomically (State.admitInstance instances (gateOf control) (controlOwner control) kept)
  where
    compacted instances =
      request
        { instanceModule = compactRef (instanceModule request)
        , instanceName = compactName <$> instanceName request
        , instanceGrants = nub [grant | grant ← map compactName (instanceGrants request), Map.member grant (insSources instances)]
        }

-- | Deliver an event to the function an instance connected to a source, without
-- waiting, from any thread. The payload is checked against the owner's limits and
-- the source's declaration, evaluated completely and copied on this thread.
deliverEvent ∷ ScheduledEndpoint → InstanceId → Text → Value → IO Delivery
deliverEvent (ScheduledEndpoint control) identity source payload = case controlInstances control of
  Nothing → pure DeliveryUnknownTarget
  Just instances → case Map.lookup source (insSources instances) of
    Nothing → pure DeliveryUnknownTarget
    Just schema → do
      -- The callback is handed the payload inside a record naming the source and
      -- stamping the event, so the limits are checked on that record: a payload that
      -- passes and whose event does not would fail the instance when it ran.
      let stamped = VRecord [("source", VText source), ("sequence", VInteger 0), ("tick", VInteger 0), ("payload", payload)]
      -- The driver's entry point takes the instance's number before it, and the host
      -- checks the two together.
      within ← evaluate (checkLimits (controlLimits control) [VInteger 0, stamped])
      let context = Context {contextVm = foreignVm, contextTypeName = const Nothing, contextTypeNumber = const Nothing}
      -- The shape is checked only once the limits have passed: a payload over them is
      -- refused as it is found to be, and its tail is never walked.
      case within of
        Left _ → pure DeliveryRefused
        Right () → do
          conforming ← evaluate (conformValue context schema payload)
          case conforming of
            Left _ → pure DeliveryRefused
            Right () → do
              prepared ← prepare (WithinBounds [compact payload])
              case preparedValue prepared of
                -- The source is kept in a buffer of its own, as the payload is: a slice of
                -- a larger string would keep all of it alive for as long as the event waits.
                WithinBounds [kept] → atomically (State.deliverEvent instances (gateOf control) (controlOwner control) identity (Text.copy source) kept)
                _ → pure DeliveryRefused
  where
    -- No capability crosses a source (the owner's creation refuses one), so no VM's
    -- identity is ever compared.
    foreignVm ∷ VmIdentity
    foreignVm = VmIdentity 0

-- | Request that an instance pause, resume or stop. Never blocks, from any thread.
requestInstanceControl ∷ ScheduledEndpoint → InstanceId → InstanceControl → IO InstanceControlAnswer
requestInstanceControl (ScheduledEndpoint control) identity request = case controlInstances control of
  Nothing → pure InstanceControlUnknown
  Just instances → atomically (State.requestInstanceControl instances (gateOf control) (controlOwner control) identity request)

-- | The settlement if there is one, without waiting. Observes it.
pollInstanceControl ∷ InstanceControlReceipt → IO (Maybe ControlResult)
pollInstanceControl = atomically . State.observeReceipt

-- | Wait for the settlement, on any thread but a Lua callback's. Refused with
-- 'CallbackWaitRefused' from a Lua callback.
waitInstanceControl ∷ HasCallStack ⇒ InstanceControlReceipt → IO ControlResult
waitInstanceControl receipt = do
  refuseCallbackWait "wait-instance-control"
  atomically (State.observeReceipt receipt >>= maybe retry pure)

-- | Wait for the settlement on the application thread, composed with
-- 'awaitSupervised'.
awaitInstanceControl ∷ HasCallStack ⇒ RuntimeControl → InstanceControlReceipt → IO ControlResult
awaitInstanceControl supervision receipt = do
  refuseCallbackWait "await-instance-control"
  awaitSupervised supervision (State.observeReceipt receipt >>= maybe retry pure)

-- | Withdraw interest in the settlement.
forgetInstanceControl ∷ InstanceControlReceipt → IO ()
forgetInstanceControl = atomically . State.forgetReceipt

-- | The settlement of an instance if it has one, without waiting. Observes it.
pollInstance ∷ InstanceTicket → IO (Maybe InstanceSettlement)
pollInstance = atomically . State.observeInstance

-- | Wait for the instance's settlement, on any thread but a Lua callback's. Every
-- accepted instance settles, so this returns once the instance has ended or its
-- owner has exited. Refused with 'CallbackWaitRefused' from a Lua callback.
waitInstance ∷ HasCallStack ⇒ InstanceTicket → IO InstanceSettlement
waitInstance ticket = do
  refuseCallbackWait "wait-instance"
  atomically (State.observeInstance ticket >>= maybe retry pure)

-- | Wait for the instance's settlement on the application thread, composed with
-- 'awaitSupervised': a worker's terminal outcome is handled first, so a fatal one is
-- raised here rather than waited out.
awaitInstance ∷ HasCallStack ⇒ RuntimeControl → InstanceTicket → IO InstanceSettlement
awaitInstance supervision ticket = do
  refuseCallbackWait "await-instance"
  awaitSupervised supervision (State.observeInstance ticket >>= maybe retry pure)

-- | Withdraw interest in an instance's result. An ended instance gives its
-- reservation back now, a live one when it ends.
forgetInstance ∷ InstanceTicket → IO ()
forgetInstance = atomically . State.forgetInstance

-- | One instance, live or ended and not yet observed, read in one transaction.
inspectInstance ∷ ScheduledEndpoint → InstanceId → STM (Maybe InstanceSnapshot)
inspectInstance (ScheduledEndpoint control) identity = case controlInstances control of
  Nothing → pure Nothing
  Just instances → State.inspectInstance instances (gateOf control) (controlOwner control) (controlLabel control) identity

-- | Every instance of the owner, live or ended and not yet observed, in one
-- transaction, by identity.
inspectInstances ∷ ScheduledEndpoint → STM [InstanceSnapshot]
inspectInstances (ScheduledEndpoint control) = case controlInstances control of
  Nothing → pure []
  Just instances → State.inspectInstances instances (gateOf control) (controlOwner control) (controlLabel control)
