# The VK-15 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote on the Linux worker, verbatim, lines the
> run printed, and the records the two VK-15 children wrote.

This is the Linux evidence for issue #231: pull request #292's validation run
[36360806147](https://github.com/coghex/hetoimasia/actions/runs/36360806147/attempts/1), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe (lvp 1.4.318 9d69cae2004b) and the pinned validation layer with
`+synchronization`. The runner executed the integration candidate
`ca476ffa279537b5469dee4de48d67378b21aebe`, the merge of the pull request's head
`5fd939d57889fa47c91a0bd4a4a764dcb77b993c` into its base, with the catalog's `--complete`
command; input identity `2ce788cd96d6d3fd6919cf4d1bd3ac7579891d1021e4cc18ad655c800ea81ebf`.

`test.vulkan-native`'s preparation built the suite in 15.721 s. Its watched native
execution — the isolated X11 display the command started for itself, the shared
session and its roots, every example and child, retirement, the diagnostic
verdict after the last teardown callback, and the display's own teardown — took
2.77 s against the 30-second watchdog. `test.vulkan-headless` passed too. So did every other group the run selected. The display helper's logs are in the
worker's `validation-receipts-vulkan` artifact beside each scenario's output and
record. The macOS evidence is [`macos-vk15.md`](macos-vk15.md). No device loss
was induced: VK-15's device-loss teardown is proved by the headless examples,
and the specification's rows in the proof records.

`vk15-validation-stop` ran on private roots in its own child process on
llvmpipe. It presented two triangle frames and observed both present fences,
submitted a third, and delivered one error-severity message through
`vkSubmitDebugUtilsMessageEXT`, identified as
`VUID-hetoimasia-vk15-injected-validation-error`. The third frame's
presentation and a further acquisition were each refused at the checkpoint with
`RefusedSessionFailed TerminalValidationError`; the frame was closed and settled
through its cleanup submission and release, and everything retired without a
failure, with nothing left unsettled and no device loss. Exactly one error
reached the capture — the injected one — and none anywhere else, with
synchronization validation on; the capture had been offered 90 reports once
`vkDestroyInstance` had returned, and the verdict after that last callback
counts the same 90 with `ErrorLatched` as its only issue.

`vk15-retention` ran the production composition over one visible window, held a
CPU use of its target's generation and let the host exit: the generation was
retained (`GenerationRetiredHeld`), the terminal latch reported the generations,
the roots and the instance's lease as retained with no primary failure and no
loss, nothing above the generation was destroyed, and the host still held the
window when the watcher wrote the record and terminated the process — the
fixture's destructive boundary, never orderly cleanup; no diagnostic verdict
follows it.

## Captured evidence

### The native suite's report

```
x11.sh: display :0 on X server The X.Org Foundation, window manager "Openbox" (0x40000e), WAYLAND_DISPLAY unset
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
114 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 94
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.129302374s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 9.5662252e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.129133959s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.174892334s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.157279754s
vulkan-native-tests: private vk15-retention: ExitSuccess in 0.116994244s
vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.135476615s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.142288159s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.8576624e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 9.8678881e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.135410899s
vulkan-native-tests: the process ran for 1.855132655s, fixtures, examples and teardown included
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `debug-names` | 6 examples, 0 failures |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk12-frames` | 7 examples, 0 failures |
| `vk13-presentation` | 7 examples, 0 failures |
| `vk15-retention` | 4 examples, 0 failures |
| `vk15-validation-stop` | 5 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The `vk15-validation-stop` record

#### A validation error during rendering

- device: llvmpipe (LLVM 20.1.2, 256 bits)
- frames presented and retired before the error: 2
- the interrupted frame's presentation answered: Left (RefusedSessionFailed TerminalValidationError)
- a further acquisition answered: Left (RefusedSessionFailed TerminalValidationError)
- primary failure: Just TerminalValidationError
- device loss observed: Nothing
- teardown evidence: []
- left once teardown had drained: ([],[],[])
- retirement: retiring the frames: returned; retiring the generations: returned; destroying the surface: returned; releasing and destroying the managed resources: returned

Native calls the frames made, status queries and drain waits left out:

1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR
1. vkAcquireNextImageKHR
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT
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
| the window's surface | 0 | 0 |
| the window's target | 25 | 0 |
| the swapchain generation | 0 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool, slot 0 | 0 | 0 |
| vkCreateCommandPool, slot 1 | 0 | 0 |
| a triangle | 0 | 0 |
| vkQueueSubmit2, a triangle | 0 | 0 |
| vkQueuePresentKHR | 0 | 0 |
| a triangle | 0 | 0 |
| vkQueueSubmit2, a triangle | 0 | 0 |
| vkQueuePresentKHR | 0 | 0 |
| awaiting the present fences | 0 | 0 |
| the frame the error interrupts | 0 | 0 |
| vkQueueSubmit2, the frame the error interrupts | 0 | 0 |
| vkSubmitDebugUtilsMessageEXT, the injected error | 1 | 1 |
| vkQueuePresentKHR, refused at the checkpoint | 0 | 0 |
| vkAcquireNextImageKHR, refused at the checkpoint | 0 | 0 |
| closing the window's frames | 0 | 0 |
| draining the frames | 0 | 0 |
| retiring the frames | 0 | 0 |
| retiring the generations | 0 | 0 |
| destroying the surface | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the device | 0 | 0 |
| the messenger and the instance | 1 | 0 |

- error reports: VUID-hetoimasia-vk15-injected-validation-error: Vulkan diagnostic
- offered once vkDestroyInstance had returned: 90
- offered in the verdict: 90
- records delivered: 90
- undelivered: 0
- verdict issues: [ErrorLatched]

### The `vk15-retention` record

#### A retained unverified resource

- a CPU use of the active generation held and never ended: True
- where the held generation stood: Just GenerationRetiredHeld
- primary failure: Nothing
- what teardown reported retained:
  - RetainedUnverified "the swapchain generations of TargetId 0 1 are retained: [GenerationId (TargetId 0 1) 0]"
  - RetainedUnverified "the Vulkan roots are retained: 1 target surfaces have not verifiably been destroyed"
  - RetainedUnverified "LeaseRetained LeaseOwed"
- the owner's run ended: True; destruction evidence: Nothing
- the roots when the watcher read them: instance RootLive, device RootLive, targets 1
- the host still holds the window, its attachment without a terminal record: True

The process was then terminated by the fixture's destructive boundary. The
session released nothing more: the operating system reclaims the window,
the surface, the device and the instance. This is not orderly cleanup,
and no diagnostic verdict follows, because the instance's messengers were
never destroyed and the last callback was never reached.

Native calls the session made, in the order they returned:

1. vkEnumerateInstanceExtensionProperties
1. vkCreateInstance
1. vkCreateDebugUtilsMessengerEXT
1. glfwCreateWindowSurface
1. vkEnumeratePhysicalDevices
1. vkCreateDevice
1. vkSetDebugUtilsObjectNameEXT
1. vkGetDeviceQueue
1. vkSetDebugUtilsObjectNameEXT
1. vkSetDebugUtilsObjectNameEXT
1. vkGetPhysicalDeviceSurfaceCapabilitiesKHR
1. vkCreateSwapchainKHR
1. vkSetDebugUtilsObjectNameEXT
1. vkGetSwapchainImagesKHR
1. vkSetDebugUtilsObjectNameEXT
1. vkCreateImageView
1. vkSetDebugUtilsObjectNameEXT
1. vkSetDebugUtilsObjectNameEXT
1. vkCreateImageView
1. vkSetDebugUtilsObjectNameEXT
1. vkSetDebugUtilsObjectNameEXT
1. vkCreateImageView
1. vkSetDebugUtilsObjectNameEXT
1. vkSetDebugUtilsObjectNameEXT
1. vkCreateImageView
1. vkSetDebugUtilsObjectNameEXT

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
  "duration_seconds": 2.77,
  "ended_at": "2026-09-28T00:06:44.316Z",
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
  "executed_commit": "ca476ffa279537b5469dee4de48d67378b21aebe",
  "executed_tree": "8e6542dc2bdc31d34cad915b0db824761f59901a",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "5fd939d57889fa47c91a0bd4a4a764dcb77b993c",
  "input_identity": "2ce788cd96d6d3fd6919cf4d1bd3ac7579891d1021e4cc18ad655c800ea81ebf",
  "outcome": "passed",
  "plan_identity": "1c7088a8d21d2cfe0141c3d1f754329e69151480be339c5cf49a4fc099a9a668",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 15.721,
    "ended_at": "2026-09-28T00:06:41.546Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-28T00:06:25.825Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36360806147/attempts/1",
  "started_at": "2026-09-28T00:06:41.546Z",
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
  "duration_seconds": 33.79,
  "ended_at": "2026-09-28T00:06:25.618Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "ca476ffa279537b5469dee4de48d67378b21aebe",
  "executed_tree": "8e6542dc2bdc31d34cad915b0db824761f59901a",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "5fd939d57889fa47c91a0bd4a4a764dcb77b993c",
  "input_identity": "2ce788cd96d6d3fd6919cf4d1bd3ac7579891d1021e4cc18ad655c800ea81ebf",
  "outcome": "passed",
  "plan_identity": "1c7088a8d21d2cfe0141c3d1f754329e69151480be339c5cf49a4fc099a9a668",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36360806147/attempts/1",
  "started_at": "2026-09-28T00:05:51.828Z",
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
