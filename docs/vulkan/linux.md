# The VK-2 native Vulkan compatibility record

Verdict: **pass**.

The proof process's own command and the environment that decided which
loader, driver, and layers it used. `tools/vulkan-proof/run-proof.sh` is
what establishes this; see the README beside it for how to reproduce.

```
HETOIMASIA_NATIVE_SESSION=isolated-x11::0 \
  VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json \
  VK_LAYER_PATH=/usr/share/vulkan/explicit_layer.d \
  DISPLAY=:0 \
  vulkan-proof
```

## The environment

- repository revision: b29a49641609d995a832bd5a6e7fe6ff4fe6b9c7
- platform: linux/x86_64
- session authorization: the isolated X11 display :0
- VK_DRIVER_FILES: /usr/share/vulkan/icd.d/lvp_icd.json
- VK_LAYER_PATH: /usr/share/vulkan/explicit_layer.d
- cleared discovery overrides: none
- loader instance version: 1.3.275
- layers the pinned path offers: VK_LAYER_MESA_device_select 1.4.303, VK_LAYER_MESA_overlay 1.4.303, VK_LAYER_INTEL_nullhw 1.1.73, VK_LAYER_KHRONOS_validation 1.3.275
- layers enabled: VK_LAYER_KHRONOS_validation
- surface extensions GLFW requires: VK_KHR_surface, VK_KHR_xcb_surface

## One loader, by address and image

GLFW was handed the Haskell binding's own `vkGetInstanceProcAddr` before
`glfwInit`, so the two cannot be independently found libraries that happen to
agree. The addresses and images below are what each side actually resolves.

- the binding's vkGetInstanceProcAddr: 0x00007fcb6ca2e3d0 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkGetInstanceProcAddr
- GLFW's vkGetInstanceProcAddr: 0x00007fcb6ca2e3d0 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkGetInstanceProcAddr
- the binding's vkCreateDevice: 0x00007fcb6ca2e090 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkCreateDevice
- GLFW's vkCreateDevice: 0x00007fcb6ca2e090 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkCreateDevice
- a device-level entry point: 0x00007fcb4a3ab850 in /lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so
- device: llvmpipe (LLVM 20.1.2, 256 bits)
- device API version: 1.4.318
- driver: llvmpipe (DRIVER_ID_MESA_LLVMPIPE)
- driver info: Mesa 25.2.8-0ubuntu0.24.04.2 (LLVM 20.1.2)
- conformance version: 1.3.1.1

## The runtime profile, queried and enabled

- instance extensions enabled: VK_KHR_surface, VK_KHR_xcb_surface, VK_EXT_debug_utils, VK_KHR_get_surface_capabilities2, VK_EXT_surface_maintenance1, VK_KHR_portability_enumeration
- portability enumeration: yes
- portability subset advertised: no
- portability subset enabled: no
- dynamicRendering: supported yes, requested and accepted yes
- synchronization2: supported yes, requested and accepted yes
- queue family: 0, graphics yes, presentation yes
- surface format: FORMAT_B8G8R8A8_UNORM in COLOR_SPACE_SRGB_NONLINEAR_KHR
- usages the surface supports: TRANSFER_SRC, TRANSFER_DST, SAMPLED, STORAGE, COLOR_ATTACHMENT, INPUT_ATTACHMENT
- usages requested: TRANSFER_SRC, TRANSFER_DST, COLOR_ATTACHMENT
- transfer-source capture supported: yes
- present modes offered: PRESENT_MODE_IMMEDIATE_KHR, PRESENT_MODE_MAILBOX_KHR, PRESENT_MODE_FIFO_KHR, PRESENT_MODE_FIFO_RELAXED_KHR
- present mode used: PRESENT_MODE_FIFO_KHR
- swapchain images: 4
- maintenance variant: VK_EXT_swapchain_maintenance1
- its dependency chain: VK_KHR_swapchain (yes), VK_EXT_surface_maintenance1 (yes), VK_KHR_get_surface_capabilities2 (yes)
- swapchainMaintenance1 feature: supported yes, requested and accepted yes
- release entry points resolved: vkReleaseSwapchainImagesEXT (yes), vkReleaseSwapchainImagesKHR (no)
- device extensions enabled: VK_KHR_swapchain, VK_EXT_swapchain_maintenance1

