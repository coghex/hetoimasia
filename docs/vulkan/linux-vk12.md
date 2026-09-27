# The VK-12 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote on the Linux worker, verbatim, lines the
> run printed, and the record the `vk12-frames` child wrote.

This is the Linux evidence for issue #225: pull request #290's validation run
[36331578946](https://github.com/coghex/hetoimasia/actions/runs/36331578946/attempts/1), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe and the pinned validation layer with `+synchronization`. The
runner executed the integration candidate `c56ad7d74603221257958e1c1c2d7944356229e8`, the merge
of the pull request's head `9cf680aa4e35b4bba39c525ecf4561e34573668c` into its base, with the
catalog's `--complete` command.

`test.vulkan-native`'s preparation built the suite in 24.796 s. Its watched native
execution — the isolated X11 display the command started for itself, the shared
session and its roots, every example and child, retirement, the diagnostic
verdict after the last teardown callback, and the display's own teardown — took
2.068 s against the 30-second watchdog. The display helper's logs are in the
worker's `validation-receipts-vulkan` artifact beside each scenario's output
and record. The macOS evidence is [`macos-vk12.md`](macos-vk12.md).

VK-12's native case, `vk12-frames`, ran on private roots in its own child
process on llvmpipe. Over a 160×120 window's surface it built a capture
generation of 160×120 in `B8G8R8A8_SRGB` (format 50) with 4 images. It acquired
a frame at the first attempt, recorded the triangle and its capture into a
readback buffer holding a sentinel, and submitted that batch with one fence
reset immediately before one `vkQueueSubmit2`; the readback refused its bytes
until the submission's fence was observed signalled, and then exposed bytes that
were no longer the sentinel. The never-presented frame was closed, its
render-finished semaphore consumed by a cleanup submission made after its
rendering completed, and its image released after that cleanup completed. A
second frame was skipped through a cleanup submission and a release, and further
frames were acquired and skipped the same way until image 0, returned earlier,
came back, with the swapchain built once. No step received a validation error, with synchronization
validation on, and the verdict after the last teardown callback was clean.

## Captured evidence

### The native suite's report

```
x11.sh: display :0 on X server The X.Org Foundation, window manager "Openbox" (0x40000e), WAYLAND_DISPLAY unset
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
111 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 94
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.105300393s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 8.0664808e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.106063427s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.138272974s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.120720077s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.0688643e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 8.4868677e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.114575811s
vulkan-native-tests: the process ran for 1.273004183s, fixtures, examples and teardown included
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `debug-names` | 6 examples, 0 failures |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk12-frames` | 7 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The `vk12-frames` record

#### Frames acquired, submitted, awaited and returned without presenting

- device: llvmpipe (LLVM 20.1.2, 256 bits)
- generation: 160x120, format 50, 4 images
- rendered, never presented: FrameSlotId (TargetId 0 1) 0 1, image 0, acquired at attempt 1, settled after 1 steps
- its submission: SubmissionId 0, completed after 28 steps
- the readback before the completion: RefusedNotWritten "a batch or a submission still holds the buffer"
- the readback's first pixel after it: Right [89,89,89,255]
- every byte still the sentinel: False
- skipped: FrameSlotId (TargetId 0 1) 0 2, image 1, acquired at attempt 1, settled after 1 steps
- acquiring a returned image again, then skipped: FrameSlotId (TargetId 0 1) 0 5, image 0, acquired at attempt 1, settled after 1 steps
- images the first two frames returned: [0,1]
- swapchain constructions: 1
- left before retirement: ([],[SlotView {viewSlotTarget = TargetId 0 1, viewSlotNumber = 0, viewSlotSync = SlotSync {syncAcquire = 21990232555540, syncAcquireState = SemaphoreUnsignalled, syncRendered = 23089744183317, syncRenderedState = SemaphoreUnsignalled, syncFence = 24189255811094, syncFenceState = FenceSignalled, syncCleanup = 25288767438871, syncCleanupState = FenceSignalled}}],[])

Native calls the frames made, status queries left out:

1. vkCreateSemaphore
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [0]
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [1]
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [2]
1. vkAcquireNextImageKHR: AcquiredIndex 3
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [3]
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [0]
1. vkDestroySemaphore
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 63 | 0 |
| the device and the target | 25 | 0 |
| the swapchain generation | 0 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool, slot 0 | 0 | 0 |
| vkCreateCommandPool, slot 1 | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| filling the readback with the sentinel | 0 | 0 |
| acquiring the rendered frame | 0 | 0 |
| recording the triangle batch | 0 | 0 |
| vkQueueSubmit2, the triangle batch | 0 | 0 |
| awaiting the submission's fence | 0 | 0 |
| closing the unpresented frame | 0 | 0 |
| settling the unpresented frame | 0 | 0 |
| acquiring the skipped frame | 0 | 0 |
| skipping the frame | 0 | 0 |
| settling the skipped frame | 0 | 0 |
| acquiring again | 0 | 0 |
| skipping the frame acquired again | 0 | 0 |
| settling the frame acquired again | 0 | 0 |
| acquiring again | 0 | 0 |
| skipping the frame acquired again | 0 | 0 |
| settling the frame acquired again | 0 | 0 |
| acquiring again | 0 | 0 |
| skipping the frame acquired again | 0 | 0 |
| settling the frame acquired again | 0 | 0 |
| retiring the frames | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generation | 0 | 0 |
| the target's surface | 0 | 0 |
| the device | 0 | 0 |
| the messenger and the instance | 1 | 0 |

- error reports: none
- records delivered: 89
- undelivered: 0
- verdict issues: []

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
  "duration_seconds": 2.068,
  "ended_at": "2026-09-27T16:02:59.907Z",
  "evidence": [
    "evidence/test.vulkan-native/debug-names.log",
    "evidence/test.vulkan-native/debug-names.md",
    "evidence/test.vulkan-native/synchronization-hazard.log",
    "evidence/test.vulkan-native/synchronization-hazard.md",
    "evidence/test.vulkan-native/vk11-recording.log",
    "evidence/test.vulkan-native/vk11-recording.md",
    "evidence/test.vulkan-native/vk12-frames.log",
    "evidence/test.vulkan-native/vk12-frames.md",
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
  "executed_commit": "c56ad7d74603221257958e1c1c2d7944356229e8",
  "executed_tree": "e7b28bb8ffdc9382d26d6223e1b8c2358916ecef",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "9cf680aa4e35b4bba39c525ecf4561e34573668c",
  "input_identity": "a9e570f4169390def84a5347dd87053c314bba949390770b6ea06543f0fadc8f",
  "outcome": "passed",
  "plan_identity": "942bd30c3b629ea7ea84cd00e2953944d4456847116b983da0161f2cf93fbb03",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 24.796,
    "ended_at": "2026-09-27T16:02:57.839Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-27T16:02:33.043Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36331578946/attempts/1",
  "started_at": "2026-09-27T16:02:57.839Z",
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
  "duration_seconds": 60.561,
  "ended_at": "2026-09-27T16:02:32.876Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "c56ad7d74603221257958e1c1c2d7944356229e8",
  "executed_tree": "e7b28bb8ffdc9382d26d6223e1b8c2358916ecef",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "9cf680aa4e35b4bba39c525ecf4561e34573668c",
  "input_identity": "a9e570f4169390def84a5347dd87053c314bba949390770b6ea06543f0fadc8f",
  "outcome": "passed",
  "plan_identity": "942bd30c3b629ea7ea84cd00e2953944d4456847116b983da0161f2cf93fbb03",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36331578946/attempts/1",
  "started_at": "2026-09-27T16:01:32.314Z",
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
