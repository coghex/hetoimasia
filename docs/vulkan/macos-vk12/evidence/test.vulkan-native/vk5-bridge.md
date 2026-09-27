# The VK-5 surface bridge record

Verdict: **pass**.

## VK-5: the loader-aware GLFW surface bridge

A third session, through the GLFW package's own Vulkan interop component:
the loader capability built from the binding's own `vkGetInstanceProcAddr`,
the package's loader-aware session behind a protected window host, a surface
created inside an attachment's construction step, and its obligation
discharged on a thread that is not the owner. GLFW offers no way to read back
its loader hint, so the setting reported is the value the interop shim last
handed it; that shim is its only production writer, and the VK-2 run's
throwaway shim, which also set it, was reset first.

- binding vkGetInstanceProcAddr: 0x000000010860f8f4 in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
- capability made from: 0x000000010860f8f4 in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
- shim setting while the session was live: 0x000000010860f8f4 in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
- GLFW resolved vkGetInstanceProcAddr to: 0x000000010860f8f4 in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
- capability while the session was live: IntegrationInstalled
- binding vkCreateDevice: 0x000000010861103c in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkCreateDevice
- GLFW vkCreateDevice: 0x000000010861103c in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkCreateDevice
- required instance extensions, as copied: VK_KHR_surface, VK_EXT_metal_surface
- surface creation: SurfaceCreated (WindowSurface (SurfaceObligation (AttachmentId (WindowId 1) 1) 35308717200))
- surface handle: 35308717200
- surface query: presentation support on queue family 0 of the first device: True
- instance release while owed: InstanceRetained (LeaseStanding {standingAdmitting = False, standingConstructing = 0, standingOwed = 1, standingUncertain = 0})
- disposal fact while owed: Nothing
- discharge: SurfaceDestroyed
- discharged off the owner thread: yes
- disposal fact afterwards: Just AttachmentNowRetired
- instance release afterwards: InstanceReleasable
- shim setting after termination: 0x0000000000000000
- capability after termination: IntegrationRestored
- failed initialization: not reachable on this platform: GLFW 3.4's Cocoa initialization has no failure an application can provoke, and Cocoa is the only backend this platform admits

## Transcript

```
## VK-5: the loader-aware GLFW surface bridge
restored GLFW's default loader through the VK-2 shim before the production shim's first setting
the capability was made from 0x000000010860f8f4 in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
while the session is live the shim holds 0x000000010860f8f4 in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
GLFW resolves vkGetInstanceProcAddr to 0x000000010860f8f4 in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkGetInstanceProcAddr
the session copied the required extensions VK_KHR_surface, VK_EXT_metal_surface
the binding resolves vkCreateDevice to 0x000000010861103c in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkCreateDevice
GLFW resolves vkCreateDevice to 0x000000010861103c in /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/fded83a2-947c-469b-a7e9-b06b56bb02f0/scratchpad/native/glfw/vulkan/lib/libvulkan.1.dylib as vkCreateDevice
created surface 35308717200 for the attached window
the binding answered a query about it: presentation support on queue family 0 of the first device: True
while it was owed, the disposal fact answered Nothing and the instance release InstanceRetained (LeaseStanding {standingAdmitting = False, standingConstructing = 0, standingOwed = 1, standingUncertain = 0})
another thread discharged it: SurfaceDestroyed
afterwards the disposal fact answered Just AttachmentNowRetired and the instance release InstanceReleasable
after termination the shim holds 0x0000000000000000 and the capability is IntegrationRestored
a failed initialization is not reachable here: GLFW 3.4's Cocoa initialization has no failure an application can provoke, and Cocoa is the only backend this platform admits
```
