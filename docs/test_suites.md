# Test suites

Moved from `AGENTS.md`, which points here. Choose what to run with
`python3 tools/validation/plan.py --base origin/master --head HEAD`
([validation.md](validation.md)); the tiers and the `$test` probe inventory
are in [test_classification.md](test_classification.md).

## Focused suites

```sh
cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct
cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct
cabal test hetoimasia-glfw:glfw-tests --test-show-details=direct
cabal test hetoimasia-scripting-lua:lua-host-tests --test-show-details=direct
cabal test hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-show-details=direct
cabal test hetoimasia-gpu-vulkan-model:gpu-model-tests --test-show-details=direct
cabal test hetoimasia-gpu-vulkan-diagnostics:diagnostics-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-math:math-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-content:content-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-asset-image:asset-image-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-render-api:render-api-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-render-2d:render-2d-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-render-2d-oracle:render-2d-oracle-tests --test-show-details=direct
cabal test hetoimasia-tests --test-show-details=direct
```

## Platform-only confinement probes

- On Linux only,
  `cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct`
  runs LUA-14's confinement probe. Its validation group
  `test.lua-confinement-linux` is optional and local-only; a green run is
  evidence rather than a verdict: where the machine cannot install the profile
  every experiment reports itself unproven. Its components are not built off
  Linux. Read [its verdict](archive/lua_linux_confinement_verdict.md) before
  building on it — the answer is `inconclusive`.
