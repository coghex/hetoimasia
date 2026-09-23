# The VK-4 provisioned native Vulkan compatibility record, macOS

> **Editorial context, added when this record was retained.** Everything from
> the heading down to the "Captured record" marker below is written by hand and
> is not part of the captured evidence. The harness's own output begins at that
> marker and is unedited from there; the only change made to it is that the
> heading `tools/vulkan-proof/proof/Test/Vulkan/Proof/Record.hs` printed is
> replaced by the one above, because this is not the VK-2 record.
>
> Three identities are easy to confuse here, so they are named apart. The
> `source digest` the captured record prints is the *harness* tree a run was
> produced from, not this file's commit — evidence exists before it can be
> retained, and a later prose-only edit under `tools/vulkan-proof/` moves it
> without moving anything the run depended on. What the prefix's own manifest is
> checked against is the **native recipe fingerprint**, which
> `python3 tools/native/native.py fingerprint` prints and which covers
> `glfw.pin`, `native.py`, `vulkan.pin`, `vulkan.py` and the tracked patches;
> at this head it is `831317965b69d8…`. The **image recipe fingerprint**,
> `7f7daa88204251…`, is a third thing: `tools/validation/ci_image.py` computes
> it over the whole image recipe and `tools/ci-image/descriptor.json` names it.
> It binds the published Linux image and has no bearing on this record at all:
> no image qualifies a local macOS prefix.

What makes this a separate record is what the proof consumed. VK-2 ran against
the machine's LunarG loader found by an rpath from a generated project file, and
against a driver manifest read out of a Homebrew cellar. This ran against the
prefix `tools/native/vulkan.py` provisions: the loader is a qualified copy
inside that prefix, linked by its absolute install name with no rpath and no
generated project file, and the driver and layer manifests are written into the
prefix naming their binaries absolutely. The layer path offers exactly the one
qualified layer rather than the six the SDK directory holds.

The loader is still shared by construction, and the evidence for it is stronger
here than it was: both GLFW and the binding resolve identical addresses in
`<prefix>/vulkan/lib/libvulkan.1.dylib`, which is a file this repository
provisioned rather than one the machine happened to offer.

The identities the prefix recorded for this run, which are the ones the native
manifest carries and the ones a later run has to match:

| Input | Identity |
| --- | --- |
| Loader | `1.3.296`, `37635580c32b`, from source `43e14d232fc7`, opened as `libvulkan.dylib` |
| Driver | `MoltenVK` `1.4.0`, binary `6e9ec5b29689` |
| Layer | `VK_LAYER_KHRONOS_validation` `1.3.296`, binary `dc6b9c2fd7b6` |
| Headers | `ec14c8cb2a13` |
| glslang | `15.0.0`, `7167bc1261b1` |

This record and [linux-provisioned.md](linux-provisioned.md) carry the *same*
source digest, `070531d5…`, and name the same repository revision, computed
independently — here from a Git checkout, and on Linux inside the published
image from the candidate mounted into it. As with the VK-2 pair, that is direct
evidence the two platforms proved one tree rather than two believed to match.

Earlier runs of this proof are deliberately not retained. Each review round that
changed `tools/native/` changed a recipe input, and a recipe input moves the
prefix's own identity — so each earlier record qualifies a configuration this
recipe would now refuse, which is not evidence about the delivered one. The
human approved this session separately, for this run alone, as they did each
earlier one.

## Captured record

Verdict: **pass**.

The proof process's own command and the environment that decided which
loader, driver, and layers it used. `tools/vulkan-proof/run-proof.sh` is
what establishes this; see the README beside it for how to reproduce.

```
HETOIMASIA_NATIVE_SESSION=desktop \
  VK_DRIVER_FILES=/Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json \
  VK_LAYER_PATH=/Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d \
  vulkan-proof
```

## The environment

- source digest: 070531d514cd66b41466f6a3df0b99988ba4ea7071c106c9a034dae0d23a5c3b
- repository revision: f0785c4d663fd863d362d372ee08bf643eadccde
- platform: darwin/aarch64
- session authorization: the human user's explicit approval for this one run on the local desktop
- VK_DRIVER_FILES: /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
- VK_LAYER_PATH: /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d
- cleared discovery overrides: none
- loader instance version: 1.3.296
- layers the pinned path offers: VK_LAYER_KHRONOS_validation 1.3.296
- implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
- layers requested: VK_LAYER_KHRONOS_validation
- the validation layer is in the loaded chain: yes
- surface extensions GLFW requires: VK_KHR_surface, VK_EXT_metal_surface

