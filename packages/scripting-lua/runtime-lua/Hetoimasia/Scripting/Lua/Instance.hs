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
-- * @update(self, dt)@ runs when a periodic instance's interval makes one due (see
--   "Cadence" below), handed @dt@ as a float number of seconds. An instance
--   admitted without an interval never has one. It may wait and yield, as @run@ and the
--   callbacks may.
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
-- ('boundInvocationQueue'), in which an accepted event waits for its turn and which a
-- due update shares: the update keeps its place among the events, and is never counted
-- in the bound. A full queue refuses the new delivery, counts it ('snapshotQueueFull')
-- and never evicts an accepted one. Terminal results are retained elsewhere and never
-- use it.
--
-- A callback is handed its instance's @self@ and the event, a table with the fields
-- @source@, @sequence@, @tick@ and @payload@.
--
-- = Provider events (subscriptions)
--
-- An owner granted subscriptions ('Hetoimasia.Scripting.Lua.Provider.SubscriptionGrant', over
-- its request service) offers provider event endpoints. An instance subscribes a function to
-- an endpoint it was granted ('instanceGrants' names endpoints beside sources) through
-- @api.subscribe(endpoint, callback)@, which answers a handle, and ends the subscription with
-- @api.unsubscribe(handle)@. The subscription is the instance's, beside its connections: it
-- survives the invocation that made it and every callback after it, and every way the instance
-- ends revokes it, with the provider told once and the instance's stop completing only when
-- the provider has proved its retirement.
--
-- A provider delivers from any thread, through the feed it was handed, without blocking and
-- without entering Lua. A delivery takes a place in the instance's queue, with the sequence
-- admission gave it and the logical tick it was admitted at, and the owner looks up the live
-- callback when it services it; the callback is handed the same record a connection's is, with
-- the endpoint as @source@ and the subscription's number as @subscription@. A delivery to a
-- subscription that has ended is refused and counted, and never run. Overload is stated per
-- endpoint: ordered events are refused when the queue has no place and never evicted, and
-- replaceable state keeps one unstarted delivery per subscription, replaced in place (keeping
-- its place in the queue) by a later value until the callback's first segment begins, after
-- which the value is the callback's and immutable.
--
-- On an owner driven by logical time, the application assigns each delivery the tick whose
-- boundary admits it and its place among the deliveries due then; the owner admits them at
-- that boundary, after the controls and before any task the tick woke, in the order of the
-- places and never in arrival order, and the grant that reached the tick waits until what was
-- admitted has begun or cannot. Owners on elapsed time admit on arrival.
--
-- = Cadence
--
-- An instance is admitted with no periodic interval ('EventOnly', 'RunOnce'), or as
-- @'Periodic' interval@, which reacts to events as an event-only instance does and has
-- its module's @update@ called on the interval. The interval is chosen at admission
-- and fixed for the instance's life, and neither kind of interval belongs to the UI or
-- to gameplay: either can run on any scheduled owner. A periodic instance whose module
-- defines no @update@ is refused before any hook runs, as a one-shot whose module
-- defines no @run@ is.
--
-- An 'Interval' is 'LogicalTicks' (a positive number of ticks of the owner's logical
-- time), 'LogicalDuration' (converted to ticks only when it is an exact multiple of the
-- owner's configured tick duration, 'instanceTickDuration', and refused otherwise) or
-- 'ElapsedEvery' (a positive duration on the owner's monotonic source). An interval
-- that does not convert, is zero or negative or is not a tick count is refused at
-- admission, naming it ('InstanceIntervalRefused'); nothing is rounded.
--
-- __Logical.__ A cadence point is every interval ticks from the tick at which @init@
-- succeeded, on a fixed phase. The point is looked at when its grant is applied, before
-- any task that grant woke runs: it makes an update due only if it finds the instance
-- serving (not paused, stopping or ended) with no invocation active. An invocation is
-- active from the segment that begins it until it finishes, including while it is
-- suspended on a wait, and whatever it is (@update@, @run@ or an event callback); an
-- invocation admitted and not yet begun is still queued, and the update falls due
-- behind it. A point that finds an invocation active adds nothing at all: there is no
-- catch-up and no backlog, the grant that resumes a waiting invocation included, and the
-- next update is due at the first point after the invocation finishes. An instance
-- never has more than one unstarted update.
--
-- The update's @dt@ is the logical duration granted since the previous update
-- finished (since @init@ succeeded, for the first), less any granted while the instance
-- was intentionally paused, from grants alone (D-35). Ticks that pass while an invocation
-- is active and the instance is not paused still count, so every tick granted while the
-- instance is live is accounted to it once. It is the sum of the durations actually
-- granted, unequal grants included, never a count of ticks times the tick duration. It
-- reaches Lua as a float number of seconds: the exact 'Duration' is converted once at the
-- boundary, which is the only rounding, and a representable duration never fails for
-- the size of its count of nanoseconds. It
-- is fixed as the update begins and is unchanged by its own waits, by later grants and by
-- real delays. What an invocation's wait was granted is told to the application on
-- the owner's thread ('Hetoimasia.Scripting.Lua.Scheduled.scheduledObserve'); a resumed
-- coroutine receives no value, so a script learns it only through a binding the
-- application grants. That duration overlaps the next update's @dt@ and is no further
-- credit: every granted tick is accounted for in a @dt@ once, and in the observation of
-- the wait it fell in.
--
-- __What a tick waits for.__ A tick does not complete until a due update has run in it,
-- but only while the update can still run in it. Its hold on the tick is let go when the
-- instance is paused or the update is discarded by a stop or an ending before it starts,
-- when an invocation queued ahead of it begins and suspends on a wait, when it has begun
-- and stopped being ready or running, and when nothing at all is ready to run. Real delay
-- slows the simulation and never skips a due update; only the instance's own logical
-- waits make a point a no-op.
--
-- __Elapsed.__ The interval is measured on the owner's monotonic source, behind the
-- owner's one timer (no timer, thread or polling per instance). At most one refresh is
-- kept unstarted; demand that finds one is coalesced into it, and queued events are
-- never dropped. Unlike a logical point, an elapsed point queues its refresh behind an
-- active invocation. Its @dt@ is the elapsed time between update starts, measured from
-- the instant @init@ succeeded. Lateness moves the next deadline to the first point on
-- the cadence strictly in the future: no burst of catch-up refreshes follows a stall.
--
-- __Pause and resume.__ A paused instance accrues no periodic demand, logical or
-- elapsed: its timer demand is cancelled, and a point that finds it paused adds nothing.
-- An update already due or admitted and not begun is retained, in its place in the
-- queue, and holds no tick. After a resume the first update newly due is one full
-- interval later: that many ticks after the tick the resume was applied at, or that much
-- time after the instant it was. An elapsed instance's baseline is rebased to that
-- instant, and a logical instance accrues nothing toward its @dt@ from the grants
-- applied while it is paused, so either @dt@ excludes the pause.
--
-- __Queue.__ A due update takes its place in the instance's one queue when it falls
-- due: behind the events accepted before it, ahead of those accepted after it, so a
-- continuous producer cannot starve it. It never competes with events for the queue's
-- bound, so it is never refused as full.
--
-- __Ending.__ Every end of an instance cancels its timer demand, discards its unstarted
-- update, counted with the other unstarted invocations, and lets go of any tick it held.
--
-- __Arithmetic.__ Accrued durations, ticks and deadlines are checked: one that is not
-- representable fails the instance ('ErrorCadence', at 'StageUpdate'), without wrapping,
-- and leaves no demand and no tick held.
--
-- = M1 behavior instances (opt-in)
--
-- Beside the instances above, which run the hooks a /global-entry/ module defines and are
-- unchanged, an owner that hosts instances admits /behavior instances/ with
-- 'admitBehaviorInstance': an instance of a behavior in the export table an export module
-- returned ("Hetoimasia.Scripting.Lua.Owner", @vmExports@), held by the VM as real Lua
-- values. The request ('BehaviorRequest') names the export module by its identity, the
-- field of its table that holds the behavior, the facade the instance is injected with,
-- and the application's rule for the behavior's cadence.
--
-- The owner's thread does the rest when it starts the instance, before any hook: it finds
-- the export module, validates the selected behavior against the fixed schema by raw access
-- and captures it (the very @init@, @update@ and @shutdown@ functions, a fresh @self@
-- holding the facade as @self.api@, and the facade), resolves the cadence by applying the
-- rule to what the table read as, and only then runs @init(self, api)@, where @api@ is the
-- facade. A behavior without an @update@ hook has no cadence and stays alive until it is
-- stopped; one with an @update@ hook is periodic on the interval the rule resolved, through
-- the same cadence machinery as any periodic instance, and its @update(self, dt_seconds)@
-- is handed the @dt@ of that machinery unchanged. @shutdown(self, reason)@ is the same
-- strings and skip rules as above.
--
-- Everything the instance runs is what it captured: replacing or removing a field of the
-- behavior table, replacing the role table in the export table or editing a cadence field
-- afterwards changes nothing it does, and a later instance reads the table as it is then.
-- Mutable upvalues and shared exports stay ordinary Lua; @self@ and the facade are its own.
-- The hooks run through a driver of the owner's, not through a lookup by name, and the
-- legacy instance driver's @api@ (@connect@, @subscribe@ and @unsubscribe@) is not handed to
-- a behavior and is no part of this surface.
--
-- A failure before @init@ (no such export module; a module whose evaluation or return
-- failed, stickily; a behavior that does not fit the schema; a cadence the rule refuses or
-- that does not resolve; a facade past the owner's value limits) fails the instance at
-- 'StageConstruct' with 'ErrorExportMissing', 'ErrorExportFailed', 'ErrorBehavior',
-- 'ErrorCadence' or 'ErrorFault', which an @init@ failure ('StageInit') is distinct from: no
-- hook ran, @shutdown@ is skipped as for any instance whose @init@ never succeeded, and what
-- was captured is released. What the instance captured is released whichever way it ends,
-- with the rest of what it holds; a coroutine still running or suspended on it keeps it in
-- Lua until it is closed, which an ending does first.
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
-- A lifecycle-operation binding a script calls answers a typed @NotYetSupported@
-- fault from an owner that was granted nothing, and its action never runs. An owner
-- that was granted lifecycle services ('Hetoimasia.Scripting.Lua.Lifecycle') gives its
-- scripts these same controls, and inspection, over the owners the grant covers,
-- through the same requests, receipts and settlements described here.
--
-- = Logical admission of controls
--
-- 'requestInstanceControl' admits a request on arrival, in the order accepted, whatever
-- the owner is configured with, and is unchanged. An owner configured with
-- 'AdmitLogically' ('instanceControlAdmission') also admits requests that carry a
-- 'ControlSlot' the application assigned: 'requestInstanceControlAt', and the requests a
-- script makes through a grant that assigns places. Each is applied at the logical
-- boundary of its tick, in the order of (tick, sequence), before that tick's ordinary
-- work and cadence point, whatever order the requests arrived in. One assigned a tick
-- the owner has begun is refused as late ('InstanceControlLate'), and one assigned a
-- place another request holds as a duplicate ('InstanceControlDuplicate'); neither is
-- ever applied at a later boundary. Admission reads the tick and enqueues in one
-- transaction, so a request accepted for a tick is queued before that tick is visible, and it
-- asks the scheduler to hold the grant that reaches the tick: that grant is not finished, and no
-- later one is applied, until the owner has applied the tick's controls, so grants queued
-- together act as grants served one by one, and the cadence points the tick reached are still
-- the scheduler's while the controls are applied. A request waiting for its tick holds its
-- reservation, and settles as no longer applicable if its instance ends first or the owner
-- exits first; its place stays taken until the tick begins, and the places queued are bounded
-- as the reservations are.
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
-- = Leases
--
-- An owner that is given 'Hetoimasia.Scripting.Lua.Lease.Leases' ('scheduledLeases')
-- gives each instance a scope before its first hook, and the bindings the application
-- writes acquire resources through it for the instance that is running
-- ("Hetoimasia.Scripting.Lua.Lease", LUA-22). What the instance still holds when it ends,
-- on any of the paths above, is released on the owner's thread after its @shutdown@ has
-- run or been skipped, newest acquisition first, whatever the script did or did not do
-- with the handles it was given. A release that fails does not stop the others, is kept
-- beside the instance's primary failure ('failureSecondary', stage 'StageRelease') and
-- is cleanup evidence on the owner's outcome: fatal under any policy, whatever the
-- application's escalation answers.
--
-- What a provider has yet to retire after that holds the instance's /stop completion/: the
-- instance's end has run its hook and released its holdings and is parked, 'Stopping', and
-- it settles once every retirement the provider was asked for has completed. The owner
-- stays live until then, through a stop and through a cancellation. A settlement says what
-- the end did with the leases ('resultLeases').
--
-- = Idle
--
-- Everything an instance's owner does is a response to something: an admission, an
-- event, a request, a grant, a deadline or a stop. A cadence point is a response to a
-- grant or to a deadline, and a cadence arms no thread, timer or poll of its own. The owner's wait is the one STM
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
-- readiness, and so do elapsed-interval updates. The order of logical updates among an
-- instance's other invocations, and the @dt@ each receives, are among what is the same. An
-- event or a request admitted on arrival that arrives in the middle of a step is not ordered
-- logically. Controls admitted logically are: the same tick-assigned requests give the same
-- sequence of controls, and so of effects, in whatever order they arrive and from whichever
-- VM sent them.
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
  , Interval (..)
  , IntervalRefusal (..)
  , Cadence (..)
  , resolveInterval
  , InstanceRequest (..)
  , BehaviorRequest (..)
  , BehaviorFacade (..)
  , InstanceAdmission (..)
  , InstanceId (..)
  , admitInstance
  , admitBehaviorInstance

    -- * Events
  , Delivery (..)
  , deliverEvent

    -- * Control
  , InstanceControl (..)
  , InstanceControlAnswer (..)
  , InstanceControlReceipt
  , requestInstanceControl
  , requestInstanceControlAt
  , ControlAdmission (..)
  , ControlSlot (..)
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
  , releaseHeldInstance
  , InstanceSettlement (..)
  , LeaseOutcome (..)
  , InstanceOutcome (..)
  , Termination (..)
  , ShutdownDisposition (..)
  , InstanceFailure (..)
  , InstanceError (..)
  , HookStage (..)

    -- * What a module defines
  , ModuleHooks (..)
  , moduleHooks

    -- * Inspection
  , InstanceSnapshot (..)
  , InstancePhase (..)
  , isTerminal
  , Execution (..)
  , inspectInstance
  , inspectInstances
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar, retry)
import Control.Exception (evaluate)
import qualified Data.ByteString as ByteString
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
import Hetoimasia.Scripting.Lua.Provider.Types (ProviderState (psEvents))
import Hetoimasia.Scripting.Lua.Owner (ExportIdentity (ExportIdentity), ModuleRef (ModuleRef))
import Hetoimasia.Scripting.Lua.Scheduled.Types (Control (controlHooks, controlInstances, controlLabel, controlLimits, controlOwner, controlProvider), ScheduledEndpoint (ScheduledEndpoint))
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
    -- strings of a task are; the grants are only the owner's own sources and the provider event
    -- endpoints it offers, once each.
    kept ← evaluate (compacted instances)
    atomically (State.admitInstance instances (gateOf control) (controlOwner control) kept)
  where
    offered grant = maybe False (Map.member grant . psEvents) (controlProvider control)
    compacted instances =
      request
        { instanceModule = compactRef (instanceModule request)
        , instanceName = compactName <$> instanceName request
        , instanceGrants = nub [grant | grant ← map compactName (instanceGrants request), Map.member grant (insSources instances) || offered grant]
        }

-- | Admit an M1 behavior instance, without waiting, from any thread.
--
-- The instance takes a live place and a result reservation as any other does, and
-- the owner's thread then finds the export module the request names, selects,
-- validates and captures the behavior, resolves its cadence and runs its hooks, as
-- the module header's M1 section describes. A behavior that fails any of that settles
-- the instance as failed at 'StageConstruct', with no hook run and nothing held.
-- Answers 'InstanceAdmissionClosed' for an owner that does not host instances.
admitBehaviorInstance ∷ ScheduledEndpoint → BehaviorRequest → IO InstanceAdmission
admitBehaviorInstance (ScheduledEndpoint control) request = case controlInstances control of
  Nothing → pure InstanceAdmissionClosed
  Just instances → do
    kept ← evaluate compacted
    atomically (State.admitBehavior instances (gateOf control) (controlOwner control) (compactRef (ModuleRef (Text.take 64 (behaviorLabel kept)) "export")) kept)
  where
    compacted =
      request
        { behaviorExport = ownedIdentity (behaviorExport request)
        , behaviorLabel = compactName (behaviorLabel request)
        , behaviorSelect = Text.copy (behaviorSelect request)
        , behaviorName = compactName <$> behaviorName request
        }

-- | An identity in a buffer of its own: the request keeps it until the instance settles.
ownedIdentity ∷ ExportIdentity → ExportIdentity
ownedIdentity (ExportIdentity bytes) = ExportIdentity (ByteString.copy bytes)

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

-- | Request that an instance pause, resume or stop at a place in the owner's logical input
-- sequence. Never blocks, from any thread.
--
-- The owner must admit controls logically ('AdmitLogically'): the request is applied at
-- the logical boundary of its tick, before that tick's other work, in the order of
-- (tick, sequence). Answers 'InstanceControlLate' for a tick the owner has begun,
-- 'InstanceControlDuplicate' for a place another request holds, and
-- 'InstanceControlNotLogical' for an owner that admits on arrival.
requestInstanceControlAt ∷ ScheduledEndpoint → InstanceId → InstanceControl → ControlSlot → IO InstanceControlAnswer
requestInstanceControlAt (ScheduledEndpoint control) identity request slot = case controlInstances control of
  Nothing → pure InstanceControlUnknown
  Just instances → atomically (State.requestInstanceControlAt instances (gateOf control) (controlOwner control) identity request slot)

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

-- | Release an instance that 'instanceHoldInit' held after its construction: its @init@ begins on the
-- owner's thread, in its turn among the owner's jobs. The release is recorded and its one job queued in a single
-- transaction, so any number of releases, from any threads, queue one job between them. An instance that was not
-- held, was released already or has ended takes nothing from it. Answers whether this call is the one that
-- released the instance.
releaseHeldInstance ∷ InstanceTicket → IO Bool
releaseHeldInstance = atomically . State.releaseHeld

-- | Withdraw interest in an instance's result. An ended instance gives its
-- reservation back now, a live one when it ends.
forgetInstance ∷ InstanceTicket → IO ()
forgetInstance = atomically . State.forgetInstance

-- | Which of the optional hooks (@init@, @update@, @shutdown@ and @run@) a module the owner
-- loaded defines; 'Nothing' for a module it did not load. An entry that is present and is not
-- a function counts as defined, as the instance's own check counts it.
--
-- The owner read it from the module, running none of the module's code, before it was ready:
-- the answer is available from the moment creation returns the owner, and it does not change for
-- the owner's life. It is how an application chooses an instance's kind from what its module
-- defines ('InstanceKind') without admitting an instance to find out.
moduleHooks ∷ ScheduledEndpoint → ModuleRef → STM (Maybe ModuleHooks)
moduleHooks (ScheduledEndpoint control) ref = Map.lookup ref <$> readTVar (controlHooks control)

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
