# The VK-13 presentation record

Verdict: **pass**.

## Frames presented, and generations and a window retired on present fences

- device: Apple M3 Max
- format 50, first generations 320x240 and 320x240
- presented to both windows:
  - first: PresentationId (TargetId 0 1) 0, image 0, PresentationEnqueued, retired after 0 drain steps
  - first: PresentationId (TargetId 0 1) 1, image 1, PresentationEnqueued, retired after 0 drain steps
  - first: PresentationId (TargetId 0 1) 2, image 2, PresentationEnqueued, retired after 1 drain steps
  - second: PresentationId (TargetId 1 1) 3, image 0, PresentationEnqueued, retired after 0 drain steps
  - second: PresentationId (TargetId 1 1) 4, image 1, PresentationEnqueued, retired after 0 drain steps
  - second: PresentationId (TargetId 1 1) 5, image 2, PresentationEnqueued, retired after 1 drain steps
- resized the first window from 320x240 to 400x300: GenerationId (TargetId 0 1) 0 replaced by GenerationId (TargetId 0 1) 1
- the old generation, once replaced, was held by [PresentationId (TargetId 0 1) 6] through 3 more generation steps
- destroyed by the first generation step after its presentation's retirement was observed: True
- presented to the resized window:
  - first: PresentationId (TargetId 0 1) 7, image 0, PresentationEnqueued, retired after 1 drain steps
  - first: PresentationId (TargetId 0 1) 8, image 1, PresentationEnqueued, retired after 1 drain steps
- the first window's retirement was withheld 1 times; first: the frames of TargetId 0 1 are retained: frames [FrameSlotId (TargetId 0 1) 1 3], slots [0,1], presentations [PresentationId (TargetId 0 1) 9], pool records [0,1]
- the second window presented 1 frames while the first was retiring
- presented to the second window after the first's surface was destroyed:
  - second: PresentationId (TargetId 1 1) 12, image 1, PresentationEnqueued, retired after 0 drain steps
  - second: PresentationId (TargetId 1 1) 13, image 2, PresentationEnqueued, retired after 0 drain steps
  - second: PresentationId (TargetId 1 1) 14, image 0, PresentationEnqueued, retired after 1 drain steps
- drain waits: 11
- left before retirement: ([],[],[])

Native calls the frames made, status queries and drain waits left out:

1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkReleaseSwapchainImagesEXT: [0]
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkAcquireNextImageKHR: AcquiredIndex 1
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 2
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkAcquireNextImageKHR: AcquiredIndex 0
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR: PresentStatusSuccess
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence
1. vkDestroySemaphore
1. vkDestroyFence

| step | reports | errors |
| --- | --- | --- |
| the instance and its messenger | 44 | 0 |
| the target of the first window | 16 | 0 |
| the target of the second window | 0 | 0 |
| the swapchain generations | 2 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool, first slot 0 | 0 | 0 |
| vkCreateCommandPool, first slot 1 | 0 | 0 |
| vkCreateCommandPool, second slot 0 | 0 | 0 |
| vkCreateCommandPool, second slot 1 | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| replacing the resized window's generation | 1 | 0 |
| awaiting the old generation's present fence | 0 | 0 |
| destroying the old generation | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| awaiting a present fence of the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| closing the first window's frames | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| retiring the first window's frames | 0 | 0 |
| the first window's generations | 0 | 0 |
| the first window's surface | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| awaiting a present fence of the second window | 0 | 0 |
| draining the second window | 0 | 0 |
| retiring the second window's frames | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generations of the second window | 0 | 0 |
| the surface of the second window | 0 | 0 |
| the device | 1 | 0 |
| the messenger and the instance | 3 | 0 |

- error reports: none
- records delivered: 67
- undelivered: 0
- verdict issues: []

## Transcript

```
## VK-13: frames presented, generations and a window retired on present fences
presented and retired 6 frames on two windows
resized SurfaceExtent {extentWidth = 320, extentHeight = 240} to SurfaceExtent {extentWidth = 400, extentHeight = 300}; the old generation was held by [PresentationId (TargetId 0 1) 6]
closed the first window after its presentation PresentationId (TargetId 0 1) 9 and its skipped frame FrameSlotId (TargetId 0 1) 1 3 settled
the lifetime delivered 67 records
```
