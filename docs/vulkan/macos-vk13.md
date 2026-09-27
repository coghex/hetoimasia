# VK-13's Vulkan groups' local evidence, macOS

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> lines the native run printed at its end, the environment section of the
> `vk2-compatibility` record, and the two receipts the validation runner
> wrote, verbatim. The per-scenario records the native receipt lists are
> retained unchanged beside this file, at the receipt's own relative paths under
> [`macos-vk13/`](macos-vk13/evidence/test.vulkan-native/); the logs it lists are
> reproduced verbatim at the end of this file, because the validation catalog
> classifies no `.log` path under `docs/` and an unclassified file would select
> every group and change the inputs these receipts identify.

This is the local macOS evidence for issue #227, VK-13's presentation and
retirement, taken as
[docs/validation.md](../validation.md#the-vulkan-groups-local-evidence)
describes: a Darwin plan, then `run.py` for `test.vulkan-headless` and — under
the owner's standing approval for desktop runs an issue needs, carried on the
command as `HETOIMASIA_NATIVE_SESSION=desktop` — `test.vulkan-native`, under
MoltenVK and Cocoa, with the catalog's `--complete` command. Both passed at
commit `ac976dd988cf4d0af7ccb6bc90006ad85ea62522`, input identity
`dbbe36cf932b5172a2e05195e35b4154fc7b72c9a34c8d0e1f6f0b98568e5782`. The plan also selected `test.workflow` and the
floor groups, which are CI's.

The native group's preparation built the suite in
11.536 s, and its watched native execution took
3.666 s against the 30-second watchdog. The receipts
record `Darwin` and the local prefix's own toolchain map — the
MoltenVK 1.4.0 6e9ec5b29689 driver, the layer
`VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization` — and no `ci-image` entry, so neither
can satisfy a Linux plan. The prefix is a private one built for this run with
`tools/native/native.py build`, because the shared prefix predates this
machine's current Command Line Tools and SDK; its `vulkan` and
`native-manifest` identities are therefore its own. Every scenario passed and
the shared session's verdict was clean.

VK-13's case, `vk13-presentation`, ran on private roots in its own child
process, over two 160×120 windows' surfaces, each with a generation of 320×240
— the framebuffer's pixels at content scale 2.0 — in `B8G8R8A8_SRGB` (format
50) with 3 images. It presented three triangle frames to each window back to
back, each through `presentFrame` with one `vkResetFences` of its pool record's
present fence immediately before one `vkQueuePresentKHR`, whose swapchain entry
answered `VK_SUCCESS`, and drained through `awaitFrames` until every
presentation's retirement had been observed through its own present fence. It
then presented a frame to the first window and resized that window to 200×150
before any progress step had asked the fence: the replacement generation,
400×300, became active while the old one, retired, was held by that one
presentation through three more generation steps, and the first generation
step after the presentation's retirement was observed destroyed it. The first
window presented twice on its new generation. It then presented to the first
window again, left a second frame of it acquired, and closed that target's
frames: the first attempt to retire them was withheld — naming the skipped
frame, the pending presentation and both pool records — while the second window
presented, and once the evidence had arrived the first window's frames,
generations and surface were destroyed, and the second window presented three
more frames on the same device. Nothing was left unsettled before the second
target, the recording and the roots retired. Fourteen presentations were made,
all enqueued with `VK_SUCCESS`; no step received a validation error, with
synchronization validation on, and the verdict after the last teardown callback
was clean. The record lists every native call the frames made, status queries
and drain waits aside.