## One loader, by address and image

GLFW was handed the Haskell binding's own `vkGetInstanceProcAddr` before
`glfwInit`, so the two cannot be independently found libraries that happen to
agree. The addresses and images below are what each side actually resolves.

- the binding's vkGetInstanceProcAddr: 0x00000001076738f4 in /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
- GLFW's vkGetInstanceProcAddr: 0x00000001076738f4 in /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
- the binding's vkCreateDevice: 0x000000010767503c in /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib as vkCreateDevice
- GLFW's vkCreateDevice: 0x000000010767503c in /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib as vkCreateDevice
- a device-level entry point: 0x000000011e01cd78 in /usr/local/lib/libVkLayer_khronos_validation.dylib as _ZN20vulkan_layer_chassis12QueueSubmit2EP9VkQueue_TjPK13VkSubmitInfo2P9VkFence_T
- device: Apple M3 Max
- device API version: 1.3.323
- driver: MoltenVK (DRIVER_ID_MOLTENVK)
- driver info: 1.4.0
- conformance version: 1.4.2.0

## The runtime profile, queried and enabled

- instance extensions enabled: VK_KHR_surface, VK_EXT_metal_surface, VK_EXT_debug_utils, VK_KHR_get_surface_capabilities2, VK_EXT_surface_maintenance1, VK_KHR_portability_enumeration
- portability enumeration: yes
- portability subset advertised: yes
- portability subset enabled: yes
- dynamicRendering: supported yes, requested and accepted yes
- synchronization2: supported yes, requested and accepted yes
- queue family: 0, graphics yes, presentation yes
- surface format: FORMAT_B8G8R8A8_UNORM in COLOR_SPACE_SRGB_NONLINEAR_KHR
- usages the surface supports: TRANSFER_SRC, TRANSFER_DST, SAMPLED, STORAGE, COLOR_ATTACHMENT
- usages requested: TRANSFER_SRC, TRANSFER_DST, COLOR_ATTACHMENT
- transfer-source capture supported: yes
- present modes offered: PRESENT_MODE_FIFO_KHR, PRESENT_MODE_IMMEDIATE_KHR
- present mode used: PRESENT_MODE_FIFO_KHR
- swapchain images: 3
- maintenance variant: VK_EXT_swapchain_maintenance1
- its dependency chain: VK_KHR_swapchain (yes), VK_EXT_surface_maintenance1 (yes), VK_KHR_get_surface_capabilities2 (yes)
- swapchainMaintenance1 feature: supported yes, requested and accepted yes
- release entry points resolved: vkReleaseSwapchainImagesEXT (yes), vkReleaseSwapchainImagesKHR (no)
- device extensions enabled: VK_KHR_swapchain, VK_EXT_swapchain_maintenance1, VK_KHR_portability_subset

## Presentation completion

The per-frame columns are what the driver reported. The two rows marked as
this harness's own discipline below are not: they say what the proof's loop
did, which is the behaviour under test rather than evidence about the
driver. What the driver supplied for those is the fence evidence beside them.

| frame | image | slot | acquire | render fence | present | present fence before wait | present fence | retired on |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | slot 0 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |
| 1 | 1 | slot 1 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |
| 2 | 2 | slot 0 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |
| 3 | 0 | slot 1 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |
| 4 | 1 | slot 0 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |

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

- image: 2
- cleanup: a tracked zero-command submission waiting on the acquisition semaphore
- its fence signalled: yes
- the semaphore was settled by: the cleanup submission's wait
- vkReleaseSwapchainImagesEXT returned: SUCCESS

### A submitted image that was never presented

- image: 0
- cleanup: the frame's own rendering submission, then a tracked zero-command submission consuming the render-finished semaphore
- its fence signalled: yes
- the semaphore was settled by: a tracked cleanup submission that waited on it
- vkReleaseSwapchainImagesEXT returned: SUCCESS

- the swapchain was rebuilt: no
- progress continued on the same swapchain afterwards: yes, frame 6 presented image 1

## Transfer-source capture

- format: FORMAT_B8G8R8A8_UNORM
- extent: 640x480
- bytes read back: 1228800
- expected first pixel: [255,0,255,255]
- observed first pixel: [255,0,255,255]
- matched: yes

## Callback and FFI behaviour

