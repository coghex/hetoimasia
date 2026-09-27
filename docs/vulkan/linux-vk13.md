# The VK-13 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote on the Linux worker, verbatim, lines the
> run printed, and the record the `vk13-presentation` child wrote.

This is the Linux evidence for issue #227: pull request #291's validation run
[36336845116](https://github.com/coghex/hetoimasia/actions/runs/36336845116/attempts/1), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe (lvp 1.4.318 9d69cae2004b) and the pinned validation layer with
`+synchronization`. The runner executed the integration candidate
`deb59b549316bd29d34e59c14db116f44b395d19`, the merge of the pull request's head
`0eb23dbd2d7f17c40f8d73ab8d8ae4d2b05c414a` into its base, with the catalog's `--complete`
command; input identity `d4d05b600d3777399659af99c78d0c98f46c06b7644fb9913f8225f12c1080c7`.

`test.vulkan-native`'s preparation built the suite in 11.296 s. Its watched native
execution — the isolated X11 display the command started for itself, the shared
session and its roots, every example and child, retirement, the diagnostic
verdict after the last teardown callback, and the display's own teardown — took
2.62 s against the 30-second watchdog. `test.vulkan-headless` passed too. The display
helper's logs are in the worker's `validation-receipts-vulkan` artifact beside
each scenario's output and record. The macOS evidence is
[`macos-vk13.md`](macos-vk13.md).

This run is the second on the pull request. The first,
[36336369172](https://github.com/coghex/hetoimasia/actions/runs/36336369172),
failed `test.vulkan-native`: every one of `vk13-presentation`'s fourteen
presentations received `SYNC-HAZARD-PRESENT-AFTER-WRITE`, because the
recorder's transition into `PRESENT_SRC_KHR` named no destination stage and so
chained its layout write into nothing that followed — not even the
render-finished semaphore's signal. MoltenVK's local run had reported nothing.
The transition now names every stage as its destination, with no access, and
this run is clean. The same run's `test.foundation` failed one Workers example,
"keeps the parent alive while a cancellation delivery blocks, until the worker
is released", which saw `SucceededKind` where it expected `CancelledKind`; the
pull request changes no foundation input, and the first run passed that group.

VK-13's native case, `vk13-presentation`, ran on private roots in its own child
process on llvmpipe, over two 160×120 windows' surfaces, each with a generation
of 160×120 in `B8G8R8A8_SRGB` (format 50) with 3 images. It presented three
triangle frames to each window back to back — each with one `vkResetFences` of
its pool record's present fence immediately before one `vkQueuePresentKHR`,
whose swapchain entry answered `VK_SUCCESS` — and drained through `awaitFrames`
until every presentation's retirement had been observed through its own present
fence. It resized the first window to 200×150 with a presentation of its old
generation not yet observed: the replacement, 200×150, became active while the
old generation stayed held by that presentation through three more generation
steps, and the first step after the retirement was observed destroyed it. The
first window then presented twice on its new generation; its close was withheld
once — naming its skipped frame, its pending presentation and both pool records
— while the second window presented, and once the evidence arrived its frames,
generations and surface were destroyed, after which the second window presented
three more frames on the same device. Nothing was left unsettled before
retirement, no step received a validation error, with synchronization validation
on, and the verdict after the last teardown callback was clean.

## Captured evidence

### The native suite's report

```
x11.sh: display :0 on X server The X.Org Foundation, window manager "Openbox" (0x40000e), WAYLAND_DISPLAY unset
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
112 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 94
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.135974675s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 0.101691537s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.137169587s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.183266633s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.16299295s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.152491695s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 5.183428e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 0.106847051s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.145858644s
vulkan-native-tests: the process ran for 1.654253489s, fixtures, examples and teardown included
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `debug-names` | 6 examples, 0 failures |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk12-frames` | 7 examples, 0 failures |
| `vk13-presentation` | 7 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The `vk13-presentation` record

#### Frames presented, and generations and a window retired on present fences

- device: llvmpipe (LLVM 20.1.2, 256 bits)
- format 50, first generations 160x120 and 160x120
- presented to both windows:
  - first: PresentationId (TargetId 0 1) 0, image 0, PresentationEnqueued, retired after 0 drain steps
  - first: PresentationId (TargetId 0 1) 1, image 1, PresentationEnqueued, retired after 0 drain steps
  - first: PresentationId (TargetId 0 1) 2, image 2, PresentationEnqueued, retired after 1 drain steps
  - second: PresentationId (TargetId 1 1) 3, image 0, PresentationEnqueued, retired after 0 drain steps
  - second: PresentationId (TargetId 1 1) 4, image 1, PresentationEnqueued, retired after 0 drain steps
  - second: PresentationId (TargetId 1 1) 5, image 2, PresentationEnqueued, retired after 1 drain steps
- resized the first window from 160x120 to 200x150: GenerationId (TargetId 0 1) 0 replaced by GenerationId (TargetId 0 1) 1
- the old generation, once replaced, was held by [PresentationId (TargetId 0 1) 6] through 3 more generation steps
- destroyed by the first generation step after its presentation's retirement was observed: True
- presented to the resized window:
  - first: PresentationId (TargetId 0 1) 7, image 0, PresentationEnqueued, retired after 1 drain steps
  - first: PresentationId (TargetId 0 1) 8, image 1, PresentationEnqueued, retired after 0 drain steps
- the first window's retirement was withheld 1 times; first: the frames of TargetId 0 1 are retained: frames [FrameSlotId (TargetId 0 1) 1 3], slots [0,1], presentations [PresentationId (TargetId 0 1) 9], pool records [0,1]
- the second window presented 1 frames while the first was retiring
- presented to the second window after the first's surface was destroyed:
  - second: PresentationId (TargetId 1 1) 12, image 0, PresentationEnqueued, retired after 0 drain steps
  - second: PresentationId (TargetId 1 1) 13, image 1, PresentationEnqueued, retired after 0 drain steps
  - second: PresentationId (TargetId 1 1) 14, image 2, PresentationEnqueued, retired after 1 drain steps
- drain waits: 9
- left before retirement: ([],[],[])

Native calls the frames made, status queries and drain waits left out:

1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 3
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 3
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkAcquireNextImageKHR: AcquiredIndex 3
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkReleaseSwapchainImagesEXT: [3]
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 63 | 0 |
| the target of the first window | 25 | 0 |
| the target of the second window | 0 | 0 |
| the swapchain generations | 0 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool, first slot 0 | 0 | 0 |
| vkCreateCommandPool, first slot 1 | 0 | 0 |
| vkCreateCommandPool, second slot 0 | 0 | 0 |
| vkCreateCommandPool, second slot 1 | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| replacing the resized window's generation | 0 | 0 |
| awaiting the old generation's present fence | 0 | 0 |
| destroying the old generation | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| closing the first window's frames | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| retiring the first window's frames | 0 | 0 |
| the first window's generations | 0 | 0 |
| the first window's surface | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| draining the second window | 0 | 0 |
| retiring the second window's frames | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generations of the second window | 0 | 0 |
| the surface of the second window | 0 | 0 |
| the device | 0 | 0 |
| the messenger and the instance | 1 | 0 |

- error reports: none
- records delivered: 89
- undelivered: 0
- verdict issues: []

#### Transcript

```
## VK-13: frames presented, generations and a window retired on present fences
presented and retired 6 frames on two windows
resized SurfaceExtent {extentWidth = 160, extentHeight = 120} to SurfaceExtent {extentWidth = 200, extentHeight = 150}; the old generation was held by [PresentationId (TargetId 0 1) 6]
closed the first window after its presentation PresentationId (TargetId 0 1) 9 and its skipped frame FrameSlotId (TargetId 0 1) 1 3 settled
the lifetime delivered 89 records
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
  "duration_seconds": 2.62,
  "ended_at": "2026-09-27T17:26:39.725Z",
  "evidence": [
    "evidence/test.vulkan-native/debug-names.log",
    "evidence/test.vulkan-native/debug-names.md",
    "evidence/test.vulkan-native/synchronization-hazard.log",
    "evidence/test.vulkan-native/synchronization-hazard.md",
    "evidence/test.vulkan-native/vk11-recording.log",
    "evidence/test.vulkan-native/vk11-recording.md",
    "evidence/test.vulkan-native/vk12-frames.log",
    "evidence/test.vulkan-native/vk12-frames.md",
    "evidence/test.vulkan-native/vk13-presentation.log",
    "evidence/test.vulkan-native/vk13-presentation.md",
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
  "executed_commit": "deb59b549316bd29d34e59c14db116f44b395d19",
  "executed_tree": "9f76e2246ac4d89564fde3c302530cab24fc1d4c",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "0eb23dbd2d7f17c40f8d73ab8d8ae4d2b05c414a",
  "input_identity": "d4d05b600d3777399659af99c78d0c98f46c06b7644fb9913f8225f12c1080c7",
  "outcome": "passed",
  "plan_identity": "ffe4c63b09f4cb6b561d1aead1d7543379818ff0b63efb6917f15bf967c78c29",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 11.296,
    "ended_at": "2026-09-27T17:26:37.105Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-27T17:26:25.809Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36336845116/attempts/1",
  "started_at": "2026-09-27T17:26:37.105Z",
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
  "duration_seconds": 15.569,
  "ended_at": "2026-09-27T17:26:25.597Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "deb59b549316bd29d34e59c14db116f44b395d19",
  "executed_tree": "9f76e2246ac4d89564fde3c302530cab24fc1d4c",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "0eb23dbd2d7f17c40f8d73ab8d8ae4d2b05c414a",
  "input_identity": "d4d05b600d3777399659af99c78d0c98f46c06b7644fb9913f8225f12c1080c7",
  "outcome": "passed",
  "plan_identity": "ffe4c63b09f4cb6b561d1aead1d7543379818ff0b63efb6917f15bf967c78c29",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36336845116/attempts/1",
  "started_at": "2026-09-27T17:26:10.028Z",
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
