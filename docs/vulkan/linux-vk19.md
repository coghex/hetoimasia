# The VK-19 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are lines
> the run printed, the record and log the `vk19-capture` child wrote, and the
> two receipts the validation runner wrote on the Linux worker, verbatim.

This is the Linux evidence for issue #299: pull request #300's validation run
[36508535495](https://github.com/coghex/hetoimasia/actions/runs/36508535495), on the
`vulkan` worker, inside the published CI image the committed
`tools/ci-image/descriptor.json` names, with Mesa's Lavapipe
(lvp 1.4.318 9d69cae2004b) and the pinned validation layer
(`VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization`). The runner executed the integration
candidate `d3693f2224d58e1d8d800f1fcbd43742afeb374a`, the merge of the pull request's head
`922e488` into its base, with the catalog's `--complete` command; input identity
`76b9c4c183a29e4fccc9e924bd6e0ce326843f40df42f84a73eeb1ae732a3aee`.

`test.vulkan-native`'s preparation built the suite in 6.082 s. Its
watched native execution — the isolated X11 display the command started for
itself, the shared session and its roots, every example and child, retirement,
the diagnostic verdict after the last teardown callback, and the display's own
teardown — took 3.171 s against the 30-second watchdog,
over a non-empty selection of 119 examples, one of them pending: the
graphics-owner interaction probe, which opened no window, as no run that does
not activate it does. `test.vulkan-headless` passed too, with `shader-tests`'
14 examples, `native-tests`' 312 and `integration-tests`' 89. The display helper's logs are in the worker's
`validation-receipts-vulkan` artifact beside each scenario's output and record.
The macOS evidence is [`macos-vk19.md`](macos-vk19.md). Every group of this run
passed. This run replaces the evidence of run [36506901050](https://github.com/coghex/hetoimasia/actions/runs/36506901050) at `dc60e54`, whose Vulkan groups passed and whose unrelated `test.foundation` failed one example, `keeps the parent alive while a cancellation delivery blocks`, which this pull request's inputs do not reach and which passed again here; and that run replaced run [36504897721](https://github.com/coghex/hetoimasia/actions/runs/36504897721) at `555681d`, which passed. They preceded the review rounds' changes: capture admission closed when a target's retirement begins, admission bounded rather than settled outcomes dropped, and a construction that raised after committing a generation raised rather than confined to its frame.

VK-19's native case, `vk19-capture`, ran on private roots in its own child
process on llvmpipe, over the production composition with verification capture
on and two mapped 160×120 windows that requested no focus. The consumer's
renderer built a pipeline layout and a pipeline over the embedded verification
shaders for the frames' `B8G8R8A8_SRGB` format (50), cleared to blue and drew
one orange triangle. Each target's capture was delivered with the whole image's
76,800 bytes: the background point read (0,0,255,255) and the triangle's
centroid (255,187,0,255) on the first target, and (0,0,255,255) and (255,187,0,255)
on the second — within the tolerance of 6 of (0, 0, 255, 255) and
(255, 188, 0, 255) — and each came from a frame the case saw acquired,
submitted, presented and retired on its own present fence. Both targets'
generations were unclipped transfer sources (usage 17), all 134 Vulkan calls
ran on the graphics owner's thread, and the verdict after the last teardown
callback had no issue and no error. Nothing about refresh cadence, vertical
blank or pacing is inferred from it.

## Captured evidence

### The native suite's report

```
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:24.3598718Z vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:24.3600052Z vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7101719Z 119 examples, 0 failures, 1 pending
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7370587Z vulkan-native-tests: shared session acquisitions: 1
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7371058Z vulkan-native-tests: shared session native calls: 169
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7373570Z vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7376175Z vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7376571Z vulkan-native-tests: private debug-names: ExitSuccess in 0.104684113s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7376983Z vulkan-native-tests: private synchronization-hazard: ExitSuccess in 7.3662375e-2s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7377391Z vulkan-native-tests: private vk11-recording: ExitSuccess in 0.104065231s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7377758Z vulkan-native-tests: private vk12-frames: ExitSuccess in 0.142137353s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7378136Z vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.135826272s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7378843Z vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.150547909s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7379218Z vulkan-native-tests: private vk15-retention: ExitSuccess in 0.101367489s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7379592Z vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.123819869s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7380105Z vulkan-native-tests: private vk16-composed: ExitSuccess in 0.124305546s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7380730Z vulkan-native-tests: private vk19-capture: ExitSuccess in 0.119882492s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7381392Z vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.189229546s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7381872Z vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.65953e-2s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7382213Z vulkan-native-tests: private vk6-capture: ExitSuccess in 7.4913568e-2s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7382551Z vulkan-native-tests: private vk7-roots: ExitSuccess in 0.103440051s
vulkan	Run the groups this candidate still needs	2026-09-29T01:36:26.7382932Z vulkan-native-tests: the process ran for 2.377630314s, fixtures, examples and teardown included
```

### The `vk19-capture` record

````markdown
# The VK-19 consumer pipeline and capture record

Verdict: **pass**.

## A consumer-built triangle captured from two targets

- AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (0,0,255,255), triangle Just (255,187,0,255); generations (usage, clipped): [(17,False)]
- AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (0,0,255,255), triangle Just (255,187,0,255); generations (usage, clipped): [(17,False)]
- expected (red, green, blue, alpha) within 6: background (0,0,255,255), triangle (255,188,0,255)
- Vulkan calls: 134, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.102075573

## Transcript

```
## VK-19: a consumer-built triangle captured from two targets through the production host
AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (0,0,255,255), triangle Just (255,187,0,255)
AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 160, extentHeight = 120} in format 50; background Just (0,0,255,255), triangle Just (255,187,0,255)
```
````

### The `vk19-capture` log

```

VK-19 consumer pipeline and capture
  captured a frame of each of two targets through the production host [[32m✔[0m]
  found the clear at a background point and the consumer's triangle at an interior point, within the tolerance [[32m✔[0m]
  captured each from a frame it acquired, submitted, presented and saw retire on its own present fence [[32m✔[0m]
  built every generation of both targets unclipped, as a transfer source [[32m✔[0m]
  made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread [[32m✔[0m]
  reached a verdict after the last callback with no issue and no error [[32m✔[0m]

Finished in 0.0018 seconds
[32m6 examples, 0 failures[0m
vulkan-native-tests vk19-capture: every check passed
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
  "duration_seconds": 3.171,
  "ended_at": "2026-09-29T01:36:26.783Z",
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
    "evidence/test.vulkan-native/vk7-roots.md",
    "evidence/test.vulkan-native/x11-manager.log",
    "evidence/test.vulkan-native/x11-server.log",
    "evidence/test.vulkan-native/x11-server.txt"
  ],
  "executed": true,
  "executed_commit": "d3693f2224d58e1d8d800f1fcbd43742afeb374a",
  "executed_tree": "9e1b1561d6013508e3c613a52d4f29154d0646d9",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "922e48821b9d86399efeb25f7dfba1b23a07df3a",
  "input_identity": "76b9c4c183a29e4fccc9e924bd6e0ce326843f40df42f84a73eeb1ae732a3aee",
  "outcome": "passed",
  "plan_identity": "c099f53911363658f08734dea1c01b95a87978263855088e70a24d5512bbaa54",
  "policy_version": "e89cc58ef003645f22724085dd5b9a2acdf2242a1c5a2884f7f2d641d39ef3e6",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 6.082,
    "ended_at": "2026-09-29T01:36:23.612Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-29T01:36:17.530Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36508535495/attempts/1",
  "started_at": "2026-09-29T01:36:23.612Z",
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
  "duration_seconds": 23.95,
  "ended_at": "2026-09-29T01:36:17.393Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "d3693f2224d58e1d8d800f1fcbd43742afeb374a",
  "executed_tree": "9e1b1561d6013508e3c613a52d4f29154d0646d9",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "922e48821b9d86399efeb25f7dfba1b23a07df3a",
  "input_identity": "76b9c4c183a29e4fccc9e924bd6e0ce326843f40df42f84a73eeb1ae732a3aee",
  "outcome": "passed",
  "plan_identity": "c099f53911363658f08734dea1c01b95a87978263855088e70a24d5512bbaa54",
  "policy_version": "e89cc58ef003645f22724085dd5b9a2acdf2242a1c5a2884f7f2d641d39ef3e6",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36508535495/attempts/1",
  "started_at": "2026-09-29T01:35:53.442Z",
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
