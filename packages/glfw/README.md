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
completion ticket. The public `runtime-glfw` sublibrary's
`Hetoimasia.Runtime.GLFW` builds a window host as an application dependency and
runs its supervised owner loop, which processes native events, drains those
ports fairly, refreshes the monitor inventory when monitors change, and surfaces
close requests to application policy. The host owns its windows through a scoped
collection: applications create windows while running, receive each one's own
command port and observations, and close them independently in any order
through the host's close protocol. There is no input
operation yet.

Its main library depends on `hetoimasia-foundation`, not on the runtime. Only
the `runtime-glfw` sublibrary, among its libraries, depends on
`hetoimasia-runtime`, and no library depends on it. No component imports a game, Lua, logger, or rendering
module. Its native handles, foreign imports,
and C shim live in private sublibraries. The public `seam` sublibrary is the
test seam `hetoimasia-tests` drives without initializing GLFW.

The contract, including owner, thread, lifetime, poison, error-evidence,
monitor identity, observation, callback-containment, release-order, and window
command rules, is
[docs/glfw.md](../../docs/glfw.md).

Build and check, after preparing the native prefix on macOS with
`python3 tools/native/native.py build` and
`eval "$(python3 tools/native/native.py prepare)"`:

```bash
cabal build all
cabal test hetoimasia-tests --test-show-details=direct --test-options='--match GLFW'
cabal test glfw-native-tests --test-show-details=direct
```

List the native examples without entering a session:

```bash
cabal test glfw-native-tests --test-show-details=direct --test-options='--dry-run'
```

`glfw-native-tests` runs the real session through the shared native fixture and
needs a windowing session: Cocoa locally, or on Linux an isolated X11 display
from `tools/display/x11.sh`. See [docs/glfw.md](../../docs/glfw.md#the-native-suite).
