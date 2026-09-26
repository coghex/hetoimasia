# #269's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the environment section of the
> `vk2-compatibility` record, and the two receipts the validation runner wrote,
> verbatim.

This is the local macOS evidence for issue #269, the logging and failure
modules' split into public facades over hidden modules, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: the documented Darwin plan, then `run.py` for `test.vulkan-headless`
and — under the owner's standing approval for desktop runs an issue needs,
carried on the one command as `HETOIMASIA_NATIVE_SESSION=desktop` —
`test.vulkan-native`, under MoltenVK and Cocoa, with the catalog's `--complete`
command. Both passed at commit
`18712c3ee724af60240c0dda30d5e068e61bca22`.

The split moves code and changes no behaviour: `Hetoimasia.Foundation.Log` and
`Hetoimasia.Foundation.Failure` keep their exports, and every Vulkan package
reaches them through those public modules exactly as before. The native
group's preparation built the suite in 21.525 s, and its watched native
execution took 2.351 s against the 30-second watchdog. The receipts record
`Darwin` and the local prefix's own toolchain map — the MoltenVK driver, the
1.3.296 layer with `+synchronization` — and no `ci-image` entry, so neither can
satisfy a Linux plan. The prefix is a private one built for this run with
`tools/native/native.py build`, because the shared prefix predates this
machine's current Command Line Tools; its `vulkan` and `native-manifest`
identities are therefore its own. Every scenario passed and the shared
session's verdict was clean. The Linux execution is CI's.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
110 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 82
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 67 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.184769s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 3.9058e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.174734s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.266536s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.130431s
vulkan-native-tests: private vk6-capture: ExitSuccess in 3.9881e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.158333s
vulkan-native-tests: the process ran for 1.611071s, fixtures, examples and teardown included
```

### The `vk2-compatibility` record's environment

- source digest: 9baa3c35ef90786cf6220ec5b9367b0dea96b6f5b0bb364abc79bff6aab0689f
- repository revision: 18712c3ee724af60240c0dda30d5e068e61bca22
- platform: darwin/aarch64
- session authorization: the desktop opt-in on this run's command, under the owner's standing approval
- VK_DRIVER_FILES: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/f6d65e64-c75f-4eff-99f1-d20c8b83d5aa/scratchpad/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
- VK_LAYER_PATH: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/f6d65e64-c75f-4eff-99f1-d20c8b83d5aa/scratchpad/native/glfw/vulkan/share/vulkan/explicit_layer.d
- cleared discovery overrides: VK_LOADER_LAYERS_DISABLE=~implicit~
- loader instance version: 1.3.296
- layers the pinned path offers: VK_LAYER_KHRONOS_validation 1.3.296
- implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
- layers requested: VK_LAYER_KHRONOS_validation
- the validation layer is in the loaded chain: yes
- validation features enabled by the create info: SynchronizationValidation
- surface extensions GLFW requires: VK_KHR_surface, VK_EXT_metal_surface

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
  "duration_seconds": 2.351,
  "ended_at": "2026-09-26T21:06:25.864Z",
  "evidence": [
    "evidence/test.vulkan-native/debug-names.log",
    "evidence/test.vulkan-native/debug-names.md",
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
    "evidence/test.vulkan-native/vk7-roots.md"
  ],
  "executed": true,
  "executed_commit": "18712c3ee724af60240c0dda30d5e068e61bca22",
  "executed_tree": "e206b141d878b58f444882248902cbe9b66ce62e",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "18712c3ee724af60240c0dda30d5e068e61bca22",
  "input_identity": "e5c1c27a41bc5720aa8e3d21f7663ef1f6d9925af87719f11d393f7342569eab",
  "outcome": "passed",
  "plan_identity": "a2dd6115146825ca56edf60c744302520ccda688eb5fa2bac4506e22a51a2bfa",
  "policy_version": "5e4ad558eadaea0fd0787938c85b8d2a310becdf812823df50d6826d72fdac85",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 21.525,
    "ended_at": "2026-09-26T21:06:23.513Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-26T21:06:01.987Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-26T21:06:23.513Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "50cfd35804c438ec335d8e4ca6d438300935b41959b474cdc27ae87d39cf15b5",
    "vulkan": "663a232ce3b1835655c5d13c4ac6493a90aba73596cd8b7d1f22ef58f788fdc8",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 b434371904e7"
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
  "duration_seconds": 59.632,
  "ended_at": "2026-09-26T21:05:46.261Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "18712c3ee724af60240c0dda30d5e068e61bca22",
  "executed_tree": "e206b141d878b58f444882248902cbe9b66ce62e",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "18712c3ee724af60240c0dda30d5e068e61bca22",
  "input_identity": "e5c1c27a41bc5720aa8e3d21f7663ef1f6d9925af87719f11d393f7342569eab",
  "outcome": "passed",
  "plan_identity": "a2dd6115146825ca56edf60c744302520ccda688eb5fa2bac4506e22a51a2bfa",
  "policy_version": "5e4ad558eadaea0fd0787938c85b8d2a310becdf812823df50d6826d72fdac85",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-26T21:04:46.628Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "50cfd35804c438ec335d8e4ca6d438300935b41959b474cdc27ae87d39cf15b5",
    "vulkan": "663a232ce3b1835655c5d13c4ac6493a90aba73596cd8b7d1f22ef58f788fdc8",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 b434371904e7"
  },
  "worker": "local"
}
```
