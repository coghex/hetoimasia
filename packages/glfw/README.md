# GLFW

Buildable package: `hetoimasia-glfw`.

Owns the small private binding to upstream GLFW 3.4 and the one scoped session
over it. `Hetoimasia.GLFW.Session` enters a session on the process main thread:
backend selection (X11 on Linux, Cocoa on macOS, never Wayland), exclusive
initialization and termination, bounded evidence of native error reports, and
poisoning when teardown cannot finish safely. `Hetoimasia.GLFW.Monitor`
publishes that session's monitor inventory: copied descriptions with opaque
identities that end on disconnect and re-resolve on the owner thread.
`Hetoimasia.GLFW.Window` creates
lexically scoped NoAPI windows in that session, publishes what the platform
observed through read-only snapshots, contains their native callbacks, and
releases them when their scopes end. `Hetoimasia.GLFW.Command` admits prepared
window commands through bounded ports and reports each through a persistent
completion ticket; its control commands change a window's title, size,
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
close requests to application policy. The host owns its windows through a scoped
collection: applications create windows while running, receive each one's own
command port and observations, and close them independently in any order
through the host's close protocol. `Hetoimasia.GLFW.Input` gives each host
window one bounded, ordered input feed read by one consumer: key, text, button,
scroll, and focus events tagged with a window and a non-wrapping epoch, and on
overflow or temporary suspension a visible reset the consumer must acknowledge
before the owner resumes a fresh epoch. Native key, character, button, cursor,
and scroll callbacks copy a fixed payload and return; the owner boundary
publishes ordered events into the feed.

Its main library depends on `hetoimasia-foundation`, not on the runtime. Only
the `runtime-glfw` sublibrary, among its libraries, depends on
`hetoimasia-runtime`, and no library depends on it. No component imports a game, Lua, or rendering
module, and only the input feed's overflow warning takes a logger, injected by
its owner. Its native handles, foreign imports,
and C shim live in private sublibraries. The public `seam` sublibrary is the
test seam `hetoimasia-tests` drives without initializing GLFW.

The contract, including owner, thread, lifetime, poison, error-evidence,
monitor identity, observation, callback-containment, release-order, window
command, window control, window mode, and input feed rules, is
[docs/glfw.md](../../docs/glfw.md).

Build and check, after preparing the native prefix on macOS with
`python3 tools/native/native.py build` and
`eval "$(python3 tools/native/native.py prepare)"`:

```bash
cabal build all
cabal test hetoimasia-tests --test-show-details=direct --test-options='--match GLFW'
```

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
