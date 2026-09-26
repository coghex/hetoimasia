/*
 * The native shim.
 *
 * The thread-identity function holds no state, queues nothing, and calls no
 * GLFW function: it answers whether the calling OS thread is the process main
 * thread, which a Haskell ThreadId or a bound thread cannot establish.
 *
 * The monitor accessors only change the pointer types GLFW returns to the ones
 * the generated import wrappers declare, and the video mode copier reads one
 * GLFWvidmode through the header's own declaration, so the binding never
 * assumes the structure's layout.
 *
 * The close-request driver and the size-limit query exist for the native
 * examples only. The first asks the
 * platform to close a window the way its close button would, so GLFW's own
 * close callback reports a real native request. Both reach the window through
 * a Cocoa or X11 handle, so both check the selected platform before asking
 * GLFW for one and answer unavailable rather than provoking a
 * GLFW_PLATFORM_UNAVAILABLE report the session would capture. An unavailable
 * answer is this shim's, not the window's: closure and size constraints are
 * GLFW's own on every backend.
 *
 * The Wayland connection-status probe is production code, and the one
 * production path here that reaches a native Wayland object; see the header.
 * Only Linux carries it. It is not declared through glfw3native.h, which would
 * pull in the Wayland client headers for one pointer the shim never
 * dereferences: glfwGetWaylandDisplay is declared below with an incomplete
 * struct type, exactly as GLFW's own header declares it.
 */
#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "hetoimasia_glfw.h"

#include <stdatomic.h>

/* Platform facts the wait's observation needs: which OS thread is waiting, and
 * whether that thread is blocked in the kernel. Defined per platform below. */
static void record_waiting_thread(void);
static int waiting_thread_blocked(void);

#if defined(__APPLE__)
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>
#include <mach/mach.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <float.h>

static atomic_uint waiting_thread = MACH_PORT_NULL;

static void record_waiting_thread(void)
{
    atomic_store(&waiting_thread, pthread_mach_thread_np(pthread_self()));
}

/* Blocked, not merely descheduled: the kernel reports the thread waiting. */
static int waiting_thread_blocked(void)
{
    mach_port_t thread = atomic_load(&waiting_thread);
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (thread == MACH_PORT_NULL
        || thread_info(thread, THREAD_BASIC_INFO, (thread_info_t) &info, &count) != KERN_SUCCESS)
        return 0;
    return info.run_state == TH_STATE_WAITING;
}

int hetoimasia_glfw_is_process_main_thread(void)
{
    return pthread_main_np() != 0;
}

/* performClose: sends windowShouldClose: to GLFW's window delegate, which
 * reports the close request and answers NO, so nothing is closed. Zero says
 * this helper could not deliver the request, not that the window refused it. */
int hetoimasia_glfw_request_close_for_check(GLFWwindow* window)
{
    id handle = glfwGetCocoaWindow(window);
    if (handle == nil)
        return 0;
    ((void (*)(id, SEL, id)) objc_msgSend)(handle, sel_registerName("performClose:"), nil);
    return 1;
}

/* NSSize is two CGFloats, doubles on every 64-bit Cocoa platform, and both
 * arm64 and x86_64 return it in registers through plain objc_msgSend. */
typedef struct { double width; double height; } content_size;

static int content_bound(double value)
{
    return value <= 0 || value >= FLT_MAX ? -1 : (int) value;
}

int hetoimasia_glfw_size_limits_for_check(GLFWwindow* window, int* limits)
{
    id handle = glfwGetCocoaWindow(window);
    if (handle == nil)
        return 0;
    content_size minimum = ((content_size (*)(id, SEL)) objc_msgSend)(handle, sel_registerName("contentMinSize"));
    content_size maximum = ((content_size (*)(id, SEL)) objc_msgSend)(handle, sel_registerName("contentMaxSize"));
    limits[0] = content_bound(minimum.width);
    limits[1] = content_bound(minimum.height);
    limits[2] = content_bound(maximum.width);
    limits[3] = content_bound(maximum.height);
    return 1;
}

/* No Wayland on Cocoa: a Wayland session is refused before initialization, and
 * the probe answers unavailable if asked. */
