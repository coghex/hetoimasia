/* See hetoimasia_glfw_vulkan.h. */

/* The Vulkan headers come first, and GLFW is then told to include no API
 * headers of its own. GLFW guards the three Vulkan-typed declarations behind
 * VK_VERSION_1_0, which <vulkan/vulkan.h> defines; GLFW_INCLUDE_VULKAN would do
 * the same but would not stop glfw3.h from also including an OpenGL header. */
#include <vulkan/vulkan.h>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

#include <stddef.h>

#include "hetoimasia_glfw_vulkan.h"

/* The handle ABI the VK-2 proof established: a non-dispatchable handle is a
 * 64-bit value on every platform this package supports, so it crosses into
 * Haskell as a uint64_t rather than as a pointer of differing width. */
_Static_assert(sizeof(VkSurfaceKHR) == sizeof(uint64_t),
               "the surface bridge assumes a 64-bit non-dispatchable Vulkan handle");

/* What this shim last handed glfwInitVulkanLoader. Written and read on the
 * session's owner thread, which is the only thread that enters or ends a
 * session. */
static void *installed_loader = NULL;

void hetoimasia_glfw_vulkan_set_loader(void *entry)
{
  glfwInitVulkanLoader((PFN_vkGetInstanceProcAddr) entry);
  installed_loader = entry;
}

void *hetoimasia_glfw_vulkan_installed_loader(void)
{
  return installed_loader;
}

int hetoimasia_glfw_vulkan_supported(void)
{
  return glfwVulkanSupported();
}

const char **hetoimasia_glfw_vulkan_required_extensions(uint32_t *count)
{
  *count = 0;
  return glfwGetRequiredInstanceExtensions(count);
}

void *hetoimasia_glfw_vulkan_instance_proc_address(void *instance, const char *name)
{
  return (void *) glfwGetInstanceProcAddress((VkInstance) instance, name);
}

int hetoimasia_glfw_vulkan_create_surface(void *instance, void *window, uint64_t *surface)
{
  VkSurfaceKHR created = VK_NULL_HANDLE;
  VkResult result = glfwCreateWindowSurface((VkInstance) instance, (GLFWwindow *) window, NULL, &created);
  *surface = (uint64_t) created;
  return (int) result;
}

int hetoimasia_glfw_vulkan_destroy_surface(void *entry, void *instance, uint64_t surface)
{
  PFN_vkGetInstanceProcAddr resolve = (PFN_vkGetInstanceProcAddr) entry;
  PFN_vkDestroySurfaceKHR destroy =
      (PFN_vkDestroySurfaceKHR) resolve((VkInstance) instance, "vkDestroySurfaceKHR");
  if (destroy == NULL) {
    return -1;
  }
  destroy((VkInstance) instance, (VkSurfaceKHR) surface, NULL);
  return 0;
}