| phase | naturally emitted | elicited by injection |
| --- | --- | --- |
| instance creation | 44 | 0 |
| messenger creation | 0 | 1 |
| device creation | 16 | 0 |
| after device creation | 1 | 0 |
| submission | 0 | 1 |
| teardown | 1 | 0 |
| instance destruction | 3 | 0 |

- binding constrained to safe foreign calls: yes (a build-time constraint; the reentry counted above is what demonstrates it works)
- threaded RTS: yes
- GLFW calls on the process main thread: yes
- callbacks in total: 67
- callbacks after the explicit messenger was destroyed: 3
- callbacks during instance destruction: 3
- callback storage still valid while the instance was destroyed: yes
- validation errors: none

## Teardown

Releases run in the reverse of the order they were registered, and one that
fails never stops the rest. Which of them run at all is decided rather than
assumed: a handle whose completion evidence is missing is retained, because
queue or device idle alone is not evidence that a presentation has retired.
The only way back from retained is the present fence itself signalling, or
the specification's device-loss rule; a retained handle is otherwise
released by process exit and by nothing else, because no native call here is
preemptible and no destroy is wrapped in a timeout. A failure fails the
verdict, and so does a retention: a session this proof could not finish
tearing down is not one it can report a clean result for.

- destruction rules in force: ordinary: each release needed its own completion evidence, and the device-idle boundary held
- released, in order: the teardown boundary, the frame slots, the swapchain, the logical device, the window surface, the proof window, the explicit debug messenger, the Vulkan instance, the callback trampoline, GLFW
- handles destroyed, in order: the command pool of slot 0, the rendering fence of slot 0, the acquisition semaphore of slot 0, the present fence of slot 0, the presentation semaphore of slot 0, the command pool of slot 1, the rendering fence of slot 1, the acquisition semaphore of slot 1, the present fence of slot 1, the presentation semaphore of slot 1, the swapchain, the logical device, the window surface, the proof window, the explicit debug messenger, the Vulkan instance, the callback trampoline, GLFW
- handles retained, and why: none
- releases that failed: none
- the effects and results this decision was taken from: vkQueuePresentKHR for slot 0 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, vkQueuePresentKHR for slot 1 returned VK_SUCCESS, a wait on the present fence of slot 1 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, vkQueuePresentKHR for slot 0 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, a wait on the present fence of slot 1 returned VK_SUCCESS, vkQueuePresentKHR for slot 1 returned VK_SUCCESS, a wait on the present fence of slot 1 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, vkQueuePresentKHR for slot 0 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, a wait on the present fence of slot 1 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, vkQueuePresentKHR for slot 0 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, vkQueuePresentKHR for slot 0 returned VK_SUCCESS, a wait on the present fence of slot 0 returned VK_SUCCESS, the teardown boundary's vkDeviceWaitIdle returned VK_SUCCESS

## Operation and result matrix