int hetoimasia_glfw_wayland_probe_resolve(void)
{
    return HETOIMASIA_PROBE_UNSUPPORTED_PLATFORM;
}

int hetoimasia_glfw_wayland_connection_status(int* reason, int* error)
{
    *reason = HETOIMASIA_PROBE_UNSUPPORTED_PLATFORM;
    *error = 0;
    return HETOIMASIA_CONNECTION_PROBE_FAILED;
}

#elif defined(__linux__)
#define GLFW_EXPOSE_NATIVE_X11
#include <GLFW/glfw3native.h>
#include <X11/Xutil.h>
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

struct wl_display;
GLFWAPI struct wl_display* glfwGetWaylandDisplay(void);

static atomic_int waiting_thread = 0;

static void record_waiting_thread(void)
{
    atomic_store(&waiting_thread, (int) syscall(SYS_gettid));
}

/* Blocked in an interruptible sleep, as poll(2) inside GLFW's wait is: the
 * state letter that follows the parenthesized command name is S. */
static int waiting_thread_blocked(void)
{
    char path[64];
    char stat[512];
    snprintf(path, sizeof path, "/proc/self/task/%d/stat", atomic_load(&waiting_thread));
    FILE* file = fopen(path, "r");
    if (file == NULL)
        return 0;
    size_t length = fread(stat, 1, sizeof stat - 1, file);
    fclose(file);
    stat[length] = '\0';
    char* name_end = strrchr(stat, ')');
    return name_end != NULL && name_end[1] == ' ' && name_end[2] == 'S';
}

/* The initial thread's kernel thread id is the process id. */
int hetoimasia_glfw_is_process_main_thread(void)
{
    return (pid_t) syscall(SYS_gettid) == getpid();
}

/* Send the WM_DELETE_WINDOW client message a window manager sends for the
 * close button. GLFW 3.4 loads libX11 at run time rather than linking it, so
 * the three Xlib functions are looked up in that same library instead of
 * adding a link requirement for the examples.
 *
 * The X11 accessors are asked for nothing unless GLFW selected X11: on any
 * other platform glfwGetX11Display answers GLFW_PLATFORM_UNAVAILABLE, and the
 * session would capture that report as a native failure. So the platform is
 * checked first — glfwGetPlatform reports no error — and this helper simply
 * answers unavailable. That is this driver being unavailable, not window
 * closure: on a Wayland session a compositor-generated close request has not
 * been demonstrated yet. */
int hetoimasia_glfw_request_close_for_check(GLFWwindow* window)
{
    Display* display;
    Window handle;
    void* xlib;
    int delivered = 0;
    if (glfwGetPlatform() != GLFW_PLATFORM_X11)
        return 0;
    display = glfwGetX11Display();
    handle = glfwGetX11Window(window);
    xlib = dlopen("libX11.so.6", RTLD_LAZY | RTLD_LOCAL);
    if (xlib == NULL)
        return 0;
    Atom (*internAtom)(Display*, const char*, Bool) = dlsym(xlib, "XInternAtom");
    Status (*sendEvent)(Display*, Window, Bool, long, XEvent*) = dlsym(xlib, "XSendEvent");
    int (*flush)(Display*) = dlsym(xlib, "XFlush");
    if (display != NULL && handle != None && internAtom != NULL && sendEvent != NULL && flush != NULL) {
        XEvent event;
        memset(&event, 0, sizeof event);
        event.xclient.type = ClientMessage;
        event.xclient.window = handle;
        event.xclient.message_type = internAtom(display, "WM_PROTOCOLS", False);
        event.xclient.format = 32;
        event.xclient.data.l[0] = (long) internAtom(display, "WM_DELETE_WINDOW", False);
        event.xclient.data.l[1] = CurrentTime;
        /* XSendEvent answers zero when it could not convert and send the
         * event. Reporting success then would be the false success this
         * result exists to remove: an example would wait for a close request
         * the server was never asked for. */
        delivered = sendEvent(display, handle, False, NoEventMask, &event) != 0;
        if (delivered)
            flush(display);
    }
    dlclose(xlib);
    return delivered;
}

