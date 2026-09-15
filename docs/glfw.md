# GLFW session and windows

Current behavior of `hetoimasia-glfw`, the package that owns the native binding
to upstream GLFW 3.4, the one process-main-thread session over it, the
lexically scoped windows created in that session, and the window host and owner
loop that compose them with the runtime's application lifecycle. The accepted
direction and the later slices live in
[the GLFW integration design](glfw_integration_design.md) (P-1 to P-9, P-11,
D-4, D-5, D-6, D-8, D-9, D-11, D-13, D-17); this document describes what the
code does today.

A session is entered, its asynchronous native error reports are read, windows
are created in it, observed through read-only snapshots, asked for fresh
observations through bounded window command ports, and released when their
scopes end, and the session ends. A window host owns those together as an
application dependency, and its supervised owner loop processes native events,
drains the ports, and surfaces close requests to application policy. There is
no input feed, monitor inventory, manipulation or mode command, default close
policy, dynamic window collection, or rendering operation.

## Package layout

| Component | Visibility | Holds |
|---|---|---|
| `hetoimasia-glfw` | public | `Hetoimasia.GLFW.Session`, `Hetoimasia.GLFW.Window`, and `Hetoimasia.GLFW.Command`, the supported interface |
| `hetoimasia-glfw:model` | private | The session and window models over a table of native operations, bounded error capture, and the window command protocol, including execution and settlement. Binds nothing. |
| `hetoimasia-glfw:native` | private | The foreign imports, `native/cbits`, and the production native table. Native handles and ABI declarations stay here. |
| `hetoimasia-glfw:runtime-glfw` | public | `Hetoimasia.Runtime.GLFW`: the window host, its supervised owner loop, and the host's quiescence action. The one library that depends on `hetoimasia-runtime`. |
| `hetoimasia-glfw:seam` | public, test-only | `Hetoimasia.GLFW.Seam`: the real models over a scripted native library, for CPU examples. Links no GLFW. Exports no window driver. |
| `hetoimasia-glfw:seam-core` | private | `Hetoimasia.GLFW.Internal.Seam`: the seam's implementation, including the window drivers that deliver scripted callbacks, queue them for the next poll or wait, and change close intent, and the private window command executor |
| `glfw-window-examples` | executable, test-only | The window model, window command, and window host examples that use those drivers and that executor. `hetoimasia-tests` runs it. |
| `glfw-native-tests` | test suite | The shared native fixture, and real session, thread, window, and window host examples on the platform it runs on |

The main library and the `model`, `native`, `seam`, and `seam-core`
sublibraries depend on `hetoimasia-foundation` and not on `hetoimasia-runtime`.
`runtime-glfw` depends on both, and no library depends on it; only the
package's own `glfw-window-examples` and `glfw-native-tests`, and
`hetoimasia-tests`, use it. The runtime integration therefore inverts no
dependency. It is a sublibrary with its own source root rather than a separate
package because the native suite must depend on it, and Cabal refuses that as a
cycle between packages. The package's only logging import is `Component` from
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

```haskell
-- Hetoimasia.GLFW.Command
data WindowCommandHost
newWindowCommandHost ∷ HasCallStack ⇒ Session → Integer → IO WindowCommandHost
windowCommandPort    ∷ WindowCommandHost → WindowCommandPort
closeWindowCommands  ∷ WindowCommandHost → STM Natural
commandStatistics    ∷ WindowCommandHost → STM CommandStatistics
performWindowCommand ∷ WindowCommandHost → [Window] → WindowCommand → IO Disposition
data CommandStatistics = CommandStatistics { commandsCapacity, commandsQueued, commandsActive, commandsPending ∷ Natural }

data WindowCommandPort
submitWindowCommand      ∷ HasCallStack ⇒ WindowCommandPort → [(Text, Text)] → WindowCommand → IO SubmitResult
awaitSubmitWindowCommand ∷ HasCallStack ⇒ WindowCommandPort → [(Text, Text)] → WindowCommand → IO WaitedSubmission
data SubmitResult     = SubmitAccepted CompletionTicket | SubmitFull | SubmitClosed
data WaitedSubmission = WaitAccepted CompletionTicket | WaitClosed

data WindowCommand                           -- Eq, Show, NFData
observeWindowCommand ∷ WindowId → WindowCommand
commandWindow        ∷ WindowCommand → WindowId

data RequestId                               -- Eq, Ord, Show
requestLocalIdentity ∷ RequestId → Natural
data CommandOrigin                           -- Eq, Show, NFData; read with:
submittedRequest ∷ CommandOrigin → RequestId
submittedWindow  ∷ CommandOrigin → WindowId
submittedAt      ∷ CommandOrigin → Maybe FailureSite
submittedContext ∷ CommandOrigin → [(Text, Text)]

data CompletionTicket                        -- Eq, Show
ticketOrigin    ∷ CompletionTicket → CommandOrigin
pollCompletion  ∷ CompletionTicket → STM (Maybe Disposition)
awaitCompletion ∷ HasCallStack ⇒ CompletionTicket → IO Disposition

data Disposition      = Performed CommandResult | Rejected CommandRejection | NotExecuted | Interrupted RequestId
data CommandResult    = ObservationPublished { publishedWindow ∷ WindowId, publishedRevision ∷ Natural }
data CommandRejection = WindowNotServed WindowId | WindowAlreadyEnded WindowId
                      | WindowNativeFailure { failedWindow ∷ WindowId, failedOperation ∷ Maybe Text
                                            , failedOutcome ∷ NativeOutcome, failedReports ∷ Reports }
data WindowCommandMisuse = OwnerThreadWouldWait
```

