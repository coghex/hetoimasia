# Lua host

One embedded Lua interpreter, reached through a private bridge. The host
library depends on `hetoimasia-foundation` and the Lua binding and on nothing
else in the engine: no runtime, GLFW, Vulkan, console or game code. The layers,
each in its own section:

| Layer | What it is |
| --- | --- |
| [The VM owner](#the-vm-owner) | One VM in a bracket-shaped IO lifetime that closes it on every exit and keeps the primary failure and the close's failures as evidence |
| [Registration, modules and bounded values](#registration-modules-and-bounded-values) | Named bindings registered once, a per-owner policy of granted namespaces, application modules, entry points called with bounded copied values |
| [Export modules and captured behaviors](#export-modules-and-captured-behaviors), [Ordered import chains](#ordered-import-chains-the-module-loader) | Modules that return an export table and `import` one another, one chain at a time |
| [Tasks and the coroutine library](#tasks-and-the-coroutine-library) | An entry point run as a coroutine on its VM's owner, one segment at a time |
| [The runtime adapter](#the-runtime-adapter) | Supervised workers each running one VM, with bounded dispatch and exactly-once settlement (a sublibrary of its own) |
| [The scheduling machinery](#the-scheduling-machinery), [The scheduled owner](#the-scheduled-owner) | Policies, service classes, logical and elapsed time, budgets and control; then the same on real VMs |
| [Script instances](#script-instances), [Instance leases](#instance-leases), [Lifecycle services](#lifecycle-services) | Instances of a module with their own state, hooks, events and an application-controlled lifecycle |
| [Asynchronous requests](#asynchronous-requests), [Atomic request admission](#atomic-request-admission), [Provider events](#provider-events) | Requests a provider answers later, and events delivered into an instance's bounded queue |
| [The script runner](#the-script-runner) | Runs a list of Lua files to completion as the instances of one named VM; the library behind the `lua` subcommand |
| [The protocol model](#the-protocol-model) | The pure task, admission, request, subscription, epoch, failure and stop types; shares nothing with the host |

A concrete game namespace and the confined path for untrusted code are not
here (the retired Lua runtime design is listed in
[removed_records.md](../../docs/removed_records.md)).

## What the boundary exposes

Four modules are public:

- `Hetoimasia.Scripting.Lua.Owner`: the protected VM owner (`withVmOwner`,
  `evalOwned`, `callOwned`, and the module and entry-point operations). Its
  `OwnedVm` is not the bridge's `Vm`, so no bridge operation can run Lua on a
  managed VM or close it behind its owner's back.
- `Hetoimasia.Scripting.Lua.Registration` and `Hetoimasia.Scripting.Lua.Value`:
  what an application registers and what crosses. They hold no VM.
- `Hetoimasia.Scripting.Lua.Bridge`: the lower, unmanaged surface the owner is
  built on (`newVm`, `closeVm`, `evalChunk`, `callGlobal`, `chunkName`, the
  `Library` set, the failure types). Its callers close what they construct.

`Vm` and `ChunkName` are abstract. No exported module hands a caller a Lua
state, a stack index, a registry reference, a coroutine, a closure or a native
address; those live in the private `bridge` sublibrary, which nothing outside
the package can depend on. A `Task` names a coroutine and gives access to
nothing of it. `Test.Lua.Opacity` compiles clients that try each reach and
requires the compiler to refuse them.

Two absences are deliberate. **A bare Haskell function cannot be handed to
Lua**: it reaches a script only as a binding of a validated `Registration`, in
a namespace the owner's policy grants, with schemas for what crosses. And no
call opens "all the libraries": `newVm` takes the list, and `[]` is a VM with
no standard library.

## The binding, and why this one

`lua-2.3.4` (bound `lua >=2.3.4 && <2.4`), which bundles the Lua **5.4.8** C
sources. `hslua-core` is **not** used: its `LuaE` monad exports the raw
`Lua.State`, and its `run` masks asynchronous exceptions across the whole
computation, where this bridge must decide for itself what a cancellation
around a native call does. From `lua` only the C API, the bundled interpreter
and the individual `luaopen_*` functions are used.

### Provisioning and build identity

The interpreter is the copy `lua` bundles; nothing is provisioned.
`cabal.project.common` pins the binding's flags for every project
configuration:

```
package lua
  flags: -system-lua -pkg-config -allow-unsafe-gc
```

**`-system-lua` and `-pkg-config` keep a second Lua off the build**: with
either on, the build links whichever `liblua` the machine offers.
`-allow-unsafe-gc` is disabled for correctness (below). The CI package-store
key covers `cabal.project.common`, so changing these flags invalidates the
cached build of the bundled sources.

## The foreign-call audit

### What is used, and what is not

Several operations go through this package's own C
(`bridge/cbits/hetoimasia_lua_bridge.c`) instead of the binding's wrappers,
because the wrappers allocate their arguments before their protected call.

| Import | Annotation | Used by |
| --- | --- | --- |
| `lua_pcall`, `lua_close` | `safe`, fixed | every call into Lua; the close |
| `luaL_loadbuffer`, `lua_tolstring`, `luaL_ref`, `luaL_unref` | `safe`, by the flag | loading a chunk; reading a string error value; the fixtures' registry probe only |
| `hetoimasia_lua_publish`, `hetoimasia_lua_getglobal`, `hetoimasia_lua_requiref`, `hetoimasia_lua_filter_m1` | `safe` | publishing a callback, reading a global, opening a library, filtering the M1 profile: each one protected call |
| `hetoimasia_lua_newstate` | `unsafe` | creating the interpreter |
| `lua_gettop`, `lua_settop`, `lua_type`, `lua_typename`, `lua_isinteger`, `lua_tointegerx`, `lua_tonumberx`, `lua_pushboolean`, `lua_pushlightuserdata`, `lua_touserdata`, `lua_remove` | `unsafe`, fixed | stack bookkeeping, rendering, the callback entry |

Deliberately **not** used: `hsluaL_newstate`, `hsluaL_requiref`,
`hslua_getglobal`, `hslua_setglobal`, `hslua_pushhsfunction`,
`hslua_newhsfunction`, `hslua_extracthsfun`, `hslua_error`. Each allocates
before its own protection or brings the binding's foreign export with it.

The `safe` calls release the capability, so other Haskell work and other VMs
progress while one VM runs a chunk. **`-allow-unsafe-gc` must stay off**: each
Haskell function in Lua is a userdata whose `__gc` frees a stable pointer, so
the collector re-enters the RTS, which an `unsafe` import may not do. The cost
of the `safe` overhead on allocation paths has not been measured.

### Allocation, and where a Lua error can be raised

Almost every allocating Lua operation can raise `LUA_ERRMEM`.

- **From inside a callback**, a raise `longjmp`s out of a Haskell frame to the
  caller's `lua_pcall`: undefined behaviour. The callback entry therefore uses
  only non-allocating operations (`lua_pushboolean`, a light userdata as the
  failure marker). A registered binding reads arguments, pushes results and
  captures context in `hetoimasia_lua_values.c`, each operation one
  `lua_pcall` with only C frames inside it, so exhaustion is a status that
  becomes a typed fault.
- **From Haskell, outside any protected frame**, a raise runs Lua's panic
  function and ends the process. So: `hetoimasia_lua_newstate` is
  `luaL_newstate`, which answers null on failure (`newVm` raises
  `MemoryExhausted`); publishing a callback, reading a global and opening a
  library each run entirely inside one `lua_pcall`, name strings included;
  reporting a fault takes no `luaL_ref` and calls `lua_tolstring` only on a
  value that is already a string (a number is formatted in Haskell).

The carrier metatable is registered only once complete, `__gc` included, so a
half-built state cannot leave a carrier nothing finalizes. Ownership of the
stable pointer is reported by a flag the shim sets where the metatable is
attached; the bridge frees the pointer only when the flag says Lua never took
it. `lua-hazard allocation-failure` walks an allocator budget upward over all
three replaced paths.

### How callbacks re-enter

The C closure calls this package's `foreign export`, `hetoimasia_lua_enter`. A
negative result count means the value on top is the failure marker, and
`lua_error` is raised by the C closure after every Haskell frame has returned.

The export runs the callback **in a Haskell thread of its own**, not the
thread that called `evalChunk`. So a callback cannot be cancelled by
cancelling the calling thread, and the escape record lives on the `Vm`.

**A callback's operation on its own VM is refused.** The caller holds the VM's
gate until the callback returns, so an operation or close asked from a
callback thread fails at once with `VmReentered` (naming the operation) before
taking the gate: it runs no Lua, leaves the stack, retains no release and
publishes no global. The refusal travels like any callback failure, and the VM
stays open. This covers callbacks run by `__index`/`__newindex` metamethods
and by a `__gc` during the close (carried by the close's `CloseFault`). The
check is by thread identity: re-entry through a thread the callback starts, or
through another VM calling back, is not detected and is equally forbidden.

Reading or publishing a global can run metamethods, so every such path reports
its own protected call's status and drains the escape record.

### Error and cancellation transport

**Cancellation targets a VM's execution owner, never a callback thread.** A
trusted callback must not publish its `ThreadId` and must not leave work
running past its return: a cancellation delivered in the RTS's prologue or
epilogue around a foreign export ends the process (`lua-hazard
callback-cancellation` reproduces it; diagnostic only).

- **Owner cancellation stays observable.** It is not delivered inside Lua
  (`lua_pcall` is `safe`); it arrives once the call has returned and the
  operation's bookkeeping is done. Operations run masked for that reason. A
  cancelled operation retires nothing its callbacks borrowed; that waits for
  the close.
- **A callback's failure keeps its type and context.** The action runs
  unmasked; its failure is recorded on the VM and answered to Lua with a
  message-less marker. Lua may `pcall` it and finish; the operation's boundary
  still re-raises the recorded exception, adding its operation to the context.
  The first escape of an operation is the one kept.
- **Nothing promises to interrupt arbitrary Lua.** Callbacks are short and do
  not block; blocking work belongs in an asynchronous request or is cut into
  segments.

A Lua error inside a protected call is a status, never an unwind. It is
classified (`LUA_ERRMEM` is `MemoryExhausted` wherever it comes from), its
value rendered under a bound, and it becomes a `LuaFault`. Rendering runs no
Lua (no `__tostring`), reports a non-string, non-number value by its Lua type
alone, never by address, and reads absence from the stack depth, so `false`
is a boolean.

### Supported and rejected execution paths

Supported: one execution owner per VM, enforced by a gate (a second thread's
operation waits; an operation on a closing or closed VM is refused); several
VMs running concurrently with separate globals; Haskell work and a second VM
progressing while one VM runs a long chunk; closing a VM whose last call
failed; closing twice.

Rejected:

- **Cancelling a thread that is inside Lua.** `throwTo` blocks until the call
  returns. Reclaiming a running task needs a hook Lua consults or a process
  boundary.
- **Unprotected calls**: one that errors ends the process.
- **Using a VM, or anything a callback borrowed, after the terminal close.**
- **A registry reference or a number-to-string conversion on a reporting
  path**, and **any allocating Lua operation from inside a callback**.
- **Running Lua, or closing, from a callback of the same VM** (`VmReentered`).
- **Cancelling a callback thread.**

### Process-global state and thread affinity

The binding declares **no OS-thread affinity**: a VM may be driven from any
Haskell thread its owner chooses, one at a time. Neither the binding nor the
bridge adds a process-global lock; the only serialization is the per-VM gate.
Two locks are reached indirectly: the RTS's stable-pointer table and the C
allocator. Lua shares no state between `lua_State`s.

The suite and `lua-hazard` run with `-threaded -rtsopts -with-rtsopts=-N2`.
The hazard runner has four modes: the allocation sweep and
`capability-release` (run with `+RTS -N1`, observed by a count hook inside
Lua, so it fails if the call did not release the capability) are routine; the
uninterruptible chunk is selected by `lua-hazard-probes`;
`callback-cancellation` is run by hand and ends the process some of the time.

## Lifetimes

`closeVm` is terminal and runs once. The caller that finds the VM open runs
the teardown holding the operation gate with the phase `Closing`: an operation
arriving meanwhile is refused, and a second `closeVm` waits for that one
teardown. The teardown is masked.

Dependencies are released only after `lua_close` has returned, because Lua's
finalizers run until then. A callback's release is retained *before* the
callback is published, so Lua can never reach a callback whose release is not
held; a failed publication leaves a release that runs at the close. Every
release is attempted, and their failures, with every failure a Haskell
finalizer raised during `lua_close`, are collected into one `CloseFault`.
Each is a `CloseFailure` with its origin (`FromFinalizer`,
`FromRefusedFinalizer`, `FromRelease`, `FromStrandedOperation`,
`FromTruncation`) and the exception with its context.

An unrestricted `lua_close` is deliberately **not** wired into
`withResource`: the resource contract's release discipline assumes controlled
blocking, which a close running arbitrary Lua finalizers does not have. The
protected owner holds the lifetime instead.

A VM made by `newVm` is *unmanaged*: nothing owns it beyond the gate, and the
callbacks its finalizers reach all run. A library that fails to open closes
the interpreter through the same close before the failure is raised, and that
close's failure is retained beside it.
## The VM owner

`Hetoimasia.Scripting.Lua.Owner` offers the protected IO lifetime of one VM:
`withVmOwner` takes a `VmConfig` (libraries or a library profile, initial
chunks, an owner name, a registration and its policy, value limits, initial
modules; `vmConfig` and `vmProfileConfig` build one) and lends its body an
`OwnedVm`. The body uses `evalOwned`, `callOwned`, `loadModule`,
`loadedModule`, `callEntry`, `startTask`, `resumeTask` and `closeTask`.
`OwnedVm` exposes no Lua state and no way to close the VM: only the lifetime
does.

The lifetime, in order:

1. The interpreter and its control state are allocated, masked (a failure
   here leaves nothing to close).
2. Initialization runs with the caller's masking state restored: the
   libraries in order, the granted bindings, the initial chunks in order, the
   initial modules in order.
3. The body runs, unless initialization failed.
4. The VM is closed, whatever ended the steps before.
5. Every cancellation still pending is taken at one place, and the outcome is
   composed.

The VM is never reachable half-constructed.

### One owner per VM

A VM an owner constructed belongs to the thread that runs its lifetime. An
operation or close asked by any other thread is refused with `VmNotOwned`
*before* the gate is taken, so it runs no Lua and does not disturb the owner.
That holds for a thread the body started, a second owner handed the VM, and a
reference that escaped. After the lifetime every attempt is `VmClosed`. A
callback's own attempt on its VM is `VmReentered`.

### Any number of independent owners (D-15)

Any number of owners may be live at once, created and closed in any order on
any threads. None shares a VM, global state, registry or callback table with
another, so closing, failing or cancelling one leaves the others unchanged.
There is no pool or scheduler across them.

### The exit and evidence matrix

Whatever ends the lifetime keeps its type, value and context. The close's
failures are retained beside it as cleanup evidence through `composeCleanup`,
each with its context and a label naming its source (`lua finalizer`, `lua
finalizer refused`, `lua release`, `lua operation`, `lua evidence truncated`,
`lua coroutine close`, `lua close`). A supervisor reads them with
`cleanupFailures` or `cleanupFailuresInContext`.

| Exit | What the owner raises | Cleanup evidence |
|---|---|---|
| Body returns, close succeeds | The body's result | None |
| Body fails | The body's failure, unchanged | Every close failure, finalizers' first then releases'; none if the close succeeded |
| Body returns, close fails | The first close failure | Every close failure, that first one included |
| Body returns with tasks still suspended | The result, unless a close fails | Each task's coroutine is closed first, in start order, every one attempted; a to-be-closed variable's error is evidence under `lua coroutine close` (see [Closing](#closing-a-task)) |
| Construction or initialization fails | That failure, after the VM that was made is closed | Any failure of that close |
| Cancellation before the lifetime | The cancellation; nothing was constructed | None |
| Cancellation during initialization, the body or the close | The cancellation, after the close has completed; repeated ones are absorbed by the first | Every close failure |
| Cancellation after the body failed | The cancellation, which supersedes the body's failure | The close's failures; the body's failure stays reachable as `WhileHandling` |

**A cleanup failure stays cleanup**, also when a cancellation is primary: the
exception raised is asynchronous, so a worker's outcome is cancelled, and it
is never re-raised as a script error a supervisor would read as a normal stop.

### The evidence seam in foundation

`Hetoimasia.Foundation.Resource.composeCleanup` composes a primary failure
with cleanup failures its caller already caught from a release it ran itself.
It neither runs nor masks anything. See
[docs/resources.md](../../docs/resources.md#caller-run-cleanup).

### Cancellation points

| Where the owner is | A cancellation |
|---|---|
| Before `withVmOwner` | Lands outside the lifetime; nothing is constructed |
| Allocating the VM | Deferred: masked |
| Initializing or in the body, outside Lua | Delivered; ends that step; the VM is closed |
| Initializing or in the body, inside a Lua call or callback | Waits for the call to return, then as above |
| Closing, including inside a finalizer or a retained release | Deferred; taken after the close |

The interpreter's close is masked, not `uninterruptibleMask_`, and runs once;
the retained dependency releases after it run uninterruptibly, as a scope's
do. **If a finalizer never returns the owner waits**, keeps the dependencies
and never detaches the VM. All cancellations pending when the close finishes
are taken together, so a later one cannot supersede the exception carrying the
evidence.

### Shutdown phase and the finalizer allowlist

Before the state closes the owner closes admission: every operation on the VM
is refused. A callback reached from a Lua finalizer runs only if the owner's
finalizer allowlist names it: exactly the granted bindings the registration
declares finalizer-eligible. The default is empty, and the asynchronous kind
can never be eligible. The allowlist is applied before arguments are read. Any
other binding is refused with `FinalizerRefused` without running, and the
refusal is cleanup evidence even if the finalizer's script caught it. The
first 64 finalizer failures are kept in order, and one further entry counts
the dropped (`FinalizerEvidenceTruncated`).

### A scope around each callback

`withVmOwnerScoped` is `withVmOwner` with a `CallbackScope`: a function that
receives each callback and a `CallbackSite` and runs it, on the callback's own
thread, for exactly the callback's duration. It runs for every callback the VM
runs (initial chunks and modules, task segments, closing handlers, allowed
finalizer bindings) and still ends when the callback fails. `siteIsCallback`
answers whether the calling thread is one of this VM's recorded callback
threads right now, so a scope that lends something can tell the callback it
lent to from every other thread. **The scope runs masked and must neither
raise nor wait.**

## Registration, modules and bounded values

What an application uses to expose a narrow capability to its own scripts. It
names no concrete namespace and grants nothing to a mod.

### Registration

A `Registration` is plain data and closures, built once by `registration`,
validated there, and opaque (no exported record label, so none can be updated
past validation). It holds application-named *namespaces* of named *bindings*
and the *capability types* scripts may be handed. One registration serves any
number of owners. A binding declares its kind, its argument and result
schemas, and three eligibilities:

| Kind | Constructor | Answers |
|---|---|---|
| snapshot query | `snapshotQuery` | values |
| owned state operation | `stateOperation` | values |
| command or UI intention | `commandIntention` | `true, nil` accepted, or `false, reason` (at most 256 UTF-8 bytes) as data |
| asynchronous native request | `asynchronousNativeRequest`, `asynchronousNativeRequestIn` | only on an owner configured with a request context (the `In` form is handed that context); otherwise a `NotYetSupported` fault and the action never runs. See [Asynchronous requests](#asynchronous-requests) |
| lifecycle operation | `lifecycleOperation`, `lifecycleOperationIn` | the same, with a lifecycle context. See [Lifecycle services](#lifecycle-services) |
| scheduler operation | `yieldOperation`, `waitOperation` | nothing: the task's coroutine is suspended (see [Tasks](#tasks-and-the-coroutine-library)); `WaitSettlement` needs a request context |

A binding is **direct-eligible** and nothing else by default, so a default
registration exposes nothing to a mod. `confinedEligible` is refused when a
schema carries a capability and for a scheduler operation; it grants nothing
by itself. `finalizerEligible` is refused for the asynchronous kind.
`withoutDirectPath` keeps an owner from installing the binding.

Refused when the registration is built: an invalid or duplicate name; a
namespace shadowing a standard-library global (`standardGlobals`); a bound
passed; a schema too deep or wide, repeating a record field or naming an
undeclared capability type; the eligibility refusals above.

| What | Bound |
|---|---|
| a name | 1 to 64 ASCII letters, digits and underscores; not starting with a digit; not a Lua keyword |
| namespaces in a registration; capability types | 64 each |
| bindings in a namespace | 256 |
| arguments, results to a binding | 16 each |
| nesting of a schema; fields of a record schema | 8; 64 |

### Per-owner policy

`vmPolicy` names the registration's namespaces this owner exposes. The
bindings are installed during construction, after the libraries and before
any initial chunk or module, by raw access (no metamethod runs), and the set
is fixed for the VM's lifetime. A policy naming an undeclared namespace
(`PolicyUnknownNamespace`), a failed install and memory exhaustion end
construction like any initialization failure.

The standard libraries a script reaches are the owner's explicit set
(`coroutine` is selectable; `utf8` is not offered) or a profile's. The debug
library an owner opens has no `sethook`. **An explicit `LibraryBase` brings
`load`, `loadfile`, `dofile` and `collectgarbage`**: an owner that must not
read the disk or compile source selects the M1 profile.

### The M1 library profile

`vmProfileConfig LibraryProfileM1` selects the filtered standard-library
surface of the M1 application's Lua owners. It is opt-in; explicit lists and
the standalone `lua` command are unaffected.

**Order.** Inside protected construction the interpreter is allocated, the
profile's libraries open, the profile removes what it excludes, and only then
does anything the application supplies run. The first authored code already
sees the filtered surface.

| Library | Kept | Removed |
| --- | --- | --- |
| base (`_G`) | `_G`, `_VERSION`, `assert`, `error`, `getmetatable`, `ipairs`, `next`, `pairs`, `pcall`, `print`, `rawequal`, `rawget`, `rawlen`, `rawset`, `select`, `setmetatable`, `tonumber`, `tostring`, `type`, `warn`, `xpcall` | `load`, `loadfile`, `dofile`, `collectgarbage` |
| `string` | `byte`, `char`, `find`, `format`, `gmatch`, `gsub`, `len`, `lower`, `match`, `pack`, `packsize`, `rep`, `reverse`, `sub`, `unpack`, `upper` | `dump` |
| `table` | `concat`, `insert`, `move`, `pack`, `remove`, `sort`, `unpack` | — |
| `math` | everything else | `random`, `randomseed` |
| `coroutine` | `close`, `create`, `isyieldable`, `resume`, `running`, `status`, `wrap`, `yield` | — |
| `os`, `io`, `package` with `require`, `debug` | — | never opened |

The removal is made once on the library tables themselves, so every route
(`rawget(_G, name)`, `_ENV`, a module's environment, the string metatable)
finds the name absent. Granted namespaces cannot bring a name back: the
registration refuses the standard names. Trusted Lua may still define its own
functions with those names.

- `print` and `warn` keep Lua's stock behaviour under the profile alone
  (process stdout; stderr after `warn('@on')`).
- A call to a removed function is an ordinary Lua error on a missing value.
  The profile ships no random generator.
- A configuration that selects a profile **and** names libraries is refused at
  construction with a `BoundaryFault` (`OpenLibraries`,
  `ProfileWithLibraries`).
- The filtering is one protected call, `hetoimasia_lua_filter_m1`; its failure
  is `MemoryExhausted` or `CallFailed` at stage `profile LibraryProfileM1`.
- **This is not hostile-code containment**: a trusted script can still hang
  its owner or exhaust memory.

### Modules and entry points

A module is Lua source the application supplies under a name and a version
(`ModuleSource`); the host reads nothing from disk and searches no path. It
loads at initialization (`vmModules`) or from the body (`loadModule`) and is
known by an opaque `ModuleHandle`. A second load under the same identity is
refused: there is no live reload. Source is text only; a precompiled chunk is
refused. Each module runs in its own environment: its global assignments are
private, and the standard libraries and granted namespaces read through to
the globals. That is separation of names, not a security boundary.

Bounds: 256 modules, 1 MiB of source, 64 entry points, 128 bytes of name or
version; one that does not fit is refused with `NoEffect`.

The application declares each entry point `Required` or `Optional`, with
schemas. They are looked up by raw access in the module's environment:

| Entry point | At load | At call |
|---|---|---|
| required, not a function | `EntryMissing` | a fault |
| optional, absent | — | `EntryAbsent`: nothing runs |
| present, not a function | — | a fault |

The opt-in alternative that returns a table is
[export modules](#export-modules-and-captured-behaviors).

### Values

Values cross as bounded copies in both directions: nil, boolean, 64-bit
integer, float, byte string, UTF-8 text, list, record, capability.

- Integers are exact over 64 bits; floats stay floats. An integer schema
  refuses every float (`1.0` included); a float schema refuses integers;
  `SNumber` accepts either and keeps which it was.
- Byte strings and text are distinct schemas; invalid UTF-8 is refused where
  text is declared.
- A list is a table whose keys are exactly `1..n`; a record's keys are exactly
  its declared fields (an optional one may be absent). Arity is exact.
- Tables are read raw. **A table with a metatable, even an empty one, is
  refused**, and so is a cycle (sharing is not a cycle).
- A nil cannot cross inside a table (`RuleNilInTable`), except as an absent
  optional field, which is still charged against the limits.
- Functions, coroutines, light userdata, foreign userdata and table keys that
  are neither integer nor string are refused with a typed reason.
- One value crosses **by reference**, and only into Lua: `VExportTable`
  (schema `SExportTable`, made by `exportTableValue` from an `ExportHandle`)
  names the [export table](#export-modules-and-captured-behaviors) a VM holds,
  and the owner pushes the very table. It must come from the VM that issued it
  (`RuleForeignHandle`); a slot holding no table is an `InternalError`. Its
  size is 9 bytes. A script cannot make one and a read from Lua never yields
  one.

One crossing (all arguments, or all results, of one call) is bounded by bytes,
depth and elements: default 64 KiB, depth 8, 4,096 elements; configurable with
`vmValueLimits` up to 16 MiB, depth 64, 1,048,576 elements. Bytes are the
encoding's size (1 for nil and boolean, 9 for a number, 5 plus length for a
string, 21 for a capability, 5 plus keys and values for a table); depth counts
nested tables; elements count every value, not keys. The reader stops at the
first limit reached, so its work is bounded by the limits, not the input.

`withArgumentLimits limits binding` also bounds that binding's arguments: the
reader applies the smaller of the binding's and the owner's limit for each
measure. It can only tighten, and leaves results and other bindings alone.
`bindingArgumentLimits` reads it back.

### Handles

A capability is an opaque identity: a declared type and a key, issued by one
VM. In Lua it is a userdata whose metatable hides itself; copying it creates
no authority. Every use is checked before the binding's action: issued by
this VM (`RuleForeignHandle`), of the declared type (`RuleHandleType`), and
live by the application's own check (`RuleRetiredHandle`). A module handle
from another owner is `ModuleHandleForeign`; after the lifetime every use is
`VmClosed`.

One exception to the liveness check: an explicit release (`releaseOperation`,
see [Instance leases](#instance-leases)) is declared with the one capability
type it releases, takes that handle as its only argument, and runs for a
handle whose lease has ended.

### Calling a binding

In order: the kind is checked (`NotYetSupported` for an undelivered kind); the
argument count; the arguments are read into a bounded copy; the copy is
checked against the schemas, capabilities included; the action runs with
copies only (no `OwnedVm`, so its own VM is `VmReentered` and another owner's
`VmNotOwned`); the results are checked, encoded under the limits and built in
Lua.

A refusal is a **fault of the call**: the action does not run for a refused
argument, and the owner's operation raises a typed `BoundaryFault` naming the
binding, the argument and the rule, even if the script caught Lua's side with
`pcall`. A Haskell failure raised by the action is re-raised at the owner's
boundary with its own type and context.

### Recoverable refusals

A binding is generic (above) unless its registration opts it in. There is no
owner-wide switch.

| Function | Effect |
|---|---|
| `recoverableRefusals binding` | The refusals the host makes **before the action** become an ordinary Lua error: argument count, shape, type, encoding, a limit, a capability of the wrong type, from another VM or retired |
| `withPrecondition check binding` | The same, and `check ∷ OwnerContexts → IO (Maybe Text)` runs first: before the host asks whether a scheduler operation can suspend and before any argument is read. `Just reason` refuses |
| `withArgumentCheck check binding` | The same, and `check ∷ OwnerContexts → [Value] → IO (Maybe Text)` runs **after** the host's own argument checks, on the copied values |

Preconditions run before argument checks, each group in the order added; the
first refusal wins.

**What the script sees**: an ordinary Lua error whose value is the string
`namespace.name: reason`, the reason at most 256 UTF-8 bytes
(`refusalReasonLimit`). `pcall` catches it and the invocation goes on; nothing
is retained on the VM. Uncaught, it is the script's own error. The host's
reasons are short fixed phrases, with anything of the script's own cut to 32
characters. **A precondition's or check's reason over the bound is not
truncated**: it is an application defect and a typed `BoundaryFault`
(`ValueRefused`, `RuleBytesLimit 256`), opted in or not.

A refused call never ran its action. It is not a rollback: what the same
invocation did earlier stands. A precondition reads only engine-owned state
(the `OwnerContexts`, or what the application captured), never an argument or
a Lua-visible table, so a script cannot change what it decides.

**After the action began**, two refusals are still ordinary for an opted-in
binding (`binding: reason`), and a fault of the call (`BindingRefused`)
otherwise:

- a request admission's credit that is full for good
  ([`CreditRefused`](#what-asking-reserves)), raised inside `startAdmitted`
  before any effect;
- **`refuseOrdinarily reason`**, for an **engine-owned** binding's action
  that finds, **before it has had any effect**, a state that makes the call
  final but is not a fault (a stop, a closure, an instance ending). The action
  releases every temporary obligation first and never raises it after
  committing an effect to a host. It counts as an action run. The reason has
  the same 256-byte bound and the same defect rule.

**A refusal is an error; a response is data.** A binding that returns
`nil, {code = "busy", message = text}` through declared result schemas has
answered successfully that it admitted nothing. The host never turns its own
full-capacity exception into one.

**What stays fatal**, opted in or not: the application's own failure (an
action's, a precondition's, a liveness check's); an asynchronous cancellation;
a bridge defect; an allocation or encoding failure; the refusal of a *result*
and every failure after the action ran; `SuspendRefused` once the
preconditions passed; `NotYetSupported`, decided before any precondition. A
caught refusal records nothing and clears nothing: a fault already recorded on
the VM is still raised by the operation.

**Finalizers.** Lua turns an error in `__gc` into a warning, so an ordinary
refusal there would be silent. An opted-in binding's refusal therefore keeps
the recorded fault for every call made while the VM is closing and for any
call made while the collector is not running (how Lua presents a running
finalizer, and also a script that stopped its collector).

```haskell
checked = recoverableRefusals (snapshotQuery "double" [SInteger] [SInteger] double)
tick = withPrecondition engineOpen (stateOperation "tick" [] [] (\_ → pure []))
```

```lua
local ok, err = pcall(app.double, 1.5)
-- ok == false, err == "app.double: argument 1: a float where an integer is declared"
```

### Fault evidence

A `BoundaryFault` is an ordinary Haskell exception, produced with no Lua run
to render it. It records the owner (name and VM identity), the operation
(`InstallBindings`, `LoadModule`, `CallEntry`, `CallBinding`, `StartTask`,
`ResumeTask`, `CloseTask`), the module's name and version and the entry point
when the call was made from that module's own code, the binding, the source
chunk, a bounded traceback, a typed reason and an `Effect`:

| Effect | Meaning |
|---|---|
| `NoEffect` | refused before any Lua or binding action ran |
| `LuaRan` | Lua had run in the operation; no binding action had |
| `BindingRan` | a binding's action had run: application state may have changed |

The effect is the one the operation **ended** with, not the one at the first
fault. The traceback is built from `lua_getstack` and `lua_getinfo` alone (not
`luaL_traceback`), so no script Lua runs and nothing is allocated; it is
bounded at 2,048 bytes and 22 levels. The close is an operation of its own.

### Phases that execute nothing

A Lua allocation can start a collection step that runs `__gc` finalizers,
which can call bindings. So the collector is held across every host-side
phase: reading arguments, building results, the entry-point lookup, the
boundary's registry set-up, and a module load until its chunk starts. It is
given back as found, and the bytes a held phase allocated are paid as one
step where script code may run, so a loop of crossings cannot grow the heap
without bound. Consequently:

- looking up an absent optional entry point answers `EntryAbsent` having run
  no Lua, and arguments are not validated (the lookup comes first);
- a load rejected before its chunk starts (precompiled, syntax error,
  allocation failure while parsing) is `NoEffect`; one that fails later says
  `LuaRan` or `BindingRan`.

### Registry, stack and memory discipline

Every operation leaves the stack at the depth it entered at, on every path. A
loaded module holds exactly one slot of a table the bridge keeps in the
registry, for the owner's lifetime. Failed loads, calls and refusals retain
nothing. The slots are not `luaL_ref` references; the live count is
`liveModuleReferences`.

Memory running out at any step of installing, loading, calling or marshalling,
inside a callback included, is `MemoryExhausted` as a `LuaFault` or a
`BoundaryFault` with `ScriptFailed MemoryExhausted`: never a panic, an unwind
through a Haskell frame or a leaked reference. This covers the allocator
failures Lua reports. A failed *initialization* closes the VM and never enters
the body. `ownerBudget` limits the interpreter's allocator, so it covers a
registration's installation, not its construction.
## Export modules and captured behaviors

An opt-in facility beside the global-entry modules, which are unchanged. A
module here is source text under a stable identity whose chunk **returns one
table**, which the VM keeps as it is. Everything runs on the VM's owner
through the protected boundary. The handles name a slot of one VM's registry
and are checked on every use.

### The export table

`evaluateExport` loads the text in a private module environment that reads
through to the owner's globals (so
[the M1 library profile](#the-m1-library-profile) has already filtered them),
runs it, and requires **exactly one** returned value, a table with **no
metatable**. Module failures, kept as the identity's outcome:

| The chunk | Failure |
| --- | --- |
| returns nothing | `ExportShapeRefused ExportNoResult` |
| returns `nil` | `ExportNil` |
| returns a boolean, number, string, function | `ExportNotTable` naming the type |
| returns more than one value, an extra `nil` included | `ExportMultiple` |
| returns a table with a metatable, protected or not | `ExportMetatable` |
| fails to parse, is a precompiled chunk, or raises | `ScriptFailed` (traceback bounded) |

The table and everything reachable from it stay **in the VM**: nothing is
serialized or copied, and Lua graph cycles are permitted. Module globals stay
in the module's environment. This is neither isolation nor a rollback: what a
chunk did before it failed is not undone.

### Identity, sticky failure and bounds

An `ExportIdentity` is opaque bytes the caller chose (for the loader, the
root plus the canonical path), compared exactly, 1 to 4096 bytes, never
truncated or hashed. A record keeps a copy that owns its bytes.

- **Once per identity per VM.** Asking again (`evaluateExport`,
  `retrieveExport`) answers the same table or the same failure and runs
  nothing. A failed identity is never retried with replacement bytes.
- **Ceilings** come from the owner's `ExportLimits`; the M1 profile's
  (`Hetoimasia.LuaEngine.Behavior.exportLimits`) are 1 MiB of source, 256
  identities per VM and a chain of 32 frames. Failed and in-progress records
  count; nothing is evicted.
- A source one byte over is **never compiled**: while room remains it is a
  failed record that counts, `ModuleRefused (SourceTooLarge n)`. A *new*
  identity at a full ceiling is `ModuleRefused (TooManyExports n)` with no
  record. Retrieval consumes nothing.
- Global-entry modules, the instance driver included, keep their own bound
  (`maxModules`) and use no slot here.
- The source bytes are not kept.
- A failure before the chunk can start charges nothing, so the identity can
  be asked for again. A Haskell failure that reached a callback while the
  chunk ran is raised in preference to what Lua reported, and the identity is
  recorded as failed.

`VmConfig` takes `vmExports` (evaluated after the modules at initialization;
a failing one is a recorded failure and does not end construction) and
`vmExportLimits`.

### A selected behavior

`captureBehavior` validates one field of an export table as a **behavior**
and captures it for one instance. It is read by raw access, visiting at most
six entries; no metamethod runs and no hook runs.

- The field must be a table with no metatable whose only keys are `init`,
  `update`, `shutdown`, `every_ticks` and `every_seconds`. Any other key, or
  a hook that is neither absent nor a function (a `__call` table is not a
  function), is refused (`BehaviorProblem`).
- An invalid role that was not selected fails nothing.
- The answer reports which hooks exist and how each cadence field *reads*
  (`CadenceField`: absent, integer, float, other), unconverted. What a
  cadence means is the application's.

A behavior that does not fit is returned as data and holds nothing.

### What a capture holds

By one registry slot: the very `init`, `update` and `shutdown` functions, a
fresh `self` table whose `api` is the facade, and the facade. The **facade**
is made last, after the behavior validated, from a `FacadeSource`:

| Source | The facade is |
| --- | --- |
| `FacadeValue v` | a fresh copy of `v` within the owner's value limits; data only; must be a table (`FacadeNotATable` otherwise) |
| `FacadeField export key` | the table a retained export module holds under `key`, shared by every capture naming it |
| `FacadeBuilt export key v` | built for this capture by calling the function under `key` with a copy of `v`; it may carry closures bound to this instance; a raise or a non-table result fails and releases the capture |

The same table is `init`'s `api` and `self.api`. Assigning to `self` or the
facade cannot replace the captured hooks. A missing or wrongly typed field
(`FacadeFieldMissing`, `FacadeNotATable`, `FacadeBuilderNotAFunction`) or a
foreign export handle is refused with no effect.

Editing the behavior table afterwards changes nothing a capture does.
Capturing a function does not freeze its upvalues.

What a captured hook raises is attributed to **the export module that holds
it** (its label, version `export`, the hook's name as the entry), for `init`,
every segment of `update` and `shutdown`. The hooks are run through a driver:
see [M1 behavior instances](#m1-behavior-instances-opt-in).

### Reference lifetimes

| What | Held until | Refused when |
| --- | --- | --- |
| export table | the VM closes (released at once if the evaluation fails afterwards) | foreign owner `ExportHandleForeign`; slot not held `ExportHandleStale`; closed `VmClosed` |
| failed record | the VM closes; holds no Lua value; counts against the ceiling | — |
| capture | `releaseBehavior` (idempotent), the instance's end, or VM close | foreign `CaptureHandleForeign`; released or never made `CaptureHandleStale`; closed `VmClosed` |
| hook, `self`, facade in a coroutine | the coroutine is closed or returns; an ending closes its coroutines before it releases the capture | release never invalidates a use under way |

Slots are issued once and never reused, so a stale handle can never name a
later capture.

## Ordered import chains: the module loader

An opt-in, engine-managed way to evaluate
[export modules](#export-modules-and-captured-behaviors) when a module
discovers a dependency while it runs. A module the loader evaluates runs once
as a Lua coroutine of the VM in its own environment and returns one table.
It can call `import(path [, root_id])`, which can **suspend the importing
coroutine** until the dependency's verified source has arrived and its module
has finished, without blocking the VM's owner. The synchronous
`evaluateExport` gives its module no `import`.

The loader compiles, evaluates, resumes, publishes and releases only on the
owner's thread, under the VM's gate; any other thread is refused with
`VmNotOwned`. It reads no file and adds no worker or scheduler.

### The seams

`VmConfig` takes `vmLoader`, a `LoaderConfig`:

| Seam | What it does | Where it runs |
| --- | --- | --- |
| `SourceSupplier` | `supplierAcquire identity` registers interest once per identity and answers `SourcePending`, `SourceVerified bytes`, `SourceFailure reason` or, for a dependency only, `SourceNoRoom` (no interest taken; the import is `ImportCacheFull`). `supplierRelease identity` ends the interest exactly once: bytes consumed, source failed, or loader stopped. An acquire that raises took no interest | acquire: the owner's thread (a root) or the `import` callback (a dependency); release: the owner's thread. **Never blocking**; asking the same VM for anything is `VmReentered` |
| `AddressResolver` | turns an import's arguments and the `ImportContext` of the module whose code made the call into a canonical identity and a bounded label; `Left` is an ordinary Lua argument error | the `import` callback, unmasked |
| `loaderEligible` | whether the root at the head of the queue may begin now | the owner's thread, only when no chain is active |

`ModulePhase` (`newModulePhase`, `modulePhaseActive`) is a flag the loader
sets while a module's top level runs.

### A chain

A coordinator admits **roots** (`admitRoot`) in the order it chooses, and the
loader keeps that order. A root's source is asked for at once, but the root
begins only when it is at the head of the queue, `loaderEligible` allows it
and its source has arrived: **source arrival alone never starts a root and
never lets a later root overtake.** `deliverSource` records an answer and
evaluates nothing. `advanceLoader` is the one operation that runs Lua. One
chain is active per VM:

1. The root's source is compiled (text only) into a coroutine in its own
   environment, and its first segment runs.
2. `import(path)` resolves to an identity. A ready identity returns the very
   table the VM holds. Otherwise the importing coroutine is suspended once
   every Haskell frame has returned, and the dependency's source is asked for.
3. When the source has arrived the dependency runs as the next frame, **depth
   first, in Lua's import call order**, and the importer is resumed with its
   exports or its failure. An identity already pending as a later root is
   evaluated within the active chain, once; its own turn later finds an
   outcome. Its request is not settled here: the outcome is reported
   (`advanceSettled`, `lookupModule`) for the coordinator.
4. `advanceLoader` returns when the chain is finished, waits for a source
   (`BlockedSource`) or the head is not eligible (`BlockedIneligible`). An
   unfinished chain holds its frames until advanced again or stopped.

**Nothing preempts trusted Lua**: a module that never yields blocks its owner.
A raw `coroutine.yield()` at a module's top level fails the module
(`UnscheduledYield`). A registered scheduler yield or wait is refused in a
module chunk (`SuspendRefused SuspendOutsideTask`), failing the module. The
module environment is the filtered globals plus `import`.

### `import` outside module evaluation

In a hook, or a helper a hook called, `import` is the **immediate lookup**: a
ready identity returns its exports, a failed one raises its cached failure,
and any other raises an ordinary `module_not_ready` error. It starts nothing
and never suspends. The default root is the one captured from the module the
closure belongs to.

### Where Lua cannot suspend

An import of a **not ready** identity where Lua cannot yield is refused before
anything is admitted, with an ordinary Lua error, **and it fails the
containing load even if the script catches it**: `ModuleRefused
(ImportNotSuspendable why dependency)`. Ready and failed identities answer as
usual there.

| Where the import was called from | Outcome |
| --- | --- |
| the module's own coroutine, including across `pcall`, `xpcall`, a metamethod called from Lua code, a yieldable to-be-closed handler | suspends |
| a coroutine the script created, including its to-be-closed handlers | `SuspendOtherCoroutine` |
| a `table.sort` comparator, a `string.gsub` callback, a finalizer, a metamethod reached from a library function | `SuspendNotYieldable` |
| the closing of a failed or stopped module | a lookup like a hook's |

`import` is not finalizer-eligible: from a finalizer while the VM closes it is
`FinalizerRefused`.

### What an import refuses, and what it condemns

| Case | The containing load |
| --- | --- |
| malformed path or root, a root the resolver refuses | **not** failed; an ordinary error before any slot, interest or frame exists |
| a dependency that failed | failed with `DependencyFailed label identity fault`, even if caught |
| an identity already on the chain | failed with `ImportCycle [a, b, a]`; no frame is allocated for the closing edge |
| a new dependency at the identity bound | failed with `ImportCacheFull`; no record |
| a new dependency past the chain bound | failed with `ImportChainTooDeep`; no record |
| not ready where Lua cannot suspend | failed with `ImportNotSuspendable` |
| a registered binding refused a call as a fault of the call | failed with that fault, even if caught; the owner is not ended |
| a Haskell failure that reached a callback | **not** the module's: raised from the operation (below) |

In every row Lua sees an ordinary error. A dependency's failure propagates up
the chain; each dependency that **completed** stays ready and is reused. No
retry, eviction, partial publication or rollback.

### Identities, records and the bounds

The loader keeps **no second cache**: pending and evaluating identities are
records of the same table as ready and failed ones, and every record counts
against the identity bound until the VM ends. M1: 256 identities, 1 MiB per
module, a chain of 32 frames with the root (`exportMaxChainDepth`; the 33rd is
`ImportChainTooDeep 32`).

- A **new root** past the bound is `RootRefused (RootCacheFull n)`: no record,
  no source asked for. A root the owner already holds is reused at any fill:
  `RootSettled` (ready or failed) or `RootJoined` (pending or evaluating).
- Source past the bound is never copied, kept or compiled: a failed record,
  `SourceTooLarge`, its interest ended at once.
- A dependency over a limit **fails its importer**; the loader never waits
  for room and never evicts.
- Failures are sticky, first kept: `SourceUnavailable`, `SourceTooLarge`,
  `ScriptFailed`, `ExportShapeRefused`, dependency, cycle, limit,
  `UnscheduledYield`. A module's failure is data and ends neither other roots
  nor the owner.

### The phase of a module's top level

A module's top level does not inherit the authority of the instance whose hook
started the work. An engine service guarded with `withPrecondition` reads
`modulePhaseActive` and refuses as an ordinary Lua error before its action. A
function the module defines may use the service later, when a hook calls it.
The phase also covers the closing of a module's coroutine (its to-be-closed
variables). `modulePhaseModule` answers the `ImportContext` of the module
whose code runs, from the loader's own record, and `Nothing` outside every
module; an application binding reads it to attribute a call. Both are put back
as they were however the segment ends.

### Stop and what it leaves

`stopModuleLoader` (the owner's lifetime also does it, before the VM closes),
in order: closes admission; closes every suspended module innermost first,
running its to-be-closed variables; withdraws every source interest once;
drops every unused answer; empties the queue; marks every pending or
evaluating identity **stopped** (`ModuleStopped`, `ExportStopped`). **A stop
is not a failure.** A late or duplicate source changes nothing
(`SourceAfterStop`, `SourceDuplicate`, `SourceUnwanted`). Stop is terminal and
idempotent; what completed stays readable. Every close and release failure is
attempted, kept and raised together afterwards, the first as primary.

### Failures of the engine and the application

A Haskell failure that reaches a callback while a chain runs (a supplier or
resolver that raises, a refused re-entry) is raised from `advanceLoader` in
preference to what Lua reported, never as a catchable content error. The chain
is abandoned: every suspended frame is closed, its identity recorded as failed
(`the evaluation was abandoned`), and a table a segment kept is released.
Memory exhaustion inside a segment is the module's `ScriptFailed`. The loader
stays usable; identities that were only pending stay pending.

### Ownership, threads and lifetimes

Everything below is owned by the VM's owner, on its thread.

| What | Made by | Ends by | Bound |
| --- | --- | --- | --- |
| identity record | `admitRoot` or the import handler | terminal: ready, failed (sticky), stopped; released at VM close | `exportMaxIdentities` |
| source interest and its answer | supplier `acquire` | consumed, failed or stopped: `supplierRelease` once | one per pending identity; the source bound |
| module frame (a coroutine in a task slot) | compiling the delivered source | returns, fails, or closed by stop or abandonment | chain depth; `liveTaskReferences == chain depth` |
| export table slot | a frame returned one plain table | VM close; released at once on condemnation | one per ready identity |
| pending import | the import handler | the dependency's outcome, or stop | one per chain frame |

### Hosting it on a scheduled owner

A [scheduled owner](#the-scheduled-owner) created with `scheduledLoader =
Just plan` (`Hetoimasia.Scripting.Lua.Loading`) hosts the loader on its
worker. `scheduledLoaderEndpoint` gives the side any thread may use without
blocking:

- `submitRoot endpoint request due`: `DueUi` (eligible at once, in submission
  order) or `DueTick t`. Logical roots must be submitted in non-decreasing
  tick order (`SubmitOutOfOrder`).
- `notifySource endpoint identity answer`; a second one for a waiting
  identity changes nothing.
- `loaderOutcome`, `awaitLoaderOutcome` (STM), `loaderRefusals`,
  `loaderDiagnostics`: admitted (from the moment the submission is accepted),
  ready or failed with the handle or sticky fault, refused (the last
  `planBound` kept), or stopped.

Both queues are bounded by `planBound`; a full inbox refuses (`SubmitFull`,
`NotifyFull`). At each boundary the owner admits, delivers and advances, so
all loader work happens on its thread **between two scheduler turns**.

**A logical root owes its tick from its submission.** `submitRoot` records
the obligation in the transaction that accepts it. The scheduler keeps the
grant that reaches tick `t` unfinished, and applies no later grant, until the
root has an outcome. A resubmitted root keeps its earliest obligation. A UI
chain owes nothing.

Once a stop is asked of the owner, nothing more is admitted, delivered,
started or resumed. At exit the inbox closes, the loader is stopped, and every
merely admitted outcome is published as stopped. `LoaderPlanRefused` names a
bound below one or a VM configuration that already names a loader.

### Placed roots (LFE-11)

Generic additions the module coordinator (`Hetoimasia.LuaEngine.Modules`)
drives; `admitRoot` and `submitRoot` are unchanged.

- **Order.** `admitRootAt` admits a root with a `RootOrder tick sequence`:
  roots start in order, equal orders in admission order, whatever order their
  sources arrived in. `promoteRoot` asks for a pending or evaluating identity
  to start no later than an order; an order never moves later, and no second
  record, interest or evaluation is made (`PromotionMoved`,
  `PromotionNotEarlier`, `PromotionNothingQueued`, `PromotionUnknown`).
- **Reserved room.** `loaderReserved identity` is the number of other
  identities the application has promised room for. It counts against the
  identity bound, so a dependency cannot take an accepted root's room; a root
  admitted from its reservation (`admitRootAt … True`) is not asked the bound
  again. The supplier's `SourceNoRoom` is the arbiter for a dependency.
- **A failed identity looked up from a hook.** The hook gets an ordinary
  catchable error, and `loaderObserved identity fault` is called first on the
  owner's thread. With `LoaderHooks.hookObserved` answering `Just reason` the
  scheduled owner fails the running instance with the module's attributed
  failure, latched once and applied at the next safe boundary, so catching
  the error cannot make it a success. `noLoaderHooks` keeps the plain error.
- **Placed roots on a scheduled owner.** `DueAt tick sequence` starts only
  once the scheduler stands just before the tick (`ticksQuiet`,
  `tickQuietBefore`), and the tick is **held** (`ticksHold`) until the root
  has an outcome: a placed root finishes before any work of its tick begins,
  where `DueTick` lets the tick begin and keeps its grant open. The owner
  keeps one hold, for the earliest such tick. `promoteSubmitted`,
  `submitReservedRoot` and `notifySourceNow` run in the caller's own
  transaction; `pokeLoader` wakes the owner.
- **Hooks.** `LoaderHooks` is called on the owner's thread, outside Lua:
  `hookService` before every service, `hookSettled` with the identities that
  came to an outcome in order, `hookBlocked`, `hookReserved`, and `hookExit`
  once the loader is stopped. A hook that raises is an application failure.

### What is not here

Content reads, file workers, per-request module waiters, the request and
identity reservation, and the lexical-root, content, time and output facades
are `hetoimasia-lua-engine`'s, composed over this loader and
[request admission](#atomic-request-admission). There is no hot reload, mod
support or hostile-code isolation.
## Tasks and the coroutine library

A task is a module's entry point run as a Lua coroutine of its VM, on the VM's
owner, one segment at a time. This is the mechanism only: no clock, timer,
queue or policy is here.

### What a task is

`startTask` checks the handle, entry point and arguments exactly as
`callEntry` does and runs the entry point up to its first yield, wait or
return, answering `TaskEntryAbsent` (an absent optional entry point; nothing
runs) or `TaskStarted task step`. `resumeTask` runs the next segment with no
values. A `TaskStep` is `Completed results` (checked like a call's; the task
has ended), `Yielded`, or `Waiting` with a `WaitRequest` (the kind
`WaitElapsed` or `WaitLogical`, the binding and its arguments).

A task is a Lua thread kept in one slot of a registry table the bridge owns
until it ends. Starting, resuming and closing are VM operations: refused from
another thread (`VmNotOwned`), from the VM's callbacks (`VmReentered`) and
after the close (`VmClosed`). A `Task` names a slot of one VM and is checked
on every use: another owner's is `TaskRefused TaskForeign`, an ended one
`TaskRefused (TaskEnded TaskCompleted | TaskFaulted | TaskClosed)` with
`NoEffect`. It is never a `Value`. The host counts and caps no tasks; every
suspended one is closed when the VM closes.

### Yielding and waiting

A script gives control back through a **scheduler operation**, a binding of
the application's registration in a granted namespace: `yieldOperation name`
(no arguments) or `waitOperation name kind schemas`. Neither runs application
code. A wait's arguments are checked against its schemas and the owner's
limits before anything is suspended (`ValueRefused ... Arguments` otherwise)
and reported uninterpreted in the `WaitRequest`.

The handler runs in Haskell, records what the script asked for on the VM and
returns; the binding's C closure then calls `lua_yield` after every Haskell
frame has returned. The coroutine yields and is resumed with no values.

#### Where it cannot reach a scheduler

A scheduler operation called where the host is not resuming the calling
coroutine is a typed fault of the call, raised at the owner's boundary even if
the script caught it:

| Called from | Reason (`SuspendRefused`) |
|---|---|
| a finite `callEntry`, an initial chunk, a module's load, a finalizer on the owner's main thread, a to-be-closed handler while its coroutine closes, a close, another owner's VM | `SuspendOutsideTask` |
| a coroutine the script created, while a task runs | `SuspendOtherCoroutine` |
| the task's own coroutine inside a table-sort comparator, a pattern-replacement callback or a finalizer | `SuspendNotYieldable` |

It works across `pcall`, `xpcall` and a metamethod called from Lua code. A raw
`coroutine.yield` at the task's top level is `UnscheduledYield`, a fault of
the segment, and the task is closed. A script that resumes the task's own
coroutine by hand leaves the host's next resume with `TaskRefused
TaskNotSuspended`.

### The `coroutine` library

`LibraryCoroutine` is selectable like any library, for transient sequences
inside a task. A coroutine a script makes is still refused as a value
(`RuleUnsupportedType "thread"`). Coroutines are not serialized or migrated:
long-lived progress uses explicit state.

### Faults in a segment

A failing segment raises a typed `BoundaryFault` with the module, entry point,
operation, traceback, reason and `Effect`: `ScriptFailed CallFailed` or
`ScriptFailed MemoryExhausted`; `ValueRefused` on results or arguments, as
`callEntry` raises them; a binding action's Haskell failure re-raised
unconverted.

**A failure the script caught still wins.** At every boundary of a segment, a
refusal the boundary made or an application failure that reached a callback is
raised in preference to what Lua reported, even when the script caught the
stand-in and went on to yield, wait or return.

**A segment that fails leaves nothing.** The host builds the traceback from
the dead coroutine, closes it (running its to-be-closed variables) and empties
its slot (`TaskEnded TaskFaulted`). The segment's failure is the one raised;
what the close raises is cleanup evidence (`lua coroutine close`), bounded at
64 plus one count entry.

### Closing a task

`closeTask` runs a suspended task's pending to-be-closed variables on the
owner's thread and empties its slot. It is terminal and idempotent: the task
is closed whether or not a handler failed, and a failure is raised once as a
`BoundaryFault` of `CloseTask` (a Haskell failure from a handler's callback
outranks a script error; later ones are cleanup evidence). A scheduler
operation inside a closing handler is `SuspendOutsideTask`.

A VM closing with suspended tasks closes each first, in start order, every one
attempted, with their callbacks held to the finalizer allowlist. A
cancellation of the owner is deferred past all of it.

### Stack, registry and memory

Every operation restores its entry stack depth. A task's slot is emptied
however it ends, so the registry holds exactly the suspended tasks
(`liveTaskReferences`). Creating a coroutine is one protected call with the
collector held: exhaustion there is `ScriptFailed MemoryExhausted` of
`StartTask` with `NoEffect`.

## The runtime adapter

Trusted VM owners under runtime supervision: the public `runtime-lua`
sublibrary (`runtime-lua/`), whose one public module is
`Hetoimasia.Scripting.Lua.Runtime`. It depends on the host library, the
private `model` and `bridge`, `hetoimasia-runtime` and
`hetoimasia-foundation`. It uses the bridge for the process-wide record of
callback threads, the mark a failure of application code carries, and the
value-limit check. `Hetoimasia.Runtime.Inbox` is not used.

One owner is one supervised worker: `withVmOwner` composed with
`startSupervised`, `workerDefinition` and `awaitSupervised`. No pool, thread,
timer or supervisor of its own.

### Creation and readiness

`newLuaRuntime` makes a `LuaRuntime` over the `RuntimeControl` of one
`withSupervision` invocation. `startLuaOwner` takes an `OwnerSpec` (a
`VmConfig`, a `WorkerPolicy`, `CallBounds`) and answers an `OwnerStart`:

1. The bounds are checked; one below one raises `OwnerBoundsRefused` before
   any worker starts.
2. The owner's identity is issued and exactly one worker starts. Its `Scoped`
   startup allocates only the bounded queue and counters.
3. The VM is constructed and initialized inside `withVmOwner` on the worker's
   thread, which is therefore the VM's execution owner.
4. The body publishes readiness and opens admission in one transaction; only
   then is an endpoint handed out.

Readiness is one `awaitSupervised` wait composed with the worker's terminal
status. **The `startSupervised` acknowledgement is not readiness.** An
initialization failure ends creation under the owner's policy: a required
owner's failure is raised by supervision; an optional owner whose classifier
recognizes it answers `OwnerUnavailable`; an owner that ended without failing
`OwnerEnded`; a closed boundary `OwnerRejected`.

Acquisition is masked from the worker's start to the handoff, with only the
readiness wait restored. A creator whose wait is abandoned or cancelled asks
the owner to stop; the worker group still drains it. Creating an owner is
refused from a Lua callback.

### Identity

Each owner gets an `OwnerId` from its `LuaRuntime`, issued once, in order,
never reissued. Make one `LuaRuntime` per `withSupervision` invocation; two
runtimes never issue equal identities. The endpoint, every settlement and the
exit record carry it beside the label `vmOwnerName`. Neither confers
authority: that is exactly the configured `vmPolicy`.

### Submitting calls

An `OwnerEndpoint` submits a call to an entry point of a module the owner
loaded at initialization, named by `ModuleRef`. It is usable from any thread,
a binding's action included. `submitCall` never blocks and answers
`CallAccepted ticket`, `CallFull` or `CallClosed` (closed takes precedence; a
refusal changes nothing).

| Bound (each at least one) | Meaning |
|---|---|
| `boundQueuedCalls` | accepted calls waiting to start; the running call is not queued |
| `boundResults` | reservations held at once: taken atomically with the enqueue and held while the call waits, runs and sits settled but unobserved |

So a result always has a place before its call runs. An owner asked to stop
admits nothing from that moment, even while a call is held in a binding.

`prepareCall` evaluates the arguments completely **on the producer's thread**
and checks them against the owner's value limits, stopping at the first limit;
`submitPrepared` then evaluates nothing. What is kept is compacted (every
string copied to its own buffer). A call whose arguments were over the limits
is accepted and settles in its turn as the `ValueRefused` fault, `NoEffect`.
Schema and capability checks happen on the owner's thread.

### Settlement

Calls run one at a time, to completion, in acceptance order, through
`callEntry`. Each accepted call settles exactly once:

| Settlement | When |
|---|---|
| `CallReturned` | the entry point's `CallResult` (`Returned` values or `EntryAbsent`) |
| `CallFaulted` | a fault of the call, as data: `ScriptFailed`, `ValueRefused`, `NotYetSupported`, a missing entry point, or `ModuleNotLoaded` (`NoEffect`). The owner goes on |
| `CallDiscarded` | the owner exited first; records how (`ExitStopped`, `ExitFailed`, `ExitCancelled`) and whether the call had started |

A started call may have had real effects; only one that never started is
known to have done nothing. The failure that ended a failed owner goes only
to supervision. A call is always queued, in flight or settled, each change one
transaction, so no path settles twice or loses a call.

### Observing results

`pollCall` reads without blocking; `waitCall` waits on any thread that is not
running a Lua callback; `awaitCall` waits on the application thread, composed
with `awaitSupervised`. The first read that finds a settlement gives the
reservation back; later reads answer the same settlement. `forgetCall`
withdraws interest (the reservation returns at settlement). **A ticket nobody
observes or forgets keeps its reservation.**

### Waiting from a callback is refused

A thread running any Lua callback, of any VM, may submit calls but may not
wait for a reply. `waitCall`, `awaitCall` and `startLuaOwner` check when they
execute and raise `CallbackWaitRefused` (`wait-call`, `await-call`,
`start-lua-owner`) at once. Detection is the bridge's process-wide record of
callback threads; a thread a callback starts is not detected and stays
outside the contract.

### Host failures and policy

A Haskell failure raised by a binding's action or a liveness check, or any
exception escaping the owner (the VM's close included), ends that owner's
worker as its primary outcome, with the close failures as cleanup evidence.
The owner's `WorkerPolicy` then applies: a recognized failure of an optional
owner is `WorkerUnavailable`; anything else is fatal. **A retained cleanup
failure is always fatal**, whatever the policy.

A failure is the host's by where it was raised, not by type: the bridge marks
a failure where it escapes application code. An unmarked `BoundaryFault` or
`LuaFault` is a fault of the call, settled as data; a marked one ends the
owner.

### Stop, retire and the exit record

Stopping (`retireOwner`, `stopSupervised`, the boundary closing) closes
admission first. The in-flight call returns with its own settlement, queued
calls are discarded as not started, and `withVmOwner` closes the VM on the
worker's thread. Every other exit discards the same way, the in-flight call of
a failed or cancelled owner as started. Admission always closes before the VM
begins to close.

`ownerExitRecord` answers the `ExitRecord` once the owner has exited:
identity, label, how it exited, and the discarded calls counted separately as
started and not started. It carries no cleanup evidence. A stuck in-flight
call keeps the worker, VM and dependencies live: nothing is detached.

### Test rules for this suite

`lua-runtime-tests` (`runtime-lua-test/`) runs real VMs under a real
`withSupervision`, coordinated by gates, never sleeps. CI on Linux is the
evidence for cancellation and shutdown windows.

- An example that parks a callback at a gate must fail within its 60-second
  `bounded` limit however it ends: it runs its boundary through
  `withBoundaryOpening` (`expectFatalOpening`, `tryBoundaryOpening`,
  `alongsideOpening`), which opens every gate before teardown and when the
  bound expires.
- A helper that catches an expected failure (`expectFatal`, `tryExpected`,
  `failingWait`, `retainedFailure`) re-raises a failed assertion or the
  `bounded` timeout as itself. **Assert with `failExample`, never `fail` or a
  `userError`**, which a helper cannot tell from an injected application
  failure.

```bash
cabal test hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct
cabal test hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct --test-options='--match Runner'
```

It also runs under `--project-file cabal.project.cpu`. The validation group is
`test.scripting-lua-runtime`; see
[docs/validation.md](../../docs/validation.md).
## The scheduling machinery

`Hetoimasia.Scripting.Lua.Scheduler` (in `runtime-lua`) is what one owner
needs to choose, under a policy, which ready task runs next; give each
service class a bounded turn; keep logical time only the application advances
and elapsed deadlines behind one timer; apply pause, resume and stop at safe
boundaries; and count what it did. It starts no thread, owns no VM and
supervises nothing: it runs a segment and closes a continuation through the
two actions of a `TaskHost`. It imports only `base`, the foundation's clock
and the protocol model.

### How it is used

`newScheduler` makes a `Scheduler v`. The producer operations (`admitTask`,
`grantStep`, `requestControl`) are transactions callable from any thread that
never block. The owner's thread loops `awaitWork` (one STM wait over
admissions, control, grants, the timer's wake and the stop request; nothing
polls), then `serviceTurn`, and on its way out, masked, `stopScheduler`.
**Only the owner's thread calls those three, and a turn is not reentrant.**

`awaitStepsComplete` and a ticket's `awaitControl` are transactions the
application composes with `awaitSupervised`. A Lua callback must not call
them: a task waits by yielding.

### Configuration

`SchedulerBounds` holds the active-task, queued-admission and retained-result
caps, the three quanta, the bounds on outstanding grants and control requests
and an optional elapsed service budget. `newScheduler` checks all of it first
and answers every violation at once (the model's `validateLimits`; a quantum,
grant or control bound below one; a non-positive budget). A refused
configuration creates no timer and no state.

### Policies

A `Policy`, fixed at creation, chooses which ready task runs next and nothing
else. `fifoPolicy` is the default; the extension interface is `PolicyView`
(the class whose opportunity it is, and every ready task with its class, kind,
`Ordinal` and segment count) and `Candidate`.

A policy cannot starve a class, control or stop: it is offered one class at a
time and must choose a ready task of that class. Any other choice is refused,
counted in `diagRefusedChoices`, and the oldest ready task of the class runs
instead. A policy can still order the tasks of one class, bounded by the
class's quantum. A policy that raises is a host failure and propagates from
the turn before anything changes.

### Service classes, quanta and turns

Every task is `ControlClass`, `OrdinaryClass` or `BackgroundClass`, each with
a finite quantum of segments. The *pass* visits the classes in that order;
each runs at most its quantum before the pass moves on. A *turn*
(`serviceTurn`) runs the pass until it completes, the owner is idle, the
budget has expired or a stop was asked.

The position in the pass and the quantum used persist across turns: a turn
cut at the budget continues the same pass and never replenishes a quantum.
The pass starts afresh when it completes and when nothing is ready.

Under `fifoPolicy` ready tasks of a class run in `Ordinal` order. An `Ordinal`
is issued at admission and whenever a task rejoins the ready set, so a
yielded, woken or resumed task is behind everything already ready. Admission
records a `TaskKind` (looped or one-shot), visible to policies; the runtime
never acts on it. A finished task keeps its slot and result reservation until
`observeTask` takes its result.

### Logical time

The logical tick advances only when the application grants a step with a
positive `Duration` (`grantStep`).

- Accepted grants are applied in acceptance order, one tick each, none skipped
  or coalesced, each only when every earlier one has finished.
- Applying one adds its duration to every task waiting for ticks and wakes
  those whose wait it reaches, in the order their waits began.
- A grant is finished, and its slot in `boundOutstandingGrants` free, when
  every task it woke has stopped being ready or running.
- Answers: `GrantFull` past the bound, `GrantNotPositive` for zero,
  `GrantClosed`; a refusal changes nothing.

A task that waits *n* ticks (`ReportWaitTicks`) wakes at its starting tick
plus *n* and resumes with the tick reached and the duration granted since
(`ResumedLogical`), both fixed when the satisfying grant is applied. A wait
for no ticks, or one whose end tick is not representable, is refused; an
unrepresentable accumulated duration fails that task. Nothing wraps.

`tickQuietBefore scheduler tick` reads the boundary just before a tick: every
earlier tick begun and finished, nothing ready or waiting to start, this tick
not begun. With `holdTick` it is where an owner runs work that must finish
before the tick begins ([placed roots](#placed-roots-lfe-11)).

`awaitStepsComplete` is "every accepted grant is applied and finished"
(`grantComplete` and `stepsOutstanding` read the same without waiting). A
paused task does not hold a grant. **This is the scheduler's progress only**:
it does not say the owner has accounted for an instance ending the work
caused, which `awaitScheduledAccounting` waits for.

### Elapsed time

A task that waits an elapsed duration (`ReportWaitElapsed`) wakes once the
scheduler's monotonic source (`schedClock`, injected in tests) reaches its
deadline and resumes with the elapsed time (`ResumedElapsed`). A deadline that
is not representable, or a wait of no time, is refused. Deadlines are looked
at once at the start of each turn, in deadline order then wait order, so an
elapsed wait is the one thing that changes readiness with real time.

A refused wait fails its task with a recoverable `ValidationFault`, reports
the `WaitRefusal` in the turn report and counts in `diagRefusedWaits`. A task
that fails while its continuation is suspended still owes it a close: made on
the owner's thread after the failure, its own failure kept in the scheduler
and reported by a turn (and by the stop until a turn shows it arrived; at
worst twice). An interrupted obligation is made by the scheduler's stop.

### The timer

One owned registration (`Hetoimasia.Scripting.Lua.Scheduler.Timer`) is armed
for the earliest elapsed deadline, re-armed as it changes, and cancelled when
nothing waits and at stop. Its wake is a flag `awaitWork` composes. Production
uses the threaded runtime's timer manager (`systemTimerBackend`); tests
supply a `TimerBackend`.

**A wake is a prompt to look at the clock, never evidence a deadline passed.**
An early wake re-arms; a stale wake (replaced, cancelled, after stop) is
ignored. Arming, cancelling and disposing run under an uninterruptible mask,
so the backend must not block for long. Registrations are whole microseconds,
rounded up, from one to one hour (`maxRegistration`); a distant deadline is a
chain of wakes. An owner that exits without `stopScheduler` leaves the
registration armed.

### Budgets and overruns

An optional elapsed service budget per turn (`boundServiceBudget`): when the
clock shows it expired as a segment returns, no further segment starts in that
turn, control and stop are served, and the pass continues next turn. A turn
always starts at least one segment. **The budget is a service target, not a
limit**: it never interrupts a segment, never changes what runs next, and
installs no instruction hook. A segment that ends strictly after the turn's
deadline is an overrun, attributed to its owner, task kind and entry point,
for at most `maxOverrunSites` sites (`diagOverrunsUnattributed` beyond).

### Control

`requestControl` asks that a task pause, resume or stop. It never blocks, is
usable from any thread (a binding's action included) and answers, in order of
precedence, `ControlAccepted`, `ControlFull`, `ControlClosed` or
`ControlUnknownTarget` (foreign, stale, ended, never issued, or still
queued). Accepting reserves a result under `boundControlRequests`, held until
the settlement is observed or abandoned through the `ControlTicket`. Every
accepted request settles exactly once: `ControlApplied`,
`ControlAlreadyInState` or `ControlNoLongerApplicable`.

Requests are applied between segments in acceptance order, **stops first**, so
a stop is never undone by a resume and an ended task is never resurrected.

| Request | Effect |
|---|---|
| pause | The task runs no segment and occupies no turn (`PhasePaused`). A task paused while waiting keeps its continuation, its wait and any wake it earns |
| resume | A task whose wait was satisfied while paused joins the tail of its class with the wake it earned; otherwise it returns to waiting |
| stop | Closes the continuation on the owner's thread, once, through `hostClose`, then cancels the task. The close and its record are masked; an interrupted close is retried by the scheduler's stop. A close failure is kept in the settlement (`CloseFailed`) and the turn report |

### Stopping, determinism and diagnostics

`stopScheduler` closes admission, grants and control; closes every live
continuation not inside a segment, once, in identity order; records each
task's disposition in the model's `ExitRecord`; settles every unapplied
request as no longer applicable; discards unfinished grants; and cancels the
timer. A second call answers the first's report. A segment running when its
host failed is recorded as outstanding and not closed. The stop runs masked
and attempts every close; the first interruption is raised again afterwards.

Given the same configuration, policy, admitted tasks, segment outcomes and
grants, the same tasks run in the same order whatever the budget and wherever
a turn is cut. Elapsed waits are the exception.

`readDiagnostics` is a snapshot of bounded counters and gauges: admitted and
rejected work, queue and active high-water marks, outcome counts, segments by
class, overruns by site, refused choices and waits, control and grant counts,
the logical tick. No per-task history.

## The scheduled owner

`Hetoimasia.Scripting.Lua.Scheduled` (in `runtime-lua`) hosts task coroutines
and the scheduling machinery on a supervised worker with a real VM. It adds no
scheduling of its own. All executable work is admitted as tasks. A finite-call
owner and a scheduled owner never run the same VM.

### Creation and readiness

`startScheduledOwner` validates the scheduler configuration first
(`SchedulerRefused` naming every violation), then starts one worker; the VM is
built inside `withVmOwner` on the worker's thread; readiness is awaited
through `awaitSupervised`, masked as for a finite-call owner. An
initialization failure ends creation under the `WorkerPolicy`.

**Creation leaves nothing behind when its wait fails or is abandoned**: it
asks the owner to stop and waits (interruptibly, never under an
uninterruptible mask) for the worker to have ended, then raises what happened
in order, a cancellation as itself and the rest as evidence. A script held in
a module's top level keeps creation pending. So an application may release
what the owner's bindings borrow as soon as creation has returned or raised.

`scheduledOnStartAbandoned` (default: nothing) tells the application earlier:
once, on the creator's thread, when a start that has not handed out an owner
is abandoned, after the worker was asked to stop and **before** the creator
waits for it. **It runs masked: it must be finite and must not wait.** What it
raises is kept as evidence beside the failure of the start and never replaces
it. It is not called when creation returns an owner, when initialization
fails under the policy (`ScheduledUnavailable`, `ScheduledEnded`), or when
the configuration is refused.

### Identity

An owner has the `OwnerId` its `LuaRuntime` issues. A task is a
`ScheduledTaskId`: the owner's identity and a model `TaskId` from a counter
that never rewinds; unique within the runtime, never reissued, never a thread
or coroutine, and granting no authority.

### Admission, settlement and tickets

`admitScheduledTask` (module entry, bounded arguments, class, kind, optional
name) never blocks and answers `TaskAccepted` with identity and ticket,
`TaskQueueFull` or `TaskAdmissionClosed`. Arguments are evaluated, checked and
copied on the producer's thread; over-limit ones settle as the refusal. Every
accepted task settles exactly once:

| Settlement | Meaning |
|---|---|
| `SettledReturned` | the entry point's results |
| `SettledFaulted` | a script fault, as data; never a worker failure |
| `SettledRefused` | the scheduler refused a wait: a recoverable failure of that task |
| `SettledCancelled` | a stop request |
| `SettledDiscarded` | the owner exited first; the exit kind and whether the task had begun |

The first read of a ticket that finds the task finished takes its result and
returns the reservation; later reads answer the same. `forgetTask` returns the
reservation at once or at the owner's next sweep after the task finishes.

A wait from inside a Lua callback is `CallbackWaitRefused`: creation,
`waitTask`, `awaitTask`, `waitControl`, `awaitControl`, `awaitTicksComplete`
and `awaitScheduledAccounting`. `awaitTicksComplete` ends with
`TickOwnerEnded`, never a false completion, when the owner exits with a tick
outstanding.

### Time, control and what a script is told

A script waits through an operation registered with `waitOperation`. Its
first argument, an integer, is the ticks of a `WaitLogical` wait or the
nanoseconds of a `WaitElapsed` one; anything else is refused as a wait for
nothing. A `WaitElapsed` wait past 2^63 − 1 nanoseconds takes **two**
integers, the high and low 32 bits (`waitOperation "wait_wide" WaitElapsed
[SInteger, SInteger]`).

`grantScheduledStep` and `requestTaskControl` are the scheduler's operations
for this owner. `grantScheduledStepSTM` is the same grant as a transaction, so
an application can read its own state and grant in one atomic step. What a
finished wait earned (tick and granted duration, or elapsed time) is told to
the application on the owner's thread before the next segment
(`scheduledObserve`).

`scheduledRefusedWait` is told, on the owner's thread, of each refused wait
at the moment the scheduler applies the report (the owner's answer to
`TaskHost`'s required `hostRefused`). The order of a turn:

1. the segment runs;
2. its report is applied (a refused wait is created here only);
3. the host is told;
4. the budget's overrun is accounted;
5. the continuation the report left is closed (the script's `__close`
   handlers run);
6. the next boundary: instances, providers, the loader and, last, the
   acknowledgement of an accounting wait;
7. another segment is chosen.

What `scheduledRefusedWait` raises is a host failure and leaves the turn
there, with the close still owed to the scheduler's stop.

### Waiting for the owner's accounting

`awaitScheduledAccounting` returns `AccountingComplete` once the owner has
finished the grants it had accepted, ended the boundary at which the last was
found finished, and every instance ending begun by the end of that boundary
has run its `shutdown` (or had it skipped), released and drained what it held,
completed every retirement a provider owes it, settled and, for a failure, had
`instanceEscalate` called **and returned**. An application decides a tick's
commit or a stop's outcome on it; `awaitTicksComplete` can return earlier.

Its parts are transactions for an application that must compose them into its
own single supervised wait: `watchScheduledAccounting` (the snapshot, once),
`scheduledAccountingStep` (retries until `AccountingComplete` or
`AccountingOwnerEnded`), `unwatchScheduledAccounting` (idempotent).

- **Who may call it.** The application thread that owns the `RuntimeControl`,
  one wait pending at a time (see `docs/supervision.md`). A latched fatal
  failure is rethrown and wins over a ready completion. Refused from a Lua
  callback. **Never from the owner's own thread** (an escalation callback).
- **What it captures.** One snapshot of the grants whose `grantScheduledStep`
  had committed when the wait began, kept across retries. Not a grant accepted
  later, nor a boundary after the captured grants' final one.
- **Its cutoff** is the end of that final boundary: every ending begun by
  then is covered whatever began it; nothing begun later is. It does not wait
  for healthy instances' future ticks, idle peers, or an ordinary task's
  fault.
- **What can delay it.** The owner has one thread and nothing is preempted. A
  retirement a provider owes holds the wait for as long as it holds the
  instance's stop completion; **there is no timeout**. Returning is evidence
  about the accounting, not permission to commit a tick that failed.
- **Who decides.** The owner writes an acknowledgement at the end of a
  boundary that finds nothing more to do, if it holds no failure that will end
  it and is not stopping. A boundary cut short by a failure writes none. An
  idle owner is woken to write one; an owner whose covered ending is still
  open is not, so it does not spin.
- **Cost.** No task, control or result slot and no per-wait state; it works
  with every scheduler bound exhausted. Cancelling a wait abandons only that
  wait.
- **When the owner ends.** `AccountingOwnerEnded` once it has ended and
  supervision handled the outcome without latching a fatal failure. An owner
  that is exiting but has not ended neither completes nor ends the wait. An
  `Escalate` answer, a raising escalation callback and a failed retirement end
  the owner as a failure, and the wait follows supervision's severity.

### Idle

An owner whose tasks are all paused or waiting for an ungranted tick or a
future deadline enters no Lua and does no periodic work: it blocks in the
scheduler's one STM wait. A stop request always wakes it.

### Lending a collection

An owner given a `Lending` handle holds a capability-owned resource
collection (`Hetoimasia.Foundation.Resource.OwnedCollection`) on its own
thread around the VM's lifetime and lends it to each synchronous callback for
exactly the callback's duration. (A thread-owned collection cannot serve a
binding: a callback runs on its own thread.) `Hetoimasia.Scripting.Lua.Lending`
is the binding's side: `lentToCallback`, `acquireLent`, `acquireLentThen`,
`withLentMember`, `retireLent`, `liveLentCount`.

**The handle is the only route.** The application makes it with `newLending`,
closes the bindings that use the collection over it, and gives it to one owner
(`scheduledLending`); a second owner is refused with `LendingInUse`. Bindings
that use the collection are therefore built per owner. Members belong to the
owner: one acquired in a callback may be borrowed and retired in a later one,
and what is live at retirement is released then. The foundation collection's
guarantees all hold, with the live-member bound `scheduledMemberLimit`
(default 256; below one is `OwnedInvalidMemberLimit`).

A loan is refused before any effect, and a refusal does not invalidate it:

| Presented | Outcome |
|---|---|
| After the callback returned, including in a later callback of the same VM | `LoanEnded` |
| From a thread the callback started, another VM's callback, or any other thread | `LoanElsewhere` |
| Asking the handle while the owner's VM runs no callback | `NoLoan` |

The check uses the VM's own record of its callback threads, when the loan is
presented. The capability behind a loan is revoked with the callback
(`CapabilityStale`).

The collection is allocated before the VM is constructed and closed after the
VM has closed, so closing handlers and finalizer-eligible bindings still find
it open. Retirement releases what remains, newest first, on the owner's
thread; **a failing release is cleanup evidence, fatal under every policy**.

### Host failures, stop and exit

A Haskell failure from a binding's action, a liveness check, the observer or
anything else escaping the owner ends the worker, unconverted, judged by the
`WorkerPolicy`. A script fault only fails its task.

Stopping (`retireScheduled`, `stopSupervised`, the boundary closing), in
order: closes admission, grants and control; lets a running segment return
(**nothing is preempted; a stuck segment keeps the worker, VM and
dependencies live**); settles every ticket; cancels the timer; discards
unbegun admissions; closes every suspended coroutine on the owner's thread,
each attempted; `withVmOwnerScoped` closes the VM; the owner's collection
releases its live members. The same retirement runs when the owner fails or is
cancelled, the primary failure surviving beside the evidence.

**A cleanup failure is fatal under any policy and ends the owner at once**: a
coroutine whose close raised, or a timer whose cancellation throws. A task's
coroutine is acquired and published masked, and a segment's outcome recorded
masked, so a cancellation queued during a segment lands after it. The
`ExitRecord` names the owner and counts discarded tasks, started and not
started; it carries no cleanup evidence.

### Determinism

On one owner with a fixed policy and configuration, the same admitted tasks,
grants and control requests, each made at the same logical point (while the
owner awaits the next grant), give the same sequence of segments, logical
durations and order of binding effects, however long segments take and whether
budgets expire. Elapsed waits are not covered. A control request arriving
mid-step is not ordered logically here; that is
[Lifecycle services](#lifecycle-services). No claim across policies, worker
counts, platforms or versions.
## Script instances

`Hetoimasia.Scripting.Lua.Instance` (in `runtime-lua`) puts instances on a
scheduled owner. An *instance* is one running copy of a module's behavior:
its own `self`, the module's hooks, functions it connected to events, and a
lifecycle the application controls and reads, following the
[instance contract](../../docs/lua_instance_contract.md). An owner hosts
instances when created with `scheduledInstances` (an `InstanceConfig`). The
hosting modules declare their hooks as optional entry points (`hookEntries`).

### Instances and identity

`admitInstance` answers at once from any thread: `InstanceAccepted` with the
identity and a ticket, `InstanceFull` or `InstanceAdmissionClosed`. The
`InstanceId` is the owner's identity and the owner's number for the instance:
unique within the runtime, never reissued, never a thread or coroutine, and
granting nothing. Live instances (`boundLiveInstances`) and unobserved results
(`boundRetainedInstances`) are bounded; a result is reserved at admission. A
configuration that does not fit the scheduler's bounds is refused before
anything starts (`InstancesRefused`): **the scheduler's retained-result bound
must be at least twice the live instances**, and its admission queue must hold
one invocation for each.

The owner's thread makes `self`, a fresh empty table, before `init`. Module
code is shared by a module's instances: a fresh `self` does not isolate
module globals or upvalues. Ending one instance ends only that instance.

`self` and connected functions stay in a VM table only a driver module the
owner loads can reach, by instance number; a script cannot forge or erase
another instance's state. The layer installs two bindings, both answering only
the instance whose code is running: `hetoimasia_instance.delta` (the `dt` of
the update about to begin) and `hetoimasia_instance.connect` (records a
connection). A script that connects through the binding instead of its `api`
has a connection with no function: the first event for it fails that instance.

### Hooks

| Hook | When | Suspends |
| --- | --- | --- |
| `init(self, api)` | once, as a finite call, before anything else; absent is a successful empty one | no: a wait or yield is a fault of the hook |
| `update(self, dt)` | when a periodic instance's interval makes one due (see [Cadence](#cadence)); `dt` is a float number of seconds. A periodic instance whose module defines none is refused before any hook runs | yes |
| `run(self, api)` | a one-shot's body (`RunOnce`), after `init`. A one-shot whose module defines none is refused | yes |
| callbacks | an event's callback, handed `self` and the event (`source`, `sequence`, `tick`, `payload`) | yes |
| `shutdown(self, reason)` | once, with `"stopped"`, `"completed"` or `"failed"`; optional | no |

`api` carries only what the instance was granted: `api.connect(source,
callback)` for a granted event source (`instanceGrants`), a script error for
any other.

`instanceOnSegment` is told, on the owner's thread just before the Lua runs,
whose segment is about to begin: the initialization (once, with or without an
`init`), the first segment of an update, callback or `run`, every resumed
segment, and `shutdown`. It runs no Lua; what it raises is a host failure and
the hook never runs. It is where an application samples what a script must
read as constant throughout a segment.

### One invocation at a time

An instance has at most one invocation in flight, a suspended one included.
An invocation is a task of the owner's scheduler, ordered by the owner's
policy and the instance's service class. The next invocation is admitted at
the boundary of the segment that ended the last, so the order depends only on
the order of admission.

**An invocation the scheduler had no room for is tried again wherever room
appears, before the next segment is chosen.** Room is a result place, an
admission-queue place and an active slot. At every safe boundary, after the
scheduler's own work, the owner accounts for ended invocations, returns what
forgotten tickets held, and, if room exists, looks at every instance in
number order, what waited for room first. So where a turn is cut changes
neither which invocation takes the room nor the order of effects.

### Events

An owner offers named event sources (`EventSource`: a name and a payload
shape), a seam for tests and the application's own threads, delivered in
arrival order. `deliverEvent` answers at once from any thread:
`DeliveryAccepted` with a sequence, `DeliveryQueueFull`, `DeliveryClosed`,
`DeliveryUnknownTarget` or `DeliveryRefused` (payload over the limits or not
what the source declares). The payload is checked and copied on the
producer's thread and kept, with its sequence and admission tick, until its
callback runs. **No producer thread enters Lua.** A connection made during
`init` accepts events at once; none is dispatched until `init` succeeds, and
if it fails they are counted as unstarted.

Each instance has one bounded FIFO queue of invocations
(`boundInvocationQueue`). A full queue refuses the new delivery
(`snapshotQueueFull`) and never evicts.

### Cadence

An instance is admitted `EventOnly`, `RunOnce` or `Periodic interval`; the
interval is fixed for its life. Neither kind belongs to UI or gameplay.

| Interval | Meaning |
| --- | --- |
| `LogicalTicks n` | a positive number of logical ticks |
| `LogicalDuration d` | the same as a duration: accepted only when `d` is an exact multiple of the owner's `instanceTickDuration` |
| `ElapsedEvery d` | a positive duration on the owner's monotonic source |

A refused interval answers `InstanceIntervalRefused` (`IntervalNotPositive`,
`IntervalUnrepresentable`, `IntervalNotExact`, `IntervalNoTickDuration`) and
takes nothing. Nothing is rounded.

**Logical updates.** Cadence points are every `interval` ticks from the tick
at which `init` succeeded. A point is looked at when its grant is *applied*,
at the safe boundary that follows, before any task that grant woke is chosen.
It makes an update due only if the instance is serving with no invocation
*active* (begun and not finished, suspended included). **A point that finds
an invocation active adds nothing: no catch-up, no backlog.** An invocation
admitted but not begun is queued, and the update falls due behind it. An
instance never has more than one unstarted update.

`dt` is the logical duration granted since the previous update *finished*
(since `init` succeeded, for the first), less any granted while the instance
was paused, from grants alone, converted once to float seconds at the Lua
boundary (the only rounding) and fixed as the update begins. Every granted
tick is accounted once in a `dt`. Example: constant grant `q`, `init` at tick
0, interval 2, a callback that waits through tick 5: the first update is at
tick 6 with `dt = 6q`.

**What a tick waits for.** A tick does not complete (`awaitTicksComplete`)
until a due update has run in it, but only while the update can still run in
it. The update lets go of its tick when its instance is paused, stopped or
ended before it starts; when an invocation queued ahead of it begins and
suspends; when it has begun and stopped being ready or running; or when
nothing at all is ready. Real delay slows the simulation and never skips a
due update.

**Elapsed updates.** Measured on the owner's monotonic source behind the
owner's one timer. At most one refresh is kept unstarted and later demand is
coalesced into it; unlike a logical point, an elapsed point queues its refresh
behind an active invocation. `dt` is the elapsed time between update starts.
Lateness moves the next deadline to the first cadence point strictly in the
future: a stall of ten intervals gives one refresh.

**Pause and resume.** A paused instance accrues no periodic demand. An update
already due and not begun is retained in place, holds no tick, and runs after
the resume. After a resume the first newly due update is one full interval
later, and either `dt` excludes the pause.

**Queue, ending, arithmetic.** A due update takes its place in the instance's
queue when it falls due, is not counted in `boundInvocationQueue` and is never
refused as full (`snapshotUpdateOwed`). Every ending cancels the timer demand,
discards the unstarted update (counted in `terminationUnstarted`) and releases
a held tick. An unrepresentable duration, tick or deadline fails the instance
(`ErrorCadence` at `StageUpdate`); nothing wraps.

### M1 behavior instances (opt-in)

`admitBehaviorInstance` admits an instance of a behavior in an
[export table](#export-modules-and-captured-behaviors) the owner holds. The
`BehaviorRequest` names the export module by identity, the field holding the
behavior, the facade (`BehaviorFacade`: `FacadeData`, `FacadeShared` or
`FacadeBuilder`) and the application's rule resolving the cadence from how
the table's fields read. It has no event grants or connections, is no
one-shot, and takes the same live place and result reservation as any
instance.

When the owner's thread starts the instance, in order, before any hook:

1. find the export module (`retrieveExport`): `ErrorExportMissing`, or
   `ErrorExportFailed` with the module's sticky fault;
2. capture the behavior (`captureBehavior`): `ErrorBehavior` for a table that
   does not fit, `ErrorFault` for a facade past the limits or a failed
   allocation;
3. resolve the cadence: a refusal, an interval that does not resolve, an
   interval with no `update`, or an `update` with no interval is
   `ErrorCadence`;
4. run `init(self, api)` if present; `api` is the facade, the same table as
   `self.api`.

Steps 1 to 3 fail the instance at **`StageConstruct`** with no hook run,
`shutdown` skipped and the capture released. A failing `init` is `StageInit`.

An instance without `update` has no cadence and lives until stopped. One with
`update` is periodic on the resolved interval through the ordinary cadence
machinery. Everything else (one invocation at a time, pause, resume, stop,
`shutdown` reasons, no suspension in `init` and `shutdown`) is the instance
contract.

- **Hooks are captured, not looked up**: later edits to the behavior table
  change nothing an instance does. The legacy driver's `api` (`connect`,
  `subscribe`, `unsubscribe`) is **not** handed to a behavior.
- An `init` entered and then interrupted by a host failure or cancellation
  settles the instance as *started* with `shutdown` skipped.
- The behavior driver is a module of the owner's, counted against
  `maxModules`, and loaded only for an owner that holds export modules
  (`vmExports`). On an owner without one, `admitBehaviorInstance` fails at
  construction with `ModuleNotLoaded`.
- The capture is released whichever way the instance ends, on the owner's
  thread without entering Lua; a failing release is cleanup evidence that ends
  the owner.

### Failure and escalation

A failed `init` fails that instance: no later hook runs, not `shutdown`
either, its connections are revoked and its VM record released. An unhandled
error in `update`, `run` or a callback fails it the same way, except that
`shutdown` runs with `failed`. The `InstanceFailure` names the instance,
owner, source module, phase, stage, error and traceback. **The first failure
recorded is primary and nothing later replaces it**; what else failed while it
ended is in `failureSecondary`. There is no retry.

A required request that settled with an expected failure fails its instance
with `ErrorRequest`, latched when the failure becomes eligible, whether or not
the script read the request, and applied at the owner's next safe boundary
(see [Atomic request admission](#atomic-request-admission)).

One exception to "first recorded is primary": when a running invocation
raises an uncaught script error (`ScriptFailed CallFailed`) and a required
*request's* failure of that instance is already latched, the latched failure
is primary (`ErrorRequest`, stage `request`) and the script's error is a
secondary. So the instance fails with the same attributed failure whichever
of the two the owner reaches first. An uncaught error recorded before the
latch stays primary. An optional request's failure is a result to read.

**The earlier notice.** An ending is *parked* while a provider has yet to
retire something the instance released, and `instanceEscalate` is told only
when it settles. `instanceOnFailing` (default: nothing) is told earlier: on
the owner's thread, once, as an ending *begins* with a failure, before
`shutdown`, the release and the retirements. Its record is the primary
failure alone. A failure that arises only in settling (a raising `shutdown`,
a failed release) goes to `instanceEscalate` alone. What the notice raises is
a host failure. The Lua-first engine's
[session coordinator](../lua-engine/README.md#the-session-coordinator-lfe-13)
uses it.

**Holding an instance after its construction.** `instanceHoldInit` (default:
hold nothing) is asked once per behavior instance, on the owner's thread,
after construction and before `init`. `True` holds the instance there while
the owner goes on to those behind it, so an application can see every
admitted instance validated before any runs, then release each with
`releaseHeldInstance`. What the question raises is a host failure. Every
transition is one transaction:

| State | Event | Result |
| --- | --- | --- |
| not held | the instance is validated | held: the rest of its start is registered **before** the application is asked |
| held | the answer is `False` | the start runs at once; a racing release finds nothing |
| held | `releaseHeldInstance` (any time after registration) | released: one job queued; answers `True` |
| released | `releaseHeldInstance` again | nothing queued; answers `False` |
| released | the job runs on the owner's thread | the start runs, unless the instance has stopped |
| any | the instance settles or its owner is stopped | settles as stopped, `ShutdownSkippedNoInit`, no hook entered; a later release answers `False` |

**Isolation is the default**: the instance ends and its peers run on. The
application is told of each failure on the owner's thread
(`instanceEscalate`), after the instance has ended, and answers `Isolate` or
`Escalate`, which fails the owner as a host failure does
(`InstanceEscalated`). A failure raised by application code is never an
instance's failure: it ends the owner, unconverted. What closing a coroutine
raised is cleanup evidence on the owner's outcome, fatal under any policy, and
stays beside an instance's primary failure. When several instances' ends raise
host failures, the first is the owner's and the rest are cleanup evidence.

### What an ending keeps

An ending is one record, made when it begins and kept until the instance
settles: why it ends, its primary failure, what it revoked and discarded, and
what became of `shutdown`. The hook's disposition is written once: not run
because `init` never succeeded, skipped because Lua was unsafe to enter,
absent, started, or finished. A hook cut short by a host failure settles as
`ShutdownRaised` and is never run again.

Every path that ends an instance settles it through one function,
`settleEnding`. An instance with a failure in its record settles as failed
whatever the owner's exit; one with none settles as discarded when the owner
exited by failure or cancellation or its hook was cut short, and as stopped or
completed otherwise. How the owner exits for its instances is written by one
function, `recordExit`: **the first failure or cancellation recorded wins**,
and a later cancellation, interrupted close or cut-short hook is cleanup
evidence only. The application is told of a failed instance exactly once; an
exiting owner is told too, but its answer is not raised.

### Control

`requestInstanceControl` asks an instance to pause, resume or stop and
answers at once from any thread: `InstanceControlAccepted` with a receipt,
`InstanceControlFull`, `InstanceControlClosed` or `InstanceControlUnknown`. An
accepted request holds a reservation (`boundInstanceControls`) until observed
or abandoned and settles exactly once: applied, already in that state, or no
longer applicable. Requests are applied in acceptance order at the owner's
next safe boundary, never inside a segment, and a request settles as it is
applied, before anything that can raise a host failure. An owner asked to stop
services nothing more. The scheduler's own task controls do not reach an
instance's invocation: they answer unknown.

| Request | Effect |
| --- | --- |
| pause | No new invocation starts; the one in flight is frozen where it is. Accepted events stay queued in order. An invocation not yet begun is taken back, with its event, to start on resume |
| resume | A suspended invocation finishes first, then retained events in order. It does not undo a stop |
| stop | Works while paused and takes precedence. Closes admission, revokes connections, discards and counts what had not begun, closes the in-flight coroutine on the owner's thread without resuming it, then runs `shutdown`. Repeats are safe |

An invocation is owed from the success of `init` until its first segment
begins; any ending counts it once among the unstarted.

Whole-owner control (`retireScheduled`) is distinct: an orderly retirement
stops each live instance with `stopped` before the VM closes. **An owner that
fails or is cancelled does not enter Lua for its instances again**: no
`shutdown` runs (`ShutdownSkippedUnsafe`) and each settles as discarded,
including the instances after one whose `shutdown` raised a host failure.

### Results, inspection and idle

Every accepted instance settles exactly once (`InstanceSettlement`):
completed, stopped, failed or discarded, with its `Termination` (connections
revoked, unstarted invocations discarded, begun invocations closed, the
`shutdown` disposition). A failing `shutdown` is kept, never retried, and
fails an instance that would have completed or stopped. `pollInstance`,
`waitInstance`, `awaitInstance` and `forgetInstance` work as for tasks; an
unobserved ticket keeps its reservation. `inspectInstance` and
`inspectInstances` answer coherent `InstanceSnapshot`s, each read in one
transaction.

Everything the owner does for an instance responds to something, so an owner
whose instances are all paused, waiting or idle enters no Lua.

### Determinism

On one owner with a fixed configuration and policy, the same admitted
instances, grants, delivered events and control requests, each made at the
same logical point, give the same order of invocations and binding effects,
and the same `dt`s, whatever segments cost and whether budgets expire.
Elapsed waits and elapsed-interval updates are excluded. An event to a
connection, or an arrival-admitted request, that arrives mid-step is not
ordered logically; a provider's event is ([Provider events](#provider-events)),
and so is a control admitted logically ([Logical admission](#logical-admission)).
## Instance leases

`Hetoimasia.Scripting.Lua.Lease` (in `runtime-lua`) makes the resources a
binding acquires for a script instance the engine's, over the collection an
owner lends its callbacks ([Lending a collection](#lending-a-collection)).
What an instance acquired is released when it ends, however the script
behaved, and no Lua-written cleanup is ever required. **A binding that needs
the script to clean up after it, whose ownership and retirement cannot be
described, or that exposes a native lifetime for Lua to manage, is not
qualified for this interface.**

### The scope and the lent capability

Each instance has a *scope*, made before its first hook and dissolved when it
settles. It lives in Haskell, in the owner's `Leases` handle, where no Lua
value can reach it. A script holds only *handles*: capabilities whose key
names a lease, checked by the value boundary ([Handles](#handles)).

One owner has one collection, with per-instance bookkeeping over it. A
binding's operations run on its callback's thread through the lent
capability; the drain at an instance's end runs on the owner's thread.
`init` and `shutdown` are callbacks, so a binding can acquire inside both.

```haskell
lending ← newLending
leases  ← newLeases lending 8      -- at most 8 charges for each instance
spec = (scheduledSpec vm worker bounds)
  { scheduledInstances = Just instanceConfig
  , scheduledLending   = Just lending
  , scheduledLeases    = Just leases }
```

An owner is refused before anything starts (`LeasesRefused`, every violation
named) if it hosts no instances, lends no collection, lends through a
different handle, or has a `scheduledMemberLimit` too small for every live
instance at capacity.

### Reserving, acquiring and registering

`acquireOwned` and `acquireShared` do three things in order before returning:

1. **Reserve** one charge of the instance's capacity, before any stage runs.
2. **Acquire** through a staged `Assembly`, with the foundation collection's
   guarantees: a failing stage rolls back the completed stages, registers
   nothing and gives Lua no handle. The constructor's own failure is an
   application failure and ends the owner; an author who wants a recoverable
   refusal returns it as data. A failing rollback release is a cleanup
   failure.
3. **Register** the obligation in the masked step that registered the member.

Only then is there a `Lease` to turn into a handle (`leaseHandle`). A result
that cannot be published leaves the lease registered and drained with the
instance.

### Capacity and its refusal

Capacity is per instance (`newLeases`) and counts every resource held *and*
every released resource whose provider has not yet proved it retired. An
acquisition over it is refused by the engine before any stage runs: a fault
of the call (`BindingRefused`), never a host failure. **The invocation is
faulted even if the script caught the error**, so the instance fails and the
owner goes on.

### Instance versus application leases

- `acquireOwned`: the instance owns what the assembly builds; releasing the
  lease destroys it.
- `acquireShared label take drop`: the instance takes an interest in a
  resource that lives on with its owner; releasing runs `drop` only.

A handle stays owned by the acquiring instance. Caching it elsewhere does not
extend its lifetime: after that instance ends every use is
`RuleRetiredHandle`, and keys are never reissued. Using it from another
instance while its owner lives is `BindingRefused`.

### Using a handle

Declare the type with `leaseCapabilityType`, so the value boundary checks
liveness through `leaseLive` (`leaseLiveSTM` inside a caller's transaction, so
a check and what it authorises are one step). `withLease leases key action` borrows the
resource for the action and is refused for a lease of another type or
instance. `withLeaseOr leases key refused action` hands the same refusal back
as data, so a binding opted in to
[recoverable refusals](#recoverable-refusals) can make it an ordinary Lua
error.

### Early release and its answers

A script may release early through a binding built with `releaseOperation`,
whose action calls `releaseLease`:

| Answer | Meaning |
|---|---|
| `Released` | the first release; the resource is retired |
| `Retiring` | the lease is revoked and the provider's retirement is pending; a repeat answers it again |
| `AlreadyReleased` | the lease ended whole earlier; nothing ran |

A release whose native cleanup failed answers none of them: the failure is
retained on the lease, answers every later release, never reruns the cleanup,
and ends the owner.

### Draining and its failure evidence

On every path by which an instance ends, its remaining holdings are released
on the owner's thread after `shutdown` has run or been skipped, newest
acquisition first, each one's parts in assembly order. Handles stay usable
inside `shutdown`. A failing release does not stop the others. **Draining runs
no Lua**, so it also runs when Lua is unsafe to enter.

A release failure is a cleanup failure:

- it is kept in the settlement (`failureSecondary`, `StageRelease`) beside
  the primary failure, or is the instance's failure when there is none;
- it is cleanup evidence on the owner's outcome: **fatal under every policy**,
  ending the owner at the boundary where it was observed. No queued invocation
  or `init` begins after it, the remaining instances get no `shutdown`, and
  their holdings are drained all the same;
- it is never retried and never reported as reclaimed (`resultLeases` counts
  what the end released, waited for and saw fail).

### Retained retirement

A resource retired by a provider that finishes later does not wait inside the
collection's uninterruptible release. The assembly's release hands the
resource over and records the obligation with `retireAsynchronously
retirements label reading`, where `reading` is an STM transaction answering
`ProviderPending`, `ProviderComplete` or `ProviderFailed`. **A reading only
reads** (what it writes is not kept); a reading that throws is that
retirement failing. The primitive is `Hetoimasia.Scripting.Lua.Retention`
(`pollObligation`, one guard, held disposals), shared with requests and
subscriptions. Every call into provider or application code that retirement
makes goes through the one guard, which answers a failure instead of raising
it; where several arise together the first is raised and the rest kept whole
as cleanup evidence.

- The lease keeps its charge until the provider says it is done.
- The instance's stop completion settles only after its obligations complete;
  until then it is `Stopping`.
- The owner stays live, through a stop and a cancellation, until the provider
  has proved completion.
- A dependency a retirement needs is handed over with `afterRetirement
  disposal`: run once every retirement the lease recorded has completed,
  uninterruptibly on the owner's thread, before the stop completion settles.
  **If a retirement fails the disposal never runs.**
- A failed retirement or disposal is cleanup evidence, fatal, and retained on
  the lease.
- A rolled-back stage whose provider has not finished keeps its charge.

## Lifecycle services

`Hetoimasia.Scripting.Lua.Lifecycle` (in `runtime-lua`) lets a script ask that
an instance pause, resume or stop, and read snapshots of instances, across
owners of one `LuaRuntime`, only where the application grants it.

### Granting

A `LifecycleGrant` (`scheduledLifecycle`) names the owners its scripts may
reach (`GrantedEndpoint` of an earlier owner of the same runtime, or
`GrantedSelf`), what each permits (`PermitInspect`, `PermitControl`) and two
bounds (`grantReceiptBound` 32 and `grantSnapshotBound` 64 by
`lifecycleGrant`). A grant that does not make sense is refused before
anything starts (`LifecycleRefused`, every reason named).

The bindings (`lifecycleBindings`, `lifecycleNamespace`) are registered once
and shared by owners with different grants. Which owner is calling is never
read from the script: each owner's state reaches its bindings through the
host's `LifecycleContext`. An owner with no grant keeps the `NotYetSupported`
fault.

### What a script calls

Identities are plain data: a TID is `{runtime, owner, id}`, an owner
reference `{runtime, owner}` (`instanceIdValue`, `ownerRefValue`). They grant
nothing: a script can forge any number and reaches exactly what its grant
covers.

| Call | Answers |
|---|---|
| `pause(tid)`, `resume(tid)`, `stop(tid)` | `{accepted = true, receipt = n}` or `{accepted = false, refusal = reason}` |
| `result(n)` | `pending`, `applied`, `already_in_state`, `no_longer_applicable` or `unknown_receipt` |
| `forget(n)` | whether the receipt was held |
| `inspect(tid)` | `{ok, refusal?, snapshot?}` |
| `inspect_owner(ref)` | `{ok, refusal?, instances, truncated}`, in identity order |
| `owners()` | `{owners, truncated}` with each label and permits |
| `self()` | the calling instance's TID, or nil |

No call controls an owner as a whole.

### Requests and refusals

A request never blocks, and every refusal is an answer, never a fault.
Refusals are decided **in this order**:

1. `unauthorized`: the owner is outside the grant or the operation is not
   permitted there (nothing is tested of the target), or no instance's code
   and no task's segment is running;
2. `unassigned` (logical targets): the application gave the request no place;
3. `full`: the caller holds as many receipts as its grant allows;
4. `closed`: the target's owner is stopping or has exited;
5. `unknown_target`: no live instance has the identity;
6. `late` and `duplicate` (logical targets): the tick has begun; the place is
   taken;
7. `full`: the target's owner holds every result reservation it may.

Inspection is refused as `unauthorized`, `closed`, `unknown_target`, in that
order. Routing is by identity, never by label. An accepted request reserves
its result at the target and its receipt at the caller in one transaction.

### Receipts

An accepted request settles exactly once: `applied`, `already_in_state` or
`no_longer_applicable`. A receipt is held until read once settled (reading
consumes it), forgotten, or abandoned when the instance or task that made it
ends or the caller's owner exits. Only the maker reads its receipt.
Abandoning interest never undoes an accepted request.

An instance may ask for its own control; it is applied at the target's next
safe boundary, not inside the asking segment.

### Inspection

`inspect` and `inspect_owner` each read one transaction. A snapshot holds the
TID, the owner's label, the name and the status (`initializing`, `active`,
`paused`, `stopping`, `completed`, `stopped`, `failed`). A list over the
grant's snapshot bound or the owner's value limits is cut and says
`truncated`; it never faults.

### Logical admission

An owner configured with `instanceControlAdmission = AdmitLogically` admits
controls made through a grant by the tick and sequence the application
assigns: the grant's `AssignControl` is called for every request that passes
the grant and answers a `ControlSlot` or declines. The request is applied at
the logical boundary of its tick, before that tick's ordinary work and
cadence point, in (tick, sequence) order whatever the arrival order. The
scheduler holds the grant that reaches such a tick until the tick's controls
are applied. A pause and resume assigned to a tick invalidate a cadence point
due at it. A place stays taken until its tick begins whatever became of the
request. The application's own `requestInstanceControl` is admitted on
arrival; `requestInstanceControlAt` takes a place.

The same tick-assigned requests give the same sequence of controls however
the requesting threads interleave.

## Asynchronous requests

`Hetoimasia.Scripting.Lua.Provider` and `Hetoimasia.Scripting.Lua.Request`
(in `runtime-lua`) let a script ask for something an engine operation answers
later, without blocking its owner and without a provider's thread entering
Lua. A bounded single-assignment result slot is reserved before a request is
accepted; a response fills it without waiting on a queue; every admitted
request settles exactly once (result, failure or cancellation); a duplicate,
late or stale reply cannot overwrite it. **Cancelling revokes interest and is
not proof that native work ended.**

### Granting the service

`scheduledRequests ∷ Maybe RequestGrant` names the providers' endpoints
(`RequestEndpoint`: a name, the answer's schema, how a request is handed
over), the bound on requests held, and the `RequestTiming`. An owner with no
grant keeps `NotYetSupported`. A grant that does not make sense (a bound
below one, no endpoint, a bad or repeated name, a result schema naming a
capability, value limits too small for the smallest failure record:
`SettlementsDoNotFit`) is refused as `RequestGrantRefused`. The binding's
action is handed the owner's own `RequestContext`
(`asynchronousNativeRequestIn`).

### What a provider implements

`endpointSubmit` is handed a `Submission`: bounded argument copies, a
`Completion` and the `RequestInfo` (owner, instance, endpoint, request
number). It answers a `ProviderWork`: `workCancel` (how the engine withdraws
interest) and `workRetirement` (a transaction that **must not retry and only
reads**). The provider answers through the `Completion`, from any thread:
`ProviderResult` or `ProviderFailure`. Completing is one transaction that
never waits for the owner, a queue or Lua. The `ReplyAnswer` says what became
of the reply: settled, held for its tick, refused for size or shape, late, or
unknown. None is an error; a duplicate, late or stale reply is counted,
overwrites nothing and still retires the provider's work.

`submissionSettled` is a read-only, non-blocking transaction saying whether
the request has settled or is gone. It exists for a provider whose accepted
resource reply (`ReplyAdoption`) ends its work at once: one that offered a
resource and finds the request settled without adoption retires what it
holds.

A reply is bounded before it is retained, measured as the record a script
will be handed. A result over the limits or not of the endpoint's shape
settles the request as a failure, its value never kept. A failure reason is
bounded the same way. Taking a settlement retires its handle, so one is never
lost to a fault.

### What a script sees

A binding's author starts a request with `startRequest` and returns the
handle as a capability (`requestHandleValue`, type from `requestHandleType`).
`requestBindings` supplies the generic operations:

| Call | Effect |
|---|---|
| `ready(h)` | whether the request has settled, without blocking |
| `take(h)` | the settlement, once: `{status, value, reason}` with `"result"`, `"failure"` or `"cancelled"` (or `"pending"`, taking nothing); retires the handle |
| `cancel(h)` | settles as cancelled, or answers `"settled"` if it settled first |
| `wait(h)` | gives control back until the request has settled; a hook fault in `init` or `shutdown` |

A handle carries no authority: another requester's, a taken one and one that
names nothing are refused as a fault of the call.

### Admission and the reserved place

`startRequest` never blocks and is allowed in any invocation of an instance
that is taking requests (`init` included) and from a task's segment. It
reserves the request's place before the provider is asked anything, and the
place is held until the settlement has been taken or discarded **and** the
provider has proved its work over.

Refused as a fault of the call, the provider asked nothing, in this order: no
instance or task is running; the owner or instance is no longer taking
requests (stopping, which `shutdown` and closing handlers already are); the
assignment declined; the assigned tick has begun; the assigned place is
taken; every place is held. An endpoint the grant does not name is a host
failure.

### Whose a request is

An instance owns its requests, not the invocation that admitted them: they
survive until taken, cancelled or the instance ends. A task that is no
instance's invocation owns its own, revoked at the first safe boundary after
it ends. When an instance ends each request settles once as cancelled, the
providers are told once, and the instance's settlement **waits** for them to
prove their work over. An owner's exit does the same and stays live until
each has.

### Settling on arrival, and at an assigned tick

**`SettleOnArrival`** (elapsed time): a reply settles the request when it
arrives, the first settlement wins, and the waiting script resumes at the
next safe boundary. A cancel that finds it settled is counted
(`rdLateCancels`). A settlement for a paused instance is retained without
resuming Lua.

**`SettleAtAssignedTick`** (logical time): the application's `AssignRequest`
assigns the due tick (default the next) and the place among requests due
then, or declines. A begun tick is refused as late, a taken place as a
duplicate. Then:

- a reply arriving *before* the due tick is a **held completion**, invisible
  to the script, until the place is served at its tick's boundary. The first
  is kept; later ones are counted (`rdDuplicateHeld`);
- **the tick does not begin until the request is complete**: the scheduler
  holds the grant that would reach it (`holdTick`). A provider that never
  answers stalls the owner at that tick until a stop or failure ends the
  request;
- **a cancel before the due tick always wins**, with the same recorded
  effects whether the reply arrived before or after it;
- otherwise the request settles at its tick, in place order, and waiting
  tasks are woken in that order.

The owner keeps one watch on a tick, shared with tick-assigned controls and
cadence points: each is served at its tick's boundary, controls first. No
ordinary work for the due tick begins while a required completion is pending.

### Cancellation and the provider's lifetime

Cancellation (a script's, the requester's end, an epoch change, the owner's
stop) settles the waiter `Cancelled`. Outstanding provider work is a retained
retirement obligation under the same `Retention` primitive as leases, charged
to the request bound until the provider proves it over by replying or by
`workRetirement`. A binding's `afterCompletion` (what the work needed) is
disposed on the owner's thread, uninterruptibly, only after that, and never if
the retirement failed. The provider is told once that interest was withdrawn;
one that had already finished is not asked to stop.

### Epochs

`advanceRequestEpoch` replaces the generation of an owner's records. Every
outstanding request settles once as cancelled by the epoch change (a
cancellation nobody took still holds its place); a settled result nobody took
is discarded; held ticks are released; providers are told at the owner's next
boundary. Accounting for unfinished work stays under its old identities, so a
late reply retires it without reaching the new epoch. Instances and tasks are
not invalidated.

### The guard, and what a failure is

Every call into provider code goes through one guard (`guarded`) and is fully
evaluated inside it.

| What happens | It is |
|---|---|
| a provider reports a failure | a reply: the request settles as a failure, as data |
| provider code raises when the engine calls it (handoff, withdrawal, assignment) | a host failure under the `WorkerPolicy`; a request whose handoff raised is taken back as never admitted |
| a retirement fails, or the disposal of what the work needed raises | a cleanup failure: retained, never retried, fatal under every policy |

### Determinism

On one logical owner, identical admissions with their assigned ticks, cancels
at logical points and grants give identical settlements, settlement order and
recorded effects however provider delays and arrival order vary. When a
dependency is disposed follows the provider, not logical time, and no script
can see it.
## Atomic request admission

`Hetoimasia.Scripting.Lua.Admission` (in `runtime-lua`) is the other way to
start a request, and the only way a full bank is an answer and not a refusal.
It is **opt-in, per request**: a binding's author calls `startAdmitted` with
an `Admission`. The generic `startRequest`, `requestBindings` and their
full-capacity refusal are unchanged. The profile's limits and the M1 records
are [`hetoimasia-lua-engine`'s](../lua-engine/README.md#the-m1-request-adapter),
which passes them in.

### What asking reserves

`startAdmitted` takes one transaction (`admitOptIn`) and only after it commits
asks the provider anything. In it, in this order:

| Bank | Owner of the count | Full is |
| --- | --- | --- |
| Request record and terminal-result storage | the protocol model's session | busy (`BankOwnerRequests`) |
| Accepted, unretired requests of the instance | the service's ledger (`pHeld`) | busy (`BankInstanceRequests`) |
| Accepted, unretired requests of the VM | the same ledger | busy (`BankVmRequests`) |
| The owner's places (the grant's bound): the ledger, the model's outstanding requests and untaken cancelled results of generic requests, each request once (`ownerPlaces`) | the same ledger | busy (`BankOwnerRequests`) |
| A result lease | `Leases`: a slot in `SlotConstructing` with the key the handle will have | busy (`BankLeases`) |
| Provider credits | the provider's own STM variables, each `Credit`'s `creditReserve` in declared order | busy (`BankCredit`), or final for `CreditRefused` |
| The due position (logical time) | the scheduler's tick: `DueSlot (tick + offset) (request number)` and the owner's hold on that tick | permanent refusal |

A bank without room, or a permanent fact, raises inside the transaction and
`catchSTM` undoes everything reserved before it: **no handle, hold, credit,
lease slot or counter is left**, the provider was asked nothing, and the
instance has no latent failure. Nothing queries capacity and then uses it, and
no retry is queued.

The order of decisions is the contract: the owner or requester is not taking
requests; the requester is a task; the request numbers are exhausted; an
offset on an owner on arrival; a non-positive offset; a tick and offset past
the ceiling; a position that has begun; then the banks in table order. One
exception: a credit that can **never** be had (`CreditRefused`) is asked
first, so a full temporary bank is never the answer to a request waiting
cannot help. A credit that retries is treated as full (`orElse`), so a
provider's bank can never make admission wait.

| What | Answer |
| --- | --- |
| A temporary bank is full | `Unavailable bank`: data. The binding hands the script `nil, {code="busy", message=TEXT}`. Never an error or an instance failure |
| A credit full **for good** (`creditReserve` raises `CreditRefused why` with `throwSTM`) | final, not a fault: `startAdmitted` raises `OrdinaryCallRefusal`. An opted-in binding ([recoverable refusals](#recoverable-refusals)) shows `binding: request refused: WHY` (256 bytes of UTF-8, cut between characters); otherwise a fault of the call |
| A permanent fact (wrong requester, closing, offset, ceiling, exhausted numbers, no lease scope) | `RequestRefusal`, a fault of the call before anything was reserved. For an ordinary Lua error, ask `preflightAdmission` in a `withArgumentCheck` |
| The engine cannot keep its bookkeeping consistent (`AdmissionDefect`) | a host failure; nothing reserved |
| A bank, provider or assignment raises | the application's own failure; nothing reserved. A provider that raises when handed the request is taken back whole |

### When a bank comes back

The ledger holds one entry per accepted request from its admission until its
result has been taken or discarded **and** its provider's work has been reaped
as retired. Losing the Lua reference, waiting, cancelling and the provider's
reply do none of that alone. **The entry is written only by the admission and
by transactions on the owner's thread, never by a provider's completion**, so
credits a native thread frees reach a logical owner's admission only at an
accounted boundary.

| Event | What becomes visible to admission, and when |
| --- | --- |
| Take of a terminal result, work already reaped (`takeTerminal`) | the places and credits, immediately: the next ask of the same call sees them |
| Take of a terminal result, work still running | nothing; the entry stays charged |
| The provider proves its work over | at the owner's next boundary (`sweepWorks`, `reapWorks`, `releaseSettled`) and not before |
| The requester ends; an epoch change; the owner's exit | uncollected requests are discarded; entries leave as their work is reaped. A resource built for an untaken result is queued for release (`pDiscards`) |
| A resource whose building failed while a stage is still retiring | nothing while the lease slot exists (`heldRetiring`) |
| A resource whose building failed and whose rollback release raised | nothing, ever: the slot stays failed with its charge |
| An admission taken back (`withdrawAdmission`) | everything at once: credits returned `CreditUnused`, the lease discharged |
| A retirement that fails | nothing, ever; the failure is cleanup evidence |
| A credit release that raises | the other credits and the place come back; the failure is cleanup evidence (`serviceProvider`) |

A `Credit` is returned once, with `CreditUnused` or `CreditSettled`, except
one that `creditTransfers` and whose request succeeded with a resource: that
credit is the resource's, returned by the provider's own release of it. A
reserved lease nothing will use is discharged once the work is retired and the
request settled. `rdHeld`, `rdHeldBy` and `rdBusy` read the ledger.

### The reply, the resource and the defect

A request admitted this way has its reply judged by `checkReplyFor`,
evaluated to its constructor inside the guard on the provider's thread:

- a `ProviderResult` is checked against the owner's value limits, the
  endpoint's schema and the admission's ceilings, measured as the record the
  script will be handed;
- a `ProviderExpected` failure must carry a code the admission lists, a root
  and path within their byte bound, and an envelope that fits; a message is
  cut visibly (`...`) until it does;
- a `ProviderResource value recipe` is a result whose resource the instance
  will own: the owner builds the recipe into the reserved lease on its own
  thread at its next boundary (`adoptReserved`) and only then holds or
  settles the result. A cancel that comes first drops an unclaimed recipe; one
  that comes during the build finds the resource built and the owner releases
  it at once; a recipe that raises rolls back and is an application failure;
- anything else (a `ProviderFailure` with no code, an undeclared code, a
  result over the ceilings or of another shape) is a **provider defect**,
  `ReplyDefective`: never a failure of the request and never retained. It is
  recorded (at most sixteen), the work is proved over, the request stays
  unsettled, and the owner raises it as a host failure (`ProviderDefect`) at
  its next boundary, for required and optional requests alike. The generic
  path keeps settling a malformed reply as a `ValidationFault` failure.

### Timing

On logical time the position is fixed once, inside the admission, from
engine-owned values: the tick is 0 for an instance whose `init` is running and
the owner's current tick otherwise, the offset is the admission's (default 1),
and the sequence is the request number the same transaction issues. Tick plus
offset and the request number are checked against `admitLogicalMaximum`
(2^63 − 1 for M1) before acceptance. Numbers never wrap or repeat.
`AssignRequest` is not consulted, so there is no read-then-admit gap. A reply
before its position is held and invisible; a late one holds the tick; a cancel
before the position wins. An owner on elapsed time takes no offset.
`RequestInfo` carries `infoNecessity`, `infoSource`, `infoOffset` and
`infoDue` to the provider. `skipRequestNumbers` advances the counter for
qualification.

### Required failure

An expected failure of a `RequiredRequest` becomes eligible when it settles
(at the reply on arrival; at the position's tick on logical time). The
requester's cell then gets `isRequestFailure`, and the owner fails the
instance with `ErrorRequest` at its next safe boundary, before any more of its
ordinary work. **Nothing a script does afterwards touches the latch**:
reading, not reading, a caught error, a late `cancel` (`already_settled`). A
cancel that won before eligibility prevents it. `OptionalRequest` leaves the
failure a result for the script.

### Handles and phases

`admittedHandleType` (over the `RequestHandles` given with
`scheduledRequestHandles`, which serves exactly one owner) declares the handle
type: a handle is live for the instance that holds it while its request
exists. `callerPhase` tells a precondition whether an instance is
initializing, serving or ending. `callerInstance` tells a binding which
instance's code is running (`Nothing` for a module's top level or a task): the
engine's reading, never a script's claim.

### Owners, threads and lifetimes of what this adds

| State | Written by | Lifetime |
| --- | --- | --- |
| `pHeld` (the ledger) | the admission; the owner's thread; never a provider | admission until taken or discarded and the work reaped |
| `pAdopting` | a provider's reply (insert); the owner (claim, finish) | until built, failed or the request ends |
| `pDiscards` | `cancelOf`, the epoch | until released at the owner's boundary |
| `pDefects`, `pCleanup` | a provider's reply; a credit release that raised | until raised or kept as evidence; at most sixteen each |
| `isRequestFailure` | the settlement that made a failure eligible | until the instance is ending; applied once |
| `RequestHandles` | the owner binds it | with the owner |

### The settlement seam and the declining hand-off (TRA-5)

Two opt-in mechanisms for a provider whose request carries a change it
commits, or whose own admission cannot run inside the engine's transaction.
Both apply only to requests admitted through an `Admission`.

**`submissionSettling ∷ Maybe Settling`** arbitrates between the provider's
commit and the request's own end in one transaction. (`completeRequest` cannot:
a cancel can win between the provider's commit and its reply.)

| Operation | Meaning |
| --- | --- |
| `settlingEligible` (STM, read only) | the request still waits for its answer, the owner takes answers, and on logical time **its assigned tick has been granted and waits unbegun at the boundary** (`ticksGranted`) **and no earlier place of that tick still waits** (so requests commit in assigned order). A cancelled, ended, epoch-replaced or exit-taken request is not eligible |
| `settlingSettle reply` (STM) | judges the reply purely (`checkReplyPure`, the verdicts of `completeRequest`) and applies it: an eligible request settles now and returns its tick's hold; one not yet eligible is held for its position. An undeclared reply is recorded as a defect and settles nothing. `settlingPrepare` / `settlePrepared` split the judgement from the application |
| `settlingJudge reply` (pure) | whether the host would take this reply. **Call it before committing**, on the largest reply possible: a reply rejected inside the committing transaction can only abandon that transaction |
| `settlingSettleFinal final reply` (STM) | for a resource reply: `final` is read in the transaction that settles the request once the owner has built the resource, and decides whether the success settles or an expected failure does (the built resource is then released) |
| `settlingSettleKeeping reply` (STM) | settles the request but does **not** prove the provider's work over (it still holds something borrowed); the places return only when the provider reports completion. Not for a resource reply |
| `settlingCancel` (STM) | the provider ended its own interest: the request settles as cancelled, unless already settled |

`preflightDeliverable context admission schema reply` is the same judgement
for a binding's precondition, reserving nothing.

A request settled by the seam on logical time stays hidden from its waiters
until its tick serves it, in place order. A resource reply through the seam
does not prove the work over: a request that ends first still gets
`workCancel`. A reply arriving while a resource reply waits to be built is a
duplicate.

**`SubmissionDeclined`** (`DeclinedBusy bank` or `DeclinedRefused why`) is
what a provider raises from `endpointSubmit` to decline a request **before it
has changed anything**. The admission is taken back whole and the call is
answered as busy data or as the ordinary permanent refusal. Anything else
raised from the hand-off is a host failure.

## Provider events

`Hetoimasia.Scripting.Lua.Provider` (in `runtime-lua`) lets an instance
subscribe a function to events a provider delivers. A subscription is an owned
record with bounded delivery, unsubscribe and invalidation. **A producer never
invokes a Lua closure on its own thread**; the owner looks up the still-live
callback when it services an event. Overload is stated per endpoint. It reuses
the granted service, guard, epoch operation and retained-obligation primitive
of [Asynchronous requests](#asynchronous-requests).

### Granting the subscriptions

An owner granted the request service that hosts instances can be granted
`scheduledSubscriptions ∷ Maybe SubscriptionGrant`: the event endpoints
(`EventEndpoint`: a name, the delivery schema, an `OverloadPolicy`, how a
subscription is handed over), the bound on subscriptions, and the bound on
events held for unreached ticks. An instance's `api` can subscribe only to an
endpoint the grant names **and** `instanceGrants` granted it. A grant that
does not make sense is refused as `SubscriptionGrantRefused`. The owner's kind
of time is the request grant's `RequestTiming`.

### What a provider implements

`eventSubscribe` is handed an `EventSubscription` (an `EventFeed` and the
`SubscriptionInfo`) and answers a `ProviderWork` (`workCancel`, called once;
`workRetirement`, which must not retry). It delivers through the feed from
any thread:

- `feedDeliver place value` never blocks. On elapsed time the place is
  `Nothing` and the value is admitted on arrival. On logical time the
  application assigns `Just (DueSlot tick sequence)` and the delivery is held
  until that tick's boundary.
- `feedFail reason` says the provider cannot preserve an authoritative event:
  the instance fails with `ErrorDelivery`, once.

The `EventAnswer` is never an error: `EventAdmitted`, `EventCoalesced`,
`EventStaged`, `EventQueueFull`, `EventStagingFull`, `EventEnded`,
`EventRefusedValue`, `EventLate`, `EventDuplicate`, `EventUnassigned`,
`EventNotLogical`. A refusal is counted and the value not kept. A delivery is
checked, copied to its own buffers and fully evaluated inside the guard,
measured as what the callback's entry point is handed; a value that throws
when first looked at is a refused delivery. A `feedFail` reason is bounded at
512 characters.

### What a script sees

`api.subscribe(endpoint, callback)` answers a handle; `api.unsubscribe(handle)`
answers whether it ended a live subscription. A callback is handed `self` and
`{source, sequence, tick, subscription, payload}`. Subscribing is allowed in
`init` and any invocation of an instance taking subscriptions. It is refused
as a fault of the call, the provider asked nothing, when the instance is
stopping, the endpoint is not granted, or every place is held. A provider that
raises when handed a subscription is a host failure and the subscription is
taken back.

### Whose a subscription is, and where deliveries wait

An instance owns its subscriptions until it unsubscribes, an epoch changes or
it ends. A delivery takes a place in the instance's one bounded invocation
queue as a *reference*; the payload stays in the model's record until the
callback's first segment is about to run. A paused instance's deliveries are
retained in order.

- **Ordered events** take a place of their own and are refused, counted and
  never evicted when the queue is full. A provider whose event is
  authoritative surfaces that with `feedFail`.
- **Replaceable state** keeps at most one unstarted delivery per
  subscription. A later value replaces its payload and tick *in place*; the
  replaced value is counted as coalesced. Filling an empty slot needs a queue
  place; replacing needs none. Once the callback's first segment begins the
  payload is immutable.
- A delivery to an ended subscription, or to a stopping instance, is
  `EventEnded`. One accepted and not begun when its subscription ends is
  discarded.

### Logical event admission

On logical time, events are admitted by assigned tick and sequence, never in
arrival order. A placed delivery is held in a store bounded by
`grantStagingBound` (`EventStagingFull`), keyed by its place (`EventDuplicate`
for a taken place, `EventLate` for a begun tick, `EventUnassigned` for none).
The owner asks to be held at the earliest tick it holds an event for.

At that boundary, after the tick's controls and before any task the tick
woke, the owner admits the due events in place order through the one function
that applies the queue bound and the overload policy. So which input is
accepted and which value a callback sees follow the logical sequence. An
ordered event that cannot be admitted at its tick is surfaced as a delivery
failure, as `feedFail` is; a refused fill of replaceable state is counted
only.

**The tick's claim.** An applied tick is held for as long as any instance has
an admitted, unfinished delivery **and** can make progress in that tick
(serving, with the invocation in flight ready, or nothing in flight and
something ready). An instance suspended on a wait, paused, stopping, ended or
initializing does not hold it. The claim is computed in one place from the
instances' state as it is, never from a flag set at admission. So queued
grants give the same admissions and effects as grants served one at a time.

### Epochs

`advanceRequestEpoch` also invalidates every subscription: each ends once, its
held events and unstarted deliveries are discarded and counted, and providers
are told at the owner's next boundary. A late delivery from an old producer
finds nothing (an identity carries its epoch and a never-reissued
generation). Places stay charged until the providers prove retirement.
Instances are not invalidated, and the owner has the driver drop the
callbacks of ended subscriptions, so repeated cycles do not grow the VM.

### Retirement and the bound

Outstanding provider work is a retained retirement obligation charged to the
subscription's place until the provider proves it over, so subscribing and
unsubscribing in a loop cannot reclaim capacity. An instance's settlement and
the owner's exit wait for the providers.

### The guard, and what a failure is

Every call into provider code goes through the one guard. Provider code
raising when the engine calls it is a host failure under the `WorkerPolicy`;
a failing retirement is a cleanup failure, fatal under every policy; a
provider that cannot preserve an authoritative event fails the instance.

### Determinism

On one logical owner, identical events with their assigned ticks and places,
and identical grants, give identical admission order and recorded effects
however arrivals, grant pacing and segment delays vary.
## The script runner

`Hetoimasia.Scripting.Lua.Runner` (in `runtime-lua`) runs a list of scripts,
each a file, as instances of one named VM, on the elapsed clock or on logical
ticks it grants at a real-time rate, publishes an event when an instance
starts and ends, and answers a bounded report: `runScripts ∷ LuaRuntime →
RunnerConfig → IO RunOutcome`. It is the layer under the `lua` subcommand and
a windowed application alike. It parses no arguments, installs no signal
handler, never calls `exit` and opens no window: what the outside world does
is injected.

### What a run is given

`RunnerConfig` holds the VM's name (`runnerName`), the scripts
(`runnerScripts`), an optional duration limit (`runnerLimit`), an optional
tick duration (`runnerTick`) with an optional tick limit (`runnerTickLimit`),
the stop request (`runnerStop ∷ STM Bool`, waited on, never polled), the
clock and timer backend (`runnerClock`, `runnerTimer`), the output and error
sinks (`runnerOutput`, `runnerErrors ∷ Text → IO ()`) and a `Logger`.
`runnerConfig` supplies the production clock and timer. A `Script` is a path,
an optional name (default: the path's last component) and an optional
interval: an elapsed duration, or on a tick VM a whole number of ticks
(`everyTicks n (script path)`).

A run admits at most `runnerMaxScripts` (64) scripts, under the runner's own
`runnerSchedulerBounds` and `runnerInstanceBounds`.

### Loading

The runner reads each *distinct* path once, in order (distinct by its text;
nothing is resolved), bounded by the host's source limit, and hands the bytes
to the host as a module. A path named twice is loaded once and admitted
twice. A module's identity is its place among the distinct paths, a colon and
the end of its path, cut to the host's 128-byte rule.

A missing, unreadable or over-bound file, or a module the host rejects, is a
*source that did not load*. **It fails the VM's start, not an instance**: the
run ends with `EndedStartupFailure` and a `LoadFailure` (the first in script
order), no instance is admitted, no hook runs, the VM is retired, and the
status is failure. The top level of the modules before it has run.

### The kind of an instance

`moduleHooks` (in `Hetoimasia.Scripting.Lua.Instance`) answers which of
`init`, `update`, `shutdown` and `run` each loaded module defines, read once
before readiness, running none of its code. A module defining `run` is a
one-shot, one defining `update` is looped on the script's interval, one
defining neither is event-only.

Refused as usage, before any instance is admitted, as the distinct result
`Refused (UsageRefusal reasons)`: both `run` and `update`; `update` with no
interval; an interval without `update`; no scripts; too many scripts; a zero
interval or limit; `TickDurationNotPositive`; `ElapsedIntervalOnTickClock`;
`TickIntervalOnElapsedClock`; `TickLimitNeedsTickClock`;
`TickCountNotPositive`; `TickCountTooLarge`. A VM started to ask is retired.

### The VM

It opens the base, string, table, math and coroutine libraries; `io`, `os`,
`package` and `debug` stay closed. The policy is `fifo`. Every instance's
failure is isolated. The lifecycle bindings are registered as `lifecycle`
(`runnerLifecycleName`), and the owner is granted every control and
inspection permit over its own instances only, so one script can pause,
resume, stop and inspect another and itself. **Scripts are trusted: nothing
here is a sandbox.**

### Admission

Scripts are admitted one at a time, in listed order, each only after the
previous instance's `init` has finished or failed and every instance is quiet
(nothing initializing, stopping, ready or running; no event queued, update
owed or `run` pending; a paused or wait-suspended instance is quiet). So TIDs
ascend in script order and `init`s run in script order on both clocks. A
failed `init` does not stop later admissions. A stop request, the duration
limit or the owner's exit during admission admits nothing further. While an
instance is admitted the owner is held, before its next segment, at a gate
the runner installs as the segment observer; the *started* event is produced
while it is held, so the owner is never ahead of the runner's coordination.

### The tick clock

With `runnerTick = Just d` the VM is a *tick VM*: it admits Lua controls
logically, takes events at assigned ticks, and looped intervals are in ticks.
Tick *n* is due *n* tick durations after the instant read when admission
completes. The timer's wake only says to look at the clock. **A late tick is
granted at once, one grant each: none is skipped, merged or shortened.** A
grant answered full is waited out and asked again; closed ends the run as a
stop request does. After a grant the driver waits for the engine to have
finished it *and* for every instance to be quiet, then produces the ends it
saw.

A **tick limit** ends the run when *n* ticks have completed, as a duration
limit does. A tick in progress when a stop arrives is not counted. The
runner assigns every script-requested control the first tick the owner has
not begun and an increasing sequence, and never declines.

**Determinism.** On a tick VM, identical scripts, intervals, tick duration and
configuration on the same build and platform give the same output, events,
order of controls, tables and report however segments and threads are paced,
provided no duration limit is set and no external stop arrives. Compare TIDs
by an instance's order in the run. Elapsed waits keep wall-clock semantics.

### The instance events

Every instance is granted one ordered-events endpoint, `instances`
(`runnerEventsName`): `api.subscribe("instances", callback)`. The payload is
a record: `event` (`"started"` or `"ended"`), `tid` (the lifecycle
namespace's `{runtime, owner, id}`), `name`, and on an end `outcome`
(`"completed"`, `"stopped"`, `"failed"`). Bounds: `runnerSubscriptionBound`
256, `runnerStagingBound` 1024.

- *Started* is produced when `init` has succeeded, while the owner is held.
  A failed `init` produces only *ended* with `failed`.
- Ends seen during admission are produced after every *started*; on a tick VM,
  ends seen during a tick are produced at its boundary; on an elapsed VM, when
  the run sees them. Events produced together are in ascending TID order.
- An event reaches only the subscriptions that exist when it is produced;
  nothing is replayed. It is delivered once per subscription, in subscription
  number order.
- No event is produced once the orderly stop has begun.

Every delivery answer is classified by one pure function (`classifyAnswer`):

| Answer | Treatment |
| --- | --- |
| admitted, staged | delivered |
| `EventQueueFull`, `EventStagingFull` when offered | counted in the report; nothing evicted, retried or failed |
| a staged delivery that finds its subscriber's queue full at its tick | fails that watcher with the delivery error; the run's status is failure |
| subscription ended | counted, benign |
| late, duplicate, unassigned, not logical, refused value, coalesced | a runner defect: raised as a host failure |

### Output and the stream rules

Before any module loads, `print` and `warn` are rebound to bindings that
write through Haskell, and the originals are unreachable. `print` joins the
`tostring` of its arguments with tabs and writes to the **output sink**;
`warn` writes `Lua warning: ` plus the same to the **error sink**. One call
writes at most `outputCallLimit` (4096) bytes of UTF-8, cut with a visible
`...` counted in the bound. Any Lua string is accepted: decoded as UTF-8 with
invalid sequences replaced, split at line breaks, control characters (NUL
included, tab excepted) replaced by `\xNN`.

The bounding and escaping are `Hetoimasia.Scripting.Lua.Output`
(`authoredLines prefix bytes`, `authoredLinesWith limit`,
`renderFunctionLines`), shared with the Lua-first engine's facade. With a
prefix, every line begins with the whole prefix, the cut line included. Below
`minimumOutputLimit` (4 bytes) nothing is written.

Rules for every write: a sink gets one line at a time with no line break and
no control character but a tab; every text a script can influence is escaped
and cut to a documented bound; the runner holds one lock around each table,
report or call. The tables go to the output sink; the source-did-not-load
report and every instance failure report go to the error sink. The runner's
own diagnostics go to the logger under `scripting.lua.runner`.

### The table

At the start and end the runner writes a title line (`instances at start`,
`instances at end`), the header `TID OWNER NAME STATUS` and a row per
instance, ended ones included, in ascending TID order. A TID's text
(`tidText`) is the runtime, owner and instance numbers, dotted. Statuses are
the lifecycle snapshot's. Owner and name are cut to `columnLimit` (32)
characters. A run that admitted no instance writes no table.

The start table is one snapshot taken when the last admitted instance has
finished or failed its `init`, or become terminal without it. A run asked to
end before then writes no start table. The end table is taken after the VM is
retired.

### Failures

An instance's failure is written to the error sink as one report when it
settles, and is in the run report: TID, name, script, VM, phase, stage
(`init`, `run`, `update`, `event <source>`, `shutdown`, `release`), error,
traceback, and up to `secondaryLimit` (8) `also failed:` lines. Each is
written exactly once; failures that settle together are written in ascending
TID order before the end table.

**A host failure is never turned into a report.** An exception from a binding
or a sink, one the runner raised, and a retained cleanup failure propagate
unchanged under the owner's policy. A host failure inside the owner ends it
without entering Lua again (`ShutdownSkippedUnsafe`, `ShutdownSkippedNoInit`).

**The retirement is complete before anything propagates.** The run asks the
owner to stop and waits for its worker to have ended, so what the sinks and
bindings borrow is not released while the owner's Lua still uses it. The wait
is interruptible but an interruption does not end it: each is recorded, and
afterwards a cancellation is raised as itself with the rest as evidence. A
segment that never returns keeps the call pending.

### Waiting and ending

A run waits in one STM wait composed with supervision. It ends at the first
of: every instance has ended; the stop request; the tick limit; the duration
limit (measured on the injected clock from just before the first admission).

**When several hold together, the order of precedence is the contract:** a
failure to write; what a finished `init` owes (the start table and the
*started* event); every instance ended (`EndedAllInstances`); the stop request
(`EndedStopRequest`); the tick limit (`EndedTickLimit`); the duration limit
(`EndedLimit`). A finished tick is counted before the duration limit is
looked at. A stop request already set when the run begins admits nothing,
reads no file and starts no VM.

Whatever the end, every unended instance is stopped in ascending TID order:
its `shutdown` runs once with `stopped`, then the VM is retired. **The runner
sets no deadline**: a script stuck in non-yielding Lua keeps the stop pending.

### The report and the status

`Ran RunReport` holds how the run ended (the four above, or
`EndedStartupFailure`), `reportTicks`, `reportEvents` (events produced;
deliveries by the engine's answer; watchers failed by overflow), each
instance's report, the `LoadFailure` if any, and the `RunStatus`:
`StatusFailure` if any instance failed or a source did not load; else
`StatusInterrupted` if the stop request ended the run; else `StatusSuccess`.

### The command line

`hetoimasia lua` (`console/Hetoimasia/Console/Lua*.hs` and `app/Main.hs` in
the root package) parses the arguments, installs two signal handlers, wires
the runner to the process's streams and maps its answer to an exit status.

```text
hetoimasia lua [--vm NAME] [--scheduler fifo] [--headless] [--tick SECONDS] [--for SECONDS | --ticks N]
               --script PATH [--name NAME] [--every SECONDS | --every-ticks N] [--script PATH ...]
```

Every option takes its value as the next argument.

| Option | Scope | Meaning |
| --- | --- | --- |
| `--vm NAME` | VM, once | default `main` |
| `--scheduler fifo` | VM, once | the default and only value |
| `--headless` | VM, once | accepted; the default and only mode |
| `--tick SECONDS` | VM, once | run on logical ticks granted at that real-time rate |
| `--for SECONDS`, `--ticks N` | VM, once | the duration limit; the tick limit |
| `--name NAME` | the latest `--script`, once | default the file's name without directory and extension |
| `--every SECONDS`, `--every-ticks N` | the latest `--script`, once | an elapsed interval; a tick interval |

Seconds are positive decimals of at most nine fractional digits, no sign or
exponent; nothing is rounded. Counts are positive whole numbers that fit a
64-bit tick. `lua --help` alone writes the help to stdout and exits 0.

**Usage is validated first**, as a pure function
(`Hetoimasia.Console.Lua.Options.parseLua`), before any file is read, VM
started or signal handler installed. Refused: an unknown option or argument; a
missing or empty value, or one that is itself an option; a repeated VM option;
a script option before the first `--script` or repeated for one script; a
scheduler other than `fifo`; a malformed number; no `--script`; `--ticks` or
`--every-ticks` without `--tick`; `--every` with `--tick`; `--every` with
`--every-ticks`. A runner usage refusal is a usage error too. A usage error
writes the usage line and a one-line reason to stderr and exits 2
(`Hetoimasia.Console.Usage`); in the reason every character that is not
printable ASCII becomes `\xNN` and each value is cut at 200 characters. An
invalid logging variable is configuration, not usage: status 1 before any
argument is read.

**Streams.** Output sink stdout, error sink stderr, each flushed after every
write, both UTF-8: `print` and the tables on stdout; `warn`, failure and
source-did-not-load reports and usage text on stderr, with the logger's
records.

| Status | When |
|---|---|
| 0 | every instance completed or was stopped, by a control or a limit |
| 1 | an instance failed, a source did not load, or a host failure propagated |
| 2 | invalid usage |
| 130 | SIGINT or SIGTERM ended the run, after the orderly stop; also a cancellation |

1 outranks 130, which outranks 0 (`Hetoimasia.Console.Exit`,
`Hetoimasia.Console.Lua.Status`).

**Signals.** SIGINT and SIGTERM handlers are installed on the `lua` path
only, after the usage check. Both call one coordinator
(`Hetoimasia.Console.Lua.Signals`): the first signal sets the runner's stop
request and returns; a **second** signal while that stop is running exits at
once with 130 (`exitImmediately`), skipping unrun shutdown hooks, cleanup and
flushing; later ones change nothing.

**Wiring.** The executable runs the runner through `runScopedApplication`:
the logging lifetime over stderr (entered first, left last), the supervision
boundary, and the runner inside it. The executable keeps `-threaded`.

**Examples** (checked in under `test/lua-examples/`, run by the root suite's
`Console` group):

```sh
hetoimasia lua --script test/lua-examples/oneshot.lua
hetoimasia lua --tick 0.001 --ticks 40 \
  --script test/lua-examples/looped.lua --every-ticks 1 \
  --script test/lua-examples/controller.lua --every-ticks 3
hetoimasia lua --tick 0.001 --ticks 20 \
  --script test/lua-examples/watcher.lua --script test/lua-examples/oneshot.lua
```

The forced exit needs a `shutdown` that never returns, so it is the optional
probe `cabal test hetoimasia:lua-forced-exit-probe --test-show-details=direct`
(validation group `test.lua-forced-exit`). Signal semantics differ between
Linux and macOS; Linux CI is the evidence.

### What is not here

Window creation, VM groups, module reload and a stop deadline.
`Hetoimasia.Scripting.Lua.Runner.Internal` is a seam for the examples, not
part of the contract and no way to configure a production run.
## The protocol model

The private `model` sublibrary (`model/`) is the vocabulary a scheduler, a
provider and a transport implement against, as pure data and pure functions.
It performs no IO, reads no clock and creates no interpreter; its
`build-depends` names only `base`, `containers` and `text`. Every record is
parameterised by one application value type the model never inspects.

### Identities

`Hetoimasia.Scripting.Lua.Internal.Protocol.Identity`. An `Owner` is one
`ModId` in one `ExecutionDomain`; a `SessionKey` adds its `SessionId` and
`Epoch`. Every `TaskId`, `RequestId` and `SubscriptionId` carries that scope.

The session issues the `TaskName` outright and stamps a `Generation`, from
one counter it never rewinds, onto every `RequestId` and `SubscriptionId`. A
caller-chosen `RequestName` or `SubscriptionName` is only half an identity, so
reusing a handle after its record was reclaimed is safe: a reply still in
flight for the old record cannot reach the new one. `Ordinal` is issued at
admission and on every re-entry to the ready set.

### Tasks and transitions

`…Protocol.Task`. A `TaskState` is `Ready`, `Running`, `Waiting` with its
`WaitCause`, `Paused`, or terminal (`Completed`, `Cancelled`, `Failed`). Each
transition (`startTask`, `applySegment`, `wakeTask`, `pauseTask`,
`resumeTask`, `cancelTask`, `failTask`) is a pure function answering the next
task or a `TransitionRejection`: `AlreadyTerminal`, `WrongState`,
`StaleScope`, `AheadOfScope`, `ForeignScope`. A rejection leaves the task
untouched, a terminal task refuses everything, and the scope check runs
before the state check. `applySegment` is the only function that writes a
cursor, and requires `Running`.

### Caps

`…Protocol.Limits`. `Limits` bounds active tasks, queued admissions,
subscriptions, one ordered-event backlog, outstanding requests, payload size
and retained terminal results, with a finite `Quantum` per `ServiceClass`.
`validateLimits` answers every `LimitViolation`, and a `ValidLimits` can be
obtained no other way. The quanta are enforced by
[the scheduling machinery](#the-scheduling-machinery), not the model.

### The session

`…Protocol.Session` is a facade over one pure session value; callers import
only it. The implementation is `…Protocol.Session.*`:

| Module | Owns |
| --- | --- |
| `Session.State` | the `Session` value, `newSession`, `Counters`, `SessionRejection`, `FailureRecord`, `ExitRecord` |
| `Session.Step` | refusal, counters, preconditions, ordinal/name/generation issuance, one task transition |
| `Session.Revocation` | `retire`, `invalidateHoldingsOf`, `revokeOne`, `revocableRequests`, `reclaim`: the one definition of provider accounting |
| `Session.Tasks` | admission, activation, task transitions, observing a result |
| `Session.Requests` | accepting, replies, cancellation, observation, provider completion |
| `Session.Subscriptions` | registration, delivery, taking events, unsubscribing |
| `Session.Epoch`, `Session.Failure`, `Session.Stop` | the three session-wide invalidations |

Each operation answers `(Session v, Either SessionRejection a)`. A rejection
never advances the protocol. **It is not true that a rejection changes
nothing**: it always counts on `sessionCounters`, and in four places records
on the record it was about: a reply to a settled request retires its provider
accounting; a reply over the payload cap discharges the request (settling an
unsettled one as a provider failure, the only rejection that moves protocol
state); a repeated provider completion increments `requestLateCompletions`; a
delivery into a full ordered backlog increments `subscriptionRejected`.

`SessionRejection`: `AdmissionIsClosed`, `CapReached`, `PayloadTooLarge`,
`UnknownTask`, `UnknownRequest`, `UnknownSubscription`, `TaskRetired`,
`TaskNotActivated`, `NotTaskOwner`, `NoTerminalResult`, `NothingQueued`,
`NoDelivery`, `SessionAlreadyFailed`, `SessionAlreadyStopped`, and the wrapped
`TransitionRefused`, `ReplyRefused`, `ObserveRefused`, `ProviderRefused`,
`DeliveryRefused`. There are no `Duplicate*` refusals: the session issues the
identities.

- **Terminal-result storage** is reserved at admission and released when the
  result is observed or discarded. An unread result keeps its storage, and the
  session refuses the next admission instead of growing.
- **A request holds two independent obligations**, reclaimed only when both
  are discharged: its result observed or discarded, and its provider's work
  known to have ended. Cancellation, task invalidation, epoch change, failure
  and stop revoke delivery authority without establishing provider
  completion. A late reply is refused, publishes nothing, and still retires
  the accounting.
- **A `FailureReason`'s detail is bounded and copied.** `failureReason`, the
  only constructor, truncates to `reasonDetailBound` characters and copies
  the result to its own array, so a short slice never pins a large buffer.

Subscriptions declare an `OverloadPolicy`: `OrderedEvents` rejects and counts
a delivery into a full backlog; `ReplaceableState` coalesces to the newest.

| Operation | Effect |
| --- | --- |
| `advanceEpoch` | invalidates every task, queued admission, subscription and pending request of the previous epoch, retaining only provider-work accounting. What its owner already revoked is not invalidated or counted twice |
| `reportFailure` with `RecoveryUnsafe` | the session becomes terminally failed: mutation admission closes, live work is invalidated, the first `FailureRecord` is kept with the last good snapshot. `Observing` admission stays open; `advanceEpoch` is refused. It applies even when the named task already finished |
| `reportFailure` with `RecoverySafe` | fails the named active task alone; refused for a finished task |
| a failure naming a *queued* admission | refused either way |
| `stopSession` | closes admission, aborts queued work, records a task inside a segment as outstanding, and answers an `ExitRecord`. It carries no worker cleanup evidence |

### Who consumes what

| Consumer | What it takes |
| --- | --- |
| the scheduling machinery | `Session` admission and caps, `ServiceClass`, `Quanta`, `validateLimits`, `Ordinal`, the task states and transitions, `activateNext`, `stopSession`. It does not use `reportFailure`: a failed task is failed alone |
| the scheduled owner | the same through the scheduler, with `TaskId` wrapped in `ScheduledTaskId` |
| requests | `RequestId`, `Settlement`, `Reply`, the two obligations, holders, the epoch change and the stop, in a session of its own |
| subscriptions | `OverloadPolicy`, over the request service unchanged |
| the runtime adapter | `Limits` and `validateLimits` for `maxQueuedAdmissions` and `maxRetainedResults` only |

## Running the suite

```bash
cabal test hetoimasia-scripting-lua:lua-host-tests --test-show-details=direct
cabal test hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct
```

Both also run under `--project-file cabal.project.cpu`. The validation groups
are `test.scripting-lua` and `test.scripting-lua-runtime`; see
[docs/validation.md](../../docs/validation.md). Components of the host suite:

```bash
cabal test hetoimasia-scripting-lua:lua-host-tests \
  --test-show-details=direct --test-option=--match --test-option='VM owner'
cabal test hetoimasia-scripting-lua:lua-host-tests \
  --test-show-details=direct --test-option=--match --test-option='the value boundary'
cabal test hetoimasia-scripting-lua:lua-host-tests \
  --test-show-details=direct --test-options='--match Protocol'
```

Cancellation, shutdown and cleanup windows can hide an asynchronous-exception
race on one platform: **CI on Linux is the evidence for them, a local pass is
not.**

## The Linux confinement probe

`linux/` holds a private feasibility probe: a child program
(`lua-confine-child`) launched inside a candidate confinement profile, a
parent-side driver, and the C that installs the profile and attempts what it
should refuse. Nothing links it, and it is built on Linux alone.

```bash
cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct
```

The validation group is `test.lua-confinement-linux`, optional and
local-only, never selected automatically. A green run is evidence, never a
verdict; the Linux confinement verdict is listed in
[removed_records.md](../../docs/removed_records.md).

## The macOS confinement probe

`macos/` holds a confined helper (`macos-confinement-helper`), the trusted
parent side (`macos-probe`, a private sublibrary) and the Hspec target
`macos-confinement-probe`, built only on Darwin. None of it is an engine
facility, and it admits no untrusted source through any public path.

**The answer was `inconclusive`**: every proof row was demonstrated, on two
interfaces Apple does not support (the macOS confinement verdict is listed in
[removed_records.md](../../docs/removed_records.md)). Do not build on this
code without reading it.

```bash
cabal test hetoimasia-scripting-lua:macos-confinement-probe --test-show-details=direct
```

The validation group is `test.macos-confinement`, optional and local-only; see
[docs/validation.md](../../docs/validation.md#the-macos-confinement-probe).

## Routine tests and optional probes

`lua-host-tests` keeps the quick bridge and protocol contracts, including
protected allocation failures and one-capability foreign-call progress. The
deliberately nonterminating Lua experiment is separate:

```sh
cabal test hetoimasia-scripting-lua:lua-hazard-probes --test-show-details=direct
```

It waits five seconds and terminates its child process. It and both
confinement probes are local-only and optional; see the
[test classification](../../docs/test_classification.md). `lua-hazard
callback-cancellation` is a manual diagnostic with no pass/fail oracle.