/* Read WM_NORMAL_HINTS through the same run-time libX11 the close driver uses,
 * behind the same platform check: zero says this helper could not read the
 * limits, never that the window holds none. */
int hetoimasia_glfw_size_limits_for_check(GLFWwindow* window, int* limits)
{
    Display* display;
    Window handle;
    void* xlib;
    if (glfwGetPlatform() != GLFW_PLATFORM_X11)
        return 0;
    display = glfwGetX11Display();
    handle = glfwGetX11Window(window);
    xlib = dlopen("libX11.so.6", RTLD_LAZY | RTLD_LOCAL);
    if (xlib == NULL)
        return 0;
    XSizeHints* (*allocHints)(void) = dlsym(xlib, "XAllocSizeHints");
    Status (*getHints)(Display*, Window, XSizeHints*, long*) = dlsym(xlib, "XGetWMNormalHints");
    int (*release)(void*) = dlsym(xlib, "XFree");
    int answered = 0;
    if (display != NULL && handle != None && allocHints != NULL && getHints != NULL && release != NULL) {
        XSizeHints* hints = allocHints();
        long supplied = 0;
        if (hints != NULL && getHints(display, handle, hints, &supplied)) {
            limits[0] = (hints->flags & PMinSize) ? hints->min_width : -1;
            limits[1] = (hints->flags & PMinSize) ? hints->min_height : -1;
            limits[2] = (hints->flags & PMaxSize) ? hints->max_width : -1;
            limits[3] = (hints->flags & PMaxSize) ? hints->max_height : -1;
            answered = 1;
        }
        if (hints != NULL)
            release(hints);
    }
    dlclose(xlib);
    return answered;
}

/* The two libwayland-client functions the probe reads through, resolved once
 * per process. The library is the one GLFW 3.4 loads at run time rather than
 * links, so dlopen answers GLFW's own handle; it is never closed, which keeps
 * the symbols valid through the final query of the last session. */
static pthread_once_t probe_once = PTHREAD_ONCE_INIT;
static int probe_resolution = HETOIMASIA_PROBE_NO_LIBRARY;
static int (*probe_display_error)(struct wl_display*) = NULL;
static int (*probe_display_fd)(struct wl_display*) = NULL;

static void resolve_probe_symbols(void)
{
    void* library = dlopen("libwayland-client.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (library == NULL) {
        probe_resolution = HETOIMASIA_PROBE_NO_LIBRARY;
        return;
    }
    probe_display_error = (int (*)(struct wl_display*)) dlsym(library, "wl_display_get_error");
    probe_display_fd = (int (*)(struct wl_display*)) dlsym(library, "wl_display_get_fd");
    probe_resolution = probe_display_error != NULL && probe_display_fd != NULL
        ? HETOIMASIA_PROBE_READY
        : HETOIMASIA_PROBE_NO_SYMBOL;
}

/* glfwGetPlatform reports no error, so the platform is asked first and
 * glfwGetWaylandDisplay, which would report GLFW_PLATFORM_UNAVAILABLE on
 * another platform, is called only on Wayland. */
int hetoimasia_glfw_wayland_probe_resolve(void)
{
    pthread_once(&probe_once, resolve_probe_symbols);
    if (probe_resolution != HETOIMASIA_PROBE_READY)
        return probe_resolution;
    if (glfwGetPlatform() != GLFW_PLATFORM_WAYLAND)
        return HETOIMASIA_PROBE_NOT_WAYLAND;
    if (glfwGetWaylandDisplay() == NULL)
        return HETOIMASIA_PROBE_NO_DISPLAY;
    return HETOIMASIA_PROBE_READY;
}

/* The latched error is read first. libwayland latches EPROTO for a protocol
 * error the compositor sent and the transport's errno — EPIPE for a read that
 * found the socket closed — for a transport failure, so a non-zero answer
 * names its own cause. It is not enough alone: a flush that fails with EPIPE
 * deliberately latches nothing in libwayland 1.22, which is exactly the path
 * GLFW's disconnect handling takes. So the socket is then polled with a zero
 * timeout for hangup, which reports the peer's closure without consuming any
 * protocol data: POLLIN is not requested, and POLLHUP and POLLERR are always
 * reported. */