```haskell
-- Hetoimasia.Runtime.GLFW, in hetoimasia-glfw:runtime-glfw
data WindowHost
allocWindowHost       ∷ HasCallStack ⇒ HostConfig → Scoped WindowHost
allocWindowHostIn     ∷ HasCallStack ⇒ Scoped Session → HostConfig → Scoped WindowHost
hostWindows           ∷ WindowHost → [Window]
hostCommandPort       ∷ WindowHost → WindowCommandPort
hostCommandStatistics ∷ WindowHost → STM CommandStatistics
hostActivity          ∷ WindowHost → STM HostActivity
quiesceWindowHost     ∷ WindowHost → STM ()
data HostActivity = HostActivity { activityTurn ∷ Natural, activityWaiting ∷ Bool }

data HostConfig = HostConfig { hostSessionConfig ∷ SessionConfig, hostWindowConfigs ∷ [WindowConfig]
                             , hostCommandCapacity ∷ Integer, hostCommandBudget, hostEventBudget ∷ Int
                             , hostIdleWait ∷ Double }
defaultHostConfig  ∷ [WindowConfig] → HostConfig   -- capacity 64, budgets 16, idle wait 0.1 s
validateHostConfig ∷ HostConfig → Either HostConfigRejected ()
data HostConfigRejected = CommandBudgetRejected Int | EventBudgetRejected Int | IdleWaitRejected Double
hostComponent ∷ Component                   -- "glfw.runtime"

runOwnerLoop ∷ WindowHost → RuntimeControl → LoopHooks a → IO a
data LoopHooks a = LoopHooks { loopEvent ∷ IO Bool, loopUpdate ∷ Turn → IO (TurnStep a) }
noApplicationEvents ∷ IO Bool
data Turn = Turn { turnNumber ∷ Natural, turnWaited ∷ Bool, turnCommands, turnEvents ∷ Int
                 , turnCloseRequests ∷ [CloseRequest] }
data TurnStep a = Continue | Finish a
rejectHostCloseRequest ∷ WindowHost → CloseRequest → IO Bool

runWindowApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r) → Text → Scoped dependencies
  → (dependencies → WindowHost)                     -- where the host is
  → (dependencies → RuntimeControl → IO services)   -- startup
  → (services → RuntimeControl → IO a)              -- the action
  → IO a
```

`Session`, `Window`, `WindowObservation`, `WindowId`, `CloseRequest`,
`WindowHost`, `WindowCommandHost`, `WindowCommandPort`, `CompletionTicket`,
`CommandOrigin`, `RequestId`, and `WindowCommand` are exported without their
constructors, and their readers are functions rather than record fields, so no
client can build or rewrite one. No public
type holds a native pointer, and the snapshot publisher is never handed out:
clients receive only the read endpoint. Nothing assumes a single or primary
window.

