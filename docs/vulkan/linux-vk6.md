# The VK-6 validation capture record, Linux

> **Editorial context, added when this record was retained.** Everything from
> the heading down to the "Captured record" marker below is written by hand and
> is not part of the captured evidence. The harness's own output begins at that
> marker and is unedited from there, except that the heading
> `tools/vulkan-proof/proof/Test/Vulkan/Proof/Record.hs` prints is replaced by
> the one above, because the VK-6 section is what this record is retained for.

This is the native evidence for issue #217: the same proof run as the VK-2
records, now carrying VK-6's session, whose section is headed "VK-6: C-only
validation capture" below. It ran through the `vulkan-proof` route of `.github/workflows/ci-image.yml` (run 35986903340), inside the published image the committed `tools/ci-image/descriptor.json` names, on the isolated X11 display `tools/display/x11.sh` starts and supplies its own consent for. No desktop session was entered.

It was produced from repository revision `fd3b3bdbf3b6989b9777ed30e248e4da88f71968` and source digest
`77852ba0986a0a2af5b0e47a9254fcd163ee80d1e515b5bc2a0b9c225eb54250`, the same pair the other platform's VK-6 record carries; the digest
covers the native backend package, the diagnostics package and their local
closure as well as the harness. It identifies the tree the run was produced
from, not this file's commit. The revision includes the fixes from the pull
request's first review round, so the capture proved here is the one that keeps
its header for the life of the process and counts in-flight records.

What the VK-6 section shows, on this platform:

- the only callback on that instance is the native package's C function, linked
  into the proof executable, and no Haskell callback is installed;
- instance creation reported 51 times through the `VkInstanceCreateInfo` chain;
- one message submitted through a genuine `unsafe` import of
  `vkSubmitDebugUtilsMessageEXT` arrived inside that call;
- a zero-count `vkCmdSetViewport` through a genuine `unsafe` import raised
  `VUID-vkCmdSetViewport-viewportCount-arraylength` inside that call and latched
  the error state — the one issue the verdict reports, and the only error;
- `vkDestroyInstance` reported 1 times after the explicit messenger was
  destroyed, and every one of those reports was delivered;
- the lifetime's verdict delivered all 79 reports offered, with nothing
  dropped, truncated, refused or undelivered, and a drain worker that completed.