## Presentation completion

The per-frame columns are what the driver reported. The two rows marked as
this harness's own discipline below are not: they say what the proof's loop
did, which is the behaviour under test rather than evidence about the
driver. What the driver supplied for those is the fence evidence beside them.

| frame | image | slot | acquire | render fence | present | present fence before wait | present fence | retired on |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | slot 0 | SUCCESS | yes | SUCCESS | signalled | yes | present fence |
| 1 | 1 | slot 1 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |
| 2 | 2 | slot 0 | SUCCESS | yes | SUCCESS | signalled | yes | present fence |
| 3 | 3 | slot 1 | SUCCESS | yes | SUCCESS | signalled | yes | present fence |
| 4 | 0 | slot 0 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |

- semaphore pool size: 2
- frames presented: 5
- slot reuses: slot 0 for frame 2, slot 1 for frame 3
- every reuse backed by a present fence: yes
- a rendering fence ever retired a presentation semaphore (this harness's own discipline): no
- delayed frame: 4
- its rendering completed before presentation: yes
- owner turns it was held unpresented: 3
- its slot was withheld while unpresented (this harness's own discipline): yes
- its slot was reused only after the present fence: yes

## Safe abandonment

### An acquired image that was never rendered

- image: 1
- cleanup: a tracked zero-command submission waiting on the acquisition semaphore
- its fence signalled: yes
- the semaphore was settled by: the cleanup submission's wait
- vkReleaseSwapchainImagesEXT returned: SUCCESS

### A submitted image that was never presented

- image: 2
- cleanup: the frame's own rendering submission, then a tracked zero-command submission consuming the render-finished semaphore
- its fence signalled: yes
- the semaphore was settled by: a tracked cleanup submission that waited on it
- vkReleaseSwapchainImagesEXT returned: SUCCESS

- the swapchain was rebuilt: no
- progress continued on the same swapchain afterwards: yes, frame 6 presented image 3

## Transfer-source capture

- format: FORMAT_B8G8R8A8_UNORM
- extent: 320x240
- bytes read back: 307200
- expected first pixel: [255,0,255,255]
- observed first pixel: [255,0,255,255]
- matched: yes

## Callback and FFI behaviour

| phase | naturally emitted | elicited by injection |
| --- | --- | --- |
| instance creation | 62 | 0 |
| messenger creation | 24 | 1 |
| device creation | 15 | 0 |
| submission | 0 | 1 |
| instance destruction | 2 | 0 |

- binding constrained to safe foreign calls: yes (a build-time constraint; the reentry counted above is what demonstrates it works)
- threaded RTS: yes
- GLFW calls on the process main thread: yes
- callbacks in total: 105
- callbacks after the explicit messenger was destroyed: 2
- callbacks during instance destruction: 2
- callback storage still valid while the instance was destroyed: yes
- validation errors: none

## Operation and result matrix

Rows marked *observed in this run* were produced by this run. The rest are
rare or destructive paths established from the specification and labelled as
such; no device loss was induced.

| operation | result | actual effects | ownership and retry | evidence |
| --- | --- | --- | --- | --- |
| `vkAcquireNextImageKHR` | VK_SUCCESS | An image index is returned and the semaphore or fence given to the call will be signalled. The application now owns that image. | Record, submit, present, or release it. The acquisition's signal operation exists whether or not the frame is ever rendered, so abandoning the frame must still consume it. | observed in this run |
| `vkAcquireNextImageKHR` | VK_SUBOPTIMAL_KHR | A successful acquisition with the same ownership and signal effects as VK_SUCCESS; the swapchain no longer matches the surface exactly. | Keep the image and its synchronization; never discard the index. Coalesce a replacement request and finish or safely abandon this frame first. | specification: vkAcquireNextImageKHR return codes; VK_SUBOPTIMAL_KHR is a success code |
| `vkAcquireNextImageKHR` | VK_NOT_READY or VK_TIMEOUT | No image was acquired and no semaphore or fence was signalled. Ordinary backpressure, not a failure. | Release any slot reservation and defer. No completion obligation was created, so there is nothing to wait on and nothing to release. | specification: vkAcquireNextImageKHR: with a zero or expired timeout no image is acquired and the semaphore and fence are unaffected |
| `vkAcquireNextImageKHR` | VK_ERROR_OUT_OF_DATE_KHR | No image was acquired and the semaphore and fence are unaffected. The swapchain can no longer be used for presentation. | No new acquisition obligation exists. Request a target-local replacement; every older obligation on the retiring swapchain remains the owner's. | specification: vkAcquireNextImageKHR: on VK_ERROR_OUT_OF_DATE_KHR the semaphore and fence are unaffected |
| `vkQueueSubmit2` | VK_SUCCESS | The batch is pending; its waits, command buffers, signals, and fence are all in force until it completes. | The command buffers, semaphores, and every resource they reference stay owned until the fence signals. A returned handle is not completion. | observed in this run |
| `vkQueueSubmit2` | VK_ERROR_OUT_OF_HOST_MEMORY or VK_ERROR_OUT_OF_DEVICE_MEMORY | No submission became pending: the specified no-effect case. The fence is not signalled and no semaphore state changed. | Do not mark anything pending and do not wait on the fence. The prior acquisition and recording stay owned; reclaim eligible resources once and retry at most once, otherwise retire the frame safely. | specification: Vulkan: a command that returns a run time error has no side effects unless otherwise specified; vkQueueSubmit2 out-of-memory returns leave the submission unmade |
| `vkQueuePresentKHR` | VK_SUCCESS | Presentation was enqueued for every swapchain in the call. The wait semaphores are consumed by that operation, and a present fence chained through VkSwapchainPresentFenceInfoKHR will signal when the presentation engine has finished with them. | Retire the presentation semaphore on the present fence and on nothing else. The rendering fence says only that rendering finished. | observed in this run |
| `vkQueuePresentKHR` | VK_SUBOPTIMAL_KHR | Presentation was enqueued exactly as for VK_SUCCESS; the swapchain no longer matches the surface exactly. | Preserve the enqueued operations and the per-swapchain results. Request recovery without resetting this frame's synchronization early. | specification: vkQueuePresentKHR return codes; VK_SUBOPTIMAL_KHR is a success code and presentation still occurred |
| `vkQueuePresentKHR` | VK_ERROR_OUT_OF_DATE_KHR or VK_ERROR_SURFACE_LOST_KHR | With several swapchains, some may have been presented and some not; pResults is the only per-swapchain truth. The semaphore waits that did happen still happened. | Classify per swapchain through pResults before deciding anything. Recover the affected target; do not treat one swapchain's failure as evidence about another's. | specification: vkQueuePresentKHR: pResults gives the per-swapchain result; the overall result is the worst of them |
| `vkQueuePresentKHR` | VK_ERROR_OUT_OF_HOST_MEMORY or VK_ERROR_OUT_OF_DEVICE_MEMORY | No presentation was enqueued: the specified no-effect case. No present fence was enqueued either. | Do not wait on a present fence this call did not enqueue. The image and its synchronization are still owned, and the prior rendering is still pending or complete on its own fence. | specification: Vulkan: a command that returns a run time error has no side effects unless otherwise specified |
| `vkReleaseSwapchainImagesEXT` | VK_SUCCESS | The named images return to the presentation engine without being presented; their contents become undefined and their layout becomes VK_IMAGE_LAYOUT_UNDEFINED. No swapchain is retired or rebuilt. | Legal only for images that were acquired and not presented, and only once every semaphore signalled by their acquisition has been waited on. This is the abandonment path; it is not a substitute for presentation. | observed in this run |
| `vkCreateSwapchainKHR with a non-null oldSwapchain` | VK_SUCCESS | A new swapchain exists and oldSwapchain is retired. Retired is not dead: it is not destroyed, its outstanding work is untouched, and images already acquired from it may still be presented. What it may no longer do is supply a new acquisition. | Finish the frames already in flight on the retired swapchain by presenting them; acquire nothing further from it. It also cannot be named as oldSwapchain again, because that parameter must be a non-retired swapchain. Every image, view, and synchronization object depending on it stays owned until its work completes; destroying it early is the error the retirement model exists to prevent. | specification: VUID-VkSwapchainCreateInfoKHR-oldSwapchain-01933 requires a non-retired oldSwapchain; VUID-vkAcquireNextImageKHR-swapchain-01285 forbids acquiring from a retired swapchain, and no such rule forbids presenting an image already acquired from one |
| `vkCreateSwapchainKHR with a non-null oldSwapchain` | any error | No new swapchain was created, but oldSwapchain is retired regardless. This is the documented exception to the no-side-effects rule, and it is the failure case a naive retry loses. | The retry cannot pass the now-retired swapchain as oldSwapchain, because that parameter must name a non-retired one; it passes VK_NULL_HANDLE and forgoes the handover. The retired swapchain is still the caller's to finish and destroy: present the images already acquired from it, acquire no more, and destroy it only once its work has completed. | specification: vkCreateSwapchainKHR: oldSwapchain is retired even if creation of the new swapchain fails; VUID-VkSwapchainCreateInfoKHR-oldSwapchain-01933 then excludes it from a retry |
| `vkDestroySwapchainKHR` | n/a | Destroys the swapchain and its images. Images acquired from it must not be in use, and the surface's other swapchains are unaffected. | Every outstanding acquisition, submission, and presentation that names this swapchain or its images must have completed. A present fence is the completion evidence for the presentation side; the rendering fence is not. | specification: vkDestroySwapchainKHR valid usage: all uses of presentable images acquired from the swapchain must have completed |
| `any queue or device command` | VK_ERROR_DEVICE_LOST | The device is permanently unusable. Pending work may never complete, and fences and semaphores may never be signalled. | Terminal for the whole graphics session. Waiting for completion is not an option, because the completion may never arrive. | specification: Vulkan, Lost Device: the device is lost and further commands on it fail |
| `destruction after VK_ERROR_DEVICE_LOST` | n/a | The specification permits destroying objects of a lost device without waiting for their pending work: completion is not required, because it may never happen. | This is the only rule that authorizes destroying an object whose work has not completed. It authorizes destruction, not a claim that the work finished, and it must never be used to mark an unfinished fence as signalled. | specification: Vulkan, Lost Device: objects of a lost device may be destroyed, and vkDeviceWaitIdle and fence waits may return VK_ERROR_DEVICE_LOST |

## Transcript

```
## The environment
proving repository revision b29a49641609d995a832bd5a6e7fe6ff4fe6b9c7
VK_DRIVER_FILES = /usr/share/vulkan/icd.d/lvp_icd.json
VK_LAYER_PATH = /usr/share/vulkan/explicit_layer.d
## The shared loader
the binding dispatches through 0x00007fcb6ca2e3d0 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkGetInstanceProcAddr
GLFW resolves the same name to 0x00007fcb6ca2e3d0 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkGetInstanceProcAddr
GLFW requires VK_KHR_surface, VK_KHR_xcb_surface
## The instance
the loader reports instance version 1.3.275
the binding resolves vkCreateDevice to 0x00007fcb6ca2e090 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkCreateDevice
GLFW resolves vkCreateDevice to 0x00007fcb6ca2e090 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkCreateDevice
## The window and its surface
## The device profile
llvmpipe (LLVM 20.1.2, 256 bits) advertises Vulkan 1.4.318
selected llvmpipe (LLVM 20.1.2, 256 bits), advertising Vulkan 1.4.318
the binding dispatches image release through 0x00007fcb4a3f52e0 in /lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so
## The presentation profile
presenting 4 images of FORMAT_B8G8R8A8_UNORM at Extent2D {width = 320, height = 240}
## Presentation completion
frame 0 presented image 0 and its present fence signalled
frame 1 presented image 1 and its present fence signalled
slot 0 was reused for frame 2 on its present fence
frame 2 presented image 2 and its present fence signalled
slot 1 was reused for frame 3 on its present fence
frame 3 presented image 3 and its present fence signalled
the delayed frame held a completed, unpresented image for 3 owner turns
## Safe abandonment
released unrendered image 1 after its acquisition semaphore was consumed
released rendered but unpresented image 2 after its render-finished semaphore was consumed
frame 6 presented image 3 and its present fence signalled
## Transfer-source capture
captured [255,0,255,255] through TRANSFER_SRC from the presented format
## Teardown
teardown runs after this procedure returns: child resources are destroyed while the explicit messenger still watches, then that messenger, then the instance
```
