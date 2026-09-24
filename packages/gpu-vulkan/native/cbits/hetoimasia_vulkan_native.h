/*
** The native backend's C side: the debug-utils messenger callback it installs.
**
** It is a C function with exactly the type Vulkan calls, and all it does is
** hand its arguments to the diagnostics package's C producer. No Haskell is
** reachable from it, which is what lets a Vulkan call made through an `unsafe`
** import report a diagnostic without re-entering the runtime.
**
** The producer reads the callback data through a layout mirror, because the
** diagnostics package includes no Vulkan header. This translation unit is the
** one place both are visible, so it checks the mirror against the real
** structures at compile time: a Vulkan header whose layout differs fails the
** build rather than being read through the wrong offsets.
*/
#ifndef HETOIMASIA_VULKAN_NATIVE_H
#define HETOIMASIA_VULKAN_NATIVE_H

#include <vulkan/vulkan.h>

VKAPI_ATTR VkBool32 VKAPI_CALL hetoimasia_vulkan_capture_messenger(
  VkDebugUtilsMessageSeverityFlagBitsEXT severity,
  VkDebugUtilsMessageTypeFlagsEXT types,
  const VkDebugUtilsMessengerCallbackDataEXT *data,
  void *user_data);

#endif
