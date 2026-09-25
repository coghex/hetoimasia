# The VK-10 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote on the Linux worker, verbatim, and lines
> the runs printed.

This is the Linux evidence for issue #222: pull request #262's validation run
[36154344605](https://github.com/coghex/hetoimasia/actions/runs/36154344605/attempts/1), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe and the pinned validation layer with `+synchronization`. The
runner executed the integration candidate
`8fecd1f07ee50c179d8c068cfe311062b6b3d863`, the merge of the pull request's head
`7d872ec4f0fafd261743010e19af4022d2b3e2f8` into its base, with the catalog's `--complete`
command.

`test.vulkan-native`'s preparation built the suite in 4.426 s. Its watched native
execution — the isolated X11 display the command started for itself, the shared
session and its roots, every example and child, retirement, the diagnostic
verdict after the last teardown callback, and the display's own teardown — took
1.868 s against the 30-second watchdog. The display helper's logs are in the
worker's `validation-receipts-vulkan` artifact beside each scenario's output
and record. The macOS evidence is [`macos-vk10.md`](macos-vk10.md).

VK-10's native cases ran over the shared roots. On the isolated display, with no
scaling, a shown 160×120 window's target built its generation on the graphics
owner's thread from the surface's concrete extent — 160×120, the window's size,
where on the Retina display it was twice that — in `B8G8R8A8_SRGB` (format 50)
with FIFO and a view of each of its 4 images; the resized window was replaced at
its new framebuffer extent with the old generation handed over, retired, and
destroyed only once the example ended the CPU use it held. The shared session's
destruction order shows each target's image views, then its swapchain, before
its surface, and every one of them before the device.

## Captured evidence

### The native suite's report

```
x11.sh: display :0 on X server The X.Org Foundation, window manager "Openbox" (0x40000e), WAYLAND_DISPLAY unset
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
108 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 59
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 9.4875488e-2s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.142252676s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.7762645e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 9.7083668e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.135637759s
vulkan-native-tests: the process ran for 0.998758711s, fixtures, examples and teardown included
```

VK-10's generation case printed:

```
VK-10 generation: 160x120 from ExtentFromSurface, window 160x120 at content scale 1.0, 4 images of format 50
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

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
  "duration_seconds": 1.868,
  "ended_at": "2026-09-25T15:29:41.577Z",
  "evidence": [
    "evidence/test.vulkan-native/synchronization-hazard.log",
    "evidence/test.vulkan-native/synchronization-hazard.md",
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
  "executed_commit": "8fecd1f07ee50c179d8c068cfe311062b6b3d863",
  "executed_tree": "085735e9f70ff8c18157cd616bba09279a87261e",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "7d872ec4f0fafd261743010e19af4022d2b3e2f8",
  "input_identity": "d438b6b364bc9ba6afb3a19dc4d537d747193471052721e269d1973e8282971e",
  "outcome": "passed",
  "plan_identity": "2a135503e5c47433ef2aa52d6a1287307cf954f9442e0db1220a8bca99d22006",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 4.426,
    "ended_at": "2026-09-25T15:29:39.709Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T15:29:35.283Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36154344605/attempts/1",
  "started_at": "2026-09-25T15:29:39.709Z",
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
  "duration_seconds": 13.617,
  "ended_at": "2026-09-25T15:29:35.091Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "8fecd1f07ee50c179d8c068cfe311062b6b3d863",
  "executed_tree": "085735e9f70ff8c18157cd616bba09279a87261e",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "7d872ec4f0fafd261743010e19af4022d2b3e2f8",
  "input_identity": "d438b6b364bc9ba6afb3a19dc4d537d747193471052721e269d1973e8282971e",
  "outcome": "passed",
  "plan_identity": "2a135503e5c47433ef2aa52d6a1287307cf954f9442e0db1220a8bca99d22006",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36154344605/attempts/1",
  "started_at": "2026-09-25T15:29:21.475Z",
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