The plan's local worker declaration is the one
[docs/validation.md](../validation.md#a-local-run-and-its-receipt) shows.

## Captured evidence

### The native suite's report

```
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
112 examples, 0 failures
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 82
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 67 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.28293s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 6.0095e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.25221s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.264268s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.357985s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.372835s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 0.174533s
vulkan-native-tests: private vk6-capture: ExitSuccess in 6.0175e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.207693s
vulkan-native-tests: the process ran for 2.715596s, fixtures, examples and teardown included
```

### The per-scenario records

Each private scenario's record and log, as the receipt's `evidence` list names
them. The records are files relative to `macos-vk13/`; the logs are the
sections below.

| scenario | record | log | verdict | examples |
| --- | --- | --- | --- | --- |
| `debug-names` | [`debug-names.md`](macos-vk13/evidence/test.vulkan-native/debug-names.md) | [`debug-names.log`](#debug-nameslog) | pass | 6 examples, 0 failures |
| `synchronization-hazard` | [`synchronization-hazard.md`](macos-vk13/evidence/test.vulkan-native/synchronization-hazard.md) | [`synchronization-hazard.log`](#synchronization-hazardlog) | pass | 5 examples, 0 failures |
| `vk11-recording` | [`vk11-recording.md`](macos-vk13/evidence/test.vulkan-native/vk11-recording.md) | [`vk11-recording.log`](#vk11-recordinglog) | pass | 7 examples, 0 failures |
| `vk12-frames` | [`vk12-frames.md`](macos-vk13/evidence/test.vulkan-native/vk12-frames.md) | [`vk12-frames.log`](#vk12-frameslog) | pass | 7 examples, 0 failures |
| `vk13-presentation` | [`vk13-presentation.md`](macos-vk13/evidence/test.vulkan-native/vk13-presentation.md) | [`vk13-presentation.log`](#vk13-presentationlog) | pass | 7 examples, 0 failures |
| `vk2-compatibility` | [`vk2-compatibility.md`](macos-vk13/evidence/test.vulkan-native/vk2-compatibility.md) | [`vk2-compatibility.log`](#vk2-compatibilitylog) | pass | 74 examples, 0 failures |
| `vk5-bridge` | [`vk5-bridge.md`](macos-vk13/evidence/test.vulkan-native/vk5-bridge.md) | [`vk5-bridge.log`](#vk5-bridgelog) | pass | 10 examples, 0 failures, 1 pending |
| `vk6-capture` | [`vk6-capture.md`](macos-vk13/evidence/test.vulkan-native/vk6-capture.md) | [`vk6-capture.log`](#vk6-capturelog) | pass | 9 examples, 0 failures |
| `vk7-roots` | [`vk7-roots.md`](macos-vk13/evidence/test.vulkan-native/vk7-roots.md) | [`vk7-roots.log`](#vk7-rootslog) | pass | 10 examples, 0 failures |

Three scenarios provoke a validation error on purpose and record it as a
latched verdict issue while their own verdict passes, as the earlier records
did: `debug-names` its one expected `VUID-vkCmdCopyImageToBuffer-pRegions-00183`
on the named command buffer and readback buffer, `synchronization-hazard` its
two unbarriered writes to one buffer, and `vk6-capture` the
`VUID-vkCmdSetViewport-viewportCount-arraylength` it sends through an unsafe
import.

### The `vk2-compatibility` record's environment

- source digest: f6d673dccb20f3509a1c3fa8527565eb6b3e12c75c17889870929ea788b3b121
- repository revision: ac976dd988cf4d0af7ccb6bc90006ad85ea62522
- platform: darwin/aarch64
- session authorization: the desktop opt-in on this run's command, under the owner's standing approval
- VK_DRIVER_FILES: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/8c033147-0de1-447f-9a53-bd9ff435ad3e/scratchpad/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
- VK_LAYER_PATH: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/8c033147-0de1-447f-9a53-bd9ff435ad3e/scratchpad/native/glfw/vulkan/share/vulkan/explicit_layer.d
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
  "duration_seconds": 3.666,
  "ended_at": "2026-09-27T17:09:22.715Z",
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
  "executed_commit": "ac976dd988cf4d0af7ccb6bc90006ad85ea62522",
  "executed_tree": "4c280f1a44b6719b4e6978880d428eb10670f1b3",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "ac976dd988cf4d0af7ccb6bc90006ad85ea62522",
  "input_identity": "dbbe36cf932b5172a2e05195e35b4154fc7b72c9a34c8d0e1f6f0b98568e5782",
  "outcome": "passed",
  "plan_identity": "e831acc6042bc7119a97b73221500570bd760d491a0a3418255ceaafb57d8a14",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 11.536,
    "ended_at": "2026-09-27T17:09:19.049Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-27T17:09:07.512Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "arm64",
  "runner_class": "display",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-27T17:09:19.049Z",
  "timeout_seconds": 30,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "751a3c401621b84e2f82b110e628b8a592c864593e350ffa5d180af6bbe53468",
    "vulkan": "5b2851d8113aae36e29e2ef1fffafc36a931411fc4c5b5cd3da7a27c39e56ac7",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 617fb8f17fc9"
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
  "duration_seconds": 19.229,
  "ended_at": "2026-09-27T17:09:01.788Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "ac976dd988cf4d0af7ccb6bc90006ad85ea62522",
  "executed_tree": "4c280f1a44b6719b4e6978880d428eb10670f1b3",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "ac976dd988cf4d0af7ccb6bc90006ad85ea62522",
  "input_identity": "dbbe36cf932b5172a2e05195e35b4154fc7b72c9a34c8d0e1f6f0b98568e5782",
  "outcome": "passed",
  "plan_identity": "e831acc6042bc7119a97b73221500570bd760d491a0a3418255ceaafb57d8a14",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": null,
  "runner_arch": "arm64",
  "runner_class": "cpu",
  "runner_os": "Darwin",
  "runner_python": "3.14.6",
  "schema_version": 4,
  "source_run_url": "",
  "started_at": "2026-09-27T17:08:42.558Z",
  "timeout_seconds": 3600,
  "toolchain": {
    "cabal": "3.18.1.0",
    "ghc": "9.14.1",
    "glslang": "15.0.0 7167bc1261b1",
    "native-manifest": "751a3c401621b84e2f82b110e628b8a592c864593e350ffa5d180af6bbe53468",
    "vulkan": "5b2851d8113aae36e29e2ef1fffafc36a931411fc4c5b5cd3da7a27c39e56ac7",
    "vulkan-driver": "MoltenVK 1.4.0 6e9ec5b29689",
    "vulkan-layers": "VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization",
    "vulkan-loader": "1.3.296 617fb8f17fc9"
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

Finished in 0.0012 seconds
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

Finished in 0.0007 seconds
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

Finished in 0.0008 seconds
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

Finished in 0.0011 seconds
7 examples, 0 failures
vulkan-native-tests vk13-presentation: every check passed
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

Finished in 0.0056 seconds
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

Finished in 0.0009 seconds
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

Finished in 0.0010 seconds
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

Finished in 0.0009 seconds
10 examples, 0 failures
vulkan-native-tests vk7-roots: every check passed
```
