# The #250 debug names and labels record

Verdict: **pass**.

## A named readback buffer overrun inside a labelled batch

- device: Apple M3 Max
- debug-utils naming offered: True
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
- the readback buffer: 0xe7e6d0000000000f, named resource 3.1 readback buffer
- the batch's label: batch 0 target 0.1 generation 0

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 44 | 0 |
| the device and the target | 16 | 0 |
| the swapchain generation | 1 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| recording the batch, with the copy overrunning the readback buffer | 1 | 1 |
| vkResetCommandPool, discarding the batch | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generation | 0 | 0 |
| the target's surface | 0 | 0 |
| the device | 1 | 0 |
| the messenger and the instance | 3 | 0 |

- error VUID-vkCmdCopyImageToBuffer-pRegions-00183, objects [("6:0xab6f35e18",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0xe7e6d0000000000f",Just "resource 3.1 readback buffer")]
  - queue labels reported: 0, copied []
  - command-buffer labels reported: 2, copied ["batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
- records delivered: 66
- undelivered: 0
- verdict issues: [ErrorLatched]

## Transcript

```
## #250: a validation report on a named managed resource inside a labelled batch
the device Apple M3 Max offers debug-utils naming
the readback buffer 0xe7e6d0000000000f is named resource 3.1 readback buffer
recorded BatchId (TargetId 0 1) 0, labelled batch 0 target 0.1 generation 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
error VUID-vkCmdCopyImageToBuffer-pRegions-00183: objects [("6:0xab6f35e18",Just "resource 2.1 command buffer target 0.1 slot 0"),("9:0xe7e6d0000000000f",Just "resource 3.1 readback buffer")]
  queue labels reported: none, []
  command-buffer labels reported: 2, ["batch 0 target 0.1 generation 0","batch 0 target 0.1 generation 0"]
the lifetime delivered 66 records
```
