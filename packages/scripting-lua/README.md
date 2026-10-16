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

The **protected VM owner** (LUA-2) is here: one VM held through a bracket-shaped
IO lifetime that closes it on every exit and keeps the primary failure and the
close's failures as cleanup evidence. See [The VM owner](#the-vm-owner).

The **registration and value boundary** (LUA-3) is here too: an application
registers named bindings once, gives each owner a policy naming the namespaces it
exposes, supplies its own Lua modules, and calls their entry points with bounded
copied values. See
[Registration, modules and bounded values](#registration-modules-and-bounded-values).
Any concrete game namespace, the scheduler, asynchronous requests and the
confined path are later slices of
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
address, and none of them has a reachable representation that becomes one: the
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
  { vmLibraries ∷ [Library], vmInitialChunks ∷ [(ChunkName, ByteString)]
  , vmOwnerName ∷ Text, vmRegistration ∷ Registration, vmPolicy ∷ [Text]
  , vmValueLimits ∷ ValueLimits, vmModules ∷ [ModuleSource] }
vmConfig    ∷ [Library] → VmConfig
evalOwned   ∷ OwnedVm → ChunkName → ByteString → IO ()
callOwned   ∷ OwnedVm → Text → IO ()
loadModule  ∷ OwnedVm → ModuleSource → IO ModuleHandle
loadedModule ∷ OwnedVm → ModuleRef → IO (Maybe ModuleHandle)
callEntry   ∷ OwnedVm → ModuleHandle → Text → [Value] → IO CallResult
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
close`), through `composeCleanup`, the foundation's seam below. Evidence is read
back with `cleanupFailures` or `cleanupFailuresInContext`, which is what a
supervisor reads.

| Exit | What the owner raises | Cleanup evidence |
|---|---|---|
| Body returns, close succeeds | The body's result | None |
| Body fails, close succeeds | The body's failure, unchanged | None: a close that succeeded is never reported |
| Body fails, close fails | The body's failure | Every close failure, finalizers' first then releases' |
| Body returns, close fails | The first close failure | Every close failure, that first one included, so it is the failure and cleanup evidence at once |
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

### What proves it

`Test.Lua.Owner.*` hold each part of this to expected values written in the
tests. The exit matrix; partial construction at each step, with an allocator
budget swept so that memory runs out at the state's allocation, while a library
opens and while a chunk runs; cancellation before, during initialization, the
body and the close, repeated, and with a failing close, with the cancellation
delivered by coordinated blocking and never by sleeping; the shutdown phase and
an empty allowlist, a denied callback performing no action and leaving evidence
even when Lua caught its refusal, and the bound; ownership by a thread the body
started, a second owner and a stale reference; and ten owners live at once on
separate threads, ended in a scrambled order, one failing, one cancelled and one
closed with a failing finalizer. `Test.Lua.Opacity` compiles the clients that try
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
| asynchronous native request | `asynchronousNativeRequest` | classified only | a Lua call is a typed `NotYetSupported` fault; the action never runs |
| lifecycle operation | `lifecycleOperation` | classified only | a Lua call is a typed `NotYetSupported` fault; the action never runs |

The defaults are the safe ones: a binding is **direct-eligible** and nothing
else, so a default registration exposes nothing to a mod
(`confinedEligibleBindings` of one is empty) and a direct-only binding needs no
IPC equivalent. `confinedEligible` is refused when any schema of the binding
carries a capability, because a handle into one VM has no meaning to a process
that cannot hold it, and it grants nothing by itself: no grant exists until the
broker that enforces one. `finalizerEligible` is refused for the asynchronous
kind. `withoutDirectPath` keeps an owner from installing the binding at all.

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
script can reach is the owner's explicit set, and the debug library an owner opens
has no `sethook`, because a hook is script-defined Lua that Lua would run while a
fault's traceback is being recorded; the base library brings `dofile`
and `loadfile`, so an owner that must not read the disk does not open it.

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
`CallBinding`), the module's name and version and the entry point when a module
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
eligible binding, an ineligible one, an allowlisted lifecycle binding);
independent owners on separate threads with different policies; installation;
discipline, with the allocator's budget swept across installation, loading,
calling and marshalling; and the dependency closure. `Test.Lua.Opacity` adds
negative clients that forge a handle or a capability, reach for a binding's
closure or for a Lua state, and a positive client built from the public modules
alone that constructs a registration and an owner's policy, loads a module, calls
an entry point and observes a typed refusal.

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

The owner's examples are the `VM owner` component of that same suite, and the
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
