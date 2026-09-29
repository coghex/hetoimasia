# The VK-17 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are lines
> the run printed, the records and logs the two `vk17-*` children wrote, and
> the two receipts the validation runner wrote on the Linux worker, verbatim.

This is the Linux evidence for issue #233: pull request #302's validation run
[36519341685](https://github.com/coghex/hetoimasia/actions/runs/36519341685), on the
`vulkan` worker, inside the published CI image the committed
`tools/ci-image/descriptor.json` names, with Mesa's Lavapipe
(lvp 1.4.318 9d69cae2004b) and the pinned validation layer
(`VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization`). The runner executed the integration candidate
`5697a5c410a9feba4548f55a1413b3fd2ac3abbe`, the merge of the pull request's head `2040d1d`
into its base, with the catalog's `--complete` command; input identity
`2cb159e450e418e1a2b981a0b312ce7995d466eb1dbe01686c9a6b18a9943b39`. Every group of the run passed, the floor and
`test.glfw-native` and `test.glfw-wayland` included.

`test.vulkan-native`'s preparation built the suite and the triangle sample's
executable in 39.265 s. Its watched native execution — the isolated X11 display
the command started for itself, the shared session and its roots, every example
and child, retirement, the diagnostic verdict after the last teardown callback,
and the display's own teardown — took 3.972 s against the 30-second
watchdog: one aggregate budget for the whole selection, both of VK-17's
frame-slot configurations and every inherited case together (121 examples, 0 failures, 1 pending, the
pending one the graphics-owner interaction probe, which opened no window, as no
run that does not activate it does). `test.vulkan-headless` passed too, with
`shader-tests`' 14 examples, `native-tests`' 312 and `integration-tests`'
91. The display helper's logs are in the worker's `validation-receipts-vulkan`
artifact beside each scenario's output and record. The macOS evidence is
[`macos-vk17.md`](macos-vk17.md).

VK-17's required profile ran twice on llvmpipe, each on private roots in a
child process of its own: `vk17-one-slot` with a frame budget of one slot
(0.300401873s) and `vk17-two-slots` with two (0.276880972s). Each drove the triangle sample's own
drawing through the production host with verification capture on, over two
mapped 160×120 windows that requested no focus. In each, both windows' frames
were captured; the first window was resized to 200×150 through its command port
and captured again at its new generation's 200×150 extent; and the
first-created window was closed and, once its target had retired, the second
was captured again. Every one of those eight captured frames read the clear as
(63, 63, 124, 255) at the background point and the triangle as
(243, 203, 89, 255) at its centroid — exactly the sRGB encodings of the
sample's linear colours, within the tolerance of 6 — and each came from a frame
the case saw acquired, submitted, presented and retired on its own present
fence. Every generation was an unclipped transfer source, every Vulkan call
ran on the graphics owner's thread, and both verdicts after the last teardown
callback had no issue and no error. Nothing about refresh cadence, vertical
blank or pacing is inferred from it.

## Captured evidence

### The native suite's report

```
vulkan	UNKNOWN STEP	2026-09-29T04:08:33.0195647Z vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan	UNKNOWN STEP	2026-09-29T04:08:33.0196817Z vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0497683Z 121 examples, 0 failures, 1 pending
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0775153Z vulkan-native-tests: shared session acquisitions: 1
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0776030Z vulkan-native-tests: shared session native calls: 169
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0780202Z vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0784204Z vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0785618Z vulkan-native-tests: private debug-names: ExitSuccess in 0.125684995s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0786242Z vulkan-native-tests: private synchronization-hazard: ExitSuccess in 8.6919312e-2s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0786880Z vulkan-native-tests: private vk11-recording: ExitSuccess in 0.130142381s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0787440Z vulkan-native-tests: private vk12-frames: ExitSuccess in 0.16639024s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0788037Z vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.157838428s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0788623Z vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.155308058s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0789157Z vulkan-native-tests: private vk15-retention: ExitSuccess in 0.114514084s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0789777Z vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.13713975s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0790364Z vulkan-native-tests: private vk16-composed: ExitSuccess in 0.155080545s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0791300Z vulkan-native-tests: private vk17-one-slot: ExitSuccess in 0.300401873s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0792112Z vulkan-native-tests: private vk17-two-slots: ExitSuccess in 0.276880972s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0792913Z vulkan-native-tests: private vk19-capture: ExitSuccess in 0.148798924s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0793753Z vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.141052567s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0794416Z vulkan-native-tests: private vk5-bridge: ExitSuccess in 5.3974448e-2s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0794991Z vulkan-native-tests: private vk6-capture: ExitSuccess in 8.9788298e-2s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0795498Z vulkan-native-tests: private vk7-roots: ExitSuccess in 0.129103602s
vulkan	UNKNOWN STEP	2026-09-29T04:08:36.0796116Z vulkan-native-tests: the process ran for 3.058403854s, fixtures, examples and teardown included
```

### The `vk17-one-slot` record

````markdown
# The VK-17 required profile record, one frame slot

Verdict: **pass**.

## The triangle sample in two windows, with 1 frame slot(s)

- both windows, first, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- both windows, second, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window, resized, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 200, extentHeight = 150} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the second window, after the first closed, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window was resized from SurfaceExtent {extentWidth = 160, extentHeight = 120}
- the first window's target had retired before the second's last capture: True
- generations seen (usage, clipped): [(17,False)]
- color formats the sample built pipelines for: [50]
- expected (red, green, blue, alpha) within 6: background (63,63,124,255), triangle (243,203,89,255)
- Vulkan calls: 182, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.280217377

