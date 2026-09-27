# The VK-11 managed recording record

Verdict: **pass**.

## A recorded, discarded triangle batch

- device: Apple M3 Max
- generation: 320x240, format 50, 3 images
- batch: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
- held before the discard: [("pipeline layout",[BatchId (TargetId 0 1) 0]),("pipeline",[BatchId (TargetId 0 1) 0]),("frame storage",[BatchId (TargetId 0 1) 0]),("readback",[BatchId (TargetId 0 1) 0])]
- held after the discard: [("pipeline layout",[]),("pipeline",[]),("frame storage",[]),("readback",[])]
- the readback with nothing submitted: RefusedNotWritten "a batch or a submission still holds the buffer"
- managed resources destroyed: 4

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 44 | 0 |
| the device and the target | 16 | 0 |
| the swapchain generation | 1 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| recording the triangle batch | 0 | 0 |
| vkResetCommandPool, discarding the batch | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generation | 0 | 0 |
| the target's surface | 0 | 0 |
| the device | 1 | 0 |
| the messenger and the instance | 3 | 0 |

- error reports: none
- records delivered: 65
- undelivered: 0
- verdict issues: []

## Transcript

```
## VK-11: managed resources and a recorded, discarded triangle batch
ffi binding: vulkan-3.27
ffi binding safe-foreign-calls: on
ffi binding darwin-lib-dirs: off
ffi capture callback: hetoimasia_vulkan_capture_messenger (C) → hetoimasia_capture_callback (C)
ffi Haskell callbacks installed: none
ffi unsafe imports declared: vkBeginCommandBuffer, vkEndCommandBuffer, vkCmdPipelineBarrier2, vkCmdBeginRendering, vkCmdEndRendering, vkCmdBindPipeline, vkCmdSetViewport, vkCmdSetScissor, vkCmdDraw, vkCmdCopyImageToBuffer, vkCmdBeginDebugUtilsLabelEXT, vkCmdEndDebugUtilsLabelEXT
ffi safe calls: everything else: waits, submission, presentation, pipeline creation, construction and destruction, through the binding
the generation is 320x240 in format 50 with 3 images
recorded BatchId (TargetId 0 1) 0: Just (BatchView {viewBatch = BatchId (TargetId 0 1) 0, viewBatchFrame = FrameSlotId (TargetId 0 1) 0 1, viewBatchStanding = BatchSealed, viewBatchCommands = 15})
reading the readback with nothing submitted answered RefusedNotWritten "a batch or a submission still holds the buffer"
the lifetime delivered 65 records
```
