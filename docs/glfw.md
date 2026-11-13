# GLFW session and windows

`hetoimasia-glfw` owns the native binding to GLFW 3.4, the one
process-main-thread session over it, the scoped windows created in that
session, and the window host and owner loop that compose them with the
runtime's application lifecycle. This is the contract of what the code does.
Signatures are in the modules' export lists and Haddock; tested cases are in
the suites named under [Build and check](#build-and-check).

There is no default close policy and no rendering operation here. Nothing
assumes a single or primary window or monitor.

## Package layout

| Component | Visibility | Holds |
|---|---|---|
| `hetoimasia-glfw` | public | `Hetoimasia.GLFW.Session`, `.Monitor`, `.Window`, `.Command`, `.Mode`, `.Demand`, `.Input` |
| `:model` | private | Session, monitor and window models over a table of native operations; error capture; controls, modes and the command protocol; the notification policy and demand slots; the input feed; the window attachment model. Binds nothing. |
| `:native` | private | Foreign imports, `native/cbits`, the production native table. Native handles and ABI declarations stay here. |
| `:runtime-glfw` | public | `Hetoimasia.Runtime.GLFW`: the window host, both owner loops, the render demand helper, quiescence. The only library that depends on `hetoimasia-runtime`. |
| `:runtime-glfw-core` | private | The host's implementation (`Hetoimasia.Runtime.GLFW.Internal.Host.*`), the pure render demand helper, the supervised graphics owner (`.Internal.Owner.*`) and the Vulkan-free surface bridge (`.Internal.Surface`), with the test-only host hooks. |
| `:vulkan-interop` | public, flag-gated | `Hetoimasia.GLFW.Vulkan`, `.Vulkan.Provenance`. Built only with the manual `vulkan-interop` flag, which only `cabal.project.vulkan` sets. See [Vulkan interop](#vulkan-interop). |
| `:seam`, `:seam-core` | test-only | The real models over a scripted native library, with window and monitor drivers. Links no GLFW. |
| `glfw-tests` | suite | Headless: everything over the seam, a scripted clock and injected fake backend operations. Initializes no GLFW, needs no display. |
| `glfw-native-tests` | suite | Real sessions, monitors, windows, controls, host and input callbacks on the platform it runs on. |

The main library and `model`, `native`, `seam`, `seam-core` depend on
`hetoimasia-foundation` and not on `hetoimasia-runtime`. `vulkan-interop` is
the only component that depends on the Vulkan binding; with its flag off it is
not buildable and contributes no dependency. `runtime-glfw` is a sublibrary
rather than a package because the native suite must depend on it and Cabal
refuses that as a package cycle. The package creates no logger: its warnings
(`glfw.input`, `glfw.wake`, `glfw.retirement`, `glfw.graphics-owner`) are
written through a logger the application injects.

## Public interface

| Module | Gives |
|---|---|
| `GLFW.Session` | `allocSession`/`withSession`, `SessionConfig` (requested backend, optional initialization deadline), `Backend` (`X11`, `Cocoa`, `Wayland`), `takeAsynchronousReports`, the `Reports`/`NativeError` evidence types, the misuse and failure types, and the wake capability (`sessionWake`, `wakeSession`, `WakeOutcome`). |
| `GLFW.Demand` | `DemandRequest` (a monoid: none, immediate, or a deadline), `DemandPublisher` and `publishDemand` (any thread), `CapturedDemand`, `DemandStatus`. |
| `GLFW.Monitor` | `monitorInventory` (a `SnapshotReader`), `synchronizeMonitors`, `resolveMonitor`, `MonitorId`, `MonitorDescription` and its attribute readers. |
| `GLFW.Window` | `allocWindow`/`withWindow`, `WindowConfig`, `WindowId`, `windowObservations`, `synchronizeWindow`, `WindowObservation` and its readers, `WindowPhase`, `CloseRequest`, `WindowCapabilities`. |
| `GLFW.Command` | `WindowCommandHost`, `WindowCommandPort`, `submitWindowCommand`/`awaitSubmitWindowCommand`, the `WindowCommand` constructors, `CompletionTicket`, `Disposition` and its result, rejection and attempt types, `WindowClient`. |
| `GLFW.Mode` | `WindowMode` (windowed, borderless, fullscreen), `VideoModePreference`, `ModeFallback`, `ModeRequest`, `StartupMode`, `ModeRecord`, `ModeOutcome` and its failure types. |
| `GLFW.Input` | `InputReader` (`readInput`, `awaitInput`), `InputEvent` and payloads, `ResetToken` and `acknowledgeReset`, `InputControl` (`enableInput`, `suspendInput`), `inputStatistics`. |
| `Runtime.GLFW` | `allocWindowHost`/`allocWindowHostIn`, `HostConfig`, the host's readers and close operations, `runOwnerLoop`, `runScheduledOwnerLoop`, the render demand helper (`renderTurn`, `acknowledgeRender`), `runWindowApplication`. |

Handles, identities, observations, commands, tickets, readers, publishers and
tokens are exported without constructors and read through functions, so no
client can build or rewrite one. No public type holds a native window or
monitor pointer. Clients receive only read endpoints of snapshots. No public
operation reaches the host's window collection, a release, or an input feed's
channel, state or producer.

Every failure is raised through `throwFailure` with component `glfw` (the
host's own under `glfw.runtime`), the operation name, and identifiers such as
`backend`, `window`, `monitor` or `request`, so `failureEvidence` reads the
origin back without a logger.

## Entry

`allocSession` builds the session as a staged composite, in this order:

1. **Backend.** Linux admits X11 and Wayland; macOS admits Cocoa. No request
   takes the platform's own backend (X11 on Linux), so Wayland is selected only
   on explicit request. A backend the platform does not admit is
   `UnsupportedBackend`. A request is never exchanged for another backend.
2. **Thread.** The caller must be a bound thread and the OS thread that entered
   the process main function (checked by a C shim), or entry is
   `NotProcessMainThread`. The threaded runtime is required.
3. **Exclusivity.** A process-wide guard is claimed: `SessionAlreadyActive` if
   a session is active on any thread, `SessionPoisoned` if the guard is
   poisoned.
4. **Support.** `glfwPlatformSupported` must accept the backend, or entry is
   `UnsupportedBackend` and the guard is released. This says only that the
   prefix was built with the backend, not that a display is reachable.
5. **Callback.** The error callback is installed.
6. **Initialization.** The platform hint and `GLFW_COCOA_CHDIR_RESOURCES =
   false` are set (the session never changes the working directory) and
   `glfwInit` runs. A false return is a `NativeFailure` carrying the reports
   GLFW made during the call. An unreachable display is identified from those
   reports by GLFW's own code and description, carried through unaltered: X11
   reports `GLFW_PLATFORM_UNAVAILABLE`, Wayland `GLFW_PLATFORM_ERROR`.
7. **Verification.** Reports from a successful initialization are raised now,
   after termination is registered, and `glfwGetPlatform` must name the
   selected backend, or entry is `BackendNotSelected`.
8. **Connection probe.** A Wayland session resolves the private probe of
   [Wayland connection loss](#wayland-connection-loss); a library that cannot
   supply it refuses the session with `ConnectionProbeUnavailable`.
9. **Monitor callback.** Its storage is allocated, its detach registered, and
   it is attached. An attachment that raises poisons the guard.
10. **Monitor inventory.** Monitors are enumerated and the prepared inventory
    becomes revision zero of a fresh snapshot.

Steps 1 to 3 change no native state. A failure at a later step releases exactly
what earlier steps acquired, with the triggering failure primary and every
cleanup failure retained ([composite construction](resources.md#composite-construction)).
Sequential sessions work after a complete, safe teardown.

### Initialization on Cocoa

`glfwInit` is the one call of entry that can fail to return. GLFW 3.4's Cocoa
initialization calls `[NSApp run]` whenever the application reports that it has
not finished launching, and that run returns only on a notification
`NSApplication` sends once per process. In a process that already initialized
GLFW once, a transiently false answer sends a later `glfwInit` into a run that
nothing stops. Two things bound that:

- **Prevention.** The native shim wraps `glfwInit`. From the second
  initialization of a process on, it queues a block on the main dispatch queue
  before the call and closes it when the call returns. If `glfwInit` enters the
  redundant run, the block stops it as GLFW's own delegate would. Otherwise the
  block finds its generation closed and does nothing. There is no visible
  effect, the first initialization is untouched, and Linux is unchanged.
- **Deadline.** `SessionConfig.initializationDeadline` carries a bound in
  microseconds and a report action over the application's own logger. The
  guard brackets exactly the `glfwInit` call. If the bound passes while the
  call is pending, the report runs on its own thread for at most two seconds
  and the process ends with `_exit(75)`, without unwinding. One transaction
  decides each call exactly once (retired or expired, never both), and the
  timer thread is joined before the guard leaves on every other path. Nothing
  is armed by default. The `run` command arms ten seconds on macOS only and
  logs one `Error` record under `run.graphics` that names what was observed
  (`glfwInit had not returned`), not a cause.

The deadline is mechanism; the policy (bound, report, flush) is the
application's.

## Owner, thread, and lifetime

The owner is the thread that entered the session. `takeAsynchronousReports` and
every window operation check, before any native call, that they run on the
owner (`NotSessionOwner`) and that the session is live (`SessionEnded`). The
session lives until its enclosing scope ends and must not escape it.

### Waking the owner

`sessionWake` lends an opaque wake capability; `wakeSession` posts GLFW's
cross-thread empty event so an owner blocked in a native event wait returns. It
is the only native call the package makes off the owner thread. Any thread may
call it. A wake is a hint: it carries no message, may coalesce, and proves
nothing about work. A call makes at most one post plus bounded, non-blocking
bookkeeping, invokes no caller IO, and takes no lock an owner operation or
callback could hold.

| Outcome | Meaning |
|---|---|
| `WakePosted` | The event was posted and nothing was reported during the call. |
| `WakeTerminal` | The session has begun closing or has closed. GLFW was not entered. |
| `WakeFailed reports` | An expected platform failure: every report for the call is `GLFW_PLATFORM_ERROR`, none lost or faulted. |

Any other evidence (another code, a lost report, a callback fault, an
unrecorded error) raises a `NativeFailure` under `wake session`. No outcome
retries the wake or chooses a degradation policy; that is the notifier's
([the degradation policy](#the-degradation-policy)).

### Wake lifetime

Each session owns a wake gate: open, closing with a count of admitted calls, or
closed. A wake is admitted by raising the count in the transaction that finds
the gate open and leaves by lowering it after its native call returns;
admission, call and leaving run masked. The session's first release closes the
gate and waits, uninterruptibly, until every admitted call has left. So
`glfwTerminate` never runs while a wake is inside GLFW, no wake enters GLFW
after termination begins, and a capability kept past its session is terminal
forever and cannot reach a later session.

## Wayland

### The supported profile

A session enters native Wayland only when its configuration requests it, on
Linux, with the pinned GLFW 3.4 prefix built with both backends. What is
supported is what was demonstrated under the pinned headless Weston that
`tools/display/wayland.sh` starts:

- entry on the requested socket; windows created and closed independently;
- title, size, visibility and size-limit commands. Size limits are command
  delivery only: a client cannot read `xdg_toplevel` limits and a compositor
  may disregard them;
- framebuffer extent and content scale as observations;
- global placement, focus and borderless-over-monitor answered unsupported,
  and placement and iconified observations unavailable, with no native call
  made ([capabilities](#capabilities-and-platform-restrictions));
- the cross-thread wake, repeated sessions in one process, and complete
  rollback of failed entry;
- Vulkan rendering on packaged Weston and Lavapipe (`test.vulkan-wayland`),
  including hiding a presenting window
  ([Hiding an attached window](#hiding-an-attached-window)).

Not qualified, and stated rather than estimated: any compositor but packaged
headless Weston; any hardware (GPU, display, input device, hotplug); a
compositor-generated close request (examples inject one through the window's
close callback); minimization, suspension and occlusion, including minimizing a
presenting window; reconnection, which does not exist.

### Wayland connection loss

GLFW 3.4 reports a lost compositor connection through no error: it issues a
close request for every window and returns. A close request is therefore
neither necessary nor sufficient evidence of a loss. The production shim
carries a private, read-only probe instead. On the owner thread it reads the
display's latched error and polls the display's socket for hangup with a zero
timeout. It never reads, dispatches, flushes, reconnects or closes the
connection, and no pointer or descriptor leaves C.

`processWindowEvents` asks the probe immediately before and after every native
poll or wait. A status other than healthy fails that processing with
`ConnectionFailed` under `process window events`:

| Cause | When |
| --- | --- |
| `TransportClosed` | The display latched a transport error, or the socket reported the peer gone. |
| `ProtocolFailure` | The display latched `EPROTO`. |
| `ProbeFailure` | The probe could not establish the status. Reported as itself, not as a loss. |

The failure is terminal. The session latches it and every later event
processing raises the same failure with no probe and no native call. In the
window host it ends the owner loop, and the protected exit retires every
attachment before any window or the session is released. A loss certifies no
retirement fact, and no completion is fabricated for work the compositor can
no longer settle. X11 and Cocoa sessions resolve no probe.

## Native error evidence

GLFW reports errors through one process-wide callback, possibly on another
thread. The installed callback runs uninterruptibly and does bounded work: it
copies at most `errorDescriptionLimit` (1024) bytes, stores one `NativeError`
with a non-blocking update, and returns. It calls no sink, takes no lock and
lets no exception unwind into C; a report it cannot record adds to
`callbackFaults`.

Reports are attributed by facts about the reporting OS thread:

- A report made during a wake call's native call, on the OS thread making it,
  belongs to that wake call (a thread-local mark set around the post). Each
  call has its own bucket.
- Otherwise a report made on the process main thread during an operation's
  native call belongs to that operation, which fails with a `NativeFailure`.
- Any other report is asynchronous and is read by `takeAsynchronousReports`.
  It is never attributed to whichever operation is running.

Each class keeps its first `errorEvidenceCapacity` (16) reports and counts
later ones in `reportsLost`. A lost report or callback fault still counts as
reported, so full storage never turns a native failure into success.

### The degradation policy

Command admission and demand publication reach the owner through one notifier
per session, shared by every host over that session.

- The first `WakeFailed` degrades the session's wake path and retains its
  evidence. Later admissions and publications skip the native call, and the
  owner's finite idle wait is the bounded polling that keeps work moving.
  Nothing is retried and no admitted work is reclassified.
- A programming or lifetime violation is not degraded around: it propagates to
  the notifying thread, and work that thread already committed still settles.
- Every admission and publication registers the notification it owes in the
  transaction that commits it and discharges it exactly once.
  `hostNotificationsInFlight` reads how many are outstanding.
- Degradation owes exactly one guarded diagnostic attempt: one structured
  warning under `glfw.wake` through the logger injected on the loop hooks,
  written on the owner thread outside transactions, callbacks and releases.
  Each turn claims it after reconciliation and the loop claims it as it ends.
  `runWindowApplication` waits for outstanding obligations after quiescence
  and worker drain, then makes the attempt; `reportHostWakeDegradation` is the
  same boundary for an application that owns its own shutdown.
- The claim is spent whatever happens. A filtered entry, a sink failure and a
  cancellation each end the attempt and none is retried.
- A sink failure that becomes the run's own failure is marked with the
  runtime's `DiagnosticFailure`. When an application failure is already
  primary it stays unmarked, the warning's failure is retained beside it under
  `glfw wake degradation report`, and the logging lifetime records the failed
  attempt so the terminal report and final flush skip the failed sink.

## Teardown, poisoning, and controlled blocking

Release order of the session composite:

| Release | What it does |
|---|---|
| `glfw wake gate` | Closes the gate, then waits uninterruptibly for admitted wakes to leave. No native call. |
| `glfw monitor inventory` | Ends every monitor identity, publishes the `InventoryClosed` inventory and closes the snapshot in one transaction. |
| `glfw monitor callback` | Takes any latched callback fault, detaches the callback, raises any report from that call, then the fault. |
| `glfw terminate` | Marks the session ended, calls `glfwTerminate`, raises any report from that call. |
| `glfw error callback` | Detaches the callback, frees its storage only if teardown has been safe, raises unread asynchronous reports as `AsynchronousErrorsUnobserved`. |
| `glfw monitor callback storage` | Freed after the last native call, only if teardown has been safe. |
| `glfw session occupancy` | Vacates the guard after a safe teardown, or poisons it. |

A release-time native error is retained through
[the failure table](resources.md#the-failure-table) and does not poison.

Poisoning is the answer when teardown cannot establish that native ownership
and callback registration ended safely: termination or a detach raises instead
of returning, initialization or attachment raises with native state unknown,
or a release runs off the owner thread. Callback storage is then leaked rather
than freed, and every later entry fails with `SessionPoisoned` before any
native call.

Every release is a bounded GLFW call on the owner thread or non-blocking
bookkeeping; the wake gate's wait is the one wait on another thread and is
bounded by calls already admitted. No release contains a queue, fence, device
wait or logger.

## The binding

- Only the operations the models use are bound. Imports go through
  `native/cbits/hetoimasia_glfw.h`, which includes the installed
  `GLFW/glfw3.h`, so the C compiler checks each CAPI declaration and every
  constant comes from the header. Callback setters are `ccall` imports because
  CAPI cannot spell their function-pointer types.
- Every GLFW import is `safe`: any may re-enter Haskell through the error
  callback. The thread-identity and wake-mark shims call nothing and are
  `unsafe`.
- Every array and string GLFW returns is copied before the operation returns.
  A negative count, or a positive count beside a null array, is reported as
  inconsistent rather than read. No structure layout is assumed.
- The shim holds the `glfwInit` wrapper, the wake post (clear error, set mark,
  post, clear mark, read error, in one C call), the finite wait with the
  observation the native examples read, and the Wayland probe. It holds no
  queue or game logic.

## Monitors

The session constructs the monitor inventory at entry and ends it at teardown.
A `MonitorInventory` is immutable, prepared to normal form, and published
through a [latest-value snapshot](messaging.md#latest-value-snapshots) with a
revision, a phase, and each connected monitor as a copied description (name,
primary, position, work area, physical size, content scale, current mode and
video modes), in GLFW's enumeration order.

- Any thread may read `monitorInventory` (the host lends it as
  `hostMonitors`). Only the owner refreshes: `synchronizeMonitors` always,
  `resolveMonitor` before it answers, and the owner loop after native events
  when the monitor callback captured a change.
- A refresh publishes a new revision only when a description or identity
  changed. GLFW's callback reports connection changes only, so a changed work
  area, scale or mode on a connected monitor appears at the next
  `synchronizeMonitors`.
- An empty list is an ordinary observation. The primary designation is an
  attribute; nothing selects a primary or assumes it sits at the origin.

**Identity.** A `MonitorId` is the session's identity plus a local number the
session never reissues, issued once per connection. The native address is kept
only as a comparison token between boundaries, never turned back into a
pointer. At a refresh: a captured connection or disconnection ends the
identity at that address (so a reconnect at the same address gets a fresh
identity); a lost change ends every identity; an identity whose address is no
longer enumerated ends. An ended identity, or one from another session, never
resolves. `resolveMonitor` answers `MonitorAvailable` with a fresh description
or `MonitorDisconnected` before any native operation targets the monitor.

**Validation.** Every native number is checked before it becomes an observed
value. An inconsistent report (bad count, null or repeated monitor, null name,
negative work area, non-positive physical size, non-finite or non-positive
scale, invalid mode) becomes `Unavailable`, never a fabricated value. A query
that reports only `GLFW_FEATURE_UNAVAILABLE` is `Unavailable`; any other
report fails the boundary with `NativeFailure` under `sample monitors`.

**Callback.** The monitor callback runs uninterruptibly, records the address
and event code into a latch of at most 64 changes with one non-blocking
update, and returns. An overflow, an undefined event code or a callback fault
is a lost change: the next refresh ends every identity, and a fault is
rethrown after that refresh commits. A refresh clears what it folded only in
the masked commit that publishes; a failure before the commit leaves every
capture latched.

**Completion.** When the session ends, every identity ends and the last
descriptions are published as the `InventoryClosed` inventory in the
transaction that closes the snapshot.

**Platforms.** On X11, GLFW enumerates connected RandR outputs with active
CRTCs. Hotplug and multi-monitor topologies are covered by the headless
examples; real attach and detach is local interactive evidence.

## Windows

`allocWindow` creates a window as a scoped resource of the enclosing scope;
any number may be live in one session. The window host creates and closes
windows dynamically as members of a
[scoped collection](resources.md#scoped-resource-collections), through the
same assembly ([Dynamic windows](#dynamic-windows)).

**Owner and lifetime.** Creation, `synchronizeWindow` and every release run on
the session's owner thread and check that first. A window's scope must be
inside the session's. Its handle turns terminal as the first step of release:
`windowEnded` answers `True` and `synchronizeWindow` answers `WindowEnded`
without a native call. A `WindowId` is the session's identity plus a local
number the session never reissues, even for a failed creation.

### Creation

A staged composite, in order:

1. **Validation.** Both dimensions in `1 .. 2147483647` and no NUL in the
   title, or `WindowConfigRejected` before any native call.
2. **Owner.** Thread and liveness are checked; a session whose teardown safety
   was lost refuses with `SessionPoisoned`. The identity is issued.
3. **Callback storage.** One wrapper per callback.
4. **Native window.** Hints are reset, then `GLFW_CLIENT_API = GLFW_NO_API`
   and the visibility and focus hints are set from the configuration, so one
   window's configuration cannot leak into the next. Destruction is registered
   before any report from the creating call is raised.
5. **Callbacks.** Their detach is registered, then each is attached.
6. **Initial observation.** Every attribute is sampled, reconciled with
   anything captured since attachment, and published as revision zero.

A failure at any stage releases exactly what earlier stages acquired, with the
triggering failure primary.

### Observations

A `WindowObservation` is immutable, prepared to normal form, and published
through the window's [latest-value snapshot](messaging.md#latest-value-snapshots).
It carries the identity, a revision equal to the snapshot's, a phase, and:

| Attribute | Source |
|---|---|
| Logical extent, framebuffer extent, content scale, placement | getter and callback |
| Focused, iconified, maximized | `glfwGetWindowAttrib` and callbacks |
| Visible | sampled only (no callback) |
| Decorated, fullscreen monitor | sampled; the mode record is derived from them |
| Close request | close callback |
| Cursor position, cursor inside | callbacks, coalesced, never sampled |

- Observed fields hold only sampled or called-back values, never the requested
  configuration.
- A query that reports only `GLFW_FEATURE_UNAVAILABLE` is `Unavailable`; any
  other report fails the boundary with `NativeFailure`.
- A zero framebuffer extent is an ordinary nondrawable observation.
- Getters sampled together are an engine observation, not an atomic snapshot
  of the OS, and a snapshot keeps no event history.

#### Visible after an iconify transition

Visible has no callback. On Cocoa a restore completes asynchronously, so the
restore's own sample can read visible `False`, and nothing would read it
again; [eligibility](#render-demand) would then keep the restored window
undrawn. An iconify callback that reports a restore therefore starts a
follow-up, owned by the window and run on the owner thread:

- **Quick phase.** On each following owner turn visible is re-read once, until
  a read reports `Observed True` or eight reads are spent. The bound is a
  count of turns, not a time.
- **Slow phase.** A window still `Observed False` is re-read on the first turn
  at least one `hostIdleWait` after its previous re-read, while it stays open,
  not iconified and suspended. At most one re-read per window per turn; it
  never shortens the loop's wait.
- **Stops.** A read of `Observed True` or `Unavailable`, a hide control that
  returned, another iconify, closing or ending. The last sampled value stands;
  nothing is forced or inferred.
- Each re-read goes through the same capability gate and error bracket as a
  full sample, and a re-read that matches the observation publishes nothing.

### Callbacks and the reconciliation boundary

Every window callback is contained at the trampoline: it runs uninterruptibly,
copies its fixed payload into the window's capture latch with one non-blocking
update, and returns. None calls application code, waits, logs or destroys a
native object. Anything it raises is latched (the first kept, later ones
counted) rather than unwinding into C.

- Geometry, attributes and cursor motion coalesce to their latest value.
- Key, character, button, scroll and focus transitions are staged in a bounded
  buffer of 256 events and never coalesced. A button copies the cursor sample
  at that moment.
- Overflow of the staging buffer sets a loss latch. At the next boundary the
  ambiguous batch is discarded and the attached feed begins an overflow reset
  ([Input feeds](#input-feeds)). A window with no feed discards staged input.

Captures are reconciled on the owner thread at an owner boundary: at creation,
at `synchronizeWindow`, after any owner step's native calls, and after each
poll or wait of the owner loop. A boundary:

1. runs its native work and takes the reports made during it;
2. reads the capture latch without clearing it and folds it, with any fresh
   sample, into the current observation;
3. prepares a new revision if anything changed, or if a refresh or close
   request was captured;
4. commits in one masked step: clears the folded captures, publishes the
   revision, records it as the owner's current observation;
5. takes and rethrows a latched callback fault, annotated with
   `window callback`.

A cancellation or failure before the commit leaves every capture and fault
latched and the snapshot unchanged. An observation's revision always equals
its snapshot cursor's.

### Close requests

A native close request never destroys the window or exits the process. It is
latched and reconciled into `observedCloseRequest` as a `CloseRequest` naming
the window and an increasing per-window number; several before one boundary
coalesce into the newest. Rejection clears a request only while it is still
the latest. What a request means is application policy
([Close requests in the owner loop](#close-requests-in-the-owner-loop)).

Test-only drivers: `requestCloseForCheck` and `sizeLimitsForCheck` reach the
Cocoa or X11 handle and answer unavailable on any other backend, Wayland
included, without asking GLFW for a handle. `injectCloseForCheck` invokes the
registered close callback on every backend and is an injected request, never
evidence of one the platform generated. `Hetoimasia.GLFW.NativeCheck`
(sublibrary `native-check`, test suites only) exposes `requestNativeClose` by
`WindowId` through the host, on the owner thread.

### Release

| Order | Part | Release |
|---|---|---|
| 1 | `glfw window callbacks` | Marks the handle terminal, takes any latched callback fault, detaches every callback, raises any report from that call |
| 2 | `glfw window` | Destroys the native window, raises any report from that call |
| 3 | `glfw window callback storage` | Frees the wrappers if release stayed certain; otherwise keeps them and poisons the session |
| 4 | `glfw window observations` | Publishes the terminal observation and closes the snapshot in one transaction |

Release becomes uncertain when a detach or destroy raises instead of
returning, when destroying reports an error, when a release runs off the owner
thread or after the session ended, or when attaching callbacks raised during
creation. The wrappers are then kept, the session refuses further windows with
`SessionPoisoned`, and it poisons its guard when it ends.

### Lifecycle phases

| Phase | Published | Meaning |
|---|---|---|
| `WindowOpen` | At creation, revision zero | Live |
| `WindowClosing` | When an owner begins the close protocol, in the transaction that closes the window's admission | Live, callbacks attached, admission closed |
| `WindowReleased` | By release, last revision | Disposed |
| `WindowDisposalFailed` | By release, last revision | A part failed; release stayed certain |
| `WindowReleaseUncertain` | By release, last revision | Callback reachability unknown |

The terminal phase is always published before the snapshot closes and keeps
the last observed attributes without querying the destroyed window. A scoped
window, or one the host disposes at shutdown, never passes through
`WindowClosing`.

## Window commands

`Hetoimasia.GLFW.Command` admits prepared window commands through a bounded
port, gives each admitted command a persistent completion ticket, and settles
each exactly once. It is built on
[the bounded FIFO channel](messaging.md#bounded-fifo-channels). The window
host's owner loop is its only production executor.

**Ownership.** `newWindowCommandHost` runs on the session's owner. The owner
keeps the `WindowCommandHost` (closure, statistics, direct performance).
Clients hold the `WindowCommandPort`, which can only submit, and tickets; any
thread may hold either. Neither carries a native handle, a channel endpoint or
a completion cell. Commands are claimed and settled only on the owner thread.

### Admission

- A `WindowCommand` is an immutable request to observe, control or close one
  window, or to create one. Submitting issues a request identity, records a
  `CommandOrigin` (request, window, submission site, caller context) and
  prepares the message on the submitting thread.
- `submitWindowCommand` never waits: `SubmitAccepted` with a ticket,
  `SubmitFull`, or `SubmitClosed` (which takes precedence).
  `awaitSubmitWindowCommand` waits for capacity; cancelling it admits nothing
  and closure ends it with `WaitClosed`.
- The message and its completion cell are added in one transaction. A
  cancellation after that commit withdraws nothing: the command settles even
  if its caller never received the ticket.
- Request identities are never reissued. Order is the order admissions
  committed.
- A committed admission wakes the session's owner. The obligation is
  registered in the admitting transaction, and the commit and wake run masked,
  so no asynchronous exception can drop the wake. The submission's answer
  never depends on the wake's outcome
  ([the degradation policy](#the-degradation-policy)).

### Dispositions

| Disposition | When | Effects |
|---|---|---|
| `Performed result` | Performed or requested from the window system | Applied |
| `Rejected reason` | No such window served, window ended or closing, a native call failed first, close or creation not permitted, creation refused or failed with a clean rollback, or a control or mode refused by validation | None applied |
| `Unsupported control` | The platform cannot perform the control | None applied |
| `Attempted attempt` | A control's native calls were made | Its observations report what happened |
| `Transitioned transition` | A mode request ran | See [Window modes](#window-modes) |
| `NotExecuted` | Closure settled it while queued | None |
| `Interrupted request` | Execution or preparing its completion data raised | May have been applied; nothing is replayed or rolled back |

A settled ticket never changes and an admitted command never disappears. A
native failure is carried as copied data; a Haskell exception is never put in
a ticket and propagates from the executor with its own type and context. A
construction whose rollback itself failed is not a rejection: it propagates,
settles the command as `Interrupted`, and ends the loop.

**Creation handoff.** A successful creation settles as
`Performed (WindowCreated window)`. The new window's `WindowClient` (its own
command port, observations, input reader and control, demand publisher) is
written beside the disposition in the settling transaction and read with
`pollWindowClient`. It carries no native handle and no release or creation
authority.

**Port scope.** Each host window has a private command host whose port its
`WindowClient` carries. Its executor settles a creation as
`CreationNotPermitted` and a command for another window as `WindowNotServed`.
Holding one window's port grants no authority over another.

**Tickets.** `pollCompletion` reads without waiting; `awaitCompletion` waits
and may be repeated; dropping a ticket cancels nothing. On the owner thread,
waiting on an unsettled ticket or for capacity fails with
`OwnerThreadWouldWait`. The owner uses `performWindowCommand`, the direct
checked execution with no queue or ticket.

**Execution.** A claim receives the command and marks it active in one
transaction, and protection begins with the claim. If anything raises, the
command settles as `Interrupted` before the exception is rethrown; a
synchronous failure gains the `execute window command` context with the
request's origin.

**Observation request.** `observeWindowCommand` synchronizes the addressed
window at an owner boundary and completes with `ObservationPublished` naming
the committed revision; publication commits before settlement.

**Lifetime commands.** Only an executor that owns window lifetimes (the owner
loop) performs `closeWindowCommand` and `createWindowCommand`. Others settle
them as `CloseNotPermitted`, `WindowNotServed` or `CreationNotPermitted`.

**Closure.** `closeWindowCommands` ends admission and, in the same
transaction, settles every queued command as `NotExecuted`. A claimed command
settles through its execution. Closure is finite and idempotent; there is no
abort. The pending map holds one cell per queued or active command and nothing
else.

## Window controls

Control commands change an existing window: title, logical size, position,
size constraints (minimum, maximum, optional aspect ratio), show, hide, focus
and attention requests, minimize, maximize, restore. The smart constructors
accept any values; validation happens when the command executes, against the
window's state then.

### Execution

No native call is made until each of these has passed, in order:

1. **Addressing.** `WindowNotServed`, `WindowIsClosing` or `WindowAlreadyEnded`.
2. **Reconciliation.** Pending captures are reconciled, so validation reads
   the owner's latest observation, never one a client holds.
3. **Mode transition.** A window in a transition is
   `ControlRejected ModeTransitionInProgress`.
4. **Presentation.** `ControlIneligibleInMode` or `ControlModeIndeterminate`
   ([by presentation](#ordinary-controls-by-presentation)).
5. **Capability.** An operation the backend cannot perform is `Unsupported`.
6. **Validation**, refusing with a typed `ControlRejection`.

Then the native calls are made, each bracketed by the error capture, and every
attribute is sampled and published as a new revision even when nothing
changed. A control never changes the applied mode or the saved placement.

### Validation

| Control | Refused when |
|---|---|
| Title | It contains a NUL (`ControlTitleRejected`) |
| Size | A dimension is outside `1 .. 2147483647`; the active constraints are indeterminate; or it lies outside the known bounds or does not satisfy the aspect ratio exactly |
| Position | A coordinate is outside the native `int` range |
| Constraints | A bound or ratio term is out of range; minimum exceeds maximum; the current size is unavailable; or they do not admit the currently observed size |

A size outside the constraints is refused, never sent for the platform to
clamp. A window starts unconstrained and fully known.

### Outcomes

An attempted control settles as `Attempted`:

| `attemptedOutcome` | Meaning |
|---|---|
| `ControlReturned` | Every native call returned without a report |
| `ControlNativeError` | A call returned but reported errors |
| `ConstraintUpdateFailed` | A constraint update stopped at a call that reported errors |

None says the window manager honoured the request. `PostCallRevision` names
the revision the post-call sample published; it proves the sample followed the
call, not that the platform converged. A sample that reports errors publishes
nothing and is `PostCallSampleFailed`. A native call that raises, or a
callback fault rethrown at the boundary, settles the command as `Interrupted`.

**Constraint updates.** A set is validated whole and applied as size limits
then aspect ratio. The owner marks the constraint state indeterminate before
the first call and known only once every call returned without a report. A
failure names the calls returned, the call that failed and the calls not
attempted; nothing is rolled back. While indeterminate, every size control is
refused with `ActiveConstraintsIndeterminate`; a constraint update that
completes re-establishes a known state.

### Capabilities and platform restrictions

`sessionWindowCapabilities` and `hostWindowCapabilities` name what the backend
cannot perform or report, each with a reason:

| Backend | Cannot perform | Cannot report |
|---|---|---|
| X11, Cocoa | nothing | nothing |
| Wayland | `SetPositionOperation`, `FocusOperation`, `BorderlessOperation` | `PlacementReport`, `IconifiedReport` |

An unperformable operation is `Unsupported`. An unreportable attribute is
always `Unavailable`: it is not queried and its callback records nothing. The
Wayland row was audited against the pinned GLFW 3.4 source over all thirteen
operations and eight reports, and `Test.GLFW.Control` asserts the enumeration
so an added operation cannot go unaudited. Position (set and report) is GLFW's
own `GLFW_FEATURE_UNAVAILABLE`. The other three are the model's conservative
restrictions: borderless needs the global position; GLFW always answers
iconified `false`, which is not evidence; and GLFW never moves focus itself on
Wayland. On Wayland restore unmaximizes but cannot undo a minimize.

Where a control is performable the platform still decides its result. An X11
window manager applies changes asynchronously, Cocoa's size limits bound only
user resizing, and focus is a request. Compositor suspension and native
drawability are not established through this integration.

## Window modes

`setWindowModeCommand` moves a window between windowed presentation,
borderless placement over a monitor's work area, and fullscreen on a monitor.
The planner (`Hetoimasia.GLFW.Internal.Mode`) is pure; the session holds the
monitor claims.

| Value | Meaning |
|---|---|
| `windowedMode` | Decorated, at the saved windowed placement |
| `borderlessMode monitor` | Undecorated, over the monitor's work area, on no monitor |
| `fullscreenMode monitor preference` | On the monitor, at its current video mode or an exact one it reports |
| `noModeFallback` / `windowedFallback n` | Settle with the failure, or return to windowed at a reachable placement at most `n` times (1 to 4) |
| `startupMode request requirement` | A transition during creation, `ModeRequired` or `ModeOptional` |

### The transition

At an owner boundary, in order:

1. Captures are reconciled; a closing or ended window is refused.
2. A window already in a transition refuses with `TransitionAlreadyInProgress`.
3. The fallback budget and video mode preference are checked.
4. The transition marker is set until the transition settles. While set, every
   control on the window is refused; observation and close commands are not.
5. The monitor inventory is refreshed and the window sampled; its applied mode
   and claims are reconciled with the sample.
6. An inert request settles as `ModeInert` with no native call.
7. Otherwise the target is attempted under the foundation's `recover`, with a
   budget of one attempt plus the fallback's.
8. The window is sampled again, the request and outcome are recorded in the
   mode record, a revision is published, and the command settles as
   `Transitioned`.

A request refused before any native call with no fallback settles as
`Rejected (ModeRejected ...)`, and an unperformable target with no fallback as
`Unsupported`; neither is recorded. A native call that raises, a callback
fault, a refresh failure and cancellation propagate and settle `Interrupted`.

**Validation.** Before any native call an attempt refuses when: the selected
monitor's identity has ended (`ModeMonitorDisconnected`); another window
claims the fullscreen monitor (`MonitorBusy`); the monitor does not report the
preferred mode; its work area is unavailable; a placement is unrepresentable
or none is reachable; the preserved windowed constraints do not admit the
windowed placement (`PlacementExcluded`); or those constraints are
indeterminate (`WindowedConstraintsIndeterminate`). A fullscreen monitor is
reserved last.

**Plans.** Windowed: decorate, place with no monitor, then restore the
preserved constraints if the native ones do not follow them. Borderless: clear
size limits and aspect ratio, undecorate, place at the work area. Fullscreen:
one `glfwSetWindowMonitor`. The plan stops at the first step that reports an
error and settles the attempt as `StoppedPartway`, naming the steps returned,
the failing step and the steps not attempted. Nothing is rolled back.

**Saved placement.** The windowed position and size: seeded from the initial
observation, cached from the observed placement when a transition leaves an
applied windowed presentation (whether the attempt completes, stops partway or
is interrupted), and never overwritten by a return to windowed, a failed
attempt's target or a fallback's derived placement.

**Inert requests.** A request is inert only when it equals the recorded
request completely, its last outcome settled cleanly at the target, and the
applied mode reconciled against the refreshed inventory still matches. A
request after a disconnect, failure or fallback is never inert.

**Applied mode.** Derived from each full sample, never copied from a request:

| Sampled | `AppliedMode` |
|---|---|
| A fullscreen monitor | `AppliedFullscreen monitor` |
| No fullscreen monitor, decorated | `AppliedWindowed` |
| Undecorated, content origin inside a current monitor's work area | `AppliedBorderless monitor` |
| Anything else, or a sample that reported errors | `AppliedIndeterminate` |

### Recovery and fallback

Each attempt is one owned operation under `recover`. A failed attempt is
answered with the windowed fallback, while the budget lasts, when it is a
refusal other than `MonitorBusy` or `TransitionAlreadyInProgress`, an
unsupported target, or a stopped step. Every other failure propagates.

The reachable placement is the saved placement if its origin lies inside a
current monitor's work area; otherwise its size centred in the work area of
the platform's primary monitor, or of the first enumerated monitor with a
nonempty work area. With no saved placement or no such monitor, none is
reachable. The derived placement is never saved.

An attempt that made a native step restores the preserved windowed constraints
of a window it left windowed. A restoration call that reports an error stops
recovery: the transition settles as `ModeRecoveryStopped` and no further
native call is made.

| `ModeOutcome` | Meaning |
|---|---|
| `ModeInert` | Matched the applied mode; no native call |
| `ModeApplied` | The target or fallback attempt completed; earlier failed attempts are listed |
| `ModeFailed` | No attempt completed |
| `ModeRecoveryStopped` | A constraint restoration failed |

A request through a command is optional: exhaustion is data. A `ModeRequired`
startup mode propagates its failure and the window's creation rolls back.

**Monitor disconnects.** After the owner loop refreshes the inventory it
reconciles every window that is not closing. A window whose recovery
obligation names an ended monitor takes its recorded windowed fallback at
once, or with no fallback is resampled once. The obligation is the monitor the
last settled request's sample established the mode on. It survives ordinary
observations taken between the native disconnect and the reconciliation, and
it follows a borderless window legitimately moved between two live monitors.

**Fullscreen claims.** The session holds at most one claim per monitor
identity: reserved, held or uncertain. A fullscreen attempt reserves before
its first native call. After every full sample a window's claims are
reconciled with its observed fullscreen monitor. An attempt interrupted after
a native step makes the window's claims uncertain and its mode indeterminate,
so the owner loop resamples it. A claim on an ended identity is dropped by
every refresh. A window's release drops its claims only when disposal
succeeded; an uncertain claim is never available to another window.
Borderless windows claim nothing.

### Ordinary controls by presentation

| Applied | Refused | Eligible where supported |
|---|---|---|
| Windowed | nothing | Every control |
| Borderless | Size, position, constraints, maximize | Title, show, hide, focus, attention, minimize, restore |
| Fullscreen | Size, position, constraints, show, hide, maximize | Title, focus, attention, minimize, restore |
| Indeterminate | The same, as `ControlModeIndeterminate` | Title, focus, attention, minimize, restore |

A refused control makes no native call, so an ordinary resize never changes a
fullscreen monitor's video mode.

## Input feeds

`Hetoimasia.GLFW.Input` is the consumer's side of a window's ordered input.
The window host creates one feed per window. The feed belongs to the window's
owner, which produces into it, attempts its warning, resumes and closes it.
The one logical consumer holds an `InputReader`; the application holds an
`InputControl`; both come through the `WindowClient`. Copies of a reader are
the same consumer. The Lua engine's input adapter is that consumer for an
input-enabled window
([its contract](../packages/lua-engine-graphics/README.md#the-lua-input-adapter-tra-6)).

**Events.** An `InputEvent` carries its window, its epoch and one payload: a
key, character, button, scroll or focus transition. Epochs start at one and
advance by one per reset. These are never coalesced. Each event is prepared in
the producer's `IO` before admission.

| Phase | Reads answer | Production | Leaves by |
|---|---|---|---|
| `InputRunning` | the next event, or `InputEmpty` | admitted through the gates | overflow or suspension; closure |
| `InputResetPending` | `InputResetRequired token` until acknowledged | suppressed and counted | acknowledgement; closure |
| `InputResetAcknowledged` | `InputPaused` | suppressed and counted | owner resumption into the reserved epoch; closure |
| `InputFeedClosed` | `InputClosed` | refused | never |

**Gates.** Admission starts `AwaitingReadiness` and `enableInput` opens it.
While running, ordinary input is admitted only with admission enabled and the
window focused, and is otherwise counted as gated. A focus transition is
admitted whenever admission is enabled.

**Held state.** Only an admitted press establishes held state. A repeat or
release of anything not held is suppressed as unpaired. An admitted focus
loss, every reset and closure clear the baseline, so each epoch begins with
nothing held.

**Reset.** An overflow (the channel full at admission, or native staging full)
commits one transaction that aborts the channel, records what it discarded,
reserves the next epoch, clears the held baseline and installs a reset with a
token bound to the feed and that epoch. `suspendInput` while running makes the
same transition with reason `AdmissionSuspended`. The consumer clears its
derived state and acknowledges the exact token; the feed replays nothing and
has no timeout that resumes it. `acknowledgeReset` answers
`ForeignResetToken`, `AcknowledgementClosed`, `StaleAcknowledgement`,
`Acknowledged` or `AlreadyAcknowledged`, in that order of precedence.

**Warning.** An overflow episode owes one `Warning` under `glfw.input`,
written by the owner at a safe boundary through the injected logger. A sink
failure or cancellation is recorded and not retried. A suspension owes none.

**Resumption and closure.** The owner installs a fresh channel only if the
same reset is still acknowledged, no warning is owed, the feed is open,
admission is enabled and the window is focused. The window's close protocol
and host quiescence close the feed. Closure is idempotent and ends every read
and wait at once, even during a reset.

## The window host and owner loop

`Hetoimasia.Runtime.GLFW` composes a session, its windows and their command
bookkeeping with the runtime's
[application lifecycle](resources.md#the-application-runner). It takes no
logger of its own; the loop writes its two warnings through the logger the
application injects on the loop hooks.

### Construction and ownership

A `WindowHost` is an application dependency, built as a `Scoped` value on the
process main thread before supervision is entered. `allocWindowHost`:

1. validates its `HostConfig`: budgets at least one; an idle wait above zero
   and at most 60 seconds; a window limit of at least one, at least the number
   of configured windows and at most `maximumWindowLimit`; an input capacity
   in the channel's range;
2. enters the session and allocates a scoped collection with that limit;
3. creates the host's command port;
4. creates each configured window in order as a collection member, with its
   own port, input feed and demand slot.

A failure at any stage releases what earlier stages acquired, before any
worker exists. Startup receives the host among the dependencies and hands
workers only client capabilities (the host port, a window's `WindowClient`,
the monitor reader, `hostActivity`); no native ownership is transferred.
`allocWindowHostIn` builds the same host over a session scope the caller
supplies, and the host then owns the session only if that scope does.

No session, collection, member, command host, native handle or release
authority can be taken from a `WindowHost`. `withHostWindow` lends one window
to an owner-thread callback it must not escape.

`withProtectedWindowHost` and `withProtectedWindowHostIn` build the same host
and additionally give it window-attachment retirement state under a host
identity only they issue
([The protected host lifetime](#the-protected-host-lifetime)). A host built
any other way can never be the target of an attachment.

### Dynamic windows

Windows are created and closed while the application runs, in any order. The
collection owns every window until it is retired or the host's scope ends.

**Creation.** A `createWindowCommand` through `hostCommandPort`, the one port
with creation authority, is executed by the owner loop. Before any native
effect it checks the configuration (`WindowConfigInvalid`), the live-window
limit (`WindowCapacityReached`, a rejection rather than a wait) and whether a
release failure has poisoned creation (`WindowCreationPoisoned`). The window
is acquired as a collection member and registered with nothing interruptible
in between.

- A native failure whose construction rolled back cleanly is
  `WindowCreationFailed`: nothing is registered and no capacity is consumed.
- A rollback whose own release failed is never downgraded to a rejection: the
  construction failure propagates as the host's primary failure, the ticket
  settles `Interrupted`, the loop stops, and the latch poisons later creation.
- A dropped creation ticket neither destroys nor relinquishes its window.
  `hostWindowIdentities` enumerates every held window and `hostWindowClient`
  returns the capabilities of any of them.

**The close protocol.** A `closeWindowCommand`, `closeHostWindow` on the owner
thread, and `honourHostCloseRequest` for a request that is still its window's
latest all begin the same protocol:

1. The closing observation is prepared. A cancellation here leaves the window
   open.
2. In one transaction the window is marked closing, its port's admission
   closes, its queued commands settle as `NotExecuted`, its feed and demand
   slot close, its attachment (on a protected host) stops admitting graphics
   use and begins retiring, and its observations publish `WindowClosing`. The
   transaction and the owner's record of the observation run masked.
3. Once no owner-thread borrow is in progress and, on a protected host, the
   attachment has retired, the window is retired through the collection.

A close command settles as `WindowCloseBegun` once step 2 commits. Disposal is
reported by the window's observations, never by the ticket. Beginning the
protocol again answers `CloseAlreadyStarted` (`WindowIsClosing` for a
command); a window no longer held answers `CloseNotServed` or
`WindowNotServed`. Closing a window stops neither the session, the loop, nor
any other window.

Retirement never waits: every turn retries it after native event processing
when no borrow is in progress. Retaining a client port is not a borrow. A
retirement whose release fails is not retried: the window is forgotten with
its failed phase and the collection latches the failure, poisoning creation
and keeping it as evidence for its final exit. Unlike a failed construction
rollback, a retirement failure is non-fatal.

After retirement, the window's port answers `SubmitClosed`, `withHostWindow`
answers `WindowEnded`, and its observation reader keeps the terminal
observation. All host bookkeeping is proportional to live windows
(`hostBookkeeping`).

### The owner turn

`runOwnerLoop` runs on the session's owner thread and refuses any other.
Each turn, in order:

1. `checkRuntime`;
2. native events: `glfwPollEvents`, or on an idle turn
   `glfwWaitEventsTimeout` with the configured bound;
3. reconciliation: the monitor inventory if its callback captured a change;
   retirement of every closing window no borrow defers; every window's
   captured callbacks, collecting unsurfaced close requests; visible
   follow-ups; each feed's overflow warning and resumption;
4. `checkRuntime`;
5. command work: at most `hostCommandBudget` commands across every port, then
   warning and resumption again;
6. `checkRuntime`;
7. application events: at most `hostEventBudget` calls of `loopEvent` that
   dispatched something;
8. `checkRuntime`;
9. `loopUpdate` with the turn's `Turn` summary, answering `Continue` or
   `Finish`;
10. `checkRuntime`.

A supervised failure latched at any point is rethrown by the next check. A
native failure, a callback fault, a command's rethrown interruption or a
hook's failure ends the loop and propagates.

**Budgets** count attempted dispatches, not time. A rejected command costs its
attempt. At most `max hostCommandBudget hostEventBudget` attempts separate two
consecutive checks. Long work belongs in a worker.

### Fair dispatch

Command work draws from the host's port and the port of every window that is
not closing, in cyclic order starting after the port served last.

- Commands of one port run in the order their admissions committed. Nothing
  orders commands across ports.
- No port is attempted twice while another port with a queued command waits.
- With `P` ports and budget `B`, a command at position `k` of its port's queue
  is attempted within `⌈k · P / B⌉` turns. This is a bound in turns, not a
  deadline.

The scheduler's only state is the cursor.

### Idle waits

A turn is idle when the previous turn attempted no command and dispatched no
application event, no command is queued, and no attachment retirement wants an
immediate opportunity. Active turns poll. Idle turns wait at most
`hostIdleWait` seconds; no wait is indefinite.

A wait ends early when an admission or a demand publication wakes the owner,
and that turn then serves it. Wakes may coalesce or be spurious; the queue and
the slots are authoritative. `hostIdleWait` remains the fallback bound,
including after the wake path has degraded. Native waits are safe foreign
calls, so workers run meanwhile. `hostActivity` publishes the current turn and
whether its wait has begun.

### The scheduled owner turn

`runScheduledOwnerLoop` is a second entry point for an application that paces
itself by absolute deadlines; `runOwnerLoop` is unchanged by it. Time enters
only through the injected `hostClock`. The loop reads no wall clock, starts no
timer thread and never sleeps.

Each scheduled turn:

1. `checkRuntime`;
2. **inspection**: one clock sample, then in one transaction the capture of
   the application's pending demand and the queued command count, then
   `scheduledReady`;
3. **choice**: anything ready (a command, an event, immediate demand) polls;
   otherwise a deadline already reached polls; otherwise the turn waits the
   shorter of the time to the earliest deadline and `hostIdleWait`. A deadline
   can only shorten a wait;
4. the native step;
5. **resample**: one more clock sample, which is the instant the update sees;
6. steps 3 to 8 of the owner turn, unchanged;
7. `scheduledUpdate`, once, with the `ScheduledTurn`;
8. `checkRuntime`.

- A turn reads the clock exactly twice. Deadlines stay absolute, so time a
  turn's own work consumed shortens the next wait.
- The schedule is what `scheduledUpdate` last answered and is never combined
  with an earlier answer. The captured request is consumed by the turn that
  captured it, so an old request never becomes permanent work.
- `scheduledReady` is inspected, not dispatched, and spends no event budget.
  A worker that needs prompt service publishes demand.
- Budgets, checkpoints, fair dispatch, retirement, close surfacing, feed
  recovery, quiescence and failure propagation are the unscheduled loop's.
- A wait under one whole nanosecond is refused by `validateHostConfig`.

### Render demand

`renderTurn` is a pure function that composes the application's simulation
demand with each window's demand and decides which windows are offered a
render opportunity this turn and what schedule the loop continues with. The
caller threads a `RenderDemand` value from turn to turn and passes the sampled
instant in. It reads no clock, makes no native call, performs no drawing and
infers no device readiness; a backend adds its own presentation accounting.

**Eligibility** reads one `WindowObservation`, in this precedence:

1. `WindowClosing` or terminal: `RenderExcluded`, and its state is removed;
2. a known suspending condition (`Observed False` visible, `Observed True`
   iconified, or a zero framebuffer dimension): `RenderSuspended`;
3. an `Unavailable` framebuffer extent: `RenderDeferred`;
4. otherwise `RenderEligible`.

An `Unavailable` visible or iconified field asserts nothing.

- A capture's immediate demand coalesces into one pending redraw, and its
  deadline is kept as the earliest pending deadline. An absolute frame
  deadline never implies a period.
- A suspended or deferred window keeps its demand and contributes nothing to
  the reported deadline. Leaving suspension owes exactly one current frame
  (`windowResumeDue`), held apart from the caller's frame schedule; nothing
  missed is replayed.
- Simulation demand is carried independently. A focus or visibility change is
  never a pause, and simulation demand never marks a window dirty.
- At most `renderBudgetSize` offers per turn, each window at most once, in
  identity order starting after the window served last. `n` eligible pending
  windows with budget `b` are each offered within `⌈n / b⌉` turns.
- `acknowledgeRender` records the revision an offer served. A newer
  publication stays pending, and a frame obligation is cleared only when it is
  still the one the offer carried.
- A window left out of `renderLive`, or observed in any phase but
  `WindowOpen`, is removed.

`Test.GLFW.Render`'s composition example is the reference composition.

### Demand slots

A worker that wants a turn publishes a `DemandRequest` through a
`DemandPublisher`: the application's (`hostDemandPublisher`) or a window's.
`publishDemand` combines the request into the slot, advances its revision, and
only then wakes the owner. There is one slot for the application and one per
live window, never one per worker or request.

- Requests combine as a monoid: immediate if any asked, and the earliest
  deadline. A later request never postpones an earlier deadline, and
  `noDemand` cancels nothing.
- Capture (`captureHostDemand`, `captureWindowDemand`, owner thread) takes the
  pending request with its revision and clears exactly what it took. A later
  publication stays pending.
- A slot holds a request, not a schedule.
- A publication has the same cancellation protection as a command admission.
- A closed slot answers `DemandSlotClosed` and makes no native call.

Deadlines are opaque `Instant` values in the publisher's clock domain.

### Close requests in the owner loop

After reconciliation, a close request the host has not surfaced appears once
in `turnCloseRequests`. The application decides: `rejectHostCloseRequest`
clears it while it is still the latest; `honourHostCloseRequest` begins the
close protocol while it is still the latest (`CloseRequestSuperseded`
otherwise); leaving it latched is also a decision. The loop ends only when the
update answers `Finish`. The host supplies no default that finishes on or
honours a close request.

### Quiescence and shutdown order

`quiesceWindowHost` is the host's quiescence action; `runWindowApplication`
installs it. In one finite transaction it closes the admission of every port,
settles every queued command as `NotExecuted`, closes every input feed and
every demand slot, and on a protected host ends new graphics use and starts
every attachment retiring. It destroys nothing, pumps nothing, waits on
nothing, and is idempotent. Wake support stays usable.

On every exit from the supervised region:

1. quiescence;
2. supervision stops and drains every worker, with every window still live;
3. the wake path's one guarded reporting attempt;
4. the dependency scope unwinds: the collection's final exit releases each
   remaining window exactly once, newest first, keeping every cleanup failure,
   then the session ends if the host owns it;
5. the terminal report, if the run failed, and the final flush.

A window whose creation was claimed before quiescence and finished after it is
registered already closed. A window whose earlier retirement failed is not
released again.

### The protected host lifetime

`withProtectedWindowHost` has the shape
[`runManagedApplication`](resources.md#managed-dependency-lifetimes) accepts,
and `runProtectedWindowApplication` is `runWindowApplication` over it. It
invokes its consumer exactly once, synchronously, with every dependency live.
Its exit handler is installed under masking before the scope is entered, so it
covers the handoff into the consumer as well as everything the consumer does.

On every exit (normal return, action, startup, construction or owner-loop
failure, a latched supervised failure, cancellation) the boundary:

1. runs `quiesceWindowHost`, even when the application installed no
   quiescence hook;
2. retires every remaining attachment on the owner thread, with every window,
   the session and every parent still live;
3. makes the wake path's one guarded degradation report;
4. returns. Only then do windows, session and parents unwind in dependency
   order, followed by the terminal report and final flush.

**The retirement round.** Retirement runs on the owner thread and calls no
application hook and no supervisor checkpoint. One round:

1. takes and folds every completion notice another thread published;
2. gives every pending attachment that still has a progress path one bounded
   opportunity, in registration order;
3. offers retirement again to every window whose close protocol has begun;
4. runs native event processing: a poll if the round made progress, otherwise
   the host's finite wait.

The round repeats until no attachment is pending. An attachment is pending
until the model records every one of its retirement facts. No elapsed time,
cancellation, failure or disposition substitutes for a fact.

- Another thread publishes a certified fact as a bounded completion notice
  with the same wake accounting as an admission. Publication closes in the
  transaction that first finds nothing pending.
- Only a fact that recorded new evidence counts as progress and revives a
  withdrawn path. A refusal or duplicate establishes nothing.
- A failed or interrupted step keeps its failure on the attachment, withdraws
  that attachment's progress path, and never marks it safe. The step is not
  run again.

**Outcome.** The initiating outcome is recorded before any drain work. A body
failure stays primary, and drain failures are retained beside it under
`glfw protected retirement` in the order found, up to a bound beyond which
they are counted. After a successful body the first drain failure becomes
primary.

**Cancellation.** A cancellation delivered during the drain is deferred,
establishes no fact, and is re-raised only once retirement is safe, never
before a window, the session or a parent is released.

**Stalls.** The [required and optional policy](recovery.md) decides the
application's disposition only; no disposition authorizes destroying an unsafe
dependent. As soon as any pending attachment has no path left, the boundary
keeps the affected chain, writes one warning under `glfw.retirement` (stalled
count, pending count, the wait bound) and keeps waiting. That diagnostic is
claimed once and its own failure is retained with the runtime's
`DiagnosticFailure` mark rather than raised. There is no retirement timeout;
operator process termination is the escape.

**The private seam.** `attachHostWindow` and its siblings stay in
`runtime-glfw-core` for the package's own examples; the public contract below
is the same reservation, ordering and model. An attachment reserves its
window, registers its protocol, constructs, and only then publishes, so a
cancellation at any handoff leaves it registered and retiring. The protocol's
declarations are demanded inside the attach call's own exception boundary
(`AttachmentMetadataRejected`, with nothing acquired). A rollback that raises
or is cancelled is recorded as unsafe: the attachment is retained owing every
fact.

### The public attachment contract

One window may have one exclusive graphics owner. `attachWindowGraphics` is
the whole way in and exists only for a host built by the protected lifetime.
Nothing here creates a surface, submits GPU work or waits on a device.
Evidence that GPU work completed is the backend's own, supplied through the
facts its owner certifies.

#### Attaching

`attachWindowGraphics host window owner` runs on the owner thread and takes
the caller's `AttachmentProtocol`: how to construct the dependents, how to
roll a failed construction back, one bounded retirement step, the
`CompletionPolicy`, how a failed step is classified, and what to do before the
window is hidden. The boundary supplies exclusivity, ordering and the
retirement rule.

Every callback runs on the owner thread, outside every transaction, native
callback and release. It may do finite, nonblocking native and backend work.
It may not wait on a GPU or a worker or pump native events. The one exception
is `protocolBeforeHide`, which may wait for the graphics owner's step in
flight. GPU effects and graphics-owned disposal execute on the graphics owner,
not in a callback.

Every refusal is answered before any acquisition effect:

| Answer | Meaning |
|---|---|
| `GraphicsRefused (GraphicsWindowClosing w)` | The window's close protocol has begun |
| `GraphicsRefused (GraphicsWindowUnavailable w)` | This host holds no such open window |
| `GraphicsRefused (GraphicsWindowOccupied a)` | Another owner holds the slot until it has safely retired |
| `GraphicsRefused GraphicsForeignSession` | The window belongs to another session |
| `GraphicsRefused GraphicsAdmissionEnded` | Attachment admission has closed |
| `GraphicsMetadataRejected r` | A declaration the protocol carries raised when demanded |
| `GraphicsHostUnprotected` | The host owns no retirement state |

On success the application receives a `GraphicsService` and nothing else. It
exposes the attachment's identity, incarnation, window identity and
observation, and carries no native pointer and no authority to destroy,
release or certify. It is published only after construction and registration
have both completed.

- A failed construction runs the caller's rollback and answers
  `GraphicsRolledBack`. A safe rollback retires the attachment and frees the
  slot. One that could not establish safety retains the attachment, its window
  and slot until each retirement fact is certified.
- A reservation that retirement already began on before its service would be
  published answers `GraphicsSuperseded`; its dependents stay registered for
  retirement.
- One protected region covers reservation, construction and publication. An
  interruption after the attachment became active begins the retirement a
  detach begins. `windowGraphicsService` hands the same service back by
  window, so an attachment is never unreachable.

#### Observing the slot

`windowGraphicsStatus host window` reads a slot in one transaction from any
thread: `GraphicsAbsent`, `GraphicsWindowUnknown`, or `GraphicsPresent` with
an observation. `readGraphicsService` reads the same from a retained service.
An observation names the incarnation, whether the slot is `SlotAttached`,
`SlotRetiring` or `SlotFree`, which
[retirement facts](#retirement-facts) are missing, and the window's native
disposal: `DisposalPending`, `DisposalCompleted` or `DisposalFailed`.

- Disposal is distinct from retirement. A retired attachment stops vetoing
  destruction; the close protocol and borrows decide when it happens. A failed
  native release is never reported as a destruction.
- A close or quiescence is readable from the retained service in the
  transaction that commits it.
- A retained service keeps answering after the host forgot its window. The
  host keeps at most one cell per held window, so repeated detach and reattach
  grows no history.

`hostPendingAttachments` lists the attachments the host still holds.

#### Close and detach

On an accepted close, the transaction that marks the window closing also ends
the attachment's admission of new use. Native destruction happens only once
the model records the attachment retired and the borrow rule is satisfied.

`detachWindowGraphics host service` retires the current owner while its window
stays open, through the same protocol. A later attachment gets a fresh
incarnation, against which the earlier owner's acknowledgement is refused.
Detaching a retired or retiring owner answers `DetachAbsent` or
`DetachAlreadyRetiring`.

#### Hiding an attached window

A hide's native call can unmap the window's surface, and a compositor need not
answer a presentation made for a surface it no longer shows (on Wayland with
Weston 13, Mesa's FIFO present then waits with no timeout). So before a hide's
native call the host runs `protocolBeforeHide` of the attachment holding the
window's slot, whatever its phase. It returns once the owner will present to
the window no more until an observation newer than the one already published
arrives, and answers the action that lifts the hold.

- A hide that made its native call keeps the hold until the hidden window's
  observation is folded. A hide that made no native call lifts it at once.
- Both routes take the hold: the host's ports, and a window lent by
  `withHostWindow`, which carries a hide guard that runs after every check and
  immediately before the native call.
- The graphics owner implements it as a presentation hold bound to the
  published observation revision. The main thread waits only while a step in
  flight may present to that target (one constructed and `RenderEligible`),
  and for one step at most. Later steps view the target as `RenderSuspended`
  until they fold a newer observation, and carry its withdrawal count
  (`viewWithdrawals`). A backend that sees the count rise must not present
  again to anything the target presented to before the hide.
- Minimizing, and anything the platform does on its own, is not held.

#### Progress and scheduling

Retirement runs while the application runs. Each owner turn offers at most
`hostRetirementBudget` opportunities, rotating across the attachments that
have begun retiring. One window's pending retirement never blocks another
window's commands, close, attachment or retirement.

- Each opportunity advances, keeps its path (`RetirementAwaiting`, or
  `RetirementAwaitingUntil` an absolute instant), or withdraws it
  (`RetirementStalled`). A withdrawn path is never replayed; only new evidence
  revives it, whether certified on the owner thread (`certifyGraphicsFact`) or
  folded from a notice.
- `hostRetirementDemand` publishes what the last round left owed: pending,
  stalled and refused counts, whether another opportunity is wanted at once,
  and the earliest instant any waiting attachment named.
- Another opportunity is wanted at once when a round advanced something, or
  an attachment is owed one it has not had (a retirement just begun, or a path
  just revived). Attachments that have all been inspected and are waiting owe
  nothing, so a set larger than the budget is an ordinary idle host.
- The scheduled loop reads the demand in its inspection: a retirement instant
  shortens the wait like an application deadline. The unscheduled loop does
  not wait when a retirement wants an opportunity now.
- An owner whose `CompletionPolicy` is `BlockingCompletion` is refused every
  opportunity before its step runs, and its path is withdrawn. Finite,
  nonblocking progress is otherwise the trusted backend's own contract.
- A declaration that fails when re-read is recorded as that attachment's
  evidence and withdraws its path. It certifies nothing and authorizes
  destroying nothing.

#### Authority and races

Only the owner thread advances, completes or removes an attachment;
`attachWindowGraphics`, `detachWindowGraphics` and `certifyGraphicsFact`
refuse any other thread. Other threads read state and publish bounded
completion notices through `hostGraphicsPublisher`. A notice carries no
authority: it is revalidated on the owner thread, and the inbox holds one
notice per fact per window.

Whatever the interleaving of a close, a detach, a published completion and a
new attachment:

- no new use begins after closing is observable;
- no second owner attaches before the slot is safely free;
- no completion is credited to the wrong incarnation;
- every construction begun is either registered or fully rolled back with its
  evidence.

### The supervised graphics owner

`withGraphicsOwnerHost` (and `withGraphicsOwnerHostIn`, with the runner
`runGraphicsOwnerApplication`) builds the same protected host and additionally
starts one supervised graphics owner: a foundation worker that owns a
rendering backend's targets and shared state, so rendering runs off the
process main thread while GLFW stays on it. A Cocoa live resize or menu
interaction blocks the owner turn's native event call for as long as it lasts,
so rendering from the owner turn would freeze the surface for the whole
interaction. An application that never asks for an owner never has one. The
Vulkan integration composes this with the scheduled owner turn
([gpu_backend.md](gpu_backend.md#the-composed-loop)).

**The owner performs no GLFW operation.** It enters no session, creates no
window or surface, processes no event and issues no window command. The one
thing it reaches across is the session's cross-thread wake, through
`publishCompletion` and `wakeGraphicsHost`.

#### The injected operations

`GraphicsOperations` is everything the owner can ask a backend to do:

| Operation | What it settles |
|---|---|
| `graphicsStartOwner` | Establish the owner's shared state, before any target exists |
| `graphicsConstructTarget` | Construct one attachment's target |
| `graphicsStep` | One bounded progress step that returns finitely and says whether more work is owed at once |
| `graphicsNextDeadline` | The earliest instant the backend next wants a round, or none |
| `graphicsWake` | Whether something the backend watches asks for a round now |
| `graphicsPrepareRetirement` | Begin retiring one target: `RetirementReady` or `RetirementOwed`. Scheduling, never evidence |
| `graphicsRetireTarget` | Retire one target, once preparation answered ready |
| `graphicsRetireOwner` | Retire the owner itself |
| `graphicsDestroyOwner` | Release the owner's shared state |

There is no recording, submission or resource API in it and no GLFW
capability. A target is named by its `AttachmentId` and `WindowId`. Every
operation returns evidence: an opaque record the owner stores and hands back
and never constructs or interprets. What draws is the backend's renderer,
called inside its own step.

#### The handoffs

| What | Direction | Transport |
|---|---|---|
| Attachment lifetime | main → owner | one bounded port |
| `WindowObservation` and render eligibility | main → owner | one latest-value snapshot per target |
| Render demand | main → owner | one latest-value snapshot |
| Scene | any application thread → owner | one snapshot, or one per window (`ownerSceneMode`) |
| Progress and next deadline | owner → main | one coalescing status cell |
| Retirement facts | owner → main | the host's completion publisher, with bounded per-target terminal records |

- A handover holds room on the lifetime port before it reserves the window's
  slot, so a full port answers `HandoverPortFull` with nothing attached. Only
  lifetime events ride that port, so a full one cannot keep the owner from
  being stopped, publishing terminal evidence or progressing.
- Every step from holding that room to spending it runs masked. A cancelled
  handover whose attachment was established is still announced, so no
  attachment exists that the owner never hears of.
- Snapshots hold one value: a publisher never waits. A target's observation
  revisions must strictly increase (`ObservationStale` otherwise), and a
  publication for an incarnation the slot moved past answers
  `ObservationUnknownTarget`.
- Quiescence, and any failure that ends the owner's run, closes the port,
  both snapshots and every observation slot together, so a retained endpoint
  is refused rather than silently ignored.

`handOverGraphicsTarget` reserves a window's slot on the main thread,
registers the attachment, tells the owner and answers the `GraphicsService`.
`publishGraphicsObservation` publishes the target's observations and
`releaseGraphicsTarget` retires it. A release answers `ReleaseBegun`,
`ReleaseSettled` (the owner was never told; facts certified on the spot),
`ReleaseOwnerRetires` (the owner owes it and its drain will produce the
evidence), `ReleaseNoOp` or `ReleasePortFull`.

The owner keeps what a construction left until the backend accepts the target
or verifies its own rollback. A partial, failed or cancelled construction is
reported unusable through `readTargetStanding`, and the main thread releases
it. Beginning a retirement is always the main thread's. The owner also reads
the host's model each round and marks every target whose attachment has begun
retiring, so a window closed through its own port is retired without a
detach.

#### Who owes an attachment's settlement

One ledger entry per registered attachment answers who owes that
incarnation's retirement evidence:

| Stage | Who owes it | Reached by |
|---|---|---|
| `CustodyRegistered` | The main thread | The protocol recording its acknowledgement |
| `CustodySettling` | The main thread | Claiming the settlement, while it is performed |
| `CustodyAnnounced` | The owner | An announcement admitted to the lifetime port |
| `CustodyOwned` | The owner | The owner taking that event |
| `CustodySettled` | Nobody | A terminal record the owner wrote, or facts the main thread certified |

- The main thread may settle only from `CustodyRegistered`, and its claim
  excludes an announcement. Absence from the owner's target table is never
  consulted.
- A claim that could not certify every fact returns to `CustodyRegistered`.
- An announcement is admitted in one transaction that checks the stage,
  confirms the host still holds that attachment pending, installs the
  observation slot and queues the event.
- `CustodySettled` is terminal.

The ledger is bounded by the windows the host may hold live.

#### A scene for each window

`ownerSceneMode` chooses once between one scene for every target
(`SharedScene`, the default) and one per window (`PerWindowScenes`). Per-window
publications are keyed by `WindowId`, never by attachment, so a recreated
surface takes the window's existing publication. `publishGraphicsWindowScene`
publishes from any thread in one transaction that never waits:

| Answer | Meaning |
|---|---|
| `WindowScenePublished window revision` | Accepted, at this per-window revision |
| `WindowSceneUnknown window` | The host holds no such window |
| `WindowSceneClosed window` | The owner's publications have closed |
| `WindowScenesNotEnabled window` | The owner carries one shared scene |

`publishOwnerScene` is refused in per-window mode. The table is bounded by the
host's windows. What a backend does with a window's scene is the backend's
([gpu_backend.md](gpu_backend.md#a-scene-for-each-window)).

#### Scheduling, stalls and extent

- Each step is handed the latest demand and scene with each one's publication
  revision; two publications of equal demand are two requests.
  `readOwnerDemandTaken` tells a publisher whether the owner has taken its
  latest.
- The owner schedules its own waits on the injected `hostClock` and
  `OwnerTimer`, handing the timer an absolute deadline. It wakes for a stop, a
  terminal failure, a lifetime event, a fresher observation, new demand or
  scene, or its deadline. It never depends on the main thread to wake it.
- A released target's retirement is performed only once preparation answers
  ready; until then it is asked again on later rounds and in the exit drain.
  No timeout ends that wait, because a timeout is not evidence.
- During a main-thread stall (a live resize, an open menu) the owner keeps
  rendering the latest scene and last coherent observation. Window commands,
  fresh observations and anything the application drives from the main loop
  still wait for the pump. Whether a presented frame becomes visible during
  the stall is the platform's.
- `chooseTargetExtent` decides in this order: render eligibility, then zero
  area, then the clamp to reported bounds, so clamping can never resume a
  suspended target. With no observation the answer is
  `ExtentWithheld ExtentUnobserved`.

#### The exit, which is D-33's

1. Quiescence closes the host's admission and the owner's publications in one
   transaction. It stops, retires and joins nothing.
2. Ordinary application workers stop and drain. The owner's worker group is
   separate, so that drain does not end it.
3. The owner drains its lifetime port, retires each target it holds and then
   itself through the injected operations, publishing each certified fact.
4. The main-thread boundary services the host's bounded native housekeeping
   while it awaits verified retirement, validating each attachment's terminal
   evidence.
5. Once the injected whole-owner destruction has returned its evidence, and
   only then, the boundary joins the owner.
6. The host's windows, session and parents unwind.

Step 4's wait returns for the evidence and nothing else: not the owner's run
ending, not an empty target set. An owner that ended without the evidence
retains the windows, session and parents and says so once through
`OwnerDestructionUnverified` under `glfw.graphics-owner`. After that only
independent evidence (`publishOwnerDestruction`) or operator process
termination ends the wait.

The one owner not waited for is a start abandoned before its run action began:
the starter withdraws it from the exit in one transaction that reads the
worker terminal and `ownerEntered` unset. An owner whose run action began is
never withdrawn.

Whole-owner retirement is independent of the attachment count: it runs for an
owner that never held a target and after the last one detached. A single
`releaseGraphicsTarget` retires one target and leaves the owner and every
other target live.

#### Failure and cancellation

- The owner is required: a terminal failure is latched at once, closes every
  admission into the handoff in the same transaction, ends the run and enters
  the protected drain. `superviseGraphicsOwner` registers a supervised service
  that raises the latched failure at the application's checkpoint.
- The latch is notification, not evidence. Failures the owner survived (a
  target's construction or retirement) are kept in `readOwnerFailures`; a
  failure that ended the run, its drain's failures and a failing final wake
  are in the worker's outcome. Each failure is reported exactly once: the exit
  leaves out the one entry the sentinel already delivered.
- A failed target retirement is marked unverified and never offered again.
- Cancellation is honoured at every owner wait and is not latched. The drain
  defers it and re-raises it only after every owed operation has been offered:
  every target, then the owner, then its destruction.
- A cancellation that escapes an injected operation leaves its outcome
  unknown: a construction settles unverified, a target retirement manufactures
  no acknowledgement, a destruction establishes nothing.
- Each injected operation is interruptible across the call and masked from
  its answer through the state that answer settles.

Nothing but the injected evidence is permission: not the owner's completion,
an empty target set, a cancellation, a timeout or a cleanup failure.

### What the owner and workers may wait on

No public owner-thread operation blocks on work only the owner turn can do
(`OwnerThreadWouldWait`). A worker's startup and cleanup must not require a
command's completion, because the owner may be starting or draining that
worker. A worker's run action may submit commands and compose the wait with
its stop request (`pollCompletion` with `awaitStopRequest` in one
transaction). `publishDemand` never blocks.

## Window attachments

The private `Hetoimasia.GLFW.Internal.Attachment` models a graphics
integration's dependency on a window: which window, where the attachment is in
its lifetime, what evidence retires it, and whether it still vetoes the
window's destruction. It is a pure state machine with bounded bookkeeping and
one bounded notice inbox. It names no Vulkan, native or GPU type and is not
public; [the public attachment contract](#the-public-attachment-contract) is
this model under the protected host boundary.

**Identity.** An attachment identity binds the host, the session, the
`WindowId` and an incarnation that is never reissued. Every operation carrying
authority compares all four, and a mismatch is typed misuse that changes
nothing.

| From | To | By |
|---|---|---|
| none | registering | attaching reserves an open, unoccupied window of this host and session |
| registering | active | construction succeeds |
| registering | retiring | detach, cancellation, the window beginning to close, or construction failing |
| active | retiring | detach, cancellation, or the window beginning to close |
| retiring | retired | the last missing retirement fact is recorded |

Retirement once begun is never undone. While construction is pending no
retirement fact is accepted. Failure evidence is stored beside the phase,
never as one: the first failure is kept and later ones counted. A safe
rollback establishes every fact; an unsafe one records none.

### Retirement facts

| Fact | Certifies |
|---|---|
| CPU use retired | No retained capability or pending producer can submit another use |
| Submitted work ended | Work already submitted has completed |
| Presentation ended | Presentation obligations have ended |
| Dependents disposed | Dependent resources are disposed |

None is accepted before retirement begins. An attachment is retired, and stops
vetoing its window, only when all four are recorded. No single fact, elapsed
time, cancellation, body return or failure stands in for another. A window
with no veto still needs the close protocol and no borrows to be destroyed.

**Acknowledgements.** Attaching returns an acknowledgement bound to the
incarnation, which every transition takes with the target identity. It
prevents cross-window and cross-incarnation misuse; it is not proof a backend
finished. A report for a replaced incarnation is misuse, ahead of terminal
idempotence. A report for an absent (retired) target is accepted and changes
nothing. Recording the same fact twice is idempotent.

**Notices.** Another thread never changes the model. It offers a completion
notice to a bounded inbox that never waits and answers admitted, coalesced or
rejected. The owner folds notices, revalidating each as a direct report.

**Bookkeeping.** One record per registered window, at most one attachment per
record. Stale identities are rejected by comparing against counters, never by
remembering them.

## Vulkan interop

`hetoimasia-glfw:vulkan-interop` is the only GLFW component that includes the
Vulkan headers. Its header names no Vulkan or GLFW type: an instance is an
untyped pointer and a surface a `Word64` (the source statically asserts
`VkSurfaceKHR` is 64 bits). Every import is `safe`. The component is gated by
the manual `vulkan-interop` flag, off by default; only `cabal.project.vulkan`
sets it, and the workflow suite checks that. It depends on no GPU package.

### The loader integration capability

`allocLoaderIntegration` builds an opaque, single-use capability from the
loader entry point the Vulkan binding dispatches through. A session takes it
through `allocIntegratedSession`, the additive constructor beside
`allocSession`. During session construction the capability is:

1. **admitted** after the guard is claimed and before the first native call:
   `IntegrationStale`, `IntegrationForeign` or `IntegrationAlreadyUsed` refuse
   before any native effect;
2. **installed** after the init hints and before `glfwInit`, as GLFW's
   pre-init loader hint;
3. **reset** by its own release, after termination, to GLFW's default loader
   search, on every path.

When the reset raises, or termination could not be established, the capability
is retained as `IntegrationUncertain` and the guard is poisoned. A window-only
session makes no loader call.

`requiredInstanceExtensions` is an owner operation. A window-only session is
refused with `SessionNotLoaderAware`; no loader is `VulkanUnsupported`. Every
name is copied into Haskell-owned storage before the query returns.

### The surface bridge

A surface may be created only through a `SurfaceAccess`, which is open only
while one of two things runs on the owner thread: the construction step of an
attachment made by `attachWindowGraphicsWithSurfaces`, or an admitted
`replaceWindowSurface` on that attachment while it is active and its window is
not closing. Every other request is a `SurfaceRefusal` before any native
effect.

The instance's owner leases it with `leaseSurfaceInstance`. Admission and
reservation are one transaction. The native call runs with asynchronous
exceptions held off and its result is always recorded:

| What the native call did | What the caller receives | Holds |
|---|---|---|
| Created a surface, nothing changed, nothing reported | `SurfaceCreated` with its one `SurfaceObligation` | Attachment and lease |
| Created a surface, but the window began closing, the attachment began retiring, the step ended, or GLFW reported errors | `SurfaceUnpublished`: the obligation alone; the surface must not be used | Attachment and lease |
| Returned a failing `VkResult` | `SurfaceCreationFailed` with it and GLFW's reports | Released |
| Raised before any native result | That exception | Released |

- A caller that loses the answer to a cancellation has not lost the surface:
  every undischarged obligation stays listed on its lease
  (`leasedObligations`).
- `dischargeSurfaceObligation` destroys the surface through the capability's
  `vkDestroySurfaceKHR`, from whichever thread holds the obligation, once. A
  destruction that raised is `DestructionUncertain`, keeps both holds for
  good, and is never retried.
- While any surface construction or undischarged obligation holds an
  attachment, the retirement boundary refuses its `DependentsDisposed` fact
  and treats a `RollbackSafe` as unsafe.
- `releaseSurfaceInstance` answers `InstanceReleasable` only when nothing is
  in flight or owed; until then the instance must not be destroyed.

Native evidence is the Vulkan native suite's `vk5-bridge` case
([gpu_backend.md](gpu_backend.md#the-native-suite)).

## State

None of this is application state. Each owner constructs, mutates and tears
down its own state; the owning modules' Haddock has the per-cell detail.

| State | Owner | Writers and readers | Lifetime and disposal |
|---|---|---|---|
| Guard occupancy and poison | The native table, process-wide | Entry claims; the last release settles | The process. Vacant after a safe teardown, poisoned otherwise |
| Error capture, callback storage, teardown safety, liveness | The session | Callback writes (any thread); owner operations and releases take | Until the callback is detached. Storage leaked when poisoned |
| Wake gate, wake-path degradation, notification obligations | The session | Any thread, in `STM` | Gate closed at first release and never reopened; degradation never healed within a session |
| Connection probe and latched failure | The session | Owner, at event processing | Latched once; never cleared |
| Monitor capture latch, identities, inventory snapshot, claims | The session | Callback writes inside owner calls; owner folds and publishes; any thread reads the snapshot | Snapshot closed first at teardown; identities never reissued |
| Native window, callback storage, capture latch, input staging | The window | Callbacks write inside owner calls; owner boundaries take | The window's scope. Storage kept when release is uncertain |
| Observation, close counter, mode record, constraint states, transition marker | The window | Owner boundaries write; any thread reads the snapshot | Final value retained in the closed snapshot |
| Command channel, pending cells, request counter | The command host | Any thread admits; the owner claims, settles and closes | Closed with its backlog settled; never reopened |
| Completion cell | Its tickets | Settled once by the owner; any thread reads | While a ticket references it |
| Demand slots | The window host | Any thread publishes; the owner captures and closes | Cleared by each capture; closed with the window or at quiescence |
| Window collection, registry, per-window command hosts, borrow counts, cursors, surfaced close requests | The window host | Owner writes; any thread reads the registry | Remaining windows released newest first when the scope unwinds |
| Input feed: channel generation, phase, epoch, gates, held baseline, counters | The window host, per window | Owner produces, warns, resumes, closes; consumer reads and acknowledges | Closed at the close protocol or quiescence; counters never reset |
| Attachment model, admission, completion inbox, retirement protocols, observation cells, surface holds | The protected host lifetime | Owner thread writes; any thread reads and offers notices | Ends with the host, every attachment retired first |
| Retirement demand and rotation cursor | The window host | Each round writes; any thread reads | Replaced each round |
| Render demand | The caller that threads the value | That caller only | The caller's own value |
| Graphics owner handoff: lifetime port, observation slots, demand and scene snapshots, status, terminal records | The graphics owner's handoff | Main and application threads publish; the owner reads and writes records | Closed by quiescence or a run-ending failure; bounded by live windows |
| Settlement ledger, retained failures, fatal latch, presentation holds | The graphics owner composition | Main thread and owner, in `STM` | The owner worker. The latch is never cleared |
| Loader capability use, instance leases, surface obligations | Their scopes and holders | Owner admits and installs; any holder discharges | Uncertain outcomes are retained for good |

## Linking

`hetoimasia-glfw:native` declares `pkgconfig-depends: glfw3 >=3.4 && <3.5`, so
Cabal resolves the private prefix
[the native recipe](validation.md#the-native-recipe) prepares, and a
missing prefix is a configure failure. The platform libraries `glfw3.pc` keeps
in `Libs.private` are declared per operating system (`Cocoa IOKit
CoreFoundation` on macOS; `rt m dl` on Linux), and `glfw-tests` compares them
with the native manifest.

## Build and check

On macOS, once per native configuration (see
[Developer prerequisites and macOS](validation.md#developer-prerequisites-and-macos)):

```bash
brew install cmake pkgconf
python3 tools/native/native.py build
eval "$(python3 tools/native/native.py prepare)"
```

Inside the Linux CI image `PKG_CONFIG_PATH` already names the prefix. Then:

```bash
cabal build all
cabal test hetoimasia-glfw:glfw-tests --test-show-details=direct
cabal test glfw-native-tests --test-show-details=direct --test-options='--dry-run'
```

`cabal.project` sets `tests: True` for this package, so `cabal build all`
compiles both suites without running either.

- **`glfw-tests`** is the headless suite, rooted at one `GLFW` group, in the
  `test.glfw` validation group. It initializes nothing and needs no display.
  A new example that needs no native session belongs here, beside the
  component spec that owns it. Boundary evidence comes only from the external
  clients it compiles against the package (`--match "across the package
  boundary"`), never from the suite's own access to private sublibraries. A
  selector that matches nothing fails the suite.
- Helper threads in examples are started through `Test.Support.Owned`
  (`Test.GLFW.Support` in `glfw-tests`, `Test.GLFW.Native.Threads` in the
  native suite), so each is stopped and joined when its example ends.
- Examples assert an order of recorded facts or an observed state, never a
  time, and coordinate threads explicitly.

## The native suite

GLFW requires the process main thread and Hspec runs examples on its own
threads, so `glfw-native-tests` makes its main thread the owner of one shared
production session and runs Hspec on a worker. Examples reach the session
through the test-only dispatcher in `Test.GLFW.Native.Fixture`. The Vulkan
window integration's native suite builds on the same rules
([gpu_backend.md](gpu_backend.md#the-native-suite)).

| Rule | How it holds |
| --- | --- |
| Selection | The tree is built, listed and filtered before any example runs. A dry run or a selection that reaches no native operation acquires nothing; a selection matching nothing fails. |
| Acquisition | Lazily, by the first dispatched operation, at most once. The run's last line reports the count and the run fails if it exceeds one. |
| Windows | Every window example creates and releases its own window inside one operation. No window is shared. |
| Private sessions | Scenarios that cannot coexist with the shared session run in a child process of the same executable (`--private-session <scenario>`). A child inherits the parent's consent; one started directly without consent refuses with exit status 3. |
| Thread identity | Checked at setup, inside every dispatched operation, and before and after release. |
| Settlement | A waiting example also watches the owner. A cancelled example's queued operation is settled without running. An acquisition failure answers every operation and is never retried. The session is released only after the Hspec run finishes. |
| Consent | No native operation runs and no child starts without the run's consent, read once from `HETOIMASIA_NATIVE_SESSION`. |
| Platform | Under `desktop` or `isolated-x11` on Linux the session must select X11 with `WAYLAND_DISPLAY` absent; on macOS it must select Cocoa. Under `isolated-wayland:<socket>` it requests and must select Wayland with `DISPLAY` unset. Anything else fails every native example with `DisplayUnavailable`. |

**Consent values.** `desktop` is the opt-in for one run on the local desktop.
`isolated-x11:<display>` is what `tools/display/x11.sh` gives the command it
runs, accepted only on Linux and only when it names the current `DISPLAY`.
`isolated-wayland:<socket>` is what `tools/display/wayland.sh` gives its
command, accepted only on Linux when `WAYLAND_DISPLAY` names that socket.

Without consent, these list the examples and run the ones that never enter a
session:

```bash
cabal test glfw-native-tests --test-show-details=direct --test-options='--dry-run'
cabal test glfw-native-tests --test-show-details=direct --test-options='--match "with a scripted owner"'
cabal test glfw-native-tests --test-show-details=direct --test-options='--match "the native opt-in"'
```

On Linux, run the native examples inside the display helper. It starts a
private display and gives its command the consent for that display alone, so
it needs no approval and touches no desktop:

```bash
bash tools/display/x11.sh -- cabal test glfw-native-tests --test-show-details=direct
bash tools/display/wayland.sh -- cabal test glfw-native-tests --test-show-details=direct \
  --test-option=--match --test-option='/GLFW native/on an isolated Wayland session/'
```

On a real desktop (Cocoa on macOS, or a person's own X11 desktop) the examples
show, focus, resize, minimize, maximize and take fullscreen windows. The
standing approval and its limits are in [AGENTS.md](../AGENTS.md). The run
carries the consent on its own command and nowhere else:

```bash
HETOIMASIA_NATIVE_SESSION=desktop cabal test glfw-native-tests --test-show-details=direct
HETOIMASIA_NATIVE_SESSION=desktop cabal test glfw-native-tests --test-show-details=direct --test-options='--match "/GLFW native/the shared session/"'
```

Never set the variable in a shell profile, a persistent environment, or a
script that runs on its own. Without it the full command fails before
initializing GLFW, with zero acquisitions in its report. See
[validation.md](validation.md#the-display-worker).

### The interaction probe

On some platforms a window move, resize or menu interaction runs a platform
modal loop inside the native event call, which stalls every owner-driven step
until it returns. `Test.GLFW.Native.Interaction` measures owner-loop progress
during such interactions, using the session's bounded, record-only interaction
trace (`Hetoimasia.Runtime.GLFW.Trace`): owner turns, the native call's entry
and exit, each callback, and the update hook, stamped from one monotonic
clock. The trace is stopped unless a probe starts it, keeps a bounded number
of records, numbers the ones it drops, and marks evidence with any loss as
incomplete.

Two gates keep the probe out of routine runs: the consent gate, and
`HETOIMASIA_INTERACTION_PROBE_SECONDS`, without which it reports pending and
opens no window. No validation group names it. An activated run works through
an idle baseline, a move, a resize and a menu-bar interaction, printing what
to do before each. It asserts only that each phase measured at least one owner
turn and one complete pump and lost no records; whether a stall happened is
the question, not an assertion. On macOS a live resize and a menu interaction
were each measured blocking the owner turn for as long as the interaction
lasted.

It asks a person to keep interacting for the whole run, so describe it, ask,
and wait for acceptance:

```bash
HETOIMASIA_NATIVE_SESSION=desktop \
HETOIMASIA_INTERACTION_PROBE_SECONDS=20 \
HETOIMASIA_INTERACTION_PROBE_OUTPUT=/tmp/owner-loop-interaction-trace.tsv \
  cabal test glfw-native-tests --test-show-details=direct \
  --test-options='--match "/GLFW native/owner-loop progress during window interactions/"'
```
