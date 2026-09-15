# Hetoimasia project memory

Updated: 2026-09-15. Durable project context for future interactive sessions.
Working rules live in [AGENTS.md](AGENTS.md); design proposals live in
[the foundation design](docs/engine_foundation_design.md).

## User intent and accepted direction

- Build a fresh modular Haskell/Vulkan game engine with Lua scripting.
- The owner already develops `~/work/synarchy`, a mature 2D engine and colony
  simulation using Haskell, Vulkan, and Lua, and knows their integration well.
- Develop 3D support here, with separate 2D and 3D modules sharing appropriate
  runtime/GPU services. Introduce a small 2D consumer early to test boundaries.
- Synarchy's game may eventually migrate through an application-owned adapter.
  This is a substantial future port, not automatic compatibility from a sprite
  renderer. Preserve useful assets, algorithms, and Lua behavior where practical.
- Keep game rules/state, game presentation, runtime services, rendering APIs,
  and Vulkan implementation separate. The application assembles them.
- Avoid repeating Synarchy's central `EngineEnv` ownership and dependency
  problem. Smaller records alone do not remove that problem.
- Use `~/work/kanban` and installed Kanban skills in interactive CLI sessions
  for issue/PR development. This repository is the target project; Kanban is
  the workflow application. Existing worktree and review habits carry over.
- Mixed implementation and documentation always travel in the same PR.
- Use Hspec wherever possible; Python probes are the fallback only where Hspec
  cannot reasonably exercise the boundary. This applies to future resource,
  concurrency, and Vulkan integration tests as well as pure code.
- GitHub target: `coghex/hetoimasia` (public). Use `master`, not `main`.
  The owner corrected the original repository-name typo on 2026-09-10 and
  created the correctly named empty repository. Preserve the local bootstrap
  history when republishing; local directory/package names already match.
  The owner explicitly requested the initial commit and remote setup.
- License: GNU GPLv3, requested explicitly by the owner; recorded as
  `GPL-3.0-only` in every Cabal package with the full license text included.

## Relevant Synarchy evidence

Inspection during the design conversation found a 92-field EngineEnv, game
manager initialization under Engine.Core, and Vulkan helpers using an EngineM
whose environment is fixed to that application-wide record. Game-specific Lua
registrations also live under Engine. Verify current code before migrating it.

Useful existing ideas include stable bindless texture handles, shader/host
layout agreement, packed sprite buffers, and coherent render-data publication.
The main sprite path expands sorted quads into six vertices; text uses GPU
instancing. The sprite shader fixes Z to zero and the render pass has no depth
attachment. Preserve the lessons without importing game-specific ownership.

The owner values Synarchy's carefully considered, pre-AI logging/resource design.
The current logger has early filtering before timestamp/thread/context collection,
per-category controls, structured context, and injectable output backends.
`Engine.Core.Resource` expresses cleanup through continuations; `allocResource'`
can position cleanup separately from allocation order (used for buffers/memory).
These ideas deserve deliberate evaluation. A continuation abstraction does not
require a universal EngineEnv. Shared mutable logging context and broad environment
access should not be ported automatically. The scratch logger here is a bootstrap,
not a verdict that Synarchy's design should be discarded.

## Implemented bootstrap

- Three Cabal packages: root console/tests, `hetoimasia-foundation` logging,
  and `hetoimasia-runtime` application entry point. Separate source roots.
- Logger accepts an injected sink and injectable clock/thread metadata, applies
  a pure filter (master switch, global and per-component thresholds, independent
  Debug selection, source switch), carries immutable derived fields and
  breadcrumbs, and validates dotted component names. It is synchronous; see
  [docs/logging.md](docs/logging.md). Runtime invokes a supplied action and
  propagates failures. Both were written from scratch; no Synarchy
  implementation was copied.
- LOG-2 settled the record layout: one line per entry, UTC to the millisecond,
  quoted text that cannot split a record, and fields sorted by key. Handle sinks
  serialize writes and flushes across the loggers sharing them and release that
  state on failure or interruption; callback sinks carry their own flush.
  Borrowed handles stay the caller's, unclosed and with their buffering intact.
- LOG-3 completed the arc: foundation parses the three configurable parts of a
  filter purely, `resolveLogFilter` assembles them over caller-supplied variable
  names and a caller-supplied lookup, and the console reads
  `HETOIMASIA_LOG_LEVEL`, `HETOIMASIA_LOG_LEVELS`, and `HETOIMASIA_DEBUG` once at
  startup, failing non-zero on an invalid value before any entry. The master and
  source switches stay programmatic. `docs/logging.md` now carries the startup
  contract and the module authoring guide AGENTS.md points new subsystems to.
- RES-1 added `Hetoimasia.Foundation.Resource`: `withResource` acquires under
  `mask`, lends the value to a body running with the caller's masking state,
  and attempts one release under `uninterruptibleMask_`. It implements the
  accepted failure policy rather than aliasing `bracket` — the body's failure
  stays primary, a cleanup-only failure becomes primary and is retained as
  evidence too, and every cleanup failure is kept as an ordered, labelled
  `CleanupFailure` that `cleanupFailures` reads back, including through a
  caller's `WhileHandling` nesting. Every internal rethrow uses `rethrowIO`
  with the primary's own context. `docs/resources.md` carries the contract.
  RES-2 through RES-4 subsequently added ranked composite construction,
  the `Scoped` continuation facade (`withScoped`, `allocResource`,
  `allocComposite`, `locally`), and the injected runtime resource demonstration.
  All are implemented at `7e92e73`, with the later repairs reviewed. The
  demonstration's `Channel` is an owned pair of slots, not a message queue.
