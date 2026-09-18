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

`lua_pcall`, `lua_load`, `lua_close`, `lua_gc`, and the binding's protected
`hslua_*` ersatz functions are imported `safe`: they can run arbitrary Lua,
which can call back into Haskell, and a `safe` call releases the capability for
its duration. That is what lets other Haskell work and other VMs progress while
one VM is running a chunk. The stack accessors — `lua_gettop`, `lua_settop`,
`lua_type`, `lua_tolstring`, `lua_topointer` — are `unsafe` and O(1).

`-allow-unsafe-gc` is **disabled**. With it on, every call that can trigger a
collection is imported `unsafe`. This bridge pushes Haskell functions into Lua,
and each one is a userdata whose `__gc` metamethod frees a stable pointer — so
any VM that has ever held a callback re-enters the RTS from its collector. An
`unsafe` import is not a context that may do that. Turning the flag off makes
those calls `safe`. The cost is the `safe` foreign-call overhead on allocation
paths, which this slice did not measure: it is a correctness setting, and a
measurement belongs with the first workload that has a budget to weigh it
against. The benefit is that Haskell finalizers remain available to LUA-2 and
LUA-3 rather than being foreclosed here.

### How callbacks re-enter

`hslua_pushhsfunction` stores a `StablePtr` to the Haskell operation in a
userdata with a `__call` metamethod, wrapped in a C closure. Calling it from Lua
reaches Haskell through the binding's `foreign export ccall hslua_callhsfun`.

That export runs the callback **in a Haskell thread of its own**, not in the
thread that called `evalChunk`. Two consequences follow, and both are load
bearing:

- A callback cannot be cancelled by cancelling the calling thread, and the
  calling thread cannot observe the callback's own thread.
- The escape record has to live on the VM rather than on a thread, which is why
  `Vm` holds one.

### Error and cancellation transport

A Lua error inside a protected call is a status code, never an unwind: it is
classified, its value is rendered under a bound, and it becomes a `LuaFault`.
Rendering runs no Lua — `lua_tolstring` converts a string or a number and
declines everything else, and a value it declines is reported by type name and
address — so a failing chunk cannot keep executing through the report of its own
failure, and a `__tostring` metamethod is never called.

A Haskell exception inside a callback never crosses the C frame. The trampoline
catches it with the context it carried, records it on the VM, and raises an
ordinary Lua error carrying a fixed message. Lua may catch that with `pcall` and
finish the chunk successfully; the operation's boundary still re-raises the
recorded exception, with its own type and context, and adds its operation to
that context. The first escape of an operation is the one kept.

A cancellation aimed at the thread running a call is **not delivered while that
thread is inside Lua**, because `lua_pcall` is a `safe` foreign call. It stays
pending and is delivered once the call returns. It is never converted into an
ordinary Lua error, and it is never swallowed.

### Supported and rejected execution paths

Supported:

- One execution owner per VM, enforced by a gate rather than assumed. A second
  thread's operation waits; an operation on a closed VM is refused.
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
`lua-hazard` executable. `-N2` rather than `-N`: the independent-progress
example needs Haskell to run while a capability is inside a Lua computation, and
the hazard needs one thread inside Lua and one observing it, on every machine
that runs them.

## Lifetimes

`closeVm` is terminal and runs once. The VM's phase becomes closed before
`lua_close` is entered and the whole close is masked, so a cancellation arriving
during it can neither release a callback's borrowed dependencies early nor leave
a half-finished close for a later call to retry. Dependencies are released only
after `lua_close` has returned, because until then Lua's finalizers are still
running; every release is attempted and their failures are collected into one
`CloseFault` rather than letting the first hide the rest.

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
