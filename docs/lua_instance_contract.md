# Lua script-instance lifecycle contract

Design contract, 2026-10-17. Owner: `coghex/hetoimasia`.

**Status: draft for the remaining behavioral signoff.** This refines
[the Lua design](lua_runtime_design.md), D-16 through D-25. It describes intended
behavior, not implemented APIs. Approved requirements are distinguished below
from the proposed detailed rules. The whole Lua arc remains `exploring`.

## Approved requirements

- Each instance has an engine-issued TID, owner label, optional name and status.
  Module code can be shared; each instance has its own `self`. Removing an
  instance does not remove other instances, shared modules or the VM.
- Lifecycle authoring uses `init(self, api)`, optional `update(self, dt)`,
  `shutdown(self, reason)` and a separate one-shot `run(self, api)`.
  Instance-owned function connections deliver engine events on the VM owner.
- Pausing suspends updates and callbacks. The owner prefers retaining callbacks
  and delivering them in order after resume. Exact retention/overflow rules are
  the proposal below; silent failure was considered, not selected as a policy.
- Failed initialization fails that instance, runs no subsequent hooks or loop,
  and reports what failed. Other instances should continue when isolation is
  safe. Existing unsafe shared-state/host failure rules still apply.
- Authoritative gameplay is deterministic under the same-build/platform target
  in D-23. UI timing remains independent. Gameplay inputs, lifecycle commands,
  event admission and committed effects have defined logical ordering.
- The owner delegates delivery organization and splitting. Implementation and
  readiness are not claimed by publication of this contract.

## Instance ownership and execution

The VM owner alone creates, mutates and disposes instance state. Other owners
submit bounded requests through explicitly granted services; knowing a TID
does not grant authority. No producer thread enters Lua. Inspection reads
coherent snapshots and never borrows Lua tables.

An instance owns its `self`, continuation, pending invocations, timer demand,
event connections and scoped engine leases. Module globals/upvalues remain
shared where the application deliberately shares them. A VM-local instance
reference cannot be transported to another VM.

Proposed observable lifecycle phases are `Initializing`, `Active`, `Paused`,
`Stopping`, and terminal `Completed`, `Stopped` or `Failed`; execution detail
distinguishes ready/running/waiting within a live phase. The existing protocol's
terminal cancellation maps to stopped inspection status; these names do not
require a second independent state machine. Retained results are bounded.

One instance has at most one active invocation, including a suspended one.
Another instance may run while it yields; its own callbacks and updates never
reenter it. The selected owner policy orders eligible instances within bounded
service classes. FIFO and yield-to-tail are the default. It cannot override
lifecycle, authority, memory or deterministic-effect constraints.

## Proposed initialization and failure rules

1. Reserve instance/result capacity and create fresh `self` before `init`.
2. `init` runs once. An absent optional initializer counts as successful empty
   initialization. Connections created during it cannot dispatch callbacks until
   it succeeds. A missing required `run` entry is refused before starting a
   one-shot; an event-only instance needs no `update`.
3. If `init` fails, mark initialization failed and never call `update`, `run`,
   callbacks or `shutdown` on that instance. Revoke its connections and release
   its runtime-owned holdings. Preserve the initialization error as primary;
   attach cleanup errors instead of replacing it.
4. Emit a bounded diagnostic and inspection result naming TID, owner, source,
   lifecycle phase, error and available traceback. A future UI can display the
   same result; the headless runner prints it. No automatic retry or restart.
5. Ordinary failures whose effects are isolated fail only the instance. Lua
   `pcall` is not rollback: if initialization changed shared authoritative state
   and recovery cannot be established, D-7/P-8 still fail the affected session.
   Fatal host failures retain the existing supervision policy. Scripts that need
   isolated failure must keep initialization effects local or stage them through
   application services with an actual discard/commit contract.

Proposed hook suspension rule: `init` and `shutdown` are finite, non-suspending
hooks. An attempted scheduler wait/yield is a reported hook fault. `update`,
`run` and event callbacks may use explicit cooperative waits/yields. Expensive
startup continues in scheduled work after `init`; asynchronous native cleanup
belongs to the runtime/provider lifetime, not a blocking Lua shutdown hook.
Finite is an author contract, not forced interruption of trusted Lua.

An unhandled error from an ordinary update/run/event invocation also fails that
instance, suppresses its remaining ordinary work and enters the cleanup path.
The same shared-state safety test applies; shutdown is eligible only after
successful initialization and while Lua entry remains safe.

## Proposed pause, event ordering and resume rules

Pause takes effect at the next explicit safe boundary. It freezes the current
continuation and prevents any new ordinary invocation. Resume and stop remain
serviceable. An already-running segment must return or yield first.
An outstanding request may complete while paused, but its reserved result is
retained without resuming Lua; pause does not abandon provider ownership.

Accepted event deliveries remain in a bounded per-instance FIFO, including
while paused. Admission assigns a stable sequence; deterministic gameplay uses
canonical logical admission order, not racing thread arrival order. Replay
means delivering previously unstarted callbacks once, not rerunning completed
callbacks or their effects. Preserve each event's original payload and logical
timestamp; resume does not rewrite it as a newly generated event.

**Overflow proposal:** reject the new delivery with an explicit queue-full
result and an attributable, bounded diagnostic/counter; do not evict an accepted
delivery, silently succeed, or grow without limit. Retained terminal failure
storage does not consume the event FIFO. Producers never block a native callback
waiting for capacity. If a provider cannot retry/preserve an authoritative event,
it must surface a delivery failure to the owning application policy; the affected
simulation cannot continue as though delivery succeeded. No generic automatic
retry or unbounded secondary queue is implied. Gameplay admission/overflow
decisions must be tied to logical boundaries so wall-time service speed alone
does not decide which inputs are accepted.