int hetoimasia_glfw_wayland_connection_status(int* reason, int* error)
{
    struct wl_display* display;
    struct pollfd status;
    int latched;
    int descriptor;
    int ready;
    *reason = HETOIMASIA_PROBE_READY;
    *error = 0;
    pthread_once(&probe_once, resolve_probe_symbols);
    if (probe_resolution != HETOIMASIA_PROBE_READY) {
        *reason = probe_resolution;
        return HETOIMASIA_CONNECTION_PROBE_FAILED;
    }
    if (glfwGetPlatform() != GLFW_PLATFORM_WAYLAND) {
        *reason = HETOIMASIA_PROBE_NOT_WAYLAND;
        return HETOIMASIA_CONNECTION_PROBE_FAILED;
    }
    display = glfwGetWaylandDisplay();
    if (display == NULL) {
        *reason = HETOIMASIA_PROBE_NO_DISPLAY;
        return HETOIMASIA_CONNECTION_PROBE_FAILED;
    }
    latched = probe_display_error(display);
    if (latched == EPROTO) {
        *error = latched;
        return HETOIMASIA_CONNECTION_PROTOCOL_FAILURE;
    }
    if (latched != 0) {
        *error = latched;
        return HETOIMASIA_CONNECTION_TRANSPORT_CLOSED;
    }
    descriptor = probe_display_fd(display);
    if (descriptor < 0) {
        *reason = HETOIMASIA_PROBE_NO_DESCRIPTOR;
        return HETOIMASIA_CONNECTION_PROBE_FAILED;
    }
    status.fd = descriptor;
    status.events = POLLRDHUP;
    status.revents = 0;
    do
        ready = poll(&status, 1, 0);
    while (ready < 0 && errno == EINTR);
    if (ready < 0) {
        *reason = HETOIMASIA_PROBE_POLL_FAILED;
        *error = errno;
        return HETOIMASIA_CONNECTION_PROBE_FAILED;
    }
    if (status.revents & POLLNVAL) {
        *reason = HETOIMASIA_PROBE_INVALID_DESCRIPTOR;
        return HETOIMASIA_CONNECTION_PROBE_FAILED;
    }
    if (status.revents & (POLLHUP | POLLRDHUP | POLLERR))
        return HETOIMASIA_CONNECTION_TRANSPORT_CLOSED;
    return HETOIMASIA_CONNECTION_HEALTHY;
}

#else

/* No supported platform: no thread is accepted as the session owner. */
int hetoimasia_glfw_is_process_main_thread(void)
{
    return 0;
}

static void record_waiting_thread(void)
{
}

static int waiting_thread_blocked(void)
{
    return 0;
}

int hetoimasia_glfw_request_close_for_check(GLFWwindow* window)
{
    (void) window;
    return 0;
}

int hetoimasia_glfw_size_limits_for_check(GLFWwindow* window, int* limits)
{
    (void) window;
    (void) limits;
    return 0;
}

int hetoimasia_glfw_wayland_probe_resolve(void)
{
    return HETOIMASIA_PROBE_UNSUPPORTED_PLATFORM;
}

int hetoimasia_glfw_wayland_connection_status(int* reason, int* error)
{
    *reason = HETOIMASIA_PROBE_UNSUPPORTED_PLATFORM;
    *error = 0;
    return HETOIMASIA_CONNECTION_PROBE_FAILED;
}

#endif

void** hetoimasia_glfw_monitors(int* count)
{
    return (void**) glfwGetMonitors(count);
}

char* hetoimasia_glfw_monitor_name(GLFWmonitor* monitor)
{
    return (char*) glfwGetMonitorName(monitor);
}

void* hetoimasia_glfw_video_mode(GLFWmonitor* monitor)
{
    return (void*) glfwGetVideoMode(monitor);
}

void* hetoimasia_glfw_video_modes(GLFWmonitor* monitor, int* count)
{
    return (void*) glfwGetVideoModes(monitor, count);
}

char* hetoimasia_glfw_window_title(GLFWwindow* window)
{
    return (char*) glfwGetWindowTitle(window);
}

