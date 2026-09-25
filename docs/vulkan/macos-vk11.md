# The VK-11 Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote, verbatim, the lines the native run
> printed at its end, and the record the `vk11-recording` child wrote.

This is the local macOS evidence for issue #223, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: the documented Darwin plan, then `run.py` for `test.vulkan-headless`
and — under the human user's explicit approval for this task's runs, given on
2026-09-25 and carried on that one command as
`HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under MoltenVK and
Cocoa, with the catalog's `--complete` command. Both passed at commit
`fb190584e2de2bdc05211514af407fe4b7838dc6`.

The native group's preparation built the suite in 6.301 s, and its watched
native execution — the shared session and its roots, every example and child,
retirement, the diagnostic verdict after the last teardown callback — took
6.698 s against the 30-second watchdog. The receipts record `Darwin` and the
local prefix's own toolchain map — the MoltenVK driver, the 1.3.296 layer with
`+synchronization` — and no `ci-image` entry, so neither can satisfy a Linux
plan. The Linux evidence is [`linux-vk11.md`](linux-vk11.md).

VK-11's native case, `vk11-recording`, ran on private roots in its own child
process. Over a 160×120 window's surface it built a capture generation of
320×240 — the framebuffer's pixels at content scale 2.0 — in `B8G8R8A8_SRGB`
(format 50) with 3 images; constructed a pipeline layout, a pipeline over VK-9's
embedded verification shaders, the frame slot's command storage and a readback
buffer; recorded one sealed batch of eleven commands through the audited
`unsafe` subset against a fixture-private frame whose acquisition exists only
in the model; found all four resources held by that batch, and the readback
refusing its bytes since nothing was submitted; discarded the batch, after
which none was held; and destroyed every resource, the generation, the surface
and the roots. No step received a validation error, with synchronization
validation on, and the capture's verdict after the last teardown callback was
clean. The record prints the package's FFI configuration, the ten `unsafe`
entry points among it. No safe-versus-unsafe timing was measured.

An earlier development run of the same child, before the capture usage
existed, reported `VUID-VkImageMemoryBarrier2-oldLayout-01212` and
`VUID-vkCmdCopyImageToBuffer-srcImage-00186`: the profile's swapchain images are
not transfer sources. That is why generations built for a verification capture
take transfer-source usage where the surface offers it, and why the recorder
refuses a copy from any other image; the run retained here is the one after
that change.

The plan selected: `build.all`, `test.engine`, `test.foundation`, `test.runtime`, `test.glfw`, `smoke.console`, `test.vulkan`, `test.vulkan-headless`, `test.vulkan-native`, `test.workflow`.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
109 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 53
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 67 records delivered
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 3.8317e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.17244s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.580117s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.163949s
vulkan-native-tests: private vk6-capture: ExitSuccess in 5.6054e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.184836s
vulkan-native-tests: the process ran for 3.348814s, fixtures, examples and teardown included
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures, 1 pending — the pending one is the failed-initialization case, which Cocoa cannot provoke |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The `vk11-recording` record

#### A recorded, discarded triangle batch

- device: Apple M3 Max
- generation: 320x240, format 50, 3 images
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 11})
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
ffi unsafe imports declared: vkBeginCommandBuffer, vkEndCommandBuffer, vkCmdPipelineBarrier2, vkCmdBeginRendering, vkCmdEndRendering, vkCmdBindPipeline, vkCmdSetViewport, vkCmdSetScissor, vkCmdDraw, vkCmdCopyImageToBuffer
ffi safe calls: everything else: waits, submission, presentation, pipeline creation, construction and destruction, through the binding
the generation is 320x240 in format 50 with 3 images
recorded BatchId (TargetId 0 1) 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 11})
reading the readback with nothing submitted answered RefusedNotWritten "a batch or a submission still holds the buffer"
the lifetime delivered 65 records
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
  "duration_seconds": 6.698,
  "ended_at": "2026-09-25T17:44:13.340Z",
  "evidence": [
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
  "executed_commit": "fb190584e2de2bdc05211514af407fe4b7838dc6",
  "executed_tree": "aeb501935d0bd18c8c7584743d53058d9bb948c1",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "fb190584e2de2bdc05211514af407fe4b7838dc6",
  "input_identity": "1e40a446108c3bdc3f10fbe0c207cccd726784e28bda25399c13c12b14a6768e",
  "outcome": "passed",
  "plan_identity": "baea896407627f83a9bde578f0286736493ddea72834a2cd2fe87372186ecf0c",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 6.301,
    "ended_at": "2026-09-25T17:44:06.642Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T17:44:00.340Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T17:44:06.642Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "143427c88d8c68273e5db46937fe44457026f7f0c804ea7b10e9c308a20f695f",
    "vulkan": "e69852d483dee57b9eb700b7a89fc2103b6115b8e7a4e11646b21d30c0a6ba30",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 663104bff7c1"
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
  "duration_seconds": 25.657,
  "ended_at": "2026-09-25T17:43:58.862Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "fb190584e2de2bdc05211514af407fe4b7838dc6",
  "executed_tree": "aeb501935d0bd18c8c7584743d53058d9bb948c1",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "fb190584e2de2bdc05211514af407fe4b7838dc6",
  "input_identity": "1e40a446108c3bdc3f10fbe0c207cccd726784e28bda25399c13c12b14a6768e",
  "outcome": "passed",
  "plan_identity": "baea896407627f83a9bde578f0286736493ddea72834a2cd2fe87372186ecf0c",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T17:43:33.204Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "143427c88d8c68273e5db46937fe44457026f7f0c804ea7b10e9c308a20f695f",
    "vulkan": "e69852d483dee57b9eb700b7a89fc2103b6115b8e7a4e11646b21d30c0a6ba30",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 663104bff7c1"
  },
  "worker": "local"
}
```
