# #250's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the record the `debug-names` child
> wrote, and the three receipts the validation runner wrote, verbatim.

This is the local macOS evidence for issue #250 (VKR-2), taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: the documented Darwin plan, then `run.py` for
`test.vulkan-diagnostics`, `test.vulkan-headless` and — under the human user's
explicit approval for this task's runs, given on 2026-09-25 and carried on that
one command as `HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under
MoltenVK and Cocoa, with the catalog's `--complete` command. All three passed at
commit `c4f836d8520ce341d4f63c8f4e61c7ddc3d08246`.

The native group's preparation built the suite in 17.257 s, and its watched
native execution — the shared session and its roots, every example and child,
retirement, the diagnostic verdict after the last teardown callback — took
2.589 s against the 30-second watchdog. The receipts record `Darwin` and the
local prefix's own toolchain map — the MoltenVK driver, the 1.3.296 layer with
`+synchronization` — and no `ci-image` entry, so none can satisfy a Linux plan.
The Linux evidence is [`linux-vkr2.md`](linux-vkr2.md).

The shared session's device offered `VK_EXT_debug_utils`'s naming and label
calls, so it named the device, its queue, every surface and every generation's
swapchain, images and views, all on the owner's thread, and its verdict after
the last teardown callback was clean. `vk11-recording`'s batch was labelled,
and so fifteen commands long.

#250's native case, `debug-names`, ran on private roots in its own child process
on the Apple M3 Max. Over a 160×120 window's surface it built VK-11's capture
generation and managed resources, and recorded VK-11's triangle and copy with
the fixture's seam moving the copy four bytes into the readback buffer. The one
validation error, `VUID-vkCmdCopyImageToBuffer-pRegions-00183`, arrived from
the recording step and no other. Its objects carried the frame storage's
command buffer and the readback buffer, each with the name the backend gave it
(`resource 2.1 command buffer target 0.1 slot 0`, `resource 3.1 readback
buffer`). The pinned layer reported no queue label and two command-buffer
labels, both the batch's own, `batch 0 target 0.1 generation 0`: the pass's
label had already closed with the rendering before the copy, and the layer
lists the batch's region twice, which the case records rather than assumes
away — the innermost is the batch's, as required. The verdict after the last
teardown callback failed for the latched error alone, with every report
admitted and delivered.

The first desktop run for this issue, at an earlier head that also named the
debug messenger, stopped with exit status −11 during the shared session's first
admission; that run and its diagnosis are
[`macos-debug-utils-naming.md`](macos-debug-utils-naming.md), and the
exception it led to is in [the backend contract](../gpu_backend.md#names-and-labels).

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
vulkan-native-tests: private debug-names: ExitSuccess in 0.183542s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 3.6636e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.205924s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.608877s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.132304s
vulkan-native-tests: private vk6-capture: ExitSuccess in 4.582e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.152975s
vulkan-native-tests: the process ran for 1.942834s, fixtures, examples and teardown included
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `debug-names` | 6 examples, 0 failures |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures, 1 pending |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The `debug-names` record

Verdict: **pass**.

### A named readback buffer overrun inside a labelled batch

- device: Apple M3 Max
- debug-utils naming offered: True
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
- the readback buffer: 0xe7e6d0000000000f, named resource 3.1 readback buffer
- the batch's label: batch 0 target 0.1 generation 0

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 44 | 0 |
| the device and the target | 16 | 0 |
| the swapchain generation | 1 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| recording the batch, with the copy overrunning the readback buffer | 1 | 1 |
| vkResetCommandPool, discarding the batch | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generation | 0 | 0 |
| the target's surface | 0 | 0 |
| the device | 1 | 0 |
| the messenger and the instance | 3 | 0 |

- error VUID-vkCmdCopyImageToBuffer-pRegions-00183, objects [("6:0x99728c818",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0xe7e6d0000000000f",Just "resource 3.1 readback buffer")]
  - queue labels reported: 0, copied []
  - command-buffer labels reported: 2, copied ["batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
- records delivered: 66
- undelivered: 0
- verdict issues: [ErrorLatched]

### Transcript

```
## #250: a validation report on a named managed resource inside a labelled batch
the device Apple M3 Max offers debug-utils naming
the readback buffer 0xe7e6d0000000000f is named resource 3.1 readback buffer
recorded BatchId (TargetId 0 1) 0, labelled batch 0 target 0.1 generation 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
error VUID-vkCmdCopyImageToBuffer-pRegions-00183: objects [("6:0x99728c818",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0xe7e6d0000000000f",Just "resource 3.1 readback buffer")]
  queue labels reported: none, []
  command-buffer labels reported: 2, ["batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
the lifetime delivered 66 records
```

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
  "duration_seconds": 2.589,
  "ended_at": "2026-09-25T21:26:55.495Z",
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
  "executed_commit": "c4f836d8520ce341d4f63c8f4e61c7ddc3d08246",
  "executed_tree": "079c7de2699ae9097e91ca2ef6fbd87e4b387fb9",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "c4f836d8520ce341d4f63c8f4e61c7ddc3d08246",
  "input_identity": "3d76de8b8601b1c68d7d3a67e97033c454263b9ff8c74452774d14e3c6484249",
  "outcome": "passed",
  "plan_identity": "d7965c65cb6fbd643edc0ea9e2593f9e00d52cff94d83c286401b126531c5db2",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 17.257,
    "ended_at": "2026-09-25T21:26:52.906Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T21:26:35.648Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T21:26:52.906Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "7d03c425cd615db7f97e05a22baa5f3fe7460bbfae0252041036d43df5b0151c",
    "vulkan": "f37cf8198c1d1c3f5b4dc15edfc352b1ba9ea527a9cf836119b7ece094efdf24",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 085fa54b6cad"
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
  "duration_seconds": 5.991,
  "ended_at": "2026-09-25T21:12:20.714Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "c4f836d8520ce341d4f63c8f4e61c7ddc3d08246",
  "executed_tree": "079c7de2699ae9097e91ca2ef6fbd87e4b387fb9",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "c4f836d8520ce341d4f63c8f4e61c7ddc3d08246",
  "input_identity": "3d76de8b8601b1c68d7d3a67e97033c454263b9ff8c74452774d14e3c6484249",
  "outcome": "passed",
  "plan_identity": "d7965c65cb6fbd643edc0ea9e2593f9e00d52cff94d83c286401b126531c5db2",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T21:12:14.724Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "7d03c425cd615db7f97e05a22baa5f3fe7460bbfae0252041036d43df5b0151c",
    "vulkan": "f37cf8198c1d1c3f5b4dc15edfc352b1ba9ea527a9cf836119b7ece094efdf24",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 085fa54b6cad"
  },
  "worker": "local"
}
```

### `test.vulkan-diagnostics` receipt

```json
{
  "command": [
    "cabal",
    "test",
    "--project-file",
    "cabal.project.cpu",
    "hetoimasia-gpu-vulkan-diagnostics:diagnostics-tests",
    "--test-show-details=direct"
  ],
  "duration_seconds": 2.227,
  "ended_at": "2026-09-25T21:12:23.230Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "c4f836d8520ce341d4f63c8f4e61c7ddc3d08246",
  "executed_tree": "079c7de2699ae9097e91ca2ef6fbd87e4b387fb9",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-diagnostics",
  "head_commit": "c4f836d8520ce341d4f63c8f4e61c7ddc3d08246",
  "input_identity": "3d76de8b8601b1c68d7d3a67e97033c454263b9ff8c74452774d14e3c6484249",
  "outcome": "passed",
  "plan_identity": "d7965c65cb6fbd643edc0ea9e2593f9e00d52cff94d83c286401b126531c5db2",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T21:12:21.004Z",
  "timeout_seconds": 1800,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "7d03c425cd615db7f97e05a22baa5f3fe7460bbfae0252041036d43df5b0151c",
    "vulkan": "f37cf8198c1d1c3f5b4dc15edfc352b1ba9ea527a9cf836119b7ece094efdf24",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 085fa54b6cad"
  },
  "worker": "local"
}
```
