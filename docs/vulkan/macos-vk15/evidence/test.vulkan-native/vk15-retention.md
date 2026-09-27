# The VK-15 retention record

Verdict: **pass**.

## A retained unverified resource

- a CPU use of the active generation held and never ended: True
- where the held generation stood: Just GenerationRetiredHeld
- primary failure: Nothing
- what teardown reported retained:
  - RetainedUnverified "the swapchain generations of TargetId 0 1 are retained: [GenerationId (TargetId 0 1) 0]"
  - RetainedUnverified "the Vulkan roots are retained: 1 target surfaces have not verifiably been destroyed"
  - RetainedUnverified "LeaseRetained LeaseOwed"
- the owner's run ended: True; destruction evidence: Nothing
- the roots when the watcher read them: instance RootLive, device RootLive, targets 1
- the host still holds the window, its attachment without a terminal record: True

The process was then terminated by the fixture's destructive boundary. The
session released nothing more: the operating system reclaims the window,
the surface, the device and the instance. This is not orderly cleanup,
and no diagnostic verdict follows, because the instance's messengers were
never destroyed and the last callback was never reached.

Native calls the session made, in the order they returned:

1. vkEnumerateInstanceExtensionProperties
1. vkCreateInstance
1. vkCreateDebugUtilsMessengerEXT
1. glfwCreateWindowSurface
1. vkEnumeratePhysicalDevices
1. vkCreateDevice
1. vkSetDebugUtilsObjectNameEXT
1. vkGetDeviceQueue
1. vkSetDebugUtilsObjectNameEXT
1. vkSetDebugUtilsObjectNameEXT
1. vkGetPhysicalDeviceSurfaceCapabilitiesKHR
1. vkCreateSwapchainKHR
1. vkSetDebugUtilsObjectNameEXT
1. vkGetSwapchainImagesKHR
1. vkSetDebugUtilsObjectNameEXT
1. vkCreateImageView
1. vkSetDebugUtilsObjectNameEXT
1. vkSetDebugUtilsObjectNameEXT
1. vkCreateImageView
1. vkSetDebugUtilsObjectNameEXT
1. vkSetDebugUtilsObjectNameEXT
1. vkCreateImageView
1. vkSetDebugUtilsObjectNameEXT

## Transcript

```
## VK-15: a retained unverified resource, reported rather than released
holding a CPU use of GenerationId (TargetId 0 1) 0: held
the host exits with the generation's use still held
```