void hetoimasia_glfw_inject_key_for_check(GLFWwindow* window, int key, int scancode, int action, int mods)
{
    GLFWkeyfun callback = glfwSetKeyCallback(window, NULL);
    glfwSetKeyCallback(window, callback);
    if (callback != NULL)
        callback(window, key, scancode, action, mods);
}

void hetoimasia_glfw_inject_char_for_check(GLFWwindow* window, unsigned int codepoint)
{
    GLFWcharfun callback = glfwSetCharCallback(window, NULL);
    glfwSetCharCallback(window, callback);
    if (callback != NULL)
        callback(window, codepoint);
}

void hetoimasia_glfw_inject_mouse_button_for_check(GLFWwindow* window, int button, int action, int mods)
{
    GLFWmousebuttonfun callback = glfwSetMouseButtonCallback(window, NULL);
    glfwSetMouseButtonCallback(window, callback);
    if (callback != NULL)
        callback(window, button, action, mods);
}

void hetoimasia_glfw_inject_cursor_pos_for_check(GLFWwindow* window, double x, double y)
{
    GLFWcursorposfun callback = glfwSetCursorPosCallback(window, NULL);
    glfwSetCursorPosCallback(window, callback);
    if (callback != NULL)
        callback(window, x, y);
}

void hetoimasia_glfw_inject_cursor_enter_for_check(GLFWwindow* window, int entered)
{
    GLFWcursorenterfun callback = glfwSetCursorEnterCallback(window, NULL);
    glfwSetCursorEnterCallback(window, callback);
    if (callback != NULL)
        callback(window, entered);
}

void hetoimasia_glfw_inject_scroll_for_check(GLFWwindow* window, double x, double y)
{
    GLFWscrollfun callback = glfwSetScrollCallback(window, NULL);
    glfwSetScrollCallback(window, callback);
    if (callback != NULL)
        callback(window, x, y);
}

void hetoimasia_glfw_inject_focus_for_check(GLFWwindow* window, int focused)
{
    GLFWwindowfocusfun callback = glfwSetWindowFocusCallback(window, NULL);
    glfwSetWindowFocusCallback(window, callback);
    if (callback != NULL)
        callback(window, focused);
}

void hetoimasia_glfw_inject_close_for_check(GLFWwindow* window)
{
    GLFWwindowclosefun callback = glfwSetWindowCloseCallback(window, NULL);
    glfwSetWindowCloseCallback(window, callback);
    if (callback != NULL)
        callback(window);
}

static atomic_int last_input_callbacks_cleared = 0;

int hetoimasia_glfw_input_callbacks_cleared_for_check(GLFWwindow* window)
{
    GLFWkeyfun key = glfwSetKeyCallback(window, NULL);
    glfwSetKeyCallback(window, key);
    GLFWcharfun character = glfwSetCharCallback(window, NULL);
    glfwSetCharCallback(window, character);
    GLFWmousebuttonfun button = glfwSetMouseButtonCallback(window, NULL);
    glfwSetMouseButtonCallback(window, button);
    GLFWcursorposfun cursor = glfwSetCursorPosCallback(window, NULL);
    glfwSetCursorPosCallback(window, cursor);
    GLFWcursorenterfun enter = glfwSetCursorEnterCallback(window, NULL);
    glfwSetCursorEnterCallback(window, enter);
    GLFWscrollfun scroll = glfwSetScrollCallback(window, NULL);
    glfwSetScrollCallback(window, scroll);
    return key == NULL && character == NULL && button == NULL
        && cursor == NULL && enter == NULL && scroll == NULL;
}

void hetoimasia_glfw_note_input_callbacks_before_destroy(GLFWwindow* window)
{
    atomic_store(&last_input_callbacks_cleared,
        hetoimasia_glfw_input_callbacks_cleared_for_check(window));
}

int hetoimasia_glfw_take_input_callbacks_cleared_for_check(void)
{
    return atomic_exchange(&last_input_callbacks_cleared, 0);
}