The session ran with a 16 KiB text budget rather than the 4 KiB default. The
first macOS run at the default budget cut MoltenVK's routine report of its
supported extensions, and its verdict was rightly not clean; see
[the proof harness](../../tools/vulkan-proof/README.md#vk-6-validation-capture).

## Captured record

Verdict: **pass**.

The proof process's own command and the environment that decided which
loader, driver, and layers it used. `tools/vulkan-proof/run-proof.sh` is
what establishes this; see the README beside it for how to reproduce.

```
HETOIMASIA_NATIVE_SESSION=isolated-x11::0 \
  VK_DRIVER_FILES=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json \
  VK_LAYER_PATH=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d \
  DISPLAY=:0 \
  vulkan-proof
```

## The environment

- source digest: 77852ba0986a0a2af5b0e47a9254fcd163ee80d1e515b5bc2a0b9c225eb54250
- repository revision: fd3b3bdbf3b6989b9777ed30e248e4da88f71968
- platform: linux/x86_64
- session authorization: the isolated X11 display :0
- VK_DRIVER_FILES: /opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json
- VK_LAYER_PATH: /opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d
- cleared discovery overrides: none
- loader instance version: 1.3.275
- layers the pinned path offers: VK_LAYER_KHRONOS_validation 1.3.275
- implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
- layers requested: VK_LAYER_KHRONOS_validation
- the validation layer is in the loaded chain: yes
- surface extensions GLFW requires: VK_KHR_surface, VK_KHR_xcb_surface

## One loader, by address and image

GLFW was handed the Haskell binding's own `vkGetInstanceProcAddr` before
`glfwInit`, so the two cannot be independently found libraries that happen to
agree. The addresses and images below are what each side actually resolves.

- the binding's vkGetInstanceProcAddr: 0x00007f57d18873d0 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkGetInstanceProcAddr
- GLFW's vkGetInstanceProcAddr: 0x00007f57d18873d0 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkGetInstanceProcAddr
- the binding's vkCreateDevice: 0x00007f57d1887090 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkCreateDevice
- GLFW's vkCreateDevice: 0x00007f57d1887090 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkCreateDevice
- a device-level entry point: 0x00007f57affde850 in /usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so
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
| 2 | 2 | slot 0 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |
| 3 | 3 | slot 1 | SUCCESS | yes | SUCCESS | not ready | yes | present fence |
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
| instance creation | 51 | 0 |
| messenger creation | 12 | 1 |
| device creation | 14 | 0 |
| submission | 0 | 1 |
| instance destruction | 1 | 0 |

- binding constrained to safe foreign calls: yes (a build-time constraint; the reentry counted above is what demonstrates it works)
- threaded RTS: yes
- GLFW calls on the process main thread: yes
- callbacks in total: 80
- callbacks after the explicit messenger was destroyed: 1
- callbacks during instance destruction: 1
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

## VK-6: C-only validation capture

A second session on its own instance, with no window, whose only
debug-utils callback is the native backend package's C function handing
each report to the diagnostics package's C producer. Both messengers — the
one chained into `VkInstanceCreateInfo` and the explicit one — register it
with the capture storage as user data, and no Haskell callback is installed.
Two calls go through genuine `unsafe` imports of the instance's and device's
own dispatch pointers. Each step's reports are read off the storage's own
counters around the call, so a report counted against an unsafe call
arrived inside it.

- capture limits: 1024 queued records, 16384 bytes of text per record (the default is 4096; see the proof README), 16 objects per record
- device: llvmpipe (LLVM 20.1.2, 256 bits)
- messenger callback: 0x000000000067a230 in /candidate/dist-vulkan-proof/build/x86_64-linux/ghc-9.14.1/hetoimasia-vulkan-proof-0.1.0.0/t/vulkan-proof/opt/build/vulkan-proof/vulkan-proof
- this executable: /candidate/dist-vulkan-proof/build/x86_64-linux/ghc-9.14.1/hetoimasia-vulkan-proof-0.1.0.0/t/vulkan-proof/opt/build/vulkan-proof/vulkan-proof
- unsafe imports this session declares: vkSubmitDebugUtilsMessageEXT, vkCmdSetViewport
- binding safe-foreign-calls in binding.pin: on
- binding darwin-lib-dirs in binding.pin: off
- native package binding: vulkan-3.27
- native package binding safe-foreign-calls: on
- native package binding darwin-lib-dirs: off
- native package capture callback: hetoimasia_vulkan_capture_messenger (C) → hetoimasia_capture_callback (C)
- native package Haskell callbacks installed: none
- native package unsafe imports declared: none

- verdict issues: ErrorLatched
- error latched: yes
- capture failure latched: no
- reports offered: 79
- admitted: 79
- dropped: 0
- truncated: 0
- capture failures: 0
- error reports: 1
- delivered to the logger: 79
- undelivered: 0
- drain worker: completed

### Reports by step

| Step | Reports | Errors |
| --- | --- | --- |
| vkCreateInstance | 51 | 0 |
| vkCreateDebugUtilsMessengerEXT | 0 | 0 |
| vkSubmitDebugUtilsMessageEXT, through an unsafe import | 1 | 0 |
| vkEnumeratePhysicalDevices | 12 | 0 |
| vkCreateDevice | 13 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkAllocateCommandBuffers | 0 | 0 |
| vkBeginCommandBuffer | 0 | 0 |
| vkCmdSetViewport, through an unsafe import | 1 | 1 |
| vkEndCommandBuffer | 0 | 0 |
| vkDestroyCommandPool | 0 | 0 |
| vkDestroyDevice | 0 | 0 |
| vkDestroyDebugUtilsMessengerEXT | 0 | 0 |
| vkDestroyInstance, after the explicit messenger was destroyed | 1 | 0 |

### Delivered records

Every record the drain worker handed to the logger, in delivery order, with
the step whose reports it was.

| Step | Severity | Message id | Message |
| --- | --- | --- | --- |
| vkCreateInstance | info | Loader Message | Portability enumeration bit was set, enumerating portability drivers. |
| vkCreateInstance | info | Loader Message | Searching for implicit layer manifest files |
| vkCreateInstance | info | Loader Message |    In following locations: |
| vkCreateInstance | info | Loader Message |       /root/.config/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /etc/xdg/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /etc/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /root/.local/share/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /usr/local/share/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /usr/share/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |    Found the following files: |
| vkCreateInstance | info | Loader Message |       /usr/share/vulkan/implicit_layer.d/VkLayer_MESA_device_select.json |
| vkCreateInstance | info | Loader Message | Found manifest file /usr/share/vulkan/implicit_layer.d/VkLayer_MESA_device_select.json (file version 1.0.0) |
| vkCreateInstance | info | Loader Message | Searching for explicit layer manifest files |
| vkCreateInstance | info | Loader Message |    In following locations: |
| vkCreateInstance | info | Loader Message |       /opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d |
| vkCreateInstance | info | Loader Message |    Found the following files: |
| vkCreateInstance | info | Loader Message |       /opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d/VK_LAYER_KHRONOS_validation.json |
| vkCreateInstance | info | Loader Message | Found manifest file /opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d/VK_LAYER_KHRONOS_validation.json (file version 1.2.0) |
| vkCreateInstance | warning | Loader Message | Layer "VK_LAYER_MESA_device_select" forced disabled because name matches filter of env var 'VK_LOADER_LAYERS_DISABLE'. |
| vkCreateInstance | info | Loader Message | Searching for driver manifest files |
| vkCreateInstance | info | Loader Message |    In following locations: |
| vkCreateInstance | info | Loader Message |       /opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json |
| vkCreateInstance | info | Loader Message |    Found the following files: |
| vkCreateInstance | info | Loader Message |       /opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json |
| vkCreateInstance | info | Loader Message | Found ICD manifest file /opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json, version 1.0.0 |
| vkCreateInstance | verbose | Loader Message | Searching for ICD drivers named /usr/lib/x86_64-linux-gnu/libvulkan_lvp.so |
| vkCreateInstance | verbose | Loader Message | Loading layer library /usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so |
| vkCreateInstance | info | Loader Message | Insert instance layer "VK_LAYER_KHRONOS_validation" (/usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so) |
| vkCreateInstance | info | Loader Message | vkCreateInstance layer callstack setup to: |
| vkCreateInstance | info | Loader Message |    <Application> |
| vkCreateInstance | info | Loader Message |      \|\| |
| vkCreateInstance | info | Loader Message |    <Loader> |
| vkCreateInstance | info | Loader Message |      \|\| |
| vkCreateInstance | info | Loader Message |    VK_LAYER_KHRONOS_validation |
| vkCreateInstance | info | Loader Message |            Type: Explicit |
| vkCreateInstance | info | Loader Message |            Manifest: /opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d/VK_LAYER_KHRONOS_validation.json |
| vkCreateInstance | info | Loader Message |            Library:  /usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so |
| vkCreateInstance | info | Loader Message |      \|\| |
| vkCreateInstance | info | Loader Message |    <Drivers> |
| vkCreateInstance | info | WARNING-CreateInstance-status-message | Validation Information: [ WARNING-CreateInstance-status-message ] Object 0: handle = 0x2303ac00, type = VK_OBJECT_TYPE_INSTANCE; \| MessageID = 0x23dfd876 \| v... |
| vkCreateInstance | info | Loader Message | linux_read_sorted_physical_devices: |
| vkCreateInstance | info | Loader Message |      Original order: |
| vkCreateInstance | info | Loader Message |            [0] llvmpipe (LLVM 20.1.2, 256 bits) |
| vkCreateInstance | info | Loader Message |      Sorted order: |
| vkCreateInstance | info | Loader Message |            [0] llvmpipe (LLVM 20.1.2, 256 bits)   |
| vkCreateInstance | info | Loader Message | linux_read_sorted_physical_devices: |
| vkCreateInstance | info | Loader Message |      Original order: |
| vkCreateInstance | info | Loader Message |            [0] llvmpipe (LLVM 20.1.2, 256 bits) |
| vkCreateInstance | info | Loader Message |      Sorted order: |
| vkCreateInstance | info | Loader Message |            [0] llvmpipe (LLVM 20.1.2, 256 bits)   |
| vkCreateInstance | verbose | Loader Message | Copying old device 0 into new device 0 |
| vkSubmitDebugUtilsMessageEXT, through an unsafe import | info | hetoimasia-vulkan-proof-unsafe-submit | delivered from inside an unsafe foreign call |
| vkEnumeratePhysicalDevices | info | Loader Message | linux_read_sorted_physical_devices: |
| vkEnumeratePhysicalDevices | info | Loader Message |      Original order: |
| vkEnumeratePhysicalDevices | info | Loader Message |            [0] llvmpipe (LLVM 20.1.2, 256 bits) |
| vkEnumeratePhysicalDevices | info | Loader Message |      Sorted order: |
| vkEnumeratePhysicalDevices | info | Loader Message |            [0] llvmpipe (LLVM 20.1.2, 256 bits)   |
| vkEnumeratePhysicalDevices | verbose | Loader Message | Copying old device 0 into new device 0 |
| vkEnumeratePhysicalDevices | info | Loader Message | linux_read_sorted_physical_devices: |
| vkEnumeratePhysicalDevices | info | Loader Message |      Original order: |
| vkEnumeratePhysicalDevices | info | Loader Message |            [0] llvmpipe (LLVM 20.1.2, 256 bits) |
| vkEnumeratePhysicalDevices | info | Loader Message |      Sorted order: |
| vkEnumeratePhysicalDevices | info | Loader Message |            [0] llvmpipe (LLVM 20.1.2, 256 bits)   |
| vkEnumeratePhysicalDevices | verbose | Loader Message | Copying old device 0 into new device 0 |
| vkCreateDevice | info | Loader Message | Inserted device layer "VK_LAYER_KHRONOS_validation" (/usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so) |
| vkCreateDevice | info | Loader Message | vkCreateDevice layer callstack setup to: |
| vkCreateDevice | info | Loader Message |    <Application> |
| vkCreateDevice | info | Loader Message |      \|\| |
| vkCreateDevice | info | Loader Message |    <Loader> |
| vkCreateDevice | info | Loader Message |      \|\| |
| vkCreateDevice | info | Loader Message |    VK_LAYER_KHRONOS_validation |
| vkCreateDevice | info | Loader Message |            Type: Explicit |
| vkCreateDevice | info | Loader Message |            Manifest: /opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d/VK_LAYER_KHRONOS_validation.json |
| vkCreateDevice | info | Loader Message |            Library:  /usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so |
| vkCreateDevice | info | Loader Message |      \|\| |
| vkCreateDevice | info | Loader Message |    <Device> |
| vkCreateDevice | info | Loader Message |        Using "llvmpipe (LLVM 20.1.2, 256 bits)" with driver: "/usr/lib/x86_64-linux-gnu/libvulkan_lvp.so" |
| vkCmdSetViewport, through an unsafe import | error | VUID-vkCmdSetViewport-viewportCount-arraylength | Validation Error: [ VUID-vkCmdSetViewport-viewportCount-arraylength ] \| MessageID = 0x7a2f405c \| vkCmdSetViewport(): viewportCount must be greater than 0. Th... |
| vkDestroyInstance, after the explicit messenger was destroyed | verbose | Loader Message | Unloading layer library /usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so |

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
proving repository revision fd3b3bdbf3b6989b9777ed30e248e4da88f71968
proving source digest 77852ba0986a0a2af5b0e47a9254fcd163ee80d1e515b5bc2a0b9c225eb54250
VK_DRIVER_FILES = /opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json
VK_LAYER_PATH = /opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d
## The shared loader
the binding dispatches through 0x00007f57d18873d0 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkGetInstanceProcAddr
the binding's loader is the recorded loader /usr/lib/x86_64-linux-gnu/libvulkan.so.1.3.275
GLFW resolves the same name to 0x00007f57d18873d0 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkGetInstanceProcAddr
GLFW requires VK_KHR_surface, VK_KHR_xcb_surface
## The instance
the loader reports instance version 1.3.275
the binding resolves vkCreateDevice to 0x00007f57d1887090 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkCreateDevice
GLFW resolves vkCreateDevice to 0x00007f57d1887090 in /lib/x86_64-linux-gnu/libvulkan.so.1 as vkCreateDevice
## The window and its surface
## The device profile
llvmpipe (LLVM 20.1.2, 256 bits) advertises Vulkan 1.4.318
selected llvmpipe (LLVM 20.1.2, 256 bits), advertising Vulkan 1.4.318
the binding dispatches image release through 0x00007f57b00282e0 in /usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so
the validation layer is in the loaded chain, by the image a device entry point resolves into
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
## VK-6: C-only validation capture
the messenger callback is an unnamed address in /candidate/dist-vulkan-proof/build/x86_64-linux/ghc-9.14.1/hetoimasia-vulkan-proof-0.1.0.0/t/vulkan-proof/opt/build/vulkan-proof/vulkan-proof
## VK-6: a message submitted through an unsafe import
vkSubmitDebugUtilsMessageEXT returned from its unsafe import
## VK-6: a validation error from an unsafe recording call
recording on llvmpipe (LLVM 20.1.2, 256 bits), queue family 0
vkCmdSetViewport returned from its unsafe import
## VK-6: teardown
the device and its pool are gone; the explicit messenger is destroyed next, then the instance
the lifetime delivered 79 records to the logger
```
