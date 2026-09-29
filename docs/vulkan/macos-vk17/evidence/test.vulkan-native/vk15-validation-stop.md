# The VK-15 validation stop record

Verdict: **pass**.

## A validation error during rendering

- device: Apple M3 Max
- frames presented and retired before the error: 2
- the interrupted frame's presentation answered: Left (RefusedSessionFailed TerminalValidationError)
- a further acquisition answered: Left (RefusedSessionFailed TerminalValidationError)
- primary failure: Just TerminalValidationError
- device loss observed: Nothing
- teardown evidence: []
- left once teardown had drained: ([],[],[])
- retirement: retiring the frames: returned; retiring the generations: returned; destroying the surface: returned; releasing and destroying the managed resources: returned

Native calls the frames made, status queries and drain waits left out:

1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR
1. vkCreateSemaphore
1. vkCreateFence
1. vkCreateFence
1. vkCreateSemaphore
1. vkCreateFence
1. vkAcquireNextImageKHR
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueuePresentKHR
1. vkAcquireNextImageKHR
1. vkResetFences
1. vkQueueSubmit2: rendering
1. vkResetFences
1. vkQueueSubmit2: cleanup
1. vkReleaseSwapchainImagesEXT
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
| the window's surface | 0 | 0 |
| the window's target | 16 | 0 |
| the swapchain generation | 1 | 0 |
| vkCreatePipelineLayout | 0 | 0 |
| vkCreateGraphicsPipelines | 0 | 0 |
| vkCreateCommandPool, slot 0 | 0 | 0 |
| vkCreateCommandPool, slot 1 | 0 | 0 |
| a triangle | 0 | 0 |
| vkQueueSubmit2, a triangle | 0 | 0 |
| vkQueuePresentKHR | 0 | 0 |
| a triangle | 0 | 0 |
| vkQueueSubmit2, a triangle | 0 | 0 |
| vkQueuePresentKHR | 0 | 0 |
| awaiting the present fences | 0 | 0 |
| the frame the error interrupts | 0 | 0 |
| vkQueueSubmit2, the frame the error interrupts | 0 | 0 |
| vkSubmitDebugUtilsMessageEXT, the injected error | 1 | 1 |
| vkQueuePresentKHR, refused at the checkpoint | 0 | 0 |
| vkAcquireNextImageKHR, refused at the checkpoint | 0 | 0 |
| closing the window's frames | 0 | 0 |
| draining the frames | 0 | 0 |
| retiring the frames | 0 | 0 |
| retiring the generations | 0 | 0 |
| destroying the surface | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the device | 1 | 0 |
| the messenger and the instance | 3 | 0 |

- error reports: VUID-hetoimasia-vk15-injected-validation-error: Vulkan diagnostic
- offered once vkDestroyInstance had returned: 66
- offered in the verdict: 66
- records delivered: 66
- undelivered: 0
- verdict issues: [ErrorLatched]

## Transcript

```
## VK-15: a validation error during rendering stops the session at its next checkpoint
presented two triangle frames and observed both present fences
injected one error-severity validation message during rendering
the checkpoint answered Left (RefusedSessionFailed TerminalValidationError); the primary is Just TerminalValidationError
the lifetime delivered 66 records
```
