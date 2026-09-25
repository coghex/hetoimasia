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
`7d872ec4f0fafd261743010e19af4022d2b3e2f8`.

The native group's preparation built the suite in 12.649 s, and its watched
native execution — the shared session and its roots, every example and child,
retirement, the diagnostic verdict after the last teardown callback — took
5.696 s against the 30-second watchdog. The receipts record `Darwin` and the
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
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 4.5839e-2s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.495261s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.160767s
vulkan-native-tests: private vk6-capture: ExitSuccess in 4.9575e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.196792s
vulkan-native-tests: the process ran for 2.759208s, fixtures, examples and teardown included
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
  "duration_seconds": 5.696,
  "ended_at": "2026-09-25T15:28:51.624Z",
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
  "executed_commit": "7d872ec4f0fafd261743010e19af4022d2b3e2f8",
  "executed_tree": "085735e9f70ff8c18157cd616bba09279a87261e",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "7d872ec4f0fafd261743010e19af4022d2b3e2f8",
  "input_identity": "54d4351180f43fbda0da78e2fe248ca6d201350bd4f0c075e7d0370e385370f3",
  "outcome": "passed",
  "plan_identity": "5dc021df2fb559634c49802677fae435005eda51160b31a0691de19d03d2a313",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 12.649,
    "ended_at": "2026-09-25T15:28:45.927Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T15:28:33.278Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T15:28:45.927Z",
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
  "duration_seconds": 39.063,
  "ended_at": "2026-09-25T15:28:32.011Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "7d872ec4f0fafd261743010e19af4022d2b3e2f8",
  "executed_tree": "085735e9f70ff8c18157cd616bba09279a87261e",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "7d872ec4f0fafd261743010e19af4022d2b3e2f8",
  "input_identity": "54d4351180f43fbda0da78e2fe248ca6d201350bd4f0c075e7d0370e385370f3",
  "outcome": "passed",
  "plan_identity": "5dc021df2fb559634c49802677fae435005eda51160b31a0691de19d03d2a313",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-25T15:27:52.947Z",
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
