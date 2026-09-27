# The VK-12 frames record

Verdict: **pass**.

## Frames acquired, submitted, awaited and returned without presenting

- device: Apple M3 Max
- generation: 320x240, format 50, 3 images
- rendered, never presented: FrameSlotId (TargetId 0 1) 0 1, image 0, acquired at attempt 1, settled after 2 steps
- its submission: SubmissionId 0, completed after 11 steps
- the readback before the completion: RefusedNotWritten "a batch or a submission still holds the buffer"
- the readback's first pixel after it: Right [89,89,89,255]
- every byte still the sentinel: False
- skipped: FrameSlotId (TargetId 0 1) 0 2, image 1, acquired at attempt 1, settled after 2 steps
- acquiring a returned image again, then skipped: FrameSlotId (TargetId 0 1) 0 4, image 0, acquired at attempt 1, settled after 2 steps
- images the first two frames returned: [0,1]
- swapchain constructions: 1
- left before retirement: ([],[SlotView {viewSlotTarget = TargetId 0 1, viewSlotNumber = 0, viewSlotSync = SlotSync {syncAcquire = 15909243860128104466, syncAcquireState = SemaphoreUnsignalled, syncFence = 15093167638295085075, syncFenceState = FenceSignalled, syncCleanup = 11519762544604479508, syncCleanupState = FenceSignalled}}],[])

Native calls the frames made, status queries left out:

1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [0]
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [1]
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [2]
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT: [0]
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 44 | 0 |
| the device and the target | 16 | 0 |
| the swapchain generation | 1 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool, slot 0 | 0 | 0 |
| vkCreateCommandPool, slot 1 | 0 | 0 |
| vkCreateBuffer | 0 | 0 |
| filling the readback with the sentinel | 0 | 0 |
| acquiring the rendered frame | 0 | 0 |
| recording the triangle batch | 0 | 0 |
| vkQueueSubmit2, the triangle batch | 0 | 0 |
| awaiting the submission's fence | 0 | 0 |
| closing the unpresented frame | 0 | 0 |
| settling the unpresented frame | 0 | 0 |
| acquiring the skipped frame | 0 | 0 |
| skipping the frame | 0 | 0 |
| settling the skipped frame | 0 | 0 |
| acquiring again | 0 | 0 |
| skipping the frame acquired again | 0 | 0 |
| settling the frame acquired again | 0 | 0 |
| acquiring again | 0 | 0 |
| skipping the frame acquired again | 0 | 0 |
| settling the frame acquired again | 0 | 0 |
| retiring the frames | 0 | 0 |
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
## VK-12: frames acquired, submitted, awaited and returned without presenting
the generation is 320x240 in format 50 with 3 images
submitted BatchId (TargetId 0 1) 0 as SubmissionId 0
after the completion the readback's first pixel is Right [89,89,89,255]
image 0 came back at reacquisition 2
the lifetime delivered 65 records
```
