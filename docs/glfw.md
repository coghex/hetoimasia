# GLFW session and windows

Current behavior of `hetoimasia-glfw`, the package that owns the native binding
to upstream GLFW 3.4, the one process-main-thread session over it, and the
lexically scoped windows created in that session. The accepted direction and
the later slices live in
[the GLFW integration design](glfw_integration_design.md) (P-1 to P-5, P-7,
P-11, D-5, D-6, D-8, D-9, D-11, D-13); this document describes what the code
does today.

A session is entered, its asynchronous native error reports are read, windows
are created in it, observed through read-only snapshots, and released when their
scopes end, and the session ends. There is no window command, event loop, input
feed, monitor inventory, mode change, close policy, dynamic window collection,
or rendering operation yet.

## Package layout

| Component | Visibility | Holds |
|---|---|---|
| `hetoimasia-glfw` | public | `Hetoimasia.GLFW.Session` and `Hetoimasia.GLFW.Window`, the supported interface |
| `hetoimasia-glfw:model` | private | The session and window models over a table of native operations, and bounded error capture. Binds nothing. |
| `hetoimasia-glfw:native` | private | The foreign imports, `native/cbits`, and the production native table. Native handles and ABI declarations stay here. |
| `hetoimasia-glfw:seam` | public, test-only | `Hetoimasia.GLFW.Seam`: the real models over a scripted native library, for CPU examples. Links no GLFW. Exports no window driver. |
| `hetoimasia-glfw:seam-core` | private | `Hetoimasia.GLFW.Internal.Seam`: the seam's implementation, including the window drivers that deliver scripted callbacks and change close intent |
| `glfw-window-examples` | executable, test-only | The window model examples that use those drivers. `hetoimasia-tests` runs it. |
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

```haskell
-- Hetoimasia.GLFW.Window
data Window
allocWindow        ∷ Session → WindowConfig → Scoped Window
withWindow         ∷ Session → WindowConfig → (Window → IO r) → IO r
windowIdentity     ∷ Window → WindowId
windowObservations ∷ Window → SnapshotReader WindowObservation
windowEnded        ∷ Window → IO Bool
synchronizeWindow  ∷ Window → IO (WindowResult WindowObservation)
data WindowResult a = WindowAvailable a | WindowEnded WindowId

data WindowConfig = WindowConfig { windowTitle ∷ Text, windowWidth, windowHeight ∷ Int
                                 , windowVisible, windowFocused, windowFocusOnShow ∷ Bool }
defaultWindowConfig, hiddenTestWindowConfig ∷ Text → Int → Int → WindowConfig
validateWindowConfig ∷ WindowConfig → Either WindowConfigRejected ()
data WindowConfigRejected = WindowExtentRejected { rejectedWidth, rejectedHeight ∷ Int }
                          | WindowTitleRejected

data WindowId                                -- Eq, Ord, Show
windowLocalIdentity ∷ WindowId → Natural

data WindowObservation                       -- Eq, Show, NFData; read with:
observedWindow ∷ WindowObservation → WindowId
observedRevision ∷ WindowObservation → Natural
observedPhase ∷ WindowObservation → WindowPhase
observedLogicalExtent, observedFramebufferExtent ∷ WindowObservation → Attribute Extent
observedContentScale ∷ WindowObservation → Attribute ContentScale
observedPlacement ∷ WindowObservation → Attribute Placement
observedFocused, observedIconified, observedMaximized, observedVisible ∷ WindowObservation → Attribute Bool
observedCloseRequest ∷ WindowObservation → Maybe CloseRequest

data WindowPhase  = WindowOpen | WindowReleased | WindowReleaseUncertain
data Attribute a  = Observed a | Unavailable
data Extent       = Extent { extentWidth, extentHeight ∷ Int }
data ContentScale = ContentScale { scaleX, scaleY ∷ Float }
data Placement    = Placement { placementX, placementY ∷ Int }
data CloseRequest                            -- Eq, Ord, Show
closeRequestWindow ∷ CloseRequest → WindowId
closeRequestNumber ∷ CloseRequest → Natural
```

`Session`, `Window`, `WindowObservation`, `WindowId`, and `CloseRequest` are
exported without their constructors, and observation readers are functions
rather than record fields, so no client can build or rewrite one. No public
type holds a native pointer, and the snapshot publisher is never handed out:
clients receive only the read endpoint. Nothing assumes a single or primary
window.