Rows marked *observed in this run* were produced by this run, and that label
is derived from what the run recorded rather than written here. The rest are
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
| `vkReleaseSwapchainImagesEXT` | VK_SUCCESS | The named images return to the presentation engine without being presented, and become acquirable again. The call is read-only with respect to them: it does not present them, does not modify their contents, does not change their layout, and does not retire or rebuild the swapchain. | Legal only for images that were acquired and not presented, and only once every semaphore signalled by their acquisition has been waited on. Contents and layout survive the release: acquiring a released image again returns it as it was, which is the one place an acquired image's contents are not simply undefined, and is why abandoning a frame this way costs nothing to redo. This is the abandonment path; it is not a substitute for presentation. | observed in this run |
| `vkCreateSwapchainKHR with a non-null oldSwapchain` | VK_SUCCESS | A new swapchain exists and oldSwapchain is retired. Retired is not dead: it is not destroyed, its outstanding work is untouched, and images already acquired from it may still be presented. What it may no longer do is supply a new acquisition. | Finish the frames already in flight on the retired swapchain by presenting them; acquire nothing further from it. It also cannot be named as oldSwapchain again, because that parameter must be a non-retired swapchain. Every image, view, and synchronization object depending on it stays owned until its work completes; destroying it early is the error the retirement model exists to prevent. | specification: VUID-VkSwapchainCreateInfoKHR-oldSwapchain-01933 requires a non-retired oldSwapchain; VUID-vkAcquireNextImageKHR-swapchain-01285 forbids acquiring from a retired swapchain, and no such rule forbids presenting an image already acquired from one |
| `vkCreateSwapchainKHR with a non-null oldSwapchain` | any error | No new swapchain was created, but oldSwapchain is retired regardless. This is the documented exception to the no-side-effects rule, and it is the failure case a naive retry loses. | A retry cannot pass the now-retired swapchain as oldSwapchain, because that parameter must name a non-retired one. Nor can it simply pass VK_NULL_HANDLE straight away: the retired swapchain still holds the native window, and creating against that surface while it lives can fail with VK_ERROR_NATIVE_WINDOW_IN_USE_KHR. The order is finish or abandon the images already acquired from it, destroy it once its work has completed, and only then create afresh with VK_NULL_HANDLE. | specification: vkCreateSwapchainKHR: oldSwapchain is retired even if creation of the new swapchain fails; VUID-VkSwapchainCreateInfoKHR-oldSwapchain-01933 then excludes it from a retry, and vkCreateSwapchainKHR may return VK_ERROR_NATIVE_WINDOW_IN_USE_KHR while the native window is still held |
| `vkDestroySwapchainKHR` | n/a | Destroys the swapchain and its images. Images acquired from it must not be in use, and the surface's other swapchains are unaffected. | Every outstanding acquisition, submission, and presentation that names this swapchain or its images must have completed. A present fence is the completion evidence for the presentation side; the rendering fence is not. | specification: vkDestroySwapchainKHR valid usage: all uses of presentable images acquired from the swapchain must have completed |
| `any queue or device command` | VK_ERROR_DEVICE_LOST | The device is permanently unusable. Pending work may never complete, and fences and semaphores may never be signalled. | Terminal for the whole graphics session. Waiting for completion is not an option, because the completion may never arrive. | specification: Vulkan, Lost Device: the device is lost and further commands on it fail |
| `destruction after VK_ERROR_DEVICE_LOST` | n/a | The specification permits destroying objects of a lost device without waiting for their pending work: completion is not required, because it may never happen. | This is the only rule that authorizes destroying an object whose work has not completed. It authorizes destruction, not a claim that the work finished, and it must never be used to mark an unfinished fence as signalled. | specification: Vulkan, Lost Device: objects of a lost device may be destroyed, and vkDeviceWaitIdle and fence waits may return VK_ERROR_DEVICE_LOST |

## Transcript

```
## The environment
implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
proving repository revision f0785c4d663fd863d362d372ee08bf643eadccde
proving source digest 070531d514cd66b41466f6a3df0b99988ba4ea7071c106c9a034dae0d23a5c3b
VK_DRIVER_FILES = /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/MoltenVK_icd.json
VK_LAYER_PATH = /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d
## The shared loader
the binding dispatches through 0x00000001076738f4 in /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
GLFW resolves the same name to 0x00000001076738f4 in /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
GLFW requires VK_KHR_surface, VK_EXT_metal_surface
## The instance
the loader reports instance version 1.3.296
the binding resolves vkCreateDevice to 0x000000010767503c in /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib as vkCreateDevice
GLFW resolves vkCreateDevice to 0x000000010767503c in /Users/vincentcoghlan/.cache/hetoimasia/native/glfw/vulkan/lib/libvulkan.1.dylib as vkCreateDevice
## The window and its surface
## The device profile
Apple M3 Max advertises Vulkan 1.3.323
selected Apple M3 Max, advertising Vulkan 1.3.323
the binding dispatches image release through 0x000000011e051b64 in /usr/local/lib/libVkLayer_khronos_validation.dylib as _ZN20vulkan_layer_chassis25ReleaseSwapchainImagesEXTEP10VkDevice_TPK31VkReleaseSwapchainImagesInfoEXT
the validation layer is in the loaded chain, by the image a device entry point resolves into
## The presentation profile
presenting 3 images of FORMAT_B8G8R8A8_UNORM at Extent2D {width = 640, height = 480}
## Presentation completion
frame 0 presented image 0 and its present fence signalled
frame 1 presented image 1 and its present fence signalled
slot 0 was reused for frame 2 on its present fence
frame 2 presented image 2 and its present fence signalled
slot 1 was reused for frame 3 on its present fence
frame 3 presented image 0 and its present fence signalled
the delayed frame held a completed, unpresented image for 3 owner turns
## Safe abandonment
released unrendered image 2 after its acquisition semaphore was consumed
released rendered but unpresented image 0 after its render-finished semaphore was consumed
frame 6 presented image 1 and its present fence signalled
## Transfer-source capture
captured [255,0,255,255] through TRANSFER_SRC from the presented format
## Teardown
teardown runs after this procedure returns: child resources are destroyed while the explicit messenger still watches, then that messenger, then the instance
```
