# The VK-16 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are lines
> the run printed, the record and log the `vk16-composed` child wrote, and the
> two receipts the validation runner wrote on the Linux worker, verbatim.

This is the Linux evidence for issue #232: pull request #294's validation run
[36445937393](https://github.com/coghex/hetoimasia/actions/runs/36445937393), on the
`vulkan` worker, inside the published CI image the committed
`tools/ci-image/descriptor.json` names — the image rebuilt for the MoltenVK
1.4.2 pin, whose Linux Vulkan identity is unchanged — with Mesa's Lavapipe
(lvp 1.4.318 9d69cae2004b) and the pinned validation layer
(`VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization`). The runner executed the integration
candidate `c840fb4df356529c4832a9bf658f4970dd2ed23b`, the merge of the pull request's head
`0518ce8` into its base, with the catalog's `--complete` command; input identity
`309160a449c398187f68c8e5d4eb572440f4dcaafa5ec8cdbf37876213fb2ca1`.

`test.vulkan-native`'s preparation built the suite in 4.928 s. Its
watched native execution — the isolated X11 display the command started for
itself, the shared session and its roots, every example and child, retirement,
the diagnostic verdict after the last teardown callback, and the display's own
teardown — took 3.22 s against the 30-second watchdog,
over a non-empty selection of 118 examples, one of them pending: the
graphics-owner interaction probe, which opened no window, as no run that does
not activate it does. `test.vulkan-headless` passed too, with `native-tests`'
310 examples and `integration-tests`' 65. The display helper's logs are in the
worker's `validation-receipts-vulkan` artifact beside each scenario's output
and record. The macOS evidence is [`macos-vk16.md`](macos-vk16.md). Every group
of this run passed.

This run replaces the evidence of runs
[36442134049](https://github.com/coghex/hetoimasia/actions/runs/36442134049) at
`362f72a`,
[36435855217](https://github.com/coghex/hetoimasia/actions/runs/36435855217) at
`1950746` and
[36426404869](https://github.com/coghex/hetoimasia/actions/runs/36426404869) at
`5addd31`, which passed too, before the review rounds' later changes: a resize
coalesced from its first move with the active generation presenting meanwhile,
a retirement preparation whose frame-closing pass resumes, the MoltenVK pin, a
refused frame's retry paced at the backoff's first interval, a demand deadline
no closing target can serve kept out of the exit drain, and both parts of a
demand publication that asks now and by a later deadline kept. The pull
request's first run,
[36421750976](https://github.com/coghex/hetoimasia/actions/runs/36421750976),
passed its Vulkan groups and failed one `test.glfw` example of this pull
request's own — the exit drain's owed retirement, which the running owner had
answered before the drain began — fixed before that second run.

VK-16's native case, `vk16-composed`, ran on private roots in its own child
process on llvmpipe, over the production composition and two visible 160×120
windows driven by `runVulkanOwnerLoop`, with nothing published by hand. The
targets presented four frames each before the first window was hidden;
while its target was suspended the second presented three more and the first
none; shown again, the first presented once more; and the host exited through
D-33. All sixteen presentations had their present fences observed signalled,
every one of the 262 Vulkan calls ran on the graphics owner's thread, both
surfaces, the device, the messenger and the instance were destroyed in that
order, and the verdict after the last teardown callback had no issue and no
error.

## Captured evidence

### The native suite's report

```
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:39.4597333Z vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:39.4599715Z vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7285873Z 118 examples, 0 failures, 1 pending
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7507591Z vulkan-native-tests: shared session acquisitions: 1
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7508750Z vulkan-native-tests: shared session native calls: 169
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7515026Z vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7519317Z vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7519864Z vulkan-native-tests: private debug-names: ExitSuccess in 0.132850832s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7520426Z vulkan-native-tests: private synchronization-hazard: ExitSuccess in 9.9277542e-2s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7521022Z vulkan-native-tests: private vk11-recording: ExitSuccess in 0.13082641s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7521530Z vulkan-native-tests: private vk12-frames: ExitSuccess in 0.175117282s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7522051Z vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.153332046s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7522603Z vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.159459731s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7523157Z vulkan-native-tests: private vk15-retention: ExitSuccess in 0.119103354s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7523741Z vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.133363275s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7524286Z vulkan-native-tests: private vk16-composed: ExitSuccess in 0.157674039s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7524798Z vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.148463848s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7525710Z vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.8444723e-2s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7526209Z vulkan-native-tests: private vk6-capture: ExitSuccess in 0.102328082s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7526695Z vulkan-native-tests: private vk7-roots: ExitSuccess in 0.135869818s
vulkan	Run the groups this candidate still needs	2026-09-28T15:46:41.7527268Z vulkan-native-tests: the process ran for 2.29127969s, fixtures, examples and teardown included
```

### The `vk16-composed` record

````markdown
# The VK-16 composed loop record

Verdict: **pass**.

## Two targets through the composed loop

- frames before the first window was hidden (first, second): (4,4)
- the hidden window's target was suspended: True
- frames while it was hidden (first, second): (0,3)
- frames the first presented once shown again: 1
- presentations made: 16; retired on their present fences: 16
- Vulkan calls: 262, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.139163123

## Transcript

```
## VK-16: two targets rendered through the composed loop, one suspended and resumed while the other presents
presented 16 frames; 16 presentations retired on their present fences
```
````

### The `vk16-composed` log

```

VK-16 composed loop
  rendered both targets through the adapter's publications, with nothing published by hand [[32m✔[0m]
  suspended the hidden window's target while the other kept presenting, and presented to it none [[32m✔[0m]
  presented to the first target again once its window was shown [[32m✔[0m]
  made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread [[32m✔[0m]
  observed every presentation's retirement through its present fence, and retired both targets and the roots in dependency order [[32m✔[0m]
  reached a verdict after the last callback with no issue and no error [[32m✔[0m]

Finished in 0.0013 seconds
[32m6 examples, 0 failures[0m
vulkan-native-tests vk16-composed: every check passed
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
  "duration_seconds": 3.221,
  "ended_at": "2026-09-28T15:46:41.793Z",
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
  "executed_commit": "c840fb4df356529c4832a9bf658f4970dd2ed23b",
  "executed_tree": "9dac9a48f26caceb9e6c95ae79710cc80f948134",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "0518ce863787a8c9ad78808d082cd5c09bcbc947",
  "input_identity": "309160a449c398187f68c8e5d4eb572440f4dcaafa5ec8cdbf37876213fb2ca1",
  "outcome": "passed",
  "plan_identity": "9aabd8f4c40808a452f6bd96ba6b94c33408f8a33e00cbb759d4756f3c9f5318",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 4.928,
    "ended_at": "2026-09-28T15:46:38.572Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-28T15:46:33.644Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36445937393/attempts/1",
  "started_at": "2026-09-28T15:46:38.572Z",
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
  "duration_seconds": 14.307,
  "ended_at": "2026-09-28T15:46:33.415Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "c840fb4df356529c4832a9bf658f4970dd2ed23b",
  "executed_tree": "9dac9a48f26caceb9e6c95ae79710cc80f948134",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "0518ce863787a8c9ad78808d082cd5c09bcbc947",
  "input_identity": "309160a449c398187f68c8e5d4eb572440f4dcaafa5ec8cdbf37876213fb2ca1",
  "outcome": "passed",
  "plan_identity": "9aabd8f4c40808a452f6bd96ba6b94c33408f8a33e00cbb759d4756f3c9f5318",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36445937393/attempts/1",
  "started_at": "2026-09-28T15:46:19.109Z",
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
