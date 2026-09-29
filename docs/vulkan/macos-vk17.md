# VK-17's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the facts of the two `vk17-*`
> records, the environment section of the `vk2-compatibility` record, and the
> two receipts the validation runner wrote, verbatim. The per-scenario records
> the native receipt lists are retained unchanged beside this file, at the
> receipt's own relative paths under
> [`macos-vk17/`](macos-vk17/evidence/test.vulkan-native/); the logs it lists are
> reproduced verbatim at the end of this file, because the validation catalog
> classifies no `.log` path under `docs/` and an unclassified file would select
> every group and change the inputs these receipts identify.

This is the local macOS evidence for issue #233, VK-17's triangle sample and
its required native profile, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: a Darwin plan, then `run.py` for `test.vulkan-headless` and — under
the owner's standing approval for desktop runs an issue needs, carried on the
command as `HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under
MoltenVK and Cocoa, with the catalog's `--complete` command. Both passed at
commit `fc8bfe056de14cd2bde19df6856a40091610f2be`, input identity `14437135361f5af3a16294a4c7a94cb2023b0bdc5f21ef9538aa20fed8685682`. The plan also selected every
other non-optional group, because the catalog changed; those are CI's.

The native group's preparation — the suite and the triangle sample's
executable — took 1.844 s, and its watched native execution took
5.334 s against the 30-second watchdog: one aggregate budget for the whole
selection, both of VK-17's frame-slot configurations and every inherited case
together (121 examples, 0 failures, 1 pending). The headless group took 10.113 s, with
`shader-tests`' 14 examples, `integration-tests`' 91 and `native-tests`'
312. The receipts record `Darwin` and the local prefix's own toolchain map — the
driver `MoltenVK 1.4.0 05df2d2145b9`, which is **MoltenVK 1.4.2**'s library under a
manifest that declares API 1.4.0, and the layer `VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization` —
and no `ci-image` entry, so neither can satisfy a Linux plan. The prefix is a
private one built with `tools/native/native.py build` from the current pin,
since the shared one predates the MoltenVK 1.4.2 pin; its `vulkan` and
`native-manifest` identities are therefore its own. Every scenario passed and
the shared session's verdict was clean.

VK-17's required profile ran twice, each on private roots in a child process
of its own: `vk17-one-slot` with a frame budget of one slot (0.331932s), and
`vk17-two-slots` with two (0.329959s). Each drove the triangle sample's own drawing
through the production host with verification capture on, over two mapped
160×120 windows that requested no focus, whose framebuffers are 320×240 on
this display. In each, both windows' frames were captured; the first window
was resized to 200×150 through its command port and captured again at its new
generation's 400×300 extent; and the first-created window was closed and, once
its target had retired, the second was captured again. Every one of those
eight captured frames read the clear as (63, 63, 124, 255) at the background
point and the triangle as (243, 203, 89, 255) at its centroid — exactly the
sRGB encodings of the sample's linear colours, within the tolerance of 6 —
and each came from a frame the case saw acquired, submitted, presented and
retired on its own present fence. Every generation was an unclipped transfer
source (usage 17), every Vulkan call ran on the graphics owner's thread, and
both verdicts after the last teardown callback had no issue and no error.
Nothing about refresh cadence, vertical blank or pacing is inferred from it.

The graphics-owner interaction probe, the suite's last example, reported
pending, as it does in every run that does not activate it.

The plan's local worker declaration is the one
[docs/validation.md](../validation.md#a-local-run-and-its-receipt) shows, with
`test.glfw-wayland` added to it, since a Darwin plan that selects that group
then reports it inapplicable here.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
121 examples, 0 failures, 1 pending
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 145
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 70 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.196298s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 6.4747e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.187201s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.219667s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.31024s
vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.301883s
vulkan-native-tests: private vk15-retention: ExitSuccess in 0.178851s
vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.226594s
vulkan-native-tests: private vk16-composed: ExitSuccess in 0.290501s
vulkan-native-tests: private vk17-one-slot: ExitSuccess in 0.331932s
vulkan-native-tests: private vk17-two-slots: ExitSuccess in 0.329959s
vulkan-native-tests: private vk19-capture: ExitSuccess in 0.255349s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.269619s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.184276s
vulkan-native-tests: private vk6-capture: ExitSuccess in 5.5853e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.213624s
vulkan-native-tests: the process ran for 4.501074s, fixtures, examples and teardown included
```

