# The desktop standing approval's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the environment section of the
> `vk2-compatibility` record, and the two receipts the validation runner wrote,
> verbatim.

This is the local macOS evidence for the change that gives desktop-disrupting
native runs the owner's standing approval (owner decision 2026-09-26), taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: the documented Darwin plan, then `run.py` for `test.vulkan-headless`
and — under that standing approval, carried on the one command as
`HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under MoltenVK and
Cocoa, with the catalog's `--complete` command. Both passed at commit
`e129af700d6e4b879f84a7a50105273d1ce43b9b`, the pull request's revision after review; they
replace the earlier run at `b47bbb2`, whose inputs that revision changed.

The change touches only consent wording: both native suites' refusal messages
and consent Haddocks, the Vulkan suite's description of a desktop consent, one
example title, and comments, including the isolated display helper's. No
native operation, scenario or budget changed. The native group's preparation
built the suite in 3.788 s, and its
watched native execution took 7.194 s against the
30-second watchdog. The receipts record `Darwin` and the local prefix's own
toolchain map — the MoltenVK driver, the 1.3.296 layer with `+synchronization`
— and no `ci-image` entry, so neither can satisfy a Linux plan. The prefix is a
private one built for this run with `tools/native/native.py build`, because the
shared prefix predates this machine's current Command Line Tools; its `vulkan`
and `native-manifest` identities are therefore its own.

The `vk2-compatibility` record shows the one behavioral difference a retained
record carries: its session authorization now reads "the desktop opt-in on this
run's command, under the owner's standing approval". Every scenario passed and
the shared session's verdict was clean.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
110 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 82
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 67 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.18591s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 4.7653e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.190963s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.219594s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.144524s
vulkan-native-tests: private vk6-capture: ExitSuccess in 4.832e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.177254s
vulkan-native-tests: the process ran for 1.576771s, fixtures, examples and teardown included
```

### The `vk2-compatibility` record's environment

- source digest: f0570ee865a45e5000074b3d81fb9e18d9cbcb98be328ecd7006539265339e99
- repository revision: e129af700d6e4b879f84a7a50105273d1ce43b9b
- platform: darwin/aarch64
- session authorization: the desktop opt-in on this run's command, under the owner's standing approval
- VK_DRIVER_FILES: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/89b33405-fb93-4273-ada5-e8f2b7470a01/scratchpad/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
- VK_LAYER_PATH: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/89b33405-fb93-4273-ada5-e8f2b7470a01/scratchpad/native/glfw/vulkan/share/vulkan/explicit_layer.d
- cleared discovery overrides: VK_LOADER_LAYERS_DISABLE=~implicit~
- loader instance version: 1.3.296
- layers the pinned path offers: VK_LAYER_KHRONOS_validation 1.3.296
- implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
- layers requested: VK_LAYER_KHRONOS_validation
- the validation layer is in the loaded chain: yes
- validation features enabled by the create info: SynchronizationValidation
- surface extensions GLFW requires: VK_KHR_surface, VK_EXT_metal_surface

### `test.vulkan-native` receipt

```json
{
  "command": [
    "bash",
    "tools/vulkan/run.sh",
    "native",
    "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests",
    "--",
    "--complete"
  ],
  "duration_seconds": 7.194,
  "ended_at": "2026-09-26T17:07:12.393Z",
  "evidence": [
    "evidence/test.vulkan-native/debug-names.log",
    "evidence/test.vulkan-native/debug-names.md",
    "evidence/test.vulkan-native/synchronization-hazard.log",
    "evidence/test.vulkan-native/synchronization-hazard.md",
    "evidence/test.vulkan-native/vk11-recording.log",
    "evidence/test.vulkan-native/vk11-recording.md",
    "evidence/test.vulkan-native/vk2-compatibility.log",
    "evidence/test.vulkan-native/vk2-compatibility.md",
    "evidence/test.vulkan-native/vk5-bridge.log",
    "evidence/test.vulkan-native/vk5-bridge.md",
    "evidence/test.vulkan-native/vk6-capture.log",
    "evidence/test.vulkan-native/vk6-capture.md",
    "evidence/test.vulkan-native/vk7-roots.log",
    "evidence/test.vulkan-native/vk7-roots.md"
  ],
  "executed": true,
  "executed_commit": "e129af700d6e4b879f84a7a50105273d1ce43b9b",
  "executed_tree": "3ca29f893733f77bb93fa37b719cf5dddd2e7a71",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "e129af700d6e4b879f84a7a50105273d1ce43b9b",
  "input_identity": "adcd8ec562fa09ada0644506752e4be9dee1bd45134ddfc0013e8aab6ba1632b",
  "outcome": "passed",
  "plan_identity": "68b791d42c468dcfe8b0b4d94d2a65fdc4d90f402d8cfc742bae33cae84a50f1",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 3.788,
    "ended_at": "2026-09-26T17:07:05.199Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-26T17:07:01.411Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-26T17:07:05.199Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "7e3ba968a5d5840bb7a2129d06250ba7fdcb071c542c8321926c6edcf8e724fb",
    "vulkan": "33c6a53c9f2288b85327a92ae2d3dfadc00b1ae9922a47c99079473308cdf06e",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 fc7423b86da9"
  },
  "worker": "local"
}
```

### `test.vulkan-headless` receipt

```json
{
  "command": [
    "bash",
    "tools/vulkan/run.sh",
    "test",
    "hetoimasia-gpu-vulkan-native:test:native-tests",
    "hetoimasia-gpu-vulkan-native:test:shader-tests",
    "hetoimasia-gpu-vulkan-glfw:test:integration-tests"
  ],
  "duration_seconds": 10.237,
  "ended_at": "2026-09-26T17:06:40.344Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "e129af700d6e4b879f84a7a50105273d1ce43b9b",
  "executed_tree": "3ca29f893733f77bb93fa37b719cf5dddd2e7a71",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "e129af700d6e4b879f84a7a50105273d1ce43b9b",
  "input_identity": "adcd8ec562fa09ada0644506752e4be9dee1bd45134ddfc0013e8aab6ba1632b",
  "outcome": "passed",
  "plan_identity": "68b791d42c468dcfe8b0b4d94d2a65fdc4d90f402d8cfc742bae33cae84a50f1",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-26T17:06:30.107Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "7e3ba968a5d5840bb7a2129d06250ba7fdcb071c542c8321926c6edcf8e724fb",
    "vulkan": "33c6a53c9f2288b85327a92ae2d3dfadc00b1ae9922a47c99079473308cdf06e",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 fc7423b86da9"
  },
  "worker": "local"
}
```
