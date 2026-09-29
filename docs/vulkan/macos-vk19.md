# VK-19's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the environment section of the
> `vk2-compatibility` record, and the two receipts the validation runner
> wrote, verbatim. The per-scenario records the native receipt lists are
> retained unchanged beside this file, at the receipt's own relative paths under
> [`macos-vk19/`](macos-vk19/evidence/test.vulkan-native/); the logs it lists are
> reproduced verbatim at the end of this file, because the validation catalog
> classifies no `.log` path under `docs/` and an unclassified file would select
> every group and change the inputs these receipts identify.

This is the local macOS evidence for issue #299, VK-19's consumer-built
pipelines and verification capture through the Vulkan host, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: a Darwin plan, then `run.py` for `test.vulkan-headless` and — under
the owner's standing approval for desktop runs an issue needs, carried on the
command as `HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under
MoltenVK and Cocoa, with the catalog's `--complete` command. Both passed at
commit `07e2198b9390ac3f44ccd7be73ca091fc111bcd7`, input identity `4b7eca29c8af4d31d74a1c6df96e02fb9e00f358e73602ee1e9e9ad963b5b158`. The plan also selected `build.all`,
`test.engine`, `test.foundation`, `test.runtime`, `test.glfw`,
`smoke.console` and `test.workflow`, which are CI's.

The native group's preparation took 3.147 s, and its watched native execution
took 5.441 s against the 30-second watchdog; the headless group took
11.76 s, with `native-tests`' 312 examples, `shader-tests`' 14 and
`integration-tests`' 86. The receipts record `Darwin` and the local prefix's own
toolchain map — the driver `MoltenVK 1.4.0 05df2d2145b9`, which is **MoltenVK
1.4.2**'s library under a manifest that declares API 1.4.0, and the layer
`VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization` — and no `ci-image` entry, so neither can satisfy a
Linux plan. The prefix is a private one built for this run with
`tools/native/native.py build` from the current pin, since the shared one
predates the MoltenVK 1.4.2 pin; its `vulkan` and `native-manifest` identities
are therefore its own. Every scenario passed and the shared session's verdict
was clean.

VK-19's case, `vk19-capture`, ran on private roots in its own child process,
over the production composition with verification capture on and two mapped
160×120 windows that requested no focus, whose framebuffers are 320×240 on this
display. The consumer's renderer built a pipeline layout and a pipeline over the
embedded verification shaders for the frames' `B8G8R8A8_SRGB` format (50),
cleared to blue and drew one orange triangle. Each target's capture was
delivered with the whole image's 307,200 bytes: the background point read
(0, 0, 255, 255) and the triangle's centroid (255, 188, 0, 255), exactly the
sRGB encodings expected, within the tolerance of 6 on every channel; each came
from a frame the case saw acquired, submitted, presented and retired on its own
present fence. Both targets' generations were unclipped transfer sources (usage
17), all 134 Vulkan calls ran on the graphics owner's thread, and the verdict
after the last teardown callback had no issue and no error. The case took
0.26 s of the native run. Nothing about refresh cadence, vertical blank or
pacing is inferred from it.

The graphics-owner interaction probe, the suite's last example, reported
pending, as it does in every run that does not activate it.

The plan's local worker declaration is the one
[docs/validation.md](../validation.md#a-local-run-and-its-receipt) shows.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
119 examples, 0 failures, 1 pending
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 145
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 70 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.254206s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 5.2661e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.274499s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.25611s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.367444s
vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.361016s
vulkan-native-tests: private vk15-retention: ExitSuccess in 0.181075s
vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.255351s
vulkan-native-tests: private vk16-composed: ExitSuccess in 0.298214s
vulkan-native-tests: private vk19-capture: ExitSuccess in 0.264819s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.749045s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.171814s
vulkan-native-tests: private vk6-capture: ExitSuccess in 5.4721e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.214441s
vulkan-native-tests: the process ran for 4.627836s, fixtures, examples and teardown included
```

### The `vk19-capture` record's facts

- AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (0,0,255,255), triangle Just (255,188,0,255); generations (usage, clipped): [(17,False)]
- AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (0,0,255,255), triangle Just (255,188,0,255); generations (usage, clipped): [(17,False)]
- expected (red, green, blue, alpha) within 6: background (0,0,255,255), triangle (255,188,0,255)
- Vulkan calls: 134, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.238424

### The per-scenario records

Each private scenario's record and log, as the receipt's `evidence` list names
them. The records are files relative to `macos-vk19/`; the logs are the
sections below.

