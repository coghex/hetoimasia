# The VK-11 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote on the Linux worker, verbatim, lines the
> run printed, and the record the `vk11-recording` child wrote.

This is the Linux evidence for issue #223: pull request #263's validation run
[36180004933](https://github.com/coghex/hetoimasia/actions/runs/36180004933/attempts/1), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe and the pinned validation layer with `+synchronization`. The
runner executed the integration candidate `a66d2a35a482748fee64e14f17d7cee5be361392`, the merge
of the pull request's head `5493b8abd79c040ee1693a4614d218a8a930b06c` into its base, with the
catalog's `--complete` command.

`test.vulkan-native`'s preparation built the suite in 5.828 s. Its watched native
execution — the isolated X11 display the command started for itself, the shared
session and its roots, every example and child, retirement, the diagnostic
verdict after the last teardown callback, and the display's own teardown — took
1.918 s against the 30-second watchdog. The display helper's logs are in the
worker's `validation-receipts-vulkan` artifact beside each scenario's output
and record. The macOS evidence is [`macos-vk11.md`](macos-vk11.md).

VK-11's native case, `vk11-recording`, ran on private roots in its own child
process on llvmpipe. Over a 160×120 window's surface it built a capture
generation of 160×120 in `B8G8R8A8_SRGB` (format 50) with 4 images; constructed
the pipeline layout, the pipeline over VK-9's embedded verification shaders, the
frame slot's storage and the readback buffer; recorded one sealed batch of
eleven commands through the audited `unsafe` subset against the fixture-private
frame; found all four resources held by it and the readback refusing its bytes;
discarded it, after which none was held; and destroyed everything. No step
received a validation error, with synchronization validation on, and the
verdict after the last teardown callback was clean.

## Captured evidence

### The native suite's report

```
x11.sh: display :0 on X server The X.Org Foundation, window manager "Openbox" (0x40000e), WAYLAND_DISPLAY unset
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
109 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 59
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 8.3068662e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.120882271s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.135084981s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 5.0727838e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 8.6952879e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.123750265s
vulkan-native-tests: the process ran for 1.057590094s, fixtures, examples and teardown included
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The `vk11-recording` record

#### A recorded, discarded triangle batch

- device: llvmpipe (LLVM 20.1.2, 256 bits)
- generation: 160x120, format 50, 4 images
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 11})
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
  "duration_seconds": 1.918,
  "ended_at": "2026-09-25T19:31:16.850Z",
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
    "evidence/test.vulkan-native/vk7-roots.md",
    "evidence/test.vulkan-native/x11-manager.log",
    "evidence/test.vulkan-native/x11-server.log",
    "evidence/test.vulkan-native/x11-server.txt"
  ],
  "executed": true,
  "executed_commit": "a66d2a35a482748fee64e14f17d7cee5be361392",
  "executed_tree": "3bb042dd701c7d7f11446901b8e218519f3705f9",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "5493b8abd79c040ee1693a4614d218a8a930b06c",
  "input_identity": "5fefad59d4cfd3bbc18b9c4ce2d48a4153b43936c996c9c5c22d6706c8592e20",
  "outcome": "passed",
  "plan_identity": "86c6c0e44eaded30bc0c5e7c447b4b9d058b59ebd4dbceaaaa171595c265a0d4",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 5.828,
    "ended_at": "2026-09-25T19:31:14.932Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T19:31:09.104Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36180004933/attempts/1",
  "started_at": "2026-09-25T19:31:14.932Z",
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
  "duration_seconds": 16.064,
  "ended_at": "2026-09-25T19:31:08.939Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "a66d2a35a482748fee64e14f17d7cee5be361392",
  "executed_tree": "3bb042dd701c7d7f11446901b8e218519f3705f9",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "5493b8abd79c040ee1693a4614d218a8a930b06c",
  "input_identity": "5fefad59d4cfd3bbc18b9c4ce2d48a4153b43936c996c9c5c22d6706c8592e20",
  "outcome": "passed",
  "plan_identity": "86c6c0e44eaded30bc0c5e7c447b4b9d058b59ebd4dbceaaaa171595c265a0d4",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36180004933/attempts/1",
  "started_at": "2026-09-25T19:30:52.875Z",
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
