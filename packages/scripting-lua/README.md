# Lua host

One embedded Lua interpreter, reached through a private bridge. This package
owns VM construction over an explicitly chosen set of standard libraries, chunk
loading, protected calls, error and cancellation transport across the C
boundary, and a terminal close. Its host library depends on
`hetoimasia-foundation` and the Lua binding and on nothing else in the engine: no
runtime, GLFW, Vulkan, console, or game code. The runtime adapter that puts
owners under supervision is a sublibrary of its own, described under
[The runtime adapter](#the-runtime-adapter).

Beside it, and sharing nothing with it, the package owns the **protocol model**:
the pure task, admission, request, subscription, epoch, failure, and stop types
that later slices implement against. See
[The protocol model](#the-protocol-model).

The **protected VM owner** (LUA-2) is here: one VM held through a bracket-shaped
IO lifetime that closes it on every exit and keeps the primary failure and the
close's failures as cleanup evidence. See [The VM owner](#the-vm-owner).

The **registration and value boundary** (LUA-3) is here too: an application
registers named bindings once, gives each owner a policy naming the namespaces it
exposes, supplies its own Lua modules, and calls their entry points with bounded
copied values. See
[Registration, modules and bounded values](#registration-modules-and-bounded-values).
**Tasks** (LUA-20) are here as well: a module's entry point run as a Lua
coroutine on its VM's owner, one segment at a time, with the yield and wait
operations a script uses to give control back and the standard `coroutine`
library for the transient sequences inside one. See
[Tasks and the coroutine library](#tasks-and-the-coroutine-library).
The **runtime adapter** (LUA-5) is here as well: trusted VM owners, each one a
supervised worker running one VM, with bounded call dispatch, exactly-once
settlement and the refusal of a reply wait from inside a Lua callback. See
[The runtime adapter](#the-runtime-adapter). The **scheduling machinery** (LUA-21)
sits beside it and needs no VM: per-owner policies, service classes and quanta,
logical and elapsed time behind one owned timer, budgets, and safe-boundary
control, tested against scripted segments. See
[The scheduling machinery](#the-scheduling-machinery). **Scheduled owners** (LUA-6)
host it, and the host's task coroutines, on supervised workers with real VMs. See
[The scheduled owner](#the-scheduled-owner). **Script instances** (LUA-18) sit on
them: instances of a module with their own state, hooks, event callbacks and a
lifecycle the application controls. See [Script instances](#script-instances).
**Lifecycle services** (LUA-23) let an owner's scripts pause, resume, stop and inspect instances
of the owners the application grants them, and nothing else. See
[Lifecycle services](#lifecycle-services). **Asynchronous requests** (LUA-7) let a script ask a provider for something it
will answer later, with a reserved result slot, settled exactly once and, on a logical owner, delivered at the tick the
application assigned. See [Asynchronous requests](#asynchronous-requests). **Provider events** (LUA-26) let an
instance subscribe a function to a provider's events: owned by the instance, delivered into its bounded queue by
producers that never call Lua, and, on a logical owner, admitted at the tick and place the application assigned. See
[Provider events](#provider-events). **The script runner** (LUA-27, LUA-28) runs a list of Lua files to completion as the instances of one
named VM, on the elapsed clock or on logical ticks, publishes the instances' start and end events, and answers a bounded report: the library the `lua` subcommand and a windowed application
share. See [The script runner](#the-script-runner). Any
concrete game namespace and the confined path are later slices of
[the Lua runtime design](../../docs/lua_runtime_design.md). What is here is the
boundary they will be built on, and the evidence that it holds.

## What the boundary exposes

Four modules are public. `Hetoimasia.Scripting.Lua.Owner` is the protected VM
owner, described under [The VM owner](#the-vm-owner): `withVmOwner`, the owned
VM it lends its body, `evalOwned` and `callOwned` on it, and the module and
entry-point operations of
[the value boundary](#registration-modules-and-bounded-values). A VM it
constructs is an `OwnedVm`, which is not the bridge's `Vm`, so nothing below
accepts it: no bridge operation can run Lua on a managed VM or close it behind
its owner's back. `Hetoimasia.Scripting.Lua.Registration` and
`Hetoimasia.Scripting.Lua.Value` are what an application registers and what
crosses; they hold no VM.

`Hetoimasia.Scripting.Lua.Bridge` is the lower, unmanaged surface. Its callers
close what they construct themselves, and it is what the owner is built on:

- `newVm ∷ [Library] → IO Vm` and `closeVm ∷ Vm → IO ()`.
- `evalChunk ∷ Vm → ChunkName → ByteString → IO ()` and
  `callGlobal ∷ Vm → Text → IO ()`.
- `chunkName`, the `Library` set, and the failure types.

`Vm` and `ChunkName` are abstract. No exported module hands a caller a Lua
state, a stack index, a registry reference, a coroutine, a closure, or a native
address, and none of them has a reachable representation that becomes one (a
`Task` of the owner is a handle that *names* a coroutine of its VM and gives
access to nothing of it; see [Tasks](#tasks-and-the-coroutine-library)): the
state, the callback entry, and the stack probes live in the package's private
`bridge` sublibrary, which no client
outside the package can depend on. `Test.Lua.Opacity` compiles clients that try
each of those reaches and requires the compiler to refuse them, and one client
that uses the whole public contract and requires it to link and run.

Two absences are deliberate. There is no way to hand Lua a bare Haskell function
from `Bridge` or from the owner: a Haskell function reaches a script only as a
binding of a validated `Registration`, in a namespace the owner's policy grants,
with schemas for what crosses, because installing callbacks without them is how a
bridge acquires a surface nobody reviewed. And there is no call that opens "all
the libraries": `newVm` takes the list, and `[]` is a VM with no standard
library at all.

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
| `hetoimasia_lua_filter_m1` | `safe` | filtering the M1 library profile's open libraries — one protected call, no argument crosses it |
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
That is undefined behaviour, not an error report. So the callback entry itself
uses only operations that allocate nothing: `lua_pushboolean` for a boolean
result, and a light userdata for the failure marker rather than a string. A
registered binding, which has to read and build values, does that work in
`hetoimasia_lua_values.c`, each operation one `lua_pcall` whose body may raise
freely because the only frames between it and its `lua_pcall` are C: reading the
arguments, pushing the results and capturing the caller's context are each such a
call, made as a `safe` foreign call from the callback's thread, so exhaustion is
a status the handler turns into a typed fault and never an unwind.

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
- Reporting a fault takes no `luaL_ref` reference (`luaL_ref` can raise) and calls
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

**A callback's operation on its own VM is refused.** The operation that ran the
callback holds the VM's gate until the callback returns, so anything the
callback asks of the same VM — evaluating a chunk under any message handler,
calling or probing a global, installing a callback, closing — could only wait
for its own caller, which is inside a `safe` call no cancellation reaches. The
VM therefore keeps the threads running its callbacks, and an operation or close
asked from one of them fails at once with `VmReentered`, naming the refused
operation, before it takes the gate: it runs no Lua, leaves the stack as it was,
retains no release and publishes no global. The refusal is an ordinary failure
of the callback's action, so it travels like one: the operation that ran the
callback raises it with its own type and context whatever Lua did with the
placeholder, and the VM stays open. That includes callbacks an `__index` or
`__newindex` metamethod runs, and callbacks a `__gc` runs during the close,
whose refusals the close's `CloseFault` carries.

Every other thread is unaffected: its operation waits for the gate while the
owner is inside a call, then runs, exactly as before, and is never refused
because a call is in progress. The check is by thread identity, so re-entry
through a thread the callback starts, or through another VM whose callback
calls back into this one, is not detected. Both remain forbidden by the
callback contract; nested execution on one VM is outside it (`P-4` in
[the runtime design](../../docs/lua_runtime_design.md)), and a synchronous call
into another VM's owner is `D-13`'s to forbid.

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
  with a light-userdata failure marker carrying no message. Lua may catch that
  with `pcall` and finish the chunk successfully; the operation's boundary still
  re-raises the recorded exception with its own type and context, and adds its
  operation to that context. The first escape of an operation is the one kept,
  and an operation that leaves by any other exception takes the record with it.
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
- **Running Lua, or closing, from inside a callback of the same VM.** Refused
  with `VmReentered` rather than left waiting; see *How callbacks re-enter*.
  Re-entry through a thread the callback starts, or through another VM, is not
  detected and is equally outside the contract.
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

The hazard runner carries four modes. The allocation sweep and progress proof
are routine examples. The uninterruptible chunk is selected separately by
`lua-hazard-probes`, which deliberately exhausts its observation window. The fourth,
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
claiming it here would assert a property a close that runs arbitrary Lua
finalizers does not have. The protected owner, below, is the facility that
holds the VM's lifetime without making that claim: it masks the close itself and
records what the close failed with through the foundation's evidence seam.

A `CloseFault` collects each failure as a `CloseFailure`: where it came from
(`FromFinalizer`, `FromRefusedFinalizer`, `FromRelease`, `FromStrandedOperation`
or `FromTruncation`) and the exception with the context it was caught with, so a
finalizer's or a release's own annotations are kept. A VM made by `newVm` is
*unmanaged*: no thread owns it beyond the gate's mutual exclusion, and the
callbacks its finalizers reach all run. A library that fails to open, in `newVm`
or in an owner, closes the interpreter through this same close before the
failure is raised, and a failure of that close is retained beside it.

## The VM owner

`Hetoimasia.Scripting.Lua.Owner` offers the protected IO lifetime of one VM
(LUA-2; design P-3, D-1, D-15):

```haskell
withVmOwner ∷ VmConfig → (OwnedVm → IO r) → IO r
data VmConfig = VmConfig
  { vmLibraries ∷ [Library], vmLibraryProfile ∷ Maybe LibraryProfile
  , vmInitialChunks ∷ [(ChunkName, ByteString)]
  , vmOwnerName ∷ Text, vmRegistration ∷ Registration, vmPolicy ∷ [Text]
  , vmValueLimits ∷ ValueLimits, vmModules ∷ [ModuleSource] }
vmConfig    ∷ [Library] → VmConfig
vmProfileConfig ∷ LibraryProfile → VmConfig
evalOwned   ∷ OwnedVm → ChunkName → ByteString → IO ()
callOwned   ∷ OwnedVm → Text → IO ()
loadModule  ∷ OwnedVm → ModuleSource → IO ModuleHandle
loadedModule ∷ OwnedVm → ModuleRef → IO (Maybe ModuleHandle)
callEntry   ∷ OwnedVm → ModuleHandle → Text → [Value] → IO CallResult
startTask   ∷ OwnedVm → ModuleHandle → Text → [Value] → IO TaskStart
resumeTask  ∷ OwnedVm → Task → IO TaskStep
closeTask   ∷ OwnedVm → Task → IO ()
```

`withVmOwner` constructs one VM over exactly the libraries named (the empty list
opens none), installs the registration's granted bindings, loads the initial
chunks and the initial modules inside the lifetime, hands the body that VM
and only that VM, and closes it on every exit. It depends on foundation and the
binding and on nothing else: no runtime, GLFW, Vulkan or game package (P-1).
`OwnedVm` exposes no Lua state, stack index, registry reference, coroutine,
closure or native address, and no way to close the VM: only the lifetime does.

The lifetime, in order: the interpreter and its control state are allocated,
masked (a failure here leaves nothing to close); initialization runs with the
caller's masking state restored — the libraries in order, then the granted
bindings, then the initial chunks in order, then the initial modules in order;
the body runs unless initialization failed; the VM is closed, whatever
ended the steps before it; every cancellation still pending is taken at one
place, and the outcome is composed. The VM is never reachable half-constructed:
the body does not run unless every initialization step succeeded, and the VM a
failed step leaves is closed through the same close before the failure is
raised.

### One owner per VM

The gate is mutual exclusion, not identity: a thread that takes it may run Lua.
A VM an owner constructed is stricter. It belongs to the thread that runs its
lifetime, its execution owner, and an operation or a close asked by any other
thread is refused with `VmNotOwned` *before* the gate is taken, so a refused
attempt runs no Lua, changes nothing and does not disturb the rightful owner,
which goes on using the VM. That holds for a thread the body started, for a second
owner handed the first's VM, and for a reference that escaped the body, as long as
the VM is open. After the lifetime every thread's attempt is refused with
`VmClosed`. A callback's own attempt on its VM is `VmReentered`, as before.

### Any number of independent owners (D-15)

Owners are independent. Any number may be live at once, created and closed in any
order, on any threads. No owner shares a VM, a Lua global state, a registry or a
callback table with another, so closing, failing or cancelling one leaves every
other one usable, its state unchanged and its evidence unaffected. There is no
pool, scheduler or sharding across them: an owner is the thread running its
lifetime.

### The exit and evidence matrix

Whatever ends the lifetime keeps its own type, value and context. The close's
failures are retained beside it as cleanup evidence, each with the context it was
caught with and under a label naming its source (`lua finalizer`, `lua finalizer
refused`, `lua release`, `lua operation`, `lua evidence truncated`, `lua
coroutine close`, `lua close`), through `composeCleanup`, the foundation's seam below. Evidence is read
back with `cleanupFailures` or `cleanupFailuresInContext`, which is what a
supervisor reads.

| Exit | What the owner raises | Cleanup evidence |
|---|---|---|
| Body returns, close succeeds | The body's result | None |
| Body fails, close succeeds | The body's failure, unchanged | None: a close that succeeded is never reported |
| Body fails, close fails | The body's failure | Every close failure, finalizers' first then releases' |
| Body returns, close fails | The first close failure | Every close failure, that first one included, so it is the failure and cleanup evidence at once |
| Body returns with tasks still suspended | The result, unless a close fails | Each suspended task's coroutine is closed first, in the order the tasks started, every one attempted whatever another does; a to-be-closed variable's error is evidence under `lua coroutine close` (see [Closing](#closing-a-task)) |
| Construction or initialization fails at any step | That failure, after the VM that was made is closed | Any failure of that close |
| Cancellation before the lifetime | The cancellation; nothing was constructed | None |
| Cancellation during initialization or the body | The cancellation, after the VM is closed | Any failure of the close |
| Cancellation during the close | The cancellation, after the close has completed | Every close failure, on the cancellation |
| Repeated cancellation | The first; the others are absorbed by it | As above |
| Cancellation after the body failed | The cancellation, which supersedes the body's failure as it would for any scope | The close's failures; the body's failure stays reachable as the failure the cancellation was raised while handling (`WhileHandling`) |

A cleanup failure stays cleanup, including when a cancellation is the primary
failure: the exception raised is an asynchronous exception, which is what makes a
worker's outcome cancelled, and its context carries the evidence a supervisor
classifies as cleanup. It is never re-raised as a new script error that a
supervisor would read as a normal stop.

### The evidence seam in foundation

`Hetoimasia.Foundation.Resource.composeCleanup` is the public seam that composes a
primary failure with cleanup failures its caller *already caught* from a release
it ran itself: it neither runs nor masks anything, issues each failure its
identity, keeps every payload immutable, preserves contexts, nested evidence and
order, and applies the failure table the scopes use. It is the minimal additive
seam P-3 asked for, so the host imports no private foundation module. See
[docs/resources.md](../../docs/resources.md#caller-run-cleanup).

### Cancellation points

Where a cancellation can be delivered is what the bridge already proves, not an
assumption (see [Error and cancellation transport](#error-and-cancellation-transport)
and the hazard probes): a thread inside a Lua call is not cancelled, because the
call is `safe`, and the exception waits until it returns. Each bridge operation
runs masked, so it lands at the boundary after the call's bookkeeping.

| Where the owner is | A cancellation |
|---|---|
| Before `withVmOwner` | Lands outside the lifetime; nothing is constructed |
| Allocating the VM | Deferred: masked |
| Initializing or in the body, outside Lua | Delivered; ends that step; the VM is closed |
| Initializing or in the body, inside a Lua call or a callback | Waits for the call to return, then as above |
| Closing, including inside a finalizer or a retained release | Deferred: the close is masked and cannot be interrupted; dependencies are released only after `lua_close` returns, each release running uninterruptibly as a scope's does, so a cancellation neither lands inside one nor is taken for its failure; it is taken afterwards |

The close of the interpreter is *not* run as `uninterruptibleMask_`, and the
owner is not a `withResource`. It is masked and runs once; the retained
dependency releases that follow it are Haskell releases with a controlled
blocking duration, and run uninterruptibly as any scope's release does; if a finalizer never returns the
owner waits as the thread running it does, retains the dependencies and never
detaches the VM. Repeated cancellation therefore cannot abandon a live VM, free
callback dependencies under it, or start a second close, and every cancellation
that is pending when the close has finished is taken together, however many, so
a later one cannot supersede the exception that carries the evidence. The owner
stops taking them when none is pending; a thread that cancels it without end keeps
it there, as it would keep any masked region.

### Shutdown phase and the finalizer allowlist

Before the state closes the owner closes admission: every operation asked of the
VM is refused. A callback reached from a Lua finalizer runs only if the owner's
finalizer allowlist names it. The allowlist is exactly the bindings of the
namespaces the owner is granted that the registration declares
finalizer-eligible, named `namespace.binding`; the default is empty because no
binding is eligible by default, and the asynchronous kind can never be (P-3).
The allowlist is applied before the call is dispatched: before its arguments are
read, its handles checked or its action run. Any other binding is refused with
`FinalizerRefused` without running,
and the refusal is recorded as cleanup evidence even if the finalizer's script
caught the error it raised. What is recorded from finalizers is bounded: the
first 64 failures are kept in the order they happened, and one further entry says
how many were dropped (`FinalizerEvidenceTruncated`). Finalizers cannot start
asynchronous work, wait for another stopping service or re-enter the VM, because
nothing but an allowlisted callback runs, and an operation on the VM is refused.

### A scope around each callback

An owner that holds something can lend it to a callback and take it back,
whatever the callback does, by running a scope around each of the VM's
callbacks. `withVmOwnerScoped` is `withVmOwner` with a `CallbackScope`: a function
that receives the callback and a `CallbackSite` and runs it, on the callback's own
thread. It starts after the VM has recorded the thread as one of its callbacks
and ends before the record is removed, so everything it set up exists for exactly
the callback's duration, and a callback that fails still ends it. It runs for
every callback the VM runs: those of the initial chunks and the modules while
they load, of a task's segments, of a closing handler, and of a finalizer-eligible
binding the policy lets run while the VM closes. A callback a finalizer policy
refuses never runs, so the scope never does for it.

The site answers one question, `siteIsCallback`: whether the calling thread is
one of this VM's recorded callback threads right now. It is the record the VM
already keeps to refuse an operation re-entered from a callback (`VmReentered`),
read at the time of the question. A thread the callback starts is not one, and
neither is a callback of another VM, which is the same limit `VmReentered` has
and is why a scope that lends something needs the question: it can tell the
callback it lent to from every other thread without taking the thread's word.
The scope runs masked and must neither raise nor wait, because it is not part of
the callback's action and nothing is there to contain a failure of it; what the
callback raises passes through unchanged. `withVmOwner` is the same lifetime with
no scope, and nothing about reentry, cancellation or the exit matrix changes.

### What proves it

`Test.Lua.Owner.*` hold each part of this to expected values written in the
tests. The exit matrix; partial construction at each step, with an allocator
budget swept so that memory runs out at the state's allocation, while a library
opens and while a chunk runs, for an explicit list and for the M1 profile (which
`Test.Lua.Owner.Profile` also pins on real Lua: every exclusion through every
alias, from the first chunk and from a module with no chunk before it, the exact
surface left, ordinary caught and uncaught errors, permitted computation,
unchanged explicit-list and empty-library owners, independent profiled and general
owners, and the refusal of a profile with a library list); cancellation before, during initialization, the
body and the close, repeated, and with a failing close, with the cancellation
delivered by coordinated blocking and never by sleeping; the shutdown phase and
an empty allowlist, a denied callback performing no action and leaving evidence
even when Lua caught its refusal, and the bound; ownership by a thread the body
started, a second owner and a stale reference; and ten owners live at once on
separate threads, ended in a scrambled order, one failing, one cancelled and one
closed with a failing finalizer; the scope around a callback, run for exactly the
callback's duration on its own thread, ended by a failing callback, and told by the
VM's own record which threads are callbacks. `Test.Lua.Opacity` compiles the clients that try
to reach a state or a native handle through the owner or to bypass it with the
bridge's operations, and one that uses the whole public owner contract and links
and runs. Cancellation tests prove ordering, not Linux behavior: CI is what runs
them where an asynchronous-exception race can differ.

## Registration, modules and bounded values

The registration and value boundary (LUA-3; design P-4, D-2, D-6, D-9, D-12 to
D-15) is what an application uses to expose a narrow capability to its own
scripts. It names no concrete namespace, depends on foundation and the binding
only (P-1) — `Test.Lua.Boundary.Dependencies` reads the Cabal stanzas and the
imports to check that — and grants nothing to a mod: confinement, IPC and
asynchronous providers are later slices.

### Registration

A `Registration` is plain data and closures, built once and validated where it is
built, and opaque: its parts are read with ordinary functions, and neither a
registration, a namespace, a binding nor a `ValueLimits` has an exported record
label, so none can be updated into one that skipped validation: `registration ∷ [CapabilityType] → [Namespace] → Either
RegistrationRefusal Registration`. It holds application-named *namespaces* of
named *bindings*, and the *capability types* the application's scripts may be
handed. One registration is usable by any number of owners at once. A binding
declares its kind, the schemas of its arguments and of its results, and three
eligibilities (D-14):

| Kind | Constructor | Delivered here | Answers |
|---|---|---|---|
| snapshot query | `snapshotQuery` | trusted direct path | values |
| owned state operation | `stateOperation` | trusted direct path | values |
| command or UI intention | `commandIntention` | trusted direct path | `true, nil` accepted, or `false, reason` (at most 256 UTF-8 bytes) as data |
| asynchronous native request | `asynchronousNativeRequest`, `asynchronousNativeRequestIn` | an owner configured with a request context | from an owner with none, a Lua call is a typed `NotYetSupported` fault and the action never runs; from one with it, the action runs and (`asynchronousNativeRequestIn`) is handed that owner's own context (see [Asynchronous requests](#asynchronous-requests)) |
| lifecycle operation | `lifecycleOperation`, `lifecycleOperationIn` | an owner configured with a lifecycle context | from an owner with none, a Lua call is a typed `NotYetSupported` fault and the action never runs; from one with it, the action runs and (`lifecycleOperationIn`) is handed that owner's own context (see [Lifecycle services](#lifecycle-services)) |
| scheduler operation | `yieldOperation`, `waitOperation` | trusted direct path | nothing: the task's coroutine is suspended (see [Tasks](#tasks-and-the-coroutine-library)); a wait for a request's settlement (`WaitSettlement`) is delivered only to an owner configured with a request context |

The defaults are the safe ones: a binding is **direct-eligible** and nothing
else, so a default registration exposes nothing to a mod
(`confinedEligibleBindings` of one is empty) and a direct-only binding needs no
IPC equivalent. `confinedEligible` is refused when any schema of the binding
carries a capability, because a handle into one VM has no meaning to a process
that cannot hold it, and it grants nothing by itself: no grant exists until the
broker that enforces one. It is refused for a scheduler operation as well, which
suspends a coroutine of the trusted path. `finalizerEligible` is refused for the
asynchronous kind. `withoutDirectPath` keeps an owner from installing the binding at all.

Refused when the registration is built: an invalid or duplicate namespace,
binding or capability-type name; a namespace that would shadow a global the
standard libraries define (`standardGlobals`); a bound passed; a schema that is
too deep or too wide, repeats a record field or names an undeclared capability
type; a confined eligibility on a binding with a capability in its schemas; a
finalizer eligibility on the asynchronous kind. Each bound is pinned by
`Test.Lua.Boundary.Registration` at the bound and one past it:

| What | Bound |
|---|---|
| a name | 1 to 64 ASCII letters, digits and underscores; not starting with a digit; not a Lua keyword |
| namespaces in a registration | 64 |
| bindings in a namespace | 256 |
| capability types | 64 |
| arguments, results to a binding | 16 each |
| nesting of a schema | 8 |
| fields of a record schema | 64 |

### Per-owner policy

An owner is configured with a registration and a policy, `vmPolicy`: the
namespaces of it that this owner exposes beside its explicit standard-library set
(D-15). Only granted namespaces are visible to its scripts. The bindings are
installed during construction, inside the protected lifetime, after the libraries
and before any initial chunk or module (P-3 step 2), and the set is fixed for the
VM's lifetime. Only a binding eligible for the direct path is installed. The
namespace tables and the bindings are created by raw access, so no metamethod of
the globals runs. A policy naming a namespace the registration does not declare
(`PolicyUnknownNamespace`), a failure to install, and memory running out while
installing end construction like any other initialization failure: the VM is
closed through the same close and the body never runs. Which standard libraries a
script can reach is the owner's explicit set (`coroutine` is selectable like the
others; `utf8` is not offered), or the set of a library profile (below), and the
debug library an owner opens has no `sethook`, because a hook is script-defined
Lua that Lua would run while a fault's traceback is being recorded. Opening the
base library through an explicit list brings `load`, `loadfile`, `dofile` and
`collectgarbage` with it, as Lua ships them: an owner that must not read the disk
or compile source selects the M1 library profile (below), which is not an
explicit list, rather than leaving the base library out.

### The M1 library profile

`vmLibraryProfile = Just LibraryProfileM1` (`vmProfileConfig LibraryProfileM1`
builds such a configuration) selects the filtered standard-library surface of the
M1 application's Lua owners, whichever role the owner has (D-5, D-69; LFE-1). It
is opt-in: `vmLibraries`, the empty list, and the standalone `lua` command are as
they were, and nothing filters an explicit `LibraryBase`, `LibraryString` or
`LibraryMath`.

```haskell
withVmOwner (vmProfileConfig LibraryProfileM1) $ \owner →
  evalOwned owner (chunkName "check") "assert(load == nil and os == nil and string.dump == nil)"
```

**Installation order.** The profile is installed inside protected construction:
the interpreter is allocated, the profile's libraries open, the profile removes
what it excludes, and only then does anything an application supplies run — the
after-libraries step of a fixture, the granted bindings (`vmPolicy`), the initial
chunks, the initial modules. The first authored code, a chunk or a module's
top-level code, therefore already sees the filtered surface, and so does a module
loaded from the body later.

**The surface.** A profiled owner has exactly these standard libraries, and
nothing else:

| Library | Kept | Removed |
| --- | --- | --- |
| base (`_G`) | `_G`, `_VERSION`, `assert`, `error`, `getmetatable`, `ipairs`, `next`, `pairs`, `pcall`, `print`, `rawequal`, `rawget`, `rawlen`, `rawset`, `select`, `setmetatable`, `tonumber`, `tostring`, `type`, `warn`, `xpcall` | `load`, `loadfile`, `dofile`, `collectgarbage` |
| `string` | `byte`, `char`, `find`, `format`, `gmatch`, `gsub`, `len`, `lower`, `match`, `pack`, `packsize`, `rep`, `reverse`, `sub`, `unpack`, `upper` | `dump` |
| `table` | `concat`, `insert`, `move`, `pack`, `remove`, `sort`, `unpack` | — |
| `math` | every function and constant of the bundled interpreter's `math` except those removed | `random`, `randomseed` |
| `coroutine` | `close`, `create`, `isyieldable`, `resume`, `running`, `status`, `wrap`, `yield` | — |
| `os`, `io`, `package` with `require`, `debug` | — | never opened: absent in full, with no search path, searcher or native loader |

The removal is made on the library tables themselves, once, after they open. The
string metatable's index is the `string` table, the registry's loaded-module table
holds the same tables, and a module's environment reads through to the globals,
so `rawget(_G, name)`, `_G` and `_ENV`, a module's environment,
`getmetatable('').__index` and `('').dump` all find the name absent, and the
`next`/`pairs` enumeration of each table does not list it. `package` and `debug`
are absent, so a script has no way to the registry or to reopen an omitted
library. Granted namespaces cannot bring a name back: the registration refuses
the standard names (`os`, `io`, `load`, `loadfile`, `dofile`, `debug`, `package`,
`require`, `collectgarbage` and the rest). This is about the supplied standard
library: trusted Lua may define ordinary functions or tables with the same
names.

`print` and `warn` keep Lua's stock behaviour under the profile alone: `print`
writes to the process's standard output, and `warn` writes to its standard error
once a script has switched warnings on with `warn('@on')`. Bounded, rebound
script output is a later slice (D-71, LFE-12), not something the profile
delivers; filtering removes the ambient OS functions, not every way a process
writes.

**Errors.** A call to a removed function is an ordinary Lua operation on a
missing value: `pcall` catches it, and later permitted computation goes on. An
uncaught one follows the existing attributed Lua fault path — a `LuaFault` from an
initial chunk, a `BoundaryFault` with a `ScriptFailed` reason from an entry
point — and is not a latched host failure or a new refusal. The profile ships no
random generator and makes no determinism claim; a script that needs one writes
its own seeded one.

**Profile and library list.** A profile owns the owner's whole standard-library
set, so it cannot be combined with an explicit list. A configuration that selects
a profile and also names libraries (`LibraryIo`, `LibraryOs`, `LibraryPackage`,
`LibraryDebug`, or any other) is refused at construction, before any library
opens or authored code runs, with a `BoundaryFault` of operation `OpenLibraries`
and reason `ProfileWithLibraries`, through the same construction failure path as
any other failed step: the VM is closed and the body never runs.

**The protected boundary.** The filtering is one call, `hetoimasia_lua_filter_m1`,
made as a single `lua_pcall` like `hetoimasia_lua_requiref`: the names it writes
are built inside the protected frame, no argument crosses it, and a failure — a
status Lua reports, or a library table missing — is classified like any other
failed call (`MemoryExhausted` for memory, otherwise `CallFailed`), attributed to
the stage `profile LibraryProfileM1`, and ends construction through the same
close. Two independent owners never share a library table, so a profiled owner
cannot receive a capability another owner opens, and opening, using or closing
either leaves the other's surface as it was. The profile adds no dependency and
exposes no Lua state, stack index, registry reference or native pointer.

**What this is not.** Filtering removes ambient OS functions and arbitrary-source
loading. It is not hostile-code containment: a trusted script can still hang its
owner or exhaust the process's memory, and cooperative budgets are not hard
limits. Engine-provided imports, bounded output, a module loader, content roots,
services and the `run` command are later slices; none is delivered by this
profile.

### Modules and entry points

A module is Lua source the application supplies under an identity, a name and a
version (`ModuleSource`); the host reads nothing from disk and searches no path.
It loads at initialization (`vmModules`; a failure ends the lifetime like an
initial chunk) or from the body (`loadModule`), is known afterwards by an opaque
`ModuleHandle` (`loadedModule` gives the body the handle of a module supplied at
initialization, by identity), and a second load under the same identity is
refused: there is no live reload. Source is text only; a precompiled chunk is refused. Each module
runs in an environment of its own (B1): its global assignments are private to it,
and the owner's standard libraries and granted namespaces are visible to it by
reading through to the globals. That is separation of names, not a security
boundary. At most 256 modules, 1 MiB of source, 64 entry points and 128 bytes of
name or version for one module; a name, version or entry point that does not fit
is refused with `NoEffect` before anything runs.

The application declares the entry points, each `Required` or `Optional`, with
schemas for its arguments and results. They are looked up by raw access in the
module's environment, so no lookup metamethod can supply or hide one:

- a required entry point the module does not define as a function fails the load
  with `EntryMissing`, naming module and entry;
- at call time a required one that has gone is a fault, never an absent answer;
- an optional one that is not there answers `EntryAbsent`: nothing runs and
  nothing faults;
- one that is present and is not a function is a fault, required or optional.

### Values

Values cross as bounded copies, in both directions: a binding's arguments and
results, an entry point's arguments and results. A value is nil, a boolean, a
64-bit integer, a float, a byte string, UTF-8 text, a list, a record or a
capability. The rules:

- Integers keep their exact value over the whole 64-bit range and floats stay
  floats. An integer schema refuses every float, an integral one such as `1.0`
  included; a float schema refuses integers; `SNumber` accepts either and keeps
  which it was.
- Byte strings and text are distinct schemas over Lua's one string type, and
  invalid UTF-8 is refused where text is declared.
- A list is a table whose keys are exactly `1..n`; a record is a table whose keys
  are exactly its declared fields, an optional one possibly absent, and an
  undeclared field is refused. Arity is exact.
- Tables are read raw. A table carrying a metatable, even an empty one, is
  refused, so a copy never depends on a metamethod and none runs. A table that
  contains itself is refused as a cycle (sharing is not a cycle).
- A nil cannot be kept in a Lua table, so it cannot cross inside one: a nil list
  element, or a nil value for a record field that is not optional, is refused
  with `RuleNilInTable`; an optional field that is nil is simply absent from the Lua table, though it
  is still inspected and so is charged against the limits like any other value.
- Functions, coroutines, light userdata, and userdata that is not a capability of
  this VM are refused with a typed reason; so is a table key that is neither an
  integer nor a string.

A crossing is bounded by bytes, depth and elements, which together cover all the
values of one call's arguments or one call's results: by default 64 KiB, depth 8
and 4,096 elements, configurable with `vmValueLimits` up to 16 MiB, depth 64 and
1,048,576 elements. Bytes are the size of the copy's encoding (1 for nil and a
boolean, 9 for a number, 5 and the length for a string, 21 for a capability, and
5 and the size of every key and value for a table), depth counts nested tables (a
flat table is 1) and elements count every value of the copy, nested ones included
and table keys not. The reader stops at the first limit it reaches, so the work
it does is bounded by the limits and not by the input; a refusal's `visited`
count is at most the element limit plus one. Each limit is pinned at the limit
and one past it in `Test.Lua.Boundary.Bindings`, `Test.Lua.Boundary.Modules` and
`Test.Lua.Boundary.Values`.

### Handles

A capability is an opaque identity the application hands its scripts: a type it
declared and a key within it, issued by one VM. In Lua it is a userdata with a
shared metatable that hides itself (`getmetatable` answers `false`), and copying
it creates no new authority. Using one is checked every time, before the
binding's action: it must have been issued by this VM (`RuleForeignHandle`), be of
the declared type (`RuleHandleType`), and still be live by the application's own
check for its type (`RuleRetiredHandle`), which runs at every use. A number, a
table with the same fields or a string with the same contents is not a handle and
is refused as the wrong kind of value. A module handle carries the identity of
the VM that issued it: another owner's is refused (`ModuleHandleForeign`), and
after the lifetime every use is `VmClosed`, as for the VM itself.

A handle the application's check reports retired is refused by every binding before its action
runs, with one exception: an explicit release (`releaseOperation`, below and in
[Instance leases](#instance-leases)). It is declared with the one capability type it releases and
takes that handle as its only argument, so it is run for a handle whose lease has ended and for
nothing else. The handle is still checked for being issued by this VM and of that type, and a
retired handle of another type, or given to any other binding, is refused as before.

### Calling a binding

A Lua call to a delivered binding is, in order: the kind is checked (a binding of
a kind not yet delivered is a `NotYetSupported` fault, decision A1); the argument
count is checked; the arguments are read into a bounded copy; the copy is checked
against the schemas, capabilities included; the action runs with copies and
nothing else — it receives no `OwnedVm`, no Lua state and no handle to its own
VM, so running Lua on or closing its own VM is refused with `VmReentered` and
using another owner's VM with `VmNotOwned`; its results are checked against the
result schemas and encoded under the limits; they are built in Lua. #460's rules
for trusted callbacks hold: the callback thread's identity is published nowhere
and nothing is left running past the action's return.

A refusal is a **fault of the call** (decision C1): the binding does not run for
a refused argument, and the owner's operation raises a typed `BoundaryFault`
naming the binding, the argument and the rule, even if the script caught Lua's
side of it with `pcall`. Refusing a result necessarily follows the action, and is
just as observable. A Haskell failure raised by the action itself keeps #460's
contract and is not converted: it is re-raised at the owner's boundary with its
own type and context.

### Fault evidence

A `BoundaryFault` is an ordinary Haskell exception, produced with no Lua run to
render it. It records the owner (by the name it was configured with, and the
VM's identity), the operation (`InstallBindings`, `LoadModule`, `CallEntry`,
`CallBinding`, and for a task `StartTask`, `ResumeTask`, `CloseTask`), the module's name and version and the entry point when a module
was running, the binding's namespace and name, the source chunk the call was made
from, a bounded traceback when one was captured, a typed reason, and an `Effect`:

| Effect | Meaning |
|---|---|
| `NoEffect` | refused before any Lua or binding action ran |
| `LuaRan` | Lua had run in the operation; no binding action had |
| `BindingRan` | a binding's action had run: application state may have been changed |

The effect is the one the operation ended with, not the one at the first fault: a
refusal the script caught is the operation's failure, and if a binding's action
runs after it the fault says `BindingRan`. The module and entry point are named
only when the call was made from that module's own code; a fault raised by
another module's `__gc` finalizer while an entry point runs names the chunk that
made the call and no module.

The traceback is built from the debug interface's call records alone
(`lua_getstack` and `lua_getinfo`; not `luaL_traceback`, whose function-name
lookup reads the registry through metamethods), so no script-defined Lua can run
while a fault is recorded, and it allocates nothing; it is bounded at 2,048 bytes
and 22 levels. The close is an operation of its own: a fault recorded while
finalizers run names no module or entry point and counts only the actions run
during the close. A non-string error value, or one whose handler
failed, is reported by the existing bounded fallback (its Lua type name, never its
`__tostring`). A fault never claims that recovery is safe: whether state may have
changed is exactly `Effect`, and task and session identities arrive with later
slices.

### Phases that execute nothing

Allocating in Lua can start a collection step, and a step can run pending `__gc`
finalizers: script-defined Lua that can call bindings. So the collector is held
(stopped, and given back as it was found: a script that stopped it itself keeps it
stopped) across every host-side phase — reading arguments, building results, the
entry-point lookup, the set-up of the boundary's registry share, and a module load
up to the moment its chunk starts. What the held collector owes is paid by the
next script phase: giving the collector back clears its debt, so the bytes a held
phase allocated are kept as owed and paid as one step of that many kilobytes where
script code may run — when a module's chunk starts, just before an entry point is
called, and when a binding returns to its script — and a loop of crossings whose
script phases allocate nothing cannot grow the heap without bound. The lookup
itself walks the module's environment comparing keys in place and allocates
nothing; calling a C function can still grow the stack and start a step, so it is
held too. Consequently:

- looking an optional entry point up that the module does not define answers
  `EntryAbsent` having run no Lua, finalizer, binding action or application
  callback, and arguments are not even validated (the lookup comes first);
- a load rejected before its chunk starts (a precompiled chunk, a syntax error, an
  allocation failure while parsing) is `NoEffect`, because nothing executed; a load
  that fails after the chunk started says what ran (`LuaRan` or `BindingRan`).

### Registry, stack and memory discipline

Every operation leaves the stack at the depth it entered at, on every path: a
call, a refusal, a script's error, a failed load. A loaded module holds exactly
one slot of a table the bridge keeps in the registry, for the owner's lifetime,
and the close releases it. Failed loads, calls and refusals retain nothing. The
slots are not `luaL_ref` references, so `probeReferenceSlot` stays where it was
whatever is loaded; the live count is read from the table itself
(`liveModuleReferences`), and `Test.Lua.Boundary.Discipline` checks both across
more than a thousand calls, refusals and faults, and across repeated successful and
failed loads.

Memory running out at any step of installing, loading, calling or marshalling in
either direction, inside a callback included (a stack that cannot be reserved
for a copy counts), is the existing classified
failure — `MemoryExhausted` as a `LuaFault`, or a `BoundaryFault` whose reason is
`ScriptFailed MemoryExhausted` — never a panic, a Lua error unwinding through a
Haskell frame, or a leaked reference. The guarantee is for the recoverable
allocator failures Lua reports; an operating-system failure to obtain memory at
all is outside it. A failed *initialization* closes the VM and never enters the
body; "the state is usable afterwards" applies only to failures caught inside an
initialized owner's body. The registration itself is plain Haskell, built outside
the owner, so `ownerBudget` (which limits the interpreter's allocator) covers its
installation in the VM and not its construction.

### What proves it

`Test.Lua.Boundary.*`, under the `value boundary` selector of the suite:
registration (names, bounds at the bound and one past, eligibility, shadowing);
values without an interpreter (the encoding, the limits, the schemas); bindings
called from Lua (every rule above, the limits at the limit and one past with
input far larger than the limit, results, `pcall` cases for the settled
decisions, handles, `VmReentered` and `VmNotOwned`, an action's own failure);
modules and entry points; the finalizer allowlist (`__gc` finalizers reaching an
eligible binding, an ineligible one, an allowlisted lifecycle binding, also for an owner configured to
deliver lifecycle operations); lifecycle operations delivered to an owner with a lifecycle context and
refused, their action never run, to one without;
independent owners on separate threads with different policies; installation;
discipline, with the allocator's budget swept across installation, loading,
calling and marshalling; and the dependency closure. `Test.Lua.Opacity` adds
negative clients that forge a handle or a capability, reach for a binding's
closure or for a Lua state, and a positive client built from the public modules
alone that constructs a registration and an owner's policy, loads a module, calls
an entry point and observes a typed refusal.

## Tasks and the coroutine library

Tasks (LUA-20; design P-5, P-6, D-12, D-13, D-22, D-29; Q-3) are the host's
mechanism for script code that gives control back: a module's entry point run as
a Lua coroutine of its VM, on the VM's owner, a segment at a time. This is the
mechanism and nothing else. The scheduler that decides when a task runs, what a
deadline or a tick is, and in what order (LUA-21), and the supervised owners that
use both (LUA-6, delivered in `runtime-lua`), are separate slices; no clock, timer, queue or policy is here,
and the examples resume a task by hand.

### What a task is

```haskell
startTask  ∷ OwnedVm → ModuleHandle → Text → [Value] → IO TaskStart
resumeTask ∷ OwnedVm → Task → IO TaskStep
closeTask  ∷ OwnedVm → Task → IO ()

data TaskStart = TaskEntryAbsent | TaskStarted Task TaskStep
data TaskStep  = Completed [Value] | Yielded | Waiting WaitRequest
data WaitRequest = WaitRequest
  { waitKind ∷ WaitKind, waitNamespace ∷ Text, waitBinding ∷ Text, waitArguments ∷ [Value] }
data WaitKind  = WaitElapsed | WaitLogical
```

`startTask` checks the handle, the entry point and the arguments exactly as
`callEntry` does (the same code), and runs the entry point as a coroutine up to
its first yield, wait or return. An optional entry point the module does not
define answers `TaskEntryAbsent` and executes nothing, as an absent entry point
does for a call. Each segment ends in one of three ways: the entry point
returned, with results checked against its declared schemas and the owner's
limits like a call's (`Completed`, after which the task has ended); the script
yielded (`Yielded`); or it waited, and the host reports which wait and the
arguments it gave (`Waiting`). Resuming goes on from there with no values, and the
operation that suspended returns nothing to the script.

A task is a Lua thread of the owner's VM, kept in a table the bridge owns in the
registry, one slot per task, until it ends, so that the collector cannot take it
while the host holds its handle. Starting, resuming and closing are operations of
the VM like any other: held under its gate by its one execution owner, refused
from another thread with `VmNotOwned`, from one of the VM's own callbacks with
`VmReentered`, and once the VM has closed with `VmClosed`. The `Task` is a value
naming a slot of one VM, checked on every use: another owner's is refused with
`TaskRefused TaskForeign`. It is never a `Value`, so no task, thread or coroutine
can cross the boundary, and Lua never sees one. A task that has returned, failed
or been closed cannot be resumed: `TaskRefused (TaskEnded TaskCompleted |
TaskFaulted | TaskClosed)`, with `NoEffect`.

The host keeps no count of tasks and imposes no cap on them: how many an owner
runs, and when, is the admission of the scheduler that uses this. Every
suspended one is closed when the VM closes.

### Yielding and waiting

A script gives control back through a **scheduler operation**: a binding of the
application's registration, in a namespace the owner's policy grants, like any
other (D-22: there is no universal environment, and a script that is not granted
one has none). Two constructors make them, and the application chooses the names
and, for a wait, the argument shapes:

```haskell
yieldOperation ∷ Text → Binding                          -- no arguments
waitOperation  ∷ Text → WaitKind → [Schema] → Binding    -- WaitElapsed | WaitLogical
```

Neither runs application code. A wait's arguments are checked against the schemas
it declares and the owner's value limits like a binding's, before anything is
suspended: a wrong type or count, or an argument past a limit, is a typed fault of
the call (`ValueRefused ... Arguments`), and the task is not suspended. Accepted
ones are reported as they are in `WaitRequest`; the host interprets none of them.

A scheduler operation is a *handler decision and a C action*. The handler runs in
Haskell like any binding's and decides whether the call can reach the scheduler at
all; it records what the script asked for on the VM and returns. The C closure of
the binding then calls `lua_yield`, after every Haskell frame has returned. That is
the rule the error protocol already follows, for the same reason: `lua_yield`
unwinds with a `longjmp` exactly as `lua_error` does, and a `longjmp` through a
Haskell frame is undefined. The coroutine yields no values and is resumed with
none, so what the script asked for travels in the host's record and never as a Lua
value.

#### Where it cannot reach a scheduler

A scheduler operation called anywhere the host is not resuming the calling
coroutine is refused as a typed fault of the call (decision C1), not run: it never
suspends something nobody will resume, and never yields to the wrong resumer.
Like every refusal it is raised at the owner's boundary even if the script caught
Lua's side of it with `pcall`.

| Called from | Reason (`SuspendRefused`) |
|---|---|
| a finite `callEntry`, an initial chunk, a module's load, a finalizer on the owner's main thread, a to-be-closed variable's handler while its coroutine closes, a close, another owner's VM | `SuspendOutsideTask`: the host is not running a task of this owner |
| a coroutine the script created with the `coroutine` library, while a task runs | `SuspendOtherCoroutine` |
| the task's own coroutine inside a table-sort comparator, a pattern-replacement callback, or a finalizer it happens to run on: anywhere Lua cannot suspend it | `SuspendNotYieldable` |

Lua can suspend across `pcall`, `xpcall` and a metamethod called from Lua code,
and so a scheduler operation works there. A coroutine that yields with *no*
scheduler operation, by calling `coroutine.yield` itself at the task's top level
(directly or through `pcall`), would be suspended to no one; that is
`UnscheduledYield`, a fault of the segment, and the task is closed. A script that
resumes the task's own coroutine by hand leaves the host's next resume with
`TaskRefused TaskNotSuspended`. If that coroutine died holding to-be-closed
variables the host closes it, which runs them: their failures are cleanup
evidence, and the fault's `Effect` says what ran (`BindingRan` if a binding's
action did, `LuaRan` if the coroutine could have held something to run, otherwise
`NoEffect`).

### The `coroutine` library

`LibraryCoroutine` is selectable like the other standard libraries, so trusted
code can use coroutines for transient sequences inside a task (P-5, D-22). Every
existing library set and default is unchanged: opening it is the owner's explicit
choice, and the opener is the C library's own. Lua coroutines are not serialized
or migrated: authoritative long-lived progress uses explicit state. A coroutine a
script makes is the script's own and is still refused as a value
(`RuleUnsupportedType "thread"`); a scheduler operation inside it is governed by
the table above.

### Faults in a segment

Whichever segment fails, it fails as a typed `BoundaryFault`, with the module and
entry point (the run context is set for every segment), the operation, a bounded
traceback, a reason and an `Effect`:

- a script error is `ScriptFailed CallFailed`, exhausted allocation
  `ScriptFailed MemoryExhausted`, with `LuaRan` (`BindingRan` after an action);
- a result the schema does not allow, or the wrong number, is `ValueRefused` on
  the results; an argument a binding is called with is `ValueRefused` on the
  arguments, as a fault of that call; both exactly as `callEntry` raises them;
- a Haskell failure a binding's action raised is re-raised unconverted with its
  own type and context, as `callEntry` re-raises it.

**A failure the script caught still wins.** At every boundary of a segment,
completed, yielded and waiting alike, a refusal the boundary made or a failure of
application code that reached a callback is raised in preference to what Lua
reported, even when the script caught the stand-in with `pcall` or
`coroutine.resume` and went on to yield, wait or return; the host reports the
failure and never a successful suspension, with its type, context and applicable
`Effect`. This is `callEntry`'s precedence, applied at each boundary a segment can
end in.

**A segment that fails leaves nothing.** The coroutine is dead and its stack
intact, so the host builds the traceback from it, then closes it, running its
pending to-be-closed variables (Lua's own `coroutine.wrap` does the same), and
empties its slot: the task has ended (`TaskEnded TaskFaulted`). The close is a
step of its own, apart from the segment, so what it raises is never mistaken for
what the segment did: the segment's failure (a Haskell failure that reached a
callback, else the script's error) is the one raised, and every Haskell failure a
to-be-closed variable's callback raises while the coroutine closes, with its own
type and context, and any error of Lua's other than the one the segment died
with, is kept beside it as cleanup evidence (`lua coroutine close`), bounded like
the finalizers' (64, with one further entry saying how many were not kept).
Nothing is lost because two failures look alike to Lua: they both reach it as the
same placeholder (a light userdata that no script can build), and the host keeps
the originals; an error of any other kind, a table included, is the script's own
and is always reported. A binding's action that runs after a refusal the closing
code caught upgrades the `Effect` of every failure kept this way, as it does the
pending one.

### Closing a task

`closeTask` runs a suspended task's pending to-be-closed variables on the owner's
thread and empties its slot. The close is terminal and idempotent: the task is
closed whether or not a variable's handler failed, a failure is raised as a
`BoundaryFault` of `CloseTask` (`ScriptFailed CallFailed`; a Haskell failure a
handler's callback raised outranks it, and when several fail the first is the
failure and the rest are cleanup evidence) once and not again, a second close
does nothing, and a task that already ended is closed already. A scheduler
operation inside a handler that runs during the close is refused
(`SuspendOutsideTask`).

A VM that closes with tasks still suspended closes each of them first, before the
state, in the order they started. Each is attempted whatever another does, on the
owner's thread, with everything its callbacks borrow still alive; a callback a
handler reaches is held to the finalizer allowlist exactly as a finalizer's is, so
one the allowlist does not name is refused (`lua finalizer refused`) and an
allowlisted one runs. A failing close is retained as evidence under `lua coroutine
close`, in the exit matrix above, and the rest still close. A cancellation of the
owner is deferred past all of it as it is for the close, so a cancellation that
arrives in the middle of a resumed segment is delivered after the segment's
bookkeeping, the suspended tasks are closed, and the original asynchronous
exception is what the owner raises, with their failures on it.

### Stack, registry and memory

Every operation restores the stack depth it entered at, on every path. A task's
slot is emptied when it ends, however it ends, so the registry holds exactly the
suspended tasks and nothing else; the slots are not `luaL_ref` references, so
`probeReferenceSlot` and `liveModuleReferences` do not move, and
`liveTaskReferences` counts what is suspended. Creating a coroutine is one
protected call with the collector held, so running out of memory there is a typed
`ScriptFailed MemoryExhausted` of `StartTask` with `NoEffect` (nothing executed),
and the allocation it needed is paid when the task first runs, as for a call.

### What proves it

`Test.Lua.Boundary.Tasks`, under the `value boundary` selector: start, yield,
resume and complete; a wait of each kind with its exact request and arguments,
resumed by hand, and malformed and over-limit wait arguments; a script error, a
refused value, an exhausted allocator and a binding's failure in a resumed
segment; a refusal and a failure caught by `pcall` or `coroutine.resume` and
followed by a yield, a wait or a return; closing, with a failing handler,
repeated, and after the task ended; resumption of an ended or foreign task;
refusals from a finite call, an initial chunk, a module load, a finalizer, a
script-created coroutine and the places Lua cannot suspend; the library selected
and used inside a task, and a coroutine still refused as a value; stack, registry,
tasks and heap across a thousand cycles of every shape and across allocation
failures swept to the creation of a coroutine; the VM closed with suspended
tasks, with a failing close, a refused callback and the allowlist; cancellation
inside a resumed segment with several tasks suspended, delivered by coordinated
blocking and never by sleeping; foreign-thread and re-entrant use; and two tasks
on one VM keeping separate continuations and faults.

## The runtime adapter

The runtime adapter (LUA-5; design D-12 to D-15, P-1, P-3, P-5, P-7 to P-9,
P-12) puts trusted VM owners under runtime supervision. It is the public
`runtime-lua` sublibrary of this package, in its own source directory
(`runtime-lua/`), and its one public module is
`Hetoimasia.Scripting.Lua.Runtime`.

It depends on the host library, the private `model` and, only where it must, the
private `bridge`, on `hetoimasia-runtime` and on `hetoimasia-foundation`, and on
nothing of GLFW, Vulkan, the console or a game. The host library gained no
dependency, and `Hetoimasia.Runtime.Inbox` is neither used nor changed: its
already-initialized startup handoff is not what a VM owner needs, and P-3 says not
to weaken it. The bridge is named for three things no public host module offers:
the process-wide record of the threads running a Lua callback, the mark a failure
of application code carries, and the value limits' check. The model supplies the
validation of the two caps the adapter has (below). `Test.LuaRuntime.Dependencies`
reads the stanza and the imports of the adapter's modules to check all of this,
without a VM.

One owner is one supervised worker. There is no pool, no scheduler across owners,
no thread or timer of the adapter's own, and no new supervisor (a scheduled owner,
below, is the opt-in owner that serves tasks, and shares none of this adapter's
queue): it composes
`withVmOwner` with `startSupervised`, `workerDefinition` and `awaitSupervised`.

### Creation and readiness

A `LuaRuntime` is made over the `RuntimeControl` of one `withSupervision`
invocation (`newLuaRuntime`). `startLuaOwner` takes it, an `OwnerSpec` and
answers an `OwnerStart`. The spec is the host's `VmConfig`, a `WorkerPolicy` the
application chooses, and the two bounds, `CallBounds`.

Creation checks the bounds first, and a bound below one raises
`OwnerBoundsRefused` naming every violation before any worker starts or VM is
built. It then issues the owner's identity and starts exactly one worker. The
worker's `Scoped` startup allocates only the owner's bounded queue and counters.
Constructing the VM, installing the registration's granted bindings, running the
initial chunks and loading the configured modules all happen inside `withVmOwner`
on the worker's own thread, which is therefore the VM's execution owner. Only then
does the body publish readiness and open admission, in one transaction, and only
then is an endpoint handed out.

Readiness is awaited by one `awaitSupervised` wait, composed with the worker's own
terminal status. The acknowledgement `startSupervised` waits for means only that
the startup finished, and the creator never treats it as readiness: a slow initial
chunk is in progress after `startSupervised` has returned and before creation
does. A failure of initialization, whether a library, a binding installation, a
chunk, a module load or a policy naming an unknown namespace, ends creation under
the owner's policy, and nobody is left waiting. A required owner's failure is
raised by supervision as any worker's is. An optional owner whose classifier
recognizes it answers `OwnerUnavailable`, its status committed and the run
continuing. At handoff admission is checked still to be live; an owner that ended
without failing answers `OwnerEnded`, and a closed boundary `OwnerRejected`.

Acquisition is masked from the worker's start to the endpoint's handoff, with
only the readiness wait restored once the stop request is armed, so a cancellation
cannot fall between the worker's start and that request, nor between the end of the
wait and the handoff. A creator whose wait is abandoned, cancelled or woken by
another worker's fatal outcome, asks the owner to stop. The worker group still owns the worker and
drains it, and no detached helper exists. Creating an owner waits for readiness,
so it is refused from a Lua callback (below).

### Identity

Each owner is issued an `OwnerId` by the `LuaRuntime` that created it, once and in
order, and an identity is never issued again, including after the owner retires.
The runtime boundary an identity is unique within is that `LuaRuntime` value: make
one for each `withSupervision` invocation. Two runtimes never issue equal
identities, even when their sequence numbers agree. The endpoint, every
settlement and the exit record carry the identity beside the application's label,
`vmOwnerName`. Neither confers trust or a grant: an owner's authority is exactly
its configured `vmPolicy`, and two owners of one label with different policies
keep the bindings of their own. The model's own two-valued `ExecutionDomain` is
D-1's composition for LUA-8 and limits nothing here; the adapter's identity wraps
nothing of it and changes none of its examples.

### Submitting calls

An `OwnerEndpoint` submits a call to an entry point of a module the owner loaded
at initialization, named by its `ModuleRef`, with `[Value]` arguments. It is a
value usable from any thread, including a binding's action on this owner or on
another, and it never needs the `RuntimeControl`. Modules come from the owner's
configuration: nothing loads one through the endpoint after readiness.

`submitCall` never blocks. It answers `CallAccepted` with a `CallTicket`,
`CallFull` or `CallClosed`, the foundation channel's `Accepted`, `Full` and
`Closed`, and a full or closed answer changes nothing. Closed takes precedence.
Two bounds, both configuration, both at least one:

- `boundQueuedCalls` is how many accepted calls may wait for the owner's thread to
  start them. The call that is running is not queued.
- `boundResults` is how many results may be reserved at once. A reservation is
  taken, atomically with the enqueue, as a call is accepted, and held while the
  call waits, runs, and sits settled but not yet observed. So a result always has
  a place before its call runs, completion needs no capacity of its own, and the
  unobserved results are bounded however slowly they are read.

Submission answers full when either bound is reached. The private model's
`validateLimits` checks the two caps, `maxQueuedAdmissions` and
`maxRetainedResults`, which mean exactly this; its other caps belong to later
slices and are held at the smallest valid value. No maximum is imposed beyond what
memory allows.

An owner that has been asked to stop admits nothing from that moment, whether or
not its thread has got as far as acting on the request: a call held inside a
binding does not keep admission open.

The payload is prepared on the producer's thread before publication.
`prepareCall` evaluates the arguments completely there, so a failure nested in a
lazy value is raised in the producer, and the owner's thread is handed nothing
unevaluated. It checks them against the owner's value limits as it goes and stops
at the first limit, so an endless or oversized argument list costs no more to
refuse than a small one, and none of it is kept. What is kept of an accepted call
is compacted as well: every string in it, its values' and its routing strings (the
module's name and version and the entry point's name), is copied to a buffer of its
own, so a short slice never keeps the larger buffer it was cut from alive while the
call waits, and a capability type name or routing string longer than any valid one
is cut to one character past the longest valid one, which can only be refused, and
is as much of it as a refusal will quote. A call whose arguments were over
the limits is accepted like any other, carries only the rule they broke, and
settles in its turn as the same `ValueRefused` fault the argument check raises,
with `NoEffect`. Preparing is separate from `submitPrepared`, so the three-way
answer never evaluates anything. The schema and capability checks still happen on
the owner's thread, under `callEntry`'s own contract.

### Settlement

Calls run one at a time, to completion, on the owner's thread, in the order they
were accepted, through `callEntry` with that module's handle. There are no
coroutine yields, tasks, deadlines, timers or providers here (the host's tasks
exist, but this adapter does not use them until the slices that schedule them). Each accepted call
settles exactly once, as one of:

- `CallReturned`, with the entry point's `CallResult`, `Returned` values or
  `EntryAbsent`;
- `CallFaulted`, with a fault of the call returned to its caller as data:
  `ScriptFailed` (a memory failure included), `ValueRefused`, `NotYetSupported`, a
  missing entry point, all as the `BoundaryFault` or `LuaFault` they are, and
  `ModuleNotLoaded` for a `ModuleRef` the owner did not load, which settles with
  `NoEffect` and runs nothing. The owner goes on serving the next call, and none
  of this is a worker failure;
- `CallDiscarded`, when the owner exits before the call settles, recording how it
  exited (`ExitStopped`, `ExitFailed` or `ExitCancelled`) and whether the call had
  started.

A call that had started may have run Lua and the application's bindings, so its
effects may be real; a discard never claims otherwise, and only a call that never
started is known to have done nothing. The failure that ended a failed owner goes
only to supervision: no caller receives the exception or a rendering of it.

No path settles a call twice, loses an accepted call or lets a late result
overwrite a settlement, including a submission that races stop, failure or
cancellation. A call the owner has dequeued is marked in flight in the same
transaction, and its settlement and the clearing of that mark are one more, so a
call is always queued, in flight or settled.

### Observing results

`pollCall` reads a settlement without blocking. `waitCall` waits for it on any
thread that is not running a Lua callback, and `awaitCall` waits on the
application thread, composed with `awaitSupervised`, so a worker's terminal
outcome is handled first and a fatal one is raised rather than waited out. Every
accepted call settles, so a wait ends once the owner has run the call or exited.

Reading a settlement is observing it. The first read that finds one gives the
reservation back, and every later read answers the same settlement and gives
nothing back, however many threads read it at once. `forgetCall` withdraws
interest: a settled call gives its reservation back at once, an unsettled one when
it settles, and the ticket can still be read. A ticket nobody observes or forgets
keeps its reservation, which is what bounds the unobserved results.

None of these is a transaction, and the adapter exposes no primitive a callback
could block on.

### Waiting from a callback is refused

A thread running a binding's action or any other Lua callback, of this owner or of
any other VM, may submit calls but may not wait for a reply, its own owner's
included: it would be a synchronous call into a thread that may be waiting for it
(D-13). `waitCall`, `awaitCall` and `startLuaOwner` check when they execute, and
raise `CallbackWaitRefused` naming the operation (`wait-call`, `await-call`,
`start-lua-owner`) at once. They never block, so a wait action built earlier
outside the callback is refused the same way when the callback runs it.

The detection is a process-wide record of the threads running a callback, kept by
the bridge's callback entry, so it covers the callbacks of a VM that was created
outside the adapter and the application's own capability-liveness checks, which
run as callbacks too. It answers a boolean to the adapter and publishes no thread
identity to application code. A thread a callback starts is not a callback thread,
and nothing detects it: that stays outside the contract, as it does for the VM's
own re-entry check.

### Host failures and policy

A Haskell failure raised by a binding's action or by the application's liveness
check, or any other exception escaping the owner, including one escaping the VM's
close, ends that owner's worker. It is the worker's primary outcome with its own
type and context, the VM's close failures are retained beside it as cleanup
evidence, and the adapter neither converts nor retries it. What follows is the
owner's `WorkerPolicy`, as for any worker: an optional owner whose classifier
recognizes the failure becomes `WorkerUnavailable` and every other owner goes on;
every other outcome is fatal. A retained cleanup failure is always fatal, whatever
the policy, so a recognized failure whose VM close also failed is `WorkerFatal`
with the close evidence on it. A normal stop and a requested cancellation keep
their usual supervision treatment.

A failure is the host's by where it was raised, not by its type. A binding's action
can throw a `BoundaryFault` or a `LuaFault`, and those are still the host's
failures. The bridge marks a failure where it escapes application code, as an
annotation on the exception's context, and the adapter reads the mark and not the
type: an unmarked `BoundaryFault` or `LuaFault` is a fault of the call, settled as
data, and a marked one ends the owner. The exception keeps its type and value. When
a script catches a refusal the boundary made and then calls a binding whose action
fails, the application's failure is the one the owner's boundary re-raises; in
every other case the first failure of an operation is the one kept.

### Stop, retire and the exit record

Stopping an owner, through `retireOwner`, `stopSupervised`, or the boundary
closing, closes admission first, so later submissions answer closed. The owner's
thread then lets the in-flight call return with its own settlement, discards every
queued call as not started and stopped, and lets `withVmOwner` close the VM on the
worker's thread. Retiring an owner is stopping its worker, and owners are created
and retired while others run.

The same discarding happens on every other exit, a failure of the application's
code and a cancellation included, with the way the owner exited recorded. In every
case admission closes, and what had not settled is discarded, before the VM begins
to close, because closing can block for as long as a finalizer runs and no call may
be accepted meanwhile. The in-flight call of a failed or cancelled owner is
discarded as started.

The `ExitRecord`, read through `ownerExitRecord` once the owner has exited, names
the owner's identity and label, how it exited, and counts the discarded calls, those
that had started and those that had not, separately. It carries no cleanup
evidence: that is supervision's, as the model's own `ExitRecord` keeps the two
apart. A stuck in-flight call keeps the worker, its VM, the registration and the
binding dependencies live, because nothing is detached and the boundary's drain
still owns the worker.

### What proves it

The adapter's examples are their own suite, `lua-runtime-tests`, in the
`runtime-lua-test/` source directory, beside the host's suite and leaving its
examples unchanged. Every execution and lifecycle example acquires real VMs under
a real `withSupervision`; the structural checks need no VM. They are coordinated
with gates the bindings open as they are reached, never with sleeps. Cancellation
and shutdown windows are the kind an asynchronous-exception race can hide on one
platform, so CI, which runs them on Linux, is the evidence for them and a local
pass is not.

An example that parks a callback at a gate (`fx.block`, `app.block`, `holdOwner`, a host
callback) must fail, and fail within its 60-second `bounded` limit, whatever way it ends
between the hold and its own release: the boundary's protected teardown waits for the
callback a held gate holds, so a gate nothing opens turns a failed assertion into a hang
until an outside deadline. Such an example runs its boundary through `withBoundaryOpening`
(`expectFatalOpening`, `tryBoundaryOpening` where it expects the boundary to fail, and
`alongsideOpening` where a helper thread acts) with the fixtures it parks callbacks at.
When the body ends by raising anything, every gate of those fixtures is opened inside the
body, the ones made so far and the ones a callback first arrives at later, before the
teardown begins; and when the example's bound expires, `bounded` opens them from a thread of
its own, because an example parked in the runner's protected retirement cannot, and the
exception the bound throws does not end that wait. A helper thread that fails opens them too,
and the example fails with the helper's failure. The passing path is untouched: each example
still opens each gate where it opens it. The `Gates` examples hold these helpers to that.

An example that expects the boundary, or a wait, to fail must not take its own failure for the
one it expects. Every helper that catches the failure (`expectFatal`, `expectFatalOpening`,
`tryBoundaryOpening`, `tryExpected` which the others are built on, and the accounting examples'
`failingWait` and `retainedFailure`) raises a failed assertion, or the example's `bounded`
timeout, as itself: the example fails with the assertion's own message and source location,
within its bound, and the helper answers no outcome and runs nothing after it. What it still
answers is the application's own failures: a typed one such as `Broken`, an injected
`userError` or other `IOException`, and the supervised fatal outcomes with their context and
retained cleanup evidence. So a helper or an example that asserts raises `failExample`, an
`HUnitFailure` carrying the caller's location, and never `fail` or a `userError`, which a
helper cannot tell from an application failure an example injected. An optional worker's
`optionalPolicy` does not recognize a failed assertion either, whatever else it recognizes, so
one a fixture raises on the worker is fatal. A catch that wraps only one production call, with
no fixture or assertion of the example inside it, may stay a plain `try`. The `Expected` examples
hold each helper to this, for an assertion raised in the boundary (the example's own and a fixture
helper's) and for the bound expiring.

```bash
cabal test hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct
```

The script runner's examples are the `Runner` component of that suite, and a selector that matches none fails the suite:

```bash
cabal test hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct --test-options='--match Runner'
```

It also runs under `--project-file cabal.project.cpu`. The validation group is
`test.scripting-lua-runtime`, non-optional, routed with `test.scripting-lua`; see
[docs/validation.md](../../docs/validation.md).

## The scheduling machinery

`Hetoimasia.Scripting.Lua.Scheduler` (LUA-21, in the `runtime-lua` sublibrary) is the
reusable machinery one owner needs to choose, under a policy, which of its ready
tasks runs next; to give each service class a bounded turn; to keep logical time
that only the application advances, and elapsed deadlines behind one owned timer;
to apply pause, resume and stop at safe boundaries; and to count what it did. It
starts no thread, owns no VM and supervises nothing. It runs a task's segment and
closes a task's continuation through the two actions of a `TaskHost`, so it is
exercised against scripted segment outcomes and is independent of how coroutines
come to exist (LUA-20). The scheduled owner that hosts it on a supervised worker with
real VMs is LUA-6, below; the finite-call adapter above is unchanged. Its module imports
nothing of the VM, the bridge, the registration, supervision, GLFW, Vulkan, the
console or a game: only `base`, the foundation's clock and the protocol model, and
`Test.LuaRuntime.Scheduler.Structure` reads its imports to check that.

### How it is used

An application makes a `Scheduler v` over tasks that carry values of type `v`
(`newScheduler`), and calls its producer operations from any thread. Each is a
transaction that never blocks and answers at once: `admitTask`, `grantStep`,
`requestControl`. The owner's thread loops: `awaitWork`, which composes admissions,
control requests, grants, the timer's wake and the owner's stop request in one STM
wait so that an idle owner sleeps in one place and nothing polls; then
`serviceTurn`; and on its way out, under mask, `stopScheduler`. Only the owner's thread
calls those three, and a turn is not reentrant.

The waits that are for other threads, `awaitStepsComplete` and a ticket's
`awaitControl`, are transactions an application composes with `awaitSupervised`. They
are the application's: nothing here is reachable from Lua, and a Lua callback must not
call them, for the reason the finite-call adapter refuses a reply wait from one. A
task waits by yielding to its owner's scheduler, never by blocking its owner's thread.

### Configuration

`SchedulerBounds` holds the active-task, queued-admission and retained-result caps,
the three quanta, the bound on outstanding grants, the bound on control requests and an
optional elapsed service budget. `newScheduler` checks all of it before anything is
made, and answers every violation at once: the caps and quanta through the protocol
model's own `validateLimits` (a quantum below one is refused), a grant or control
bound below one, and a budget that is not positive. A refused configuration
creates no timer and no state. The caps the scheduler does not use are held at one,
as the finite-call adapter holds the ones it does not use.

### Policies

Each scheduler takes a `Policy` at creation and keeps it for its life. A policy
chooses which ready task runs next and nothing else: admission and capacity, the class
pass and its quanta, control and stop, the timer, the settlement of results and
ownership all stay with the runtime, under every policy, and none can be bypassed from
a policy. `fifoPolicy` is the supplied default; the extension interface is
`PolicyView` (the class whose opportunity it is, and every ready task with its class,
kind, `Ordinal` and segment count, in `Ordinal` order) and `Candidate`. There is no
other built-in policy and no live policy change.

How the runtime guarantees a policy cannot starve a class, control or stop: the
runtime offers a policy an opportunity for one class at a time, and a choice must be a
ready task of that class. Anything else (a task that is not ready, one of another
class, one that does not exist) is refused, counted in `diagRefusedChoices`, and
never run: the oldest ready task of that class runs instead, so a policy that cannot
choose cannot stall its owner. When a class has used its quantum or has nothing
ready the pass moves to the next class whatever was chosen, and control requests and
stop are served between segments, before the policy is asked again. What a policy
can still do is order the tasks of one class, which includes starving a peer in it,
and that is bounded only by the class's quantum. A policy that raises is a failure of
the host and propagates from the turn, before anything is changed.

### Service classes, quanta and turns

Every task belongs to `ControlClass`, `OrdinaryClass` or `BackgroundClass`. Each class has a
finite quantum of segments. The /pass/ visits the classes in that order; each class with a
ready task runs at most its quantum of segments before the pass moves on, so no task, of
any class, gets more than its class's quantum while a peer in another class is ready. A
/turn/ (`serviceTurn`) runs the pass until it completes, the owner is idle, the budget has
expired or the owner has been asked to stop.

The position in the pass, and how much of the current class's quantum is used, belong to
the scheduler and persist across turns. A turn that ends early, at the budget, continues
the same pass in the next: it never restarts at the control class or replenishes a
quantum, so where a budget cuts a pass moves where turns end and nothing else. The pass
starts afresh when it completes and when nothing at all is ready.

Under `fifoPolicy` the ready tasks of a class run in `Ordinal` order. The model issues an
`Ordinal` at admission and again whenever a task rejoins the ready set, so a yielded,
woken or resumed task is behind everything already ready, and waiting and paused tasks
occupy no turn.

Admission records a `TaskKind`, looped or one-shot. The kind is visible to a policy and
the diagnostics and the runtime never acts on it, so where a one-shot is placed is the
selected policy's: the default appends it at its class's tail like any other task.
Admission reserves the task's result storage in the model's session, as the model
documents, and a finished task keeps its slot and reservation until `observeTask`
takes its result.

### Logical time

The logical tick advances only when the application grants a step with a positive
TIME-1 `Duration` (`grantStep`). A round of scheduling, an elapsed deadline and an expired
budget never advance it.

Accepted grants are applied in the order they were accepted, one tick each, none skipped
or coalesced, and a grant is applied only when every earlier one has finished, so the
logical timeline is strictly sequential and what runs depends on the grants and never on
when they arrived. Applying one adds its duration to every task waiting for ticks and
wakes the tasks whose wait it reaches, in the order their waits began, to the tail of
their classes; the policy then serves them. A grant is finished, and its slot in the bound
on outstanding grants (`boundOutstandingGrants`) is free again, when every task it woke has
stopped being ready or running: by waiting again, completing, failing, being paused or being
stopped. A grant past the bound answers `GrantFull` and changes nothing; a zero duration
answers `GrantNotPositive`; a closed scheduler answers `GrantClosed`.

A task that waits for *n* ticks (`ReportWaitTicks`) wakes when the tick reaches the one it
was at when the wait began plus *n*, and resumes with the tick it reached and the logical
duration granted since its wait began (`ResumedLogical`). Both are fixed when the grant that
satisfied the wait is applied, so a later grant or a delayed dispatch cannot change them. A
wait for no ticks, or one whose end tick is not representable, is refused. A duration that
cannot be represented fails that task with a typed failure; nothing wraps, and the rest of
the step stands.

`awaitStepsComplete` is the STM condition "every accepted grant is applied and finished".
Composed with `awaitSupervised` it is how an application observes tick completion without
blocking a thread of its own; `grantComplete` and `stepsOutstanding` read the same state
without waiting. A task that is paused when its grant is applied does not hold the grant:
it is not ready or running. That is the scheduler's progress, and all `awaitStepsComplete`
promises: it does not say that the owner has accounted for an instance ending the work
caused (`shutdown`, the drain of what the instance held, a retirement a provider still owes,
its settlement, the application's escalation), which `awaitScheduledAccounting` waits for.

### Elapsed time

A task that waits for an elapsed duration (`ReportWaitElapsed`) wakes once the scheduler's
monotonic source (`schedClock`: TIME-1's, injected in tests) reaches its deadline, the source's
reading when the wait began plus the duration, and resumes with the time elapsed on that
source (`ResumedElapsed`). Arithmetic uses `addDuration`, so a deadline that is not
representable refuses the wait rather than wrapping; a wait of no time is refused. Deadlines
are looked at once at the start of each turn, in deadline order and, for one deadline, in
the order the waits began. How often turns start can therefore move when an elapsed wait
wakes, and an elapsed wait is the one thing that legitimately changes readiness with real
time.

A refused wait fails its task with a recoverable `ValidationFault`, reports the
`WaitRefusal` and the failure in the turn report, and counts in `diagRefusedWaits`. A task that fails while its
continuation is suspended (a refused wait, or a logical wait whose accumulated duration cannot be represented)
still owes that continuation a close: it is made on the owner's thread after the failure, its own failure
is kept in the scheduler, in the step that records the close, and handed to a turn's report only after the timer has been
brought in line; the stop reports it too until the next turn shows the report arrived (so no exception on the way out can lose it,
and at worst it is reported twice), and an obligation that was interrupted is made by the scheduler's stop. A task that
fails in its own segment owes none, since its continuation is dead.

### The timer

One owned registration (`Hetoimasia.Scripting.Lua.Scheduler.Timer`) is armed for the
earliest elapsed deadline and re-armed as it changes. It is cancelled when nothing waits and
at stop, and it is never more than one at a time. Its wake is a flag `awaitWork` composes
with the owner's other conditions: there is no polling, no per-task timer and no thread of its
own. Production uses the threaded runtime's timer manager (`systemTimerBackend`), which
needs the threaded runtime, as running Lua does anyway; tests supply a `TimerBackend` and
fire its wakes by hand.

A wake is a prompt to look at the clock, never evidence that a deadline passed. An early wake
finds nothing due and the timer is armed again. A wake of a registration that was replaced
or cancelled is stale and ignored, as is any wake after stop. Arming, cancelling and disposing happen under an uninterruptible mask, so the registration the backend
made and the way to cancel it are never separated by an asynchronous exception, even at a blocking operation
inside the backend, which is therefore called uninterruptibly and must not block for long. Registrations are whole
microseconds, rounded up, at least one and at most one hour (`maxRegistration`), so a
distant deadline is reached by a chain of wakes each followed by a look at the clock. None of
this defines a clock. An owner that exits without `stopScheduler` leaves the registration
armed until it fires, which is why the exit path calls it.

### Budgets and overruns

A scheduler may be configured with an elapsed service budget per turn
(`boundServiceBudget`). When the clock shows it expired as a segment returns, no further
segment starts in that turn, control and stop are served at that boundary, and the pass
continues in the next turn. A turn that is cut at the budget (or a stop request) when nothing is ready starts the pass afresh, as choosing the next segment would, so a cutoff can never change what runs next. The clock is read again after the work at each boundary, which can close
continuations and so use up the budget. A turn always starts at least one segment, so a small budget cannot
stop progress, and a budget so large that its deadline is not representable never
expires. The budget never interrupts a running segment, never changes which task runs next
or the order tasks run in, and installs no instruction hook: it is a service target, not a
limit, and a segment that never returns is not stopped. A segment that ends strictly after
the turn's deadline is an overrun, attributed to its owner, its task kind and its entry
point; a segment that ends exactly at it is not. At most `maxOverrunSites` sites are
attributed, and an overrun of a site that finds the table full is counted in
`diagOverrunsUnattributed`.

### Control

A caller holding a task's identity requests that it pause, resume or stop
(`requestControl`). A request never blocks, is usable from any thread including a
binding's action, and answers `ControlAccepted`, `ControlFull`, `ControlClosed` or
`ControlUnknownTarget` (a foreign, stale, ended or never-issued identity, or an admission
still in the queue), in that order of precedence, and a refusal changes nothing but a
counter. Accepting takes a reservation for the result, bounded by `boundControlRequests`,
and holds it until the settlement is observed or abandoned through the request's
`ControlTicket`, once, whichever comes first. Every accepted request settles exactly once,
as `ControlApplied`, `ControlAlreadyInState` or `ControlNoLongerApplicable`, including one
overtaken by the task's end and one outstanding when the scheduler stops.

Requests are applied between segments, in the order accepted, except that stops come first:
a stop takes precedence over any pause or resume accepted beside it, so a stop is never undone
by a resume, and a task that has ended is never resurrected. A request about the running task
is applied when its segment returns or yields; one about a task that completed in it is no
longer applicable.

Pause freezes a task: it runs no segment and occupies no turn. The model pauses only a
ready task, so a task paused while it waits stays waiting, with its continuation, its wait
and any wake it earns kept: if the wait is satisfied while it is paused it runs nothing,
and resuming it then puts it at the tail of its class with a fresh `Ordinal` and the wake
it earned; resuming it before the wait is satisfied returns it to waiting. A paused task
reports `PhasePaused` either way. Stop closes the task's continuation on the owner's thread,
once, through `hostClose`, and then cancels it. The close and its record are made under a
mask, so a cancellation that arrives after a close has returned waits until the task is
cancelled and the request settled, and a completed close is never repeated; a close that
was interrupted inside the host is retried by the scheduler's stop. A synchronous failure of the close is retained
in the settlement (`CloseFailed`) and in the turn report and is never reported as a clean
close; the task is cancelled all the same. A second stop of a task that has ended is not
applicable and closes nothing again.

### Stopping, determinism and diagnostics

`stopScheduler` is the whole scheduler's stop, distinct from stopping a task. It closes
admission, grants and control, closes every live continuation that is not inside a segment
once, in identity order, records each task's disposition and what it discarded in the model's
`ExitRecord`, settles every request not yet applied as no longer applicable, discards
unfinished grants (so no one is left waiting for them) and cancels the timer, which stays
disposed. A second call answers the first's report. A segment's report is applied, so its task is no longer running, before the clock is read or anything else that can
fail or be interrupted; if reading the clock fails for an elapsed wait the wait is applied as a yield, which leaves
the task ready and closable. A segment that was running when its host
failed is recorded as outstanding and its continuation is not closed. The stop runs
masked and attempts every close: one that is interrupted at its own interruptible
point keeps the interruption as its failure, the others still run, the stop completes,
and the first interruption is raised again afterwards.

Given the same configuration, policy, admitted tasks, segment outcomes and grants, the same
tasks run in the same order whatever the budget and wherever a turn is cut. Elapsed waits are
the exception, since a deadline reached changes readiness; the order among tasks already
ready is unaffected. Arbitrary elapsed-time workloads are not promised the same trace from
one run to the next. The proof on real VMs is the scheduled owner's, below.

`readDiagnostics` is a snapshot of bounded counters and gauges that borrows nothing from a Lua
state: admitted and rejected work, queue and active high-water marks, completed, yielded,
waiting, failed, cancelled and discarded counts, segments by class, overruns by site, refused
policy choices and refused waits, control and grant counts, and the logical tick. There is no
per-task history and no per-segment record.

### What proves it

The examples are part of `lua-runtime-tests` (`Test.LuaRuntime.Scheduler.*`), in
`runtime-lua-test/`. They drive a rig of scripted segments under an injected clock and a
fake timer whose wakes the example fires, so none sleeps and none needs a VM; the one
exception that touches a VM checks that a lifecycle-operation binding still answers
not-yet-supported through the finite-call adapter, which has no grant. One example arms the production timer and blocks in STM until its wake
arrives. Cancellation and shutdown windows are the kind an asynchronous-exception race can
hide on one platform, so CI, which runs them on Linux, is the evidence for them and a local
pass is not.

## The scheduled owner

`Hetoimasia.Scripting.Lua.Scheduled` (LUA-6, in `runtime-lua`) hosts the host's task
coroutines (LUA-20) and the scheduling machinery (LUA-21) on a supervised worker with a
real VM. It adds no scheduling of its own: which task runs next, what a tick or a
deadline is, how a budget ends a turn and how pause, resume and stop apply are the
scheduler's, documented above. The finite-call owners of the runtime adapter are
unchanged and stay the way to run a call; an application opts into a scheduled owner,
which admits all executable work as tasks (finite work is a task that completes in one
segment). A finite-call owner and a scheduled owner never run the same VM, and any
number of each can be created and retired while the others run.

### Creation and readiness

`startScheduledOwner` validates the scheduler's configuration (caps and quanta through the
model's `validateLimits`, the grant and control bounds, the budget) before anything starts,
raising `SchedulerRefused` naming every violation, then starts exactly one worker through
`startSupervised`. The VM is constructed, its bindings installed, its initial chunks run
and its modules loaded inside `withVmOwner` on the worker's thread; only then is
readiness published and an endpoint returned. Readiness is awaited through
`awaitSupervised` composed with the worker's outcome, never the startup acknowledgement,
and acquisition is masked exactly as for a finite-call owner. A failure of initialization
ends creation under the owner's `WorkerPolicy`. Unlike a finite-call owner's, a scheduled owner's creation
leaves nothing behind when its wait fails or is abandoned (another worker's fatal outcome, a cancellation): it asks
the owner to stop and waits for the worker it started to have ended (its raw completion, which supervision's latch
does not shorten), recording each interruption of that wait and going on until the worker has ended, and only then raises
what happened in order, a cancellation as itself and the rest as evidence beside it. A script held in a module's top
level keeps creation pending, as a held segment keeps the worker (D-27); the wait is interruptible and never runs under an
uninterruptible mask. This is what lets an application release what the owner's bindings borrow as soon as creation
has returned or raised.

### Identity

An owner has the `OwnerId` its `LuaRuntime` issues, from the one counter finite-call
owners use. A task is named by a `ScheduledTaskId`: the owner's identity and the model's
`TaskId` the owner issues from a counter that never rewinds. It is unique within the
runtime and never reissued, after the task settles and is observed and after its owner
retires. It is never an OS thread, a `ThreadId` or a coroutine, and neither it nor the
application's optional name for the task grants authority. The model's `TaskId` is scoped
by a `SessionKey` made from the owner's label, the configured domain and the owner's
sequence number, so the model's two domains limit neither owners nor tasks, and
`Test.Lua.Protocol` is untouched.

### Admission, settlement and tickets

`admitScheduledTask` admits a task (module entry, bounded arguments, class, kind, optional
name). It never blocks and answers `TaskAccepted` with the identity and a ticket,
`TaskQueueFull` or `TaskAdmissionClosed`. Arguments are evaluated, checked against the
owner's value limits and copied on the producer's thread; arguments over the limits are
accepted and settle as the refusal the argument check raises. Every accepted task settles
exactly once, as `SettledReturned`, `SettledFaulted` (a script fault returned as data,
never a worker failure), `SettledRefused` (the scheduler refused a wait: a recoverable
failure of that task), `SettledCancelled` (a stop request) or `SettledDiscarded` (the owner
exited first, with the exit kind and whether the task had begun).

Reading a ticket is observing it, as for a finite call's: the first read that finds the
task finished takes its result and gives its reservation back, and every later read, on
any thread, answers the same settlement. `forgetTask` gives a finished task's reservation
back at once and an unfinished one's when the owner next sweeps after it finishes. The
engine keeps no other history of terminal results: the retained cells are bounded by the
reservations.

A wait is refused from inside a Lua callback, scheduled-owner creation, `waitTask`,
`awaitTask`, `waitControl`, `awaitControl`, `awaitTicksComplete` and
`awaitScheduledAccounting` included, with `CallbackWaitRefused`, and so is an action built
outside the callback; a task waits by yielding. `awaitTicksComplete` ends with
`TickOwnerEnded`, never a false completion, when the owner exits with a tick outstanding. It
returns when every accepted grant has been applied and every task it woke has stopped being
ready or running, which is the scheduler's progress and not the owner's accounting of what
that work caused.

### Time, control and what a script is told

A script waits through a wait operation the application registered with `waitOperation`:
its first argument, an integer, is the number of ticks of a `WaitLogical` wait or the
nanoseconds of a `WaitElapsed` one; anything else is read as none and refused by the
scheduler as a wait for nothing, so the operation's schema should require one integer.
`grantScheduledStep` and `requestTaskControl` are the scheduler's `grantStep` and
`requestControl` for this owner. A resumed coroutine receives no value, so what the wait
that ended earned (the tick reached and the granted duration, or the elapsed time) is told
to the application on the owner's thread, before the segment that follows
(`scheduledObserve`); a binding that should answer a script's question about its tick keeps
what it was told where it reads it.

### Waiting for the owner's accounting

`awaitScheduledAccounting` (LUA-31, D-47) is the supervised wait for the owner's accounting
of the grants it has accepted: it returns `AccountingComplete` once the owner has finished
those grants, has ended the boundary at which the last of them was found finished, and every
instance ending begun by the end of that boundary has run its `shutdown` (or had it skipped),
released and drained what it held, completed every retirement a provider owes it, settled and,
for a failure, had `instanceEscalate` called **and returned**. An application decides a tick's
commit, or a stop's outcome, on it: `awaitTicksComplete` can return while any of those still
lies ahead on the owner's thread.

- *Who may call it.* It is a supervised wait like every other, composed with
  `awaitSupervised` and called on the application thread that owns the `RuntimeControl`
  (`docs/supervision.md`: the control is owned by the application thread, the drain status
  its one read-only exception), so one wait is pending at a time. Pending worker outcomes are
  handled first, and a latched fatal failure is rethrown by the wait and wins over a ready
  completion. It is refused from a Lua callback. It must not be called from the owner's own
  thread, an escalation callback say, where it would wait for its own return.
- *What it captures.* One committed snapshot of the owner's grant accounting, taken once
  when the wait begins and kept across the retries of the wait and across supervision's
  handling of outcomes, never taken again: every grant whose `grantScheduledStep` had
  committed before it, and concurrent grant calls are ordered by it. It does not wait for a
  grant accepted after the snapshot to be applied or finished, nor for a boundary after the
  captured grants' final one.
- *Where its ending cutoff lies.* At the end of that final boundary, not at the snapshot:
  every ending begun by then is covered whatever began it (a failed hook, a refused wait, a
  faulted invocation, a delivery failure, a stop, a one-shot completing, an instance stopping
  itself, and a grant accepted after the snapshot that was applied in that same boundary,
  which can fail a task by overflowing a logical wait's accumulated duration), and nothing
  begun in a later boundary is. With no grant outstanding, or none ever accepted, it covers
  the endings already begun, and it works for an owner that hosts no instances. It does not
  wait for healthy instances' future ticks, for idle peers, or for an ordinary task's fault,
  which stays a ticket result the application consumes.
- *What can delay it.* The owner has one thread and nothing is preempted, so later work can
  still delay an earlier wait: a later grant entering a blocking callback while an earlier
  ending is parked awaiting retirement holds the thread the ending needs to settle. A
  retirement a provider owes holds the wait for as long as it holds the instance's stop
  completion; there is no timeout. Returning is evidence about the owner's accounting. It is not
  permission to advance or to commit a tick that failed.
- *Who decides it is complete.* The owner, never the wait. At the end of a boundary that finds
  nothing more to do (the last step of its settling, after the instance layer's accounting, the
  providers' and leases' retirements and the disposals they owed were swept and handed over), the
  owner's thread, if it holds no failure that will end it (what the scheduler kept, what the owner
  kept) and is not stopping, writes an acknowledgement. The wait completes on an acknowledgement
  written after its cut was fixed (so a wait begun in the middle of a batch, the disposals a
  retirement owes or the providers being told, waits for the end of that batch), when the grants it
  captured have finished and no ending it covers was open when the acknowledgement was written.
  A boundary cut short by a failure kept or raised, an exception included, writes none, so a
  failure caught and not yet kept can never be acknowledged over. An idle owner is woken to write
  one, and is woken again when an acknowledgement was written with a covered ending still open and
  that ending has been accounted for since (its retirement completed after the boundary, and the
  owner settled it after its turn): that acknowledgement can no longer answer the wait, and it
  does not wait for unrelated work to cause another boundary. An owner whose covered ending is
  still open is not woken, so one waiting for a retirement does not spin.
- *What it costs the owner.* No task, control or result slot, no ticket and no per-wait state:
  the owner keeps a watch and a count of the endings it has begun and not yet accounted for,
  bounded by the instances' own bound, whatever number of waits were made, and the wait works
  with every one of the scheduler's bounds exhausted. Cancelling a pending wait, while it is
  parked or while supervision handles an outcome, abandons only that wait. A wait changes
  nothing the owner does.
- *When its owner ends.* An owner that exits, is stopped, cancelled or fails ends the wait
  with `AccountingOwnerEnded` once it has ended and supervision has handled the outcome
  without latching a fatal failure, and never with `AccountingComplete` unless the accounting
  was complete before the owner began to exit. An owner that is exiting but has not ended (a
  stop waiting for a provider's retirement) neither completes the wait nor ends it, and an owner
  that holds cleanup evidence that will end it as a failure (the failure of closing a coroutine, of
  a release, of a settlement) writes no acknowledgement, even with every ending accounted for: the
  wait is for the exit, and for the failure supervision then handles. An
  `Escalate` answer, an escalation callback that raises and a failed retirement end the owner
  as a failure, and the wait follows the severity supervision gives that outcome: rethrown if
  it is fatal, `AccountingOwnerEnded` if it is tolerated.

### Idle

An owner whose tasks are all paused, or waiting for an ungranted tick or a future
deadline, enters no Lua and does no periodic work: it blocks in the scheduler's one STM
wait until a stop request, an admission, a control request, a grant or its timer's wake. A
stop request wakes it whatever its tasks wait for.

### Lending a collection

An owner the application gave a `Lending` handle holds a resource collection owned by a
capability instead of a thread (`Hetoimasia.Foundation.Resource.OwnedCollection`, LUA-25), on
its own thread around the VM's lifetime, and lends it to each synchronous callback of its VM
for exactly the callback's duration. The thread-owned collection cannot be used from a binding:
a callback runs on a thread of its own while the owner's thread is blocked inside Lua, and it
accepts calls from the thread that created it only. `Hetoimasia.Scripting.Lua.Lending` is how
a binding's action uses what its callback was lent:

```haskell
newLending      ∷ IO Lending
lentToCallback  ∷ Lending → IO LentCollection
acquireLent     ∷ LentCollection → Assembly a → IO (Member a)
acquireLentThen ∷ LentCollection → Assembly a → (Member a → IO b) → IO b
withLentMember  ∷ LentCollection → Member a → (a → IO r) → IO r
retireLent      ∷ LentCollection → Member a → IO Retirement
liveLentCount   ∷ LentCollection → IO Int
```

**The handle is the only route.** The application makes a `Lending` with `newLending`, closes
the bindings that use the collection over it, and gives it to the owner it creates
(`scheduledLending`). A handle serves one owner; giving it to a second is refused with
`LendingInUse` before anything starts. There is no registry of owners and no lookup by thread:
a binding can reach only the owner whose handle it was built over, and an owner with no handle
holds no collection and runs as it always did. Because a registration is built before an owner
exists and may be shared, bindings that use the collection are built per owner, over that
owner's handle.

The action asks `lentToCallback handle` when it runs and finds the collection of the owner whose
VM is running its callback. The loan is never a Lua value, so a script cannot hold or pass it.
The members it acquires belong to the owner: a member acquired in one callback is borrowed and
retired in a later one, and what is still live when the owner retires is released then. The
operations are those of the foundation collection with every one of its guarantees, so the
live-member bound (`scheduledMemberLimit`, 256 unless the spec says otherwise, and never below
one: a lower limit is refused with `OwnedInvalidMemberLimit` before anything starts), staged
acquisition with masked registration and the handoff, retirement exactly once, poisoning and the
exit's failure table all hold, and a rejection is raised with its own type.

A loan is valid for the callback it was lent to, on that callback's thread. It is refused before
the operation has any effect, and a refusal does not invalidate the loan:

| Presented | Outcome |
|---|---|
| After the callback returned, including in a later callback of the same VM | `LoanEnded` |
| From a thread the callback started, from another VM's callback, or from any other thread | `LoanElsewhere` |
| Asking the handle while the owner's VM is running no callback | `NoLoan` |

Whether a thread is the VM's callback is decided by the record the VM keeps of its callbacks, the
one that refuses an operation re-entered from a callback, not by anything the callback or the
thread says: the owner lends through the VM's callback scope, which runs inside that record, and
the check is made when the loan is presented, not when it is asked for. A thread that holds the
handle can therefore ask and is given a loan it cannot use. The capability behind a loan is itself
lent for the callback and revoked with it, so a loan that did reach the foundation's operations
later would meet `CapabilityStale` there.

The collection is allocated before the VM is constructed and closed after the VM has closed, as
part of the owner's retirement. Callbacks run by a coroutine's closing handlers and by
finalizer-eligible bindings while the VM closes still find it open. Retirement releases what
remains, newest first, on the owner's thread, and a release that fails is cleanup evidence on the
owner's outcome beside the VM's, fatal under every policy, as for any other cleanup failure of the
owner. The same retirement runs when the owner fails or is cancelled, and when initialization
fails after a callback acquired a member.

### Host failures, stop and exit

A Haskell failure raised by a binding's action, the application's liveness check or
observer, or anything else escaping the owner, ends the worker as for a finite-call owner:
the primary outcome with its own type and context, unconverted, judged by the owner's
`WorkerPolicy`, whatever its type. A script fault only fails its task.

Stopping the owner (`retireScheduled`, `stopSupervised`, the boundary closing) closes
admission, grants and control at once, lets a running segment return (nothing is
preempted, and a stuck segment keeps the worker, the VM and the binding dependencies
live), settles every ticket (a finished task keeps its result, any other is discarded with
the exit kind and whether it began), cancels the timer, discards the admissions that had
not begun, and closes every suspended coroutine on the owner's thread, attempting each
whatever another does. Closing errors are cleanup evidence on the owner's outcome, and a
retained cleanup failure is fatal under any policy, as supervision decides for any worker
(`WorkerCleanupFailed` when the worker was cancelled). `withVmOwnerScoped` then closes the VM,
and the owner's collection then releases the members still live; a release that fails is
cleanup evidence as well. The same retirement runs when the owner fails or is cancelled, with the way it exited
recorded, so a primary host failure or cancellation survives beside the evidence. A
coroutine the scheduler left alone because its task was inside a segment when the owner
ended (the application's observer raised before it resumed, say) is closed too, before the
VM is, where the cleanup a script asked for may run state operations a VM's own teardown
refuses. A failure of cleanup is fatal and ends the owner at once, so nothing accumulates
while it serves: the first coroutine whose close raised, a script error raised together with
the failures of closing its coroutine (the task still settles as faulted), or a timer
whose cancellation throws ends the owner through the same retirement. A stop that is itself
interrupted keeps every close's failure, the interruption among them, and the failure of a
timer's cancellation beside it (the scheduler's stop report carries it, whether the stop
or an earlier service turn met it: the timer remembers the first, whatever the type of what
the cancellation raised, an asynchronous exception type it throws itself included). A task-level stop
whose close is interrupted keeps that failure before it propagates. A task's coroutine is
acquired and published to the owner's table together, masked, and a resumed segment's
outcome is recorded masked as well, so a cancellation queued during a segment lands after
it: the retirement finds the coroutine, a task that finished in that segment keeps its
result, and the failures of closing the coroutine of a task that failed in it are kept. The
`ExitRecord` is the finite-call adapter's: it names the owner and counts the tasks it
discarded, started and not started separately, and carries no cleanup evidence.

### Determinism

On one owner with a fixed policy and configuration, the same admitted tasks, grants and
control requests, each made at the same logical point (while the owner awaits the next
grant), give the same sequence of segments, the same logical durations to each task and the
same order of effects recorded through a binding, however long the segments take and
whether budgets expire. It is a property of the scheduler's documented ordering, and holds
for logical-time work: elapsed waits legitimately change readiness with real time, are not
covered by it, and are tested separately. A control request that arrives in the middle of a
step is not ordered logically here: deterministic logical admission of a script instance's
controls is the instance layer's (LUA-23, [Lifecycle services](#lifecycle-services); D-30). No claim is made across policies, worker counts,
platforms or versions.

### What proves it

`Test.LuaRuntime.Scheduled.*`, in `lua-runtime-tests`, run real Lua tasks as coroutines on
real supervised scheduled owners, under an injected clock and a fake timer whose wakes the
example fires, with gates and STM signals instead of sleeps: the policy, classes, quanta,
one-shot placement, grants, elapsed waits, budgets and control end to end; creation,
readiness and identity across cycles; every outcome, every bound, a thousand admissions
racing control requests and a stop, and a ticket's reservation; idle and stop, with
closing errors retained; host failures, failure and cancellation; the refused waits and tick
completion; repeated runs of one workload under different delays and budgets; the
accounting wait (`Test.LuaRuntime.Accounting.*`), each window it waits through on its own
(a close the owner runs at a boundary, a refused wait's close, a `shutdown`, a retirement a
provider completes later, the escalation callback and its return), the final boundary of the
captured grants and an ending a later grant caused in it, prefix isolation and a snapshot kept
across supervision's handling of an outcome, every bound exhausted, cancellation, and the
owner's end in each way; and the
lent collection (`Test.LuaRuntime.Scheduled.Lending`): members acquired, borrowed and
retired during a callback and in a later one, the bound and a lower limit refused, a loan
kept past its callback, used from a thread the callback started and presented from another
VM's callback refused with no effect while the callback goes on using its own, a handle given to
one owner only, a loan
ended by a callback that fails, the loan found in an initial chunk, a closing handler and a
finalizer-eligible binding, and retirement releasing what remains on the owner's thread
after the VM closed, however the owner ends, with a failing release fatal under an optional
policy that recognizes everything and kept beside the VM's own close failure, whether that is a
coroutine's or a finalizer-eligible binding's that failed while the VM closed. The
cancellation and shutdown windows are the kind an asynchronous-exception race can hide on
one platform, so CI, which runs them on Linux, is the evidence for them and a local pass is
not.

## Script instances

`Hetoimasia.Scripting.Lua.Instance` (LUA-18, in `runtime-lua`) puts instances on a scheduled
owner. An *instance* is one running copy of a module's behavior, with a `self` of its own, hooks
the module defines, functions it connected to events, and a lifecycle the application controls and
reads. It follows the accepted
[instance contract](../../docs/lua_instance_contract.md) (D-26, D-27). An owner hosts instances
when it is created with a `scheduledInstances` configuration (`InstanceConfig`); one without serves
tasks as before and loads nothing of this. The modules that host instances declare their hooks as
optional entry points (`hookEntries`). Periodic update cadence (LUA-24) is described under
[Cadence](#cadence). What an instance acquires through the application's bindings is owned by the
engine (LUA-22, [Instance leases](#instance-leases)); control and inspection a script is granted across
owners (LUA-23) are described under [Lifecycle services](#lifecycle-services); the requests a script makes of
providers (LUA-7) are described under [Asynchronous requests](#asynchronous-requests), and the events a provider
delivers to functions an instance subscribed (LUA-26) under [Provider events](#provider-events).

### Instances and identity

`admitInstance` admits an instance from a module the owner loaded and answers at once, from any
thread, without blocking: `InstanceAccepted` with the instance's identity and a ticket, `InstanceFull`
or `InstanceAdmissionClosed`. The identity (`InstanceId`, the TID) is the owner's identity and the
owner's number for the instance. It is unique within the runtime and never reissued, not after the
instance ends and its result is observed and not after its owner retires; it is never an OS thread,
a `ThreadId` or a coroutine, and it, like the application's name for the instance, grants nothing.
Live instances (`boundLiveInstances`) and the results of ended ones nobody has observed
(`boundRetainedInstances`) are each bounded, and a result is reserved at admission. A configuration
that does not fit the scheduler's own bounds is refused before anything starts, naming every
violation (`InstancesRefused`; a source's name must also leave room for the driver's entry point's prefix): the scheduler's retained-result bound must be at least twice the
live instances, because an instance's next invocation is admitted before the scheduler has given
back its last result, and its queue of admissions must hold one invocation for each.

The owner's thread makes the instance's `self`, a fresh empty table, before `init` runs. Module code is
shared by the instances of a module and a fresh `self` does not isolate mutable module globals or
upvalues. Ending one instance ends only that instance: another instance, the module and the VM stay,
and what they share stays valid. Instances of one module are independent.

`self`, and the functions an instance connected, are values of the VM: they have an identity and a
lifetime of their own and cannot cross the value boundary, which copies. The layer keeps them in a
table in the VM that only a driver module the owner loads beside the application's can reach, by the
instance's number, and the host runs a hook by handing it to the driver, which calls it with its
instance's `self`. A script cannot reach the table, so it cannot forge or erase another instance's
state. The layer installs two bindings. `hetoimasia_instance.delta` hands the driver the `dt`, in
seconds, of the update that is about to begin (a negative number for anything else), so that a one-shot's
`run` and an update go through one driver entry point that takes the instance's number alone, which keeps
the boundary footprint of `run` and of `update` to that one value; only the instance whose code is
running is answered. `hetoimasia_instance.connect` tells the owner a connection was made, so the owner
records it at once; it accepts only the number of the instance
whose code is running, so a script that names another instance's number is refused. A script that connects itself through the binding and
not through its `api` has a connection with no function behind it: the first event for it fails that instance, by name,
rather than being dropped.

### Hooks

| Hook | When | Suspends |
| --- | --- | --- |
| `init(self, api)` | once, as a finite call, before anything else; an absent `init` is a successful empty one | no: a wait or a yield is a fault of the hook |
| `update(self, dt)` | when a periodic instance's interval makes one due (see [Cadence](#cadence)), handed `dt` as a float number of seconds; an instance admitted without an interval never has one; a periodic instance whose module defines none is refused before any hook runs, naming `update` | yes, as `run` and the callbacks do |
| `run(self, api)` | a one-shot's body (`RunOnce`), to completion after `init`; a one-shot whose module defines none is refused before any hook runs, naming `run` | yes, as a task's entry point does |
| callbacks | an event's callback, handed `self` and the event | yes |
| `shutdown(self, reason)` | once, with `"stopped"`, `"completed"` or `"failed"`; optional | no |

`api` carries only what the instance was granted. In this slice that is `api.connect(source,
callback)`, which connects a function to an event source the instance was granted (`instanceGrants`)
and is a script error for any other. The event a callback receives is a table with `source`,
`sequence`, `tick` and `payload`.

### One invocation at a time

An instance has at most one invocation in flight, including a suspended one: a callback, or a
one-shot's `run`. An invocation is a task of the owner's scheduler, so the owner's policy orders the
invocations of its instances among each other and among its tasks (first in, first out, yielding to
the tail, by default) by the instance's service class; no policy overrides lifecycle, capacity or the
order an instance's own invocations were accepted in. The next invocation of an instance is admitted at
the boundary of the segment that ended the last, so the order depends on the order of admission and
nothing about how long segments take, when timers fire or whether a budget expires.

**An invocation the scheduler had no room for is tried again wherever room appears, before the next segment is
chosen.** Room is a result place, a place of the admission queue and an active slot, and a task keeps its slot and its
place until its result is observed. The owner takes one step at every safe boundary, after the scheduler's own work
there (its activations, controls and closes), and the scheduler does the boundary again while that step says it
released or used something. The step accounts for the invocations that ended and gives back what they held, gives
back what tickets the application forgot, and then, if the application asked anything or an invocation waits for room
and there is room, looks at every instance in the order of its number: what waited for room goes before what the
batch of requests begins. The sites that release room, and where each reaches the step, are these: an invocation's
end (its place, when the step observes it at the boundary; its slot, with it), a queued admission's activation (a
place of the queue, by the scheduler's own reconcile before the step), the application's observation or forgetting
of a ticket (a place and a slot: at any time by the application, and for a forgotten ticket of an unfinished task,
when the step sweeps after it finishes), an instance's control (a stop or a pause of a begun invocation ends or
freezes it directly, and a control that finishes a grant settles it at the boundary's second look; a resume looks at
the instance), the end of an instance (its coroutine's close, accounted at the step before it is looked at again),
and the owner's own control of its tasks (applied by the scheduler before the step). So where a turn is cut, which
only decides when the owner's thread is handed back to the loop, changes neither which invocation takes the room
that is there nor in what order effects happen. Room an application's own thread releases while a segment runs is
taken at the next boundary, whenever it was released: the application chose when to observe.

### Events

An owner offers named event sources (`EventSource`: a name and the shape of the payload). They are a seam
for tests and for the application's own threads, which deliver in arrival order (a provider's events are
[Provider events](#provider-events), which a logical owner admits by assigned place). `deliverEvent` answers at
once, from any thread, without blocking: `DeliveryAccepted` with a sequence, `DeliveryQueueFull`,
`DeliveryClosed`, `DeliveryUnknownTarget` (no live instance of this owner, or none with a connection to
the source) or `DeliveryRefused` (the payload is over the owner's limits or not what the source
declares). The payload is checked, as the callback will be handed it (stamped with its source and sequence,
beside the instance's number, against the owner's limits) and copied on the producer's thread, and is kept with its sequence and
the logical tick it was admitted at, unchanged, until its callback runs, however long that takes and
whether the instance is paused. No producer thread enters Lua. A connection made during `init` is
recorded when it is made, so events can be accepted while `init` runs; none is dispatched until `init`
has succeeded, and if it fails the connection is revoked and the events are counted as unstarted.

Each instance has one bounded first-in, first-out queue of invocations (`boundInvocationQueue`),
which a due update shares: the update keeps its place among the events and is never counted in the
bound. A full queue refuses the new delivery, counts it (`snapshotQueueFull`) and never evicts an
accepted one. Retained results use no part of it.

### Cadence

An instance is admitted with no periodic interval (`EventOnly`, `RunOnce`), or as `Periodic interval`,
which reacts to events as an event-only instance does and has its module's `update` called on that
interval. The interval is chosen at admission and fixed for the instance's life. Neither kind belongs
to the UI or to gameplay: either can run on any scheduled owner, and a gameplay owner and a UI owner
are an application's arrangement, not a hard-coded pair.

| Interval | Meaning |
| --- | --- |
| `LogicalTicks n` | gameplay's logical time: a positive number of ticks (`n` is an `Integer`; zero, a negative number and one that is not a tick count are refused) |
| `LogicalDuration d` | the same, as a duration: converted to ticks only when `d` is an exact multiple of the owner's configured tick duration (`instanceTickDuration`, a positive `Duration` the application sets; no production rate is hard-coded), and refused otherwise, naming `d` |
| `ElapsedEvery d` | the UI's elapsed time: a positive duration on the owner's monotonic source |

A refused interval answers `InstanceIntervalRefused` (`IntervalNotPositive`, `IntervalUnrepresentable`,
`IntervalNotExact`, `IntervalNoTickDuration`), takes no place and no result, and changes nothing.
Nothing is rounded.

**Logical updates.** The cadence points are every `interval` ticks from the tick at which `init`
succeeded, on a fixed phase. A point is looked at when its grant is *applied* (not when it was
accepted), at the safe boundary that follows, before any task that grant woke is chosen. It makes
an update due only if it finds the instance serving (not paused, stopping or ended) with no invocation
*active*. An invocation is active from the segment that begins it until it finishes, including while
it is suspended on a wait, and whether it is an `update`, a `run` or an event callback; one that is
admitted and has not yet begun is still queued, and the update falls due behind it. A point that
finds an invocation active adds nothing at all: no catch-up and no backlog, the grant that resumes a
waiting invocation included. The next update is due at the first point after that invocation
finishes, and no update overtakes an active invocation or an earlier queued one. An instance never has
more than one unstarted update.

The update's `dt` is the logical duration granted since the previous update *finished* (since `init`
succeeded, for the first), less any granted while the instance was intentionally paused (D-35), from
grants alone. Ticks that pass while an invocation is active and the instance is not paused still
count, so every tick granted while the instance is live is accounted to it once. It reaches Lua as a
**float number of seconds**: the exact `Duration` (the sum of the durations actually granted, so grants
of unequal sizes are summed as they were granted; or the elapsed difference) is converted once at the Lua
boundary, which is the only rounding. The owner's tick duration is only the unit an interval given as a
duration converts by, never a replacement for the grants. A representable `Duration` never fails because
its count of nanoseconds exceeds Lua's integer range. It is fixed as the update begins and is unchanged by
its own waits, by later grants and by real delays. The duration an invocation's own wait was granted is
reported to the application on the owner's thread when it resumes (`scheduledObserve`'s
`ResumedLogical`); a resumed coroutine receives no value, so a script learns it only through a binding
the application grants, as the test fixture's `fx.resume` does. That duration overlaps the next
update's `dt` and is no further credit. With a constant grant `q`, `init` at tick 0, interval 2 and an
event callback that waits through tick 5, the callback's wait observation is `5q`, and the first update
is at tick 6 with `dt = 6q`, whatever the callback did. Every granted tick is accounted exactly once in
a `dt`, and once in the observation of the wait it fell in.

**What a tick waits for.** A tick does not complete (`awaitTicksComplete`) until a due update has run
in it, but only while the update can still run in it, so a tick never waits on an update that cannot
start. The update lets go of its tick when: its instance is paused, or a stop or an ending discards it
before it starts; an invocation queued ahead of it begins and suspends on a wait; it has begun and
stopped being ready or running; or nothing at all is ready to run, so that what it waits for can never
happen. A callback that waits for future ticks therefore never deadlocks a due update behind it.
Real delay slows the simulation and never skips a due update: only the instance's own logical waits
make a point a no-op.

**Elapsed updates.** The interval is measured on the owner's monotonic source, behind the owner's one
timer: there is no per-instance timer, no polling and no thread. At most one refresh is kept
unstarted; demand that finds one is coalesced into it, and queued events are never dropped. Unlike a
logical point, an elapsed point queues its refresh behind an active invocation. Its `dt` is the elapsed
time between update starts, from the instant `init` succeeded. Ordinary lateness moves the next deadline
to the first point on the configured cadence strictly in the future: a stall of ten intervals gives one
refresh, not ten.

**Pause and resume.** A paused instance accrues no periodic demand, logical or elapsed: its timer
demand is cancelled and a point that finds it paused adds nothing. An update that was already due or
admitted and had not begun is retained, in its place, and holds no tick; it runs after the resume. After
a resume the first update newly due is one full interval later: that many ticks after the tick the
resume was applied at, or that much time after the instant it was. An elapsed instance's baseline is
rebased to that instant, and a logical instance accrues nothing toward its `dt` from the grants applied
while it is paused, so either `dt` excludes the pause: a resumed instance's first update receives about
one interval, plus whatever was granted between its previous update and the pause.

**The queue.** A due update takes its place in the instance's one queue when it falls due: behind the
events accepted before it, ahead of those accepted after it, so a continuous producer cannot starve it.
It is not counted in `boundInvocationQueue` and never competes with events for it, so it is never refused
as full; `snapshotUpdateOwed` says one is owed.

**Ending.** Every way an instance ends (a stop, a failure, its owner's retirement or exit) cancels its timer demand, discards its unstarted update, counted with the other unstarted
invocations (`terminationUnstarted`), and lets go of a tick it held.

**Arithmetic.** An accrued duration, a tick or a deadline that cannot be represented fails the instance
(`ErrorCadence`, at `StageUpdate`), attributably: nothing wraps, no timer demand is left and no tick is
held.

### Failure and escalation

A failed `init` fails that instance: no `update`, `run`, callback or `shutdown` ever runs on it, its
connections are revoked and its record in the VM is released. Its failure (`InstanceFailure`) names the
instance, its owner, its source module, the phase, the stage, the error and the traceback, if one was
captured; the `init` error is primary, nothing later replaces it, and what else failed while it ended is
kept beside it (`failureSecondary`). There is no retry. An unhandled error in `run` or a callback fails the
instance the same way, except that `shutdown` runs with the reason `failed`.

Isolation is the default: the instance ends and the owner's other instances run on. The engine cannot
tell whether state the instances share was damaged, so the application is told of each failure on the
owner's thread (`instanceEscalate`), after the instance has ended, and decides `Isolate` or `Escalate`,
which fails the owner as a host failure does (`InstanceEscalated`) under its `WorkerPolicy`. A failure
raised by application code is never an instance's failure; it ends the owner, unconverted, as it does for
tasks. Cleanup is the engine's and nothing the application answers can hide it: what closing a coroutine
raised, a closing handler the script defined included, is cleanup evidence on the owner's outcome and is
fatal under any policy, as it is for a task, and it stays beside an instance's primary failure; a failure raised
while an instance ends does not take a close's failure with it, a `shutdown` that raised a failure of the host is not
started again when the owner's exit comes back to the instance, an instance whose coroutine the scheduler closed is ended
from the owner's own code and not from inside the close, so a failure of the host that a hook raises is the owner's own
failure and is never taken for a failure of the close, and when several instances' ends raise failures the first
is the owner's and every other is kept whole as cleanup evidence. What an ending had counted survives a failure of the
host in its hook.

### What an ending keeps

An instance's ending is one record, made when it begins and kept until the instance settles: why it ends, its
primary failure (the phase, the stage, the error and the traceback), what the ending revoked and discarded, and what
became of `shutdown`. The hook's disposition is written once, when it is decided: not run because `init` never
succeeded, skipped because Lua was not safe to enter, absent, started, or finished (returned, or raised a failure of the
instance's code). A hook that was started and has not answered is recorded as started; if a failure of the host cut it
short that is how it settles (`ShutdownRaised`, with no failure the instance can report), and coming back to the ending
neither runs it again nor releases the instance's record in a VM that raised. Nothing is recomputed from the owner's mode
afterwards.

One function, `settleEnding`, settles an instance and tells the application of its failure, and every path that ends an
instance reads the record through it: a stop of its own (`applyControl`, `continueStop`), an invocation that failed or a
one-shot's `run` that completed (`invocationFailed`, `invocationCompleted`), an instance that failed at a hook
(`failInstance`), a coroutine the scheduler closed (`instanceClosed`, ended from the owner's own code), the owner's
retirement in order and after a failure or a cancellation (`retireInstances`, through `finishEnding`), an ending that a
failure of the host interrupted and that retirement comes back to (`finishEnding` again, which finds the hook's record),
and an ending that could not be carried through at all (`discardUnsettled`, which is the same function). A first failure,
once recorded, is never replaced by anything later: not by the owner's exit, not by a hook that raised a failure of the
host, not by the retirement. An instance with a failure in its record settles as failed, with that failure, its
traceback and a failing `shutdown` beside it as secondary, whatever the owner's exit; one with none settles as discarded
when the owner exited by a failure or a cancellation, or when its hook was cut short, and as stopped or completed
otherwise. The failure of the host still ends the owner, unconverted, under its `WorkerPolicy`, and the way the owner first exited (a failure or a cancellation) is the way every instance left after it is discarded: what a later ending raises does not rewrite it. That is one function, `recordExit`, and it is the only thing that writes how the owner exits for its instances: the first failure or cancellation recorded wins, an exit in order gives way to the first of those, and a later cancellation, an interrupted close or a hook cut short is cleanup evidence on the owner's outcome and nothing else. Its callers are the owner's exit (from how its loop ended), the close of a coroutine the scheduler's own close interrupted, the scheduler's stop when it is interrupted, the close of a coroutine the scheduler did not close, and the retirement of an instance whose end raised; the owner's exit record (written once, as the owner exits) and the instances read the same first cause. An owner stopped in order is recorded as stopped, and a cancellation of its own teardown after that discards the instances as cancelled and leaves that record as it was written. Settling an instance and deciding that the application is told of it are one step a cancellation cannot cut between, and the hook's answer is recorded in a step it cannot cut either. The application is told of
a failed instance exactly once, by whichever path settles it (an owner that is exiting is told too: what it answers is
not raised, because the owner's own failure is what it exits with, and what telling it raised is kept as cleanup
evidence beside that failure).

### Control

`requestInstanceControl` asks that an instance pause, resume or stop, and answers at once, from any
thread: `InstanceControlAccepted` with a receipt, `InstanceControlFull`, `InstanceControlClosed` or
`InstanceControlUnknown` (another owner's identity, an ended or never issued instance). An accepted
request holds a reservation until its settlement is observed or abandoned
(`boundInstanceControls`), and settles exactly once, as applied, already in that state, or no longer
applicable, including when the instance or the owner ends first. Requests are applied in the order accepted,
at the owner's next safe boundary: the owner's thread services them at each of the scheduler's boundaries,
before the first segment of a turn and after every segment, when no task is running, after the scheduler's own work
at that boundary, and never inside a segment.
Pause and resume of the invocation in flight, and stop, are done to its task directly, at that boundary,
with no scheduler request, reservation or queue between: a request settles as it is applied, before anything that
can raise a failure of the host. An invocation that has not run a segment has nothing to freeze or close, even when
the scheduler holds it in its queue behind slots that stay occupied: pausing takes it back, with its event, to be
started on resume (the task the scheduler holds is used again when the invocation is the same, so pausing and
resuming over and over admits nothing new), and a stop discards it as an unstarted invocation. (A task the scheduler holds in its admission queue cannot be
withdrawn from it: an instance that took one back leaves at most one such task, which does nothing when chosen and
is used again by the same invocation, and it holds a queue place and a stored-result place until then.) Until it runs, an
invocation holds its place in the instance's queue, so taking it back never overfills the queue; a one-shot's `run`
is no event and holds none. It is owed from the success of the instance's `init` until its first segment begins,
whatever became of it meanwhile (taken by the scheduler and queued, refused for want of a place or a queue place,
taken back by a pause, held while paused): the instance has one record of that, and an ending of any kind (a stop, a
failure, the owner's retirement or cancellation) counts it once among the unstarted invocations it discards. An owner that has been asked to stop services
nothing more: its exit settles what was left. The scheduler's own task controls do not reach an instance's
invocation, whatever the application learned of its identity: they answer unknown, and the instance layer is
the only thing that pauses, resumes or stops it.

- **Pause** stops new invocations from starting and freezes the invocation in flight, if any, suspended
  where it is, running nothing, however its wait would have ended. Accepted events stay in the queue, in
  order.
- **Resume** lets it go on: a suspended invocation finishes before another starts, then the retained
  events run in the order they were accepted and new ones behind them. It does not undo a stop.
- **Stop** works while paused and takes precedence over ordinary work. It closes the instance's
  admission, revokes its connections, discards what had not begun and counts it (an invocation stopped before its first segment is one
  of those, not a coroutine closed), closes the coroutine of
  the invocation in flight on the owner's thread and never resumes it, and only then runs `shutdown`. The
  request's result says the stop was taken; its completion is the instance's settlement, written after the
  hook and the release. A stop ends an instance as it is applied unless a hook raises a failure of the host, so a
  second request finds it ended and settles as no longer applicable. Repeated requests are safe and never
  resurrect an instance or run `shutdown` again.

Whole-owner control (`retireScheduled`) is distinct. An orderly retirement stops each live instance
through the same path with the reason `stopped` before the VM is closed. An owner that fails or is
cancelled does not enter Lua for its instances again: no `shutdown` runs, which the settlement reports
(`ShutdownSkippedUnsafe`), and each instance settles as discarded. That includes an owner whose retirement is
itself failing: once an instance's `shutdown` raises a failure of the host, or a close or hook is cut short as a
cancellation is, the instances after it are discarded with the owner's exit, not stopped. A lifecycle binding a script
calls answers a typed `NotYetSupported` fault from an owner that was granted nothing; an owner that was granted lifecycle
services gives its scripts these same controls (see [Lifecycle services](#lifecycle-services)).

### Results, inspection and idle

Every accepted instance settles exactly once (`InstanceSettlement`): completed, stopped, failed or
discarded, with what its end revoked and released (`Termination`: the connections revoked, the unstarted
invocations discarded, the invocations that began and were closed, and what became of `shutdown`). A
failing `shutdown` is kept and never retried, runtime cleanup still happens, and an instance that would
have completed or stopped is failed by it; a primary failure stays primary, with its traceback, on every path
that ends an instance, including one a failure of the host interrupted (see *What an ending keeps*), and the
disposition of `shutdown` is the one recorded when it was decided. Observing, abandoning and
waiting work as for tasks (`pollInstance`, `waitInstance`, `awaitInstance`, `forgetInstance`), and a
ticket nobody observes or forgets keeps its reservation, which bounds the retained results.
`inspectInstance` and `inspectInstances` answer bounded, coherent snapshots (`InstanceSnapshot`), each
read in one transaction, and never borrow a Lua table.

Everything the owner does for an instance is a response to something: an admission, an event, a request,
a grant, a deadline or a stop, or room appearing in the scheduler's queue or results for an invocation it had none for, which the owner tries again
at the boundary where room appears (every boundary gives back what ended invocations held first), so the order of
invocations does not depend on where turns are cut even when the scheduler's result places are all taken. Its wait is
the scheduled owner's one STM wait with the instance layer's jobs added, so an owner whose instances are all paused, waiting or idle enters no Lua and does no periodic
work until one of those arrives.

### Determinism

On one owner with a fixed configuration and policy, the same admitted instances, grants, delivered events
and control requests, each made at the same logical point (while the owner awaits the next grant), give
the same order of invocations and of effects recorded through a binding, however long the segments take,
whenever timers fire and whether budgets expire. It holds for logical-time workloads: elapsed waits
legitimately change readiness, as do elapsed-interval updates, which depend on real time and are tested
against the injected clock. The order of logical updates among an instance's other invocations, and the
`dt` each receives, are among what is the same. An event delivered to a connection, or an arrival-admitted request, that arrives in the middle of
a step is not ordered logically (a provider's event is: see [Provider events](#provider-events)). A control admitted logically is: see [Logical admission](#logical-admission).

### What proves it

`Test.LuaRuntime.Instance.*`, in `lua-runtime-tests`, run real instances on real supervised scheduled
owners under the injected clock and fake timer of the scheduled-owner examples, with gates and STM signals
instead of sleeps: an instance's own `self` and the module it shares, one-shots, identity and snapshots, idle; a failed `init`
and the hooks that cannot suspend, a failed callback, a failed `shutdown`, the application's escalation, a failure of the
host and the evidence of a failed close; events during `init`, a full queue, every refusal, and what an accepted event
keeps; pause and the order resume restores, stop while paused, contradictory and refused requests; what each way
of ending revokes and counts, retirement, cancellation and the instances an owner never began; every bound and a
configuration that does not fit; and one workload run under different segment costs and service budgets; the cadence's examples
(`Test.LuaRuntime.Instance.Cadence` and `.Elapsed`): an interval's exact conversion and its refusals,
the first update one interval after `init` and the duration granted since the previous one finished, a
callback that waits across a due tick (the regression for a deadlock the first review of LUA-24 found), a
due update's place in the queue and its tick released when it cannot start, pause and stop settlement of a
due update, elapsed refreshes coalesced after a stall and rebased at a resume, the owner's one timer shared
by instances and an ordinary waiter with a stale wake, and the checked arithmetic; and a sweep of what ended the owner first (a failure of the host, a failing script its escalation made the owner's, a stop, a cancellation) by what happened to its teardown (a close interrupted, a hook cut short as a cancellation is, nothing but an idle peer), holding the instances, the exit record and supervision to one cause, with the two paths of it that only an interrupted close of a task inside a segment, and a cancelled escalation, reach; a matrix of what first happened
to an instance (a Lua error in a callback, a failure of the host, nothing) by what its `shutdown` does (returns, raises, raises a
failure of the host) by how it ends (its own stop, the owner's retirement, the owner's teardown), each cell holding the settlement, the
owner's exception and the application's notification to one model. Every wait in these examples is for a signal the code
under test sets (a settlement, a terminal status, the notification the escalation makes, a diagnostic that says an invocation was queued or refused, the wait a grant is for
having been taken), never for an ordering the test assumes. The
cancellation and shutdown windows are the kind an asynchronous-exception race can hide on one platform, so CI, which
runs them on Linux, is the evidence for them and a local pass is not.

## Instance leases

`Hetoimasia.Scripting.Lua.Lease` (LUA-22, in `runtime-lua`) makes the resources a binding acquires for
a script instance the engine's, so that cleanup is correct however the script behaves. It implements the
accepted [instance contract's](../../docs/lua_instance_contract.md) "Automatic resource ownership"
(D-26, D-27) on the capability-owned collection an owner lends to its callbacks
([Lending a collection](#lending-a-collection), D-32). A script that raises before storing a handle,
overwrites it, never stores it, or defines no `shutdown`, or a `shutdown` that fails, still has what
it acquired released when its instance ends, and no Lua-written cleanup is ever required. **A binding
that needs the script to clean up after it, whose ownership and retirement cannot be described, or that
exposes a native lifetime for Lua to manage, is not qualified for this interface.**

### The scope and the lent capability

Each instance has a *scope* the engine makes before its first hook and dissolves when the instance
settles. It lives in Haskell, in the state of the owner's `Leases` handle; `self`, a module's globals
and every other Lua value cannot erase, replace or forge it, because none of them can reach it. A script
holds only *handles*: capabilities whose key names a lease, issued by the VM and checked by the value
boundary before a binding's action runs ([Handles](#handles)).

One owner has one collection, and each instance's scope keeps its own bookkeeping over it, so what one
instance holds is never another's to release. A binding's operations run on its callback's thread,
through the capability the owner lent for that callback; the drain at an instance's end runs on the
owner's thread, through the capability the owner holds. Nothing assumes a binding runs on the owner's
thread, and `init` and `shutdown` are callbacks like any other, so a binding can acquire inside both.

The application makes the handle over its `Lending`, closes its bindings over it, and gives the owner
both:

```haskell
lending ← newLending
leases  ← newLeases lending 8      -- at most 8 charges for each instance
spec = (scheduledSpec vm worker bounds)
  { scheduledInstances = Just instanceConfig
  , scheduledLending   = Just lending
  , scheduledLeases    = Just leases
  }
```

An owner is refused before anything starts, naming every violation (`LeasesRefused`), if it hosts no
instances, lends no collection, lends through a different handle than the leases were made over, or has
a `scheduledMemberLimit` too small to hold every live instance at the capacity. A handle serves one owner,
because the `Lending` it is made over does.

### Reserving, acquiring and registering

`acquireOwned` and `acquireShared` do three things, in this order, before they return, and none can be
left half done:

1. **Reserve** one charge of the instance's capacity, before any stage runs. Exhausting the capacity is
   an *engine* refusal of the calling invocation, below.
2. **Acquire** through a staged `Assembly`, with every guarantee of the foundation collection: a failing
   stage rolls back exactly the stages that completed, registers nothing and gives Lua no handle. The
   constructor's own failure is a failure of application code, so it ends the owner under its
   `WorkerPolicy`, unconverted, as any binding's does; a binding author who wants a recoverable refusal
   returns it as bounded data. A rollback whose release fails is a cleanup failure.
3. **Register** the obligation in the masked step that registered the member, so a cancellation or a
   failure to publish the call's result cannot land between having the resource and having a record of
   it.

Only then does the action have a `Lease` to turn into a handle (`leaseHandle`). There is no interval
in which Lua holds a resource whose cleanup depends on the script's next statement. A result that cannot
be published (the call returned more values than the binding declares, say) leaves the lease
registered and drained with the instance.

### Capacity and its refusal

Capacity is bounded for each instance (`newLeases`). It counts every resource the instance holds *and*
every released resource whose provider has not yet proved it retired, so a script cannot grow what is
outstanding without limit by acquiring and releasing in a loop. An acquisition over it is refused by
the engine, before any stage runs and before anything is charged:

* the refusal is raised unmarked as application code, so it is a fault of the call
  (`BindingRefused`, decision C1) and never a failure of the host, whatever the script does with the
  Lua error it sees, a `pcall` included;
* the invocation is faulted even though the script caught the error, so the instance fails (isolated,
  as a faulted invocation is) and the owner goes on;
* nothing converts an exception the `Assembly` throws: capacity is checked before the assembly runs
  and only the engine can raise the refusal.

### Instance versus application leases

The binding author chooses:

* `acquireOwned`: the instance owns what the assembly builds, and releasing the lease destroys it.
* `acquireShared label take drop`: the instance takes an interest in a resource that lives on with its
  owner (a shared asset, a world object). Releasing the lease runs `drop` and nothing else; another
  instance's lease on the same asset, and the application's own, are untouched.

A handle stays owned by the instance that acquired it. Caching it in a module's global or in another
instance's `self` does not extend its lifetime: when the acquiring instance ends every later use is
refused as retired (`RuleRetiredHandle`), and keys are issued in order and never again, so the capacity
an ended lease gave back cannot make the old handle live. Using it from another instance while its
owner lives is refused by the engine (`BindingRefused`). Longer-lived ownership than a lease is out of
scope.

### Using a handle

The value boundary has already checked that a handle was issued by this VM, is of the declared type and,
through `leaseLive` (declare the type with `leaseCapabilityType`), that its lease has not ended.
`withLease leases key action` borrows the held resource for the action, under the collection's borrowing
rules, and is refused for a lease of another type or another instance.

### Early release and its answers

A script may release a handle early through a binding built with `releaseOperation`
([Handles](#handles)), whose action calls `releaseLease`:

| Answer | Meaning |
|---|---|
| `Released` | The first release; the resource is retired. |
| `Retiring` | The lease is revoked and the provider's retirement is pending. A repeated release answers it again and restarts nothing. |
| `AlreadyReleased` | The lease ended whole earlier. Nothing ran. |

A release whose native cleanup failed answers none of them. Its failure is retained on the lease, is
the answer to every later release of it, never runs the cleanup again, and ends the owner as cleanup
failures do. An invalid or missing Lua value is an ordinary argument error and never prevents the
engine from cleaning up the instance's other holdings. A closing handler a script defined runs as the
instance whose invocation it is, so it may release a handle it holds.

### Draining and its failure evidence

On every path by which an instance ends (a failed `init`, a stop, a faulted invocation including a
failure of a closing handler, a one-shot's completion, the owner's retirement or cancellation, and a
`shutdown` that is absent or raises) the instance's remaining holdings are released on the owner's
thread after its `shutdown` has run or been skipped, newest acquisition first and each one's parts in
the order its assembly declared. Handles stay usable inside `shutdown`. A release that fails does not
stop the others from being attempted. Draining runs no Lua, so it also runs when Lua is no longer safe
to enter, and when a failure of the host in `shutdown` is what ends the owner: the instance is drained
and, if a provider has yet to retire something, parked all the same, so nothing is left live for the
collection's own close, where nothing would wait for its provider.

A release failure is a cleanup failure:

* it is kept beside the instance's primary failure, which stays primary, in the settlement
  (`failureSecondary`, stage `StageRelease`), and is the instance's failure when there is none. That
  includes a rollback release that failed while a constructor was failing: the constructor's exception
  stays the owner's failure, as an application failure, and the rollback failure is kept for the
  instance beside it;
* it is cleanup evidence on the owner's outcome, so it ends the owner at once through supervision and
  is fatal under every policy, an `Optional` owner whose classifier recognizes every exception
  included. At once means at the boundary where it was observed: admission, grants and control close
  and the scheduler is asked to stop, so no queued invocation or `init` begins after it, and the owner
  exits as a failure from that moment: the instances still to end have no `shutdown` run and no Lua
  entered, and their holdings are drained all the same, settling or awaiting what is left as any exit
  does;
* it is never retried and never reported as reclaimed. `resultLeases` counts what the end released,
  waited for and saw fail.

### Retained retirement

A resource retired by a provider that finishes later does not wait inside the collection's
uninterruptible release (`docs/resources.md`, "What a release may do"). The assembly's release hands the
resource over and records the obligation with `retireAsynchronously retirements label reading`, where
`reading` is an STM transaction that says `ProviderPending`, `ProviderComplete` or `ProviderFailed`. It is
application code and may throw, when it is run or when what it answered is first inspected: either is
that retirement failing, retained as cleanup evidence while every independent retirement is still served
and awaited, and a reading that retries says it is not done. A reading only reads: what it writes is not kept,
and it may read TVars that other readings share or that the provider's own thread writes. The engine polls it
inside a transaction that has read state already, so when another thread commits to what both read, the poll
starts again from a consistent view and runs the reading once more, rather than running it again and again
against the stale one; that holds under the build and runtime settings the repository already has, and is the
same one reading (`Hetoimasia.Scripting.Lua.Retention.pollObligation`) for leases, requests and subscriptions.
The same holds for every other call into
provider or application code the retirement makes (a deferred disposal, the application's escalation of
an instance's failure, the Lua `release` hook, rendering an exception for the settlement): each is run
through one guard that answers the failure instead of raising it, with what it answered evaluated inside
that guard, and a failure of one is recorded while the independent ones go on. No failure is dropped:
where several arise together (several endings settling at once, several releases of a drain, several
retirements failing in one reading) the first is raised and every other is kept whole as cleanup evidence
on the owner, so supervision receives each of them. The lease keeps its charge until the provider says it is done. The reading, the guard, the held
disposals and their rules are one primitive, `Hetoimasia.Scripting.Lua.Retention`, which the request service
uses for its provider work too (see [Asynchronous requests](#asynchronous-requests)); a lease's behavior is
unchanged by that. The owner awaits it outside
the collection, in its own protected lifetime:

* the instance's stop completion settles only after its obligations have completed; until then it is
  `Stopping`, and nothing is reported as reclaimed merely because Lua stopped;
* the owner stays live, with everything its exit keeps, through a stop and through a cancellation, as a
  stuck segment keeps it, until the provider has proved completion;
* what a retirement needs is handed to it, not disposed: the release of the part that owns a dependency
  calls `afterRetirement disposal`, ranked after the parts being retired, and the engine runs the disposal
  once every retirement the lease has recorded has completed, uninterruptibly on the owner's thread and
  before the stop completion settles (at once, inside the release, if none is pending), so a dependency is
  never disposed under a retirement still using it. If a provider reports its retirement failed the disposal
  never runs: the dependency is retained, as the resource is. A disposal that fails is cleanup evidence
  and is retained on the lease, whose every later release answers that failure and runs nothing again;
* a retirement the provider reports failed is retained as cleanup evidence and is fatal, and the lease
  it belonged to answers that failure and never success;
* a stage rolled back whose provider has not finished keeps its charge, and the owner's life, though the
  constructor failed.

### What is not here

Real providers (a request's provider and its retirement are [Asynchronous requests](#asynchronous-requests)), GPU or native game bindings, rollback of committed effects
(D-7), a longer-lived ownership API than the lease boundary, and the update cadence of LUA-24, which
is described under [Cadence](#cadence).

### What proves it

`Test.LuaRuntime.Instance.Lease.*`, in `lua-runtime-tests`, run real instances on real supervised
scheduled owners that lend their collection and hold leases, with fake resources and a fake provider and
no Lua cleanup code in any module: acquisition from `init`, a callback and `shutdown`; handles lost, overwritten or
never stored; a constructor that fails part way, and a rollback whose release fails; the capacity and the
engine's refusal, which a `pcall` does not turn into a host failure; a result that cannot be published; a
shared asset surviving one instance's exit and a cached handle staying retired; early and repeated
release, the retired handle accepted only by the release operation and refused by every other, and a failing
release; the drain on each way an instance ends, newest first and past a failing release, with the failure
beside the primary one and fatal under both a required and an optional policy; and a provider's retirement
that holds the stop completion, the capacity and the owner's life through a stop and a cancellation. The
release operation and the engine's refusal are also pinned in `lua-host-tests`. The cancellation and
cleanup windows are the kind an asynchronous-exception race can hide on one platform, so CI, which runs
them on Linux, is the evidence for them and a local pass is not.

## Lifecycle services

`Hetoimasia.Scripting.Lua.Lifecycle` (LUA-23, in `runtime-lua`) lets a script instance's code ask that an
instance pause, resume or stop, and read snapshots of instances, across owners of one `LuaRuntime`. It builds
on the instance layer, the capability-owned collection and the instance cadences, and reopens none of their
contracts. It is available to the application's scripts only where the application grants it, and a grant is
the whole of the authority.

### Granting

A `LifecycleGrant`, given to an owner as `scheduledLifecycle`, names the owners its scripts may reach
(`GrantTarget`: `GrantedEndpoint` of another owner of the same runtime created earlier, or `GrantedSelf`), what
each permits (`PermitInspect`, `PermitControl`) and two bounds (`grantReceiptBound`, `grantSnapshotBound`, each at
least one; 32 and 64 by `lifecycleGrant`). It is validated before anything starts, and a grant that does not
make sense is refused, naming every reason, as `LifecycleRefused`: a bound below one, too many or a repeated owner,
no permits or a repeated one, an owner of another runtime, an owner that hosts no instances, a permitted control
of an owner that admits logically with no assignment, and an assignment for an owner that does not.

The bindings (`lifecycleBindings`, `lifecycleNamespace`) are registered once, in one `Registration` that any
number of owners with different grants share, and exposed by an owner's policy like any namespace. Which owner
is calling is not read from the script: the engine hands each owner's own state to its bindings through the host
library's `LifecycleContext` (`lifecycleOperationIn`), set from the owner's configuration, so an inspection-only
owner cannot control, a control-only owner cannot inspect, and an owner with no grant keeps the typed
`NotYetSupported` fault with its action never run, whichever registration it was given. The calling instance is
the one whose Lua the owner is running, and the calling task the one whose segment it is. The host library still
depends on no runtime package, and a lifecycle binding a finalizer may call is never delivered.

### What a script calls

Identities are plain data: a TID is the record `{runtime, owner, id}` and an owner reference `{runtime, owner}`, all
integers (`instanceIdValue`, `ownerRefValue` make them). They name and grant nothing: a script can forge any
number, and reaches exactly what its grant covers.

| Call | Answers |
|---|---|
| `pause(tid)`, `resume(tid)`, `stop(tid)` | `{accepted = true, receipt = n}` or `{accepted = false, refusal = reason}` |
| `result(n)` | `pending`, or one of `applied`, `already_in_state`, `no_longer_applicable`, or `unknown_receipt` |
| `forget(n)` | whether the receipt was held |
| `inspect(tid)` | `{ok, refusal?, snapshot?}`: the TID, the owner's label, the name and the status |
| `inspect_owner(ref)` | `{ok, refusal?, instances, truncated}`, in order of identity |
| `owners()` | `{owners, truncated}`: the covered owners with their label and what each permits |
| `self()` | the calling instance's TID, or nil |

There is no call that controls an owner as a whole.

### Requests and refusals

A request never blocks, and every refusal is an answer, never a fault. They are decided in this order, and the order is
the contract: `unauthorized` (the owner is outside the grant, or the grant does not permit the operation there: nothing is
tested of the target, so an owner outside the grant, another runtime's identity and an identity never issued answer
alike; it is also the answer to a request made when no instance's code and no task's segment is running, such as an
initial chunk's or a module's top level, which has no caller to read its answer or to abandon it); for a target admitting logically, `unassigned` (the application is asked for the request's place once the grant
has passed it, and gave none); `full` (the caller already holds as many receipts as its grant allows); `closed` (the
target's owner is stopping or has exited); `unknown_target` (within the authorized owner, no live instance has the
identity: ended, stale or never issued); for a target admitting logically, `late` (the tick has begun) and `duplicate`
(the place is taken); and `full` (the target's owner holds every result reservation it may). Inspection is refused as
`unauthorized`, `closed` and `unknown_target`, in that order. Routing is by identity and never by label, so two owners with one label
are told apart. A request that is accepted reserves its result at the target before it is accepted, and the receipt at
the caller in the same transaction.

### Receipts

An accepted request settles exactly once: `applied`, `already_in_state`, or `no_longer_applicable` (the instance ended
first, a stop superseded it, or its owner stopped, failed or was cancelled first). A receipt is held until it is read
once settled (reading consumes it and gives the reservation back; any later read answers `unknown_receipt`), forgotten
(the reservation comes back when the request settles), or abandoned: when the instance that made the request ends, when
a task that made it ends, and when the caller's owner exits. A closing handler a script defined runs as the instance or task
whose coroutine is being closed, so it asks and reads as that caller and what it asked is abandoned with it. Only the instance or task that made a request reads its
receipt. Abandoning interest never undoes a request already accepted: it is still applied, or settled, by its target.
The engine keeps no other history of results; what is held is bounded by `grantReceiptBound`.

### Self-control

An instance may ask for its own control. The request is not applied inside the segment that made it: the target applies
requests at its safe boundaries, so the segment returns or yields first, and its own inspection inside it still reads the
status it had. The stop precedence of the Haskell API is unchanged.

### Inspection

`inspect` and `inspect_owner` read one transaction each, so an owner's snapshot is coherent, and borrow no Lua table. A
snapshot holds the TID, the owner's label, the name and the status (`initializing`, `active`, `paused`, `stopping`,
`completed`, `stopped`, `failed`). The count is bounded by the grant's snapshot bound and the size by the owner's value limits:
a list that would not fit is cut, and says so (`truncated`), and never faults the script.

### Logical admission

An owner configured with `instanceControlAdmission = AdmitLogically` admits the controls made through a grant by the tick
and sequence the application assigned each (D-23). The grant carries an `AssignControl` for such a target, which the engine
calls for every request that passes the grant, telling it the calling owner, the calling instance, the target and the
operation, all of them the engine's own knowledge; it answers a `ControlSlot` or declines. The request is applied at the
logical boundary of its tick, before that tick's ordinary work and cadence point, in the order of (tick, sequence), whatever order
requests arrived in and whichever VM sent them. The scheduler holds the grant that reaches such a tick, as it holds one a
cadence point or a woken task owes work for, and applies no later grant, until the owner has applied the tick's controls, so
grants queued together act exactly as grants served one by one; and the cadence points the tick reached are still the
scheduler's while the controls are applied, so a pause and a resume assigned to a tick invalidate a point due at it, and the
next update is a full interval after the resume. One assigned a tick the owner has begun is refused as `late`, one assigned
a place another request holds as `duplicate`, and one given no place as `unassigned`; none is ever applied at another
boundary. Admission reads the tick and enqueues in one transaction, so a request accepted for a tick is always queued before that
tick is visible. A request waiting for its tick holds its reservation, and settles as no longer applicable if its instance
ends or its owner exits first; its place stays taken until its tick begins whatever became of the request, and the places
queued are bounded as the reservations are (a request is refused as `full` when the queue holds that many). The application's own `requestInstanceControl` is admitted on arrival whatever the owner admits,
and `requestInstanceControlAt` takes a place from the Haskell API.

### Determinism

The same tick-assigned requests give the same sequence of controls, and so of effects, however the threads that made them
interleave: the order is (tick, sequence) and nothing about arrival. Requests admitted on arrival are not ordered logically.

### What proves it

`Test.LuaRuntime.Lifecycle.*`, in `lua-runtime-tests`, run real instances on two or more real supervised scheduled owners,
under injected clocks and fake wakes, with gates and barriers and no sleeps: one registration shared by owners with different
grants, authority and its refusals, control across owners and its receipts, every refusal, exactly-once settlement whatever
ends a target first, abandonment by a caller's instance, task or owner, self-control, inspection and its bounds, and logical
admission (order independence, late, duplicate, unassigned, before-the-tick's-work, racing the grant that begins a tick,
and retirement). The host library's examples (`Test.Lua.Boundary.*`) pin that a lifecycle operation is delivered only
to an owner configured with a context. Cancellation and shutdown windows are the kind an asynchronous-exception race can
hide on one platform, so CI, which runs them on Linux, is the evidence for them and a local pass is not.

## Asynchronous requests

`Hetoimasia.Scripting.Lua.Provider` and `Hetoimasia.Scripting.Lua.Request` (LUA-7, in `runtime-lua`) let a script ask
for something an engine operation will answer later (pathfinding, an asset load, a query) without blocking its owner
and without a provider's thread ever entering Lua. They follow P-7 of [the Lua runtime
design](../../docs/lua_runtime_design.md): a component-local protocol, not an engine RPC bus. A bounded
single-assignment result slot is reserved before a request is accepted; a response fills it without waiting on a
shared queue; the session, domain, request identity and generation are carried; every admitted request settles
exactly once, with a result, a failure or a cancellation; and a duplicate, late or stale reply cannot overwrite it.
Cancelling revokes interest and is not proof that native work ended, so what the provider borrowed stays owned until
it proves the work over. The mechanics are proven with fake providers. Subscriptions and provider events are
[LUA-26](../../docs/lua_runtime_design.md#lua-26-deliver-provider-events-through-owned-lua-subscriptions)'s, which
reuses this section's granted service, guard and epoch operation unchanged.

### Granting the service

A scheduled owner is granted the service when it is created, with `scheduledRequests ∷ Maybe RequestGrant`. A
`RequestGrant` names the providers' endpoints (`RequestEndpoint`: a name, the schema of what the provider answers, and
how a request is handed to it), the bound on the requests the owner holds, and when settlements reach Lua
(`RequestTiming`). The grant is the whole of the authority. An owner created with none keeps the
`NotYetSupported` fault every asynchronous request answered before, with its action never run, whichever registration it
was given; the finalizer refusals do not change (an asynchronous binding still cannot be declared finalizer-eligible,
and a call made while the VM closes is still refused with `FinalizerRefused` before dispatch). A grant that does not
make sense (a bound below one, no endpoint, an invalid or repeated endpoint name, a result schema that names a
capability, or value limits too small to hold the smallest failure or cancellation record a script is handed:
`SettlementsDoNotFit`) is refused before anything starts as `RequestGrantRefused`, naming every reason. One registration serves
any number of owners with different grants, because the binding's action is handed the *owner's own* `RequestContext`,
read from the owner's configuration and never from a value a script supplied (`asynchronousNativeRequestIn`).

### What a provider implements

An endpoint's `endpointSubmit` is handed a `Submission`: the request's arguments (bounded copies), a `Completion` and
the request's identity (`RequestInfo`: the owner, the instance, the endpoint and the request's number). It answers a
`ProviderWork`, which is how the engine later withdraws interest (`workCancel`) and reads where the provider's own
retirement of the work has got to (`workRetirement`, a transaction that must not retry and only reads: what it writes
is not kept). The provider answers through
the `Completion`, from any thread, now or later: `ProviderResult` with a value, or `ProviderFailure` with a reason.
Completing is one transaction that writes the request's reserved slot, or holds the answer, and never waits for the
owner, a queue or Lua, so a full owner never makes a provider's thread wait. The answer says what became of the
reply (`ReplyAnswer`): settled, held for its tick, refused for its size or shape, late, or unknown. None is an error;
a duplicate, late or stale reply is evidence about the provider, is counted, overwrites nothing, and still retires
the provider's work.

A reply is bounded before it is retained, against the owner's value limits and the endpoint's schema, and what is
measured is the record a script is handed when it takes the result, not the bare value, so a result that is
retained is a result that can be delivered. A result over the limits settles an unsettled request as a failure, its
value never kept, and retires the provider's accounting, as the model's `applyReplyIn` does; so does a result that is
not what the endpoint declares. The same holds for a failure: a provider's failure reason is bounded, and one whose
record would not fit the limits is retained as a failure that says so. Every record a script is handed (result,
failure, cancellation) fits the owner's limits. Taking a settlement retires its handle, so it never loses one to a
fault: a result that the taking operation itself cannot hold (its declared schema is not the endpoint's) is
delivered as a failure that says so.

### What a script sees

A binding's author starts a request with `startRequest` and returns the handle as a capability
(`requestHandleValue`, of a type declared with `requestHandleType`). The generic operations a script uses on it are
supplied by `requestBindings` (a namespace the application names): `ready(h)` answers without blocking whether the
request has settled; `take(h)` takes the settlement once, as `{status, value, reason}` (`"pending"` without taking
anything, or `"result"`, `"failure"` or `"cancelled"`), and retires the handle; `cancel(h)` settles the request as
cancelled (or answers `"settled"` when it settled first and keeps its settlement); and `wait(h)` gives control back,
cooperatively and without blocking the owner, until the request has settled. A wait in `init` or `shutdown` is a
hook fault as any wait is there; an owner with no service answers the wait `NotYetSupported`.

A handle carries no authority. It names a request of the instance, or task, that made it; another requester's handle,
one whose settlement was taken and one that names nothing are refused as a fault of the call, never run.

### Admission and the reserved place

`startRequest` never blocks. It is allowed in any invocation of an instance that is taking requests, `init` included,
and from a task's segment. It reserves the request's place in the protocol model's session before the provider is
asked anything, and the place is held until the settlement has been taken or discarded *and* the provider has proved
its work over: a result nobody took counts, and so does a cancelled request whose provider has not finished.

A request is refused, as a fault of the call and never a failure of the host, and with the provider asked nothing,
in this order: when no instance or task is running to receive the answer; when the owner or the instance is no longer
taking requests (it is stopping, which a `shutdown` hook and a coroutine's closing handlers already are, and so
is a task whose coroutine is being closed); when the
application's assignment declined to place it; when the tick assigned is one the owner has begun; when the place
assigned is taken; and when every place is held. An endpoint the grant does not name is the application's own mistake
and a failure of the host.

### Whose a request is

An instance owns its requests, not the invocation that admitted them. They survive that invocation's end until their
settlement is taken, they are cancelled, or the instance ends; ending an invocation's task revokes nothing. This is
the model's *holder*: an identity the session issues for an owner that is not one of its tasks, ended with the instance
through the same revocation a retiring task's requests go through. A task of the owner that is no instance's invocation
owns its own, and they are revoked at the first safe boundary after it ends.

When an instance ends (a stop, a failed `init`, a faulting invocation, a one-shot's completion, the owner's exit) each
of its requests settles once, as cancelled by the requester's end, and the providers are told once. The instance's
settlement then *waits* for those providers to prove their work over, as it waits for a lease's retirement, so
nothing is reported as stopped or reclaimed merely because Lua stopped. A scheduled owner's exit does the same for
everything left: it revokes, tells the providers and stays live, through a stop and through a cancellation, until each
has said it is done.

### Settling on arrival, and at an assigned tick

`RequestTiming` is the owner's kind of time. **`SettleOnArrival`** is an owner on elapsed time: a reply settles the
request when it arrives, the first settlement wins, and the waiting script resumes at the next safe boundary after it.
A cancel that finds the request settled is refused, counted (`rdLateCancels`), and the settlement stands. While the
instance is paused a settlement is retained in its slot without resuming Lua (D-26).

**`SettleAtAssignedTick`** is an owner on logical time (D-23, D-36, D-39). The application's policy, called through
the binding that admits the request, assigns the tick its settlement is due (`AssignRequest`, which may decline,
and by default the next tick) and the place among the requests due then, as LUA-23 assigns a control's. A tick the
owner has begun is refused as late, and a place that is taken as a duplicate. Then:

* a reply that arrives *before* the due tick is a **held completion**, kept in the request's record and not a
  settlement, until the request's place is served at the boundary of its tick (so a duplicate that arrives after
  the owner applied the tick and before it served the place is still a duplicate). The first is kept; a later one is counted (`rdDuplicateHeld`) and never replaces it or resurrects a
  value a cancel discarded; the script cannot see it, and readiness reports pending;
* the tick does **not begin** until the request is complete. The scheduler holds the grant that would reach it
  (`holdTick`), as LUA-23 holds a tick for its controls, until the completion is held or the request is cancelled
  or its requester ended. A slow provider stalls the owner only at its tick, a provider that never answers stalls
  it there until its stop or failure ends the request, and later grants wait behind the held one in order;
* a **cancel before the due tick always wins**: the request settles `Cancelled` whatever the provider has done, any
  held value is discarded without reaching Lua, the tick's hold is released and the provider's work is retired. The
  same cancel gives the same `Cancelled` settlement and the same recorded effects whether the reply arrived before it
  or after;
* a request that is not cancelled settles at its tick, at the boundary where the grant that reached it is held, in the
  order of the places, with what the provider delivered, and the tasks waiting for them are woken in that order.
  Readiness answers from logical state: pending before the tick, settled from it on.

The one watch the owner keeps on a tick is shared with LUA-23's tick-assigned controls and with cadence points: each
is served at the boundary of its tick, controls first, and what is next watched for is the earliest tick any of them
is still waiting for, taken in the same transaction as the step that served the last, so none leaves another
without its watch. An owner that hosts no instances serves the watch's points itself. No ordinary work for the due
tick begins while a required completion is pending, cadence work included.

### Cancellation and the provider's lifetime

Cancellation (a script's, the requester's end, an epoch change, the owner's stop) revokes interest and settles the
waiter `Cancelled`. It does not tell the engine the work ended. Outstanding provider work is a **retained
retirement obligation**, and it is the same one the instance leases keep: the primitive (`Hetoimasia.Scripting.Lua.Retention`:
`Obligation`, `RetirementState`, the single reading `pollObligation`, the single guard `guarded`, and the
disposals held behind obligations and run only after they completed without failure) is shared by a lease's
`retireAsynchronously` and by the request service, which keeps no copy of the rules. The request's work is not a
lease and is not charged to a lease slot or to lease capacity; it is charged to the request bound (the request's place
is held until the provider proves its work over), and it stays so until the provider proves it over, by replying or
by its own reading (`workRetirement`). A binding's `afterCompletion` (what the work needed, such as a borrowed
dependency) is disposed of on the owner's thread, uninterruptibly, only after that, and never if the retirement
failed; a retirement failure is a cleanup failure, fatal under every policy. The provider is told *once* that
interest was withdrawn, as soon as it can be; a provider that had already finished is not asked to stop. The model is
told the work is over whenever its request has settled and the work is known over, whichever came last, so work
that ended long before the request settled (a completion held for its tick) never leaves a place charged.

### Epochs

`advanceRequestEpoch` (P-9) replaces the generation of an owner's records at a moment the application chooses.
Every outstanding request settles, once, as cancelled by the epoch change, and its script can take that; a cancellation
nobody has taken is still a place held, charged to the bound until it is taken, so repeated epochs cannot accumulate
more than the bound; a settled result nobody had taken is discarded with the epoch's records, as the model discards
it; the ticks the requests held are let go; and the providers whose work that was are told by the owner at its next
boundary, as for every other withdrawal of interest, so one that raises is a failure of the host under the owner's
policy and nothing is raised on the application's thread. The accounting for work that is not over is retained under
the identities it was issued under, so a late reply retires it without reaching anything the new epoch issues.
Instances and tasks are not invalidated by it.

### The guard, and what a failure is

Every call into provider code (handing a request over, withdrawing interest, reading a retirement, disposing of what
the work needed, and the application's assignment) goes through **one guard**, `guarded` (its transactional form,
which the provider's own reading uses, is the same one the leases use), and is fully evaluated inside it. Nothing
is dropped: where failures arise together the first is raised and the others are kept whole as cleanup evidence.

* A provider reporting a failure is a reply, and settles the request as a failure, returned as data.
* Provider code raising when the engine calls it (handing a request over, withdrawing interest, the assignment) is
  a failure of application code: a failure of the host under the owner's `WorkerPolicy`, unconverted. A request
  whose handoff raised is taken back as though it had never been admitted.
* A provider's retirement that fails, and the disposal of what its work needed that raises, are cleanup failures:
  retained on the work, never retried, fatal under every policy. Servicing answers each once, and recording it is
  the same masked step, so a cancellation of the owner cannot come between and lose it; the same holds for a tell
  that was claimed.

### Determinism

On one logical owner, identical inputs give identical settlements, settlement order and recorded effects however
provider delays, arrival order and segment delays vary. The inputs are the admissions with their assigned ticks,
cancels at logical points, and grants. What a binding's disposal of a dependency does follows when the provider
finished, which is not logical time, and no script can see it.

### What proves it

`Test.LuaRuntime.Request.*`, in `lua-runtime-tests`, run real instances and tasks on real supervised scheduled owners
with a fake provider the examples drive by hand, an injected clock and gates, never a sleep: admission and every
refusal, a place reserved before the provider is asked and held until its work is over; settlement on every path
with duplicate, late, unknown, oversized and malformed replies; interests admitted in `init` and in an update and
taken in a later invocation; the instance's end and the owner's stop, failure and cancellation waiting for the
provider; waits, pause, readiness and hook faults; a provider that raises, a retirement that fails, and failures
arising together; a completion that never waits for the owner; the assigned tick, the held completion, the tick held
until the provider completes, a late, unassigned or duplicate place, the cancel that wins whichever of the reply
and the cancel came first, the order of the places, holds shared between requests, cadence work and controls, and
determinism across arrival orders; and epochs. The protocol model's holders are pinned in `lua-host-tests`. The
cancellation and cleanup windows are the kind an asynchronous-exception race can hide on one platform, so CI, which runs
them on Linux, is the evidence for them and a local pass is not.

## Provider events

`Hetoimasia.Scripting.Lua.Provider` (LUA-26, in `runtime-lua`) lets an instance subscribe a function to the events
a provider delivers, without a provider's thread ever entering Lua. It follows P-7 of [the Lua runtime
design](../../docs/lua_runtime_design.md): a subscription is an owned record with bounded delivery, unsubscribe and
invalidation; a producer never invokes a Lua closure on its own thread, and the owner looks up the still-live callback
when it services an event; overload is stated per endpoint, and there is no universal lossy stream. It is built on the
granted provider service, the one guard and the epoch operation of [Asynchronous requests](#asynchronous-requests),
used unchanged, on the shared retained-obligation primitive of the instance leases, and on the protocol model's
subscription records ([The protocol model](#the-protocol-model)).

### Granting the subscriptions

A scheduled owner that is granted the request service (`scheduledRequests`) and hosts instances can also be granted
subscriptions, with `scheduledSubscriptions ∷ Maybe SubscriptionGrant`. A `SubscriptionGrant` names the providers' event
endpoints (`EventEndpoint`: a name, the schema every delivery must conform to, the endpoint's `OverloadPolicy` and how a
subscription is handed to the provider), the bound on the subscriptions the owner holds, and the bound on the events a
logical owner holds for ticks it has not reached. The grant is the whole of the authority: an instance's `api` can
subscribe only to an endpoint the grant names *and* the instance was granted (`instanceGrants` names endpoints beside event
sources). An owner created with no grant leaves `api.subscribe` refused as not yet supported, with its action never run.
A grant that does not make sense (a bound below one, no endpoint, an invalid or repeated endpoint name, a payload that
names a capability, more endpoints than the driver module can declare entry points for beside the owner's sources, an
owner with no request service or no instances) is refused before anything starts as `SubscriptionGrantRefused`, naming
every reason. The owner's kind of time is the request grant's (`RequestTiming`): an owner that settles at assigned ticks
admits events at assigned ticks, and one that settles on arrival admits them on arrival.

### What a provider implements

An endpoint's `eventSubscribe` is handed an `EventSubscription`: an `EventFeed` and the subscription's identity
(`SubscriptionInfo`: the owner, the instance, the endpoint and the subscription's number). It answers a `ProviderWork`, as
a request's provider does: `workCancel` withdraws the engine's interest (called once, on any path that ends the
subscription) and `workRetirement` reads where the provider's own retirement of it has got to (a transaction that must not
retry). The provider delivers through the feed, from any thread, now or later:

* `feedDeliver place value` delivers one value. It never blocks and never waits for the owner, the queue or Lua. On an owner
  on elapsed time the place is `Nothing` and the value is admitted on arrival. On an owner on logical time the application
  assigns the place, `Just (DueSlot tick sequence)` (D-36); the delivery is held until that tick's boundary.
* `feedFail reason` surfaces a delivery failure: the provider cannot preserve an authoritative event. The instance fails with
  it (`ErrorDelivery`), once, and the application's escalation (`instanceEscalate`) decides what that means for its peers; the
  simulation cannot go on as though the event had been delivered.

The answer says what became of a delivery (`EventAnswer`), and none is an error: `EventAdmitted`, `EventCoalesced`,
`EventStaged`, `EventQueueFull`, `EventStagingFull`, `EventEnded`, `EventRefusedValue`, `EventLate`, `EventDuplicate`,
`EventUnassigned` and `EventNotLogical`. A refusal is evidence about the provider: it is counted, and the value is not kept.
A delivery is checked before anything is retained, against the owner's value limits and the endpoint's schema. What is
measured is what the callback's entry point is handed: the instance's number and the record naming the endpoint and the
subscription, which the host checks together (so a payload that fits the record alone and not the record with the number is
refused to the producer, and never accepted and then fails the instance). It is copied to buffers of its own, so a small slice
of a large text or byte string does not keep the whole buffer alive while the delivery waits, which the limits do not count, and
it is fully evaluated, all inside the guard: a value that throws when it is first looked at is a refused delivery and not an
exception loose on the producer's thread. The reason of a `feedFail` is bounded (512 characters) and copied the same way.

### What a script sees

`api.subscribe(endpoint, callback)` subscribes a function to an endpoint and answers a handle; `api.unsubscribe(handle)`
ends the subscription and answers whether it ended a live one (`false` for one that had ended already: unsubscribe settles
once). A callback is handed the instance's `self` and a record `{source, sequence, tick, subscription, payload}`: `source`
is the endpoint, `sequence` is the place admission gave the delivery among the instance's invocations, `tick` is the
logical tick it was admitted at and `subscription` is the subscription's number. Subscribing is allowed in `init` and in
any invocation of an instance that is taking subscriptions, and is refused, as a fault of the call and never a failure of the
host, when the instance is stopping (a `shutdown` hook is past taking them), when the endpoint is not one the instance was
granted, and when every place is held. The provider is asked nothing of a refused subscription. A provider that raises when
it is handed one is a failure of the host, unconverted, and the subscription is taken back as though it had never been
admitted.

### Whose a subscription is, and where deliveries wait

An instance owns its subscriptions, not the invocation that made them: they survive that invocation's end and every callback
after it, until the instance unsubscribes them, an epoch changes, or the instance ends. This is the protocol model's
*holder* (the same one the instance's requests use): the model's subscription records are owned by an identity the session
issues for the instance, ended through the revocation a retiring task goes through.

A producer's delivery takes a place in the instance's one bounded queue of invocations (`boundInvocationQueue`), shared with
its events and its due update, as a *reference* to the subscription: the payload stays in the model's record for the
subscription, and is taken as the callback's first segment is about to run. A delivery keeps its sequence, its logical tick
and its place in the queue until then, whatever happens, paused included (D-26): a paused instance's deliveries are retained
in order and run after the resume.

* **Ordered events** take a place of their own and are refused, counted (`readingRefused`, `snapshotQueueFull`) and never
  evicted when the queue has none. A provider whose event is authoritative surfaces the refusal with `feedFail`.
* **Replaceable state** keeps at most one unstarted delivery per subscription. A later value replaces that delivery's payload
  and tick *in place*, keeping its place in the queue and taking no further place; the value it replaced is counted as
  coalesced and was never delivered. Filling an empty slot needs a place in the queue, as an ordered event does; replacing
  needs none. "Unstarted" lasts through the callback's first segment, including the time after the owner selected the
  delivery for its next invocation and before that segment runs; once the segment begins the payload is the callback's and
  immutable, and a later value is a delivery of its own behind it.
* A delivery to a subscription that has ended (unsubscribed, invalidated, or ended with its instance or its owner), or whose
  instance is stopping, is refused and counted (`EventEnded`), never run, and on a logical owner never held for a tick the
  instance will not reach. One accepted and not yet begun when its subscription ends is discarded, counted by
  the model, and never run; an invocation already selected for it completes without entering Lua.

### Logical event admission

On an owner driven by logical time, provider events are admitted by application-assigned tick and sequence (D-36), as
LUA-23 admits controls, and never in arrival order. A delivery with a place is held, in a store bounded by the grant
(`grantStagingBound`, refused and counted as `EventStagingFull` past it) and keyed by its place (a place that is taken is
`EventDuplicate`, a tick the owner has begun `EventLate`, and one with no place `EventUnassigned`). The owner asks to be held at
the earliest tick it holds an event for, in the same transaction as the delivery, so the grant that reaches the tick is held
until the owner has served it.

At that boundary, after the controls the tick holds and before any task the tick woke, the owner admits the events due, in the
order of their places, through the one function that applies the queue's bound and the endpoint's overload policy. That is
where an ordered event is refused for want of a place, or replaceable state coalesces, so which input is accepted and which
value a callback sees follow the logical sequence and not how fast the owner served; a value assigned to a later tick never
replaces one that was visible at an earlier tick. An ordered event that is accepted for a tick and cannot be admitted at it
(the queue is full) cannot be reported to the provider that is no longer waiting for an answer, so it is surfaced as the
delivery failure it is, exactly as `feedFail` is, and is counted; a refused fill of replaceable state is counted and fails
nothing, since only the newest value of a state matters.

**The tick's claim.** A tick whose grant is applied is held, by the owner's one watch, for as long as any instance has a
delivery of a subscription that is admitted and unfinished (waiting in its queue, selected for its next invocation, or being
run by the invocation in flight) *and* can make progress in that tick: it is serving, and the invocation in flight is ready to
run a segment (it yields and goes on, or it has just ended and the next is about to be given a place), or nothing is in flight
and the next delivery waits its turn and something is ready to run. An instance whose work is suspended on a wait (a tick, a
deadline, a request) cannot, and neither can one that is paused, stopping, ended or still initializing: the tick does not wait
for it, and it claims the tick it is woken at, and later ones, as it becomes able, by the same rule. While any instance has such
work the owner also asks to be held at the next tick, so every grant it applies is looked at before any task it woke is chosen.

The claim is computed in one place from the instances' state as it is, and never from a flag set when a delivery was admitted,
so no path that changes a delivery's state can leave a tick claimed that nothing needs, or unclaimed that something does:
admission, selection for an invocation, a yield, a wait and the grant that resumes it, a coalesce, an unsubscribe, an epoch
change, a pause and a resume, a stop, and a failure each change what that function reads. So the next tick's deliveries are not
admitted while this tick's can still run, a callback that yields or waits for a tick waits for the same tick however the grants
behind it were queued, several deliveries admitted at one tick each start at the tick their predecessor ended at, and queued
grants give the same admissions and effects as grants served one at a time.

### Epochs

`advanceRequestEpoch` replaces the generation of an owner's records, and invalidates every subscription with them, as the
model's `advanceEpoch` does: each subscription ends once, the events held for it and its unstarted deliveries are discarded
and counted, and the providers are told by the owner at its next boundary. The accounting of their work is retained under the
identities it was issued under, so a late delivery from an old producer finds nothing, cannot reach a subscription made in the
new epoch (an identity carries its epoch and a generation that is never reissued, so the same local number does not give it
somewhere new to land), and the places stay charged until the providers prove their retirements over. Instances are not
invalidated: the same instance subscribes again. The instance's VM is not left holding what it captured for the subscriptions
the engine ended: the owner has the driver let go of their callbacks and handles at its next boundary, without the script
unsubscribing them (the driver's creation entry on a slot that is live is that cleanup point, and it asks the engine for the numbers that
ended one at a time, so the answer fits any limits however many ended; an epoch wakes the owner once for an instance, however
often it changes before the owner gets there), so repeated subscribe, epoch-change and retirement cycles do not grow the VM.

### Retirement and the bound

Outstanding provider work is a retained retirement obligation, the one the instance leases and the request service keep, and it
is charged to the subscription's place in the owner's bound until the provider proves it over. A subscription that ended still
holds its place while its provider's retirement is pending, so subscribing and unsubscribing over and over cannot reclaim
capacity. An instance's settlement waits for the providers of its subscriptions, as it waits for a lease's retirement:
nothing is reported as stopped merely because Lua stopped, and the owner's exit waits, uninterruptibly, through a stop and a
cancellation, until each has said it is done.

### The guard, and what a failure is

Every call into provider code for a subscription goes through the one guard and is fully evaluated inside it: subscribing,
withdrawing interest, reading a retirement and reading a delivery. Where failures arise together the first is raised and the
others are kept whole as cleanup evidence; nothing is dropped.

* Provider code raising when the engine calls it (handing it a subscription, telling it interest was withdrawn) is a failure of
  application code: a failure of the host under the owner's `WorkerPolicy`, unconverted.
* A provider's retirement that fails is a cleanup failure: retained on the work, never retried, fatal under every policy.
* A provider that cannot preserve an authoritative event surfaces a delivery failure, which fails the instance (above).

### Determinism

On one logical owner, identical inputs give identical event admission order and recorded effects, however the producers'
arrivals, the grants' pacing (queued or served one at a time) and the segment delays vary. The inputs are the events with their
assigned ticks and places, and the grants.

### What proves it

`Test.LuaRuntime.Subscription.*`, in `lua-runtime-tests`, run real instances on real supervised scheduled owners with a fake
provider the examples drive by hand, an injected clock and gates, never a sleep: a producer from other threads that never blocks
and never calls Lua; ordered events and their refusal at capacity; replaceable state coalescing in place, at capacity, through
the delivery the owner selected for its next invocation, and not once a callback has begun; unsubscribe and stop settling once,
in either order; every way an instance can end revoking its subscriptions and its stop waiting for the provider; a subscription
made in `init` surviving every callback after it; a paused instance retaining its deliveries; a refused subscribe; logical
admission by assigned place under reversed and permuted arrivals, late, duplicate and unassigned places and a full store, the
queue's overflow decided at the boundary, queued and individually served grants, and the tick not waiting on what cannot start;
epochs, generations and the bound that churn cannot reclaim; a provider that raises, a retirement that fails and failures
arising together; unfit and throwing deliveries; and every grant that is refused. The protocol model's holders of
subscriptions are pinned in `lua-host-tests`. The cancellation and cleanup windows are the kind an asynchronous-exception race
can hide on one platform, so CI, which runs them on Linux, is the evidence for them and a local pass is not.

## The script runner

`Hetoimasia.Scripting.Lua.Runner` (LUA-27 and LUA-28, in `runtime-lua`) runs a list of scripts, each a file, as instances of one
named VM, on the elapsed clock or on logical ticks it grants at a real-time rate, and answers a bounded report of the run. It is the
layer under the `lua` subcommand (LUA-19) and under a windowed application alike. It publishes an event when an instance starts and when
it ends, to the scripts that subscribe. It parses no arguments, installs no signal handler, never calls `exit`, opens no window and imports nothing of the
console, GLFW, Vulkan or a game: what the outside world does is injected. Its behavior is [D-40 and D-42 of the Lua runtime
design](../../docs/lua_runtime_design.md#d-40-the-headless-runners-clock-ending-event-source-and-exit-statuses), over the
instance contract (D-26, D-27), and it reopens none of the contracts it is built on.

```haskell
runScripts ∷ LuaRuntime → RunnerConfig → IO RunOutcome
```

### What a run is given

`RunnerConfig` holds the VM's name (`runnerName`, the owner label the tables and reports show), the scripts
(`runnerScripts`), an optional run limit (`runnerLimit`), an optional tick duration (`runnerTick`) with an optional limit of ticks
(`runnerTickLimit`), and the inputs that are not data: the stop request
(`runnerStop ∷ STM Bool`, which the run waits on and never polls), the monotonic clock and the timer backend
(`runnerClock`, `runnerTimer`; `runnerConfig` supplies the production ones), the output sink and the error sink
(`runnerOutput`, `runnerErrors ∷ Text → IO ()`) and a `Logger`. A `Script` is a file path, an optional name (without one, the last
component of the path) and an optional interval: a positive elapsed duration (`Script path name (Just duration)`), or on a tick VM a
positive whole number of ticks (`everyTicks n (script path)`). The `LuaRuntime` is the one a `withSupervision`
boundary made: the owner the run starts is one of its supervised workers.

A run admits at most `runnerMaxScripts` (64) scripts. The scheduler and instance bounds are the runner's own, documented
constants (`runnerSchedulerBounds`, `runnerInstanceBounds`) that pass the instance configuration's validation: the
live-instance bound is the most scripts a run admits, and the retained results are twice that.

### Loading

The host reads nothing from disk, so the runner reads each *distinct* path once, in order (a path is distinct by its text;
nothing is resolved), and hands the host the bytes as a module. A read is bounded by the host's source limit: no more than one byte
past it is read, and a file over it is refused. A path named twice is read and loaded once and admitted twice. A module's identity is its
place among the run's distinct paths, a colon and the end of its path, with control characters replaced and cut to the host's
128-byte rule: two distinct paths never share one, even with the same file name in different directories, and it is the same for
the same scripts every time.

A missing, unreadable or over-bound file, and a module the host rejects (a syntax error, an error at its top level), are each *a source that
did not load*. It fails the VM's start and not an instance: the run ends with `EndedStartupFailure` and a `LoadFailure` naming the
file as it was given, the VM, the error and the traceback if one was captured, each bounded, and no TID. The first one in script
order is the one reported, and the top level of the modules before it has run, as the host's load order has it; no instance is
admitted and no `init`, `run`, `update`, callback or `shutdown` runs. The VM is retired. The status is failure.

### The kind of an instance

The owner reads, once, before it is ready and running none of the module's code, which of the optional hooks `init`, `update`,
`shutdown` and `run` each module it loaded defines, and answers `moduleHooks` (in `Hetoimasia.Scripting.Lua.Instance`) from
that reading for the owner's life. An entry that is present and is not a function counts as defined, as the instance's own check counts it.
A module defining `run` is a one-shot, one defining `update` is looped on the script's interval, and one defining neither is an
event-only instance. These are refused as usage, before any instance is admitted and before any hook runs, naming the script: a
module defining both `run` and `update`; one defining `update` with no interval; an interval for a module that does not define
`update`; no scripts at all; more scripts than a run admits; a zero interval or a zero limit; and, for the clock: a tick duration of zero
(`TickDurationNotPositive`), an elapsed interval on a tick VM (`ElapsedIntervalOnTickClock`), a tick interval on an elapsed VM
(`TickIntervalOnElapsedClock`), a tick limit on an elapsed VM (`TickLimitNeedsTickClock`), and a tick count, as a limit or as an interval,
that is not positive (`TickCountNotPositive`) or does not fit a 64-bit tick (`TickCountTooLarge`). A refusal is the distinct outer result
`Refused (UsageRefusal reasons)`, never a report of a run, so the command line can map it. Where it needed the VM to ask, the VM that
was started is retired.

### The VM

It opens the base, string, table, math and coroutine libraries and no others; `io`, `os`, `package` and `debug` stay closed. The policy is
`fifo`, the only built-in one. The owner hosts instances with no event source of the old kind, and holds the request service and the subscription grant that the instance events
need ([Events](#the-instance-events)). On the elapsed clock it has no tick duration and admits controls on arrival. On a tick VM it is hosted with the
tick duration and admits controls logically ([Ticks](#the-tick-clock)). Every instance's failure is isolated (the runner's answer to the escalation decision is
always `Isolate`). The lifecycle bindings are registered as `lifecycle` (`runnerLifecycleName`): `pause`, `resume`, `stop`, `inspect`,
`inspect_owner`, `owners`, `self`, `result` and `forget`, as [Lifecycle services](#lifecycle-services) documents them. The owner is
granted every control and inspection permit over its own VM's instances and nothing else, so one script can pause, resume, stop and inspect
another, and itself. Scripts are trusted (D-12): nothing here claims a sandbox.

### Admission

Scripts are admitted one at a time, in the order they are listed, each only after the previous instance's `init` has finished or failed and the owner
has nothing left to do (every instance quiet, which the runner reads from one inspection: nothing initializing or stopping, nothing ready or running,
no event queued, no update owed, no one-shot's `run` yet to execute; a paused instance is quiet, and so is one whose invocation is suspended on a wait, however much is queued behind it: the owner can do nothing for it until its wake, a tick or a time that a grant of the runner's brings). So TIDs ascend in script order
and the order of the `init`s is the script order, on both clocks. A failed `init` does not stop later scripts from being admitted. The wait is
the run's one wait: a stop request, the duration limit or the owner's exit during admission admits no further script, the instances admitted are
stopped in ascending TID order and the tables list them. While one instance is admitted the owner is held, before its next segment, at the gate the
runner installs as the owner's segment observer; the instance's *started* event is produced while it is held, and only then does the owner run the
instance's `run`. That is what makes a one-shot that runs, ends or unsubscribes at once give the same events as one the runner's thread observes
promptly: the owner is never ahead of the runner's coordination. The gate is released on every way out of the admission and before every retirement.
`runnerInstanceBounds` queues for twice as many invocations as a run has scripts (128), so a watcher with one subscription never overflows in the
ordinary case.

### The tick clock

With `runnerTick = Just d` (a positive duration of whole nanoseconds) the VM is a *tick VM*: it is hosted with tick duration `d`, admits Lua controls
logically and takes events at assigned ticks. A looped script's interval is then in ticks (`everyTicks n`). The driver grants one tick of exactly `d`
whenever one is due: tick *n* is due *n* tick durations after the instant read when admission is complete, on the injected clock, and waited for on
the injected timer, whose wake only says to look at the clock again, so an early or a stale wake grants nothing. A tick that is late is granted at
once, one grant for each, so that none is skipped, merged or shortened and the number granted is the number due. A grant the engine answers full is
waited out and asked again; one it answers closed means the owner is stopping, and the run ends as for a stop request. After a grant the driver waits
for the engine to have finished it *and* for every instance to be quiet (a grant finishes when the work it woke has finished, which is not the owner
having nothing left to do: a resumed instance can make other work ready), and then, at the boundary, produces the ends it saw, for the next tick. The
wait is one STM wait with no polling, composed with supervision, the stop request, the limits, the owner's exit and every instance having ended.

A **tick limit** (`runnerTickLimit = Just n`, at least one) ends the run when *n* ticks have completed, exactly as a duration limit ends it: every
remaining instance is stopped in ascending TID order, its `shutdown` runs once with reason `stopped`, the VM is retired, and no tick is granted after
the stop begins. A tick that is in progress when a stop request or a duration limit arrives lets the running segment return and is not counted as
completed. Both limits may be set; the first reached ends the run. **When several endings hold together** the order of precedence is the contract, and
the tick limit is third: a failure to write, then *every instance ended* (a tick whose last instance ended is waited out and counted first), then *the
stop request*, then *the tick limit*, then *the duration limit*. A tick that has finished is counted before the duration limit is looked at. The
report says the run ended at the tick limit (`EndedTickLimit`) and how many ticks completed (`reportTicks`); the status is success only if no instance
failed (a failing `shutdown` included) and no source failed to load, as for any ending.

Every pause, resume or stop a script requests through the lifecycle namespace on a tick VM is assigned by the runner a tick, the first the owner has not
begun, and a sequence that is unique and increases in assignment order; the runner never declines to assign, so the engine's *late* and *duplicate*
answers are not reachable in a correct run. On an elapsed VM controls are admitted on arrival.

**Determinism.** On a tick VM, for identical scripts, intervals, tick duration and scheduling configuration, on the same build and platform, runs give the
same script output, events (with their ticks and places), order of controls, tables and report however long segments take, however the runner's own
threads are scheduled and whenever in real time the ticks are granted, provided the runs set no duration limit and take no external stop (those can change
the completed work when pacing changes); a tick limit is allowed. Runtime identities are unique to a run, so a comparison maps TIDs to the instance's
order in the run. The guarantee is of logical-time work: any elapsed wait a script makes keeps its wall-clock semantics.

### The instance events

Every instance is granted one ordered-events endpoint, `instances` (`runnerEventsName`), which a script reaches with `api.subscribe("instances", callback)`.
The callback is handed LUA-26's envelope (`source`, `sequence`, `tick`, `subscription`, `payload`) unchanged, and the payload is a record: `event`, `"started"` or
`"ended"`; `tid`, the record the lifecycle namespace uses (`{runtime, owner, id}`), so a watcher can hand it to `pause`, `resume`, `stop` and `inspect`; `name`, the
instance's name; and `outcome`, present only on an end, `"completed"`, `"stopped"` or `"failed"`. The request service the subscription grant needs holds exactly one
endpoint, which no namespace of the VM can start (a script has no binding that starts a request); it settles at assigned ticks on a tick VM and on arrival on an
elapsed VM, which is what decides whether the endpoint's deliveries are assigned. The endpoint's subscription bound is `runnerSubscriptionBound` (256) and its staging
bound `runnerStagingBound` (1024), sized so that a watcher with one subscription in a run of the most scripts does not overflow in the ordinary case, since each instance
produces at most two events. No capacity invariant is claimed for other subscription patterns. When the engine withdraws interest in a subscription the runner stops delivering
to it and proves its retirement at once, so no instance's stop waits on the runner.

**When an event is produced.** *Started* is produced when an instance's `init` has succeeded, while the owner is held; an instance whose `init` fails produces only
*ended*, with outcome `failed`, and an instance's *started* always precedes its *ended*. *Ended* is produced when the instance has ended. Ends seen while scripts are still
being admitted are produced after admission is complete, after every *started*; on a tick VM ends seen during a tick are produced at its boundary, after the tick has
completed; on an elapsed VM an end is produced when the run sees it. Events produced together are in ascending TID order. An event reaches only the subscriptions that
exist when it is produced, and nothing is replayed to a later subscriber. One event is delivered once to each such subscription, in ascending order of the subscription's
number, so several deliveries can go to one instance. On a tick VM every *delivery* is assigned the first tick the owner has not begun and a place of its own (a sequence that
increases in production order and then recipient order; a place is unique across the owner); on an elapsed VM each is made on arrival. The ends instances have earned are produced, and counted, once the owner is quiet and before the run ends by every instance having ended or by the tick limit, even when no later tick can deliver them; no event is produced once the orderly
stop (the stop request, the duration limit, the owner's exit) has begun.

**Overload and defects.** Every answer to a delivery is classified by one pure function (`classifyAnswer`) and none is dropped without being counted. Admitted or staged:
delivered (a staged one can still fail at its tick). Refused when offered because the queue is full (`EventQueueFull`, on an elapsed owner) or the staging store is full
(`EventStagingFull`): counted in the report by kind, nothing evicted or retried, nothing fails. A delivery staged for a tick that finds its subscriber's queue full when the tick
is admitted fails that watcher with LUA-26's delivery error (D-43): there is no second answer to the runner, the failure is reported once like any instance failure, the run's
status is failure and the report counts the watcher failed. The subscription having ended is counted and benign. Late, duplicate, unassigned, not logical, a value the endpoint's
schema refuses and coalesced (the endpoint is ordered events) are defects of the runner: they are raised as a failure of the host, never counted away.

### Output and the stream rules

Before any module loads, `print` and `warn` are rebound, by an initial chunk, to bindings that write through Haskell; the namespace the
chunk reads them from is removed from the globals, so no reference to the originals stays reachable and nothing a script runs writes
to the process's C streams. `print` joins the `tostring` of its arguments with a tab and writes the line to the **output sink**; `warn` does the
same after `Lua warning: ` and writes to the **error sink**, from a module's top level, `init`, `run`, `update`, a callback and
`shutdown` alike. One call writes at most `outputCallLimit` (4096) bytes of UTF-8 in all, as it is written (each line counting one byte more for its end), cut
with the visible marker `...` (counted in the bound), and any Lua string is accepted: it crosses as bytes, is decoded as UTF-8 with every
invalid sequence replaced, is split at its line breaks, and has its control characters (an embedded NUL included) replaced by `\xNN`
escapes, a tab excepted. The script cuts the text to the same number of bytes before it crosses, so the value boundary cannot refuse it for
length, and the runner bounds what it writes again after decoding and escaping, which can make the text longer (a NUL byte becomes four
characters, an invalid byte three).

The rules for every write: a sink is handed one line at a time, with no line break and no control character in it but a tab; a script's
text and every other text a script can influence (a name, an error, a traceback, a path) has its control characters replaced and is then cut
to a documented bound, so the bound holds for what is written and none can split a table or a report into forged lines; the runner holds one lock around each table, report or call,
so a sink is never called by two threads at once and a table is never cut by a script's output. The **tables** go to the output sink, like
`print`; the **source-did-not-load report** and every **instance failure report** go to the error sink, like `warn` (the owner's decision
on [#492](https://github.com/coghex/hetoimasia/issues/492#issuecomment-6270451945)). Which process streams the two sinks are is LUA-19's
wiring. The runner's own diagnostics (a record when a run starts and when it ends) go to the logger, under the component
`scripting.lua.runner`; script output, tables and reports never do.

### The table

At the start and at the end the runner writes a title line (`instances at start`, `instances at end`) and the table of D-17: a header
`TID OWNER NAME STATUS` and a row for each instance of the run, ended ones included, in ascending TID order. A TID has one text form
(`tidText`): the runtime's number, the owner's and the instance's, dotted, the three integers of the record a script reads from
`lifecycle.self` and `lifecycle.inspect`. The status words are the lifecycle snapshot's: `initializing`, `active`, `paused`, `stopping`,
`completed`, `stopped`, `failed`. The owner and name columns are cut to `columnLimit` (32) characters with the visible marker; a row has no
control character; a run that admitted no instance writes no table.

The start table is one coherent snapshot taken when the last admitted instance has finished its `init` or failed it, or has become terminal
without its `init` having run (a stop of an instance the owner had not begun discards it, and nothing waits for an initializer that
will never execute, nor makes it run to satisfy the barrier). Every admitted instance is a row, including one that completed or failed
before the last initializer finished: the run reads an instance's settlement without observing it, so the owner's inspection keeps the
instance for the tables. A run asked to end before the barrier opens writes no start table. The end table is taken after the VM is retired
and shows each instance's final status.

### Failures

An instance's failure is written to the error sink as one report as soon as it settles, and is in the run report. A report names the
TID, the instance's name and script, the VM, the phase it was in, the stage (`init`, `run`, `update`, `event <source>`, `shutdown`,
`release`), the error and the traceback if one was captured, each bounded, and up to `secondaryLimit` (8) other failures that happened as the
instance ended (`also failed:` lines), with the count of those not kept. A failed `init` runs none of the instance's later hooks; a failure
in `run`, `update` or a callback runs its `shutdown` once with reason `failed`; a failing `shutdown` is kept, a primary failure stays primary
and the rest are listed. Every failure is written exactly once whichever wake or ending finds it, and failures that settle together are
written in ascending TID order, all of them before the end table.

A failure of the **host** is not an instance's failure and is never turned into a report: an exception a binding or a sink raised, one the
runner raised itself and a retained cleanup failure propagate unchanged, with their type and context, under the owner's policy (an
optional worker whose classifier recognizes only the host's fault of loading a module, which is how a source that did not load is told
from a host failure: an exception application code raised is the application's whatever its type). A host failure inside the owner
ends the owner, which retires protected: Lua is not entered again, so the instances it left keep `ShutdownSkippedUnsafe`, and one whose
`init` had not succeeded keeps `ShutdownSkippedNoInit`. One raised on the runner's own thread (a sink's, as a table or a report is written)
retires the owner first, in order, as the run's end would.

The retirement is complete before anything propagates, however it began and however many times the runner's thread is interrupted meanwhile:
the run asks the owner to stop and waits for the owner's worker to have ended (its raw completion, which supervision's latch of another worker's
failure never makes unavailable), so what the run's sinks and bindings are borrowed from is not released while the owner's Lua still uses them.
That wait is for arbitrary Lua segments and shutdown hooks, so it is interruptible and never runs under an uninterruptible mask (a release has
a controlled blocking duration, and a worker's join has none); but an interruption does not end it. Each one is recorded and the wait goes on
until the worker has actually ended, and then what happened is raised in order: a cancellation, if one was among them, as itself, and every other
failure whole as evidence beside it. A segment that never returns keeps the call pending, as it keeps the worker (D-27). Creation is the same:
`startScheduledOwner` does not return or raise, on a failure of its wait (another worker's latched failure, a cancellation) or any other, while the
worker it started is alive, so a script held in a module's top level keeps the call pending until it is let go. The wait does not raise the owner's
failure again: supervision delivers it, to the next supervised wait and at the boundary's exit beside the body's own. When failures arise together
the first is the primary and the rest are kept whole as evidence beside it; a single failure is never recorded again as a failure of cleanup.

### Waiting and ending

A run waits in one place: a single STM wait, composed with supervision (a failure of the owner raises as soon as supervision commits it), that sees a
failure to write, the ends to produce (an elapsed VM), every instance having ended, the stop request, the tick limit, the duration limit's timer and what the
step the run is in waits for (an admission, a tick that is due, a tick that has finished). It polls nothing.
The run ends at the first of: every instance has ended (a one-shot completing, a failure, or a granted Lua control, of itself or another); the stop
request fires; the tick limit is reached; the duration limit is reached. **The limit** is a positive duration measured on the injected clock from the *origin*, the instant read just
before the first instance is admitted, and waited for on the injected timer, whose wake only tells the run to look at the clock again: an early
or a stale wake finds the deadline not reached and the run arms again. The timer's registration is cancelled on every way out of the run, and a
limit too large for the clock's range is one that is never reached.

**When several apply together** the order of precedence is the contract: a failure to write, then what a finished `init` owes (the start table and the *started*
event), then *every instance ended*, then *the stop request*, then *the tick limit*, then *the limit*. So a run in which every instance has ended ends as `EndedAllInstances` even if the stop request and the limit
are due too; one that the stop request and the limit both end is `EndedStopRequest`; the limit ends a run nothing else has. A stop request that is
already set when the run begins admits nothing, reads no file and starts no VM, and returns as stopped.

Whatever the end, every instance still unended is stopped in ascending TID order through the ordinary path: its `shutdown` runs once, with reason
`stopped`, if its module defines one (an instance that is paused is stopped too), and then the VM is retired. A running segment is let return and the
runner sets no deadline: a script stuck in non-yielding Lua keeps the stop pending (D-27), and forcing the exit is LUA-19's. An instance a Lua control
stops, or that ends by itself, ends under the same contract: no path runs a `shutdown` twice or skips the retirement.

### The report and the status

`Ran RunReport` holds how the run ended (`EndedAllInstances`, `EndedLimit`, `EndedTickLimit`, `EndedStopRequest`, or `EndedStartupFailure` when a source did not load),
the ticks completed (`reportTicks`) and the event tallies (`reportEvents`: events produced, started and ended; delivery attempts, counted by the engine's answer, admitted,
staged, refused queue-full, refused staging-full, subscription ended; and watchers failed by overflow), each instance's report (TID, name, file, final status, how it ended and what became of `shutdown`, its failure if any), the `LoadFailure` when
there is one, and the `RunStatus`. The status is `StatusFailure` if any instance failed or a source did not load; otherwise `StatusInterrupted` if the
stop request ended the run; otherwise `StatusSuccess`: a limit, a Lua control and every instance completing are success. Exit numbers are the command
line's.

### The command line

`hetoimasia lua` (LUA-19, `console/Hetoimasia/Console/Lua*.hs` and `app/Main.hs` in the root package) is the
runner's command line: it parses the arguments, installs two signal handlers, wires the runner to the
process's streams and maps the runner's answer to an exit status. It changes nothing of the runner.

```text
hetoimasia lua [--vm NAME] [--scheduler fifo] [--headless] [--tick SECONDS] [--for SECONDS | --ticks N]
               --script PATH [--name NAME] [--every SECONDS | --every-ticks N] [--script PATH ...]
```

Every option takes its value as the next argument. *VM options* may appear anywhere and at most once each: `--vm NAME`
(default `main`), `--scheduler fifo` (the default and only value), `--headless` (accepted; headless is the default and only
mode), `--tick SECONDS` (the tick duration: the VM runs on logical ticks granted at that real-time rate), `--for SECONDS` (the duration limit)
and `--ticks N` (the tick limit). *Script options* bind to the most recent `--script PATH` and at most once each: `--name NAME` (default the
file's name without directory and extension), `--every SECONDS` (an elapsed interval) and `--every-ticks N` (a tick interval). Seconds are positive decimal
numbers of at most nine fractional digits with no sign and no exponent, so they are whole nanoseconds: zero, finer, malformed or unrepresentable
values are refused and nothing is rounded. Counts are positive whole numbers that fit a 64-bit tick. `lua --help` alone writes the
help to stdout and exits 0. No `--group` flag, and no stdin console.

**Usage is validated first**, as a pure function of the argument list (`Hetoimasia.Console.Lua.Options.parseLua`), before any file is read, any VM is
started or any signal handler is installed. Refused: an unknown option or argument; a value that is missing, empty or itself an option; a repeated VM option
(`--headless` included); a script option before the first `--script`; a script option repeated for one script; a scheduler other than `fifo`; a malformed number;
no `--script`; `--ticks` or `--every-ticks` without `--tick`; `--every` with `--tick`; `--every` with `--every-ticks`. A refusal the runner returns (it needs the
module's entries: a module defining both `run` and `update`, `update` with no interval, an interval for a module with no `update`) is a usage error too. A usage error
writes the usage line and a one-line reason to stderr, nothing to stdout, and exits 2; so does the top-level unknown argument, through the same writer (`Hetoimasia.Console.Usage`). The reason is built from what the user typed, so every character that is not printable ASCII becomes a `\xNN` escape and each value is cut at 200 characters with a visible marker: a newline or a carriage return in an argument or a path cannot add a line, and a locale that cannot encode the text cannot turn a usage error into a failure to report it. A present but invalid logging
variable is configuration, not usage: it fails startup with status 1 before any argument is read.

**Streams.** The runner's output sink is stdout and its error sink is stderr, each flushed after every write, so a reader on a pipe sees each line at once: `print` output
and the TID/OWNER/NAME/STATUS tables on stdout; `warn`, failure and source-did-not-load reports and usage text on stderr (the owner's decision on
[#492](https://github.com/coghex/hetoimasia/issues/492#issuecomment-6270451945)). The logger's records stay on stderr under the logging variables, as for `--smoke`. Both handles are UTF-8.

**Exit statuses** (`Hetoimasia.Console.Exit` names them; `Hetoimasia.Console.Lua.Status` maps the runner's answer, a pure function):

| Status | When |
|---|---|
| 0 | every instance completed or was stopped, by a control or by a limit |
| 1 | an instance failed, a source did not load, or a failure of the host propagated |
| 2 | invalid usage |
| 130 | SIGINT or SIGTERM ended the run, after the orderly stop; also a cancellation |

When several apply, 1 outranks 130, which outranks 0 (the runner's status value already ranks failure over interrupted over success).

**Signals.** SIGINT and SIGTERM handlers are installed on the `lua` path only, after the usage check and before the runner starts; every other path keeps GHC's
defaults. Both call one coordinator (`Hetoimasia.Console.Lua.Signals`), one atomic step on one state: the first signal, whichever it is, sets the runner's stop
request and returns without waiting for the shutdown it asks for, and the run ends through the orderly stop of the runner (nothing is admitted if it comes first). A
**second** signal while that stop is still running exits at once with status 130, skipping the shutdown hooks that have not run, waiting for no cleanup and
flushing nothing (D-42; `exitImmediately`); a later one changes nothing, and overlapping deliveries request the stop once and force at most once. A script stuck in
non-yielding Lua keeps the first stop pending (D-27), which is what the second signal is for.

**Wiring.** The executable runs the runner through the runtime's application lifecycle (`runScopedApplication`): the logging lifetime over stderr, entered first and
left last so it outlives the supervision drain and makes the one final flush after it, the public supervision boundary, and the runner inside it with the production
clock and timer. The executable keeps `-threaded`; the bridge's calls are `safe`, so no more capabilities are needed. The interpreter is the copy the `lua` package bundles.

**Examples.** Three checked-in scripts under `test/lua-examples/`, run by their documented commands in the root suite's `Console` group:

```sh
# a one-shot: prints and completes
hetoimasia lua --script test/lua-examples/oneshot.lua
# a looped instance and a controller that pauses, resumes and stops it through the lifecycle controls
hetoimasia lua --tick 0.001 --ticks 40 \
  --script test/lua-examples/looped.lua --every-ticks 1 \
  --script test/lua-examples/controller.lua --every-ticks 3
# an event-only watcher of the instances' start and end events, which stops itself once every other instance has ended
hetoimasia lua --tick 0.001 --ticks 20 \
  --script test/lua-examples/watcher.lua --script test/lua-examples/oneshot.lua
```

The looped and watcher examples run on `--tick` with `--ticks`, so their output is the same on every run; the elapsed-clock variant (`--every SECONDS`,
`--for SECONDS`) is asserted on structure only.

**What proves it.** The `Console` group of `hetoimasia-tests` (`--test-options='--match Console'`): the command line as direct examples (every refusal, default and
number at its boundary), the status mapping, the coordinator (first signal, second, later, overlapping deliveries on many threads), and every status by running the
built executable as a child process: 0, 1, 2 (a representative of each class of usage error, a runner refusal and the top-level unknown argument) and 130 for SIGINT
and SIGTERM with the instance's `shutdown` output on stdout before the process exits, and which stream carries what. A signal is delivered only after the child has said on stdout
that its script is running; every read and wait is bounded; no example sleeps; every child is killed with `SIGKILL` and reaped on every way out, independently of
the signal under test. The forced exit needs a script whose `shutdown` never returns, so it is the optional probe `lua-forced-exit-probe`
(`cabal test hetoimasia:lua-forced-exit-probe --test-show-details=direct`, validation group `test.lua-forced-exit`, `optional: true`, never selected by affected
inputs): a first signal after the script reports it is running, a second after it reports its stop has begun, and the process exits 130 promptly, the hook never having finished.
Signal semantics differ between Linux and macOS; Linux CI is the evidence.

### What is not here

Signals, `exit` and exit numbers belong to the command line above, and the runner does not use them; window creation, VM groups, module reload, a stop deadline. `Hetoimasia.Scripting.Lua.Runner.Internal` is the seam the
examples use for a callback (an event source, bindings of their own, the owner's endpoint): it is not part of the contract and
is no way to configure a production run.

### What proves it

`Test.LuaRuntime.Runner.*`, in `lua-runtime-tests` (select them with `--test-options='--match Runner'`), run real Lua on real supervised
scheduled owners started by the runner, with the injected clock, a fake timer, gates and STM signals, and no sleep: every way a source can fail to load,
in script order; a path named twice; two files with one name; the identity's rules; each kind from a module's entries and each usage
refusal, with no hook run and the VM retired; the query answering defined, absent and present-but-not-a-function, running no code and never
changing; a failed `init`, a failing `run`, `update`, callback and `shutdown`, several failures in one run and a primary kept over a failing `shutdown`;
a host failure from a binding, from a sink while a script prints and while a module loads (and an application's exception shaped as the host's
fault of loading), the runner's own write failing after an orderly retirement, failures arising together, a failure another supervised worker latched
propagating only after the owner's retirement is complete (during the run and during startup), and cancellations, during startup and during cleanup after a failure, that do not end the wait for the owner; every ending (a one-shot, a script stopping
itself and another, the stop request, the limit with an early and a stale wake, a stop request set beforehand), each stop path stopping a live
event-only, looped and paused instance in order, simultaneous endings in their order of precedence, the timer cancelled on every exit; the
start table with a gated initializer and a stop before an instance began, the early settlement kept in the tables, and the tables' bounds; output
to the sinks only (and to no C stream), bounded as it is written after escaping (NUL bytes, invalid bytes, line breaks, multibyte text, an error, a name and a path), safe and unforgeable; and the status for each combination. For LUA-28: every usage refusal of the clock; the driver granting ticks of exactly the tick duration, back to back when the clock
jumps past several deadlines while a segment is held, nothing for an early or a stale wake, none after a stop begins; the tick limit and every ending of a tick VM
leaving each remaining `shutdown` once, in order; the tie rule at a tick's boundary with the runner held in the write of a report; Lua controls placed by the runner in the
order they were issued; the events a watcher sees, with a usable TID, the outcomes, the failed `init`, no replay and recipients in subscription order; the pure
classification of every engine answer and production against feeds that answer each way; both overload cases and the defects with real VMs; admission one script at a time
with an init held; and a scenario with a ready, yielding one-shot, a one-shot that unsubscribes at once and a paused one-shot resumed by a logical control, compared transcript
for transcript across runs whose pacing differs. The cancellation and shutdown
windows are the kind an asynchronous-exception race can hide on one platform, so CI, which runs them on Linux, is the evidence for them and a local
pass is not.

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
recorded here and enforced by nothing in the model: the scheduling machinery of
`runtime-lua` (LUA-21) enforces them per pass, and what runs next is a policy's choice
within it. See [The scheduling machinery](#the-scheduling-machinery).

### The session

`…Protocol.Session` composes the rest. It is a facade over one pure session
value, and it states the aggregate's contract; the implementation sits beneath
it in `…Protocol.Session.*`, one responsibility per module and an acyclic
import graph from the bottom up:

| Module | Owns |
| --- | --- |
| `Session.State` | The `Session` value, `newSession`, `Counters`, `SessionRejection`, and the records it keeps (`FailureRecord`, `ExitRecord`) |
| `Session.Step` | Refusal, counters, the not-stopped and not-failed preconditions, ordinal/task-name/generation issuance, and one task transition |
| `Session.Revocation` | `retire`, `invalidateHoldingsOf`, `revokeOne`, `revocableRequests`, `reclaim` — the one definition of the shared provider accounting |
| `Session.Tasks` | Admission, activation, and every task transition up to observing its result |
| `Session.Requests` | Accepting requests, replies, cancellation, observation, provider completion |
| `Session.Subscriptions` | Registration, delivery, taking events, unsubscribing |
| `Session.Epoch`, `Session.Failure`, `Session.Stop` | The three session-wide invalidations, kept apart because each retains different records and reports different counts |

Callers import the facade only. Each operation answers
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

Three bounds are worth stating in full.

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

**A `FailureReason`'s detail is bounded and copied.** It may quote a script's
own error text, so `failureReason` truncates it to `reasonDetailBound`
characters -- counted as characters, so a multibyte detail is never cut inside
one -- and copies what survives into an array of its own. Truncation alone
would bound the characters and not the memory: a `Text` is a window onto a
shared array, so a 512-character prefix of a megabyte of script output would
keep the megabyte alive, and a detail already within the bound is just as
likely to be a small window onto a large allocation. The copy is made either
way. `failureReason` is also the only way to build one -- `reasonCode` and
`reasonDetail` read a reason but are not its record fields, and the constructor
is not exported -- so the count limits on stored failures bound retained memory
rather than only the number of reasons held.

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
| LUA-21, the scheduling machinery | `Session` admission and its caps, `ServiceClass`, `Quanta` and `validateLimits`, `Ordinal`, the ready, waiting and paused states and their transitions, `activateNext`, `stopSession` |
| LUA-6, the scheduled owner | the same, through LUA-21's machinery, with `TaskId` scoped by the owner's identity and wrapped in `ScheduledTaskId` |
| LUA-7, requests | `RequestId`, `Settlement`, `Reply`, the two obligations, holders, the epoch change and the stop, in a session of the owner's requests |
| LUA-26, subscriptions | `OverloadPolicy`, and LUA-7's granted service, guard and epoch operation unchanged |
| LUA-9, the child-process transport | every identity, `Payload`, `Reply`, `SegmentOutcome`, the rejection vocabulary |
| LUA-5, supervision integration | `Limits` and `validateLimits`, for the two caps its call dispatch has (`maxQueuedAdmissions`, `maxRetainedResults`) |

LUA-5 takes nothing else from this model. It runs finite calls and no task, session
or request, so the adapter has an exit record of its own, counting what its stop
discarded. The scheduling machinery is the first consumer of a session of tasks: it keeps
one `Session` per scheduler, drives its transitions, and answers the model's `ExitRecord`
in its stop report. It does not use the model's `reportFailure`, whose unsafe case ends the
whole session (D-7): a failed task is failed alone, its `TaskFailure` and recovery marking are
reported in the turn, and whether a session ends is the integrating owner's decision. The request service keeps a
session of its own (the scheduler's has no requests): requests are owned by *holders* the session issues, which an
instance's end revokes through the same path a retiring task's requests go through; its epoch is the request
service's, and the instances and tasks are not invalidated by it. Subscriptions wait for LUA-26.

## Running the suite

```bash
cabal test hetoimasia-scripting-lua:lua-host-tests --test-show-details=direct
```

It also runs under `--project-file cabal.project.cpu`, which this package needs
no GLFW SDK for. The validation group is `test.scripting-lua`; see
[docs/validation.md](../../docs/validation.md).

The runtime adapter's examples and the scheduling machinery's are a suite of their own,
whose validation group is `test.scripting-lua-runtime`:

```bash
cabal test hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct
```

The owner's examples are the `VM owner` component of the host suite, and the
bridge's own are the rest:

```bash
cabal test hetoimasia-scripting-lua:lua-host-tests \
  --test-show-details=direct --test-option=--match --test-option='VM owner'
```

The registration and value boundary's examples are the `value boundary`
component of that same suite:

```bash
cabal test hetoimasia-scripting-lua:lua-host-tests \
  --test-show-details=direct --test-option=--match --test-option='the value boundary'
```

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

The validation group is `test.lua-confinement-linux`, optional and local-only.
It is not selected automatically, even for affected inputs. A green run of it is
evidence and never a verdict: each example prints what it proved, or says that
the machine could not install the profile and names the prerequisite that was
missing. What those lines add up to is
[the Linux confinement verdict](../../docs/archive/lua_linux_confinement_verdict.md),
which is where the accounting semantics of the memory limit, the deployment
baseline, and the residual limits are recorded, and the runs it draws on are
kept verbatim in
[the retained runs](../../docs/archive/lua_linux_confinement_evidence.md).

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
[docs/archive/macos_confinement_verdict.md](../../docs/archive/macos_confinement_verdict.md) is
where it is stated and argued: every proof row was demonstrated, on two
interfaces Apple does not support. Read it before building anything on this
code.

```bash
cabal test hetoimasia-scripting-lua:macos-confinement-probe --test-show-details=direct
```

Each example prints what it proved. The validation group is
`test.macos-confinement`, optional and local-only; see
[docs/validation.md](../../docs/validation.md#the-macos-confinement-probe).

## Routine tests and optional probes

`lua-host-tests` keeps the quick bridge/protocol contracts, including protected
allocation failures and one-capability foreign-call progress. The deliberate
nonterminating-Lua experiment is separate:

```sh
cabal test hetoimasia-scripting-lua:lua-hazard-probes --test-show-details=direct
```

It deliberately waits five seconds and terminates its child process. It and
both confinement feasibility probes are local-only and optional. Select them
explicitly or through coordinated local testing; see the repository's
[test classification](../../docs/test_classification.md). The existing
`lua-hazard callback-cancellation` mode remains a manual diagnostic with no
pass/fail oracle, not a routine test.
