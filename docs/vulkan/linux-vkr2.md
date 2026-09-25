# #250's Vulkan groups' Linux evidence

> **Editorial context, added when this evidence was retained.** Everything
> above the "Captured evidence" marker is written by hand; below it are the
> record the `debug-names` child wrote and the two receipts the validation
> runner wrote on the Linux worker, verbatim.

This is the Linux evidence for issue #250 (VKR-2): pull request #264's
validation run [36197357322](https://github.com/coghex/hetoimasia/actions/runs/36197357322), on the `vulkan` worker, inside the
published CI image the committed `tools/ci-image/descriptor.json` names, with
Mesa's Lavapipe and the pinned validation layer with `+synchronization`. The
runner executed the integration candidate `a28bc42a9cf1142ae5a9ad03dbcd00c1558eaca3`, the merge of the pull
request's head `d915bec6d84e5ea06d5c143de4d2474cd36c49c9` into its base, with the catalog's `--complete` command.

`test.vulkan-native`'s preparation built the suite in 26.356 s. Its watched
native execution — the isolated X11 display the command started for itself, the
shared session and its roots, every example and child, retirement, the
diagnostic verdict after the last teardown callback, and the display's own
teardown — took 2.069 s against the 30-second watchdog. The display helper's
logs and every scenario's output and record are in the worker's
`validation-receipts-vulkan` artifact. The macOS evidence is
[`macos-vkr2.md`](macos-vkr2.md).

#250's native case, `debug-names`, ran on private roots in its own child
process on llvmpipe. Over a 160×120 window's surface it built VK-11's capture
generation and managed resources and recorded VK-11's triangle and copy with the
fixture's seam moving the copy four bytes into the readback buffer. The one
validation error, `VUID-vkCmdCopyImageToBuffer-pRegions-00183`, arrived from the
recording step and no other; its objects carried the frame storage's command
buffer and the readback buffer, each with the name the backend gave it. This
layer reported no queue label and three command-buffer labels: the pass's
region first — although it had closed with the rendering before the copy —
then the enclosing batch's region twice. Which labels a layer lists, and in what
order, is the layer's; the case requires only that the batch's is among them,
and the record keeps the array as reported. The verdict after the last teardown
callback failed for the latched error alone, with every report admitted and
delivered.

## Captured evidence

Each private scenario's own examples:

| scenario | result |
| --- | --- |
| `debug-names` | 6 examples, 0 failures |
| `synchronization-hazard` | 5 examples, 0 failures |
| `vk11-recording` | 7 examples, 0 failures |
| `vk2-compatibility` | 74 examples, 0 failures |
| `vk5-bridge` | 10 examples, 0 failures |
| `vk6-capture` | 9 examples, 0 failures |
| `vk7-roots` | 10 examples, 0 failures |

### The `debug-names` record

Verdict: **pass**.

### A named readback buffer overrun inside a labelled batch

- device: llvmpipe (LLVM 20.1.2, 256 bits)
- debug-utils naming offered: True
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
- the readback buffer: 0x110000000011, named resource 3.1 readback buffer
- the batch's label: batch 0 target 0.1 generation 0

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 63 | 0 |
| the device and the target | 25 | 0 |
| the swapchain generation | 0 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| recording the batch, with the copy overrunning the readback buffer | 1 | 1 |
| vkResetCommandPool, discarding the batch | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generation | 0 | 0 |
| the target's surface | 0 | 0 |
| the device | 0 | 0 |
| the messenger and the instance | 1 | 0 |

- error VUID-vkCmdCopyImageToBuffer-pRegions-00183, objects [("6:0x43ac9640",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0x110000000011",Just "resource 3.1 readback buffer")]
  - queue labels reported: 0, copied []
  - command-buffer labels reported: 3, copied ["pass batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
- records delivered: 90
- undelivered: 0
- verdict issues: [ErrorLatched]

### Transcript

```
## #250: a validation report on a named managed resource inside a labelled batch
the device llvmpipe (LLVM 20.1.2, 256 bits) offers debug-utils naming
the readback buffer 0x110000000011 is named resource 3.1 readback buffer
recorded BatchId (TargetId 0 1) 0, labelled batch 0 target 0.1 generation 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
error VUID-vkCmdCopyImageToBuffer-pRegions-00183: objects [("6:0x43ac9640",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0x110000000011",Just "resource 3.1 readback buffer")]
  queue labels reported: none, []
  command-buffer labels reported: 3, ["pass batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
the lifetime delivered 90 records
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
  "duration_seconds": 2.069,
  "ended_at": "2026-09-25T22:36:40.395Z",
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
    "evidence/test.vulkan-native/vk7-roots.md",
    "evidence/test.vulkan-native/x11-manager.log",
    "evidence/test.vulkan-native/x11-server.log",
    "evidence/test.vulkan-native/x11-server.txt"
  ],
  "executed": true,
  "executed_commit": "a28bc42a9cf1142ae5a9ad03dbcd00c1558eaca3",
  "executed_tree": "c4446c956ff0143f1a697423b82bbc7750828b1b",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-native",
  "head_commit": "d915bec6d84e5ea06d5c143de4d2474cd36c49c9",
  "input_identity": "abd8a7df74ee2048f6dbceeef31737db7c6d4bb1e719cbd395965bb1d6ef6345",
  "outcome": "passed",
  "plan_identity": "ac300ffe7de5c134b756d24a84108b81d74311cc4e748560ae889f2ccc5f218f",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": {
    "command": [
      "bash",
      "tools/vulkan/run.sh",
      "build",
      "hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests"
    ],
    "duration_seconds": 26.356,
    "ended_at": "2026-09-25T22:36:38.325Z",
    "exit_status": 0,
    "expiry": null,
    "outcome": "passed",
    "started_at": "2026-09-25T22:36:11.970Z",
    "timeout_seconds": 3600
  },
  "runner_arch": "X64",
  "runner_class": "display",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36197357322/attempts/1",
  "started_at": "2026-09-25T22:36:38.326Z",
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
  "duration_seconds": 32.192,
  "ended_at": "2026-09-25T22:36:11.784Z",
  "evidence": [],
  "executed": true,
  "executed_commit": "a28bc42a9cf1142ae5a9ad03dbcd00c1558eaca3",
  "executed_tree": "c4446c956ff0143f1a697423b82bbc7750828b1b",
  "exit_status": 0,
  "expiry": null,
  "group": "test.vulkan-headless",
  "head_commit": "d915bec6d84e5ea06d5c143de4d2474cd36c49c9",
  "input_identity": "abd8a7df74ee2048f6dbceeef31737db7c6d4bb1e719cbd395965bb1d6ef6345",
  "outcome": "passed",
  "plan_identity": "ac300ffe7de5c134b756d24a84108b81d74311cc4e748560ae889f2ccc5f218f",
  "policy_version": "c30ee2b9af078c3312475a5290cfba008a5ccf7c9fa8c8b40dee4873892e8783",
  "preparation": null,
  "runner_arch": "X64",
  "runner_class": "cpu",
  "runner_os": "Linux",
  "runner_python": "3.12.3",
  "schema_version": 4,
  "source_run_url": "https://github.com/coghex/hetoimasia/actions/runs/36197357322/attempts/1",
  "started_at": "2026-09-25T22:35:39.592Z",
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