Every failure is raised through `throwFailure` with the `glfw` component, the
operation (`enter session`, `initialize`, `verify backend`, `terminate`,
`detach error callback`, `take asynchronous reports`, `create window`,
`sample window`, `attach window callbacks`, `synchronize window`,
`detach window callbacks`, `destroy window`), and identifiers such as `backend`,
`title`, or `window`, so `failureEvidence` reads the origin back without a
logger.

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
every window operation check, before any native call, that they run on the
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

Only the operations the models use are bound: `glfwPlatformSupported`,
`glfwSetErrorCallback`, `glfwInitHint`, `glfwInit`, `glfwGetPlatform`,
`glfwTerminate`, `glfwDefaultWindowHints`, `glfwWindowHint`, `glfwCreateWindow`,
`glfwDestroyWindow`, `glfwGetWindowSize`, `glfwGetFramebufferSize`,
`glfwGetWindowContentScale`, `glfwGetWindowPos`, `glfwGetWindowAttrib`, and the
size, framebuffer size, content scale, position, focus, iconify, maximize,
refresh, and close callback setters. `glfwSetWindowSize` and `glfwPollEvents`
are bound for the native check only; no production path calls them.

- Imports go through `native/cbits/hetoimasia_glfw.h`, which includes the
  installed `GLFW/glfw3.h` with `GLFW_INCLUDE_NONE`. The C compiler therefore
  checks each CAPI declaration, and every constant comes from the header. The
  exception is `glfwSetErrorCallback`, a `ccall` import, because CAPI cannot
  spell its function-pointer type.
- Every GLFW import is `safe`. Any of them may re-enter Haskell through the
  error callback, and a safe call lets other Haskell threads run while it is in
  C. The thread-identity shim calls nothing and is `unsafe`.
- The C shim holds no state, queue, or game logic.

The window callback setters are `ccall` imports for the same reason. Each
callback wrapper only drops the window pointer and calls the model's callback,
which is already contained.

## Windows