On resume, finish any previously suspended invocation before starting another.
Then process retained events in admission order under ordinary service quotas;
new events join behind them. Events and due updates share an ordered invocation
queue, so a continuous producer cannot indefinitely jump ahead of an already
due update. The application defines gameplay tick/phase/sequence ordering for
simultaneous external events and due updates. The UI owner uses its local
admission ordinal. This does not promise a global order across independent VMs.

Intentional pause accumulates no new periodic update demand. A previously
admitted update remains suspended or queued. After resume, the first newly due
periodic update is one full configured interval later. An application resuming
an instance is choosing how the game accounts for its inactive time; replayed
old events may need application-level stale-target handling. No engine policy
pretends those callbacks ran at their original occurrence time.

## Proposed stop and shutdown rules

Stop has a request result and a later completion result. Acceptance is not proof
that the instance has stopped or resources have retired. Once applied at a safe
boundary, it closes instance admission, cancels timer demand, disconnects event
sources and discards unstarted invocations with recorded disposition counts.
Stop also works while paused and takes precedence over ordinary queued work.

Do not resume the cancelled ordinary continuation. Unwind/close its coroutine
at the VM boundary before shutdown; preserve errors from local closing handlers.
Lua closing can execute user code and fail, so dependencies and instance state
remain alive through this phase. No current segment is forcibly interrupted:
a trusted script that never returns or yields cannot be guaranteed to stop.
See Lua's [coroutine close contract](https://www.lua.org/manual/5.4/manual.html#pdf-coroutine.close).

**Shutdown proposal:** if initialization succeeded and the VM/state remains safe
to enter, invoke the optional `shutdown` hook once, even if an update or callback
was cancelled before finishing. Pass the same `self` and a bounded reason
(`stopped`, `completed` or `failed`). A normal one-shot completion uses the same
cleanup path. Repeated stop requests never invoke shutdown again. If init never
succeeded, or the owner suffered a fatal failure that makes Lua entry unsafe,
skip the hook and report that disposition.

Shutdown must tolerate missing or partial loop state. Register ownership when a
resource is acquired, not at the end of an update. Keep persistent handles on
`self` when shutdown needs them; do not assume a cancelled coroutine's local
variables will be available. Release only holdings that actually exist. A
shutdown hook cannot restart the stopping instance or admit new ordinary work.

After the hook, release remaining runtime-owned instance holdings even if the
hook failed, invalidate callable references, and retain the terminal outcome.
Native/provider cleanup follows its actual completion contract; dropping Lua
interest does not prove external work stopped. Essential engine resources must
not depend on the Lua hook running successfully. Manually owned application
resources still require an explicit application cleanup/lease contract.

A shutdown error is reported with cleanup evidence, not retried. An ordinary
stopped/completed instance becomes failed if its hook fails; an existing primary
failure remains primary. Host cleanup failures follow supervision. Cancellation
does not undo partial shared mutations: safe boundaries must preserve application
invariants or leave staged effects discardable; otherwise D-7/P-8 apply.

## Proposed cadence and control defaults

The application supplies a positive logical tick duration; no production rate
is hard-coded. Gameplay intervals are positive integer tick counts. Convenience
duration input must convert exactly to that unit or be refused, never silently
rounded. One-shot/event-only instances have no periodic interval. First update
is due one interval after successful initialization. A gameplay invocation keeps
its granted `dt` across waits and real execution delays.

UI periodic intervals use monotonic time. Keep at most one unstarted periodic
refresh; coalesce obsolete refresh demand without dropping queued events. Its
`dt` is elapsed time between update starts, initially from successful init and
rebased at resume to exclude intentional pause. Ordinary lateness advances the
deadline to the next point strictly in the future on the configured cadence;
it does not issue a burst of catch-up refreshes. A later presentation composition
may additionally supply frame-driven updates.

Control admission reserves bounded result capacity; full/closed/unauthorized/
unknown-or-stale-target requests are explicit refusals. Application results
distinguish applied, already-in-that-state and no-longer-applicable. Repeated
pause/resume/stop is safe and never resurrects a terminal instance. Control on
the currently running instance is deferred to a safe boundary. Pending stop
cannot be undone by resume. Terminal stop completion awaits cleanup obligations;
module references retained by other users remain valid. A deterministic game's
control admission and application boundary are part of its recorded logical
input contract, including commands issued from the UI VM or terminal.

## Delivery organization and evidence

The owner delegated organization. Keep separately reviewable outcomes:

1. LUA-6: scheduler and logical-time/control machinery, policy extension seam,
   protected coroutine execution and deterministic model tests.
2. LUA-18: instance authoring/lifecycle adapter, isolated state, inspection and
   granted control API, bounded invocation queue and cleanup/failure behavior.
3. LUA-7: connect real request/subscription machinery to instances; prove paused
   event retention, overload, cancellation and safe provider retirement.
4. LUA-19: headless CLI runner using the same reusable APIs available to a future
   windowed application; source loading stays in the application. No game terminal
   or windowed application is necessary for this proof.
5. LUA-8: integrate independent gameplay/UI VMs and qualify deterministic gameplay
   against varied execution delays and UI activity with identical logical inputs.

The canonical ledger and dependencies live in the parent design. These entries
are not filed issues. Do not implement behavior still marked proposed above
until the owner accepts the contract and the owning slice passes readiness.

Contract tests must cover failed init without later hooks, isolation versus
unsafe shared-state failure, pause during a yielded callback, ordered bounded
resume, explicit overflow, stop while paused, cancellation before an update
finishes, shutdown once, shutdown failure plus runtime cleanup, stale controls,
provider completion after cancellation, and equal committed gameplay state under
different real-time delays. Tests use injected clocks/barriers, not timing sleeps.