void hetoimasia_glfw_video_mode_at(const GLFWvidmode* modes, int index, int* fields)
{
    const GLFWvidmode* mode = &modes[index];
    fields[0] = mode->width;
    fields[1] = mode->height;
    fields[2] = mode->redBits;
    fields[3] = mode->greenBits;
    fields[4] = mode->blueBits;
    fields[5] = mode->refreshRate;
}

/* The production finite event wait, and what the native examples may observe
 * of it.
 *
 * wait_sequence is odd while an owner is inside this call and even otherwise,
 * so each wait has its own odd number. A progress note names the wait it landed
 * in, and the wait reports, as it returns, whether a note named it. A production
 * wake records the wait in progress as it posts, and the wait reports, as it
 * returns, whether a wake named it. Nothing here changes what GLFW does, and the
 * production path never reads what is recorded. */
static atomic_ulong wait_sequence = 0;
static atomic_ulong noted_wait = 0;
static atomic_int last_wait_noted = 0;
static atomic_ulong woken_wait = 0;
static atomic_ulong last_wait = 0;
static atomic_int last_wait_woken = 0;
static atomic_ulong wakes_entered = 0;
static atomic_ulong wakes_returned = 0;

void hetoimasia_glfw_wait_events_timeout(double timeout)
{
    record_waiting_thread();
    unsigned long entered = atomic_fetch_add(&wait_sequence, 1) + 1;
    glfwWaitEventsTimeout(timeout);
    atomic_fetch_add(&wait_sequence, 1);
    atomic_store(&last_wait_noted, atomic_exchange(&noted_wait, 0) == entered);
    atomic_store(&last_wait_woken, atomic_exchange(&woken_wait, 0) == entered);
    atomic_store(&last_wait, entered);
}

/* The wait in progress, only while its thread is blocked in the kernel: the same
 * odd sequence number is read on both sides of observing it. The shim does no
 * blocking work before calling glfwWaitEventsTimeout, so that thread is blocked
 * inside GLFW's own wait, not in the call's entry. */
static unsigned long blocked_wait(void)
{
    unsigned long sequence = atomic_load(&wait_sequence);
    if ((sequence & 1) == 0 || !waiting_thread_blocked() || atomic_load(&wait_sequence) != sequence)
        return 0;
    return sequence;
}

/* A note lands only in a blocked wait. A stale note left by a wait that has
 * already returned is overwritten. */
int hetoimasia_glfw_note_progress_for_check(void)
{
    unsigned long sequence = blocked_wait();
    if (sequence == 0)
        return 0;
    unsigned long seen = atomic_load(&noted_wait);
    while (seen != sequence)
        if (atomic_compare_exchange_weak(&noted_wait, &seen, sequence)) {
            glfwPostEmptyEvent();
            return 1;
        }
    return 0;
}

int hetoimasia_glfw_take_wait_noted_for_check(void)
{
    return atomic_exchange(&last_wait_noted, 0);
}

unsigned long hetoimasia_glfw_blocked_wait_for_check(void)
{
    return blocked_wait();
}

unsigned long hetoimasia_glfw_take_last_wait_for_check(int* woken)
{
    *woken = atomic_exchange(&last_wait_woken, 0);
    return atomic_load(&last_wait);
}

void hetoimasia_glfw_wake_counts_for_check(unsigned long* entered, unsigned long* returned)
{
    *entered = atomic_load(&wakes_entered);
    *returned = atomic_load(&wakes_returned);
}

/* The production wake. The mark, the post, and the error state it reads all
 * belong to the calling thread, so what the error callback attributes to the
 * mark and the code returned describe this call alone. */
static _Thread_local unsigned long long current_wake_mark = 0;

unsigned long long hetoimasia_glfw_current_wake_mark(void)
{
    return current_wake_mark;
}

int hetoimasia_glfw_post_empty_event(unsigned long long mark)
{
    glfwGetError(NULL);
    atomic_fetch_add(&wakes_entered, 1);
    atomic_store(&woken_wait, atomic_load(&wait_sequence));
    current_wake_mark = mark;
    glfwPostEmptyEvent();
    current_wake_mark = 0;
    atomic_fetch_add(&wakes_returned, 1);
    return glfwGetError(NULL);
}
