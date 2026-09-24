/*
 * The GLFW package's Vulkan interop shim: the one translation unit in the
 * package that sees Vulkan's headers.
 *
 * GLFW 3.4 declares glfwInitVulkanLoader, glfwGetInstanceProcAddress, and
 * glfwCreateWindowSurface only when VK_VERSION_1_0 is defined, so the shim's
 * source includes <vulkan/vulkan.h> before <GLFW/glfw3.h>. The package's
 * ordinary native library keeps GLFW_INCLUDE_NONE and names nothing from Vulkan;
 * this shim belongs to the separate vulkan-interop component, which only
 * cabal.project.vulkan builds.
 *
 * This header itself names no Vulkan or GLFW type, so the Haskell imports that
 * name it see untyped pointers: a dispatchable handle as the pointer it is, a
 * GLFW window as an opaque pointer, and a surface as the 64-bit value every
 * supported Vulkan ABI gives a non-dispatchable handle — a width the source
 * checks at compile time.
 *
 * Every function here may reach the loader and whatever layers it enabled, so
 * every import of one is `safe`.
 */
#ifndef HETOIMASIA_GLFW_VULKAN_H
#define HETOIMASIA_GLFW_VULKAN_H

#include <stdint.h>

/* glfwInitVulkanLoader(entry), then record entry as the value this shim last
 * handed GLFW. `entry` is the Vulkan binding's own vkGetInstanceProcAddr, or
 * NULL to restore GLFW's default loader search. It is a pre-init hint: GLFW
 * reads it at the next glfwInit and it survives glfwTerminate. Call it on the
 * session's owner thread. */
void hetoimasia_glfw_vulkan_set_loader(void *entry);

/* The value this shim last handed glfwInitVulkanLoader, or NULL if it has
 * handed none or last restored the default. This shim is the only code in the
 * process that sets that hint, so this is the hint's value: GLFW itself offers
 * no way to read it back. Any thread may call it: the record is atomic, and
 * only a session's owner thread changes it. */
void *hetoimasia_glfw_vulkan_installed_loader(void);

/* glfwVulkanSupported. */
int hetoimasia_glfw_vulkan_supported(void);

/* glfwGetRequiredInstanceExtensions. GLFW owns the array and its strings until
 * termination; the caller copies them before its operation returns. */
const char **hetoimasia_glfw_vulkan_required_extensions(uint32_t *count);

/* glfwGetInstanceProcAddress: what GLFW's loader resolves a name to. `instance`
 * may be NULL for a global entry point. For provenance evidence only. */
void *hetoimasia_glfw_vulkan_instance_proc_address(void *instance, const char *name);

/* glfwCreateWindowSurface for a live GLFW window. Writes the handle to
 * `surface`, VK_NULL_HANDLE when nothing was created, and returns the VkResult. */
int hetoimasia_glfw_vulkan_create_surface(void *instance, void *window, uint64_t *surface);

/* vkDestroySurfaceKHR, resolved through `entry` — the capability's own
 * vkGetInstanceProcAddr — for this instance. It is a Vulkan call, never a GLFW
 * one, and any thread may make it. Returns 0 once the destruction has been
 * called, and -1, having destroyed nothing, when the loader resolved no such
 * entry point. */
int hetoimasia_glfw_vulkan_destroy_surface(void *entry, void *instance, uint64_t surface);

#endif /* HETOIMASIA_GLFW_VULKAN_H */
