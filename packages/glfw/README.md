# GLFW

Buildable package: `hetoimasia-glfw`.

Owns the small private binding to upstream GLFW 3.4 and the one scoped session
over it. `Hetoimasia.GLFW.Session` enters a session on the process main thread:
backend selection (X11 on Linux, Cocoa on macOS, never Wayland), exclusive
initialization and termination, bounded evidence of native error reports,
poisoning when teardown cannot finish safely, and an opaque wake capability
(`sessionWake`, `wakeSession`) that any thread may use to end the owner's native
event wait. A wake is only a hint; it is terminal once its session begins closing,
and what to do after a failed wake is the notification policy's, not the
capability's. `Hetoimasia.GLFW.Monitor`
publishes that session's monitor inventory: copied descriptions with opaque
identities that end on disconnect and re-resolve on the owner thread.
`Hetoimasia.GLFW.Window` creates
lexically scoped NoAPI windows in that session, publishes what the platform
observed through read-only snapshots, contains their native callbacks, and
releases them when their scopes end. `Hetoimasia.GLFW.Command` admits prepared
window commands through bounded ports and reports each through a persistent
completion ticket, waking the session's owner once an admission has committed,
so a command submitted during the owner's idle wait ends it; its control commands change a window's title, size,
position, size constraints, visibility, focus and attention, and minimized or
maximized state, validated on the owner thread and settled as rejected,
unsupported, or attempted with the revision a post-call sample published.
`Hetoimasia.GLFW.Mode` requests windowed, borderless, and fullscreen presentation
on a selected monitor, keeping each window's windowed placement, arbitrating one
fullscreen window per monitor, and falling back to windowed operation within a
finite budget when a monitor disappears or a mode is unavailable. The public `runtime-glfw` sublibrary's
`Hetoimasia.Runtime.GLFW` builds a window host as an application dependency and
runs its supervised owner loop, which processes native events, drains those
ports fairly, refreshes the monitor inventory when monitors change, and surfaces
close requests to application policy. Beside that loop it offers an additive
scheduled path, `runScheduledOwnerLoop`, for an application that paces itself by
absolute deadlines: each turn samples the host's injected monotonic clock,
weighs the schedule its update last answered against the demand its own
inspection captured, and polls or waits at most the earlier deadline and at most
the configured finite fallback bound, with the same checkpoints, budgets, and
reconciliation. `runOwnerLoop` and its `LoopHooks`, `Turn`, and `TurnStep` are
unchanged by it, and an application that keeps using them reads no clock. `Hetoimasia.GLFW.Demand` is how a worker
asks that owner for a turn without a command: one bounded demand slot for the
application, lent as `hostDemandPublisher`, and one per live window, lent on its
`WindowClient` as `clientDemandPublisher`. Concurrent requests combine immediate
demand and the earliest requested deadline, publication records before it wakes,
and the owner captures a pending request with its revision and clears exactly
what it captured. `renderTurn` is the CPU-only helper that composes those
captures with the application's own simulation demand: it keeps per-window
scheduling state keyed by `WindowId`, suspends a window known to be hidden,
minimized, or of zero framebuffer extent while keeping its demand out of the
wait, defers one whose extent is unknown, owes exactly one rebased frame on
resume, offers a bounded and rotating number of opportunities per turn so no
always-dirty window starves another, drops a window's state at its first closing
observation because its slot closed with it, and answers the schedule the
scheduled loop continues with, leaving out the work its own offers already
cover. It calls no graphics API and infers no device readiness; a
rendering backend must add presentation backpressure on top of it. An admission
and a publication each register the notification they owe in the
transaction that commits them, and discharge it exactly once. An expected
platform wake failure degrades that session's wake path once, warns once under
`glfw.wake`, and leaves the owner's finite idle wait as the bounded fallback,
without changing any ticket or slot. `runWindowApplication` makes that one
guarded warning itself, after quiescence and the worker drain and while the
dependencies and logger are live, so an application needs no reporting call of
its own. The host owns its windows through a scoped
collection: applications create windows while running, receive each one's own
command port and observations, and close them independently in any order
through the host's close protocol. `Hetoimasia.GLFW.Input` gives each host
window one bounded, ordered input feed read by one consumer: key, text, button,
scroll, and focus events tagged with a window and a non-wrapping epoch, and on
overflow or temporary suspension a visible reset the consumer must acknowledge
before the owner resumes a fresh epoch. Native key, character, button, cursor,
and scroll callbacks copy a fixed payload and return; the owner boundary
publishes ordered events into the feed. The private `model` sublibrary also
holds a backend-neutral model of exclusive window attachments and the
retirement evidence that frees a window for a future graphics integration.
`withProtectedWindowHost` builds the same host inside a dedicated IO
continuation boundary that owns that state: on every exit it ends new graphics
use, retires every remaining attachment on the main thread while the windows,
the session, and every parent are still live, and retains them all when it
cannot. The `Scoped` constructors — `allocWindowHost` and `allocWindowHostIn` —
keep their signatures and behaviour and accept no attachment: they are issued no
attachment identity, so a registration against such a host is refused before any
effect.

