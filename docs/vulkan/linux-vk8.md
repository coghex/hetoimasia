# The VK-8 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the two
> receipts the validation runner wrote on the Linux worker, verbatim, and lines
> the runs printed.

This is the Linux evidence for issue #220: pull request #260's validation run
[36080224597](https://github.com/coghex/hetoimasia/actions/runs/36080224597/attempts/1), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe and the pinned 1.3.275 validation layer with
`+synchronization`. The runner executed the integration candidate
`dd27aa65a018bfbd97a3fb699894fe330bafd71d`, the merge of the pull request's head
`a3f1731bffa912d456a3c87fbae93470cf3d946c` into its base, with the catalog's `--complete`
command.

`test.vulkan-native`'s preparation built the suite in 1.066 s. Its watched native
execution — the isolated X11 display the command started for itself, the shared
session and its roots, every example and child, retirement, the diagnostic
verdict after the last teardown callback, and the display's own teardown — took
1.768 s against the 30-second watchdog. The display helper's logs are
in the worker's `validation-receipts-vulkan` artifact beside each scenario's
output and record. The macOS evidence is [`macos-vk8.md`](macos-vk8.md).

## Captured evidence

### The native suite's report

```
x11.sh: display :0 on X server The X.Org Foundation, window manager "Openbox" (0x40000e), WAYLAND_DISPLAY unset
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
106 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 16
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 9.824434e-2s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.145996104s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.9909837e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 9.9391221e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.138760006s
vulkan-native-tests: the process ran for 0.838944689s, fixtures, examples and teardown included
```

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The synchronization-validation control

#### Two writes to one buffer with no barrier between them

- device: llvmpipe (LLVM 20.1.2, 256 bits)

| step | reports | errors |
| --- | --- | --- |
| the loader's offer | 0 | 0 |
| vkCreateInstance | 63 | 0 |
| vkCreateDebugUtilsMessengerEXT | 0 | 0 |
| vkCreateDevice | 13 | 0 |
| vkCreateBuffer | 0 | 0 |
| vkAllocateMemory | 0 | 0 |
| vkBindBufferMemory | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkAllocateCommandBuffers | 0 | 0 |
| vkBeginCommandBuffer | 0 | 0 |
| vkCmdFillBuffer, the first write | 0 | 0 |
| vkCmdFillBuffer, the second write with no barrier | 1 | 1 |
| vkEndCommandBuffer | 0 | 0 |
| vkDestroyCommandPool | 0 | 0 |
| vkFreeMemory | 0 | 0 |
| vkDestroyBuffer | 0 | 0 |
| vkDestroyDevice | 0 | 0 |
| vkDestroyDebugUtilsMessengerEXT | 0 | 0 |
| vkDestroyInstance | 1 | 0 |

- error reports, by message id: SYNC-HAZARD-WRITE-AFTER-WRITE
- records delivered: 90
- undelivered: 0
- verdict issues: [ErrorLatched]

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
  "duration_seconds": 1.768,
  "ended_at": "2026-09-25T01:07:28.778Z",
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
  "executed_commit": "dd27aa65a018bfbd97a3fb699894fe330bafd71d",
  "executed_tree": "067733ad2ee0dc4ff9d5bed2f65254374ae09723",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "a3f1731bffa912d456a3c87fbae93470cf3d946c",
  "input_identity": "c8013f8feb74d07d8d593e133166aa88d556f052844651069413abd63ecad756",
  "outcome": "passed",
  "plan_identity": "a43c6b22c9a8496c634684f7ac87a95549a89f886a9279da73c72a39e99c3c50",
  "policy_version": "cb5d8291713043b74d8de6c79379f07a527b887e5a4f46ef171770a53e8ff0c9",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 1.066,
    "ended_at": "2026-09-25T01:07:27.010Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T01:07:25.944Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36080224597/attempts/1",
  "started_at": "2026-09-25T01:07:27.010Z",
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
  "duration_seconds": 4.085,
  "ended_at": "2026-09-25T01:07:25.753Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "dd27aa65a018bfbd97a3fb699894fe330bafd71d",
  "executed_tree": "067733ad2ee0dc4ff9d5bed2f65254374ae09723",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "a3f1731bffa912d456a3c87fbae93470cf3d946c",
  "input_identity": "c8013f8feb74d07d8d593e133166aa88d556f052844651069413abd63ecad756",
  "outcome": "passed",
  "plan_identity": "a43c6b22c9a8496c634684f7ac87a95549a89f886a9279da73c72a39e99c3c50",
  "policy_version": "cb5d8291713043b74d8de6c79379f07a527b887e5a4f46ef171770a53e8ff0c9",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36080224597/attempts/1",
  "started_at": "2026-09-25T01:07:21.668Z",
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
