/*
 * Test-only Wayland helpers for glfw-native-tests; see the header.
 *
 * Only Linux carries a Wayland backend. Elsewhere both helpers answer
 * HETOIMASIA_TEST_UNSUPPORTED_PLATFORM and call nothing, so the suite still
 * links on macOS, where the Wayland examples are reported pending.
 */
#include "hetoimasia_glfw_test.h"

#if defined(__linux__)

#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stddef.h>

/* Declared as GLFW's own headers declare them, with incomplete struct types,
 * as the production shim does: this file needs neither the GLFW nor the
 * Wayland client headers for pointers it never dereferences. */
struct wl_display;
struct wl_event_queue;
extern int glfwGetPlatform(void);
extern struct wl_display* glfwGetWaylandDisplay(void);

/* GLFW_PLATFORM_WAYLAND, from GLFW 3.4's glfw3.h. */
#define TEST_GLFW_PLATFORM_WAYLAND 0x00060003

static pthread_once_t symbols_once = PTHREAD_ONCE_INIT;
static int symbols_resolution = HETOIMASIA_TEST_NO_LIBRARY;
static struct wl_event_queue* (*create_queue)(struct wl_display*) = NULL;
static int (*roundtrip_queue)(struct wl_display*, struct wl_event_queue*) = NULL;
static void (*destroy_queue)(struct wl_event_queue*) = NULL;
static int (*display_flush)(struct wl_display*) = NULL;
static int (*display_fd)(struct wl_display*) = NULL;

static void resolve_symbols(void)
{
    void* library = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (library == NULL) {
        symbols_resolution = HETOIMASIA_TEST_NO_LIBRARY;
        return;
    }
    create_queue = (struct wl_event_queue* (*)(struct wl_display*)) dlsym(library, "wl_display_create_queue");
    roundtrip_queue = (int (*)(struct wl_display*, struct wl_event_queue*)) dlsym(library, "wl_display_roundtrip_queue");
    destroy_queue = (void (*)(struct wl_event_queue*)) dlsym(library, "wl_event_queue_destroy");
    display_flush = (int (*)(struct wl_display*)) dlsym(library, "wl_display_flush");
    display_fd = (int (*)(struct wl_display*)) dlsym(library, "wl_display_get_fd");
    symbols_resolution =
        create_queue != NULL && roundtrip_queue != NULL && destroy_queue != NULL
            && display_flush != NULL && display_fd != NULL
        ? HETOIMASIA_TEST_READY
        : HETOIMASIA_TEST_NO_SYMBOL;
}

/* The live session's display. glfwGetWaylandDisplay would report
 * GLFW_PLATFORM_UNAVAILABLE on another platform, so the platform is asked
 * first. */
static int wayland_display(struct wl_display** display)
{
    pthread_once(&symbols_once, resolve_symbols);
    if (symbols_resolution != HETOIMASIA_TEST_READY)
        return symbols_resolution;
    if (glfwGetPlatform() != TEST_GLFW_PLATFORM_WAYLAND)
        return HETOIMASIA_TEST_NOT_WAYLAND;
    *display = glfwGetWaylandDisplay();
    if (*display == NULL)
        return HETOIMASIA_TEST_NO_DISPLAY;
    return HETOIMASIA_TEST_READY;
}

/* The flush below is the only one here: wl_display_roundtrip_queue flushes as
 * part of dispatching, and it answers only once the sync it sent is done. */
int hetoimasia_glfw_test_wayland_barrier(int* error)
{
    struct wl_display* display = NULL;
    struct wl_event_queue* queue;
    int status;
    int result;
    *error = 0;
    status = wayland_display(&display);
    if (status != HETOIMASIA_TEST_READY)
        return status;
    queue = create_queue(display);
    if (queue == NULL) {
        *error = errno;
        return HETOIMASIA_TEST_FAILED;
    }
    result = roundtrip_queue(display, queue);
    if (result < 0)
        *error = errno;
    destroy_queue(queue);
    return result < 0 ? HETOIMASIA_TEST_FAILED : HETOIMASIA_TEST_READY;
}

int hetoimasia_glfw_test_wayland_flush_and_await_reply(int timeout_ms, int* error)
{
    struct wl_display* display = NULL;
    struct pollfd readable;
    int status;
    int ready;
    *error = 0;
    status = wayland_display(&display);
    if (status != HETOIMASIA_TEST_READY)
        return status;
    if (display_flush(display) < 0) {
        *error = errno;
        return HETOIMASIA_TEST_FAILED;
    }
    readable.fd = display_fd(display);
    readable.events = POLLIN;
    readable.revents = 0;
    do
        ready = poll(&readable, 1, timeout_ms);
    while (ready < 0 && errno == EINTR);
    if (ready < 0) {
        *error = errno;
        return HETOIMASIA_TEST_FAILED;
    }
    if (ready == 0)
        return HETOIMASIA_TEST_TIMED_OUT;
    if (readable.revents & POLLIN)
        return HETOIMASIA_TEST_READY;
    return HETOIMASIA_TEST_HANGUP;
}

#else

int hetoimasia_glfw_test_wayland_barrier(int* error)
{
    *error = 0;
    return HETOIMASIA_TEST_UNSUPPORTED_PLATFORM;
}

int hetoimasia_glfw_test_wayland_flush_and_await_reply(int timeout_ms, int* error)
{
    (void) timeout_ms;
    *error = 0;
    return HETOIMASIA_TEST_UNSUPPORTED_PLATFORM;
}

#endif
