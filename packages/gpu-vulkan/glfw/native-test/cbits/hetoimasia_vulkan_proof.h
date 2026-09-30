/* The proof harness's throwaway GLFW/Vulkan interop shim.
 *
 * GLFW 3.4 guards `glfwInitVulkanLoader`, `glfwGetInstanceProcAddress`, and
 * `glfwCreateWindowSurface` behind `VK_VERSION_1_0`, so reaching them needs
 * Vulkan headers in the translation unit that calls them. The engine's own
 * `hetoimasia-glfw` native library compiles with `GLFW_INCLUDE_NONE` and must
 * keep doing so: an ordinary GLFW client does not gain a Vulkan SDK
 * requirement because this proof exists. So the three calls live here instead,
 * in a shim that is part of the qualification harness and not of any library.
 *
 * VK-5 designs the production surface bridge. Nothing here is that bridge, and
 * nothing here is a public API.
 */
#ifndef HETOIMASIA_VULKAN_PROOF_H
#define HETOIMASIA_VULKAN_PROOF_H

#include <stddef.h>
#include <stdint.h>

/* An opaque GLFW window, so the Haskell side never names a GLFW type. */
typedef struct hetoimasia_proof_window hetoimasia_proof_window;

/* Hand GLFW the loader the Haskell binding already dispatches through, before
 * `glfwInit`. `entry` is that binding's own `vkGetInstanceProcAddr`. Checks no
 * initialization state and returns 1 unconditionally, so the return value
 * reports neither success nor whether GLFW was already initialized. */
int hetoimasia_proof_init_vulkan_loader(void *entry);

/* The platform a proof session asks GLFW for. `ANY` is GLFW's own default,
 * which on Linux these sessions have always taken; the others name one
 * platform, and a session that names one is never answered with another. */
#define HETOIMASIA_PROOF_PLATFORM_ANY 0
#define HETOIMASIA_PROOF_PLATFORM_WAYLAND 1
#define HETOIMASIA_PROOF_PLATFORM_X11 2
#define HETOIMASIA_PROOF_PLATFORM_COCOA 3

/* Clear the stored error description, install the shim's error callback, set
 * GLFW's platform initialization hint to `platform`, and initialize GLFW. A
 * named platform that initialization did not select is a failure: GLFW is
 * terminated again and the stored description says what it selected instead.
 * Returns 1 on success and 0 otherwise. Window hints, the client API among
 * them, belong to `hetoimasia_proof_create_window`. */
int hetoimasia_proof_glfw_init(int platform);

/* The platform the initialized GLFW selected, as a lower-case name ("wayland",
 * "x11", "cocoa", "win32", "null"), or "none" when GLFW is not initialized. */
const char *hetoimasia_proof_glfw_platform(void);

void hetoimasia_proof_glfw_terminate(void);

/* GLFW's own view of the Vulkan loader: whether it found one, and what it
 * resolves a name to. `instance` may be NULL. */
int hetoimasia_proof_vulkan_supported(void);
void *hetoimasia_proof_instance_proc_address(void *instance, const char *name);

/* The instance extensions GLFW requires for this platform's surfaces, copied
 * into `out` (at most `capacity` entries, each at most `stride` bytes
 * including the terminator). Returns the number GLFW reported, which may
 * exceed `capacity`; a negative return means GLFW reported none. */
int hetoimasia_proof_required_extensions(char *out, size_t capacity, size_t stride);

/* One small, visible, client-API-less window. Returns NULL on failure. */
hetoimasia_proof_window *hetoimasia_proof_create_window(int width, int height, const char *title);
void hetoimasia_proof_destroy_window(hetoimasia_proof_window *window);
void hetoimasia_proof_poll_events(void);

/* `glfwSetWindowSize`, in screen coordinates: the resize VK-13's native case
 * makes, whatever the window's resizable hint says about the user. */
void hetoimasia_proof_set_window_size(hetoimasia_proof_window *window, int width, int height);

/* `glfwGetFramebufferSize`, in pixels. */
void hetoimasia_proof_framebuffer_size(hetoimasia_proof_window *window, int *width, int *height);

/* `glfwCreateWindowSurface`. `surface` receives the non-dispatchable handle as
 * the 64-bit value every 64-bit Vulkan ABI gives it. Returns the `VkResult`. */
int hetoimasia_proof_create_window_surface(void *instance,
                                           hetoimasia_proof_window *window,
                                           uint64_t *surface);

/* The most recent GLFW error description, or the empty string. */
const char *hetoimasia_proof_last_error(void);

/* Image provenance for a resolved address: which loaded image defines it, and
 * under what symbol name. Writes at most `capacity` bytes including the
 * terminator and returns 1 when the address was attributed, 0 when it was not.
 *
 * This is what makes "the same loader" an observation rather than an
 * assumption: two independently found libraries can export the same symbol
 * name, but only one image can define the address a call actually reaches. */
int hetoimasia_proof_image_of(const void *address, char *image, size_t image_capacity,
                              char *symbol, size_t symbol_capacity);

/* The calling OS thread's identity, as `pthread_self` answers it, widened to 64
 * bits. VK-7's native cases record it at each native call, so which thread
 * made a call is an observation at the native boundary rather than a reading
 * of which Haskell thread asked. */
uint64_t hetoimasia_proof_os_thread(void);

#endif /* HETOIMASIA_VULKAN_PROOF_H */
