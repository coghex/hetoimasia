# GLFW session

Current behavior of `hetoimasia-glfw`, the package that owns the native binding
to upstream GLFW 3.4 and the one process-main-thread session over it. The
accepted direction and the later slices live in
[the GLFW integration design](glfw_integration_design.md) (P-1 to P-3, D-8, D-9,
D-13); this document describes what the code does today.

This slice adds no window type, window command, event loop, input, monitor, or
rendering operation. A session is entered, its asynchronous native error reports
are read, and it ends.

## Package layout

| Component | Visibility | Holds |
|---|---|---|
| `hetoimasia-glfw` | public | `Hetoimasia.GLFW.Session`, the supported interface |
| `hetoimasia-glfw:model` | private | The session model over a table of native operations, and bounded error capture. Binds nothing. |
| `hetoimasia-glfw:native` | private | The foreign imports, `native/cbits`, and the production native table. Native handles and ABI declarations stay here. |
| `hetoimasia-glfw:seam` | public, test-only | `Hetoimasia.GLFW.Seam`: the real model over a scripted native library, for CPU examples. Links no GLFW. |
| `glfw-native-check` | test suite | The real session on the platform it runs on |

The package depends on `hetoimasia-foundation` and not on
`hetoimasia-runtime`. Its only logging import is `Component` from
`Hetoimasia.Foundation.Log`, for failure identifiers; it takes no logger and
writes to no sink.

## Public interface

```haskell
-- Hetoimasia.GLFW.Session
data Session
allocSession            ∷ SessionConfig → Scoped Session
withSession             ∷ SessionConfig → (Session → IO r) → IO r
sessionBackend          ∷ Session → Backend
takeAsynchronousReports ∷ Session → IO Reports

data SessionConfig = SessionConfig { requestedBackend ∷ Maybe Backend }
defaultSessionConfig ∷ SessionConfig      -- the platform's own backend
data Backend = X11 | Cocoa | Wayland

data Reports     = Reports { reportedErrors ∷ [NativeError], reportsLost ∷ Natural, callbackFaults ∷ Natural }
data NativeError = NativeError { nativeErrorCode ∷ Int, nativeErrorDescription ∷ Text
                               , nativeErrorTruncated ∷ Bool, nativeErrorThread ∷ ReportingThread }
data ReportingThread = ProcessMainThread | OtherThread
errorEvidenceCapacity, errorDescriptionLimit ∷ Int   -- 16 reports, 1024 bytes

data SessionMisuse = NotProcessMainThread | NotSessionOwner | SessionAlreadyActive
                   | SessionPoisoned | SessionEnded
data UnsupportedBackend  = UnsupportedBackend { unsupportedRequest ∷ Maybe Backend
                                              , unsupportedPlatformBackend ∷ Maybe Backend }
data BackendNotSelected  = BackendNotSelected { selectionRequested ∷ Backend, selectionReported ∷ Maybe Backend }
data NativeOutcome       = NativeCallReturned | NativeCallFailed
data NativeFailure       = NativeFailure { nativeOutcome ∷ NativeOutcome, nativeReports ∷ Reports }
newtype AsynchronousErrorsUnobserved = AsynchronousErrorsUnobserved Reports
glfwComponent ∷ Component                   -- "glfw"
```

`Session` is exported without its constructor. Every failure is raised through
`throwFailure` with the `glfw` component, the operation (`enter session`,
`initialize`, `verify backend`, `terminate`, `detach error callback`,
`take asynchronous reports`, `create window`, `destroy window`), and identifiers
such as `backend`, so `failureEvidence` reads the origin back without a logger.

## Entry

`allocSession` constructs the session as a staged composite. In order:

1. **Backend.** The request is resolved against the backend this platform
   supports: X11 on Linux and Cocoa on macOS, each selected explicitly. Wayland
   is never selected, and neither is another platform's backend; either request
   is `UnsupportedBackend` before anything else happens, so no XWayland run is
   ever presented as Wayland.
2. **Thread.** The calling thread must be bound and must be the OS thread that
   entered the process main function, or entry is `NotProcessMainThread`. A
   bound worker thread is not enough: the OS identity comes from a C shim
   (`pthread_main_np` on macOS, `gettid() == getpid()` on Linux). An unbound
   thread is rejected even if it runs there, because it could migrate. The
   threaded runtime is therefore required.
3. **Exclusivity.** A process-wide guard is claimed. An active session, entered
   from any thread, makes this `SessionAlreadyActive`; a poisoned guard makes it
   `SessionPoisoned`.
