# #266's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the records the `vk11-recording` and
> `debug-names` children wrote, and the two receipts the validation runner
> wrote, verbatim.

This is the local macOS evidence for issue #266, the swapchain generations'
split into private modules, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: the documented Darwin plan, then `run.py` for `test.vulkan-headless`
and — under the owner's standing approval for native desktop runs an issue
needs, carried on that one command as `HETOIMASIA_NATIVE_SESSION=desktop` —
`test.vulkan-native`, under MoltenVK and Cocoa, with the catalog's
`--complete` command. Both passed at commit
`19990307a48c52036cd99e6fa5d834e8a2e60ebf`.

The native group's preparation built the suite in 21.155 s, and its
watched native execution — the shared session and its roots, every example and
child, retirement, the diagnostic verdict after the last teardown callback —
took 2.311 s against the 30-second watchdog. The receipts record `Darwin` and
the local prefix's own toolchain map — the MoltenVK driver, the 1.3.296 layer
with `+synchronization` — and no `ci-image` entry, so neither can satisfy a
Linux plan. The prefix is a private one built for this run with
`tools/native/native.py build`, because the shared prefix predates this
machine's current Command Line Tools and SDK; its `vulkan`,
`vulkan-loader` and `native-manifest` identities are therefore its own, and
differ from #265's. The Linux evidence is
[`linux-generations-split.md`](linux-generations-split.md).

The split moves code and changes no behaviour, so this run is the same
evidence VK-10 retained, taken again over the new modules. The shared roots'
generation cases did what they did before: a shown 160×120 window's target
built its generation on the graphics owner's thread from the surface's
concrete extent — 320×240 at content scale 2.0 — in `B8G8R8A8_SRGB` (format
50) with a view of each of its 3 images, and a window resized through the
host's command port was replaced, the old generation retired only after the
example ended the CPU use it held. The shared session's destruction order shows
each target's image views, then its swapchain, before its surface, and every one
of them before the device. The two children that build a capturing generation
on private roots — `vk11-recording` and `debug-names` — each built one at
320×240 with 3 images, recorded into it, and destroyed it before its surface
with no validation error at either generation step; `debug-names` failed its
verdict for its one deliberately provoked
`VUID-vkCmdCopyImageToBuffer-pRegions-00183` alone. The shared session's
verdict was clean.

The plan selected: `build.all`, `test.engine`, `test.foundation`, `test.runtime`, `test.glfw`, `smoke.console`, `test.vulkan-headless`, `test.vulkan-native`, `test.workflow`.

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
vulkan-native-tests: private debug-names: ExitSuccess in 0.185657s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 5.3195e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.180585s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.255217s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.136555s
vulkan-native-tests: private vk6-capture: ExitSuccess in 4.0995e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.158002s
vulkan-native-tests: the process ran for 1.611083s, fixtures, examples and teardown included
```

VK-10's generation case printed:

```
VK-10 generation: 320x240 from ExtentFromSurface, window 160x120 at content scale 2.0, 3 images of format 50
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `debug-names` | 6 examples, 0 failures |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures, 1 pending — the pending one is the failed-initialization case, which Cocoa cannot provoke |
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
## VK-11: managed resources and a recorded, discarded triangle batch
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

- error VUID-vkCmdCopyImageToBuffer-pRegions-00183, objects [("6:0x9c5805218",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0xe7e6d0000000000f",Just "resource 3.1 readback buffer")]
  - queue labels reported: 0, copied []
  - command-buffer labels reported: 2, copied ["batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
- records delivered: 66
- undelivered: 0
- verdict issues: [ErrorLatched]

#### Transcript

```
## #250: a validation report on a named managed resource inside a labelled batch
the device Apple M3 Max offers debug-utils naming
the readback buffer 0xe7e6d0000000000f is named resource 3.1 readback buffer
recorded BatchId (TargetId 0 1) 0, labelled batch 0 target 0.1 generation 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
error VUID-vkCmdCopyImageToBuffer-pRegions-00183: objects [("6:0x9c5805218",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0xe7e6d0000000000f",Just "resource 3.1 readback buffer")]
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
  "duration_seconds": 2.311,
  "ended_at": "2026-09-26T21:04:21.555Z",
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
  "executed_commit": "19990307a48c52036cd99e6fa5d834e8a2e60ebf",
  "executed_tree": "9ac2abdb8c472685bba977c2c3597392bac795c2",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "19990307a48c52036cd99e6fa5d834e8a2e60ebf",
  "input_identity": "00efb54bb4ac10e3611468a14b1fdd77943af819e35877c65d70c54a5ee399ca",
  "outcome": "passed",
  "plan_identity": "e51539365afc6dbaf81ed1964d4da25ef131fd01a10541e88e7e082973174622",
  "policy_version": "5e4ad558eadaea0fd0787938c85b8d2a310becdf812823df50d6826d72fdac85",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 21.155,
    "ended_at": "2026-09-26T21:04:19.244Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-26T21:03:58.089Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-26T21:04:19.244Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "ea40b0775d9493f290fd6018c657275e9fce38d1342622b62082a6e1d3938486",
    "vulkan": "8d5e2bd64fc57a3c0f40453376b6ba03514196f14bdbfa6c2a3f3bdc3edeae86",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 2440ffa71dea"
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
  "duration_seconds": 52.267,
  "ended_at": "2026-09-26T21:03:46.879Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "19990307a48c52036cd99e6fa5d834e8a2e60ebf",
  "executed_tree": "9ac2abdb8c472685bba977c2c3597392bac795c2",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "19990307a48c52036cd99e6fa5d834e8a2e60ebf",
  "input_identity": "00efb54bb4ac10e3611468a14b1fdd77943af819e35877c65d70c54a5ee399ca",
  "outcome": "passed",
  "plan_identity": "e51539365afc6dbaf81ed1964d4da25ef131fd01a10541e88e7e082973174622",
  "policy_version": "5e4ad558eadaea0fd0787938c85b8d2a310becdf812823df50d6826d72fdac85",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-26T21:02:54.612Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "ea40b0775d9493f290fd6018c657275e9fce38d1342622b62082a6e1d3938486",
    "vulkan": "8d5e2bd64fc57a3c0f40453376b6ba03514196f14bdbfa6c2a3f3bdc3edeae86",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 2440ffa71dea"
  },
  "worker": "local"
}

```
