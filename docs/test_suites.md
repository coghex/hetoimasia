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
  its components are not built off Darwin. A pull-request request block must
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
  window. A
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
  `lua-runtime-tests` (`packages/scripting-lua/runtime-lua-test/`, composed by
  `Test.LuaRuntime.Spec`, group `test.scripting-lua-runtime`) owns the runtime
  adapter's examples: readiness, identity, submission and its bounds,
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

## Vulkan suites

- The Vulkan native backend and window integration packages, the 2D
  renderer's Vulkan recorder (`packages/render-2d-vulkan`), and the
  triangle, sprites, image2d and scene3d samples, build only through `cabal.project.vulkan`, by
  `bash tools/vulkan/run.sh`. Its test mode runs their headless suites
  (`native-tests`, `shader-tests`, `integration-tests`, `triangle-tests`,
  `sprites-tests`, `image2d-tests`, `scene3d-tests`, `render-2d-vulkan-tests`,
  the Lua-first engine's graphics adapter's `lua-engine-graphics-tests`, and the root package's
  full-product `hetoimasia-tests`) — the group `test.vulkan-headless` — and needs no consent. The native suite `vulkan-native-tests` (`test.vulkan-native`) opens
  windows and presents on macOS, so it takes the same desktop opt-in, under the
  same standing approval, as `glfw-native-tests`; on Linux its runner starts an
  isolated X11 display, and `test.vulkan-wayland` runs it on the isolated
  headless Wayland compositor. See [gpu_backend.md](gpu_backend.md#the-native-suite).
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
  (`bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests`) and run,
  unbuilt, by `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests -- --complete`. It
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
  stage and run, unbuilt, by
  `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --complete`;
  the subgroup alone by the same command with `-- --match 'window provider'`. Its
  headless counterpart is the `window provider` group of `lua-engine-graphics-tests`
  (group `test.vulkan-headless`), a gated fake port inside the real request
  admission, leases and a Lua owner; the shared composition lives in the
  package's `test-common` directory, not in either suite's spec modules.
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