### The `vk17-one-slot` record's facts

- both windows, first, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- both windows, second, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window, resized, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 400, extentHeight = 300} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the second window, after the first closed, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window was resized from SurfaceExtent {extentWidth = 320, extentHeight = 240}
- the first window's target had retired before the second's last capture: True
- generations seen (usage, clipped): [(17,False)]
- color formats the sample built pipelines for: [50]
- expected (red, green, blue, alpha) within 6: background (63,63,124,255), triangle (243,203,89,255)
- Vulkan calls: 184, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.2952

### The `vk17-two-slots` record's facts

- both windows, first, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- both windows, second, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window, resized, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 400, extentHeight = 300} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the second window, after the first closed, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window was resized from SurfaceExtent {extentWidth = 320, extentHeight = 240}
- the first window's target had retired before the second's last capture: True
- generations seen (usage, clipped): [(17,False)]
- color formats the sample built pipelines for: [50]
- expected (red, green, blue, alpha) within 6: background (63,63,124,255), triangle (243,203,89,255)
- Vulkan calls: 192, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.300462

### The per-scenario records

Each private scenario's record and log, as the receipt's `evidence` list names
them. The records are files relative to `macos-vk17/`; the logs are the
sections below.

| scenario | record | log | verdict | examples |
| --- | --- | --- | --- | --- |
| `debug-names` | [`debug-names.md`](macos-vk17/evidence/test.vulkan-native/debug-names.md) | [`debug-names.log`](#debug-nameslog) | pass | 6 examples, 0 failures |
| `synchronization-hazard` | [`synchronization-hazard.md`](macos-vk17/evidence/test.vulkan-native/synchronization-hazard.md) | [`synchronization-hazard.log`](#synchronization-hazardlog) | pass | 5 examples, 0 failures |
| `vk11-recording` | [`vk11-recording.md`](macos-vk17/evidence/test.vulkan-native/vk11-recording.md) | [`vk11-recording.log`](#vk11-recordinglog) | pass | 7 examples, 0 failures |
| `vk12-frames` | [`vk12-frames.md`](macos-vk17/evidence/test.vulkan-native/vk12-frames.md) | [`vk12-frames.log`](#vk12-frameslog) | pass | 7 examples, 0 failures |
| `vk13-presentation` | [`vk13-presentation.md`](macos-vk17/evidence/test.vulkan-native/vk13-presentation.md) | [`vk13-presentation.log`](#vk13-presentationlog) | pass | 7 examples, 0 failures |
| `vk14-recovery` | [`vk14-recovery.md`](macos-vk17/evidence/test.vulkan-native/vk14-recovery.md) | [`vk14-recovery.log`](#vk14-recoverylog) | pass | 8 examples, 0 failures |
| `vk15-retention` | [`vk15-retention.md`](macos-vk17/evidence/test.vulkan-native/vk15-retention.md) | [`vk15-retention.log`](#vk15-retentionlog) | pass | 4 examples, 0 failures |
| `vk15-validation-stop` | [`vk15-validation-stop.md`](macos-vk17/evidence/test.vulkan-native/vk15-validation-stop.md) | [`vk15-validation-stop.log`](#vk15-validation-stoplog) | pass | 5 examples, 0 failures |
| `vk16-composed` | [`vk16-composed.md`](macos-vk17/evidence/test.vulkan-native/vk16-composed.md) | [`vk16-composed.log`](#vk16-composedlog) | pass | 6 examples, 0 failures |
| `vk17-one-slot` | [`vk17-one-slot.md`](macos-vk17/evidence/test.vulkan-native/vk17-one-slot.md) | [`vk17-one-slot.log`](#vk17-one-slotlog) | pass | 9 examples, 0 failures |
| `vk17-two-slots` | [`vk17-two-slots.md`](macos-vk17/evidence/test.vulkan-native/vk17-two-slots.md) | [`vk17-two-slots.log`](#vk17-two-slotslog) | pass | 9 examples, 0 failures |
| `vk19-capture` | [`vk19-capture.md`](macos-vk17/evidence/test.vulkan-native/vk19-capture.md) | [`vk19-capture.log`](#vk19-capturelog) | pass | 6 examples, 0 failures |
| `vk2-compatibility` | [`vk2-compatibility.md`](macos-vk17/evidence/test.vulkan-native/vk2-compatibility.md) | [`vk2-compatibility.log`](#vk2-compatibilitylog) | pass | 74 examples, 0 failures |
| `vk5-bridge` | [`vk5-bridge.md`](macos-vk17/evidence/test.vulkan-native/vk5-bridge.md) | [`vk5-bridge.log`](#vk5-bridgelog) | pass | 10 examples, 0 failures, 1 pending |
| `vk6-capture` | [`vk6-capture.md`](macos-vk17/evidence/test.vulkan-native/vk6-capture.md) | [`vk6-capture.log`](#vk6-capturelog) | pass | 9 examples, 0 failures |
| `vk7-roots` | [`vk7-roots.md`](macos-vk17/evidence/test.vulkan-native/vk7-roots.md) | [`vk7-roots.log`](#vk7-rootslog) | pass | 10 examples, 0 failures |

### The `vk2-compatibility` record's environment

- source digest: 50d8706ca775e9da0d04ee3f325ad5c9dc76fe58bddbb259768872f34ad80aff
- repository revision: fc8bfe056de14cd2bde19df6856a40091610f2be
- platform: darwin/aarch64
- session authorization: the desktop opt-in on this run's command, under the owner's standing approval
- VK_DRIVER_FILES: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/aef5e084-a407-4541-a19a-f920334be7c1/scratchpad/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
- VK_LAYER_PATH: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/aef5e084-a407-4541-a19a-f920334be7c1/scratchpad/native/glfw/vulkan/share/vulkan/explicit_layer.d
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
  "duration_seconds": 5.334,
  "ended_at": "2026-09-29T03:55:21.428Z",
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
    "evidence/test.vulkan-native/vk16-composed.log",
    "evidence/test.vulkan-native/vk16-composed.md",
    "evidence/test.vulkan-native/vk17-one-slot.log",
    "evidence/test.vulkan-native/vk17-one-slot.md",
    "evidence/test.vulkan-native/vk17-two-slots.log",
    "evidence/test.vulkan-native/vk17-two-slots.md",
    "evidence/test.vulkan-native/vk19-capture.log",
    "evidence/test.vulkan-native/vk19-capture.md",
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
  "executed_commit": "fc8bfe056de14cd2bde19df6856a40091610f2be",
  "executed_tree": "05a3b4a2282131ae38f02cfc22f971611627362e",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "fc8bfe056de14cd2bde19df6856a40091610f2be",
  "input_identity": "14437135361f5af3a16294a4c7a94cb2023b0bdc5f21ef9538aa20fed8685682",
  "outcome": "passed",
  "plan_identity": "627cec41a6364e55853052c3c93fc3a56f54230d2168f1e9b14d8311bb1caccb",
  "policy_version": "54ac79a5eca2043eb5bb0136a98161b3bffe994541177066a9f80ddaeb94a0f4",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests",
      "hetoimasia-sample-triangle-app:exe:hetoimasia-triangle"
    ],
    "duration_seconds": 1.844,
    "ended_at": "2026-09-29T03:55:16.094Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-29T03:55:14.250Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-29T03:55:16.094Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "47f599dd2238423690222400880aee4929cf4c5f1b92e67ff3144a8ec82083da",
    "vulkan": "4d532cbe71e8ce89e0b697b5fbc359b449f2844259f7b31b9ec8d94a5c7b8eb8",
    "vulkan-driver": "MoltenVK 1.4.0 05df2d2145b9",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 e0705834c1a0"
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
  "duration_seconds": 10.113,
  "ended_at": "2026-09-29T03:55:13.790Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "fc8bfe056de14cd2bde19df6856a40091610f2be",
  "executed_tree": "05a3b4a2282131ae38f02cfc22f971611627362e",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "fc8bfe056de14cd2bde19df6856a40091610f2be",
  "input_identity": "14437135361f5af3a16294a4c7a94cb2023b0bdc5f21ef9538aa20fed8685682",
  "outcome": "passed",
  "plan_identity": "627cec41a6364e55853052c3c93fc3a56f54230d2168f1e9b14d8311bb1caccb",
  "policy_version": "54ac79a5eca2043eb5bb0136a98161b3bffe994541177066a9f80ddaeb94a0f4",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-29T03:55:03.677Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "47f599dd2238423690222400880aee4929cf4c5f1b92e67ff3144a8ec82083da",
    "vulkan": "4d532cbe71e8ce89e0b697b5fbc359b449f2844259f7b31b9ec8d94a5c7b8eb8",
    "vulkan-driver": "MoltenVK 1.4.0 05df2d2145b9",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 e0705834c1a0"
  },
  "worker": "local"
}
```

### The per-scenario logs

#### `debug-names.log`

```

#250 names and labels
  established every step of its private roots, its generation and its managed resources, on a device that offers naming [✔]
  recorded the batch inside its labels, and the report left it sealed and discardable [✔]
  received the provoked report while the overrunning copy was recorded, and no error from any other step [✔]
  carried the readback buffer, with the name the backend gave it, among the report's objects [✔]
  carried the enclosing batch's label among the report's command-buffer labels, wherever the layer reports any [✔]
  lost nothing, and failed its verdict after the last teardown callback for the latched error alone [✔]

Finished in 0.0005 seconds
6 examples, 0 failures
vulkan-native-tests debug-names: every check passed
```

#### `synchronization-hazard.log`

```

Synchronization validation's negative control
  established every step of its private roots [✔]
  reported the deliberate write-after-write hazard from inside the second write [✔]
  reported no error but the hazard it provoked, from no other step [✔]
  completed its capture: every report admitted and delivered, and its worker finished [✔]
  failed its verdict, after its last teardown callback, for the latched error and nothing else [✔]

Finished in 0.0006 seconds
5 examples, 0 failures
vulkan-native-tests synchronization-hazard: every check passed
```

#### `vk11-recording.log`

```

VK-11 managed recording
  established every step of its private roots, its generation and its managed resources [✔]
  recorded one sealed batch of eleven commands against the generation's image, inside the batch's and the pass's labels [✔]
  held every managed resource the batch referenced, and no longer once the discard invalidated it [✔]
  exposed no readback bytes, since nothing was submitted [✔]
  constructed, released and destroyed every managed resource [✔]
  received no validation error during any step [✔]
  completed its capture, and its verdict after the last teardown callback is clean [✔]

Finished in 0.0004 seconds
7 examples, 0 failures
vulkan-native-tests vk11-recording: every check passed
```

#### `vk12-frames.log`

```

VK-12 frames
  established every step of its private roots, its generation, its resources and its frames [✔]
  exposed the copied bytes only once the submission's fence signalled, and they are not the sentinel [✔]
  returned the rendered, never-presented image only after its rendering and its render-finished semaphore's cleanup completed [✔]
  skipped acquired frames through cleanup submissions and releases, and acquired a returned image again without rebuilding the swapchain [✔]
  held nothing unsettled before its retirement [✔]
  received no validation error during any step [✔]
  completed its capture, and its verdict after the last teardown callback is clean [✔]

Finished in 0.0005 seconds
7 examples, 0 failures
vulkan-native-tests vk12-frames: every check passed
```

#### `vk13-presentation.log`

```

VK-13 presentation
  established every step of its private roots, its two windows' generations, its resources and its frames [✔]
  presented every frame with its present fence reset immediately before, and observed every presentation's retirement through that fence [✔]
  retired the resized window's old generation only once its presentation's present fence had been observed [✔]
  closed the first window, withholding its retirement until its evidence arrived, while the second kept presenting on the shared device [✔]
  held nothing unsettled before the session's retirement, every fence observed [✔]
  received no validation error during any step [✔]
  completed its capture, and its verdict after the last teardown callback is clean [✔]

Finished in 0.0005 seconds
7 examples, 0 failures
vulkan-native-tests vk13-presentation: every check passed
```

#### `vk14-recovery.log`

```

VK-14 recovery
  established every step of its private roots, its two windows' generations, its resources and its frames [✔]
  gave the lost acquisition's reservation back, and replaced the surface on the same window and target, as one attempt of its episode [✔]
  destroyed the lost surface's generation, then the lost surface, and only then checked the replacement against the one device and built a fresh generation on it [✔]
  kept the second window presenting throughout, and presented on the first window's new generation [✔]
  recovered an allocation that ran out of memory by reclaiming the retired generation once and making the creation once more [✔]
  held nothing unsettled before the session's retirement, every fence observed [✔]
  received no validation error during any step [✔]
  completed its capture, and its verdict after the last teardown callback is clean [✔]

Finished in 0.0007 seconds
8 examples, 0 failures
vulkan-native-tests vk14-recovery: every check passed
```

#### `vk15-retention.log`

```

VK-15 retention
  held a CPU use of the target's active generation, which nothing certified as ended [✔]
  reported the generation and every parent above it as retained, without calling that a failure [✔]
  destroyed nothing the held generation depends on: not its swapchain, the surface, the device, the messenger or the instance [✔]
  ended the owner's run without destruction evidence or the target's terminal record, so the host still holds the window and every parent [✔]

Finished in 0.0001 seconds
4 examples, 0 failures
vulkan-native-tests vk15-retention: every check passed
```

#### `vk15-validation-stop.log`

```

VK-15 validation stop
  established its private roots, its window's generation, its resources and its frames, and rendered before the error [✔]
  refused the interrupted frame's presentation and a further acquisition at the next checkpoint, naming the injected error [✔]
  made the error the session's primary failure, with no device loss, and tore down under the ordinary rules with every obligation settled [✔]
  received exactly one error, the injected one, and no other in any step [✔]
  counted the final callbacks in a verdict whose only issue is the injected error [✔]

Finished in 0.0005 seconds
5 examples, 0 failures
vulkan-native-tests vk15-validation-stop: every check passed
```

#### `vk16-composed.log`

```

VK-16 composed loop
  rendered both targets through the adapter's publications, with nothing published by hand [✔]
  suspended the hidden window's target while the other kept presenting, and presented to it none [✔]
  presented to the first target again once its window was shown [✔]
  made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread [✔]
  observed every presentation's retirement through its present fence, and retired both targets and the roots in dependency order [✔]
  reached a verdict after the last callback with no issue and no error [✔]

Finished in 0.0006 seconds
6 examples, 0 failures
vulkan-native-tests vk16-composed: every check passed
```

#### `vk17-one-slot.log`

```

VK-17 required profile, 1 frame slot(s)
  ran with the frame budget it was given [✔]
  captured both windows, the first again at its new extent after the resize, and the second again after the first closed [✔]
  found the clear at a background point and the sample's triangle at its centroid in every captured frame, within the tolerance [✔]
  captured the resized window at the extent of the generation built after the resize, not the one before [✔]
  retired the first window's target before the second's last capture, which the second still rendered [✔]
  captured each from a frame it acquired, submitted, presented and saw retire on its own present fence [✔]
  built every generation unclipped, as a transfer source [✔]
  made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread [✔]
  reached a verdict after the last callback with no issue and no error [✔]

Finished in 0.0007 seconds
9 examples, 0 failures
vulkan-native-tests vk17-one-slot: every check passed
```

#### `vk17-two-slots.log`

```

VK-17 required profile, 2 frame slot(s)
  ran with the frame budget it was given [✔]
  captured both windows, the first again at its new extent after the resize, and the second again after the first closed [✔]
  found the clear at a background point and the sample's triangle at its centroid in every captured frame, within the tolerance [✔]
  captured the resized window at the extent of the generation built after the resize, not the one before [✔]
  retired the first window's target before the second's last capture, which the second still rendered [✔]
  captured each from a frame it acquired, submitted, presented and saw retire on its own present fence [✔]
  built every generation unclipped, as a transfer source [✔]
  made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread [✔]
  reached a verdict after the last callback with no issue and no error [✔]

Finished in 0.0007 seconds
9 examples, 0 failures
vulkan-native-tests vk17-two-slots: every check passed
```

#### `vk19-capture.log`

```

VK-19 consumer pipeline and capture
  captured a frame of each of two targets through the production host [✔]
  found the clear at a background point and the consumer's triangle at an interior point, within the tolerance [✔]
  captured each from a frame it acquired, submitted, presented and saw retire on its own present fence [✔]
  built every generation of both targets unclipped, as a transfer source [✔]
  made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread [✔]
  reached a verdict after the last callback with no issue and no error [✔]

Finished in 0.0007 seconds
6 examples, 0 failures
vulkan-native-tests vk19-capture: every check passed
```

#### `vk2-compatibility.log`

```

A whole run
  releases the same ten entries, in the same order [✔]
  retains nothing and destroys every handle in plan order [✔]
  counts the boundary as an entry that ran and not as a handle destroyed [✔]
  reports the ordinary destruction rules, not device loss [✔]
A present fence that times out
  retains that slot's present fence and presentation semaphore, the swapchain, and every parent above them [✔]
  destroys only what does not depend on the unretired present [✔]
  names the reason on each retained handle [✔]
  is not device loss, however long the wait went unsatisfied [✔]
A teardown boundary that fails without device loss
  prohibits every release whose safety the boundary was to establish [✔]
  reports the boundary failure as the reason rather than a presentation [✔]
  is not discharged by a later valid present fence [✔]
Later valid present-fence evidence
  permits ordered release once the fence signals during teardown [✔]
Device loss
  permits destruction under the specification's own rule [✔]
  is never reached by promoting a timeout to it [✔]
  is established by the boundary alone as readily as by a fence [✔]
A present rejected out-of-date or surface-lost
  counts its enqueued operations and holds the slot [✔]
  releases the slot only on the fence, never on the error result [✔]
  creates no obligation for the specified no-effect results [✔]
An exception in place of a result
  classifies a thrown Vulkan result as that result [✔]
  treats an exception carrying no result as evidence of nothing [✔]
  treats a boundary that threw as a boundary that failed [✔]
A run that stopped before the boundary was registered
  releases what it registered [✔]
  still withholds when a registered boundary reached no result at all [✔]
A recycled slot
  is not discharged by the completion of the present before it [✔]
The record a stopped run renders
  keeps the failing step and the failed verdict [✔]
  renders the retained handles, their reasons, and the disposition [✔]
  still claims nothing the run did not establish [✔]
The loaded Vulkan loader
  accepts the recorded loader [✔]
  refuses an alternate loader found ahead of it on the search path, naming both [✔]
  refuses a run whose runner named no recorded loader [✔]
  refuses an entry point attributed to no image [✔]
The native run
  established every step it started [✔]
The recorded environment
  selected the driver by an absolute manifest path rather than by default discovery [✔]
  cleared every conflicting discovery override it found [✔]
  identifies the exact sources it proved, by their content [✔]
  names a repository revision alongside it [✔]
  ran with validation actually loaded, so a clean run means something [✔]
  enabled synchronization validation through the instance's own create info [✔]
  recorded the layers the pinned path offers [✔]
One loader
  gives GLFW and the binding the same vkGetInstanceProcAddr address [✔]
  attributes that address to one image [✔]
  resolves an ordinary instance command to the same address on both sides [✔]
  records which driver was actually loaded, not which one was configured [✔]
The runtime profile
  enabled Vulkan 1.3 dynamic rendering and synchronization2 rather than assuming them [✔]
  enabled the portability subset exactly when the device advertised it [✔]
  found one queue family with both graphics and real surface presentation [✔]
  presents through a format whose usages include transfer-source capture [✔]
  enabled the selected maintenance extension with its whole dependency chain [✔]
  resolved a release entry point, and records which spelling answered [✔]
  built a swapchain with room to hold an abandoned image [✔]
Presentation completion
  observed every present fence signalled [✔]
  retires every presentation semaphore on its present fence and never on the rendering fence [✔]
  recycles the semaphore pool only on present-fence evidence [✔]
  withholds a delayed frame's slot until its present fence, not until its rendering fence [✔]
Safe abandonment
  returns an acquired, unrendered image after a tracked cleanup submission consumed its acquisition semaphore [✔]
  returns a submitted, unpresented image after its rendering completed and its semaphore was settled [✔]
  needs no swapchain rebuild for either path [✔]
  keeps making progress on the same swapchain afterwards [✔]
The capture path
  reads a known payload back through transfer-source usage [✔]
Callbacks and the FFI
  re-entered Haskell during creation, submission, and destruction [✔]
  still reached Haskell after the explicit messenger was destroyed [✔]
  found its callback storage still valid while the instance was destroyed [✔]
  ran on the threaded RTS with GLFW on the process main thread [✔]
  recorded no validation error and no failed callback [✔]
Teardown
  released everything it acquired, with nothing failing and nothing retained [✔]
  destroyed the explicit messenger after every resource it should have watched [✔]
The operation and result matrix
  covers acquisition, submission, presentation, oldSwapchain creation, and destruction [✔]
  states the device-loss destruction rule from the specification and induces no device loss [✔]
  labels every row as either a specification citation or an observation to resolve [✔]
  actually observed every result it claims to observe [✔]
The matrix's observation labels
  claims nothing for a run that stopped [✔]
  does not call a VK_SUCCESS row observed when every result was suboptimal [✔]
  does not call a release row observed when a release failed [✔]
  records the oldSwapchain failure case, which retires the old swapchain anyway [✔]

Finished in 0.0043 seconds
74 examples, 0 failures
vulkan-native-tests vk2-compatibility: every check passed
```

#### `vk5-bridge.log`

```

VK-5 loader-aware surface bridge
  established every step of its session [✔]
  made the capability from the binding's own vkGetInstanceProcAddr [✔]
  had GLFW resolve through that exact entry point while the session was live [✔]
  had GLFW and the binding resolve an instance entry point into one image [✔]
  copied the platform's required instance extensions [✔]
  created a surface for the attached window, which the binding accepted [✔]
  refused the attachment's disposal fact and the instance's release while the surface was owed [✔]
  destroyed the surface through Vulkan on another thread, and then granted both [✔]
  restored GLFW's default loader after termination [✔]
  restored GLFW's default loader after a failed initialization, where the platform can fail one [‐]
    # PENDING: GLFW 3.4's Cocoa initialization has no failure an application can provoke, and Cocoa is the only backend this platform admits

Finished in 0.0006 seconds
10 examples, 0 failures, 1 pending
vulkan-native-tests vk5-bridge: every check passed
```

#### `vk6-capture.log`

```

VK-6 validation capture
  established every step of its session [✔]
  installed a C callback from the executable's own image, and no Haskell callback [✔]
  heard instance creation through the create-info chain [✔]
  delivered a message from inside a genuine unsafe import [✔]
  latched the validation error an unsafe recording call provoked, from inside that call [✔]
  heard vkDestroyInstance after the explicit messenger was destroyed, and delivered it [✔]
  counted every delivery in its final verdict [✔]
  found no error but the one it provoked [✔]
  records the FFI configuration the toolchain pin qualified [✔]

Finished in 0.0007 seconds
9 examples, 0 failures
vulkan-native-tests vk6-capture: every check passed
```

#### `vk7-roots.log`

```

VK-7 Vulkan roots
  established every step of its session [✔]
  made no native call that raised [✔]
  created each window's surface through GLFW on the process main thread [✔]
  made every root's creation and destruction, and every surface's destruction, on the graphics owner's thread [✔]
  created the instance, then the explicit messenger, then one device against the first window's surface [✔]
  admitted both windows' targets, each required, on that one shared device [✔]
  retired the first-created window's target alone, leaving the device, the instance and the second target live [✔]
  destroyed every surface, then the device, then the explicit messenger, then the instance [✔]
  delivered every report, both messengers' teardown reports included, with the instance's destruction as the quiescence evidence [✔]
  reported no validation error [✔]

Finished in 0.0006 seconds
10 examples, 0 failures
vulkan-native-tests vk7-roots: every check passed
```