Every failure is raised through `throwFailure` with the `glfw` component, the
operation (`enter session`, `initialize`, `verify backend`, `terminate`,
`detach error callback`, `take asynchronous reports`, `create window`,
`sample window`, `attach window callbacks`, `synchronize window`,
`detach window callbacks`, `destroy window`, `new window command host`,
`submit window command`, `await window command`, `execute window command`,
`perform window command`, `process window events`, `reconcile window events`,
`run owner loop`, `reject close request`), and identifiers such as `backend`,
`title`, `window`, or `request`, so `failureEvidence` reads the origin back
without a logger. A host configuration rejection is raised under the `glfw.runtime`
component and the `construct window host` operation.

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
   observed before any event is polled.
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
refresh, and close callback setters, and the owner loop's `glfwPollEvents` and
`glfwWaitEventsTimeout`. `glfwSetWindowSize` and `glfwPostEmptyEvent` are called
for the native examples only; no production path calls them.

- Imports go through `native/cbits/hetoimasia_glfw.h`, which includes the
  installed `GLFW/glfw3.h` with `GLFW_INCLUDE_NONE`. The C compiler therefore
  checks each CAPI declaration, and every constant comes from the header. The
  exception is `glfwSetErrorCallback`, a `ccall` import, because CAPI cannot
  spell its function-pointer type.
- Every GLFW import is `safe`. Any of them may re-enter Haskell through the
  error callback, and a safe call lets other Haskell threads run while it is in
  C. The thread-identity shim calls nothing and is `unsafe`.
