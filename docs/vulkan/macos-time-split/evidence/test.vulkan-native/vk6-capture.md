# The VK-6 validation capture record

Verdict: **pass**.

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
- device: Apple M3 Max
- messenger callback: 0x00000001034139ac in /Users/vincentcoghlan/worktrees/coghex/hetoimasia/issue-274-time-types-arithmetic/dist-vulkan/build/aarch64-osx/ghc-9.14.1/hetoimasia-gpu-vulkan-glfw-0.1.0.0/t/vulkan-native-tests/opt/build/vulkan-native-tests/vulkan-native-tests as hetoimasia_vulkan_capture_messenger
- this executable: /Users/vincentcoghlan/worktrees/coghex/hetoimasia/issue-274-time-types-arithmetic/dist-vulkan/build/aarch64-osx/ghc-9.14.1/hetoimasia-gpu-vulkan-glfw-0.1.0.0/t/vulkan-native-tests/opt/build/vulkan-native-tests/vulkan-native-tests
- unsafe imports this session declares: vkSubmitDebugUtilsMessageEXT, vkCmdSetViewport
- binding safe-foreign-calls in binding.pin: on
- binding darwin-lib-dirs in binding.pin: off
- native package binding: vulkan-3.27
- native package binding safe-foreign-calls: on
- native package binding darwin-lib-dirs: off
- native package capture callback: hetoimasia_vulkan_capture_messenger (C) → hetoimasia_capture_callback (C)
- native package Haskell callbacks installed: none
- native package unsafe imports declared: vkBeginCommandBuffer, vkEndCommandBuffer, vkCmdPipelineBarrier2, vkCmdBeginRendering, vkCmdEndRendering, vkCmdBindPipeline, vkCmdSetViewport, vkCmdSetScissor, vkCmdDraw, vkCmdCopyImageToBuffer, vkCmdBeginDebugUtilsLabelEXT, vkCmdEndDebugUtilsLabelEXT
- native package safe calls: everything else: waits, submission, presentation, pipeline creation, construction and destruction, through the binding

- verdict issues: ErrorLatched
- error latched: yes
- capture failure latched: no
- reports offered: 66
- admitted: 66
- dropped: 0
- truncated: 0
- capture failures: 0
- error reports: 1
- delivered to the logger: 66
- undelivered: 0
- drain worker: completed

### Reports by step

| Step | Reports | Errors |
| --- | --- | --- |
| vkCreateInstance | 44 | 0 |
| vkCreateDebugUtilsMessengerEXT | 0 | 0 |
| vkSubmitDebugUtilsMessageEXT, through an unsafe import | 1 | 0 |
| vkEnumeratePhysicalDevices | 0 | 0 |
| vkCreateDevice | 16 | 0 |
| vkCreateCommandPool | 0 | 0 |
| vkAllocateCommandBuffers | 0 | 0 |
| vkBeginCommandBuffer | 0 | 0 |
| vkCmdSetViewport, through an unsafe import | 1 | 1 |
| vkEndCommandBuffer | 0 | 0 |
| vkDestroyCommandPool | 0 | 0 |
| vkDestroyDevice | 1 | 0 |
| vkDestroyDebugUtilsMessengerEXT | 0 | 0 |
| vkDestroyInstance, after the explicit messenger was destroyed | 3 | 0 |

### Delivered records

Every record the drain worker handed to the logger, in delivery order, with
the step whose reports it was.

