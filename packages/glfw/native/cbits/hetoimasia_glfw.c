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
 * examples only. It asks the
 * platform to close a window the way its close button would, so GLFW's own
 * close callback reports a real native request.
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
 * reports the close request and answers NO, so nothing is closed. */
void hetoimasia_glfw_request_close_for_check(GLFWwindow* window)
{
    id handle = glfwGetCocoaWindow(window);
    if (handle != nil)
        ((void (*)(id, SEL, id)) objc_msgSend)(handle, sel_registerName("performClose:"), nil);
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

#elif defined(__linux__)
#define GLFW_EXPOSE_NATIVE_X11
#include <GLFW/glfw3native.h>
#include <X11/Xutil.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

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
 * adding a link requirement for the examples. */
void hetoimasia_glfw_request_close_for_check(GLFWwindow* window)
{
    Display* display = glfwGetX11Display();
    Window handle = glfwGetX11Window(window);
    void* xlib = dlopen("libX11.so.6", RTLD_LAZY | RTLD_LOCAL);
    if (xlib == NULL)
        return;
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
        sendEvent(display, handle, False, NoEventMask, &event);
        flush(display);
    }
    dlclose(xlib);
}

/* Read WM_NORMAL_HINTS through the same run-time libX11 the close driver uses. */
int hetoimasia_glfw_size_limits_for_check(GLFWwindow* window, int* limits)
{
    Display* display = glfwGetX11Display();
    Window handle = glfwGetX11Window(window);
    void* xlib = dlopen("libX11.so.6", RTLD_LAZY | RTLD_LOCAL);
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

void hetoimasia_glfw_request_close_for_check(GLFWwindow* window)
{
    (void) window;
}

int hetoimasia_glfw_size_limits_for_check(GLFWwindow* window, int* limits)
{
    (void) window;
    (void) limits;
    return 0;
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
 * in, and the wait reports, as it returns, whether a note named it. Nothing here
 * changes what GLFW does, and the production path never reads the note. */
static atomic_ulong wait_sequence = 0;
static atomic_ulong noted_wait = 0;
static atomic_int last_wait_noted = 0;

void hetoimasia_glfw_wait_events_timeout(double timeout)
{
    record_waiting_thread();
    unsigned long entered = atomic_fetch_add(&wait_sequence, 1) + 1;
    glfwWaitEventsTimeout(timeout);
    atomic_fetch_add(&wait_sequence, 1);
    atomic_store(&last_wait_noted, atomic_exchange(&noted_wait, 0) == entered);
}

/* A note lands only when the same wait's odd sequence number is read on both
 * sides of observing the waiting thread blocked in the kernel. The shim does no
 * blocking work before calling glfwWaitEventsTimeout, so that thread is blocked
 * inside GLFW's own wait, not in the call's entry. A stale note left by a wait
 * that has already returned is overwritten. */
int hetoimasia_glfw_note_progress_for_check(void)
{
    unsigned long sequence = atomic_load(&wait_sequence);
    if ((sequence & 1) == 0 || !waiting_thread_blocked() || atomic_load(&wait_sequence) != sequence)
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