- The production finite wait is made through the shim's
  `hetoimasia_glfw_wait_events_timeout`, a `safe` import that records the
  waiting OS thread and gives each wait an odd sequence number, then calls
  `glfwWaitEventsTimeout`. That observation is the shim's only state, and no
  production path reads it: the native examples' progress note lands only when
  the same wait's sequence number surrounds a kernel report that the waiting
  thread is blocked — `TH_STATE_WAITING` on macOS, state `S` in
  `/proc/self/task/<tid>/stat` on Linux — so it lands only inside GLFW's own
  wait. The shim holds no queue or game logic.

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
5. **Callbacks.** The callbacks' detach is registered, and then every callback
   is attached. An attachment that reports an error, raises part-way, or is
   interrupted is therefore detached before the window is destroyed.
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
a poll. An observation request executes through the same boundary, and so
does the window host's [owner loop](#the-window-host-and-owner-loop), which
reconciles every window after each poll or wait. In order, a boundary:

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
application's decision: the window host
[surfaces it to application policy](#close-requests-in-the-owner-loop), which may
reject it. There is no default close policy and no close command.

### Release

| Order | Part | Release |
|---|---|---|
| 1 | `glfw window callbacks` | Marks the handle terminal, takes any callback fault latched since the last boundary, detaches every callback, then raises any report made during that call |
| 2 | `glfw window` | Destroys the native window, then raises any report made during that call |
| 3 | `glfw window callback storage` | Frees the wrappers if release stayed certain; otherwise keeps them and poisons the session |
| 4 | `glfw window observations` | Publishes the terminal observation and closes the snapshot in one transaction |

Detaching before destruction, after every borrowing scope has ended, is the
documented order. A callback fault nobody observed is taken before the detach,
so no detach outcome can abandon it: after a detach that succeeded it is the
release's own failure, and beside a detach that raised or reported an error it
is retained as a `glfw window callback fault` cleanup failure while the detach's
failure stays primary. A release-time native error whose call returned is checked after the call,
without logging or pumping events, and retained through
[the failure table](resources.md#the-failure-table). After a detach, release
stays certain. After a destroy, the window's destruction was not established,
so release becomes uncertain, as below.

Release becomes uncertain when detaching or destroying raises instead of
returning, when destroying reports an error, when a release runs off the owner thread or after the session ended,
or when attaching the callbacks raised during creation. Callback reachability is
then unknown, so the wrappers are kept rather than freed beneath native code,
the session refuses further windows with `SessionPoisoned`, keeps its own error
callback storage, and poisons its guard when it ends.

The terminal observation keeps the last observed attributes without querying the
destroyed window, advances the revision, and names `WindowReleased` only when
release stayed certain, `WindowReleaseUncertain` otherwise. This happens on
exceptional teardown as on normal teardown. Readers holding the endpoint can
still read it and receive `EndOfStream` after it, under the snapshot contract.

## Window commands

`Hetoimasia.GLFW.Command` admits prepared window commands through a bounded
port, gives each admitted command a persistent completion ticket, and settles
every one of them exactly once. It composes
[the bounded FIFO channel](messaging.md#bounded-fifo-channels) and
[prepared payloads](messaging.md#evaluation-guarantees) and adds the per-request
completion both deliberately leave out. It is a window-service protocol, not
generic request/reply machinery. The window host's
[owner loop](#the-window-host-and-owner-loop) is its only production executor;
the test seam's private executor drives the same protocol in CPU examples.

### Owner, thread, and lifetime

`newWindowCommandHost` checks, before anything else, that it runs on the
session's owner (`NotSessionOwner`) and that the session is live
(`SessionEnded`), then creates the host's channel, refusing a capacity
`newChannel` refuses. The owner keeps the `WindowCommandHost`: closure,
statistics, and direct performance. Clients receive the `WindowCommandPort`,
which can only submit, and the tickets their submissions return; any thread may
hold either. Neither carries a native handle, destruction authority, a channel
endpoint, or a completion cell. Queued commands are claimed and settled only on
the owner thread. A host lives while referenced. The window host closes its
command host by quiescence, before the worker drain, and again when it is
released; a command host created directly is closed by its application.

### Admission

A `WindowCommand` is an immutable value addressed to one window. Submitting it
issues a request identity, records a `CommandOrigin` beside it — the request,
the window, the submission site, and the caller's diagnostic context — and
prepares the message to normal form on the submitting thread. A failure raised
while preparing propagates and admits nothing. The submission site is the
outermost call-stack frame and the whole stack, under the failure module's
[caller attribution](failures.md#caller-attribution) policy.

`submitWindowCommand` never waits. It answers `SubmitAccepted` with a ticket,
`SubmitFull` when capacity commands are queued, or `SubmitClosed` once admission
has ended, and `SubmitClosed` takes precedence. `awaitSubmitWindowCommand` is
the separate wait for capacity. Cancelling it with an asynchronous exception
admits nothing, and closure ends it with `WaitClosed`.

The message and its completion cell are added in one transaction: the message
to the channel, and the cell, keyed by request, to the host's pending map. The
cell is never inside the message. `SubmitFull`, `SubmitClosed`, a rolled-back
admission, and a cancellation before that transaction commits leave neither. A
cancellation after it commits withdraws nothing: the command stays queued and
settles even if its caller never received the ticket. Request identities are
never reissued, even for a submission that was not admitted. They identify
requests and do not order them; order is the order admissions committed.

### Dispositions

| Disposition | When | Effects |
|---|---|---|
| `Performed result` | The command was performed or requested from the window system | Applied; `result` was prepared before settlement |
| `Rejected reason` | The executor serves no such window (`WindowNotServed`), the window has ended (`WindowAlreadyEnded`), or a native call failed first (`WindowNativeFailure`) | None applied |
| `NotExecuted` | Closure settled it while it was still queued | None |
| `Interrupted request` | Its execution, or the preparation of its completion data, raised | May have been applied; nothing is replayed or rolled back |

A settled ticket never changes, and an admitted command never disappears. A
native failure is carried as copied data: the operation that raised it, whether
the call itself failed, and the reported codes and descriptions. An arbitrary
Haskell exception is never serialized into a ticket. The ticket names only the
interrupted request, and the exception propagates from the executor with its
own type and context.

### Tickets and waiting

`pollCompletion` reads a ticket in `STM` without waiting, as often as desired.
`awaitCompletion` waits for settlement and may be repeated; cancelling the wait
affects only the wait, and dropping a ticket cancels nothing. A ticket stays
readable after its cell has left the host's bookkeeping, and after closure.

The owner thread is the only thread that executes commands, so no public
operation waits for one there. On the owner thread, `awaitCompletion` of an
unsettled ticket and `awaitSubmitWindowCommand` on a full host fail with
`OwnerThreadWouldWait` instead of blocking; a settled ticket answers at once.
The owner uses `performWindowCommand`, the direct checked execution operation.
It checks the owner and liveness, involves no queue, cell, or ticket, answers
`NotExecuted` after closure, and lets a Haskell exception propagate unchanged.

### Execution

An executor claims queued commands in the order their admissions committed. A
claim receives the command and marks it active in one transaction, and its
protection begins with the claim, so no interruption can separate them. The
whole claimed lifetime is protected, including the preparation of completion
data. If anything raises, synchronous or asynchronous, the command settles as
`Interrupted` with its request identity before the original exception is
rethrown with its context. A synchronous failure gains the
`execute window command` operation context with the `request`, `window`,
`submitted-at`, and caller-context identifiers, so crossing the queue keeps
where the request came from while the failure's origin stays at the operation
that raised it. An asynchronous exception is rethrown unannotated. A settlement
never replaces a disposition already settled.

The executor protocol is private to the package. Its one production caller is
the window host's owner loop. The test seam's private executor also drives it:
it executes queued commands against the
seam windows it is given, can deliver an interruption immediately after the
claim, and can replace execution with a scripted step for simulated effects or
completion data that fails to prepare. It is a test seam, not a second
production executor.

### The observation request

`observeWindowCommand` is the only command. Executing it synchronizes the
addressed window at an owner boundary, which samples and publishes under the
[observation contract](#observations). It completes with
`ObservationPublished`, naming the revision of the committed observation that
followed the sample: a new revision if sampling changed anything, and otherwise
the published observation the sample matched. Publication commits before
settlement, so a reader that sees the disposition can already read that
revision. It never samples another window. A window the executor was not given
is `WindowNotServed`, an ended window is `WindowAlreadyEnded` without a native
call, and a sampling failure is `WindowNativeFailure` with nothing published.
A callback fault rethrown at that boundary is not a sampling failure: it
interrupts the command and propagates.

### Bookkeeping and closure

The pending map holds one cell per queued or active command and nothing else,
so it never holds more than the capacity plus the commands being executed.
Settlement writes a cell and removes it in one transaction, and a cell is always
settled before it is removed. There is no result queue and no request history.
`commandStatistics` reads the capacity and the queued, active, and pending
counts in one transaction.

`closeWindowCommands` ends admission and, in the same transaction, settles every
command still queued at its commit as `NotExecuted` and removes it, returning how
many it settled. No queued command runs afterwards, every waiter on those
tickets wakes, blocked capacity waits end with `WaitClosed`, and later
submissions answer `SubmitClosed`. A command already claimed is active work:
closure neither waits for it nor reports it unexecuted, and it settles through
its execution. Closure is finite, never retries, and is idempotent. A raw
channel close alone would keep the backlog, and a raw abort would discard it
without settling tickets; there is no abort.

## The window host and owner loop

`Hetoimasia.Runtime.GLFW`, in the public `runtime-glfw` sublibrary, composes a
session, its windows, and their command bookkeeping with the runtime's
[application lifecycle](resources.md#the-application-runner). It follows the
[module authoring guide](logging.md#module-authoring-guide): it takes no logger
and writes to no sink, and its failures are raised, never logged — a
configuration rejection under `glfw.runtime` and `construct window host`, native
failures under GLFW's own operations, and supervised failures as the runtime
delivers them. The runner makes the one terminal report.

### Construction and ownership

A `WindowHost` is an application dependency, built by `allocWindowHost` as a
`Scoped` value before supervision is entered, on the process main thread. It
validates its `HostConfig` first — both budgets at least one, and an idle wait
above zero and at most 60 seconds, so a NaN or infinite wait is refused — then
enters the session, creates each configured window in order, and creates the
command host. A failure at any stage releases what the earlier stages acquired
through ordinary scoped release, before any worker exists. The host is never a
service the startup callback returns: startup receives it among the
dependencies and hands workers only client capabilities — `hostCommandPort`, a
window's read-only observations, and `hostActivity` — transferring no native
ownership. `allocWindowHostIn` builds the same host over a session scope the
caller supplies, such as a test seam's or a borrowed session; the host then owns
the session only if that scope does.

`WindowHost` is exported without its constructor or fields. No session, command
host, native handle, executor, or release authority can be taken from it. A
window it lends carries no release authority, and its owner operations refuse
other threads.

### The owner turn

`runOwnerLoop` runs on the session's owner thread — the application's action
calls it on the process main thread — and refuses any other thread with
`NotSessionOwner` before anything runs. Every turn performs, in order:

1. `checkRuntime`;
2. native event processing: `glfwPollEvents`, or on an idle turn
   `glfwWaitEventsTimeout` with the configured bound;
3. reconciliation of every window's captured callbacks at an owner boundary,
   collecting the close requests not yet surfaced;
4. `checkRuntime`;
5. command work: at most `hostCommandBudget` queued commands claimed, executed,
   and settled;
6. `checkRuntime`;
7. application event work: at most `hostEventBudget` calls of `loopEvent` that
   dispatched something, ending at the first that found nothing ready;
8. `checkRuntime`;
9. the application's update opportunity, `loopUpdate`, which receives the turn's
   `Turn` summary and answers `Continue` or `Finish`;
10. `checkRuntime`, before a `Finish` result is returned or the next turn begins.

A supervised failure latched at any point is rethrown by the next check, so no
dispatch begins once a check has seen it. A native failure, a callback fault
rethrown at reconciliation, a command's rethrown interruption, or a hook's
failure also ends the loop and propagates.

### Budgets

Budgets count attempted dispatches, not time. A rejected command — addressed to
a window the host does not serve, or to one that has ended — costs its attempt
exactly as a performed one does. At most `max hostCommandBudget hostEventBudget`
dispatch attempts separate two consecutive checks, however continuously the
command queue and the application's event source are refilled. A budget does
not bound one native call or one event handler; long work belongs in a worker.

### Idle waits

A turn is idle when the turn before it attempted no command and dispatched no
application event, and no command is queued at its entry. Active turns poll.
Idle turns wait at most `hostIdleWait` seconds, so a checkpoint follows even when
no native input arrives. No wait is indefinite, a host with no windows waits on
each idle turn instead of spinning, and the bound is a latency rather than a
shutdown deadline. There is no wake-on-post: a command
submitted during a wait waits for the wait to end, and the same turn's command
work then serves it. Native waits are safe foreign calls, so background workers
run while the owner is inside one. `hostActivity` publishes the current turn and
whether its owner has begun its finite wait; the flag is set immediately before
the native call and cleared once it returns, so it signals a wait starting or in
progress rather than proving the call was entered.

### Close requests in the owner loop

A close request is captured by the window's own callbacks and reconciled into
its observation, as [Close requests](#close-requests) describes; the host adds no
second callback owner. After reconciliation, a request the host has not surfaced
before appears once in `turnCloseRequests`. The application decides:
`rejectHostCloseRequest` clears it while it is still that window's latest, and
leaving it latched is equally a decision. The loop ends only when `loopUpdate`
answers `Finish`, so a close request — the last window's included — ends neither
the loop nor the runtime and destroys nothing. The host supplies no default that
finishes on a close request.

### Quiescence and shutdown order

`quiesceWindowHost` is the host's quiescence action for
[`runScopedApplicationWithQuiescence`](resources.md#quiescence), and
`runWindowApplication` is that runner with the action installed. In one finite,
non-retrying transaction it closes the command host's admission and settles
every queued command as `NotExecuted`. It destroys nothing, pumps nothing, waits
on nothing, and repeating it changes nothing. On every exit from the supervised
region, the ordinary order is:

1. quiescence: admission closes and queued callers settle as not executed;
2. supervision asks every live worker to stop and drains them, with the host
   live;
3. the dependency scope unwinds: the host closes admission again, a no-op after
   quiescence, destroys its windows, and then ends the session if it owns it;
4. the terminal report, if the run failed, and the final flush.

The runtime's two earlier orderings are unchanged: a fatal latch may request
worker stops before quiescence, and a worker whose managed startup is abandoned
or cancelled is drained before it. Quiescence neither precedes nor unblocks
either.

### What the owner and workers may wait on

No public owner-thread operation blocks on work only the owner turn can do. On
the owner thread, awaiting an unsettled ticket or capacity fails with
`OwnerThreadWouldWait`, and `runOwnerLoop` and `rejectHostCloseRequest` refuse
other threads. The owner may be starting or draining a worker instead of
turning, so a worker's startup and cleanup — rollback and finalizers included —
must not require a command's completion. A worker's acknowledged run action may
submit commands while the loop runs, composing its wait with its stop request:

```haskell
awaitOrStop ∷ StopToken → CompletionTicket → IO (Maybe Disposition)
awaitOrStop token ticket =
  atomically $
    (Just <$> (pollCompletion ticket >>= maybe retry pure))
      `orElse` (Nothing <$ awaitStopRequest token)
```

These are obligations on application and worker code; the runtime's guarantee
is not broadened.

### CPU examples

The host's CPU examples run whole applications over the test seam in
`glfw-window-examples`. The seam's native table scripts the poll and the finite
wait — recorded as `PollEvents` and `WaitEvents`, with `scriptPollEvents` and
`scriptWaitEvents` steps — and its private `seamQueueEvents` driver leaves
callback events, such as a close request, for the next poll or wait to deliver
from inside that call. They prove the turn order and the poll or wait choice,
the checks after saturated command and event batches, worker progress during a
wait, settlement through the loop, the owner-thread refusals, close-request
surfacing, quiescence, and the shutdown order on startup failure, action return,
failure, and cancellation, a supervisor-detected failure, and an abandoned
managed startup.

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
| Command channel | The command host | Ports admit; the executor claims; closure drains | Admit: any; claim and close: owner | While referenced | Closed by closure with its backlog settled; never reopened |
| Pending completion cells | The command host | Admission reserves; settlement and closure remove | Reserve: any; settle: owner | Admission until settlement | Removed at settlement |
| Active command count | The command host | Claims raise it; settlements lower it | Owner | The host | Zero whenever nothing is executing |
| Completion cell | Its tickets | Settled once; tickets read | Settle: owner; read: any | While a ticket references it | Never reset |
| Admission flag | The command host | Closure sets it; direct performance reads it | Owner | The host | Never cleared |
| Request counter | The command port | Submissions issue from it | Any; atomic | The host | Never reissued |
| Host session and windows | The window host | Construction creates them; the owner loop pumps and reconciles them | Owner | The host's scope | Windows destroyed, then an owned session ended, when the scope unwinds |
| Surfaced close requests | The window host | The owner loop records the latest request surfaced per window | Owner | The host | Replaced by a newer request; never reset |
| Host activity | The window host | The owner loop writes it around each event step; clients read it | Write: owner; read: any | While referenced | Left at the last turn |

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
cabal test glfw-native-tests --test-show-details=direct
```

`cabal.project` sets `tests: True` for this package alone. `cabal build all`
therefore compiles `glfw-native-tests` from a clean configuration without
running it.

- **The `GLFW` group** in `hetoimasia-tests` is headless and initializes nothing.
  It proves the session model through the seam, checks the link declarations,
  and compiles external clients against the package, including clients refused
  for naming a command host's, port's, or ticket's constructor or reaching for
  command execution, and a supported client that submits and awaits a command.
  It also runs the `glfw-window-examples` executable, reached through the suite's
  `build-tool-depends`, and fails with that executable's report if any window
  model example fails. It runs in the `test.engine` validation group.
- **`glfw-window-examples`** holds the window model and window command
  examples, as an Hspec executable that initializes no GLFW. The window model
  examples use the seam's private drivers: `seamDrive` delivers scripted callbacks from inside a setter- or poll-origin
  owner step, `seamDriveCancelledBeforeCommit` delivers a cancellation at the
  reconciliation's preparation point, and `seamRejectCloseRequest` is the
  private close-request transition. None is a public command. They live in the
  private `seam-core` sublibrary, which the public seam does not re-export, so
  no package outside `hetoimasia-glfw` can name them; the `GLFW` opacity
  examples compile clients proving it. Each driver also refuses, with
  `ForeignSeamWindow`, a window its own seam did not create.
- **The window command examples** in the same executable drive the private
  command executor — `seamExecuteNext`, `seamExecuteNextInterrupted`, and
  `seamExecuteNextScripted` — and the admission hooks of `submitWith`, both
  also private to `seam-core`. Without sleeps, they prove immediate
  `SubmitFull` and `SubmitClosed`; cancellable capacity waits; FIFO claim in
  committed admission order; one disposition for repeated, cancelled, and
  owner-thread reads, after removal from the bookkeeping; closure settling queued
  commands and leaving a claimed one to its execution; interruptions after the
  claim, after effects, in preparation, and by cancellation, none replayed;
  bookkeeping bounded by capacity plus active work across repeated cycles;
  admission rollback and cancellation on both sides of the commit; origin
  metadata intact across the queue; a native failure as prepared data beside a
  Haskell exception with its context; owner-thread waits refused rather than
  blocking; and the observation request settling with a revision published
  first, while unserved and ended windows are rejected.
- **`glfw-native-tests`** needs a windowing session: Cocoa locally, or an
  isolated X11 display. It is not part of `hetoimasia-tests` or the console
  smoke; it is the `test.glfw-native` validation group, which only the display
  worker runs. See [The native suite](#the-native-suite).

## The native suite

GLFW requires the process main thread, and Hspec runs examples on threads of its
own, so `glfw-native-tests` makes its process main thread the owner of one
shared production session and runs Hspec on a worker thread. An example reaches
the session through the test-only dispatcher in `Test.GLFW.Native.Fixture`: it
submits an operation, the main thread runs that operation against the session,
and the result or the original failure comes back to the example. This is a
test adapter over the production session, not a second supervisor or a general
test environment.

| Rule | How it holds |
| --- | --- |
| Selection | The Hspec tree is built, listed, and filtered before any example runs. A `--dry-run`, a listing, or a selection that never reaches a native operation acquires nothing, and a selection matching no example fails. |
| Acquisition | Lazily, by the first dispatched operation, and at most once. The run's last line reports how many times the shared session was acquired, and the run fails if that is more than once. |
| Windows | Every window example creates and releases its own private window inside one operation. No window is shared: no example yet demonstrates the reset and isolation a shared window would need. |
| Private sessions | Sessions entered and left in sequence, a forced initialization failure and its rollback, and a session over a faulting native table cannot coexist with the shared session, so each scenario runs in a child process of the same executable, started with `--private-session <scenario>`. No example ends the shared session. |
| Thread identity | Checked with the native main-thread shim, `isCurrentThreadBound`, and the owner's `ThreadId` at setup, inside every dispatched operation, before release, and after release. A failed check fails its operation or release, and the run. |
| Settlement | A waiting example also watches the owner, so an owner that fails wakes it with the owner's own failure. A cancelled example's queued operation is settled without running; one already running finishes and its reply is dropped. An acquisition failure answers every operation and is never retried. A failure crossing between the owner and an example is rethrown with the context it was raised with, so its failure evidence and retained cleanup failures survive. The session is released only once the Hspec run has finished, and a release failure beside a primary failure is kept as cleanup evidence. |
| Platform | On Linux the session is entered only when `DISPLAY` names a display and `WAYLAND_DISPLAY` is absent, and it must select X11; on macOS it must select Cocoa. Anything else fails every native example with `DisplayUnavailable`: no other platform is selected instead. |

The fixture's settlement rules are proven against a scripted owner that records
its acquisition and release — lazy single acquisition, nothing acquired by a dry
run or an empty selection, a deliberately failing nested example, a cancelled
borrower with one operation in flight and one queued, an owner that fails while
a borrower waits, and an acquisition failure — and the failing and cancelled
cases again against the real shared session. Every deliberate failure is inside
a nested run or a forked borrower and is asserted as expected, so the suite
itself passes.

The native examples cover:

- the platform's backend selected explicitly, on an isolated X11 display under
  Linux;
- operations running on the bound process main thread that entered the session,
  never on the Hspec worker, and a single acquisition;
- nested entry on the owner thread, entry from a bound worker and from an
  unbound thread, and owner-only use from the Hspec worker, each rejected while
  the shared session keeps serving;
- a hidden non-focusing window's creation, nondegenerate initial framebuffer
  observation, release, terminal observation, and terminal handle;
- two live windows with a stray hint reset before the second's creation;
- a second window after a window's release in the same session;
- a window host over the shared session running a whole application on the
  process main thread: a supervised worker's observation request executed by
  the real owner loop and settled with a published revision;
- a supervised worker progressing while the owner is blocked inside the
  production `glfwWaitEventsTimeout`: the worker's progress note lands only
  inside GLFW's own wait, as [the binding](#the-binding) describes, and wakes
  it with `glfwPostEmptyEvent`, and the loop reads back that a note landed in
  the wait it just returned from. On the suite's single capability, a wait that
  kept its capability would let no note land;
- a real close request — `performClose:` on Cocoa, a `WM_DELETE_WINDOW` client
  message on X11, sent by a test-only shim driver — reaching application policy
  without destroying the only window, the loop and a worker still running two
  turns later, and the window released only after that worker drained, with the
  run returning normally;
- in a private process, sessions entered and left in sequence, a real
  `GLFW_PLATFORM_UNAVAILABLE` initialization failure before any polling followed
  by a successful session, and a fault raised inside a real GLFW size callback,
  driven by `glfwSetWindowSize` and `glfwPollEvents`, rethrown at the owner
  boundary with its context. Cocoa calls that callback inside the resize, while
  X11 delivers it after a round trip to the server, so later boundaries wait
  for events with `glfwWaitEventsTimeout` — returning as soon as one arrives,
  within a bound of 100 boundaries of at most 50 ms — until the fault is
  rethrown.

```bash
cabal test glfw-native-tests --test-show-details=direct
cabal test glfw-native-tests --test-show-details=direct --test-options='--dry-run'
cabal test glfw-native-tests --test-show-details=direct --test-options='--match "/GLFW native/the shared session/"'
```

On Linux, run it inside the display helper, exactly as the display worker does:
`bash tools/display/x11.sh -- cabal test glfw-native-tests --test-show-details=direct`.
See [validation.md](validation.md#the-display-worker).

Record native evidence with the manifest and compiler identities it ran under:

```bash
python3 tools/native/native.py toolchain
ghc --numeric-version && cabal --numeric-version
```