A window is a lexical scoped resource: `allocWindow` creates it for the rest of
the enclosing `withScoped` scope, and `withWindow` is that scope on its own. Any
number may be live in one session. Dynamic creation and independent close order
arrive with GLFW-9 on the [scoped collection](resources.md#scoped-resource-collections),
which will take the same `Assembly` as one member; there is no second
acquisition or cleanup path.

### Owner, thread, and lifetime

The owner is the session's owner, the process main thread. Creation,
`synchronizeWindow`, and every release run there and check, before any native
call, that they do (`NotSessionOwner`) and that the session is live
(`SessionEnded`). A window lives until its enclosing scope ends, which must be
inside the session's. Its handle turns terminal as the first step of release,
after every borrowing scope has ended: `windowEnded` answers `True`, and
`synchronizeWindow` answers `WindowEnded` without a native call. The session
survives a window's release and can create another window.

A `WindowId` is the session's identity and a local number starting at one that
the session never reissues, even for a creation that failed. A later window
never answers to an ended handle.

### Creation

`allocWindow` constructs the window as a staged composite. In order:

1. **Validation.** Both dimensions must lie in `1 .. 2147483647` and the title
   must contain no NUL, or creation is `WindowConfigRejected` before any
   conversion to C or native call. `validateWindowConfig` is the same check.
2. **Owner.** The owner thread and liveness are checked. A session whose
   teardown safety has been lost refuses with `SessionPoisoned`, the answer its
   next entry would give. The local identity is issued.
3. **Callback storage.** One wrapper per callback is allocated.
4. **Native window.** Every hint is reset with `glfwDefaultWindowHints`, then
   `GLFW_CLIENT_API = GLFW_NO_API`, `GLFW_VISIBLE`, `GLFW_FOCUSED`, and
   `GLFW_FOCUS_ON_SHOW` are set explicitly from the configuration, so one
   window's configuration cannot leak into the next. When `glfwCreateWindow`
   returns a live pointer, its destruction is registered before any report
   from the same call is raised.
5. **Callbacks.** Every callback is attached.
6. **Initial observation.** Every attribute is sampled at that owner boundary,
   reconciled with anything captured since attachment, prepared, and published
   as revision zero of a fresh snapshot.

A failure at any stage releases exactly what the earlier stages acquired, in the
release order below, with the triggering failure primary.
`hiddenTestWindowConfig` is hidden, unfocused, and not focused on show;
`defaultWindowConfig` is shown and focused.

### Observations

A `WindowObservation` is immutable and prepared to normal form in producer `IO`
before it is published through the window's
[latest-value snapshot](messaging.md#latest-value-snapshots). It carries the
window's identity, a revision equal to the snapshot's, a phase, and the
attributes:

| Attribute | Source |
|---|---|
| Logical extent | `glfwGetWindowSize`, size callback; screen coordinates |
| Framebuffer extent | `glfwGetFramebufferSize`, framebuffer size callback; pixels |
| Content scale | `glfwGetWindowContentScale`, content scale callback |
| Placement | `glfwGetWindowPos`, position callback; desktop screen coordinates |
| Focused, iconified, maximized | `glfwGetWindowAttrib`, their callbacks |
| Visible | `glfwGetWindowAttrib` |
| Close request | close callback |

Observed fields hold only sampled or called-back values, never the requested
configuration; a sampled value may of course equal the request. Each query is
bracketed by the error capture. A query that reports only
`GLFW_FEATURE_UNAVAILABLE` is `Unavailable` rather than a fabricated value, and
any other report fails the boundary with `NativeFailure`. A zero framebuffer
extent, as an iconified window reports, is an ordinary nondrawable observation.

Getters sampled together are an engine observation, not an atomic snapshot of
the OS. Geometry and attributes coalesce to their latest values; a snapshot
preserves no event history.

### Callbacks and the reconciliation boundary

The size, framebuffer size, content scale, position, focus, iconify, maximize,
refresh, and close callbacks are contained at the trampoline. Each runs
uninterruptibly, copies and forces its fixed payload, records it into the
window's capture latch with one non-blocking `IORef` update, and returns. None
calls application code, waits for capacity, joins a worker, polls, logs, or
destroys a native object. Anything a callback raises is caught there with its
context and latched rather than unwinding into C; the first is kept and later
ones are counted.

Captures are reconciled on the owner thread at an owner boundary: at creation
after the initial sampling, at `synchronizeWindow` after it samples, and after
any private owner step's native calls return, whether that call was a setter or
a poll. The same boundary serves the command service and event loop that
arrive later. In order, a boundary:

1. runs its native work, taking the reports made during it;
2. reads the capture latch without clearing it and folds it, then any fresh
   sample, into the current observation;
3. prepares a new revision if anything changed, or if a refresh or a close
   request was captured, even when every attribute is unchanged;
4. commits: clears the captures it folded, publishes the revision, and records
   it as the owner's current observation, in one masked step with no
   interruptible operation;
5. takes and rethrows a latched callback fault in one masked step, with its
   original type and context, annotated with the `window callback` operation
   and the `window`, `callback`, and `later-faults` identifiers.

A cancellation or failure before the commit leaves every capture, the fault
included, latched for the next boundary, and the snapshot and owner state
unchanged; nothing can land between the commit's three writes, so an
observation's revision always equals its snapshot cursor's. If a callback
recorded anything between the read and the commit, the fold starts again from
the newer captures.

An asynchronous exception is rethrown unannotated, so cancellation stays
cancellation. If the native work itself fails, its failure propagates and the
captures and fault stay latched for the next boundary. Preparation runs outside
the trampoline and outside `STM`.

### Close requests

A native close request never destroys the window and never exits the process.
It is latched and reconciled into `observedCloseRequest` as a `CloseRequest`
naming the window and a number issued in increasing order per window; several
requests before one boundary coalesce into the newest. The model's private
rejection transition clears a request only while it is still the latest, so
rejecting an older request never erases a newer one. What a request means is the
application's decision: this slice adds no close policy and no public command.

### Release

| Order | Part | Release |
|---|---|---|
| 1 | `glfw window callbacks` | Marks the handle terminal, detaches every callback, then raises any report made during that call, or a callback fault nobody observed |
| 2 | `glfw window` | Destroys the native window, then raises any report made during that call |
| 3 | `glfw window callback storage` | Frees the wrappers if release stayed certain; otherwise keeps them and poisons the session |
| 4 | `glfw window observations` | Publishes the terminal observation and closes the snapshot in one transaction |

Detaching before destruction, after every borrowing scope has ended, is the
documented order. A release-time native error whose call returned is checked
after the call, without logging or pumping events, and retained through
[the failure table](resources.md#the-failure-table); release stays certain.

Release becomes uncertain when detaching or destroying raises instead of
returning, when a release runs off the owner thread or after the session ended,
or when attaching the callbacks raised during creation. Callback reachability is
then unknown, so the wrappers are kept rather than freed beneath native code,
the session refuses further windows with `SessionPoisoned`, keeps its own error
callback storage, and poisons its guard when it ends.

The terminal observation keeps the last observed attributes without querying the
destroyed window, advances the revision, and names `WindowReleased` only when
release stayed certain, `WindowReleaseUncertain` otherwise. This happens on
exceptional teardown as on normal teardown. Readers holding the endpoint can
still read it and receive `EndOfStream` after it, under the snapshot contract.

## State

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
|---|---|---|---|---|---|
| Guard occupancy and poison | The native library's table; process-wide in production | Entry claims it; the last release settles it | Any; atomic | The process | Vacant after a safe teardown; poisoned for the rest of the process otherwise |
| Error capture buckets | The session | The callback writes; owner operations and releases take | Callback: any; takes: owner | Construction until the callback is detached | Unread asynchronous reports become cleanup evidence |
| Callback storage | The session | Installed at entry; freed at teardown | Owner | Until detached | Freed after a safe detach; leaked when poisoned |
| Teardown safety flag | The session | Releases clear it; the guard release reads it | Owner | The session | Read once |
| Liveness | The session | Termination clears it; owner operations read it | Owner | The session | Never set again |
| Window identity counter | The session | Window creation issues from it | Owner | The session | Never reissued |
| Native window | The window | Its parts create and destroy it; owner boundaries query it | Owner | The window's scope | Destroyed at release |
| Window callback storage | The window | Its parts allocate, attach, detach, and free it; GLFW invokes it | Owner | Through the window's final native use | Freed after a certain release; kept when uncertain |
| Capture latch | The window | Callbacks write; boundaries and release take | Callbacks: inside owner calls; takes: owner | The window | Emptied at each boundary |
| Current observation and close counter | The window | Boundaries fold, then publish | Owner | The window | Final value retained in the closed snapshot |
| Observation snapshot | The window | The owner publishes and closes; clients read | Publish: owner; read: any | While referenced | Closed at release; never reopened |
| Window liveness | The window | Release clears it; every operation reads it | Owner; `windowEnded` any | The window | Never set again |
| Release certainty | The window | Uncertain parts clear it; the storage and observation releases read it | Owner | The window | Read at release |

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
  It proves the session model through the seam, checks the link declarations,
  and compiles external clients against the package. It also runs the
  `glfw-window-examples` executable, reached through the suite's
  `build-tool-depends`, and fails with that executable's report if any window
  model example fails. It runs in the `test.engine` validation group.
- **`glfw-window-examples`** holds the window model examples, as an Hspec
  executable that initializes no GLFW. They use the seam's private drivers:
  `seamDrive` delivers scripted callbacks from inside a setter- or poll-origin
  owner step, `seamDriveCancelledBeforeCommit` delivers a cancellation at the
  reconciliation's preparation point, and `seamRejectCloseRequest` is the
  private close-request transition. None is a public command. They live in the
  private `seam-core` sublibrary, which the public seam does not re-export, so
  no package outside `hetoimasia-glfw` can name them; the `GLFW` opacity
  examples compile clients proving it. Each driver also refuses, with
  `ForeignSeamWindow`, a window its own seam did not create.
- **`glfw-native-check`** needs a windowing session: Cocoa locally, or an X11
  display. It is not part of `hetoimasia-tests`, the console smoke, or any
  validation group. GLFW-7 owns the display runner and the shared native
  fixture.

It is a plain executable rather than an Hspec suite, because Hspec runs examples
off the main thread. Its checks cover:

- entering and leaving a real session, and a sequential second session;
- nested entry, and entry from a bound worker and an unbound thread;
- owner-only use from another thread;
- a hidden non-focusing window's creation, nondegenerate initial framebuffer
  observation, release, terminal observation, and terminal handle;
- two live windows with a stray hint reset before the second's creation;
- a second window after a window's release in the same session;
- a fault raised inside a real GLFW size callback, driven by `glfwSetWindowSize`
  and `glfwPollEvents`, rethrown at the owner boundary with its context;
- a real `GLFW_PLATFORM_UNAVAILABLE` initialization failure before any polling,
  followed by a successful session.

Record native evidence with the manifest and compiler identities it ran under:

```bash
python3 tools/native/native.py toolchain
ghc --numeric-version && cabal --numeric-version
```
