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
  GLFW and needs no display. Root `hetoimasia-tests` (`test/`) owns only
  `Console` (the executable's startup and exit mapping, run as a child
  process), composed by `Test.Engine.Spec`, and depends on no GLFW package. A
  new runtime example belongs in `runtime-tests`, beside that component's own
  helpers; a headless GLFW example belongs in `glfw-tests`, and one that needs a
  real native session in `glfw-native-tests`; a console example belongs in root
  `Console`;
  in general a new example belongs in the component spec that owns the
  behaviour it asserts. `lua-host-tests`
  (`packages/scripting-lua/test/`) owns two components: the bridge's own
  examples (the module loader's, LFE-9, among them: `--test-options='--match "the module loader"'`, `"the loader's"`,
  `"stopping the loader"` and `"failures of the engine"`), and `Protocol` (`Test.Lua.Protocol.Spec`), the pure task,
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
  owner (`Test.LuaRuntime.Loading`, `--match 'module loader on a scheduled owner'`, LFE-9), plus
  the adapter's dependency closure, which needs no VM. It selects and fails on
  an empty selection the same way.
  `lua-engine-tests` (`packages/lua-engine/test/`, composed by `Test.LuaEngine.Spec`,
  group `test.lua-engine`, the CPU project) owns the Lua-first engine's pure
  configuration boundary (LFE-3): the strict manifest parser's accepted examples,
  byte and nesting limits, syntax and schema refusals and exact tick conversion, the
  fixed M1 profile and its smaller validated test profiles, and the package's
  dependency and import boundary, the manifest and entry boot checkpoint (LFE-6)
  composed with the content inventory over real temporary folders (`Test.LuaEngine.Boot`), the M1
  behavior selection and the export-module and loader ceilings the profile gives a VM, and the M1 request adapter
  (LFE-7, `Test.LuaEngine.Request.*`): the busy record, the exact `ready`/`take`/`cancel`/`wait` records, handles
  and phases, the profile's limits, a texture lease, and required and optional failure, over real Lua instances on
  a supervised owner with controlled fake providers. The owned texture pipeline (LFE-16, `Test.LuaEngine.Texture.*`) is
  covered over a real content root, inventory and shared read pool, the real bounded PNG decoder and a gated fake upload
  backend: the admission banks, the lanes, workers and queues, the stage-by-stage charges, cancellation at every stage,
  failures, independent loads and release, the close and drain, and a separately compiled public client. It starts no window or GPU; its one example of the Lua host's
  module loader under the fixed profile (`Test.LuaEngine.Loader`, LFE-9) starts an in-process Lua owner. A new
  manifest or profile example belongs there, in the component spec that owns it.
  `lua-runtime-tests` also owns the host's opt-in admission (`Test.LuaRuntime.Admission.*`)
  and `lua-host-tests` the argument checks (`Test.Lua.Boundary.ArgumentChecks`).
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
  `sprites-tests`, `image2d-tests`, `scene3d-tests`, `render-2d-vulkan-tests`) — the
  group `test.vulkan-headless` — and needs no consent. The native suite `vulkan-native-tests` (`test.vulkan-native`) opens
  windows and presents on macOS, so it takes the same desktop opt-in, under the
  same standing approval, as `glfw-native-tests`; on Linux its runner starts an
  isolated X11 display, and `test.vulkan-wayland` runs it on the isolated
  headless Wayland compositor. See [gpu_backend.md](gpu_backend.md#the-native-suite).
