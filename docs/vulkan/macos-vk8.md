# The VK-8 Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote, verbatim, and lines the runs printed.

This is the local macOS evidence for issue #220, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: the documented Darwin plan, then `run.py` for `test.vulkan-headless`
and — under the human user's explicit approval for this session, given on
2026-09-24 and carried on that one command as
`HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under MoltenVK and
Cocoa, with the catalog's `--complete` command. Both passed at commit
`ce918c45351f9a9a84fe4d2da9e04e7c911fd518`.

The native group's preparation built the suite in 1.21 s on a warm build, and its
watched native execution — the shared session and its roots, every example and
child, retirement, the diagnostic verdict after the last teardown callback —
took 1.661 s against the 30-second watchdog. The receipts record `Darwin`
and the local prefix's own toolchain map — the MoltenVK driver, the 1.3.296
layer with `+synchronization` — and no `ci-image` entry, so neither can satisfy
a Linux plan. The Linux evidence is [`linux-vk8.md`](linux-vk8.md).

The plan selected: `build.all`, `test.engine`, `test.foundation`, `test.runtime`, `test.glfw`, `smoke.console`, `test.scripting-lua`, `test.vulkan`, `test.vulkan-diagnostics`, `test.vulkan-headless`, `test.vulkan-native`, `test.workflow`, `test.glfw-native`.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
106 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 16
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 64 records delivered
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 5.1429e-2s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.266143s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.139256s
vulkan-native-tests: private vk6-capture: ExitSuccess in 5.5366e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.157865s
vulkan-native-tests: the process ran for 0.979252s, fixtures, examples and teardown included
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures, 1 pending — the pending one is the failed-initialization case, which Cocoa cannot provoke |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The synchronization-validation control

#### Two writes to one buffer with no barrier between them

- device: Apple M3 Max

| step | reports | errors |
| --- | --- | --- |
| the loader's offer | 0 | 0 |
| vkCreateInstance | 44 | 0 |
| vkCreateDebugUtilsMessengerEXT | 0 | 0 |
| vkCreateDevice | 16 | 0 |
| vkCreateBuffer | 0 | 0 |
| vkAllocateMemory | 0 | 0 |
| vkBindBufferMemory | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkAllocateCommandBuffers | 0 | 0 |
| vkBeginCommandBuffer | 0 | 0 |
| vkCmdFillBuffer, the first write | 0 | 0 |
| vkCmdFillBuffer, the second write with no barrier | 1 | 1 |
| vkEndCommandBuffer | 0 | 0 |
| vkDestroyCommandPool | 0 | 0 |
| vkFreeMemory | 0 | 0 |
| vkDestroyBuffer | 0 | 0 |
| vkDestroyDevice | 1 | 0 |
| vkDestroyDebugUtilsMessengerEXT | 0 | 0 |
| vkDestroyInstance | 3 | 0 |

- error reports, by message id: SYNC-HAZARD-WRITE-AFTER-WRITE
- records delivered: 65
- undelivered: 0
- verdict issues: [ErrorLatched]

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
  "duration_seconds": 1.661,
  "ended_at": "2026-09-25T01:21:12.711Z",
  "evidence": [
    "evidence/test.vulkan-native/synchronization-hazard.log",
    "evidence/test.vulkan-native/synchronization-hazard.md",
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
  "executed_commit": "ce918c45351f9a9a84fe4d2da9e04e7c911fd518",
  "executed_tree": "bf61e13508b0c14468694deb84d12f9687303cbb",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "ce918c45351f9a9a84fe4d2da9e04e7c911fd518",
  "input_identity": "09e47e26734eb9a5142be51d18e31ee968fc24506d1220e4a5f3e9020538f9ee",
  "outcome": "passed",
  "plan_identity": "f3bf53dbe0053bb62de24a461cb6b3cf045b5c499382e275a87729af7079b206",
  "policy_version": "30ac95d88b0895b9d4eee682bcd3cfc9b200351ac8c06508b468cac756fa0fd5",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 1.21,
    "ended_at": "2026-09-25T01:21:11.050Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T01:21:09.840Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T01:21:11.050Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "208157dea26adbf37bd84a95840a4ee85f5b15c4d9b06435054601e40a0c87c0",
    "vulkan": "6e35aff9fb1b6f7225e1ea9ef8efffcec462870d6ba058e7a0c086815b65f96f",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 b2026fa5581d"
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
  "duration_seconds": 3.918,
  "ended_at": "2026-09-25T01:21:09.529Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "ce918c45351f9a9a84fe4d2da9e04e7c911fd518",
  "executed_tree": "bf61e13508b0c14468694deb84d12f9687303cbb",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "ce918c45351f9a9a84fe4d2da9e04e7c911fd518",
  "input_identity": "09e47e26734eb9a5142be51d18e31ee968fc24506d1220e4a5f3e9020538f9ee",
  "outcome": "passed",
  "plan_identity": "f3bf53dbe0053bb62de24a461cb6b3cf045b5c499382e275a87729af7079b206",
  "policy_version": "30ac95d88b0895b9d4eee682bcd3cfc9b200351ac8c06508b468cac756fa0fd5",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T01:21:05.611Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "208157dea26adbf37bd84a95840a4ee85f5b15c4d9b06435054601e40a0c87c0",
    "vulkan": "6e35aff9fb1b6f7225e1ea9ef8efffcec462870d6ba058e7a0c086815b65f96f",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 b2026fa5581d"
  },
  "worker": "local"
}
```
