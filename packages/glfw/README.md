# GLFW

Buildable package: `hetoimasia-glfw`.

Owns the small private binding to upstream GLFW 3.4 and the one scoped session
over it. `Hetoimasia.GLFW.Session` enters a session on the process main thread:
backend selection (X11 on Linux, Cocoa on macOS, never Wayland), exclusive
initialization and termination, bounded evidence of native error reports, and
poisoning when teardown cannot finish safely. There is no public window, event,
or input operation yet.

The package depends on `hetoimasia-foundation`, not on the runtime, and imports
no game, Lua, logger, or rendering module. Its native handles, foreign imports,
and C shim live in private sublibraries. The public `seam` sublibrary is the
test seam `hetoimasia-tests` drives without initializing GLFW.

The contract, including owner, thread, lifetime, poison, and error-evidence
rules, is [docs/glfw.md](../../docs/glfw.md).

Build and check, after preparing the native prefix on macOS with
`python3 tools/native/native.py build` and
`eval "$(python3 tools/native/native.py prepare)"`:

```bash
cabal build all
cabal test hetoimasia-tests --test-show-details=direct --test-options='--match GLFW'
cabal test glfw-native-check --test-show-details=direct
```
