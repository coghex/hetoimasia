# The VK-14 recovery record

Verdict: **pass**.

## A lost surface replaced on its live window, and an allocation recovered

- device: Apple M3 Max
- frames presented in all: 12
- the injected acquisition answered AcquisitionPending PendingSurfaceLost
- the first window's surface 0xfab64d0000000002 was replaced by 0x980b0000000002e on the same window; its generation GenerationId (TargetId 0 1) 0 by GenerationId (TargetId 0 1) 1
- the target before and after: (TargetId 0 1,TargetId 0 1); recovery attempts spent: Just 1
- offering the replacement answered ReplacementInstalled
- the second window presented 3 frames while the first recovered
- the first window presented 3 frames on its new generation

The roots' native calls from the injection to the replacement's generation:

1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroySwapchainKHR 0xf56c9b0000000004
1. vkDestroySurfaceKHR 0xfab64d0000000002
1. vkGetPhysicalDeviceSurfaceSupportKHR 0x980b0000000002e
1. vkCreateSwapchainKHR on 0x980b0000000002e, handing nothing over

- the second window's retired generation GenerationId (TargetId 1 1) 0 was eligible for disposal before the failure: True
- it was gone once the creation returned: True; the creation answered a readback

The native calls during the readback's creation:

1. vkCreateBuffer: VK_ERROR_OUT_OF_DEVICE_MEMORY (injected)
1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroyImageView
1. vkDestroySwapchainKHR 0xec4bec000000000b
1. vkCreateBuffer

- left before retirement: ([],[],[])

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
| awaiting the first window's present fences | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| awaiting the second window's present fences | 0 | 0 |
| the injected acquisition | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| retiring the lost surface's generation and the lost surface, while the second window presents | 0 | 0 |
| the replacement surface, on the same window | 0 | 0 |
| offering the replacement | 0 | 0 |
| recording a triangle for the second window | 0 | 0 |
| vkQueueSubmit2, the second window's triangle | 0 | 0 |
| vkQueuePresentKHR, the second window | 0 | 0 |
| the replacement's generation, while the second window presents | 1 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| recording a triangle for the first window | 0 | 0 |
| vkQueueSubmit2, the first window's triangle | 0 | 0 |
| vkQueuePresentKHR, the first window | 0 | 0 |
| awaiting the first window's present fences | 0 | 0 |
| replacing the resized window's generation | 1 | 0 |
| awaiting the retired generation's presentations | 0 | 0 |
| the readback's creation, out of memory once | 0 | 0 |
| releasing the readback | 0 | 0 |
| draining both windows | 0 | 0 |
| retiring the first window's frames | 0 | 0 |
| retiring the second window's frames | 0 | 0 |
| releasing and destroying the managed resources | 0 | 0 |
| the generations of the first window | 0 | 0 |
| the surface of the first window | 0 | 0 |
| the generations of the second window | 0 | 0 |
| the surface of the second window | 0 | 0 |
| the device | 1 | 0 |
| the messenger and the instance | 3 | 0 |

- error reports: none
- records delivered: 68
- undelivered: 0
- verdict issues: []

## Transcript

```
## VK-14: a lost surface replaced on its live window, and an allocation recovered by reclamation
presented and retired three frames on each window
replaced the first window's surface 0xfab64d0000000002 with 0x980b0000000002e while the second presented 3 frames
recovered the readback's allocation: vkCreateBuffer: VK_ERROR_OUT_OF_DEVICE_MEMORY (injected); vkDestroyImageView; vkDestroyImageView; vkDestroyImageView; vkDestroySwapchainKHR 0xec4bec000000000b; vkCreateBuffer
the lifetime delivered 68 records
```
