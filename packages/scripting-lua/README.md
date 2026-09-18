# Lua host

One embedded Lua interpreter, reached through a private bridge. This package
owns VM construction over an explicitly chosen set of standard libraries, chunk
loading, protected calls, error and cancellation transport across the C
boundary, and a terminal close. It depends on `hetoimasia-foundation` and the
Lua binding and on nothing else in the engine: no runtime, GLFW, Vulkan,
console, or game code.

The public module and capability registration surface, the protected VM owner,
the task and admission model, and any game binding are later slices of
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
state, the callback trampoline, the temporary registry references, and the stack
probes live in the package's private `bridge` sublibrary, which no client
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

Nothing in `hslua-core` is needed for what this slice does: the raw layer
already exposes the individual `luaopen_*` functions, protected `pcall`, the
registry reference helpers, and the Haskell-function trampoline.

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

### Which calls are safe, and which are not

Recorded per call, because grouping them gets it wrong. `lua-2.3.4` fixes some
imports and leaves others to the `allow-unsafe-gc` flag, which this repository
disables; under that setting the flagged ones are `safe`.

| Import | Annotation | Used by |
| --- | --- | --- |
| `lua_pcall` | `safe`, fixed | every call into Lua |
| `lua_close` | `safe`, fixed | the close |
| `hslua_getglobal`, `hslua_setglobal` | `safe`, fixed | reading and publishing a global |
| `luaL_loadbuffer` | `safe`, by the flag | loading a chunk |
| `hslua_newhsfunction` (behind `hslua_pushhsfunction`), `hslua_extracthsfun` | `safe`, by the flag | installing and entering a callback |
| `hslua_error` | `safe`, by the flag | the trampoline's stand-in error |
| `luaL_ref`, `luaL_unref` | `safe`, by the flag | the fixtures' registry probe only |
| `lua_tolstring` | `safe`, by the flag | reading a string error value |
| `hetoimasia_lua_publish` (this package's C) | `safe` | publishing a callback, under protection |
| `lua_touserdata`, `lua_remove` | `unsafe`, fixed | the callback entry, reading its carrier |
| `hsluaL_newstate`, `hsluaL_requiref` | `unsafe`, fixed | constructing a VM and opening a library |
| `lua_gettop`, `lua_settop`, `lua_type`, `lua_typename`, `lua_isinteger`, `lua_tointegerx`, `lua_tonumberx`, `lua_pushboolean`, `lua_pushlightuserdata` | `unsafe`, fixed | stack bookkeeping, rendering, and the escape marker |

`lua_pushlstring`, `lua_newuserdatauv`, and `luaL_newmetatable` appear only
inside `hetoimasia_lua_publish`, where they run under a protected call; the
binding's own `hslua_pushhsfunction`, `hslua_setglobal`, and `hslua_error`,
which would reach them unprotected or bring their own export with them, are not
used. See *Allocation* and *How callbacks re-enter* below.

The `safe` calls are what let other Haskell work and other VMs progress while
one VM is running a chunk: a `safe` call releases the capability for its
duration. That is the property the one-capability example in
`Test.Lua.Hazard` exists to make falsifiable.

Two of the `unsafe` ones are worth stating rather than listing.
`hsluaL_requiref` runs Lua — it opens a standard library through an internal
protected call — under an `unsafe` import. That is sound only because the
`luaopen_*` functions are C and call no Haskell, so the call cannot re-enter the
RTS; it would not be sound for a module opener written in Haskell, and LUA-3
must not reuse this path for one. `hsluaL_newstate` allocates the interpreter
and registers the Haskell-function metatable, and touches no Haskell either.

`-allow-unsafe-gc` is **disabled**. With it on, every call that can trigger a
collection — including `hslua_newhsfunction` and `lua_tolstring` above — is
imported `unsafe`. This bridge pushes Haskell functions into Lua, and each one
is a userdata whose `__gc` metamethod frees a stable pointer, so any VM that has
ever held a callback re-enters the RTS from its collector. An `unsafe` import is
not a context that may do that. Turning the flag off makes those calls `safe`.
The cost is the `safe` foreign-call overhead on allocation paths, which this
slice did not measure: it is a correctness setting, and a measurement belongs
with the first workload that has a budget to weigh it against. The benefit is
that Haskell finalizers remain available to LUA-2 and LUA-3 rather than being
foreclosed here.

### Allocation, and where a Lua error can be raised

Import safety is not the same question as whether a call can raise a Lua error.
Almost every Lua operation that allocates can raise `LUA_ERRMEM`, and where that
raise lands depends entirely on where the call was made from. There are two
places, and they are not equally bad.

**From inside a callback.** A protected frame exists — the caller's
`lua_pcall`, further out — so a raise here `longjmp`s *out of a Haskell frame*
to reach it. That is undefined behaviour, not an error report. So the
trampoline uses only operations that allocate nothing: `lua_pushboolean` for a
boolean result, and a light userdata for the escape marker rather than a string,
because pushing a string allocates. `hslua_error` reads the binding's error
sentinel out of the registry with a key that `hsluaL_newstate` already interned,
so its lookup finds an existing short string and allocates nothing either.

**From Haskell, outside any protected frame.** The reporting path after
`lua_pcall` has returned is in this position, and so is `installCallback`, which
is not reachable from inside Lua because the VM's gate is held. Here a raise
finds no frame at all and runs Lua's panic function, which ends the process. No
Haskell frame is unwound and nothing is corrupted, but the failure is a dead
process rather than a `MemoryExhausted` fault.

The reporting path is clean: it takes no registry reference (`luaL_ref` can
raise) and calls `lua_tolstring` only on a value that is already a string, where
it converts nothing; a number is read with the non-allocating accessors and
formatted in Haskell. `Test.Lua.Faults` pins that — a numeric error value
renders in Haskell's formatting, not Lua's, which is the observable difference.

**Publishing a callback allocates twice**, and used to do it in this second
position: `hslua_pushhsfunction` reaches `lua_newuserdatauv`, and the binding's
`hslua_setglobal` pushes its key with `lua_pushlstring` *before* entering its
own protected call. Both now happen inside one `lua_pcall`, in this package's
own `bridge/cbits/hetoimasia_lua_publish.c`, which calls the binding's
`hslua_newhsfunction` from there. Nothing that could allocate crosses into that
call: the stable pointer and the name go in as light userdata and an integer,
and `lua_checkstack` reports its own failure rather than raising it. Memory
exhaustion while publishing is therefore a status, and the bridge reports it as
a fault.

`lua-hazard allocation-failure` proves it, because the binding exports no
`lua_newstate` and an allocator that fails on demand cannot be installed from
Haskell: the hazard runner builds one in C, starves it, and reports the status
that came back. A starved publication answers `LUA_ERRMEM`; a generous one
answers `LUA_OK`. Without the protection there would be no line to read, because
the process would be gone.

Ownership of the Haskell function's stable pointer is reported rather than
inferred. Two allocations can fail on that path and only the second of them
leaves an owner behind, so the status alone cannot say whether Lua took it: the
shim sets a flag at the exact instruction the userdata stores the pointer, and
the bridge frees the pointer only when that flag says Lua never did. That is why
the shim builds the userdata itself instead of calling the binding's
`hslua_newhsfunction` — the instruction is inside that function, and nothing
outside it can observe it.

### How callbacks re-enter

This package owns the callback path. `bridge/cbits/hetoimasia_lua_publish.c`
builds a userdata that carries a stable pointer to the Haskell operation, gives
it a metatable whose `__gc` frees that pointer and whose `__metatable` keeps a
script away from it, and wraps it in a C closure. Lua calls that closure, which
calls this package's own `foreign export`, `hetoimasia_lua_enter`.

Using the binding's equivalent is what the two previous sections rule out. It
allocates outside protection, and it runs more of its own Haskell after the
function it called returns — an asynchronous exception delivered there unwinds
through a C frame and ends the process, and it is not code this package can
mask. With its own export, the only Haskell between Lua calling in and the
callback thread ending is this package's, and all of it is masked but the
action.

The error protocol is correspondingly this package's. A negative result count
means the value on top is the failure marker; `lua_error` is raised by the C
closure, after every Haskell frame has returned, because a `longjmp` through one
is undefined.

That export runs the callback **in a Haskell thread of its own**, not in the
thread that called `evalChunk` — that is how GHC's foreign exports work, and two
consequences follow:

- A callback cannot be cancelled by cancelling the calling thread, and the
  calling thread cannot observe the callback's own thread.
- The escape record has to live on the VM rather than on a thread, which is why
  `Vm` holds one.

A globals table can carry `__index` and `__newindex` metamethods, so reading or
publishing a global runs Lua too, and that Lua can call one of these callbacks.
Every such path therefore reports the protected helper's own status and drains
the escape record; collapsing a failed lookup into "not a function" would report
the wrong failure and leave the real one for an unrelated later operation.

### Error and cancellation transport

A Lua error inside a protected call is a status code, never an unwind: it is
classified, its value is rendered under a bound, and it becomes a `LuaFault`.
Rendering runs no Lua — a `__tostring` metamethod is never called — and reports
a value that is neither a string nor a number by its Lua type alone. Not by its
address: a pointer rendered into text is still a native address, and `LuaFault`
crosses the package boundary. Absence is read from the stack depth, so a
`false` error value is reported as a boolean rather than mistaken for nothing.

A Haskell exception inside a callback never crosses the C frame. The entry runs
the callback's own action unmasked, so a cancellation aimed at it is delivered
there and caught with the context it carried; everything after the action —
recording the failure, building the result, returning — is masked, because an
exception delivered in that stretch would unwind through a frame that is not
Haskell's. The recorded failure becomes an ordinary Lua error carrying the
escape marker.

Masking stops a cancellation from unwinding; it does not stop one from being
pending. A `throwTo` blocked against the mask is delivered the moment the mask
lifts, and a callback thread that ends killed is reported by the export's
epilogue as an uncaught exception the process does not survive. So before
returning, the entry lets each pending cancellation in through a window of its
own and drops it. Dropping is right rather than expedient: the thread is the
runtime's, made for one call and ending with it, and a cancellation arriving
after the action has finished cannot stop work that is already done — while a
failure the action itself suffered was recorded on the VM first and is still
owed to the caller. `lua-hazard callback-cancellation` fires three cancellations
at each of fifty callbacks and requires every one to be delivered, contained,
and survived. Lua may catch that with `pcall` and
finish the chunk successfully; the operation's boundary still re-raises the
recorded exception, with its own type and context, and adds its operation to
that context. The first escape of an operation is the one kept, and an operation
that leaves by any other exception takes the record with it.

A cancellation aimed at the thread running a call is **not delivered while that
thread is inside Lua**, because `lua_pcall` is a `safe` foreign call. It stays
pending and is delivered once the call returns. It is never converted into an
ordinary Lua error, and it is never swallowed.

The instant it is delivered matters. Without care it lands between the protected
call returning and the bookkeeping that follows — restoring the stack, taking
the escape record — and leaves both for the next, unrelated operation. So an
operation runs masked; the only interruptible point is waiting for a VM that is
busy. Nothing is lost by that, because a thread inside Lua could not be
cancelled anyway.

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
  unwinds out of a Haskell frame to the protected call outside it. The entry
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

## Running the suite

```bash
cabal test hetoimasia-scripting-lua:lua-host-tests --test-show-details=direct
```

It also runs under `--project-file cabal.project.cpu`, which this package needs
no GLFW SDK for. The validation group is `test.scripting-lua`; see
[docs/validation.md](../../docs/validation.md).
