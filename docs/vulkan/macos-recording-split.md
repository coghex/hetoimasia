# #265's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the records the `vk11-recording` and
> `debug-names` children wrote, and the two receipts the validation runner
> wrote, verbatim.

This is the local macOS evidence for issue #265, the managed recording's split
into private modules, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: the documented Darwin plan, then `run.py` for `test.vulkan-headless`
and — under the human user's explicit approval for this task's run, given on
2026-09-26 and carried on that one command as
`HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under MoltenVK and
Cocoa, with the catalog's `--complete` command. Both passed at commit
`862d30cbd86a9fec26a90de26560fb30e3b8a5b1`.

The native group's preparation built the suite in 3.016 s, and its
watched native execution — the shared session and its roots, every example and
child, retirement, the diagnostic verdict after the last teardown callback —
took 3.137 s against the 30-second watchdog. The receipts record `Darwin` and
the local prefix's own toolchain map — the MoltenVK driver, the 1.3.296 layer
with `+synchronization` — and no `ci-image` entry, so neither can satisfy a
Linux plan. The prefix is a private one built for this run with
`tools/native/native.py build`, because the shared prefix predates this
machine's current Command Line Tools; its `vulkan` and `native-manifest`
identities are therefore its own. The Linux evidence is
[`linux-recording-split.md`](linux-recording-split.md).

The split moves code and changes no behaviour, so this run is the same
evidence VK-11 and #250 retained, taken again over the new modules. The two
scenarios that drive the managed recording through a real device did what they
did before: `vk11-recording` built VK-11's managed resources, recorded and
sealed a labelled, fifteen-command triangle batch, saw each resource held by it
until the discard invalidated the pool and discharged it, refused the readback
with nothing submitted, destroyed all four resources, and reported no
validation error; `debug-names` provoked its one expected
`VUID-vkCmdCopyImageToBuffer-pRegions-00183` on the named command buffer and
readback buffer inside the batch's label, and failed its verdict for that
latched error alone. The shared session's verdict was clean.

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
vulkan-native-tests: private debug-names: ExitSuccess in 0.187422s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 4.6706e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.233424s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.632392s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.14177s
vulkan-native-tests: private vk6-capture: ExitSuccess in 4.815e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.167197s
vulkan-native-tests: the process ran for 2.425156s, fixtures, examples and teardown included
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

### The `vk11-recording` record

Verdict: **pass**.

#### A recorded, discarded triangle batch

- device: Apple M3 Max
- generation: 320x240, format 50, 3 images
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
- held before the discard: [("pipeline layout",[BatchId (TargetId 0 1) 0]),("pipeline",[BatchId (TargetId 0 1) 0]),("frame storage",[BatchId (TargetId 0 1) 0]),("readback",[BatchId (TargetId 0 1) 0])]
- held after the discard: [("pipeline layout",[]),("pipeline",[]),("frame storage",[]),("readback",[])]
- the readback with nothing submitted: RefusedNotWritten "a batch or a submission still holds the buffer"
- managed resources destroyed: 4

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 44 | 0 |
| the device and the target | 16 | 0 |
| the swapchain generation | 1 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| recording the triangle batch | 0 | 0 |
| vkResetCommandPool, discarding the batch | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generation | 0 | 0 |
| the target's surface | 0 | 0 |
| the device | 1 | 0 |
| the messenger and the instance | 3 | 0 |

- error reports: none
- records delivered: 65
- undelivered: 0
- verdict issues: []

#### Transcript

```
#### VK-11: managed resources and a recorded, discarded triangle batch
ffi binding: vulkan-3.27
ffi binding safe-foreign-calls: on
ffi binding darwin-lib-dirs: off
ffi capture callback: hetoimasia_vulkan_capture_messenger (C) → hetoimasia_capture_callback (C)
ffi Haskell callbacks installed: none
ffi unsafe imports declared: vkBeginCommandBuffer, vkEndCommandBuffer, vkCmdPipelineBarrier2, vkCmdBeginRendering, vkCmdEndRendering, vkCmdBindPipeline, vkCmdSetViewport, vkCmdSetScissor, vkCmdDraw, vkCmdCopyImageToBuffer, vkCmdBeginDebugUtilsLabelEXT, vkCmdEndDebugUtilsLabelEXT
ffi safe calls: everything else: waits, submission, presentation, pipeline creation, construction and destruction, through the binding
the generation is 320x240 in format 50 with 3 images
recorded BatchId (TargetId 0 1) 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
reading the readback with nothing submitted answered RefusedNotWritten "a batch or a submission still holds the buffer"
the lifetime delivered 65 records
```

### The `debug-names` record

Verdict: **pass**.

#### A named readback buffer overrun inside a labelled batch

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

- error VUID-vkCmdCopyImageToBuffer-pRegions-00183, objects [("6:0x85cf69618",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0xe7e6d0000000000f",Just "resource 3.1 readback buffer")]
  - queue labels reported: 0, copied []
  - command-buffer labels reported: 2, copied ["batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
- records delivered: 66
- undelivered: 0
- verdict issues: [ErrorLatched]

#### Transcript

```
#### #250: a validation report on a named managed resource inside a labelled batch
the device Apple M3 Max offers debug-utils naming
the readback buffer 0xe7e6d0000000000f is named resource 3.1 readback buffer
recorded BatchId (TargetId 0 1) 0, labelled batch 0 target 0.1 generation 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
error VUID-vkCmdCopyImageToBuffer-pRegions-00183: objects [("6:0x85cf69618",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0xe7e6d0000000000f",Just "resource 3.1 readback buffer")]
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
  "duration_seconds": 3.137,
  "ended_at": "2026-09-26T14:36:07.693Z",
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
  "executed_commit": "862d30cbd86a9fec26a90de26560fb30e3b8a5b1",
  "executed_tree": "3e29e887da707179af54d64a4ae7f5da2fb3dddb",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "862d30cbd86a9fec26a90de26560fb30e3b8a5b1",
  "input_identity": "bb6f311b8bdd777e64bd2bf78d2c8bb683489dd2d804682886cce8f7d4986fbb",
  "outcome": "passed",
  "plan_identity": "33cfe6495e0a37a3621c2b3d45056d0117eed356b6b90fc352d1eb91b703a815",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 3.016,
    "ended_at": "2026-09-26T14:36:04.558Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-26T14:36:01.543Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-26T14:36:04.558Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "3a26327004a5905c298f32f7f6d86629c241ef19af20dc4362df46736af4b628",
    "vulkan": "5f423638a7ade831c02609b54a86364cc93e8330f92afd9fc26e2d04d0922b39",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 34b8052e15e4"
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
  "duration_seconds": 14.844,
  "ended_at": "2026-09-26T14:35:14.808Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "862d30cbd86a9fec26a90de26560fb30e3b8a5b1",
  "executed_tree": "3e29e887da707179af54d64a4ae7f5da2fb3dddb",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "862d30cbd86a9fec26a90de26560fb30e3b8a5b1",
  "input_identity": "bb6f311b8bdd777e64bd2bf78d2c8bb683489dd2d804682886cce8f7d4986fbb",
  "outcome": "passed",
  "plan_identity": "33cfe6495e0a37a3621c2b3d45056d0117eed356b6b90fc352d1eb91b703a815",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-26T14:34:59.964Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "3a26327004a5905c298f32f7f6d86629c241ef19af20dc4362df46736af4b628",
    "vulkan": "5f423638a7ade831c02609b54a86364cc93e8330f92afd9fc26e2d04d0922b39",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 34b8052e15e4"
  },
  "worker": "local"
}
```
