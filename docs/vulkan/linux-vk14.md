# The VK-14 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are lines
> the run printed, the record the `vk14-recovery` child wrote, and the two
> receipts the validation runner wrote on the Linux worker, verbatim.

This is the Linux evidence for issue #229: pull request #293's validation run
[36373633189](https://github.com/coghex/hetoimasia/actions/runs/36373633189), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe (lvp 1.4.318 9d69cae2004b) and the pinned validation layer
(`VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization`). The runner executed the integration candidate
`f803e202260557783915728744b2c3d04bcf6925`, the merge of the pull request's head
`7e5243b5acd8ae749dbc4cbf1edf3fabd6822619` into its base, with the catalog's `--complete`
command; input identity `20dc801d71d7090b56492c145951e83d8b81a129c7e1909bf825652ebeb152c2`.

`test.vulkan-native`'s preparation built the suite in 30.129 s. Its watched native
execution — the isolated X11 display the command started for itself, the shared
session and its roots, every example and child, retirement, the diagnostic
verdict after the last teardown callback, and the display's own teardown — took
3.071 s against the 30-second watchdog, over a non-empty selection of 116
examples. `test.vulkan-headless` passed too, with `native-tests`' 303 examples and
`integration-tests`' 49. The display helper's logs are in the worker's
`validation-receipts-vulkan` artifact beside each scenario's output and record.
The macOS evidence is [`macos-vk14.md`](macos-vk14.md). This run is over the
merge of `master`'s VK-15 terminal failure (#231) into this branch, and its
native suite also ran VK-15's `vk15-validation-stop` and `vk15-retention`,
which passed. It replaces the evidence of the pull request's earlier runs,
whose Vulkan groups passed too: [36347413844](https://github.com/coghex/hetoimasia/actions/runs/36347413844), [36346536996](https://github.com/coghex/hetoimasia/actions/runs/36346536996),
[36345767851](https://github.com/coghex/hetoimasia/actions/runs/36345767851), [36344844515](https://github.com/coghex/hetoimasia/actions/runs/36344844515) and [36343333703](https://github.com/coghex/hetoimasia/actions/runs/36343333703). Every group of this run passed; the
second of those runs failed one `test.foundation` Workers example, "keeps the
parent alive while a cancellation delivery blocks, until the worker is
released", as #227's Linux run once did, though the pull request changes no
foundation input.

VK-14's native case, `vk14-recovery`, ran on private roots in its own child
process on llvmpipe, over two windows' surfaces, each with a generation. It
presented three triangle frames to each window and drained every present fence.
The first window's next acquisition was answered `VK_ERROR_SURFACE_LOST_KHR`
without the call being made, and answered `AcquisitionPending
PendingSurfaceLost`. While the second window presented three frames, the first
window's four views and its swapchain were destroyed, then its lost surface; a
replacement surface was created on the same window, its support checked against
the one queue family, and a fresh swapchain handed nothing over was built on
it, the target the same `TargetId` with one attempt spent; the first window then
presented three frames on its new generation. The second window was resized, its
old generation left eligible for disposal once its presentations had retired,
and the readback buffer's creation was answered `VK_ERROR_OUT_OF_DEVICE_MEMORY`
without the call being made: one reclamation pass destroyed that generation's
four views and its swapchain, and the creation was made once more and succeeded.
Twelve frames were presented in all, nothing was left unsettled before
retirement, no step received a validation error, with synchronization validation
on, and the verdict after the last teardown callback was clean. The shared roots'
replacement through the controller and the production bridge passed too.

## Captured evidence

### The native suite's report

```
x11.sh: display :0 on X server The X.Org Foundation, window manager "Openbox" (0x40000e), WAYLAND_DISPLAY unset
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
116 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 169
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.12348589s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 9.3974482e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.127850327s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.170734041s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.159053295s
vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.155457016s
vulkan-native-tests: private vk15-retention: ExitSuccess in 0.11605513s
vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.130341468s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.14239941s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.9112324e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 0.102566542s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.133710507s
vulkan-native-tests: the process ran for 2.135337746s, fixtures, examples and teardown included
```

### The `vk14-recovery` record


#### A lost surface replaced on its live window, and an allocation recovered

- device: llvmpipe (LLVM 20.1.2, 256 bits)
- frames presented in all: 12
- the injected acquisition answered AcquisitionPending PendingSurfaceLost
- the first window's surface 0x20000000002 was replaced by 0x320000000032 on the same window; its generation GenerationId (TargetId 0 1) 0 by GenerationId (TargetId 0 1) 1
- the target before and after: (TargetId 0 1,TargetId 0 1); recovery attempts spent: Just 1
- offering the replacement answered ReplacementInstalled
- the second window presented 3 frames while the first recovered
- the first window presented 3 frames on its new generation

The roots' native calls from the injection to the replacement's generation:

1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroySwapchainKHR 0x40000000004
1. vkDestroySurfaceKHR 0x20000000002
1. vkGetPhysicalDeviceSurfaceSupportKHR 0x320000000032
1. vkCreateSwapchainKHR on 0x320000000032, handing nothing over

- the second window's retired generation GenerationId (TargetId 1 1) 0 was eligible for disposal before the failure: True
- it was gone once the creation returned: True; the creation answered a readback

The native calls during the readback's creation:

1. vkCreateBuffer: VK_ERROR_OUT_OF_DEVICE_MEMORY (injected)
1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroySwapchainKHR 0xd000000000d
1. vkCreateBuffer

- left before retirement: ([],[],[])

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
| awaiting the first window's present fences | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| awaiting the second window's present fences | 0 | 0 |
| the injected acquisition | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| retiring the lost surface's generation and the lost surface, while the second window presents | 0 | 0 |
| the replacement surface, on the same window | 0 | 0 |
| offering the replacement | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| the replacement's generation, while the second window presents | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| awaiting the first window's present fences | 0 | 0 |
| replacing the resized window's generation | 0 | 0 |
| awaiting the retired generation's presentations | 0 | 0 |
| the readback's creation, out of memory once | 0 | 0 |
| releasing the readback | 0 | 0 |
| draining both windows | 0 | 0 |
| retiring the first window's frames | 0 | 0 |
| retiring the second window's frames | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generations of the first window | 0 | 0 |
| the surface of the first window | 0 | 0 |
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
#### VK-14: a lost surface replaced on its live window, and an allocation recovered by reclamation
presented and retired three frames on each window
replaced the first window's surface 0x20000000002 with 0x320000000032 while the second presented 3 frames
recovered the readback's allocation: vkCreateBuffer: VK_ERROR_OUT_OF_DEVICE_MEMORY (injected); vkDestroyImageView; vkDestroyImageView; vkDestroyImageView; vkDestroyImageView; vkDestroySwapchainKHR 0xd000000000d; vkCreateBuffer
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
  "duration_seconds": 3.071,
  "ended_at": "2026-09-28T03:27:59.335Z",
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
    "evidence/test.vulkan-native/vk14-recovery.log",
    "evidence/test.vulkan-native/vk14-recovery.md",
    "evidence/test.vulkan-native/vk15-retention.log",
    "evidence/test.vulkan-native/vk15-retention.md",
    "evidence/test.vulkan-native/vk15-validation-stop.log",
    "evidence/test.vulkan-native/vk15-validation-stop.md",
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
  "executed_commit": "f803e202260557783915728744b2c3d04bcf6925",
  "executed_tree": "2b9c11a84a6d96edc2c806b2dda62bc49052b98c",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "7e5243b5acd8ae749dbc4cbf1edf3fabd6822619",
  "input_identity": "20dc801d71d7090b56492c145951e83d8b81a129c7e1909bf825652ebeb152c2",
  "outcome": "passed",
  "plan_identity": "da7534b89e0f95d3558f20dbf63cc72f3a5c0dc6340bd89cbbf079ef642a8c81",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 30.129,
    "ended_at": "2026-09-28T03:27:56.264Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-28T03:27:26.135Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36373633189/attempts/1",
  "started_at": "2026-09-28T03:27:56.264Z",
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
  "duration_seconds": 69.288,
  "ended_at": "2026-09-28T03:27:25.925Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "f803e202260557783915728744b2c3d04bcf6925",
  "executed_tree": "2b9c11a84a6d96edc2c806b2dda62bc49052b98c",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "7e5243b5acd8ae749dbc4cbf1edf3fabd6822619",
  "input_identity": "20dc801d71d7090b56492c145951e83d8b81a129c7e1909bf825652ebeb152c2",
  "outcome": "passed",
  "plan_identity": "da7534b89e0f95d3558f20dbf63cc72f3a5c0dc6340bd89cbbf079ef642a8c81",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36373633189/attempts/1",
  "started_at": "2026-09-28T03:26:16.637Z",
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
