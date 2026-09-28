# The VK-16 Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are lines
> the run printed, the record and log the `vk16-composed` child wrote, and the
> two receipts the validation runner wrote on the Linux worker, verbatim.

This is the Linux evidence for issue #232: pull request #294's validation run
[36426404869](https://github.com/coghex/hetoimasia/actions/runs/36426404869), on the
`vulkan` worker, inside the published CI image the committed
`tools/ci-image/descriptor.json` names, with Mesa's Lavapipe
(lvp 1.4.318 9d69cae2004b) and the pinned validation layer
(`VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization`). The runner executed the integration
candidate `33bda847fdf525a84455a382e6613be2777df8e0`, the merge of the pull request's head
`5addd31` into its base, with the catalog's `--complete` command; input identity
`17e5254ba84e922f402422bfbc5fd1b6af28142121c924f55031edd86ca27788`.

`test.vulkan-native`'s preparation built the suite in 11.703 s. Its
watched native execution — the isolated X11 display the command started for
itself, the shared session and its roots, every example and child, retirement,
the diagnostic verdict after the last teardown callback, and the display's own
teardown — took 3.27 s against the 30-second watchdog,
over a non-empty selection of 118 examples, one of them pending: the
graphics-owner interaction probe, which opened no window, as no run that does
not activate it does. `test.vulkan-headless` passed too, with `native-tests`'
306 examples and `integration-tests`' 61. The display helper's logs are in the
worker's `validation-receipts-vulkan` artifact beside each scenario's output
and record. The macOS evidence is [`macos-vk16.md`](macos-vk16.md). Every group
of this run passed. The pull request's first run,
[36421750976](https://github.com/coghex/hetoimasia/actions/runs/36421750976),
passed its Vulkan groups and failed one `test.glfw` example of this pull
request's own — the exit drain's owed retirement, which the running owner had
answered before the drain began — fixed before this run.

VK-16's native case, `vk16-composed`, ran on private roots in its own child
process on llvmpipe, over the production composition and two visible 160×120
windows driven by `runVulkanOwnerLoop`, with nothing published by hand. The
targets presented four and five frames before the first window was hidden;
while its target was suspended the second presented three more and the first
none; shown again, the first presented once more; and the host exited through
D-33. All eighteen presentations had their present fences observed signalled,
every one of the 289 Vulkan calls ran on the graphics owner's thread, both
surfaces, the device, the messenger and the instance were destroyed in that
order, and the verdict after the last teardown callback had no issue and no
error.

## Captured evidence

### The native suite's report

```
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:51.7111861Z vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:51.7114024Z vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0406122Z 118 examples, 0 failures, 1 pending
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0657395Z vulkan-native-tests: shared session acquisitions: 1
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0658028Z vulkan-native-tests: shared session native calls: 169
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0663892Z vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0669250Z vulkan-native-tests: shared session verdict: clean, 90 records delivered
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0669934Z vulkan-native-tests: private debug-names: ExitSuccess in 0.127575065s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0670929Z vulkan-native-tests: private synchronization-hazard: ExitSuccess in 9.5680234e-2s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0671748Z vulkan-native-tests: private vk11-recording: ExitSuccess in 0.12809952s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0679675Z vulkan-native-tests: private vk12-frames: ExitSuccess in 0.176723134s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0680604Z vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.158971341s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0681574Z vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.155273066s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0682108Z vulkan-native-tests: private vk15-retention: ExitSuccess in 0.117914547s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0682649Z vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.136550844s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0683198Z vulkan-native-tests: private vk16-composed: ExitSuccess in 0.158685476s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0683712Z vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.143022591s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0684372Z vulkan-native-tests: private vk5-bridge: ExitSuccess in 4.7686827e-2s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0684894Z vulkan-native-tests: private vk6-capture: ExitSuccess in 9.747735e-2s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0685386Z vulkan-native-tests: private vk7-roots: ExitSuccess in 0.138172238s
vulkan	Run the groups this candidate still needs	2026-09-28T13:09:54.0685941Z vulkan-native-tests: the process ran for 2.355011451s, fixtures, examples and teardown included
```

### The `vk16-composed` record

````markdown
# The VK-16 composed loop record

Verdict: **pass**.

## Two targets through the composed loop

- frames before the first window was hidden (first, second): (4,5)
- the hidden window's target was suspended: True
- frames while it was hidden (first, second): (0,3)
- frames the first presented once shown again: 1
- presentations made: 18; retired on their present fences: 18
- Vulkan calls: 289, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.139622885

## Transcript

~~~
## VK-16: two targets rendered through the composed loop, one suspended and resumed while the other presents
presented 18 frames; 18 presentations retired on their present fences
~~~
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
  "duration_seconds": 3.273,
  "ended_at": "2026-09-28T13:09:54.117Z",
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
  "executed_commit": "33bda847fdf525a84455a382e6613be2777df8e0",
  "executed_tree": "9c69ddf6d67eeb33baf74b21a11329382e854148",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "5addd31ab2b6ea4c898c6e671308ffe0e1333525",
  "input_identity": "17e5254ba84e922f402422bfbc5fd1b6af28142121c924f55031edd86ca27788",
  "outcome": "passed",
  "plan_identity": "0737c3dbef303f6f034dea4adec5e283283e110681f3581cdcb59a25768adf17",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 11.703,
    "ended_at": "2026-09-28T13:09:50.844Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-28T13:09:39.141Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36426404869/attempts/1",
  "started_at": "2026-09-28T13:09:50.844Z",
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
  "duration_seconds": 33.626,
  "ended_at": "2026-09-28T13:09:38.924Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "33bda847fdf525a84455a382e6613be2777df8e0",
  "executed_tree": "9c69ddf6d67eeb33baf74b21a11329382e854148",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "5addd31ab2b6ea4c898c6e671308ffe0e1333525",
  "input_identity": "17e5254ba84e922f402422bfbc5fd1b6af28142121c924f55031edd86ca27788",
  "outcome": "passed",
  "plan_identity": "0737c3dbef303f6f034dea4adec5e283283e110681f3581cdcb59a25768adf17",
  "policy_version": "aad24a40fa339228b695fbdd3f5d43904e8c4ea20cb490c87d407bb31580490f",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36426404869/attempts/1",
  "started_at": "2026-09-28T13:09:05.299Z",
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
