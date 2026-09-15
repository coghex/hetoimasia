/*
 * The native shim.
 *
 * The thread-identity function holds no state, queues nothing, and calls no
 * GLFW function: it answers whether the calling OS thread is the process main
 * thread, which a Haskell ThreadId or a bound thread cannot establish.
 *
 * The close-request driver exists for the native examples only. It asks the
 * platform to close a window the way its close button would, so GLFW's own
 * close callback reports a real native request.
 */
#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "hetoimasia_glfw.h"

#if defined(__APPLE__)
#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3native.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>

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

#elif defined(__linux__)
#define GLFW_EXPOSE_NATIVE_X11
#include <GLFW/glfw3native.h>
#include <dlfcn.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

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

#else

/* No supported platform: no thread is accepted as the session owner. */
int hetoimasia_glfw_is_process_main_thread(void)
{
    return 0;
}

void hetoimasia_glfw_request_close_for_check(GLFWwindow* window)
{
    (void) window;
}

#endif
