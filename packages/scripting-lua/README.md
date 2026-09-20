# Lua host

One embedded Lua interpreter, reached through a private bridge. This package
owns VM construction over an explicitly chosen set of standard libraries, chunk
loading, protected calls, error and cancellation transport across the C
boundary, and a terminal close. It depends on `hetoimasia-foundation` and the
Lua binding and on nothing else in the engine: no runtime, GLFW, Vulkan,
console, or game code.

Beside it, and sharing nothing with it, the package owns the **protocol model**:
the pure task, admission, request, subscription, epoch, failure, and stop types
that later slices implement against. See
[The protocol model](#the-protocol-model).

The public module and capability registration surface, the protected VM owner,
and any game binding are later slices of
[the Lua runtime design](../../docs/lua_runtime_design.md). What is here is the
boundary they will be built on, and the evidence that it holds.

## What the boundary exposes

`Hetoimasia.Scripting.Lua.Bridge` is the whole public surface:

- `newVm ∷ [Library] → IO Vm` and `closeVm ∷ Vm → IO ()`.
- `evalChunk ∷ Vm → ChunkName → ByteString → IO ()` and
  `callGlobal ∷ Vm → Text → IO ()`.
- `chunkName`, the `Library` set, and the failure types.

`Vm` and `ChunkName` are abstract. No exported module hands a caller a Lua
state, a stack index, a registry reference, a coroutine, a closure, or a native
address, and none of them has a reachable representation that becomes one: the
state, the callback entry, and the stack probes live in the package's private
`bridge` sublibrary, which no client
outside the package can depend on. `Test.Lua.Opacity` compiles clients that try
each of those reaches and requires the compiler to refuse them, and one client
that uses the whole public contract and requires it to link and run.

Two absences are deliberate. There is no way to register a Haskell function:
module identity, capability namespaces, and per-domain policy are LUA-3's, and
installing callbacks without them is how a bridge acquires a surface nobody
reviewed. And there is no call that opens "all the libraries": `newVm` takes the
list, and `[]` is a VM with no standard library at all.

## The binding, and why this one

`lua-2.3.4`, which bundles the Lua **5.4.8** C sources, on GHC 9.14.1 and Cabal
3.18.1.0 at `index-state: 2026-09-18T00:00:00Z` — the baseline
[issue #157 qualified](../../docs/toolchain.md), merged as `3af4cb2`. The
package contract's bound is `lua >=2.3.4 && <2.4`.

`lua` is the HsLua project's own raw binding layer, the first candidate the
design names. `hslua-core`, the monadic layer above it, is **not** used, for two
reasons that are this slice's requirements rather than preferences:

- Its `LuaE` monad exports `state`, which hands any holder the raw
  `Lua.State`. A public API built on it could not keep the state private.
- Its `run` masks asynchronous exceptions across the whole computation. This
  bridge has to decide for itself what a cancellation delivered around a native
  call does, and inheriting a blanket mask forecloses that.

Nothing in `hslua-core` is needed for what this slice does. What is used from
`lua` is narrower still: the Lua C API, the bundled interpreter, and the
individual `luaopen_*` functions. Its Haskell-facing conveniences are not used,
for the reasons under *The foreign-call audit*.

### Provisioning and build identity

The interpreter is the copy `lua` bundles; nothing is provisioned. The Linux CI
image recipe is unchanged, its pinned descriptor and toolchain identity contract
are untouched, and no macOS remote CI is introduced.

`cabal.project.common` pins the binding's own flags for every project
configuration:

```
package lua
  flags: -system-lua -pkg-config -allow-unsafe-gc
```

`-system-lua` and `-pkg-config` are what keep a second Lua off the build.
Both default to off, but they are stated rather than assumed: with either on,
the build links whichever `liblua` the machine happens to offer, which is a
different interpreter version per developer. `-allow-unsafe-gc` is the audited
choice below.

The dependency's cache identity is the workflow's existing package-store key,
`cabal-store-<environment>-${{ hashFiles('cabal.project', 'cabal.project.common',
'**/*.cabal') }}`. The bundled Lua sources are compiled once into that store and
restored on every later run, so no job rebuilds Lua unconditionally; and because
the key covers `cabal.project.common`, changing the flags above correctly
invalidates it. A clean build with a cold store compiles the Lua C sources and
the binding before this package, and nothing else changes.

## The foreign-call audit

What the boundary actually does, recorded here so later slices do not have to
rediscover it.

### What is used, and what is not

This package performs several Lua operations through its own C rather than the
binding's wrappers, in `bridge/cbits/hetoimasia_lua_bridge.c`. The reason is the
same each time and is set out under *Allocation* below: the binding's wrappers
put their protected call after the allocation that builds their arguments, so
the first allocation of the operation is unprotected.

| Import | Annotation | Used by |
| --- | --- | --- |
| `lua_pcall` | `safe`, fixed | every call into Lua |
| `lua_close` | `safe`, fixed | the close |
| `luaL_loadbuffer` | `safe`, by the flag | loading a chunk |
| `luaL_ref`, `luaL_unref` | `safe`, by the flag | the fixtures' registry probe only |
| `lua_tolstring` | `safe`, by the flag | reading a string error value |
| `hetoimasia_lua_publish`, `hetoimasia_lua_getglobal`, `hetoimasia_lua_requiref` | `safe` | publishing a callback, reading a global, opening a library — each one protected call |
| `hetoimasia_lua_newstate` | `unsafe` | creating the interpreter |
| `lua_gettop`, `lua_settop`, `lua_type`, `lua_typename`, `lua_isinteger`, `lua_tointegerx`, `lua_tonumberx`, `lua_pushboolean`, `lua_pushlightuserdata`, `lua_touserdata`, `lua_remove` | `unsafe`, fixed | stack bookkeeping, rendering, and the callback entry |

`lua-2.3.4` fixes some of its imports and leaves others to the
`allow-unsafe-gc` flag, which this repository disables; under that setting the
flagged ones are `safe`.

Deliberately **not** used: `hsluaL_newstate`, `hsluaL_requiref`,
`hslua_getglobal`, `hslua_setglobal`, `hslua_pushhsfunction`,
`hslua_newhsfunction`, `hslua_extracthsfun`, and `hslua_error`. Each either
allocates before its own protection or brings the binding's foreign export with
it. Nothing this package does reaches them, so the binding is used for the Lua C
API, the bundled interpreter, and the standard-library openers — not for its
Haskell-facing conveniences.

The `safe` calls are what let other Haskell work and other VMs progress while
one VM is running a chunk: a `safe` call releases the capability for its
duration. That is the property the one-capability example in `Test.Lua.Hazard`
exists to make falsifiable.

`-allow-unsafe-gc` is **disabled**. With it on, every call that can trigger a
collection is imported `unsafe`. This bridge puts Haskell functions into Lua,
and each one is a userdata whose `__gc` frees a stable pointer, so any VM that
has ever held a callback re-enters the RTS from its collector. An `unsafe`
import is not a context that may do that. Turning the flag off makes those calls
`safe`. The cost is the `safe` foreign-call overhead on allocation paths, which
this slice did not measure: it is a correctness setting, and a measurement
belongs with the first workload that has a budget to weigh it against.

### Allocation, and where a Lua error can be raised

Almost every Lua operation that allocates can raise `LUA_ERRMEM`, and where that
raise lands depends on where the call was made from. There are two places, and
they are not equally bad.

**From inside a callback.** A protected frame exists — the caller's `lua_pcall`,
further out — so a raise here `longjmp`s *out of a Haskell frame* to reach it.
That is undefined behaviour, not an error report. So the callback entry uses
only operations that allocate nothing: `lua_pushboolean` for a boolean result,
and a light userdata for the failure marker rather than a string.

**From Haskell, outside any protected frame.** A raise here finds no frame at
all and runs Lua's panic function, which ends the process. Everything this
package does from that position is therefore either non-allocating or wrapped:

- Constructing the interpreter cannot be protected, because there is no state
  yet to protect it with. `hetoimasia_lua_newstate` is `luaL_newstate`, which
  reports an allocation failure by answering a null state rather than by
  raising, and `newVm` turns that into `MemoryExhausted`. The binding's
  `hsluaL_newstate` also builds a registry entry and a metatable afterwards,
  unprotected; this package needs neither.
- Publishing a callback, reading a global, and opening a standard library each
  run entirely inside one `lua_pcall`, including the `lua_pushlstring` that
  builds their names. The binding's wrappers push those names first.
- Reporting a fault takes no registry reference (`luaL_ref` can raise) and calls
  `lua_tolstring` only on a value that is already a string, where it converts
  nothing; a number is read with the non-allocating accessors and formatted in
  Haskell. `Test.Lua.Faults` pins that — a numeric error value renders in
  Haskell's formatting, not Lua's, which is the observable difference.

`lua-hazard allocation-failure` is the evidence, for all three replaced paths.
The binding exports no `lua_newstate`, so an allocator that fails on demand
cannot be installed from Haskell; the hazard runner builds one in C and walks
its budget from nothing upwards, so every allocation on each path is the one
that fails in some run. Each path must be refused at some budget and complete at
another — a path never refused was never starved — and every refusal must be
Lua's own memory status rather than something else, the shim must leave exactly
one value on the stack whether it succeeded or failed, and the state must still
work afterwards.

Publication is asked two things more. At each budget it publishes to the *same*
state again with room to spare and requires that to succeed, and requires the
carriers the state finalizes to equal exactly those a publication took ownership
of. That pair is what a half-built state breaks: this package's carrier
metatable is registered only once complete, because a metatable registered
before its `__gc` is installed would be found by the next publication, believed
finished, and leave a carrier nothing ever finalizes.

What the child cannot show is what the bridge does with the status it gets back,
because it has no `Vm`; `Test.Lua.Faults` holds that half, and requires
`LUA_ERRMEM` to become `MemoryExhausted` rather than the rejected chunk it was
read as before these paths were protected.

Ownership of the Haskell function's stable pointer is reported rather than
inferred. Several allocations can fail on that path and only some leave an owner
behind, so the status alone cannot say whether Lua took it: the shim sets a flag
at the instruction the carrier's metatable is attached — the first point from
which its `__gc` is certain to run — and the bridge frees the pointer only when
that flag says Lua never took it.

### How callbacks re-enter

This package owns the callback path. `hetoimasia_lua_bridge.c` builds a userdata
that carries a stable pointer to the Haskell operation, gives it a metatable
whose `__gc` frees that pointer and whose `__metatable` keeps a script away from
it, and wraps it in a C closure. Lua calls that closure, which calls this
package's own `foreign export`, `hetoimasia_lua_enter`. The error protocol is
correspondingly this package's: a negative result count means the value on top
is the failure marker, and `lua_error` is raised by the C closure after every
Haskell frame has returned, because a `longjmp` through one is undefined.

That export runs the callback **in a Haskell thread of its own**, not in the
thread that called `evalChunk` — that is how GHC's foreign exports work, and two
consequences follow:

- A callback cannot be cancelled by cancelling the calling thread, and the
  calling thread cannot observe the callback's own thread.
- The escape record has to live on the VM rather than on a thread, which is why
  `Vm` holds one.

A globals table can carry `__index` and `__newindex` metamethods, so reading or
publishing a global runs Lua too, and that Lua can call one of these callbacks.
Every such path therefore reports its own protected call's status and drains the
escape record; collapsing a failed lookup into "not a function" would report the
wrong failure and leave the real one for an unrelated later operation.

### Error and cancellation transport

**Cancellation targets a VM's execution owner.** A callback thread is the
runtime's machinery, created for one call and ending with it, and is not an
endpoint an owner addresses. A trusted callback must not publish its own
`ThreadId` for something else to cancel, and must not leave work running past
its own return. This is a contract, not a wish: the runtime's own prologue and
epilogue around a foreign export are not code this package can mask, and a
cancellation delivered there ends the process. `lua-hazard
callback-cancellation` reproduces that on demand and is kept as diagnostic
evidence rather than as an example, because an example that accepts either
outcome asserts nothing.

What the contract does promise:

- **Owner cancellation stays observable.** It is not delivered while the owner
  is inside Lua, because `lua_pcall` is a `safe` foreign call; it stays pending
  and arrives once the call has returned *and* the operation's bookkeeping is
  done. Operations run masked for that reason — delivered between the call
  returning and the stack being restored, it would leave the stack deep and one
  call's callback failure for the next to raise. Nothing is lost by masking,
  because a thread inside Lua could not be cancelled anyway. What a cancelled
  operation does not do is retire anything its callbacks borrowed; that waits
  for the close.
- **A callback's failure keeps its type and context.** The action runs unmasked,
  so it is interruptible for its own purposes and a failure of any type is
  caught with the context it carried, recorded on the VM, and answered to Lua
  with the failure marker. Lua may catch that with `pcall` and finish the chunk
  successfully; the operation's boundary still re-raises the recorded exception,
  with its own type and context, and adds its operation to that context. The
  first escape of an operation is the one kept, and an operation that leaves by
  any other exception takes the record with it.
- **Nothing promises to interrupt arbitrary Lua.** Callbacks are short and do
  not block; work that would block belongs in an asynchronous request or is cut
  into segments. Enforcing limits on untrusted code is the business of the
  isolated processes that will run it, not of this boundary.

A Lua error inside a protected call is a status code, never an unwind: it is
classified — including `LUA_ERRMEM` as `MemoryExhausted`, wherever it comes from
— its value is rendered under a bound, and it becomes a `LuaFault`. Rendering
runs no Lua, so a `__tostring` metamethod is never called, and reports a value
that is neither a string nor a number by its Lua type alone. Not by its address:
a pointer rendered into text is still a native address, and `LuaFault` crosses
the package boundary. Absence is read from the stack depth, so a `false` error
value is reported as a boolean rather than mistaken for nothing.

### Supported and rejected execution paths

Supported:

- One execution owner per VM, enforced by a gate rather than assumed. A second
  thread's operation waits; an operation on a closing or closed VM is refused.
- Several VMs in one process, each with its own globals, running concurrently.
- Haskell work and a second VM progressing while one VM runs a long chunk.
- Closing a VM whose last call failed; closing twice.

Rejected:

- **Cancelling a thread that is inside Lua.** It does not work and cannot be
  made to work with an asynchronous exception; `throwTo` blocks until the call
  returns. A supervisor that must reclaim a running task needs something else —
  a hook Lua itself consults, or a process boundary. `Test.Lua.Hazard` proves
  this in a child process, because a chunk that never returns holds its thread
  for the life of the process.
- **Unprotected calls.** Anything that can raise a Lua error goes through
  `lua_pcall` or the binding's protected ersatz functions; an unprotected one
  that errors ends the process.
- **Using a VM, or anything a callback borrowed, after the terminal close.**
- **Taking a registry reference, or converting a number to a string, on a
  reporting path.** Both can raise a Lua error where no protected frame is left
  to catch it.
- **Any allocating Lua operation from inside a callback.** A raise there unwinds
  out of a Haskell frame to the protected call outside it.
- **Reaching Lua from a callback with anything that allocates.** A raise there
  unwinds out of a Haskell frame to the protected call outside it.
- **Cancelling a callback thread.** Not an endpoint; see *Error and cancellation
  transport*. Cancel the VM's execution owner instead. The entry
  pushes only a boolean or a light userdata for that reason.

### Process-global state and thread affinity

The binding declares **no OS-thread affinity**, and this slice adopted none: the
suite creates VMs, runs chunks, takes callbacks, and closes from ordinary
`forkIO` threads, and the hazard runner drives one from a thread other than the
main one. A VM may be driven from any Haskell thread its owner chooses, one at a
time.

The binding and this bridge introduce **no process-global lock**; the only
serialization either adds is the per-VM gate. Two locks are still reached
indirectly, and neither is this bridge's to remove: the RTS's stable-pointer
table, when a callback userdata is created or collected, and the C allocator
Lua's default allocation function uses. The Lua interpreter holds no state
shared between `lua_State`s, which is why two VMs share no globals.

The suite runs with `-threaded -rtsopts -with-rtsopts=-N2`, and so does the
`lua-hazard` executable. `-N2` rather than `-N`, so every machine runs the same
thing: the hazard needs one thread inside Lua and one observing it.

The hazard runner carries four modes. Three are examples: the uninterruptible
chunk, the allocation sweep, and the progress proof. The fourth,
`callback-cancellation`, is a diagnostic — it cancels callback threads, which
the contract does not support, and ends the process some of the time, which is
the evidence for saying so. Run it by hand; the suite does not assert on it.

The independent-progress proof runs `lua-hazard capability-release` with
`+RTS -N1`, overriding that. Two things make it mean something.

One capability is what makes it falsifiable: a Haskell thread can run during a
foreign call only if the call released the capability, so an `unsafe` import
would let no Haskell run at all inside the call. With two capabilities the same
example passes either way.

And the observation is made from inside Lua, by a count hook in the hazard
runner's own C. Every signal Haskell can see from a running chunk arrives
through a callback, and a callback is Haskell — so work observed around one
proves only that one Haskell thread ran while another did. The hook samples a
counter twice from within Lua's instruction loop, with nothing but Lua
instructions in between; growth between those samples happened while Lua was
executing. The test is that they differ, not that they differ by some amount,
which would be a claim about throughput. What the hook costs is that it
interrupts the interpreter every 200,000 instructions, which slows the chunk and
creates yield points: that changes how much growth is seen, not whether any is
possible, and no latency bound is read out of it.

The in-process example in `Test.Lua.Independence` shows a second VM running to
completion while the first VM's call is outstanding. That is deterministic, and
it says nothing about capability release; it does not claim to.

## Lifetimes

`closeVm` is terminal and runs once, and the VM's phase distinguishes *closing*
from *closed*. The caller that finds it open runs the teardown holding the
operation gate; the phase is `Closing` throughout, so an operation that arrives
meanwhile is refused, and a second `closeVm` waits for that one teardown rather
than being told the VM is closed while Lua is still running a finalizer. The
teardown is masked, so a cancellation arriving during it can neither release a
callback's borrowed dependencies early nor leave a half-finished close for a
later call to retry.

Dependencies are released only after `lua_close` has returned, because until then
Lua's finalizers are still running. A callback's release is retained *before* the
callback is published, so there is no ordering in which Lua can reach a callback
whose release is not held; a publication that then fails leaves a release that
runs at the close and frees something never used, which is the harmless
direction of that pair. Every release is attempted, and their failures — together
with any failure a Haskell finalizer raised while `lua_close` ran it, which
belongs to no caller's operation and would otherwise be observed by nobody — are
collected into one `CloseFault` rather than letting the first hide the rest.
Every failing finalizer is kept, not just the first: an operation's first
callback failure is the one its caller is owed, but a close is not one
operation — `lua_close` runs each pending finalizer, and each can fail on its
own account.

An unrestricted `lua_close` is deliberately **not** wired into
`Hetoimasia.Foundation.Resource`'s `withResource`. The resource contract's
release discipline is written for releases whose blocking is controlled, and
claiming it here would assert a property this slice has not established. The
close proof lives in the suite's own private fixture; the protected owner that
will make that claim is LUA-2's.


## The protocol model

The private `model` sublibrary (`model/`) is LUA-4: the vocabulary a scheduler,
a provider, and a transport implement against, as pure data and pure functions.
It performs no IO, reads no clock, and creates no interpreter, and its
`build-depends` names only `base`, `containers`, and `text` — neither the `lua`
binding nor this package's own `bridge` sublibrary. That last fact is the
boundary, and it is checked two ways that answer different questions:
`Test.Lua.Protocol.Fixture` reports that the examples acquired no interpreter,
and `Test.Lua.Protocol.Boundary` reads the Cabal stanza and every model module's
imports, because a component can depend on the binding and simply not call it.

Every record is parameterised by one application value type the model never
inspects. A cursor is one, a settlement carries one, an event delivers one, and
nothing in the package pattern matches on it.

### Identities

`Hetoimasia.Scripting.Lua.Internal.Protocol.Identity`. An `Owner` is one `ModId`
in one `ExecutionDomain`; a `SessionKey` adds its `SessionId` and `Epoch`. Every
`TaskId`, `RequestId`, and `SubscriptionId` carries that scope, so D-8's
isolation is structural: two mods' first tasks are different values, and so are
two epochs' or two sessions'.

Local numbers are not the caller's to guarantee. The session issues the
`TaskName` outright — `requestAdmission` answers the `TaskId` it built — and
stamps a `Generation` from one counter it never rewinds onto every `RequestId`
and `SubscriptionId` it hands out. A `RequestName` or `SubscriptionName` the
caller chooses is only half an identity, so reusing a handle after its record
was reclaimed is safe: the identity is new, and a reply or event still in flight
for the record that handle named before cannot reach the one it names now. That
is the bound the alternative lacks — validating reuse against what has been
forgotten would need a list of retired identities that grows forever.

`Ordinal` is the one counter that is not an identity: the session issues it on
admission and on every re-entry into the ready set, which is what puts a yielded
task behind its ready peers.

### Tasks and transitions

`…Protocol.Task`. A `Task` holds identity, behaviour identity, service class,
state, cursor, ordinal, readiness, and an optional pending interest. Its
`TaskState` is `Ready`, `Running`, `Waiting` with its exact `WaitCause`,
`Paused`, or one of `Completed`, `Cancelled`, and `Failed`. Each transition —
`startTask`, `applySegment`, `wakeTask`, `pauseTask`, `resumeTask`,
`cancelTask`, `failTask` — is a pure function answering the next task or a
`TransitionRejection`: `AlreadyTerminal`, `WrongState`, `StaleScope`,
`AheadOfScope`, or `ForeignScope`. A rejection returns the task untouched, a
terminal task refuses everything including another terminal transition, and the
scope check runs before the state check, so a stale resume reports staleness
rather than the state it happened to find. `applySegment` is the only function
that writes a cursor, and it requires `Running`: a `SegmentOutcome` is
completed, yielded with a new cursor, or waiting on a named cause.

### Caps

`…Protocol.Limits`. `Limits` bounds active tasks, queued admissions,
subscriptions, one ordered-event backlog, outstanding requests, payload size,
and retained terminal results, with a finite `Quantum` per `ServiceClass`
(`ControlClass`, `OrdinaryClass`, `BackgroundClass`). `validateLimits` answers
every `LimitViolation` it finds, and a `ValidLimits` can be obtained no other
way, so no session exists over an unchecked configuration. The quanta are
recorded and enforced by nothing here; choosing what runs next is LUA-6's.

### The session

`…Protocol.Session` composes the rest. Each operation answers
`(Session v, Either SessionRejection a)`. A rejection never advances the
protocol: no task changes state, no cursor moves, no settled slot is
overwritten, no event is delivered, no admission is accepted. It is *not* true
that a rejection changes nothing, and no later slice should be built on that
stronger reading. A rejection may record evidence — always on
`sessionCounters`, and on the record it was about in four places: a reply to an
already-settled request retires its provider accounting, a reply over the
payload cap discharges the request (settling an unsettled one as a provider
failure), a repeated provider completion increments `requestLateCompletions`,
and a delivery into a full ordered backlog increments `subscriptionRejected`.
The payload-cap case is the only rejection that moves a record's protocol
state. `SessionRejection` names `AdmissionIsClosed`, `CapReached`,
`PayloadTooLarge`, the identity refusals `UnknownTask`, `UnknownRequest`,
`UnknownSubscription`, `TaskRetired` (a task this epoch issued whose result has
been observed away) and `TaskNotActivated` (an accepted admission that has
never run), `NotTaskOwner`, `NoTerminalResult`,
`NothingQueued`, `NoDelivery`, `SessionAlreadyFailed`, `SessionAlreadyStopped`,
and the wrapped refusals of the records themselves (`TransitionRefused`,
`ReplyRefused`, `ObserveRefused`, `ProviderRefused`, `DeliveryRefused`). There
are no `Duplicate*` refusals: the session issues the identities that could have
collided, so the collision cannot arise.

Two bounds are worth stating in full.

**Terminal-result storage** is reserved at admission and released when the
result is observed or discarded, so a completed task whose result nobody reads
keeps occupying storage its admission already paid for, and the session refuses
the next admission rather than growing. There is no ticket history.

**A request holds two independent obligations** and its bookkeeping is reclaimed
only when both are discharged: its result observed or discarded, and its
provider's work known to have ended. Completing the provider does not release an
unobserved result; observing a cancellation does not establish that the provider
stopped. Cancellation, task invalidation, epoch change, failure, and stop all
revoke delivery authority without establishing provider completion, and the
accounting for it survives them, keyed by the old identity. A late reply is
refused and publishes nothing, and still retires that accounting, because an
answer is evidence the provider finished.

A reply whose declared payload exceeds the cap is refused with
`PayloadTooLarge` and its value is never stored, but it still discharges the
request: an unsettled one settles as a provider failure naming the overrun, and
one that had already settled is counted as a late reply. Either way the
provider's work retires — a provider that overran still answered, and a refusal
that left its accounting outstanding would hold capacity nothing could release.

Subscriptions declare their endpoint's `OverloadPolicy`: `OrderedEvents` rejects
and counts a delivery into a full backlog, `ReplaceableState` coalesces to the
newest value. There is no universal lossy stream.

`advanceEpoch` invalidates every task, queued admission, subscription, and
pending request of the previous epoch before the new one exists, retaining only
provider-work accounting. It invalidates only what still holds a local
interest: a stub whose owner already revoked it — by having its task
invalidated, or by observing its cancellation and walking away — is carried for
provider accounting and is not invalidated, or counted, a second time. Session
failure, stop, and the invalidation of one task's own holdings all follow that
same rule. `reportFailure` with `RecoveryUnsafe` moves the
session to its terminal failed state: mutation admission closes, live work is
invalidated, and the record is kept beside the identity of the last good
snapshot. `Observing` admission stays open, because a failed gameplay session
that could say nothing about itself would be worse than a stopped one, and
`advanceEpoch` refuses it — replacing a failed domain means a new `Session`. An
unsafe failure ends the session even when the task it names has already
finished, or has been observed away entirely: the task keeps its one terminal
outcome, but "the behaviour that touched authoritative state was cancelled a
moment ago" is not evidence that the state is consistent. A *safe* failure
naming such a task is refused. A failure naming a *queued* admission is refused
either way and escalates nothing — a task that has never run cannot have left
authoritative state half-applied — and an identity this epoch never issued is
`UnknownTask`. The reporting work a failed session admits settles like any
other task: a `RecoverySafe` failure naming one that is active fails it once,
retires its holdings, and leaves its `ResultFailed` to be observed, so a report
about the failure cannot strand the terminal-result capacity its own admission
reserved. It settles once and overwrites nothing — the session keeps the first
`FailureRecord` and its last-good snapshot, mutation admission stays closed, no
epoch advances, and every other report a failed session receives, a repeat of
that settlement included, is still `SessionAlreadyFailed`.
`stopSession` closes admission, aborts queued work, records a task inside a
segment as outstanding rather than draining it, and answers an `ExitRecord` of
dispositions and discard counts. There is no operation that waits for every task
to finish, and the exit record carries no worker cleanup evidence: that is
supervision's, and mixing the two would let a clean stop here be read as proof a
worker unwound.

### Who consumes what

| Slice | What it takes from this model |
| --- | --- |
| LUA-6, the scheduler | `ServiceClass`, `Quanta`, `Ordinal`, the ready/waiting states, `activateNext` |
| LUA-7, requests and subscriptions | `RequestId`, `Settlement`, `Reply`, the two obligations, `OverloadPolicy` |
| LUA-9, the child-process transport | every identity, `Payload`, `Reply`, `SegmentOutcome`, the rejection vocabulary |
| LUA-5, supervision integration | `FailureRecord`, `RecoverySafety`, `ExitRecord` |

## Running the suite

```bash
cabal test hetoimasia-scripting-lua:lua-host-tests --test-show-details=direct
```

It also runs under `--project-file cabal.project.cpu`, which this package needs
no GLFW SDK for. The validation group is `test.scripting-lua`; see
[docs/validation.md](../../docs/validation.md).

The protocol model's examples are the `Protocol` component of that same suite:

```bash
cabal test hetoimasia-scripting-lua:lua-host-tests \
  --test-show-details=direct --test-options='--match Protocol'
```

They need no interpreter, and the group's last example reports that it acquired
none.

## The Linux confinement probe

`linux/` holds a second, private thing this package carries: the Linux
feasibility probe LUA-14 ([#147](https://github.com/coghex/hetoimasia/issues/147))
delivers. It is a child program (`lua-confine-child`) launched inside a
candidate confinement profile, a parent-side driver, and the C that installs the
profile and attempts the operations it is supposed to refuse.

It is not part of the bridge and nothing above links it. No library, executable,
or public interface depends on it; the only Lua source it ever loads is a fixture
chunk compiled into the child; and it is built on Linux alone, excluded
elsewhere by an `if os(linux)`/`else buildable` conditional rather than built
and passing vacuously.

```bash
cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct
```

The validation group is `test.lua-confinement-linux`. A green run of it is
evidence and never a verdict: each example prints what it proved, or says that
the machine could not install the profile and names the prerequisite that was
missing. What those lines add up to is
[the Linux confinement verdict](../../docs/lua_linux_confinement_verdict.md),
which is where the accounting semantics of the memory limit, the deployment
baseline, and the residual limits are recorded, and the runs it draws on are
kept verbatim in
[the retained runs](../../docs/lua_linux_confinement_evidence.md).

## The macOS confinement probe

`macos/` holds LUA-15's feasibility probe: a confined helper
(`macos-confinement-helper`), the trusted parent side it is launched from
(`macos-probe`, a private sublibrary), and the Hspec target that drives the
epic's proof matrix (`macos-confinement-probe`). All three are built only on
Darwin; elsewhere the components are not built rather than built and passing
vacuously.

None of it is an engine facility. No production library, executable, or public
API depends on it, and it admits no untrusted source through any public path —
the only Lua it loads is the fixture its own parent wrote into the private
directory it was given. It exists to answer
[Q-5](../../docs/lua_runtime_design.md#q-5-verified-platform-confinement-and-resource-enforcement-profile)'s
macOS row with observations.

The answer is `inconclusive` — with one row of evidence explicitly identified as
missing rather than passed — and
[docs/macos_confinement_verdict.md](../../docs/macos_confinement_verdict.md) is
where it is stated and argued: every proof row was demonstrated, on two
interfaces Apple does not support. Read it before building anything on this
code.

```bash
cabal test hetoimasia-scripting-lua:macos-confinement-probe --test-show-details=direct
```

Each example prints what it proved. The validation group is
`test.macos-confinement`, optional and local-only; see
[docs/validation.md](../../docs/validation.md#the-macos-confinement-probe).