| Step | Severity | Message id | Message |
| --- | --- | --- | --- |
| vkCreateInstance | info | Loader Message | Portability enumeration bit was set, enumerating portability drivers. |
| vkCreateInstance | info | Loader Message | Searching for implicit layer manifest files |
| vkCreateInstance | info | Loader Message |    In following locations: |
| vkCreateInstance | info | Loader Message |       /Users/vincentcoghlan/worktrees/coghex/hetoimasia/issue-274-time-types-arithmetic/dist-vulkan/build/aarch64-osx/ghc-9.14.1/hetoimasia-gpu-vulkan-glfw-0... |
| vkCreateInstance | info | Loader Message |       /Users/vincentcoghlan/.config/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /etc/xdg/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /Users/lunarg/Dev/macos-sdk-build/Vulkan-Loader/build/install/etc/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /etc/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /Users/vincentcoghlan/.local/share/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /Applications/cmux.app/Contents/Resources/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /usr/local/share/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /usr/share/vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |       /Applications/cmux.app/Contents/Resources/ghostty/../vulkan/implicit_layer.d |
| vkCreateInstance | info | Loader Message |    Found no files |
| vkCreateInstance | info | Loader Message | Searching for explicit layer manifest files |
| vkCreateInstance | info | Loader Message |    In following locations: |
| vkCreateInstance | info | Loader Message |       /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/c8254ba4-eed6-49f2-a1f4-e3921f3b274d/scratchpad/native/glfw/vulkan/share/vulkan/explicit_... |
| vkCreateInstance | info | Loader Message |    Found the following files: |
| vkCreateInstance | info | Loader Message |       /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/c8254ba4-eed6-49f2-a1f4-e3921f3b274d/scratchpad/native/glfw/vulkan/share/vulkan/explicit_... |
| vkCreateInstance | info | Loader Message | Found manifest file /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/c8254ba4-eed6-49f2-a1f4-e3921f3b274d/scratchpad/native/glfw/vulkan/share/vu... |
| vkCreateInstance | info | Loader Message | Searching for driver manifest files |
| vkCreateInstance | info | Loader Message |    In following locations: |
| vkCreateInstance | info | Loader Message |       /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/c8254ba4-eed6-49f2-a1f4-e3921f3b274d/scratchpad/native/glfw/vulkan/share/vulkan/icd.d/Mol... |
| vkCreateInstance | info | Loader Message |    Found the following files: |
| vkCreateInstance | info | Loader Message |       /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/c8254ba4-eed6-49f2-a1f4-e3921f3b274d/scratchpad/native/glfw/vulkan/share/vulkan/icd.d/Mol... |
| vkCreateInstance | info | Loader Message | Found ICD manifest file /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/c8254ba4-eed6-49f2-a1f4-e3921f3b274d/scratchpad/native/glfw/vulkan/shar... |
| vkCreateInstance | verbose | Loader Message | Searching for ICD drivers named /opt/homebrew/Cellar/molten-vk/1.4.0/lib/libMoltenVK.dylib |
| vkCreateInstance | verbose | Loader Message | Loading layer library /usr/local/lib/libVkLayer_khronos_validation.dylib |
| vkCreateInstance | info | Loader Message | Insert instance layer "VK_LAYER_KHRONOS_validation" (/usr/local/lib/libVkLayer_khronos_validation.dylib) |
| vkCreateInstance | info | Loader Message | vkCreateInstance layer callstack setup to: |
| vkCreateInstance | info | Loader Message |    <Application> |
| vkCreateInstance | info | Loader Message |      \|\| |
| vkCreateInstance | info | Loader Message |    <Loader> |
| vkCreateInstance | info | Loader Message |      \|\| |
| vkCreateInstance | info | Loader Message |    VK_LAYER_KHRONOS_validation |
| vkCreateInstance | info | Loader Message |            Type: Explicit |
| vkCreateInstance | info | Loader Message |            Manifest: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/c8254ba4-eed6-49f2-a1f4-e3921f3b274d/scratchpad/native/glfw/vulkan/share/v... |
| vkCreateInstance | info | Loader Message |            Library:  /usr/local/lib/libVkLayer_khronos_validation.dylib |
| vkCreateInstance | info | Loader Message |      \|\| |
| vkCreateInstance | info | Loader Message |    <Drivers> |
| vkCreateInstance | info | mvk-info | MoltenVK version 1.4.0, supporting Vulkan version 1.4.323. 	The following 145 Vulkan extensions are supported: 	VK_KHR_16bit_storage v1 	VK_KHR_8bit_storage ... |
| vkCreateInstance | info | mvk-info | GPU device: 	model: Apple M3 Max 	type: Integrated 	vendorID: 0x106b 	deviceID: 0x1a070209 	pipelineCacheUUID: 000028A0-1A07-0209-0000-000100000000 	GPU memo... |
| vkCreateInstance | info | mvk-info | Created VkInstance for Vulkan version 1.3.323, as requested by app, with the following 1 Vulkan extensions enabled: 	VK_EXT_debug_utils v2 |
| vkCreateInstance | info | WARNING-CreateInstance-status-message | Validation Information: [ WARNING-CreateInstance-status-message ] Object 0: handle = 0x10af9fcb0, type = VK_OBJECT_TYPE_INSTANCE; \| MessageID = 0x23dfd876 \| ... |
| vkSubmitDebugUtilsMessageEXT, through an unsafe import | info | hetoimasia-vulkan-proof-unsafe-submit | delivered from inside an unsafe foreign call |
| vkCreateDevice | info | Loader Message | Inserted device layer "VK_LAYER_KHRONOS_validation" (/usr/local/lib/libVkLayer_khronos_validation.dylib) |
| vkCreateDevice | info | Loader Message | vkCreateDevice layer callstack setup to: |
| vkCreateDevice | info | Loader Message |    <Application> |
| vkCreateDevice | info | Loader Message |      \|\| |
| vkCreateDevice | info | Loader Message |    <Loader> |
| vkCreateDevice | info | Loader Message |      \|\| |
| vkCreateDevice | info | Loader Message |    VK_LAYER_KHRONOS_validation |
| vkCreateDevice | info | Loader Message |            Type: Explicit |
| vkCreateDevice | info | Loader Message |            Manifest: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/c8254ba4-eed6-49f2-a1f4-e3921f3b274d/scratchpad/native/glfw/vulkan/share/v... |
| vkCreateDevice | info | Loader Message |            Library:  /usr/local/lib/libVkLayer_khronos_validation.dylib |
| vkCreateDevice | info | Loader Message |      \|\| |
| vkCreateDevice | info | Loader Message |    <Device> |
| vkCreateDevice | info | Loader Message |        Using "Apple M3 Max" with driver: "/opt/homebrew/Cellar/molten-vk/1.4.0/lib/libMoltenVK.dylib" |
| vkCreateDevice | info | mvk-info | Vulkan semaphores using MTLEvent. |
| vkCreateDevice | info | mvk-info | Descriptor sets binding resources using Metal3 argument buffers. |
| vkCreateDevice | info | mvk-info | Created VkDevice to run on GPU Apple M3 Max with the following 1 Vulkan extensions enabled: 	VK_KHR_portability_subset v1 |
| vkCmdSetViewport, through an unsafe import | error | VUID-vkCmdSetViewport-viewportCount-arraylength | Validation Error: [ VUID-vkCmdSetViewport-viewportCount-arraylength ] \| MessageID = 0x7a2f405c \| vkCmdSetViewport(): viewportCount must be greater than 0. Th... |
| vkDestroyDevice | info | mvk-info | Destroyed VkDevice on GPU Apple M3 Max with 1 Vulkan extensions enabled. |
| vkDestroyInstance, after the explicit messenger was destroyed | info | mvk-info | Destroyed VkPhysicalDevice for GPU Apple M3 Max with 0 MB of GPU memory still allocated. |
| vkDestroyInstance, after the explicit messenger was destroyed | info | mvk-info | Destroying VkInstance for Vulkan version 1.3.323 with 1 Vulkan extensions enabled. |
| vkDestroyInstance, after the explicit messenger was destroyed | verbose | Loader Message | Unloading layer library /usr/local/lib/libVkLayer_khronos_validation.dylib |

## Transcript

```
## VK-6: C-only validation capture
the messenger callback is hetoimasia_vulkan_capture_messenger in /Users/vincentcoghlan/worktrees/coghex/hetoimasia/issue-274-time-types-arithmetic/dist-vulkan/build/aarch64-osx/ghc-9.14.1/hetoimasia-gpu-vulkan-glfw-0.1.0.0/t/vulkan-native-tests/opt/build/vulkan-native-tests/vulkan-native-tests
## VK-6: a message submitted through an unsafe import
vkSubmitDebugUtilsMessageEXT returned from its unsafe import
## VK-6: a validation error from an unsafe recording call
recording on Apple M3 Max, queue family 0
vkCmdSetViewport returned from its unsafe import
## VK-6: teardown
the device and its pool are gone; the explicit messenger is destroyed next, then the instance
the lifetime delivered 66 records to the logger
```