`attachWindowGraphics` is the public attachment contract over that boundary, and
the only way in. It attaches one exclusive graphics owner to one open window of
a protected host, on the owner thread, taking the caller's own construction,
bounded retirement step, and completion policy, and answering a typed refusal —
a closing or ended window, an occupied one, another host or session, closed
admission, an unprotected host — before any acquisition effect. On success it
hands back an opaque `GraphicsService`: an identity, an incarnation, and its own
observation, with no native pointer, no window, no session, and no authority to
destroy, release, or certify anything. `windowGraphicsStatus` and
`readGraphicsService` answer whether an owner is attached, retiring, or absent,
which incarnation holds the slot, which retirement facts are still missing, and
whether the window's native destruction has completed, from any thread and
without inference. An accepted close ends that window's graphics admission in
the same transaction that publishes its closing phase;
`detachWindowGraphics` runs the same retirement while the window stays open, and
a later attachment gets a fresh incarnation. Retirement itself progresses on
owner turns under `hostRetirementBudget`, rotating across pending attachments so
one window's retirement never blocks another's, and `hostRetirementDemand` feeds
the scheduled loop so a due step is not delayed by the idle wait. No surface,
GPU submission, or device wait appears anywhere in it: evidence that GPU work
has completed is the backend's own, and which mechanism proves it is an open
question of the graphics design rather than of this package. See
[docs/glfw.md](../../docs/glfw.md#the-public-attachment-contract).

Its main library depends on `hetoimasia-foundation`, not on the runtime. Only
the `runtime-glfw` sublibrary, among its libraries, depends on
`hetoimasia-runtime`, and no library depends on it. No component imports a game, Lua, or rendering
module, and only the input feed's overflow warning and the wake path's
degradation warning take a logger, injected by its owner. Its native handles, foreign imports,
and C shim live in private sublibraries. The public `seam` sublibrary is the
test seam the package's headless `glfw-tests` suite drives without initializing
GLFW.

The contract, including owner, thread, lifetime, poison, error-evidence,
monitor identity, observation, callback-containment, release-order, window
command, admission wake, demand slot, wake degradation, window control, window
mode, input feed, and window attachment model rules, is
[docs/glfw.md](../../docs/glfw.md).

Build and check, after preparing the native prefix on macOS with
`python3 tools/native/native.py build` and
`eval "$(python3 tools/native/native.py prepare)"`:

```bash
cabal build all
cabal test hetoimasia-glfw:glfw-tests --test-show-details=direct
```

`glfw-tests` (`test/`) is the headless suite, composed by `Test.GLFW.Spec` under
one `GLFW` group: the session examples over the seam, the window model, command,
control, host, dynamic window, monitor inventory, input feed, and window mode
examples that use the private drivers and executor, the admission-wake, demand,
and degradation examples (`--match "wake"`), the link declarations, and
the external-client opacity examples. It initializes no GLFW, opens no window,
and needs no display, and a selector that matches nothing fails it. Focus a
component with its group name, for example
`--test-options='--match "GLFW window modes"'`. A new example that needs no
native session belongs here, beside the spec that owns its behaviour; one that
must initialize GLFW or open a real window belongs in `glfw-native-tests`.

`cabal build all` compiles `glfw-native-tests` without running it. List its
examples, or run the selections that never enter a session, without any
approval:

```bash
cabal test glfw-native-tests --test-show-details=direct --test-options='--dry-run'
cabal test glfw-native-tests --test-show-details=direct --test-options='--match "with a scripted owner"'
cabal test glfw-native-tests --test-show-details=direct --test-options='--match "the native opt-in"'
```

The full suite runs the real session through the shared native fixture, and
its examples show, focus, resize, minimize, maximize, and take fullscreen
windows on the desktop they run on. It refuses to enter a session without
per-run consent. On Linux, the isolated display helper supplies that consent
for the private X11 display it starts, and needs no approval:

```bash
bash tools/display/x11.sh -- cabal test glfw-native-tests --test-show-details=direct
```

On a real desktop — Cocoa on macOS — an agent first describes that
disruption, asks the human user for explicit approval, and waits for
acceptance; the approved run, and only that run, then carries the consent on
its own command:

```bash
HETOIMASIA_NATIVE_SESSION=desktop cabal test glfw-native-tests --test-show-details=direct
```

Never put that variable in a shell profile or in a script an agent runs on its
own. See [docs/glfw.md](../../docs/glfw.md#the-native-suite).