| scenario | record | log | verdict | examples |
| --- | --- | --- | --- | --- |
| `debug-names` | [`debug-names.md`](macos-vk19/evidence/test.vulkan-native/debug-names.md) | [`debug-names.log`](#debug-nameslog) | pass | 6 examples, 0 failures |
| `synchronization-hazard` | [`synchronization-hazard.md`](macos-vk19/evidence/test.vulkan-native/synchronization-hazard.md) | [`synchronization-hazard.log`](#synchronization-hazardlog) | pass | 5 examples, 0 failures |
| `vk11-recording` | [`vk11-recording.md`](macos-vk19/evidence/test.vulkan-native/vk11-recording.md) | [`vk11-recording.log`](#vk11-recordinglog) | pass | 7 examples, 0 failures |
| `vk12-frames` | [`vk12-frames.md`](macos-vk19/evidence/test.vulkan-native/vk12-frames.md) | [`vk12-frames.log`](#vk12-frameslog) | pass | 7 examples, 0 failures |
| `vk13-presentation` | [`vk13-presentation.md`](macos-vk19/evidence/test.vulkan-native/vk13-presentation.md) | [`vk13-presentation.log`](#vk13-presentationlog) | pass | 7 examples, 0 failures |
| `vk14-recovery` | [`vk14-recovery.md`](macos-vk19/evidence/test.vulkan-native/vk14-recovery.md) | [`vk14-recovery.log`](#vk14-recoverylog) | pass | 8 examples, 0 failures |
| `vk15-retention` | [`vk15-retention.md`](macos-vk19/evidence/test.vulkan-native/vk15-retention.md) | [`vk15-retention.log`](#vk15-retentionlog) | pass | 4 examples, 0 failures |
| `vk15-validation-stop` | [`vk15-validation-stop.md`](macos-vk19/evidence/test.vulkan-native/vk15-validation-stop.md) | [`vk15-validation-stop.log`](#vk15-validation-stoplog) | pass | 5 examples, 0 failures |
| `vk16-composed` | [`vk16-composed.md`](macos-vk19/evidence/test.vulkan-native/vk16-composed.md) | [`vk16-composed.log`](#vk16-composedlog) | pass | 6 examples, 0 failures |
| `vk19-capture` | [`vk19-capture.md`](macos-vk19/evidence/test.vulkan-native/vk19-capture.md) | [`vk19-capture.log`](#vk19-capturelog) | pass | 6 examples, 0 failures |
| `vk2-compatibility` | [`vk2-compatibility.md`](macos-vk19/evidence/test.vulkan-native/vk2-compatibility.md) | [`vk2-compatibility.log`](#vk2-compatibilitylog) | pass | 74 examples, 0 failures |
| `vk5-bridge` | [`vk5-bridge.md`](macos-vk19/evidence/test.vulkan-native/vk5-bridge.md) | [`vk5-bridge.log`](#vk5-bridgelog) | pass | 10 examples, 0 failures, 1 pending |
| `vk6-capture` | [`vk6-capture.md`](macos-vk19/evidence/test.vulkan-native/vk6-capture.md) | [`vk6-capture.log`](#vk6-capturelog) | pass | 9 examples, 0 failures |
| `vk7-roots` | [`vk7-roots.md`](macos-vk19/evidence/test.vulkan-native/vk7-roots.md) | [`vk7-roots.log`](#vk7-rootslog) | pass | 10 examples, 0 failures |

### The `vk2-compatibility` record's environment

- source digest: 74f72bd318e39d3449342cdbb658f2ae68b74ae87107a367de1b7033c6bcc202
- repository revision: 07e2198b9390ac3f44ccd7be73ca091fc111bcd7
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
  "duration_seconds": 5.441,
  "ended_at": "2026-09-29T00:46:58.559Z",
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
  "executed_commit": "07e2198b9390ac3f44ccd7be73ca091fc111bcd7",
  "executed_tree": "a29bbdd998bd1f572f4d755e1e6d58e6de54f1c4",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "07e2198b9390ac3f44ccd7be73ca091fc111bcd7",
  "input_identity": "4b7eca29c8af4d31d74a1c6df96e02fb9e00f358e73602ee1e9e9ad963b5b158",
  "outcome": "passed",
  "plan_identity": "e37708074770bae0dcc071a9a443cc73fdd7f60f3edf3785ae964c71389474d8",
  "policy_version": "e89cc58ef003645f22724085dd5b9a2acdf2242a1c5a2884f7f2d641d39ef3e6",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 3.147,
    "ended_at": "2026-09-29T00:46:53.118Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-29T00:46:49.971Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-29T00:46:53.118Z",
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
  "duration_seconds": 11.76,
  "ended_at": "2026-09-29T00:46:43.749Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "07e2198b9390ac3f44ccd7be73ca091fc111bcd7",
  "executed_tree": "a29bbdd998bd1f572f4d755e1e6d58e6de54f1c4",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "07e2198b9390ac3f44ccd7be73ca091fc111bcd7",
  "input_identity": "4b7eca29c8af4d31d74a1c6df96e02fb9e00f358e73602ee1e9e9ad963b5b158",
  "outcome": "passed",
  "plan_identity": "e37708074770bae0dcc071a9a443cc73fdd7f60f3edf3785ae964c71389474d8",
  "policy_version": "e89cc58ef003645f22724085dd5b9a2acdf2242a1c5a2884f7f2d641d39ef3e6",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-29T00:46:31.989Z",
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

Finished in 0.0004 seconds
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

Finished in 0.0005 seconds
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

Finished in 0.0005 seconds
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

Finished in 0.0006 seconds
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

Finished in 0.0007 seconds
6 examples, 0 failures
vulkan-native-tests vk16-composed: every check passed
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

Finished in 0.0008 seconds
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

Finished in 0.0038 seconds
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
