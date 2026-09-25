# Naming a debug messenger crashes the pinned macOS loader and driver

> **Editorial context, added when this evidence was retained.** This is the
> crash evidence behind #250's one naming exception
> ([the backend contract](../gpu_backend.md#names-and-labels)): the backend
> never names its debug messenger. It was gathered on 2026-09-25 on the local
> macOS machine, with windowless diagnostic probes — no window, no swapchain,
> no submission — and it is evidence of the inputs it names, not a routine
> check. Nothing in the repository runs the probe.

## Inputs

- Loader 1.3.296 — `/usr/local/lib/libvulkan.1.3.296.dylib`, SHA-256
  `43e14d232fc727b7f2832da79944650237223a9f47b71cf1aafd3891bf6cb3e6`, and the
  provisioned native prefix's copy of it (`085fa54b6cad`).
- Driver MoltenVK 1.4.0 — `libMoltenVK.dylib`, SHA-256
  `6e9ec5b2968916d5d3172a55e43192727674470d4f16ece10fe579b1c7d01057`.
- Layer `VK_LAYER_KHRONOS_validation` 1.3.296 — SHA-256
  `dc6b9c2fd7b6e19c2b1d66fbc837bceaca72e62ea63114de17bd86b4e2d49d95`.

These are the pinned profile's (`tools/native/vulkan.pin`). No Linux or
Lavapipe observation was made; the exception applies on both profiles because
the defect is in how a loader hands a messenger to a driver, and one uniform
rule is simpler than a driver conditional.

## What happened

The first approved desktop run of `test.vulkan-native` for #250 stopped with
exit status −11 (SIGSEGV) during the shared session's first target admission,
the moment the roots first named anything. At that head the roots named the
explicit messenger before the device, its queue and the surface.

## Results

Each case is one call of `vkSetDebugUtilsObjectNameEXT` through the device, on
an instance created with `VK_EXT_debug_utils` and a device created with
`VK_KHR_portability_subset`:

| Object named | Device extensions | Validation layer | Result |
| --- | --- | --- | --- |
| The device | with `VK_KHR_swapchain` | on, off | `VK_SUCCESS` |
| Its queue | with `VK_KHR_swapchain` | on, off | `VK_SUCCESS` |
| The instance, the physical device | with `VK_KHR_swapchain` | on, off | `VK_SUCCESS` |
| A Metal surface over an unattached `CAMetalLayer` | with `VK_KHR_swapchain` | on, off | `VK_SUCCESS` |
| The same surface | without `VK_KHR_swapchain` | on, off | crash |
| The debug messenger | either | on, off | crash (SIGSEGV; SIGABRT in the Objective-C runtime's unknown-class check in one rerun) |
| The messenger and the surface, calling MoltenVK directly with no loader | — | off | `VK_SUCCESS` |

The last row is a control experiment only; the backend never bypasses the
loader.

## Why

The pinned loader's `terminator_CreateDebugUtilsMessengerEXT` stores each
driver's messenger separately and answers the application a loader-owned
pointer to an index as the messenger's handle.
`terminator_SetDebugUtilsObjectNameEXT` translates physical devices, instances
and surfaces to the driver's own handles before forwarding the naming call, but
has no case for messengers: it forwards the loader's pointer unchanged.
MoltenVK's `vkSetDebugUtilsObjectNameEXT` casts every non-dispatchable handle
to one of its own objects and releases that object's previous name, so the
loader's pointer is dereferenced as an object it is not. The surface
translation is guarded by the device's `vkCreateSwapchainKHR` dispatch entry,
which is why a surface on a device without `VK_KHR_swapchain` crashes the same
way; the profile's device always enables it (`Profile.selectDevice`).

Vulkan permits naming an instance-level object through a device descended from
the same instance
([`vkSetDebugUtilsObjectNameEXT`](https://docs.vulkan.org/refpages/latest/refpages/source/vkSetDebugUtilsObjectNameEXT.html)),
so this is a loader and driver interoperability defect, not a misuse. It is not
a recoverable Vulkan error either, so the backend makes no naming call for a
messenger rather than trying one.

## The probe

A diagnostic-only C harness, built against the provisioned prefix's headers and
loader with `-framework QuartzCore -framework Foundation -lobjc`, and run with
`VK_DRIVER_FILES` and `VK_LAYER_PATH` pointing into the prefix and
`VK_LOADER_LAYERS_DISABLE=~implicit~`, one object per run
(`device`, `queue`, `surface`, `messenger`). Removing `VK_KHR_swapchain` from
the device's extensions is the negative surface control, and dropping the layer
from the instance's create info the layer-off case.

```c
#define VK_USE_PLATFORM_METAL_EXT 1
#include <vulkan/vulkan.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static VKAPI_ATTR VkBool32 VKAPI_CALL cb(VkDebugUtilsMessageSeverityFlagBitsEXT s, VkDebugUtilsMessageTypeFlagsEXT t,
  const VkDebugUtilsMessengerCallbackDataEXT *d, void *u) {
  if (s >= VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) printf("  report %s: %.200s\n", d->pMessageIdName ? d->pMessageIdName : "-", d->pMessage);
  return VK_FALSE;
}

int main(int argc, char **argv) {
  const char *which = argc > 1 ? argv[1] : "all";
  const char *exts[] = {"VK_EXT_debug_utils", "VK_KHR_portability_enumeration", "VK_KHR_surface", "VK_EXT_metal_surface"};
  const char *layers[] = {"VK_LAYER_KHRONOS_validation"};
  VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "probe", 0, "probe", 0, VK_API_VERSION_1_3};
  VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR, &app, 1, layers, 4, exts};
  VkInstance inst; VkResult r = vkCreateInstance(&ici, NULL, &inst); printf("instance %d\n", r); if (r) return 1;
  PFN_vkCreateDebugUtilsMessengerEXT cm = (PFN_vkCreateDebugUtilsMessengerEXT) vkGetInstanceProcAddr(inst, "vkCreateDebugUtilsMessengerEXT");
  VkDebugUtilsMessengerCreateInfoEXT mci = {VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT, NULL, 0, 0x1111, 0x7, cb, NULL};
  VkDebugUtilsMessengerEXT msgr; r = cm(inst, &mci, NULL, &msgr); printf("messenger %d\n", r);
  uint32_t n = 1; VkPhysicalDevice phys; vkEnumeratePhysicalDevices(inst, &n, &phys);
  float prio = 1; VkDeviceQueueCreateInfo q = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
  const char *dext[] = {"VK_KHR_portability_subset", "VK_KHR_swapchain"};
  VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &q, 0, NULL, 2, dext, NULL};
  VkDevice dev; r = vkCreateDevice(phys, &dci, NULL, &dev); printf("device %d\n", r); if (r) return 1;
  VkQueue queue; vkGetDeviceQueue(dev, 0, 0, &queue);
  PFN_vkSetDebugUtilsObjectNameEXT sn = (PFN_vkSetDebugUtilsObjectNameEXT) vkGetDeviceProcAddr(dev, "vkSetDebugUtilsObjectNameEXT");
  printf("set name via device %p\n", (void *) sn); fflush(stdout);
  if (!strcmp(which, "device") || !strcmp(which, "all")) {
    VkDebugUtilsObjectNameInfoEXT i = {VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT, NULL, VK_OBJECT_TYPE_DEVICE, (uint64_t)(uintptr_t) dev, "probe device"};
    printf("naming device -> %d\n", sn(dev, &i)); fflush(stdout);
  }
  if (!strcmp(which, "queue") || !strcmp(which, "all")) {
    VkDebugUtilsObjectNameInfoEXT i = {VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT, NULL, VK_OBJECT_TYPE_QUEUE, (uint64_t)(uintptr_t) queue, "probe queue"};
    printf("naming queue -> %d\n", sn(dev, &i)); fflush(stdout);
  }
  if (!strcmp(which, "messenger") || !strcmp(which, "all")) {
    VkDebugUtilsObjectNameInfoEXT i = {VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT, NULL, VK_OBJECT_TYPE_DEBUG_UTILS_MESSENGER_EXT, (uint64_t) msgr, "probe messenger"};
    printf("naming messenger -> %d\n", sn(dev, &i)); fflush(stdout);
  }
  if (!strcmp(which, "surface") || !strcmp(which, "all")) {
    id layer = ((id (*)(id, SEL)) objc_msgSend)((id) objc_getClass("CAMetalLayer"), sel_registerName("layer"));
    VkMetalSurfaceCreateInfoEXT sci = {VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT, NULL, 0, (const CAMetalLayer *) layer};
    VkSurfaceKHR surface;
    PFN_vkCreateMetalSurfaceEXT cs = (PFN_vkCreateMetalSurfaceEXT) vkGetInstanceProcAddr(inst, "vkCreateMetalSurfaceEXT");
    printf("surface %d\n", cs(inst, &sci, NULL, &surface)); fflush(stdout);
    VkDebugUtilsObjectNameInfoEXT i = {VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT, NULL, VK_OBJECT_TYPE_SURFACE_KHR, (uint64_t) surface, "probe surface"};
    printf("naming surface -> %d\n", sn(dev, &i)); fflush(stdout);
    vkDestroySurfaceKHR(inst, surface, NULL);
  }
  vkDestroyDevice(dev, NULL);
  ((PFN_vkDestroyDebugUtilsMessengerEXT) vkGetInstanceProcAddr(inst, "vkDestroyDebugUtilsMessengerEXT"))(inst, msgr, NULL);
  vkDestroyInstance(inst, NULL);
  printf("done\n");
  return 0;
}
```

Its runs, with the layer on:

```
== surface
instance 0
messenger 0
device 0
surface 0
naming surface -> 0
done
== messenger
instance 0
messenger 0
device 0
(the process died here; "naming messenger" and "done" were never printed)
```
