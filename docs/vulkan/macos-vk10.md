# The VK-10 Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote, verbatim, and lines the runs printed.

This is the local macOS evidence for issue #222, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: the documented Darwin plan, then `run.py` for `test.vulkan-headless`
and — under the human user's explicit approval for this task's runs, given on
2026-09-25 and carried on that one command as
`HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under MoltenVK and
Cocoa, with the catalog's `--complete` command. Both passed at commit
`fb93e8c3193fd226fb4faa72782cb10acb5d0dc2`.

The native group's preparation built the suite in 12.728 s, and its watched
native execution — the shared session and its roots, every example and child,
retirement, the diagnostic verdict after the last teardown callback — took
5.496 s against the 30-second watchdog. The receipts record `Darwin` and the
local prefix's own toolchain map — the MoltenVK driver, the 1.3.296 layer with
`+synchronization` — and no `ci-image` entry, so neither can satisfy a Linux
plan. The Linux evidence is [`linux-vk10.md`](linux-vk10.md).

VK-10's native cases ran over the shared roots. A shown 160×120 window's target
built its generation on the graphics owner's thread from the surface's concrete
extent — 320×240, the framebuffer's pixels at content scale 2.0, which is the
Retina difference the compatibility record anticipated — in `B8G8R8A8_SRGB`
(format 50) with FIFO and a view of each of its 3 images; a window resized
through the host's command port was replaced at its new framebuffer extent with
the old generation handed over as `oldSwapchain`, retired, and destroyed on the
owner's thread only once the example ended the CPU use it held. The shared
session's destruction order shows each target's image views, then its
swapchain, before its surface, and every one of them before the device.

The plan selected: `build.all`, `test.engine`, `test.foundation`, `test.runtime`, `test.glfw`, `smoke.console`, `test.vulkan-headless`, `test.vulkan-native`, `test.workflow`.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
108 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 53
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 67 records delivered
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 4.9257e-2s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.594446s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.165832s
vulkan-native-tests: private vk6-capture: ExitSuccess in 4.795e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.200676s
vulkan-native-tests: the process ran for 2.798239s, fixtures, examples and teardown included
```

VK-10's generation case printed:

```
VK-10 generation: 320x240 from ExtentFromSurface, window 160x120 at content scale 2.0, 3 images of format 50
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures, 1 pending — the pending one is the failed-initialization case, which Cocoa cannot provoke |
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
  "duration_seconds": 5.496,
  "ended_at": "2026-09-25T13:50:26.027Z",
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
    "evidence/test.vulkan-native/vk7-roots.md"
  ],
  "executed": true,
  "executed_commit": "fb93e8c3193fd226fb4faa72782cb10acb5d0dc2",
  "executed_tree": "db36e1c35e73b7b651fcdc56877fcb439eb727bd",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "fb93e8c3193fd226fb4faa72782cb10acb5d0dc2",
  "input_identity": "c74531546e379f5fab7e0b5296ef07cf4db5830f94dd0374af376339c1532f7c",
  "outcome": "passed",
  "plan_identity": "7015f0674977de4398f1a0ec42b9eba2092d8637e51690683f8907be06e128bc",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 12.728,
    "ended_at": "2026-09-25T13:50:20.531Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T13:50:07.802Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T13:50:20.531Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "53c8baf03525871852bc0293726ad24328cd91ff9e6df8888e24914619411a64",
    "vulkan": "1d4b16963c8741cad18e9bdc5b8a1419447f0ccc24da61b5a14acdc0949a64de",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 7922f643fef9"
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
  "duration_seconds": 29.35,
  "ended_at": "2026-09-25T13:50:00.416Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "fb93e8c3193fd226fb4faa72782cb10acb5d0dc2",
  "executed_tree": "db36e1c35e73b7b651fcdc56877fcb439eb727bd",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "fb93e8c3193fd226fb4faa72782cb10acb5d0dc2",
  "input_identity": "c74531546e379f5fab7e0b5296ef07cf4db5830f94dd0374af376339c1532f7c",
  "outcome": "passed",
  "plan_identity": "7015f0674977de4398f1a0ec42b9eba2092d8637e51690683f8907be06e128bc",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T13:49:31.065Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "53c8baf03525871852bc0293726ad24328cd91ff9e6df8888e24914619411a64",
    "vulkan": "1d4b16963c8741cad18e9bdc5b8a1419447f0ccc24da61b5a14acdc0949a64de",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 7922f643fef9"
  },
  "worker": "local"
}
```
