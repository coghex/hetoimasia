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
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

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
    symbols_resolution =
        create_queue != NULL && roundtrip_queue != NULL && destroy_queue != NULL
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

/* barrier_sequence is odd while a barrier is in progress, so each barrier has
 * its own odd number; barrier_thread is the kernel thread running it. */
static atomic_ulong barrier_sequence = 0;
static atomic_int barrier_thread = 0;

/* Blocked in an interruptible sleep, as poll(2) inside libwayland's round-trip
 * is: the state letter after the parenthesized command name is S. */
static int thread_blocked(int thread)
{
    char path[64];
    char stat[512];
    FILE* file;
    size_t length;
    char* name_end;
    snprintf(path, sizeof path, "/proc/self/task/%d/stat", thread);
    file = fopen(path, "r");
    if (file == NULL)
        return 0;
    length = fread(stat, 1, sizeof stat - 1, file);
    fclose(file);
    stat[length] = '\0';
    name_end = strrchr(stat, ')');
    return name_end != NULL && name_end[1] == ' ' && name_end[2] == 'S';
}

/* wl_display_roundtrip_queue flushes as part of dispatching, and answers only
 * once the sync it sent on the private queue is done. */
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
    atomic_store(&barrier_thread, (int) syscall(SYS_gettid));
    atomic_fetch_add(&barrier_sequence, 1);
    result = roundtrip_queue(display, queue);
    if (result < 0)
        *error = errno;
    atomic_fetch_add(&barrier_sequence, 1);
    destroy_queue(queue);
    return result < 0 ? HETOIMASIA_TEST_FAILED : HETOIMASIA_TEST_READY;
}

unsigned long hetoimasia_glfw_test_blocked_barrier(void)
{
    unsigned long sequence = atomic_load(&barrier_sequence);
    if ((sequence & 1) == 0 || !thread_blocked(atomic_load(&barrier_thread))
        || atomic_load(&barrier_sequence) != sequence)
        return 0;
    return sequence;
}

#else

int hetoimasia_glfw_test_wayland_barrier(int* error)
{
    *error = 0;
    return HETOIMASIA_TEST_UNSUPPORTED_PLATFORM;
}

unsigned long hetoimasia_glfw_test_blocked_barrier(void)
{
    return 0;
}

#endif