- On macOS only,
  `cabal test hetoimasia-scripting-lua:macos-confinement-probe --test-show-details=direct`
  runs LUA-15's confinement probe. It is local evidence, not a routine check:
  its validation group `test.macos-confinement` is optional, no CI runs it, and
  its components are not built off Darwin. The library owns its two threads (an endpoint's
  backlog thread and a launched helper's output reader) with `base` alone, and
  `Test.MacOS.Ownership` (`--test-options='--match "#598"'`) judges both. A pull-request request block must
  name neither it nor `all-hspec`. Read
  [its verdict](archive/macos_confinement_verdict.md) before building on it — the
  answer is `inconclusive`.

## Which suite owns what

- Tests belong to the package whose contract they assert. `foundation-tests`
  (`packages/foundation/test/`) owns the `Logging`, `Resources`, `Failures`,
  `Recovery`, `Workers`, `Messaging`, and `Time` components, composed by
  `Test.Foundation.Spec`; it depends on no runtime, GLFW, or console code.
  `runtime-tests` (`packages/runtime/test/`) owns the `Runtime` group, composed
  by `Test.Runtime.Spec`: the runner and application lifecycle, logging
  lifetime, reporting, supervision, inbox services, runtime opacity, the
  resource smoke, and the supervised channel and snapshot waits, against real
  foundation services; it depends on no GLFW or console code. `glfw-tests`
  (`packages/glfw/test/`) owns the headless `GLFW` group, composed by
  `Test.GLFW.Spec`: the session, window, command, control, host, dynamic
  window, monitor, input, and mode examples over the test seam, the link
  declarations, and the external-client opacity examples; it initializes no
  GLFW and needs no display. Root `hetoimasia-tests` (`test/`, composed by
  `Test.Engine.Spec`) is **profile-dependent**. In the default and CPU builds it owns only
  `Console` (the executable's startup and exit mapping, run as a child process) and depends on
  no GLFW package; its second source directory is `test-cpu/` and adds nothing. In the
  full-product build (the Vulkan project, flag `full-product`; group `test.vulkan-headless`) it
  also owns `Run` (`test-full/`): the `hetoimasia run` command's grammar, the exit status as a
  pure function (including `--vulkan-validation`: accepted before the folder, a literal root after
  `--`, and each usage error), the exit status as a pure function, the production host's empty
  request and the optional validation's record, the composition over real temporary content with no
  graphics (roles, failures, boot refusals, stops), the built executable's usage, help and boot
  refusals, and the suite's own binary as a child under real signals. None acquires a native session, reads consent or opens a
  window. Every helper thread these examples start is an owned thread (#600, `Test.Support.Owned`): the callers of
  the production scope and the senders that interrupt them, the writers queued in a held sink, the scenario thread beside the
  command, the 32 clients of the signal coordinator's overlap example and the runner of the console's exit path are ended and
  joined when the example's scope returns, whether the example returned, failed or was cancelled. A thread held at a gate only
  the example opens has the gate opened by the scope (`withOwnedThreadOpening`), and a thread that supplies what an exit needs
  (a sender, the scenario that signals the command) is in a scope that encloses that exit. Four shapes have regressions that
  run twice with one judgement, through the facility and through the deliberately unowned start of `Test.Engine.Unowned`
  (the negative control, which must fail): a caller parked in the queued callback before it is armed, with its sender and the
  production session it started; a caller held uninterruptibly by the child it asked to stop; and the 32 signal clients held
  at their start gate. Select them with `--test-options='--match "#600"'`. A
  new runtime example belongs in `runtime-tests`, beside that component's own
  helpers; a headless GLFW example belongs in `glfw-tests`, and one that needs a
  real native session in `glfw-native-tests`; a console example belongs in root
  `Console`;
  in general a new example belongs in the component spec that owns the
  behaviour it asserts. `lua-host-tests`
  (`packages/scripting-lua/test/`) owns two components: the bridge's own
  examples (the module loader's, LFE-9, among them: `--test-options='--match "the module loader"'`, `"the loader's"`,
  `"stopping the loader"` and `"failures of the engine"`; LFE-11's placed roots, `"placed roots"`, and the export table crossing
  into Lua by reference, `"an export table crossing"`), and `Protocol` (`Test.Lua.Protocol.Spec`), the pure task,
  admission, request, subscription, epoch, failure, and stop model in the
  package's private `model` sublibrary. Select the model's examples with
  `--test-options='--match Protocol'`; they construct no interpreter, and the
  group's last example reports that they acquired none. Every VM the suite
  constructs goes through `Test.Lua.Support.acquireVm`, which is what makes
  that report the suite's whole construction record. Run one component with
  `--test-options='--match <Component>'` on the suite that owns it; a selector
  that matches no example fails the suite rather than reporting a silent pass.
  Every thread this suite starts is owned (#598): started through
  `Test.Support.Owned`, with the gates an example alone opens let go by the registered stop,
  except the `detached` runner and the two starts of the `Reentry` examples, which run inside
  an owner that may be trapped in a `safe` foreign call and stay in the guard's baseline with
  their reason recorded at the start. The regression examples for the helpers that start
  threads, with a negative control each, are `Test.Lua.Ownership`
  (`--test-options='--match "#598"'`).
  `lua-runtime-tests` (`packages/scripting-lua/runtime-lua-test/`, composed by
  `Test.LuaRuntime.Spec`, group `test.scripting-lua-runtime`) owns the runtime
  adapter's examples (every thread the suite starts is owned, #598: the example bound
  `Test.LuaRuntime.Support.boundedAfter` ends and joins its watchdog and interrupter before it
  returns, and the regression examples with their negative controls are
  `Test.LuaRuntime.Ownership`, `--test-options='--match "#598"'`): readiness, identity, submission and its bounds,
  settlement, host failures, stop, independent owners, and the refused reply
  wait from a Lua callback, with real VMs under a real `withSupervision`, the module loader hosted on a scheduled
  owner (`Test.LuaRuntime.Loading`, `--match 'module loader on a scheduled owner'`, LFE-9; its `placed roots` examples are
  LFE-11's), the scheduler's `tickQuietBefore` (`Test.LuaRuntime.Scheduler.Requests`), plus
  the adapter's dependency closure, which needs no VM. It selects and fails on
  an empty selection the same way.
  `lua-engine-tests` (`packages/lua-engine/test/`, composed by `Test.LuaEngine.Spec`,
  group `test.lua-engine`, the CPU project) owns the Lua-first engine's pure
  configuration boundary (LFE-3): the strict manifest parser's accepted examples,
  byte and nesting limits, syntax and schema refusals and exact tick conversion, the
  fixed M1 profile and its smaller validated test profiles, and the package's
  dependency and import boundary, the manifest and entry boot checkpoint (LFE-6)
  composed with the content inventory over real temporary folders (`Test.LuaEngine.Boot`), the M1
  behavior selection and the export-module and loader ceilings the profile gives a VM, the session coordinator
  (LFE-13, `Test.LuaEngine.Session.*`, `--match Session`: the pure model and its invariants after every step of every sequence of
  five events, and real Lua on real owners the coordinator starts, with an injected clock, a fake timer, recording sinks and held
  points: both `init` orders, validation before either root, stop and failure on each side of the gates, the clocks and their
  limits, the failure policy, the evidence, the stop and drain, construction and cancellation at every step of every acquisition, the
  teardown protocol of every exit (the all-owner stop barrier, one accounting commit, the drain proof, the registered releases and a retirement
  published only when proven, each with a control that removes the protection it proves; the logger held at each class of site while a stop, an owner's end, its drain and its retirement go on, because the session's own writer is the only caller of the sink; and every text of the failure record counted in its bound), and a separately compiled client),
  and the M1 request adapter
  (LFE-7, `Test.LuaEngine.Request.*`): the busy record, the exact `ready`/`take`/`cancel`/`wait` records, handles
  and phases, the profile's limits, a texture lease, and required and optional failure, over real Lua instances on
  a supervised owner with controlled fake providers. The owned texture pipeline (LFE-16, `Test.LuaEngine.Texture.*`) is
  covered over a real content root, inventory and shared read pool, the real bounded PNG decoder and a gated fake upload
  backend: the admission banks, the lanes, workers and queues, the stage-by-stage charges, cancellation at every stage,
  failures, independent loads and release, the close and drain, and a separately compiled public client, The fixed M1 scene schema (LFE-19, `Test.LuaEngine.Scene.*`, `--match Scene`) is covered on real instances that own real textures behind the injected backend and a controlled sink: the schema's accepted and refused tables, the colour and geometry rules, the limits at the limit and one past under the fixed and smaller profiles, the calling instance's texture authority, refusals as ordinary Lua errors, and the translation to the renderer's snapshot under its validation, draw plan and oracle; the host's per-binding argument limits are `lua-host-tests`' (`Test.Lua.Boundary.ArgumentLimits`) and the non-throwing lease borrow `lua-runtime-tests`' (`Test.LuaRuntime.Instance.Lease.*`). The module coordinator (LFE-11, `Test.LuaEngine.Modules.*`, `--match Modules`): real modules through real VMs on supervised scheduled owners over a real content root, inventory and read pool, with the production reader behind gates and nothing slept, and a separately compiled client. The authoring facade (LFE-12, `Test.LuaEngine.Facade.*`, `--match Facade`): the accepted P-72 example, every call's schema table-driven in every role and phase, instance ownership, the lexical import and the instance-rooted requests, the request records, the role clocks and waits under an injected clock and fake timer, print and warn with their exact bound, the sinks under contention and failure, and a separately compiled client, on real instances over a real content root, inventory and read pool with recording sinks and nothing slept. It starts no window or GPU; its one example of the Lua host's
  module loader under the fixed profile (`Test.LuaEngine.Loader`, LFE-9) starts an in-process Lua owner. A new
  manifest or profile example belongs there, in the component spec that owns it.
  Every helper thread `lua-engine-tests` starts is an owned start through `Test.Support.Owned` (#599): the scenario runners
  (`runScenarioWith`, `runCaught`, `runHeld`), the cancellers, closing threads and workers parked in a held sink, grant or
  hook, and the two helpers of the texture suite (`withJanitor`, and `withNested`'s helper, which supplies what the nested pipeline's
  drain waits for and whose scope therefore encloses that exit). However the scope that needed a thread ends, it has ended and been
  joined before the scope returns, and what only the example can open (the held sink, the pool reader's gates, a recorder's
  hold) is let go by the same release, before the kill. The shapes have regressions (`Test.LuaEngine.Owned`,
  `--test-options='--match "the threads the helpers start are owned (#599)"'`) that run twice with one judgement, through the
  facility and through the previous form of the helper or the deliberately unowned start of `Test.LuaEngine.Unowned` (the negative
  control, which must fail): the runner's thread when the session's run is cancelled before the scenario started and when the
  example is cancelled once the session has ended, a canceller waiting for a point never reached, a writer parked in a held sink, and a
  supplier that is not ended before the exit it serves. The runner's seams (`RunnerSeams`) exist test-side only.
  `lua-runtime-tests` also owns the host's opt-in admission (`Test.LuaRuntime.Admission.*`, including the caller's instance),
  the notification of a hook's segments (`Test.LuaRuntime.Instance.Behavior`, `--match 'notification of a hook'`), the elapsed wait through the whole
  Word64 range (`Test.LuaRuntime.Scheduled.Execution`) and the shared bounded output (`Test.LuaRuntime.Runner.Output`)
  and `lua-host-tests` the argument checks (`Test.Lua.Boundary.ArgumentChecks`) and the naming of the module whose code runs (`Test.Lua.Boundary.Loader`).
  `content-tests` (`packages/content/test/`, composed by `Test.Content.Spec`, group
  `test.content`, the CPU project) owns the content package's anchored native roots, its
  logical identity policy and, from LFE-6, its bounded whole-folder inventory and verified
  reads, over temporary trees each example owns. Select a component with
  `--test-options='--match <Component>'`: `Roots`, `Links`, `Reading`, `Enumeration`,
  `Lifecycle`, `Opacity`, `Identity`, or `Inventory` with its components `Scan`, `Limits`,
  `Changes`, `Aliases`, `Reading`, `Lifecycle` and `Inventory boundary`. A new inventory
  or verified-read example belongs there, in the component that owns the behavior.
  Selectors moved with their examples: on the root suite, `--match Runtime`,
  `Resources`, `Recovery`, `Workers`, `Messaging`, `Logging`, `Failures`, and
  `GLFW` now select nothing and fail; on `runtime-tests`, `--match Supervision`
  or `--match 'Logging lifetime'` select runtime subgroups as they did at root,
  and on `glfw-tests` the GLFW group names, such as `--match 'GLFW session'`,
  select what they selected at root or in the removed window-examples executable.
- Every helper thread the `foundation-tests`, `runtime-tests` and `asset-image-tests`
  suites start is an owned start through `Test.Support.Owned` (#597): however the scope
  that needed it ends (a return, a failed assertion, a timeout of the example, a
  cancellation) the thread has ended and been joined before the scope returns, and a
  thread held at a gate only the example can open (an uninterruptible release, a
  worker parked behind a hook) is let go by the same release, before the kill. A gate
  opener or observer that supplies what a surrounding exit needs in order to finish
  encloses that exit. Each suite's helpers are scoped (`withOwner`, `withWaiter`,
  `withChild`, `withObserving`, `withOpenWhenWaiting`, ...), and each family has an
  example that ends the scope by a failing body and by a cancellation and judges the
  thread, with a negative control that applies the same judgement to the previous
  unowned start and must fail. They are selected, on `foundation-tests`, by
  `--match 'The owner helper'`, `--match 'The runner of a production scope'`,
  `--match 'The masked runner'` and `--match 'The waiter helper'`, and on
  `runtime-tests` by `--match 'The gate opener'`. The controls keep their one raw start
  in `Test.Foundation.OwnedControl` and `Test.Runtime.OwnedControl`, exempt by binding
  (see [validation.md](validation.md#the-owned-start-guard)). A new thread in these
  suites is started through the facility, as the guard requires.
- `workflow-tests` (`tools/test/`, group `test.workflow`) owns the contracts of
  the workflow tooling and, since #584 and #588, the shared owned-thread and
  owned-subprocess facilities and the guard that keeps test sources using them.
  Select them with
  `--test-options='--match <name>'`: `the shared owned-thread facility`
  (`OwnedThread`: every way a scope can end with a thread parked at a gate, each
  with a negative control that applies the same judgement to a deliberately
  unowned start and must fail; the thread that ended on its own; the
  uninterruptible release; the interruptibility the body runs with; since #610 the
  capability-pinned starts (`withOwnedThreadOn`, `withOwnedThreadOpeningOn`: every
  ending again, the thread placed and pinned on the capability asked for, a
  cancellation pending against a masked target from the moment its sender, on the
  same capability, is seen blocked, a deterministic negative control (a sender
  blocked delivering to a decoy leaves nothing pending, and the target's effect
  runs), and a scope cancelled after the target entered its step and before its
  sender was published that still joins); since #593 the
  owned bound start (`withOwnedBoundThread`: every ending again, with a plain
  `forkOS` start as the negative control; the thread is bound and the unbound
  start is not; the gate the scope opens for a thread that keeps waiting after a
  kill; the interruptibility the body and the thread run with; and a cancellation
  already pending when the start returns from its acquisition) and the rescue of
  the negative controls themselves (a worker registered even when a cancellation
  is pending as the control starts it, and a stop-and-join that a pending
  cancellation does not abandon); the
  cancellation helpers behind the two `Library.hs` helpers and the parked-release
  orchestration behind `ChildSpec`, with their former unowned forms as controls)
  `the shared subprocess facility` (`OwnedSubprocess`: a command run to completion
  (status, both streams beyond a pipe buffer, environment, working directory and
  input, a descendant holding a pipe open past the drain bound, a run bound that
  expires on a child that ignores SIGTERM, a cancelled call, and a converted
  helper that suites call, `Sandbox.run`); a scoped child ended whichever way its
  scope ends (a return, an exception, the run bound, a cancellation in the body,
  a failure after the child exists, a cancellation delivered while the release is
  parked) with its descendant in the group; a leader that exits on SIGTERM or by
  itself while a descendant ignores it; the escalation (SIGTERM then SIGKILL to
  the group, no SIGKILL to a child that obeys, nothing to a child that left no
  member); a reap or a group's end that is not confirmed, injected through the
  facility's test-side seams; the stream choices and the handles the caller
  opened; a child that has exited and not been reaped; where a child is placed (a
  group of its own in the caller's session, or the caller's group with only its
  identifier signalled); a call that states no bound and is unbounded; and a test-owner
  process, this very executable re-run with `HETOIMASIA_SUBPROCESS_OWNER` set,
  whose process group is ended from outside while its body is parked. Each
  ownership and timeout example has a negative control that applies the same
  judgement to the library call the converted sites used and must fail),
  `the hosted subprocess` (`OwnedHost`, #608: every cell of the host's state-by-operation
  table and every row of its cause table, each example named after its cell; the three
  abandonment races for a request's handles; a cancellation delivered into each cleanup
  the host adds; the limit of a body that is not cancellable; and a captured run, the
  shape the display-helper suites use; none sleeps, and a run bound passes when the
  example says so) and
  `The unowned-start guard` (`OwnedStarts`: fixture trees for a new unowned
  start, an owned start, a baselined start, a stale or shrunken baseline entry, a
  count raised with its baseline, a new start in a file that has an exempt helper,
  and the three sites the issue named; then this repository: the guard passes,
  the baseline has not grown, and every directory it scans is an input of the
  group). The facility's own sources live in `tools/test-support`, which both
  `workflow-tests` and `run-native-tests` depend on; the real child helper runs
  under the same parked-release orchestration in `Test.Run.Native.ChildSpec`
  (group `test.vulkan-run-native`, selected with `--match 'the child helper'`).
  A test that starts a thread starts it through `Test.Support.Owned`, and one that
  starts a subprocess through `Test.Support.Subprocess` (#588 converted the
  subprocess sites the baseline listed; #608 converted the two display-helper suites,
  which run the helper on a host of `Test.Support.Subprocess.Host` so that its
  process group outlives the call, and whose probe calls are one-shot owned calls). `glfw-tests` was converted in #593 and #612: every thread it starts is owned
  (`Test.GLFW.Support`'s `onThread`, `onBoundThread`, `withDeferredThread`, `withMainThread`,
  `withMainThreadKeepingContextVia` and the scoped helpers beside the specs that use them), and no
  baseline entry is left for it. #593 was narrowed by the owner (2026-11-02) and left nine examples
  to #612, which converted or rescued them: `Owner/Port.hs` `testPortFullReported` and
  `testFullPortDoesNotBlockExit`, `Owner/Exit/Settlement.hs` `testUnannouncedDirectAttachSettles`,
  `testUnannouncedClosedSettles` and `testCoherentDestructionSnapshot`, `Owner/Handover.hs`
  `testHandoffOrder` and `testHandoverRecovery`, `Owner/Failure/Interruption.hs`
  `testRetirementRecordSurvivesCancellation` (its harasser is an owned start that
  delivers one cancellation, after the retirement call returned, and the owner's later calls wait for
  it; under `-N2` the old stream of cancellations outlasted the target's retirement and reached the
  owner's destruction, which production rightly leaves unverified; a cancellation that interrupts
  the call instead is its own example), and `Protected.hs`
  `testStallWarningCancelledAtItsSink` (its supplier and runner are owned; the scope that owns the
  runner releases the registered owners and the sink's hold before it kills the runner).
  The seven that hold the owner's startup or its destruction are cut at every boundary of the
  owner's start by `Test.GLFW.Owner.Fixture.Cut` (`boundaryExamples`, and `boundaryControls` where
  the fixture without its rescue strands): the private host hooks `ownerBoundary` (called, on the
  starting thread, with `OwnerBeforePublication` before the owner's handle is published,
  `OwnerPublished` once it is, `OwnerAwaitingStartup` before the wait for the worker's startup, and
  `OwnerStarted` after the start has published it) and `ownerWorkerBoundary` (on the worker's
  thread, which holds the worker before its acknowledgement for the `AwaitingStartup` cut and after
  it for the `AwaitingEntry` cut), the rig's startup callback, and the body's entry, each ending the
  run by a failure, a cancellation pending when the boundary is reached, or a cancellation delivered
  while the run is parked there. A pending cancellation is made pending by a sender pinned to the
  target's capability (`withOwnedThreadOn`, #610), because across capabilities a throw is a message
  that is taken in later. The rescue is the exit's own: the wait for the owner's destruction opens
  the fixture's gate on its first snapshot (`afterDestructionSnapshot`), and the body opens it on
  every way out (`heldBody`). **The four boundaries before the owner's run action begins (#613)**
  have no rescue and no control, because the exit has nothing to wait for: the starter withdraws
  an owner whose worker was drained without running its action, so each of those cells judges that
  the exit finished without a destruction snapshot, that the backend was asked for nothing, and that
  the failure, caught on the main thread where it still carries its context, holds the
  abandoned-start evidence of one drained worker. `Test.GLFW.Owner.Failure.AbandonedStart` holds
  what the matrix cannot say: an owner whose run began and ended without evidence is still waited
  for when the start is abandoned afterwards (and the exit retains everything until independent
  evidence ends the wait), an owner withdrawn from an exit whose quiescence committed before or while
  it was published has its publications closed, and a worker that ends before it acknowledges while
  the start's wait returns is withdrawn too (the owner it returns refuses every publication and handover, and a failure or
  cancellation right after the start returns it finishes the exit; `afterUnacknowledgedExamples`). The examples that hold the
  conversion to account run in `glfw-tests` (`--match '#593'`), each as an owned
  example and a negative control: the start-and-wait helper, the bound
  main-thread helper and the bound start in a session, a deferred thread, a
  submitter, a waiting admission and a publication parked in an admission or
  demand hook with its gate closed (`GLFW admission helper threads`), an injector
  and the helper it never reaches, a runner parked in its construction whose
  rollback waits at a second gate, and an evidence supplier waiting for an owner
  that never exists (`GLFW protected host`, `the drain`). `glfw-native-tests` was
  converted in #594: its `onThread`, `runOwned`'s borrower, the harness's
  `withForked`, the launch-interruption example's launcher, `wokenWait` and
  `wokenWaitBy`, the private-session rounds' wakers and the two Wayland scenario
  workers start their threads through `Test.GLFW.Native.Threads`, which takes the
  boundness (`Unbound` or `Bound`) in place of a fork primitive, and all 17 of its
  baseline references (14 sites) left the baseline; `WaylandScenarios.hs:938` was
  #588's. Its regressions run with no consent in `--match "owns the threads its
  helpers start"` (under `the native opt-in`), each as an owned example and a
  negative control through the deliberately unowned start of
  `Test.GLFW.Native.Unowned`. The thread sites that
  remain in other suites are a known-debt baseline to be removed by follow-up
  changes, not to be extended.

## Vulkan suites

- The Vulkan native backend and window integration packages, the 2D
  renderer's Vulkan recorder (`packages/render-2d-vulkan`), the terrain
  material for it (`packages/terrain-render-2d-vulkan`, TRA-8, with the pure
  `packages/terrain` and `packages/terrain-render-2d` as prerequisites), and the
  triangle, sprites, image2d and scene3d samples, build only through `cabal.project.vulkan`, by
  `bash tools/vulkan/run.sh`. Its test mode runs their headless suites
  (`native-tests`, `shader-tests`, `integration-tests`, `triangle-tests`,
  `sprites-tests`, `image2d-tests`, `scene3d-tests`, `render-2d-vulkan-tests`,
  `terrain-render-2d-vulkan-tests` (the terrain material's declaration, record
  conversion and draw path, device-free),
  the Lua-first engine's graphics adapter's `lua-engine-graphics-tests`, and the root package's
  full-product `hetoimasia-tests`) — the group `test.vulkan-headless` — and needs no consent. The native suite `vulkan-native-tests` (`test.vulkan-native`) opens
  windows and presents on macOS, so it takes the same desktop opt-in, under the
  same standing approval, as `glfw-native-tests`; on Linux its runner starts an
  isolated X11 display, and `test.vulkan-wayland` runs it on the isolated
  headless Wayland compositor. See [gpu_backend.md](gpu_backend.md#the-native-suite).
  Its `tra8-terrain` scenario (TRA-8, Q-13; `--private-roots tra8-terrain`, in the
  complete profile) draws plans of the terrain arena's faces through the existing
  fixed-quad and material ABI into surface-free targets with a real `D32_SFLOAT`
  depth image and judges every pixel against the render-2d oracle and against an
  independent line-of-sight expectation; it creates no window, must finish inside
  the 20-second child deadline, and fails (never skips) where the device chooses
  another depth format. It reads the approved artwork under
  `samples/ecce-homo/content/textures/`. Its evidence is under
  `docs/evidence/terrain/tra8/`.
  Every helper thread `diagnostics-tests`, `native-tests`, `integration-tests`,
  `render-2d-vulkan-tests` and the `allocator-parity-probe` start is an owned start
  through `Test.Support.Owned` (#595): however the scope that needed it ends (a return, a
  failed assertion, a timeout of the example, a cancellation) it has ended and been
  joined before the scope returns. A thread held where only the scope can reach it (a
  hold, a gate, a scene transition's hook) is let go by the same release, before the kill,
  and an evidence supplier, the helper that publishes what a run's exit needs in order to
  finish, is in a scope that encloses that exit (`withRunHelper` of
  `Test.GPU.Vulkan.GLFW.StandIn`). The shared helpers are `onOtherThread` and
  `withOtherThread` (`Test.GPU.Vulkan.Native.Threads`), `withOwnedThreads` (the
  diagnostics `Support`), `onOtherThread`, `withRunHelper` and the `ProceedGate` of the
  integration `StandIn`; the integration suite's example bound, `Bound.hs`, is not
  converted and is recorded as three audited helpers (see
  [validation.md](validation.md#the-owned-start-guard)). Five shapes have regressions
  that run twice with one judgement, through the facility and through the deliberately
  unowned start of each suite's `Unowned` module (the negative control, which must fail):
  the start-and-wait helper, the stepper parked at a held creation with the killer aimed at
  it, a producer held after announcing itself with the lifetime closing around it, an
  evidence supplier (also judged alive when the exit it serves begins), and the thread
  parked in a scene transition with the thrower aimed at it. Select them with
  `--test-options='--match "#595"'` on `native-tests` and `diagnostics-tests`, and on
  `integration-tests` with `--match "#595"`, `--match "owns the thread parked"` and
  `--match "negative control"`.
  Every helper thread `vulkan-native-tests` starts is an owned start through `Test.Support.Owned` (#596): the shared fixture's
  borrower (the Hspec run, served by the process main thread), the interrupted-launch launcher of `a bounded child launcher`,
  the interaction probe's scene thread, the retention case's watcher (its scope is the whole case, because the watcher supplies the
  evidence the host's exit waits for), the bound discharger of the bridge case (`withOwnedBoundThread`), and the killers and workers
  of the construction and publication examples, which are pinned to one capability (`withOwnedThreadOn`; the killer is started with
  the worker and outlives the arm, `Test.Vulkan.Proof.PendingCancellation`). However the scope that needed a thread ends, it has ended
  and been joined before the scope returns. The consent-free regressions are in the suite's approval-free group, `--match "without a
  native session"`: `a bounded child launcher` (the launcher and its child, by a failure and by a cancellation) and `the shared
  fixture's borrower is owned (#596)` (a cancellation while serving is idle, while the stand-in session is served, and after a session
  failure the dispatch caught, with and without a following cancellation (the wait for the borrower after a reported failure is
  bounded, so a parked borrower is stopped and joined and the dispatch raises), and a cancellation that escapes the session). Each runs twice with one judgement, through the facility
  and through the deliberately unowned start of `Test.GPU.Vulkan.Native.Unowned` (the negative control, which must fail). The controls' own
  stop-and-join is uninterruptible, and `the negative controls' own cleanup (#596)` holds that to account (a cancellation while its
  kill is blocked, and the example cancelled before the worker is let go, each with its control), as the GLFW native suite's does
  (#594). The fixture's
  seams (`runSharedWith`) exist test-side only. The pinned start's own examples, with a plain `forkOn` control, are in `workflow-tests`
  (`--match "a thread pinned to a capability"`).
  The generic run command's real-device suite `run-native-tests` (the root package, `run-native-test/`,
  full-product build only, group `test.vulkan-run-native`) takes the same desktop consent as the other
  window-opening native suites, under the same standing approval, and the runner starts an isolated X11
  display on Linux. It runs the command's production composition with real windows (the shipped
  content's scene adopted and a genuine native close delivered through
  `Hetoimasia.GLFW.NativeCheck`, a script that quits, a required texture that cannot be read, and the
  assembled facade's capacity behavior), and starts the built full-product `hetoimasia run` as a child
  of the suite, named by the runner in `HETOIMASIA_RUN_EXECUTABLE`, for exactly one SIGTERM and exit
  130, twice: with Vulkan validation not requested, and with `--vulkan-validation` (LFE-28), where the
  layer and synchronization validation must be recorded as requested and enabled (a layer missing from
  the prefix fails the case), the layer must announce itself to the diagnostic capture (the child runs
  with `HETOIMASIA_DEBUG=gpu.vulkan.diagnostics`) with synchronization validation among its enables, and
  the diagnostic verdict must be clean through teardown. Each case sends the
  signal only after the resolved root, the validation record and the session's start gate, and requires
  `failures=0 verdict=VerdictInterrupted`. The suite's child helper (`Test.Run.Native.Child`) has its own harness examples first
  (`Test.Run.Native.ChildSpec`: a failure part-way through acquisition, a cancellation during the release, a child that
  cannot be confirmed reaped or drained, the body's failure preserved), run against `/bin/sh` children with no native session. It is built, with the executable it launches, in the group's preparation stage
  (`bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests`) and run by
  `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests -- --complete`, which builds nothing and presents the
  build identity the preparation recorded (see [validation.md](validation.md#a-native-runs-build-identity)). It
  captures no pixel and reads no window back in its smoke cases. See [run_command.md](run_command.md).
  Its `Lua native milestone` subgroup (LFE-25, [#540](https://github.com/coghex/hetoimasia/issues/540), selectable alone with
  `--match 'Lua native milestone'` and part of `--complete`) is the final qualification of native windows: a two-instance harness composed through
  the public Haskell interfaces over a host the suite composes with the validation layer and synchronization validation (one UI VM with two
  engine-owned instances of the shipped content, an independent logical owner, one PNG path requested by both) whose diagnostic verdict fails on any
  issue; one instance ended while its accepted scene holds its released texture, with its texture read held at the pool's reader and with its
  window creation outcome withheld, each with the peer kept live; resize, minimize and restore through the public window commands with the metrics
  actually reported and the published revision unchanged (the restore is the regression check for #581); a genuine platform-delivered user close
  of either window as one whole-session quit; a labelled injected clean refusal; the unwinding of a failing scenario; and the actual built command with
  `--vulkan-validation` as an owned child (a genuine `WM_DELETE_WINDOW` close with exit 0, a logical failure leaving the UI on the exact red clear until a
  close with exit 1, a Lua quit with exit 0). On the isolated X11 display each window is captured through the external helper
  `tools/x11-window/x11_window.py` (identity-checked, lossless, judged against landmarks written from the fixture) and the captures are
  retained with records and checksums in [the evidence](evidence/lua_first_native/README.md); its device-free examples run in `test.workflow`, and
  its preparation (`prepare`) fails rather than skips. macOS has no OS capture: the unattended receipt (`--complete`) records the owner's visual
  confirmations as pending and never holds, and the supervised run (the desktop consent with the narrower `--match` selection) holds at each
  checkpoint for the operator's line on standard input, bounded.
  The adapter's real-device suite `lua-engine-graphics-native-tests`
  (`packages/lua-engine-graphics`, group `test.vulkan-lua-engine-native`) enters
  the same kind of session: it starts the production graphics owner with no
  surface, loads real PNGs through the texture pipeline and the production
  backend, and reads the device's evidence back. Its subgroup `window provider`
  (LFE-18) opens real windows: two instances' visible windows on one protected
  host, an empty scene published to each after the owner's admission, one
  instance ended with its window destroyed after retirement while the other's
  stays usable, a cancelled real creation, and a genuine native close made through
  `Hetoimasia.GLFW.NativeCheck`, routed to one session stop. It takes the same
  desktop consent as `vulkan-native-tests`, under the same standing approval (on
  macOS `HETOIMASIA_NATIVE_SESSION=desktop` on the one command; on Linux the
  runner starts its own X11 display), and is built in the group's preparation
  stage and run by
  `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --complete`, which builds
  nothing and refuses an executable whose recorded build identity is missing or stale;
  the subgroup alone by the same command with `-- --match 'window provider'`. Its
  headless counterpart is the `window provider` group of `lua-engine-graphics-tests`
  (group `test.vulkan-headless`), a gated fake port inside the real request
  admission, leases and a Lua owner; the shared composition lives in the
  package's `test-common` directory, not in either suite's spec modules.
  Every helper thread `lua-engine-graphics-tests` and `lua-engine-graphics-native-tests` start is an owned start
  (#599): `withFakeOwner` and the peers rig's `mainLoop` (whose scope encloses the retirement and the windows' teardown, which
  may wait for a main-thread step), the backend scope forked by `withForkedScope` (whose `forkedJoin` may be made again, so the
  scope's own join never waits on a signal an example consumed), the scenario threads of the facade, the window coordinator and the
  native `Facade` and `Pixels` groups, and the native session's bound OS thread that runs the complete profile (`withProfileBeyond`,
  `Test.LuaEngine.Graphics.Served`). That thread is started by `withOwnedBoundThread` before the owner host and joined after the
  host's own teardown, because the host and the texture backend's drain wait for windows that only the thread's example scopes can
  close, and those windows retire only while the process main thread serves the owner loop: when the loop is left abnormally,
  `serveProfile` (inside the backend's scope, before its drain) kills the thread through a second owned thread and serves the loop
  again until the thread has ended. The order and its waits are tabulated in the pull request that made it (#620). A latched
  supervision failure that makes serving the loop again impossible is a known gap with its own issue. The headless regressions are
  `Test.LuaEngine.Graphics.Owned` (`--match "the threads the helpers start are owned (#599)"`), each run through the facility and
  through the previous form of the helper (the negative control): the fake owner and the main-step loop cancelled between the fork
  and the body's first step, a scope held at a gate it waits at uninterruptibly, the real drain a stop latches the fake's holds
  for, and a model of the whole shutdown order for the normal, assertion-failure and main-thread-cancellation exits. The native
  sites are covered by their examples still passing in `test.vulkan-lua-engine-native` and by the baseline guard; the live-window
  cancellation is the probe `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests --
  --probe-cancel-loop` (a window-opening run, so the desktop opt-in on that one command; it is not part of the catalog group).
  Its scene publication (LFE-20) has a second native subgroup, `scene retention`:
  a published scene adopted by the real owner, its texture protected and recorded
  again after Lua released it, a publication naming the released lease refused,
  retirement only after the scene is replaced and the frames that used it
  completed, a peer instance's scene kept adopted and recorded when the first
  ends, and the largest legal scene recorded; the same consent and command, with
  `-- --match 'scene retention'`. It reads the host's frame events and scene state
  and captures no pixel. Its headless counterparts in `lua-engine-graphics-tests`
  are `scene retention` (the production ledger and backend over the fake owner and
  a model of the host's ledger rules, which is injected evidence), `scene
  publication` (real Lua instances, leases, pipeline and window provider) and `the
  frame of an adopted scene` (the pure adaptation against the render-2d oracle).
  Its presentation input (TRA-6) is covered in four layers, none of which delivers a real key, button or scroll (no public API can):
  the CPU facade's `input calls` group of `lua-engine-tests` (`test.lua-engine`: real Lua over an injected ordered port: the exact
  packet, order and epoch, a prefix and then the remainder, 128 events, the observation, and every refusal before a read);
  the graphics adapter's `input adapter over a controlled feed` and `input through the production graphics injection` groups of
  `lua-engine-graphics-tests` (`test.vulkan-headless`: the consumer over a model of the feed in `Test.LuaEngine.Graphics.InputFeed`,
  and real Lua over the production injection, the real leases and the window provider's fake port; both injected evidence); and one
  native example in the `graphics facade` subgroup of `lua-engine-graphics-native-tests` (`test.vulkan-lua-engine-native`) that polls a
  real window's feed through the production host and reads the public suspension reset, its acknowledgement and the paused feed.
  Its surface-free scene target (LFE-27) has a third native group, `an offscreen scene
  target on a real device (LFE-27)`, which opens no window: with the owner held on a
  gate it makes a scene naming a texture the target's latest value, releases the
  texture through the production lane before the owner has adopted it (the host's own
  scene state shows the revision published, the revision adopted and the release request
  queued behind a barrier naming the target), lets the owner adopt, draws and reads back
  the texture after the Lua release, and sees it freed only after that recording's own
  ticket completed; the same consent and command, with `-- --match 'an offscreen scene
  target on a real device'`, and an empty selection fails. Its headless counterpart is
  the `Offscreen scene targets (LFE-27)` group of the window integration's
  `integration-tests` (`Test.GPU.Vulkan.GLFW.Targets`, group `test.vulkan-headless`):
  registration and its refusals, the bound on targets, the barrier, adoption and release
  driven only by a batch's own ticket (completion withheld, one of several batches
  completed, a batch discarded), the retention limit and its deferral, teardown at every
  exit, and a host with a window and a target, over the stand-in native layers. The
  production texture release lane cannot be composed over those stand-ins from the
  adapter's suites (its host is private), so the lane's behaviour under a key is the
  `scene retention` group's model, which is generic in the key and injected evidence, and
  the native group above.
  Its pixel evidence (LFE-24) is the fourth native group, `Lua offscreen pixels`, which also opens
  no window and renders no screen: the shipped `samples/lua-quad/content` unchanged and small
  purpose-built Lua programs with committed technical PNG fixtures run as the roles of a real
  `runSession` over the production host, facade, scene publisher, hold ledger and release barrier,
  with only the display target substituted (a surface-free offscreen scene target registered
  through LFE-27's interface, recorded only through the host's recording boundary into a managed
  RGBA8 sRGB colour target and read back after the batch's own ticket completed). Every
  determinate pixel is judged by the render-2d oracle, and independently by hand-stated colours
  and the oracle over the specification. It writes lossless PNG readbacks and a machine-readable
  record per image under `HETOIMASIA_VALIDATION_EVIDENCE`. The same consent and command, with
  `-- --match 'Lua offscreen pixels'`; an empty selection fails; its record reports `windows: 0`.
  Its device-free half is the `Lua offscreen pixels comparator` group of `lua-engine-graphics-tests`
  (group `test.vulkan-headless`): the committed fixtures against their SHA-256 and the decoder, the
  hand-stated numbers against the oracle, and the comparator rejecting the representative defects
  on synthetic readbacks. The design's wording for the owner of these tests is "the Vulkan headless
  runner"; that lane (`run.sh test`) creates no device by contract, so the real-pixel group is in the
  native lane, as R2D-7's offscreen pixels are. See
  [the adapter's README](../packages/lua-engine-graphics/README.md#lua-offscreen-pixels-lfe-24) and
  [the evidence](evidence/lfe24-offscreen-pixels/README.md).