- GLFW-10 (#87) added `Hetoimasia.Foundation.Resource.Collection`, the
  resource prerequisite for dynamic windows: a `Scoped` collection with one
  owner thread and a positive live-member limit that acquires members from
  ordinary `Assembly` values, lends them through `withMember`, and retires them
  early in any order. Reentry while acquiring, retiring, or closing is rejected;
  any release failure poisons acquisition and is latched into the exit outcome.
  `Scoped` itself still has no early-release token. Contract:
  `docs/resources.md`, "Scoped resource collections".
- RT-1 (#53) added `Hetoimasia.Foundation.Failure`: `throwFailure` attaches a
  component, operation, identifiers, and outermost-frame caller site to a typed
  exception's context without wrapping it; `withOperationContext` adds ordered
  outer context to synchronous failures, leaving cancellation unannotated and
  native causes native with an unknown throw site; `failureEvidence` reads it
  back without a logger. `docs/failures.md` carries the contract, and the
  `Failures` Hspec group proves it.
- RT-2 (#54) added `Hetoimasia.Foundation.Recovery`: `recover` runs one
  complete owned `IO` operation under an explicit, validated policy (component
  classifier, one finite budget across retry and named fallback, required or
  optional disposition, injected wait). Cancellation and attempts with cleanup
  evidence propagate before classification; histories ride on the propagated
  failure as an annotation. No logger and no `Scoped` catch instance.
  `docs/recovery.md` carries the contract; the `Recovery` Hspec group proves it.
- RT-3 (#55) added `Hetoimasia.Runtime.Reporting`: `reportOutcome` warns once
  for a recovered or unavailable outcome the caller already holds, and
  `reportTerminalFailure` makes one guarded `Error` attempt, then rethrows
  preservingly with a mark so enclosing boundaries do not report again. Origin
  goes in `origin.*`/`observed.*` fields, separate from the entry's source.
  `DiagnosticFailure` moved into it; `resourceSmoke` is its consumer. The
  contract is in `docs/logging.md`, proven by `Runtime`'s `Outcome reporting`.
- RT-7 (#58) added `Hetoimasia.Runtime.Logging`: `withLoggingLifetime` borrows
  a logger, lends it through a `LoggingLifetime` handle that records managed
  reporting-attempt outcomes (`reportTerminalFailureWith`'s recorder), and makes
  at most one final flush after the callback, outside releases, following P-11's
  matrix; secondary flush failures and known failed reports ride on the failure
  as evidence. Both console paths run inside it, the resource path through
  `managedResourceSmoke`. Contract: `docs/logging.md`, "Logging lifetime".
- RT-8 (#59) added `Hetoimasia.Runtime.Supervision`: `withSupervision` owns one
  worker group inside a logging lifetime and lends `RuntimeControl`;
  `startSupervised` registers a `Service`/`Job` role, `Required`/`Optional`
  disposition, and component classifier before child code runs, with a startup
  wait woken by certainly-fatal outcomes; `checkRuntime` and `awaitSupervised`
  select, classify outside STM, commit, then warn or rethrow; the first fatal
  status is latched and simultaneous failures are ordered by registration.
  Closing reuses `closeWorkerGroup`'s snapshot and drain; a cancelled body
  classifies nothing more. Runtime now depends on `stm`. Contract:
  `docs/supervision.md`; `Runtime`'s `Supervision` Hspec group proves it.
- RT-6 (#60) added `Hetoimasia.Runtime.Application.runScopedApplication` beside
  the unchanged `Hetoimasia.Runtime.runApplication`: it enters a caller-supplied logging lifetime,
  builds application-owned dependencies with `withScoped`, runs supervision,
  startup, and the action on the calling thread with an application-owned
  immutable services value, then closes and drains workers, disposes
  dependencies, makes one managed terminal report, and lets the lifetime flush.
  The console's exit mapping lives in the root package's private `console`
  library (`Hetoimasia.Console.Exit`): failure exits 1, cancellation 130.
  Contract: `docs/resources.md`, "The application runner"; `Runtime`'s
  `Application lifecycle` Hspec group proves it.
- MSG-1 (#74) added `Hetoimasia.Foundation.Messaging.Payload`: `prepare`
  fully evaluates a value through its `NFData` instance in producer IO and
  returns an opaque, nominal-role `Prepared` handle; `preparedValue` reads it
  without `NFData` or re-evaluation. Failures propagate untouched, cancellation
  stays cancellation, and there is no transport state or STM. Foundation and
  the root tests now depend on `deepseq`. Contract: `docs/messaging.md`; the new
  `Messaging` Hspec group proves it and is where later messaging slices go.
- MSG-3 (#76) added `Hetoimasia.Foundation.Messaging.Channel`: `newChannel`
  builds a bounded FIFO channel of `Prepared` payloads from an owner-chosen
  capacity (a non-positive or above-`maxBound ∷ Int` capacity throws
  `ChannelCapacityRejected` with engine origin) and returns a `ChannelControl`
  that hands out `Sender` and `Receiver` endpoints. `send` reports
  `Accepted`/`Full`/`Closed` without waiting and `awaitSend` waits only while
  open; `receive` distinguishes an entry, empty, drained, and aborted, and
  `awaitReceive` waits only while open and empty. Close keeps the backlog,
  abort drops it and returns the depth counter's count; neither retries.
  `channelStatistics` reads capacity, depth, high-water, and `Natural`
  accepted/dequeued/discarded counts in one transaction. It is a two-list queue
  in TVars, not `TBQueue`. Composition with `awaitSupervised` and
  `awaitStopRequest` is proven in `Messaging`; contract in `docs/messaging.md`.
- MSG-4 (#77) added `Hetoimasia.Foundation.Messaging.Snapshot`: `newSnapshot`
  builds a latest-value snapshot from a `Prepared` initial value with a fresh
  `Data.Unique` identity and returns a `SnapshotPublisher` that hands out a
  read-only `SnapshotReader`. Value, `Natural` revision, and terminal flag live
  in one `TVar`, so `publish` replaces value and revision together; every
  publication advances the revision and close does not. `readSnapshot` returns
  an opaque `Observation` (`observedValue`, `observedCursor`); `awaitSnapshot`
  checks the cursor's identity first, raising `ForeignSnapshotCursor` through
  `throwFailureSTM`, then returns the newest unseen publication, `EndOfStream`
  once closed, or retries. No per-reader state. Contract in `docs/messaging.md`.
- MSG-5 (#78) added `Hetoimasia.Runtime.Inbox`, the optional supervised inbox
  adapter over `startSupervised`: `startInboxService` builds the component's
  `Scoped` context, then the inbox with an `uninterruptibleMask_` abort as the
  innermost release, then writes a one-shot `TVar` handoff before
  acknowledgement, read once without waiting after `WorkerStarted`. Dispatch
  is a stop-first `orElse` over one prepared message at a time; handler
  exceptions escape to supervision's policy with no isolation or replay. An
  ordinary stop aborts and returns an opaque `InboxExit` holding the cumulative
  discard count (backlog is not processed on stop). Contract in
  `docs/messaging.md`; examples under `Runtime`'s `Inbox services` and its
  opacity clients.
- MSG-6 (#79) completed the messaging arc: `finishInboxService` closes
  admission normally, lets the worker handle the in-flight message and backlog
  in FIFO order, and waits through `awaitSupervised` for a `DrainAcknowledgement`
  the worker records in the same STM decision as its stop check and the closed,
  empty receive, then waits for its stop token. Finish stops through
  `stopSupervised` and awaits completion supervised, reporting `InboxFinished`,
  `InboxUnfinished` (with any acknowledgement and the actual completion), or
  `InboxFinishUnavailable`; other failures propagate. `InboxExit` gained a
  private acknowledgement field read by `inboxDrain`; `inboxAcknowledgedDrain`
  reads it raw on the handle. A cancellation after the drain has no
  deterministic public trigger that settles as `WorkerStopped`; its example is
  the policy-judged unexpected termination. The combined command/snapshot
  example is under `Runtime`'s `Inbox finish`; the bounded-turn loop is
  `Messaging`'s `Bounded turns`, a test-only pattern, not an API.
- GLFW-14 (#88) supplies native provisioning for the GLFW arc (#86) before
  GLFW-1. `tools/native/native.py` builds a checksum-pinned upstream GLFW 3.4
  as a static PIC archive into a private prefix and records a native manifest
  whose identity covers the C compiler, SDK, architecture, deployment target,
  and CMake options; `check`/`prepare` refuse any other prefix or a system GLFW.
  Linux CI runs in the public `ghcr.io/coghex/hetoimasia-ci` image, addressed
  only by the digest committed in `tools/ci-image/descriptor.json`. Changing any
  recipe input means running the `ci-image` builder and committing its returned
  descriptor in the same pull request; the planner refuses a stale descriptor
  and never selects an older image. The GHCR package inherited public visibility
  on first publication from this public repository. Container jobs need
  `--init` and a Git `safe.directory` entry. `docs/validation.md` carries the
  image, descriptor, builder, cache-layer, and macOS contracts.
- GLFW-1 (#89) added `hetoimasia-glfw` under `packages/glfw/`, the first
  consumer of that contract. It depends on foundation, not runtime. A private
  `model` sublibrary holds the session over a table of native operations; a
  private `native` sublibrary holds the CAPI imports through
  `native/cbits/hetoimasia_glfw.h`, a thread-identity shim, and the process
  guard; the public `seam` sublibrary is the test-only scripted native table.
  `Hetoimasia.GLFW.Session.withSession`/`allocSession` resolves the backend (X11
  or Cocoa; Wayland is always `UnsupportedBackend`), requires the bound process
  main thread, claims the guard, then installs a bounded error callback,
  initializes, and verifies the platform. Owner-thread reports fail their
  operation; others are read with `takeAsynchronousReports` or retained at
  teardown. An unsafe teardown leaks the callback storage and poisons the guard.
  Linking is `pkgconfig-depends` plus per-OS `frameworks`/`extra-libraries`,
  checked against the manifest by the `GLFW` Hspec group; the planner accepts
  those link-only `if os(...)` blocks and follows `package:library` deps.
  Its first real-session check was folded into GLFW-7's `glfw-native-tests`,
  which `cabal build all` builds but does not run (`tests: True` for that
  package only). Contract: `docs/glfw.md`.
- GLFW-2 (#90) added `Hetoimasia.GLFW.Window`: `allocWindow`/`withWindow`
  build a window in a live session from a validated `WindowConfig` through one
  `Assembly` (`Hetoimasia.GLFW.Internal.Window.windowAssembly`) that
  collection-backed construction will reuse. Dimensions are checked before C,
  hints are reset per window, and identities are the session's `Unique` plus a
  never-reissued local number. Each window publishes a prepared, opaque
  `WindowObservation` through a snapshot (separate logical, framebuffer, scale,
  placement; `Unavailable` for a `GLFW_FEATURE_UNAVAILABLE`-only query). Nine
  callbacks are contained at the trampoline and reconciled at owner boundaries
  (creation, `synchronizeWindow`, the private `windowStep`, and since GLFW-3
  the owner loop's `reconcileWindowEvents` after each poll or wait), where a latched
  fault is rethrown with `window callback` context; close requests latch with
  per-window numbers and never destroy. Release: mark terminal and detach, then
  destroy, then free storage only if certain (else keep it and poison the
  session), then publish the terminal phase and close the snapshot in one
  transaction. The old private creation seam was removed. The seam's
  implementation moved to the private `seam-core` sublibrary; its window drivers
  (`seamDrive`, `seamDriveCancelledBeforeCommit`, `seamRejectCloseRequest`) are
  not re-exported by the public `seam`, and only the package's
  `glfw-window-examples` executable uses them. `hetoimasia-tests` runs that
  executable from its `GLFW` group through `build-tool-depends`. The shared
  opacity harness exposes `-inplace` unit ids with `-package-id`, because
  sublibraries share their package's name.
  Contract: `docs/glfw.md`, "Windows".
- GLFW-13 (#91) added `Hetoimasia.GLFW.Command`: an owner-created
  `WindowCommandHost` (capacity-bounded, over `Messaging.Channel`) hands clients
  a submit-only `WindowCommandPort`. Submission prepares the command with a
  `CommandOrigin` (request id, window, call site, caller context);
  `SubmitFull`/`SubmitClosed` are immediate and `awaitSubmitWindowCommand` is the
  cancellable wait. Admission adds the message and a completion cell (keyed by
  request in a pending map, never inside the message) in one transaction; a
  `CompletionTicket` is persistent and non-consuming. Dispositions: `Performed`,
  `Rejected` (not served, ended, copied native failure), `NotExecuted`
  (closure), `Interrupted` (request id; the exception propagates with an
  `execute window command` context, never serialized). On the owner thread,
  waiting for a ticket or capacity fails with `OwnerThreadWouldWait`;
  `performWindowCommand` is the direct path. `closeWindowCommands` is one finite
  STM transaction that closes admission and settles the queued backlog, leaving
  claimed work to its execution. The one command, `observeWindowCommand`, runs
  `synchronizeWindow` and names the committed revision. Execution
  (`executeNextWith`) is private; GLFW-3's owner loop is its production caller
  and the seam-core executor (`seamExecuteNext*`) drives it in tests. Its
  examples live in `glfw-window-examples`. Contract: `docs/glfw.md`,
  "Window commands".
- GLFW-7 (#93) delivered TEST-2's first shared native fixture and the
  `display` runner class. `glfw-native-tests` (`packages/glfw/native-tests/`)
  makes the process main thread the owner of one lazily acquired production
  session (`Test.GLFW.Native.Fixture.runOwned`) and runs Hspec on a worker that
  `dispatch`es operations to it; dry runs and unreached selections acquire
  nothing, examples use private windows (none is shared yet), lifecycles that
  need their own session run in a `--private-session` child process, and thread
  identity is checked at setup, per operation, and around release. The catalog's
  `test.glfw-native` group (runner `display`, outside the floor) runs only on the
  `glfw-native` CI worker, each group inside `tools/display/x11.sh` (Xvfb plus
  Openbox, X11 forced, Wayland removed); the image carries those packages but
  starts nothing. Workers are declared once to `plan.py --worker
  NAME=CLASS:GROUPS`; the plan (schema 3) records the validated assignment, a
  worker-less plan is inspection-only, and `run.py`, `reuse.py`, and
  `aggregate.py` consume the plan's routing (receipt schema 3 records `worker`
  and `runner_class`). Contract: `docs/validation.md`, `docs/glfw.md`.
- GLFW-3 (#94) added the public `hetoimasia-glfw:runtime-glfw` sublibrary
  (`Hetoimasia.Runtime.GLFW`), the only component depending on both GLFW and the
  runtime. A separate `packages/runtime-glfw/` package was tried and rejected:
  Cabal's solver refuses the package cycle once `glfw-native-tests` depends on
  it, through `build-depends` or `build-tool-depends`. `allocWindowHost` builds a
  `WindowHost` (session, windows, command host) as a `Scoped` dependency;
  `runOwnerLoop` runs bounded turns (check, poll or finite `hostIdleWait` wait,
  reconcile, check, at most `hostCommandBudget` commands, check, at most
  `hostEventBudget` application events, check, `loopUpdate`, check) and is the
  only production command executor. A turn is idle when the previous one
  dispatched nothing and no command is queued. Close requests surface once in
  `turnCloseRequests`, and nothing finishes on them by default.
  `quiesceWindowHost` closes admission and settles `NotExecuted`, and
  `runWindowApplication` installs it. The native table gained
  `nativePollEvents`/`nativeWaitEventsTimeout` (seam `PollEvents`/`WaitEvents`,
  private `seamQueueEvents`), and the shim gained the test-only
  `requestCloseForCheck` (Cocoa `performClose:`; X11 `WM_DELETE_WINDOW` through
  a `dlopen`ed libX11, so no link requirement changes). Contract:
  `docs/glfw.md`, "The window host and owner loop".
- GLFW-11 (#97) added `Hetoimasia.GLFW.Monitor`: the session owns a monitor
  inventory (model `Hetoimasia.GLFW.Internal.Monitor`, stages in
  `sessionAssembly`) published as a prepared `MonitorInventory` snapshot; the
  host lends it as `hostMonitors`. `Attribute`/`ContentScale` moved to
  `Internal.Attribute`, and `glfwComponent`, `NativeFailure`, `NativeOutcome`,
  and `raiseReported` to `Internal.Capture` (both re-exported as before), so the
  monitor model needs no import of the session. `MonitorId` is the session
  `Unique` plus a never-reissued number per connection; native addresses are
  kept only as correlation tokens. A connect or disconnect event for an address
  ends its identity; overflow past 64 changes, an undefined event code, or a
  callback fault ends every identity; an inconsistent enumeration makes the
  monitor list `Unavailable`. `resolveMonitor` refreshes, then answers
  `MonitorDisconnected` before any monitor-targeted call; the private
  `withResolvedMonitor` lends the fresh pointer to one step (GLFW-6's hook). The
  owner loop calls `reconcileMonitorEvents` after native events. Release order:
  inventory close, monitor callback detach, terminate, error callback, monitor
  storage free, guard; seam entry now ends with `CreateMonitorCallback`,
  `AttachMonitorCallback`, `QueryMonitors`, `QueryPrimaryMonitor`. The CAPI
  wrappers warn on GLFW's `const` returns, so four shim accessors restate them.
  Xvfb exposes one 1280x1024 monitor; hotplug is model-tested, and the native
  hotplug example is pending unless `HETOIMASIA_MONITOR_HOTPLUG_SECONDS` is set.
  Contract: `docs/glfw.md`, "Monitors".
- GLFW-9 (#95) made the host's windows dynamic. `WindowHost` owns them through
  GLFW-10's `Collection` (limit `hostWindowLimit`, default 16, validated as
  `WindowLimitRejected`); configured and created windows alike are members built
  from `windowAssembly`, each with a private per-window `WindowCommandHost`
  (`PortScope` `WindowScope`: creation and other windows are rejected at
  execution, costing budget). `hostWindows` was removed: `withHostWindow` lends a
  window, `hostWindowIdentities`/`hostWindowClient` enumerate. Commands gained
  `createWindowCommand`/`closeWindowCommand`; `commandWindow` and
  `submittedWindow` are now `Maybe`. A completion cell holds a `Settlement`: the
  prepared disposition plus, beside it, a created window's `WindowClient` (port
  and reader), read with `pollWindowClient`. The close protocol (command,
  `closeHostWindow`, `honourHostCloseRequest`) closes the window's port and
  settles its queue in one transaction, publishes `WindowClosing`, and retires
  unless a borrow is in progress (retried at turn step 3); a failed release is
  forgotten, never retried, and latched by the collection. `WindowPhase` gained
  `WindowClosing` and `WindowDisposalFailed` (a part failed but release stayed
  certain), so a lexical window whose detach reports an error now ends
  `WindowDisposalFailed`. Dispatch is round-robin from a cursor over the host
  port then window ports; a command at queue position `k` is attempted within
  `⌈k·P/B⌉` turns. Quiescence closes every port. Registration uses the
  collection's additive `acquireMemberThen`: construction runs with the caller's
  masking state (so an external cancellation rolls it back), and the host's
  registry insertion is the masked handoff. The closing commit and the
  `WindowClosing` publication share one STM transaction. The implementation lives
  in the private `runtime-glfw-core` (`Hetoimasia.Runtime.GLFW.Internal`, with
  test-only `HostHooks`); the public module re-exports it.
  Examples catching cleanup evidence must catch inside `asProcessMainThread`,
  because `runInBoundThread` drops exception context. Contract: `docs/glfw.md`,
  "Dynamic windows" and "Fair dispatch".
- GLFW-5 (#96) added ordinary window controls: the private model module
  `Hetoimasia.GLFW.Internal.Control` (pure validation, constraint call order,
  outcomes, capabilities; `Extent`/`Placement` moved to `Internal.Attribute`),
  `controlWindow` in the window model, and eleven smart constructors in
  `Hetoimasia.GLFW.Command` over a private `ControlWindow` command. Validation
  runs on the owner thread after reconciling captures and before any native
  call; out-of-constraint sizes are refused, never clamped, and sizes must meet
  an aspect ratio by exact cross-multiplication. `Disposition` gained
  `Unsupported` and `Attempted` (outcome plus `PostCallRevision`, a revision the
  forced post-call sample published); `CommandRejection` gained
  `ControlRejected`. Constraint updates call size limits then aspect ratio,
  mark the state indeterminate first, and report `ConstraintUpdateFailed` with
  returned, failed, and unattempted calls; sizes are refused while
  indeterminate. The `Native` table gained the control setters and
  `nativeWindowCapabilities`; `backendWindowCapabilities Wayland` names position
  and focus unperformable and placement and iconified unreportable, and
  unreportable attributes are neither queried nor captured. A private per-window
  mode transition marker (`setModeTransition`, seam `seamSetModeTransition`)
  refuses controls; GLFW-6 is to be its only producer. Native checks use
  test-only queries (`windowSizeForCheck`, `windowPositionForCheck`,
  `windowTitleForCheck`, `windowStateForCheck`). Contract: `docs/glfw.md`,
  "Window controls".
- GLFW-8 (#99) added `Hetoimasia.GLFW.Input` over the private
  `Hetoimasia.GLFW.Internal.Input` (model sublibrary). Each host window owns one
  `InputFeed` (`hostInputCapacity`, default 256, `InputCapacityRejected`), handed
  out through `WindowClient` as an opaque `InputReader` (read, wait, acknowledge,
  statistics) and `InputControl` (`enableInput`/`suspendInput`). The feed's whole
  state is one `TVar`: phase (running, reset pending, reset acknowledged,
  closed), running epoch, current channel generation, application admission
  (`AwaitingReadiness`, `InputEnabled`, `InputSuspended`), focus gate, held
  key/button `IntSet`s bounded to GLFW's domains, the latest episode as a
  `ResetSummary`, and `Natural` counters. Overflow or post-readiness suspension
  aborts and drops the channel in one transaction, reserving `epoch + 1`; the
  token carries the feed's `Unique` and that epoch. An overflow episode owes a
  `glfw.input` warning claimed by the private `attemptOverflowWarning`; a failed
  or cancelled attempt is recorded and not retried, and counts as complete for
  resumption. The private producer (`produceInput`, `recordCursor`,
  `produceButton`), warning, and `resumeInputWith` are driven only by
  `glfw-window-examples`' `Test.GLFW.Input`. The window close protocol and host
  quiescence close feeds. GLFW-12 (#100) connects the native callbacks and the
  owner loop. Contract: `docs/glfw.md`, "Input feeds".
- GLFW-12 (#100) registered per-window key, character, mouse button, cursor
  position, cursor enter/leave, and scroll callbacks as protected resources of
  the window assembly, reusing GLFW-2's focus callback rather than a second
  owner. Each callback copies a fixed payload and returns. Ordered events stage
  in a bounded buffer of 256; overflow sets a loss latch that survives the
  buffer being full, and the next owner boundary discards the batch and starts
  the same `InputOverflowed` reset, with no prefix replayed. Cursor motion
  coalesces into `observedCursorPosition` / `observedCursorInside` and the
  feed's cursor sample. The host attaches each window's feed at registration
  and, on `runOwnerLoop`, claims the overflow warning through `loopLogger` and
  resumes acknowledged feeds after event reconciliation and after command
  work, because setters can invoke callbacks. Native examples inject through
  the registered C trampolines (`hetoimasia_glfw_inject_*_for_check`); hidden
  test windows use that fixture owner-thread path, recorded with the suite.
  Contract: `docs/glfw.md`.
- GLFW-6 (#98) added window modes: the pure private model
  `Hetoimasia.GLFW.Internal.Mode` (requests, saved placement, `ModeRecord`,
  `AppliedMode` derived from sampled decoration, fullscreen monitor, and work-area
  containment, plans, the windowed placement policy, claims, outcomes), public
  `Hetoimasia.GLFW.Mode`, `setWindowModeCommand` settling as `Transitioned`, and
  `transitionWindow`/`reconcileWindowMode` in the window model. Each attempt is
  a `recover` attempt inside `withResourceLabelled` whose release restores
  windowed constraints; cleanup failure yields `ModeRecoveryStopped`. Samples now
  query `DecoratedAttribute` and `glfwGetWindowMonitor` (the pointer is compared
  with the inventory's connections without a refresh, `Unavailable` while changes
  are unfolded). `ControlState` splits preserved windowed constraints from
  `NativeConstraints`; controls check `controlEligibility` by applied
  presentation. The session holds `sessionClaims` (`MonitorClaims`), pruned to
  live identities when consulted; window release disposes them only on
  `WindowReleased`. The owner loop calls `reconcileWindowModes` after its monitor
  refresh. `WindowConfig` gained `windowStartupMode`. The seam tracks decoration
  and monitor per window, geometry with `scriptTrackWindows`, applies a step's
  effect only when it reported nothing, and takes windows off a detached monitor.
  `WindowOperation` gained `BorderlessOperation`/`FullscreenOperation`; Wayland
  names borderless unperformable. Contract: `docs/glfw.md`, "Window modes".
- Console `--smoke` needs no GPU, Lua, window, network, or Synarchy process.
- Planned component directories contain ownership notes, not implementations.
- Local Git initialized on `master`, with `origin` pointing to
  `https://github.com/coghex/hetoimasia.git` for the authorized initial baseline.
- GHC 9.12.2 / Cabal 3.16.1.0 verified locally. Hackage index baseline copied
  deliberately from Synarchy: 2026-08-14T00:00:00Z.

## Bootstrap verification — 2026-09-10

- `cabal build all`: passed for all three packages with local warnings as errors.
- `cabal test hetoimasia-tests --test-show-details=direct`: passed four Hspec
  checks covering filtering, sink failures, action ordering/results, and failure
  propagation without a false completion entry.
- `cabal run exe:hetoimasia -- --smoke`: passed with the three expected log lines.
- `cabal check` in all three package directories: exit 0 with no warnings.
  All packages declare the confirmed GitHub source repository.
- Local documentation links resolve; all package copies of GPLv3 match the
  full text retrieved from `https://www.gnu.org/licenses/gpl-3.0.txt`.

## Kanban integration — 2026-09-10

- Kanban's read-only doctor passed all issue/PR actions for this checkout.
  Shared review backend, Codex plugin, and Claude plugin setup plans all reported
  unchanged. These dependencies are user-installed outside the repository.
- The repository vendors the docs landing helper and checker from Kanban,
  with its MIT notice retained under `tools/`. The local adaptation supports
  the regular authoritative `AGENTS.md`; no instruction-file migration is needed.
  Provenance and checks are recorded in [tools/README.md](tools/README.md).
- Use `kanban:push-docs` for user-requested standalone documentation batches.
  Mixed code/docs remain in the same PR. Plugin-owned design/report helpers
  come from the installed bundle, not this repository's `tools/` directory.
- The owner then supplied Kanban's missing-service screenshot. Installed the
  issue-approval and PR-drainer jobs for `coghex/hetoimasia` using Kanban's
  installer/controller. Both are loaded in launchd and have not been started;
  the approval controller has no run-status document yet. Board keys `a` and
  `d` control them.
- The owner explicitly approved publishing this tested tooling setup directly
  to `master` as a bootstrap exception. Subsequent implementation still follows
  the normal PR lane. The ready designs were separately published in `0d9be37`.

## Open choices and next work

- CI runs the validation pipeline and the review gate described in
  [validation.md](docs/validation.md). `build-test` and `review-approved` are
  the checks the installed drainer reads. A prose-only update now inherits an
  earlier run's code evidence through candidate input identity and receipt
  artifacts. Review inheritance requires a proven approved revision and an
  identical-tree push or an exact clean merge with a commit already on master;
  CI evidence is assessed independently. See [workflow.md](docs/workflow.md). The
  selected GitHub repo was verified empty with zero issues and PRs before the
  initial publication on 2026-09-10; repeat deduplication when turning designs
  into tracker artifacts.
- On 2026-09-10 the owner requested review and readiness of both discussed
  designs. [Logging](docs/logging_design.md) has three slices;
  [resource ownership](docs/resource_ownership_design.md) has four. Both were
  published to `master` on 2026-09-10 as `ready for issue processing`. Logging
  is now implemented (#1 through #4). On 2026-09-11 the owner accepted a review
  of the resource design and re-granted readiness: it records the satisfied
  logging gate, the catalog and test-grouping obligations, and D-6 through D-9
  (uninterruptible bounded release, exception-annotation evidence with rethrow
  rules, bracket argument order with `withScoped` as the only runner, and a
  staged composite constructor). No `smoke.resource` catalog group. The
  original resource proposal path is now a navigation stub.
- The logging-first gate is satisfied: LOG-3 (#4) merged in `cb2a25d`.
  Resource primitives themselves remain independent of the logging module.
- Accepted resource failure policy: retain the original action/cancellation
  failure, preserve secondary cleanup failures independently of logging, and
  attempt remaining eligible cleanup. Cleanup-only failure fails the operation.
  Preserve typed catch behavior and inspectable structured evidence.
- The resource design selects a small scoped continuation facade for
  `allocResource`/`locally`, over safe CPU ownership and composite constructors.
  The runtime design uses explicit IO and narrow handles over this facade;
  an application-wide monad is outside the accepted arc. Dynamic ownership transfer and
  GPU retirement are later work. FND-1 reuses the resource epic and its children;
  do not create a second implementation from the broader foundation plan.
- Unicode type syntax is retained; standard Prelude is the bootstrap choice.
  A broader custom operator/prelude policy is undecided.
- The first rendering milestone is a window with a rendered triangle, explicitly
  selected by the owner. On 2026-09-12 the owner selected macOS and Linux
  verification from the start, with Linux-only remote CI and macOS validation
  locally. Do not add hosted macOS jobs. The Vulkan baseline, thread/ownership
  APIs for graphics, Linux graphics test environment, render contract, and Lua integration
  still need bounded design. See [the backend design](docs/vulkan_backend_design.md).
- The owner clarified that reusable infrastructure must come before Vulkan:
  messaging, runtime initialization/lifecycle, threading, and GLFW should be
  developed methodically and validated independently. The triangle is an
  eventual graphics milestone, not a near-term demonstration target. Queues
  with Hspec coverage are accepted as pre-graphics work; include worker
  lifecycle before Vulkan even though a triangle alone would not require it.
- Separate GLFW and Vulkan components and a first main-thread window/render
  loop are accepted. Worker support does not move GLFW's owning-thread
  operations. The resource continuation is implemented. The
  [runtime foundation design](docs/runtime_foundation_design.md) now specifies
  component contexts, scoped construction, recovery, worker ownership,
  supervision, and boot/shutdown composition through explicit IO and narrow
  handles. RT-5 (#57) implements the raw worker contract in foundation's
  `Hetoimasia.Foundation.Worker` ([docs/workers.md](docs/workers.md)): a group
  boundary with a `Scoped` adapter, gated fork/registration, STM startup and
  terminal observation, run-exit ordering, group-owned cancellation helpers,
  retirement, and a protected drain; it adds `stm`, not `async`. Supervision
  (RT-8, #59) is implemented in `Hetoimasia.Runtime.Supervision`, and
  application integration (RT-6, #60) in
  `Hetoimasia.Runtime.Application.runScopedApplication`; `runApplication` stays
  the thin runner that only logs around an `IO` action.
- Runtime epic #52's eight children #53–#60 are merged, along with supervision
  repairs #69 / PR #71 and #70 / PR #72. Review at `8979877` on 2026-09-13
  found no remaining blocking repair: local build, 298 engine and 262 workflow
  Hspec examples, both smoke modes, and the two original evidence-loss
  reproductions pass; current-master Linux CI is green. Review coverage includes
  PRs #61–#68 and #71–#72. The owner requested completion housekeeping;
  epic #52 is closed with its checklist complete. Do not create duplicate runtime issues or
  reopen accepted D-13 through D-18 decisions. Workers keep borrowed dependencies
  alive until completion; supervision uses checkpoints and supervised waits;
  logging finalization has its own IO lifetime outside controlled releases.
  Application services remain application-owned and immutable. Messaging and
  independent GLFW work still need their own designs before Vulkan.
- Messaging design started in [docs/messaging_design.md](docs/messaging_design.md)
  against `8979877`, with Synarchy `fe225c5` inspected read-only. It is now
  `ready for issue processing`, by owner signoff on 2026-09-13 (D-12):
  the owner approved typed bounded FIFO channels plus latest-value snapshots,
  deferring broadcast/request-reply; ordinary sends report Full immediately with
  waiting explicitly selected; close preserves backlog and explicit abort discards
  it (D-4 through D-6). Publication requires opaque payloads prepared to normal
  form through NFData in producer IO (D-7). Snapshots start with an initial value,
  use independent opaque cursors checked against snapshot identity, retain the
  final value after close, and deliver an unseen final publication before EOF
  (D-8). Initial telemetry is atomic counters, with timestamps and queue-age
  measurement deferred (D-9). The owner also approved explicit graceful finish
  (close, process accepted work, acknowledge drain, request stop, await cleanup),
  aborting backlog on ordinary stop without replaying in-flight effects (D-10),
  and the optional reusable runtime adapter for supervised inbox services (D-11).
  All eight behavioral questions are resolved. Six delivery slices cover
  payload preparation, an additive STM origin-aware failure helper, FIFO,
  snapshots, supervised inbox startup/stop, and acknowledged graceful finish.
  Cross-agent feedback was checked against the code and installed GHC/STM
  sources: MSG-3 needs MSG-1 only; MSG-2 gates the snapshot cursor check in MSG-4.
  The accepted design makes startup handoff non-retrying after acknowledgement,
  closes inbox admission before component teardown, counts aborts from depth
  without traversing backlog, and preserves prepared handles through reads.
  P-8 specifies a private ordinary-stop exit record: MSG-5 exposes cumulative
  discards only, and MSG-6 adds drain state with the actual finish protocol.
  An escaping synchronous handler exception terminates dispatch and follows the
  existing worker/supervisor failure policy; only explicit safe recovery inside
  the handler can continue. There is no per-message catch-and-continue or replay.
  Cancellation/cleanup failure retains its original completion instead of
  fabricating an ordinary result. STM failure origin matches the engine annotation,
  without promising the IO throw primitive's additional backtrace.
  The corrected specification and split are approved for processing; the tracker
  readiness recheck found no overlapping arc. No messaging issues or implementation
  have been created, and the design remains unpublished.
- The owner wants Synarchy's solid GLFW integration preserved deliberately.
  The backend design records its existing window/callback, resize, Vulkan
  synchronization, and shared-scope test decisions as reuse evidence.
- Review at `7e92e73` found no current defect in the cleanup-evidence opacity
  repair (#47 / PR #48) or TEST-1 (#50 / PR #51). Local checks passed 145 engine
  and 262 workflow examples, build, smoke, and the three focused component
  selections; an empty selector fails. Logging, Runtime, and Resources now
  compose through `Test.Engine.Spec`. Graphics fixtures were then deferred
  TEST-2; GLFW-7 (#93) has since delivered the first shared native fixture,
  and Vulkan fixtures remain the Vulkan arc's work. Earlier bootstrap entries above are
  historical snapshots, not the present resource implementation inventory.
- No engine save format or game migration commitment exists yet.
