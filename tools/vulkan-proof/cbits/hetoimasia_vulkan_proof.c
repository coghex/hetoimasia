/* See hetoimasia_vulkan_proof.h. */

/* `dladdr` and `Dl_info` are GNU extensions. glibc hides both behind
 * `_GNU_SOURCE`, and hides them quietly: without this the struct is simply not
 * declared and every field access becomes an error about "something not a
 * structure or union". Apple's libc declares them unconditionally, which is why
 * only the Linux container noticed. This has to precede every include. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

/* The Vulkan headers come first, and GLFW is then told to include no API
 * headers of its own. Both halves matter.
 *
 * GLFW guards `glfwInitVulkanLoader`, `glfwGetInstanceProcAddress`, and
 * `glfwCreateWindowSurface` behind `VK_VERSION_1_0`, so something must define
 * it before `glfw3.h` is read or those three declarations simply are not there.
 *
 * `GLFW_INCLUDE_VULKAN` would do that, but it does not stop `glfw3.h` from also
 * including an OpenGL header — and on Linux `GL/gl.h` belongs to a package this
 * container has no reason to carry. Including Vulkan directly and passing
 * `GLFW_INCLUDE_NONE` gets the Vulkan section without the GL one. */
#include <vulkan/vulkan.h>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#include "hetoimasia_vulkan_proof.h"

/* GLFW reports failures through a callback rather than a return value, so the
 * most recent description is kept here for the Haskell side to read after a
 * call that failed. One slot is enough: every call is made from the process
 * main thread, one at a time. */
static char last_error[512] = {0};

static void record_error(int code, const char *description)
{
  snprintf(last_error, sizeof last_error, "GLFW error %d: %s", code,
           description ? description : "(no description)");
}

const char *hetoimasia_proof_last_error(void)
{
  return last_error;
}

int hetoimasia_proof_init_vulkan_loader(void *entry)
{
  /* Must precede glfwInit: GLFW resolves its loader during initialization and
   * ignores a later choice. Handing it the binding's own entry point is what
   * makes "one shared loader" true by construction rather than by two
   * independent searches agreeing. */
  glfwInitVulkanLoader((PFN_vkGetInstanceProcAddr) entry);
  return 1;
}

int hetoimasia_proof_glfw_init(void)
{
  last_error[0] = '\0';
  glfwSetErrorCallback(record_error);
  return glfwInit();
}

void hetoimasia_proof_glfw_terminate(void)
{
  glfwTerminate();
}

int hetoimasia_proof_vulkan_supported(void)
{
  return glfwVulkanSupported();
}

void *hetoimasia_proof_instance_proc_address(void *instance, const char *name)
{
  return (void *) glfwGetInstanceProcAddress((VkInstance) instance, name);
}

int hetoimasia_proof_required_extensions(char *out, size_t capacity, size_t stride)
{
  uint32_t count = 0;
  const char **names = glfwGetRequiredInstanceExtensions(&count);
  if (names == NULL) {
    return -1;
  }
  for (uint32_t index = 0; index < count && index < capacity; index++) {
    char *slot = out + (size_t) index * stride;
    size_t length = strlen(names[index]);
    if (length >= stride) {
      length = stride - 1;
    }
    memcpy(slot, names[index], length);
    slot[length] = '\0';
  }
  return (int) count;
}

hetoimasia_proof_window *hetoimasia_proof_create_window(int width, int height, const char *title)
{
  GLFWwindow *window;
  glfwDefaultWindowHints();
  /* No client API: the surface is Vulkan's, and GLFW must not create a GL
   * context for it. */
  glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
  glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE);
  glfwWindowHint(GLFW_VISIBLE, GLFW_TRUE);
  /* The proof presents to this window; it does not want the desktop's focus
   * while it does. Where the platform cannot honour that, GLFW ignores it. */
  glfwWindowHint(GLFW_FOCUS_ON_SHOW, GLFW_FALSE);
  window = glfwCreateWindow(width, height, title, NULL, NULL);
  return (hetoimasia_proof_window *) window;
}

void hetoimasia_proof_destroy_window(hetoimasia_proof_window *window)
{
  glfwDestroyWindow((GLFWwindow *) window);
}

void hetoimasia_proof_poll_events(void)
{
  glfwPollEvents();
}

int hetoimasia_proof_create_window_surface(void *instance,
                                           hetoimasia_proof_window *window,
                                           uint64_t *surface)
{
  VkSurfaceKHR created = VK_NULL_HANDLE;
  VkResult result = glfwCreateWindowSurface((VkInstance) instance,
                                            (GLFWwindow *) window, NULL, &created);
  /* Every Vulkan platform this proof runs on defines a non-dispatchable handle
   * as 64 bits wide, so the handle crosses as a uint64_t rather than as a
   * pointer whose width would differ. The static assertion below is what makes
   * that a checked assumption. */
  *surface = (uint64_t) created;
  return (int) result;
}

_Static_assert(sizeof(VkSurfaceKHR) == sizeof(uint64_t),
               "this proof assumes a 64-bit non-dispatchable Vulkan handle");

int hetoimasia_proof_image_of(const void *address, char *image, size_t image_capacity,
                              char *symbol, size_t symbol_capacity)
{
  Dl_info info;
  if (image_capacity > 0) {
    image[0] = '\0';
  }
  if (symbol_capacity > 0) {
    symbol[0] = '\0';
  }
  if (address == NULL) {
    return 0;
  }
  memset(&info, 0, sizeof info);
  if (dladdr(address, &info) == 0) {
    return 0;
  }
  if (info.dli_fname != NULL && image_capacity > 0) {
    snprintf(image, image_capacity, "%s", info.dli_fname);
  }
  if (info.dli_sname != NULL && symbol_capacity > 0) {
    snprintf(symbol, symbol_capacity, "%s", info.dli_sname);
  }
  return 1;
}
