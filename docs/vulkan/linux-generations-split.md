# #266's Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the records the `vk11-recording` and
> `debug-names` children wrote, and the two receipts the validation runner wrote
> on the Linux worker, verbatim.

This is the Linux evidence for issue #266, the swapchain generations' split
into private modules: pull request #277's validation run
[36272134231](https://github.com/coghex/hetoimasia/actions/runs/36272134231), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe and the pinned validation layer with `+synchronization`. The
runner executed the integration candidate `e87f576502fb245a204e65f6c4324cb90f8c61c3`, the merge
of the pull request's head `66f401a9e05b079c102bcdf0d3e8433d5d6e5a2a` into its base, with the
catalog's `--complete` command. Both groups passed.

`test.vulkan-native`'s preparation built the suite in 31.929 s. Its watched
native execution — the isolated X11 display the command started for itself, the
shared session and its roots, every example and child, retirement, the
diagnostic verdict after the last teardown callback, and the display's own
teardown — took 2.168 s against the 30-second watchdog. The display helper's
logs and every scenario's output and record are in the run's
`validation-receipts-vulkan` artifact. The macOS evidence is
[`macos-generations-split.md`](macos-generations-split.md).

The split moves code and changes no behaviour, and the generation cases did on
llvmpipe what they did for VK-10: the shared roots built a shown 160×120
window's generation on the graphics owner's thread from the surface's concrete
extent — 160×120 at content scale 1.0 — in `B8G8R8A8_SRGB` (format 50) with a
view of each of its 4 images, and replaced it after a resize, retiring the old
one only after its hold ended. The shared session's destruction order shows each
target's four image views, then its swapchain, before its surface, and every one
of them before the device, and its verdict was clean. The two children that
build a capturing generation on private roots — `vk11-recording`, whose record
names it 160×120 with 4 images, and `debug-names` — each recorded into it and
destroyed it before its surface, with no validation error at either generation
step; `debug-names` failed its verdict for its one deliberately provoked
`VUID-vkCmdCopyImageToBuffer-pRegions-00183` alone.

## Captured evidence

### The native suite's report

```
110 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 94
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.121377794s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 8.9876577e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.121027081s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.137683751s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.7078537e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 9.5244754e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.130905348s
vulkan-native-tests: the process ran for 1.252059608s, fixtures, examples and teardown included
```

VK-10's generation case printed:

```
VK-10 generation: 160x120 from ExtentFromSurface, window 160x120 at content scale 1.0, 4 images of format 50
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `debug-names` | 6 examples, 0 failures |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The `vk11-recording` record

Verdict: **pass**.

#### A recorded, discarded triangle batch

- device: llvmpipe (LLVM 20.1.2, 256 bits)
- generation: 160x120, format 50, 4 images
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
- held before the discard: [("pipeline layout",[BatchId (TargetId 0 1) 0]),("pipeline",[BatchId (TargetId 0 1) 0]),("frame storage",[BatchId (TargetId 0 1) 0]),("readback",[BatchId (TargetId 0 1) 0])]
- held after the discard: [("pipeline layout",[]),("pipeline",[]),("frame storage",[]),("readback",[])]
- the readback with nothing submitted: RefusedNotWritten "a batch or a submission still holds the buffer"
- managed resources destroyed: 4

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 63 | 0 |
| the device and the target | 25 | 0 |
| the swapchain generation | 0 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| recording the triangle batch | 0 | 0 |
| vkResetCommandPool, discarding the batch | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generation | 0 | 0 |
| the target's surface | 0 | 0 |
| the device | 0 | 0 |
| the messenger and the instance | 1 | 0 |

- error reports: none
- records delivered: 89
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
the generation is 160x120 in format 50 with 4 images
recorded BatchId (TargetId 0 1) 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
reading the readback with nothing submitted answered RefusedNotWritten "a batch or a submission still holds the buffer"
the lifetime delivered 89 records
```

### The `debug-names` record

Verdict: **pass**.

#### A named readback buffer overrun inside a labelled batch

- device: llvmpipe (LLVM 20.1.2, 256 bits)
- debug-utils naming offered: True
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
- the readback buffer: 0x110000000011, named resource 3.1 readback buffer
- the batch's label: batch 0 target 0.1 generation 0

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 63 | 0 |
| the device and the target | 25 | 0 |
| the swapchain generation | 0 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| recording the batch, with the copy overrunning the readback buffer | 1 | 1 |
| vkResetCommandPool, discarding the batch | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generation | 0 | 0 |
| the target's surface | 0 | 0 |
| the device | 0 | 0 |
| the messenger and the instance | 1 | 0 |

- error VUID-vkCmdCopyImageToBuffer-pRegions-00183, objects [("6:0x1ef57710",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0x110000000011",Just "resource 3.1 readback buffer")]
  - queue labels reported: 0, copied []
  - command-buffer labels reported: 3, copied ["pass batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
- records delivered: 90
- undelivered: 0
- verdict issues: [ErrorLatched]

#### Transcript

```
## #250: a validation report on a named managed resource inside a labelled batch
the device llvmpipe (LLVM 20.1.2, 256 bits) offers debug-utils naming
the readback buffer 0x110000000011 is named resource 3.1 readback buffer
recorded BatchId (TargetId 0 1) 0, labelled batch 0 target 0.1 generation 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
error VUID-vkCmdCopyImageToBuffer-pRegions-00183: objects [("6:0x1ef57710",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0x110000000011",Just "resource 3.1 readback buffer")]
  queue labels reported: none, []
  command-buffer labels reported: 3, ["pass batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
the lifetime delivered 90 records
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
  "duration_seconds": 2.168,
  "ended_at": "2026-09-26T21:25:11.623Z",
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
    "evidence/test.vulkan-native/vk7-roots.md",
    "evidence/test.vulkan-native/x11-manager.log",
    "evidence/test.vulkan-native/x11-server.log",
    "evidence/test.vulkan-native/x11-server.txt"
  ],
  "executed": true,
  "executed_commit": "e87f576502fb245a204e65f6c4324cb90f8c61c3",
  "executed_tree": "d37e4fde8633157ac4c8a25e57548dbaec79799d",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "66f401a9e05b079c102bcdf0d3e8433d5d6e5a2a",
  "input_identity": "b1c8a37116281c7a6aa7daf69e8dc5b0141942c2ab6bf7b65b7269954dc79dfa",
  "outcome": "passed",
  "plan_identity": "5b4e7b21b05abdb3eb2d3c70e5da351e0c8fd1b1a8d165817ead81c3ae6864ac",
  "policy_version": "5e4ad558eadaea0fd0787938c85b8d2a310becdf812823df50d6826d72fdac85",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 31.929,
    "ended_at": "2026-09-26T21:25:09.454Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-26T21:24:37.525Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36272134231/attempts/1",
  "started_at": "2026-09-26T21:25:09.454Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ci-image": "sha256:74c08dc539d2364b640a9560edc4560ce0e5e55a70db82b8ddbf906c9feab612",
    "ghc": "9.14.1",
    "glslang": "15.1.0 96ea85d4228d",
    "native-manifest": "8c6860a3616749bf1d3f0af52d6dda7f70b69ef82fb2f4095ab1641ac3da86fd",
    "vulkan": "0a53afbd93d705f228556e9c4bbcacd4c1e0e79b1216b2c8f68458668d384a71",
    "vulkan-driver": "lvp 1.4.318 9d69cae2004b",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization",
    "vulkan-loader": "1.3.275 e833b010f814",
    "weston": "13.0.0-4build3"
  },
  "worker": "vulkan"
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
  "duration_seconds": 650.559,
  "ended_at": "2026-09-26T21:24:37.338Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "e87f576502fb245a204e65f6c4324cb90f8c61c3",
  "executed_tree": "d37e4fde8633157ac4c8a25e57548dbaec79799d",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "66f401a9e05b079c102bcdf0d3e8433d5d6e5a2a",
  "input_identity": "b1c8a37116281c7a6aa7daf69e8dc5b0141942c2ab6bf7b65b7269954dc79dfa",
  "outcome": "passed",
  "plan_identity": "5b4e7b21b05abdb3eb2d3c70e5da351e0c8fd1b1a8d165817ead81c3ae6864ac",
  "policy_version": "5e4ad558eadaea0fd0787938c85b8d2a310becdf812823df50d6826d72fdac85",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36272134231/attempts/1",
  "started_at": "2026-09-26T21:13:46.779Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ci-image": "sha256:74c08dc539d2364b640a9560edc4560ce0e5e55a70db82b8ddbf906c9feab612",
    "ghc": "9.14.1",
    "glslang": "15.1.0 96ea85d4228d",
    "native-manifest": "8c6860a3616749bf1d3f0af52d6dda7f70b69ef82fb2f4095ab1641ac3da86fd",
    "vulkan": "0a53afbd93d705f228556e9c4bbcacd4c1e0e79b1216b2c8f68458668d384a71",
    "vulkan-driver": "lvp 1.4.318 9d69cae2004b",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization",
    "vulkan-loader": "1.3.275 e833b010f814",
    "weston": "13.0.0-4build3"
  },
  "worker": "vulkan"
}
```
