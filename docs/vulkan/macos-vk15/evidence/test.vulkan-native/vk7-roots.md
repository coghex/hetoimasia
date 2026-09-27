# The VK-7 Vulkan roots record

Verdict: **pass**.

## VK-7: the Vulkan roots under the graphics owner

A fourth session, through the integration package's own composition: the
native backend package's production roots, run by the GLFW package's
supervised graphics owner, with the GLFW package's production surface bridge,
inside a diagnostic lifetime whose capture both of the instance's messengers
report into. Two hidden windows are handed over; the first-created is closed
while the second stays attached; the host then exits. Every native call is
listed below with the OS thread it ran on, read through `pthread_self` at the
call itself, and the reports the capture received during it. Reports during
child teardown reach the explicit messenger, which is live until its own
destruction; reports during `vkDestroyInstance` reach the create-info
messenger alone. Their counts are platform-dependent and are recorded, not
required.

- capture limits: 1024 queued records, 16384 bytes of text per record (the default is 4096; see the proof README), 16 objects per record
- main thread: OS thread 0x1eda5a1c0, ThreadId 4
- readiness: RootsReady
- device: Apple M3 Max
- queue family: 0
- targets once both windows were handed over: RequiredTarget on surface 0xfab64d0000000002, RequiredTarget on surface 0xfa21a40000000003
- after the first window closed: device RootLive, instance RootLive, 1 targets
- second target after the close: TargetUsable
- windows after the close: 1
- reports during child teardown (explicit messenger): 1
- reports during vkDestroyInstance (create-info messenger): 3

- verdict issues: none
- error latched: no
- capture failure latched: no
- reports offered: 64
- admitted: 64
- dropped: 0
- truncated: 0
- capture failures: 0
- error reports: 0
- delivered to the logger: 64
- undelivered: 0
- drain worker: completed

| Native call | OS thread | Main thread | Haskell thread | Reports during it | Raised |
| --- | --- | --- | --- | --- | --- |
| vkEnumerateInstanceExtensionProperties | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkCreateInstance | 0x16de6b000 | no | ThreadId 6 | 44 | no |
| vkCreateDebugUtilsMessengerEXT | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| glfwCreateWindowSurface | 0x1eda5a1c0 | yes | ThreadId 4 | 0 | no |
| vkEnumeratePhysicalDevices | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkCreateDevice | 0x16de6b000 | no | ThreadId 6 | 16 | no |
| vkSetDebugUtilsObjectNameEXT | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkGetDeviceQueue | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkSetDebugUtilsObjectNameEXT | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkSetDebugUtilsObjectNameEXT | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| glfwCreateWindowSurface | 0x1eda5a1c0 | yes | ThreadId 4 | 0 | no |
| vkGetPhysicalDeviceSurfaceSupportKHR | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkSetDebugUtilsObjectNameEXT | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkDestroySurfaceKHR | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkDestroySurfaceKHR | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkDestroyDevice | 0x16de6b000 | no | ThreadId 6 | 1 | no |
| vkDestroyDebugUtilsMessengerEXT | 0x16de6b000 | no | ThreadId 6 | 0 | no |
| vkDestroyInstance | 0x16de6b000 | no | ThreadId 6 | 3 | no |

## Transcript

```
## VK-7: the Vulkan roots under the graphics owner
the owner created the instance and its explicit messenger, and leased it to the surface bridge
both targets admitted on Apple M3 Max, queue family 0
after the first window closed: device RootLive, instance RootLive, 1 target
the explicit messenger received 1 reports during child teardown
the create-info messenger received 3 reports during vkDestroyInstance
```