4. **Support.** `glfwPlatformSupported` must accept the backend, or entry is
   `UnsupportedBackend` and the guard is released.
5. **Callback.** The error callback is installed.
6. **Initialization.** The platform hint and `GLFW_COCOA_CHDIR_RESOURCES = false`
   are set, so session configuration never changes the process working
   directory, and `glfwInit` runs. A false return is a `NativeFailure` carrying
   the reports GLFW made during the call. That is how an initialization error is
   observed before any event polling exists.
7. **Verification.** Reports from a successful initialization are raised only
   now, after termination has been registered, and `glfwGetPlatform` must name
   the selected backend, or entry is `BackendNotSelected`.

Steps 1 to 3 change no native state, so every misuse and unsupported request is
rejected before native mutation. A failure at any later step releases exactly
what the earlier steps acquired, with the triggering failure primary and every
cleanup failure retained, as [composite construction](resources.md#composite-construction)
guarantees. Sequential sessions work after a complete, safe teardown.

## Owner, thread, and lifetime

The owner is the thread that entered the session. `takeAsynchronousReports` and
the private creation seam check, before any native call, that they run on the
owner (`NotSessionOwner`) and that the session is still live (`SessionEnded`).
The session lives until its enclosing `withScoped` continuation returns or
throws. Like any scoped value, it must not escape that scope.

## Native error evidence

GLFW reports an error through one process-wide callback, possibly on another
thread, with a description that is valid only during the call. The installed
callback runs uninterruptibly and does only bounded work. It copies at most
`errorDescriptionLimit` bytes, decodes them leniently as UTF-8, and records
truncation. It stores one `NativeError` with a non-blocking `IORef` update and
returns. It invokes no sink, takes no lock, and waits for nothing, so a callback
made synchronously from inside an owner call cannot deadlock. No Haskell
exception unwinds into C: a callback that cannot record its report adds to
`callbackFaults` instead.

Reports are sorted by the OS identity of the reporting thread, never by Haskell
thread identity (a callback runs in a Haskell thread of its own):

- A report made on the process main thread during an operation's native call
  belongs to that operation. The operation takes it after the call returns and
  fails with a `NativeFailure` naming whether the call itself failed.
- Any other report is asynchronous. It is never attributed to whichever
  operation is running when it is observed. `takeAsynchronousReports` reads it.

Each class keeps its first `errorEvidenceCapacity` reports and counts later ones
in `reportsLost`. A lost report or a callback fault still counts as reported, so
full storage can never turn a native failure into success.

## Teardown, poisoning, and controlled blocking

The composite declares its release order: terminate, then detach the error
callback and free its storage, then settle the guard.

| Release | What it does |
|---|---|
| `glfw terminate` | Marks the session ended, calls `glfwTerminate`, then raises any report made during that call |
| `glfw error callback` | Detaches the callback, frees its storage only if teardown has been safe so far, then raises any asynchronous report nobody read as `AsynchronousErrorsUnobserved` |
| `glfw session occupancy` | Vacates the guard after a safe teardown, or poisons it |

A release-time native error is checked after the native call returns, without
logging or pumping events. It is retained through
[the failure table](resources.md#the-failure-table): beside a failing body as a
labelled cleanup failure, or as the scope's own failure after a successful body.
It does not poison.

Poisoning is the answer when teardown cannot establish that native ownership
and callback registration ended safely. That is the case when termination or
detaching raises instead of returning, when initialization or attachment raises
with the native state unknown, or when a release runs on a thread other than
the owner. The callback storage is then deliberately leaked rather than freed
while it might still be called. The guard stays occupied-and-poisoned, so every
later entry fails with `SessionPoisoned` before any native call.

The storage is safe to free after a normal detach because of the owner-thread
rules. This package makes every GLFW call on the owner thread, and GLFW reports
errors from inside the failing call. Once the owner has detached the callback,
GLFW can no longer invoke it.

These releases satisfy [what a release may do](resources.md#what-a-release-may-do).
Each native call is a bounded GLFW call on the owner thread that waits for no
other thread and no event, and the bookkeeping is a non-blocking atomic `IORef`
update. No release contains a queue, fence, device wait, or logger.

## The binding

Only the operations above are bound: `glfwPlatformSupported`,
`glfwSetErrorCallback`, `glfwInitHint`, `glfwInit`, `glfwGetPlatform`,
`glfwTerminate`, `glfwDefaultWindowHints`, `glfwWindowHint`, `glfwCreateWindow`,
and `glfwDestroyWindow`.

- Imports go through `native/cbits/hetoimasia_glfw.h`, which includes the
  installed `GLFW/glfw3.h` with `GLFW_INCLUDE_NONE`. The C compiler therefore
  checks each CAPI declaration, and every constant comes from the header. The
  exception is `glfwSetErrorCallback`, a `ccall` import, because CAPI cannot
  spell its function-pointer type.
- Every GLFW import is `safe`. Any of them may re-enter Haskell through the
  error callback, and a safe call lets other Haskell threads run while it is in
  C. The thread-identity shim calls nothing and is `unsafe`.
- The C shim holds no state, queue, or game logic.

The private creation seam resets hints before every window and sets
`GLFW_CLIENT_API = GLFW_NO_API` explicitly. A hidden test window also sets
`GLFW_VISIBLE`, `GLFW_FOCUSED`, and `GLFW_FOCUS_ON_SHOW` to false. When
`glfwCreateWindow` returns a live pointer, its destruction is registered before
any report from the same call is raised.

## State

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
|---|---|---|---|---|---|
| Guard occupancy and poison | The native library's table; process-wide in production | Entry claims it; the last release settles it | Any; atomic | The process | Vacant after a safe teardown; poisoned for the rest of the process otherwise |
| Error capture buckets | The session | The callback writes; owner operations and releases take | Callback: any; takes: owner | Construction until the callback is detached | Unread asynchronous reports become cleanup evidence |
| Callback storage | The session | Installed at entry; freed at teardown | Owner | Until detached | Freed after a safe detach; leaked when poisoned |
| Teardown safety flag | The session | Releases clear it; the guard release reads it | Owner | The session | Read once |
| Liveness | The session | Termination clears it; owner operations read it | Owner | The session | Never set again |

The guard holds only occupancy and poison. None of this is application state.

## Linking

`hetoimasia-glfw:native` declares `pkgconfig-depends: glfw3 >=3.4 && <3.5`, the
range form of `3.4.*` that Cabal's pkg-config grammar accepts. Cabal therefore
resolves the private prefix that
[the native recipe](validation.md#the-native-glfw-recipe) prepares, and a missing
prefix is a configure failure. For an ordinary executable link, Cabal passes
only the archive flags, so the platform requirements that `glfw3.pc` keeps in
`Libs.private` are declared per operating system:

```cabal
if os(darwin)
    frameworks: Cocoa IOKit CoreFoundation
if os(linux)
    extra-libraries: rt m dl
```

The `GLFW link declarations` examples in `hetoimasia-tests` compare these, for the
platform they run on, with the `libs_static` the native manifest recorded. Any
drift fails the suite. No GLFW library-path override is needed on either
platform. The [validation planner](validation.md#how-a-groups-inputs-are-derived)
accepts these link-only conditionals and follows the `package:library`
dependencies on the private sublibraries.

## Build and check

On macOS, once per native configuration (see
[Developer prerequisites and macOS](validation.md#developer-prerequisites-and-macos)):

```bash
brew install cmake pkgconf
python3 tools/native/native.py build
eval "$(python3 tools/native/native.py prepare)"
```

Inside the Linux CI image, `PKG_CONFIG_PATH` already names the image's prefix.
Then:

```bash
cabal build all
cabal test hetoimasia-tests --test-show-details=direct --test-options='--match GLFW'
cabal test glfw-native-check --test-show-details=direct
```

`cabal.project` sets `tests: True` for this package alone. `cabal build all`
therefore compiles `glfw-native-check` from a clean configuration without
running it.

- **The `GLFW` group** in `hetoimasia-tests` is headless and initializes nothing.
  It proves the model through the seam, checks the link declarations, and
  compiles external clients against the package. It runs in the `test.engine`
  validation group.
- **`glfw-native-check`** needs a windowing session: Cocoa locally, or an X11
  display. It is not part of `hetoimasia-tests`, the console smoke, or any
  validation group. GLFW-7 owns the display runner and the shared native
  fixture.

It is a plain executable rather than an Hspec suite, because Hspec runs examples
off the main thread. Its checks cover:

- entering and leaving a real session, and a sequential second session;
- nested entry, and entry from a bound worker and an unbound thread;
- owner-only use from another thread;
- a hidden NoAPI window;
- a real `GLFW_PLATFORM_UNAVAILABLE` initialization failure before any polling,
  followed by a successful session.

Record native evidence with the manifest and compiler identities it ran under:

```bash
python3 tools/native/native.py toolchain
ghc --numeric-version && cabal --numeric-version
```