## Transcript

```
## VK-17: the triangle sample in two windows, resized and closed, with 1 frame slot(s)
both windows, first: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
both windows, second: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
the first window, resized: captured SurfaceExtent {extentWidth = 200, extentHeight = 150} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
the second window, after the first closed: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
```
````

### The `vk17-one-slot` log

```

VK-17 required profile, 1 frame slot(s)
  ran with the frame budget it was given [[32m✔[0m]
  captured both windows, the first again at its new extent after the resize, and the second again after the first closed [[32m✔[0m]
  found the clear at a background point and the sample's triangle at its centroid in every captured frame, within the tolerance [[32m✔[0m]
  captured the resized window at the extent of the generation built after the resize, not the one before [[32m✔[0m]
  retired the first window's target before the second's last capture, which the second still rendered [[32m✔[0m]
  captured each from a frame it acquired, submitted, presented and saw retire on its own present fence [[32m✔[0m]
  built every generation unclipped, as a transfer source [[32m✔[0m]
  made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread [[32m✔[0m]
  reached a verdict after the last callback with no issue and no error [[32m✔[0m]

Finished in 0.0018 seconds
[32m9 examples, 0 failures[0m
vulkan-native-tests vk17-one-slot: every check passed
```

### The `vk17-two-slots` record

````markdown
# The VK-17 required profile record, two frame slots

Verdict: **pass**.

## The triangle sample in two windows, with 2 frame slot(s)

- both windows, first, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- both windows, second, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window, resized, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 200, extentHeight = 150} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the second window, after the first closed, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window was resized from SurfaceExtent {extentWidth = 160, extentHeight = 120}
- the first window's target had retired before the second's last capture: True
- generations seen (usage, clipped): [(17,False)]
- color formats the sample built pipelines for: [50]
- expected (red, green, blue, alpha) within 6: background (63,63,124,255), triangle (243,203,89,255)
- Vulkan calls: 191, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.256889348

## Transcript

```
## VK-17: the triangle sample in two windows, resized and closed, with 2 frame slot(s)
both windows, first: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
both windows, second: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
the first window, resized: captured SurfaceExtent {extentWidth = 200, extentHeight = 150} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
the second window, after the first closed: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
```
````

### The `vk17-two-slots` log

