# The VK-14 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are lines
> the run printed, the record the `vk14-recovery` child wrote, and the two
> receipts the validation runner wrote on the Linux worker, verbatim.

This is the Linux evidence for issue #229: pull request #293's validation run
[36379106304](https://github.com/coghex/hetoimasia/actions/runs/36379106304), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe (lvp 1.4.318 9d69cae2004b) and the pinned validation layer
(`VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization`). The runner executed the integration candidate
`8e05c11dd1bcba2ab3653d3c9bd70bdc49f96af2`, the merge of the pull request's head
`04b602b0f1b3d89e0e6e7fb2aae6b36b7c78d14f` into its base, with the catalog's `--complete`
command; input identity `fc3deca9e8bc5e5d77583614f7ca4433fbc26c9afd41ce9efbe2e7a231056596`.

`test.vulkan-native`'s preparation built the suite in 16.019 s. Its watched native
execution — the isolated X11 display the command started for itself, the shared
session and its roots, every example and child, retirement, the diagnostic
verdict after the last teardown callback, and the display's own teardown — took
3.02 s against the 30-second watchdog, over a non-empty selection of 116
examples. `test.vulkan-headless` passed too, with `native-tests`' 305 examples and
`integration-tests`' 49. The display helper's logs are in the worker's
`validation-receipts-vulkan` artifact beside each scenario's output and record.
The macOS evidence is [`macos-vk14.md`](macos-vk14.md). This run is over the
fix for the review of the merge of `master`'s VK-15 terminal failure (#231);
since the merge its native suite also runs VK-15's `vk15-validation-stop` and
`vk15-retention`, which passed. It replaces the evidence of the pull request's
earlier runs, whose Vulkan groups passed too: [36373633189](https://github.com/coghex/hetoimasia/actions/runs/36373633189), [36347413844](https://github.com/coghex/hetoimasia/actions/runs/36347413844),
[36346536996](https://github.com/coghex/hetoimasia/actions/runs/36346536996), [36345767851](https://github.com/coghex/hetoimasia/actions/runs/36345767851), [36344844515](https://github.com/coghex/hetoimasia/actions/runs/36344844515) and [36343333703](https://github.com/coghex/hetoimasia/actions/runs/36343333703). Every
group of this run passed; the third of those runs failed one `test.foundation`
Workers example, "keeps the parent alive while a cancellation delivery blocks,
until the worker is released", as #227's Linux run once did, though the pull
request changes no foundation input.

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
vulkan-native-tests: private debug-names: ExitSuccess in 0.12717832s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 9.4074225e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.127012865s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.17107828s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.157022632s
vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.156177978s
vulkan-native-tests: private vk15-retention: ExitSuccess in 0.118949903s
vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.135031619s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.141542835s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.7663962e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 9.4412069e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.134524009s
vulkan-native-tests: the process ran for 2.096256642s, fixtures, examples and teardown included
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
  "duration_seconds": 3.02,
  "ended_at": "2026-09-28T04:48:23.721Z",
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
  "executed_commit": "8e05c11dd1bcba2ab3653d3c9bd70bdc49f96af2",
  "executed_tree": "dc5628d5d0b817bf8ebea3c4dfb6025a7fad840b",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "04b602b0f1b3d89e0e6e7fb2aae6b36b7c78d14f",
  "input_identity": "fc3deca9e8bc5e5d77583614f7ca4433fbc26c9afd41ce9efbe2e7a231056596",
  "outcome": "passed",
  "plan_identity": "9ac1360e2d86d706e3f1066b0726bb30caf3e91d49e6d1bc93b9bf3e6c6da275",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 16.019,
    "ended_at": "2026-09-28T04:48:20.702Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-28T04:48:04.682Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36379106304/attempts/1",
  "started_at": "2026-09-28T04:48:20.702Z",
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
  "duration_seconds": 37.95,
  "ended_at": "2026-09-28T04:48:04.474Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "8e05c11dd1bcba2ab3653d3c9bd70bdc49f96af2",
  "executed_tree": "dc5628d5d0b817bf8ebea3c4dfb6025a7fad840b",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "04b602b0f1b3d89e0e6e7fb2aae6b36b7c78d14f",
  "input_identity": "fc3deca9e8bc5e5d77583614f7ca4433fbc26c9afd41ce9efbe2e7a231056596",
  "outcome": "passed",
  "plan_identity": "9ac1360e2d86d706e3f1066b0726bb30caf3e91d49e6d1bc93b9bf3e6c6da275",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36379106304/attempts/1",
  "started_at": "2026-09-28T04:47:26.524Z",
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