```

VK-17 required profile, 2 frame slot(s)
  ran with the frame budget it was given [[32m✔[0m]
  captured both windows, the first again at its new extent after the resize, and the second again after the first closed [[32m✔[0m]
  found the clear at a background point and the sample's triangle at its centroid in every captured frame, within the tolerance [[32m✔[0m]
  captured the resized window at the extent of the generation built after the resize, not the one before [[32m✔[0m]
  retired the first window's target before the second's last capture, which the second still rendered [[32m✔[0m]
  captured each from a frame it acquired, submitted, presented and saw retire on its own present fence [[32m✔[0m]
  built every generation unclipped, as a transfer source [[32m✔[0m]
  made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread [[32m✔[0m]
  reached a verdict after the last callback with no issue and no error [[32m✔[0m]

Finished in 0.0018 seconds
[32m9 examples, 0 failures[0m
vulkan-native-tests vk17-two-slots: every check passed
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
  "duration_seconds": 3.972,
  "ended_at": "2026-09-29T04:08:36.149Z",
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
    "evidence/test.vulkan-native/vk7-roots.md",
    "evidence/test.vulkan-native/x11-manager.log",
    "evidence/test.vulkan-native/x11-server.log",
    "evidence/test.vulkan-native/x11-server.txt"
  ],
  "executed": true,
  "executed_commit": "5697a5c410a9feba4548f55a1413b3fd2ac3abbe",
  "executed_tree": "1a4f8fe193cf6407540a1cd414caaafe6f6c8bbf",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "2040d1d8394790908657d15ce25269ef63552954",
  "input_identity": "2cb159e450e418e1a2b981a0b312ce7995d466eb1dbe01686c9a6b18a9943b39",
  "outcome": "passed",
  "plan_identity": "57581f380a4b6434c7f6fc8d856479cd7731097180ccd748afad666d6399e0e0",
  "policy_version": "54ac79a5eca2043eb5bb0136a98161b3bffe994541177066a9f80ddaeb94a0f4",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests",
      "hetoimasia-sample-triangle-app:exe:hetoimasia-triangle"
    ],
    "duration_seconds": 39.265,
    "ended_at": "2026-09-29T04:08:32.177Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-29T04:07:52.913Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36519341685/attempts/1",
  "started_at": "2026-09-29T04:08:32.177Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ci-image": "sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb",
    "ghc": "9.14.1",
    "glslang": "15.1.0 96ea85d4228d",
    "native-manifest": "c074c480471ad2e58ccd309f18d24da736b7c61e6cf0ce92872f5b5c15287965",
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
  "duration_seconds": 607.152,
  "ended_at": "2026-09-29T04:07:52.731Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "5697a5c410a9feba4548f55a1413b3fd2ac3abbe",
  "executed_tree": "1a4f8fe193cf6407540a1cd414caaafe6f6c8bbf",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "2040d1d8394790908657d15ce25269ef63552954",
  "input_identity": "2cb159e450e418e1a2b981a0b312ce7995d466eb1dbe01686c9a6b18a9943b39",
  "outcome": "passed",
  "plan_identity": "57581f380a4b6434c7f6fc8d856479cd7731097180ccd748afad666d6399e0e0",
  "policy_version": "54ac79a5eca2043eb5bb0136a98161b3bffe994541177066a9f80ddaeb94a0f4",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36519341685/attempts/1",
  "started_at": "2026-09-29T03:57:45.578Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ci-image": "sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb",
    "ghc": "9.14.1",
    "glslang": "15.1.0 96ea85d4228d",
    "native-manifest": "c074c480471ad2e58ccd309f18d24da736b7c61e6cf0ce92872f5b5c15287965",
    "vulkan": "0a53afbd93d705f228556e9c4bbcacd4c1e0e79b1216b2c8f68458668d384a71",
    "vulkan-driver": "lvp 1.4.318 9d69cae2004b",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization",
    "vulkan-loader": "1.3.275 e833b010f814",
    "weston": "13.0.0-4build3"
  },
  "worker": "vulkan"
}
```
