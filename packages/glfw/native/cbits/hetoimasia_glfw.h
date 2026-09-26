/*
 * The one header the private GLFW binding's foreign imports name.
 *
 * It includes the installed GLFW 3.4 header with no client API header, so every
 * constant and function declaration the binding uses comes from GLFW itself,
 * and declares the shim's functions beside it.
 */
#ifndef HETOIMASIA_GLFW_H
#define HETOIMASIA_GLFW_H

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

/* Non-zero when the calling OS thread is the one that entered the process
 * main function. It reads the thread's identity and nothing else. */
int hetoimasia_glfw_is_process_main_thread(void);

/* glfwGetMonitors, glfwGetMonitorName, glfwGetVideoMode, and glfwGetVideoModes,
 * returning the pointer types the Haskell imports' generated wrappers declare.
 * GLFW owns what they point to, and the binding only reads and copies it
 * before the calling operation returns. */
void** hetoimasia_glfw_monitors(int* count);
char* hetoimasia_glfw_monitor_name(GLFWmonitor* monitor);
void* hetoimasia_glfw_video_mode(GLFWmonitor* monitor);
void* hetoimasia_glfw_video_modes(GLFWmonitor* monitor, int* count);

/* glfwGetWindowTitle, returning the pointer type the Haskell import's generated
 * wrapper declares. GLFW owns the string; the native examples copy it at once. */
char* hetoimasia_glfw_window_title(GLFWwindow* window);

/* Copy the six fields of modes[index] — width, height, red, green, and blue
 * bits, and refresh rate, in that order — into fields. It calls no GLFW
 * function; the caller supplies an index below the count GLFW reported. */
void hetoimasia_glfw_video_mode_at(const GLFWvidmode* modes, int index, int* fields);

/* Ask the platform to close a window, as its close button would, for the
 * native examples only. GLFW reports the request through the window's close
 * callback and destroys nothing. Call it on the session's owner thread.
 *
 * Non-zero when the request was delivered. It is this helper that is
 * unavailable outside Cocoa and X11, not window closure itself: it drives the
 * close through the X11 or Cocoa handle GLFW exposes, and the session may run
 * on a backend that exposes neither. On a Wayland session it answers zero
 * before asking GLFW for any X11 handle, so no GLFW error is reported. No
 * compositor-generated close request has been demonstrated on Wayland yet. */
int hetoimasia_glfw_request_close_for_check(GLFWwindow* window);

/* Invoke the currently registered input callback through its C function
 * pointer, for the native examples only. Each helper reads the pointer GLFW
 * holds, restores it, and calls it, so the path is the trampoline the window
 * attached rather than a Haskell producer. Call them on the session's owner
 * thread. */
void hetoimasia_glfw_inject_key_for_check(GLFWwindow* window, int key, int scancode, int action, int mods);
void hetoimasia_glfw_inject_char_for_check(GLFWwindow* window, unsigned int codepoint);
void hetoimasia_glfw_inject_mouse_button_for_check(GLFWwindow* window, int button, int action, int mods);
void hetoimasia_glfw_inject_cursor_pos_for_check(GLFWwindow* window, double x, double y);
void hetoimasia_glfw_inject_cursor_enter_for_check(GLFWwindow* window, int entered);
void hetoimasia_glfw_inject_scroll_for_check(GLFWwindow* window, double x, double y);
void hetoimasia_glfw_inject_focus_for_check(GLFWwindow* window, int focused);

/* Invoke the window's registered close callback, for the native examples only:
 * an injected close request, never evidence of one the platform generated. It
 * reaches no platform handle, so it is available on every backend, and it is
 * how the Wayland examples exercise close-request handling that no client can
 * provoke from the compositor. Call it on the session's owner thread. */
void hetoimasia_glfw_inject_close_for_check(GLFWwindow* window);

/* Non-zero when every input callback slot is empty. The destroy path records
 * this immediately before glfwDestroyWindow; the native examples read it. */
int hetoimasia_glfw_input_callbacks_cleared_for_check(GLFWwindow* window);
void hetoimasia_glfw_note_input_callbacks_before_destroy(GLFWwindow* window);
int hetoimasia_glfw_take_input_callbacks_cleared_for_check(void);

/* For the native examples only: the size limits the platform holds for a
 * window, read back from the platform itself — contentMinSize and contentMaxSize
 * on Cocoa, WM_NORMAL_HINTS on X11 — into limits as minimum width and height,
 * then maximum width and height, with -1 for a bound the platform does not
 * hold. Non-zero when they were read. Call it on the session's owner thread.
 *
 * Zero says this helper could not read them, never that the window has no size
 * constraints: GLFW holds those whatever the backend, and this reads back only
 * what an X11 or Cocoa handle exposes. On a Wayland session it answers zero
 * before asking GLFW for any X11 handle, so no GLFW error is reported. */
int hetoimasia_glfw_size_limits_for_check(GLFWwindow* window, int* limits);

/* The private, read-only Wayland connection-status probe the Wayland
 * qualification design's D-13 permits in the production shim. It is the one
 * production path that reaches a native Wayland object, and it hands nothing
 * native back: only a status, a reason, and an errno, copied into ints.
 *
 * It uses glfwGetWaylandDisplay, wl_display_get_error, and wl_display_get_fd,
 * with a zero-timeout poll(2) of the display's socket for peer closure. It never
 * reads or dispatches protocol messages, flushes, creates windows, reconnects,
 * or closes GLFW's connection; GLFW stays the connection's owner. The two
 * libwayland symbols are resolved once per process from the library GLFW itself
 * loads, and that library is never closed, so they stay valid through the
 * final query. Call both functions on the session's owner thread while the
 * session is live. */
#define HETOIMASIA_CONNECTION_HEALTHY 0
#define HETOIMASIA_CONNECTION_TRANSPORT_CLOSED 1
#define HETOIMASIA_CONNECTION_PROTOCOL_FAILURE 2
#define HETOIMASIA_CONNECTION_PROBE_FAILED 3

/* Why the probe is unavailable or could not answer. */
#define HETOIMASIA_PROBE_READY 0
#define HETOIMASIA_PROBE_NO_LIBRARY 1
#define HETOIMASIA_PROBE_NO_SYMBOL 2
#define HETOIMASIA_PROBE_NOT_WAYLAND 3
#define HETOIMASIA_PROBE_NO_DISPLAY 4
#define HETOIMASIA_PROBE_NO_DESCRIPTOR 5
#define HETOIMASIA_PROBE_POLL_FAILED 6
#define HETOIMASIA_PROBE_INVALID_DESCRIPTOR 7
#define HETOIMASIA_PROBE_UNSUPPORTED_PLATFORM 8

/* Resolve the probe for the initialized session: HETOIMASIA_PROBE_READY when
 * it can answer, otherwise the reason it cannot. */
int hetoimasia_glfw_wayland_probe_resolve(void);

/* One status read: a HETOIMASIA_CONNECTION_ value. For a transport closure,
 * error is the errno the display latched, or zero when only the socket reported
 * the closure; for a protocol failure it is that latched errno; for a probe
 * failure, reason is a HETOIMASIA_PROBE_ value and error any errno behind it. */
int hetoimasia_glfw_wayland_connection_status(int* reason, int* error);

/* The production finite event wait: glfwWaitEventsTimeout, recording which OS
 * thread waits and a sequence number for each wait, which only the native
 * examples read. Call it on the session's owner thread. */
void hetoimasia_glfw_wait_events_timeout(double timeout);

/* The production cross-thread wake: glfwPostEmptyEvent, callable from any
 * thread while GLFW is initialized. For the duration of the call the calling
 * thread's wake mark is the one given, which the error callback reads on the
 * same thread with hetoimasia_glfw_current_wake_mark; the thread's GLFW error
 * state is cleared before the post and read after it, and the code read is the
 * answer, zero for none. It also records, for the native examples only, which
 * wait was in progress and how many calls entered and returned. */
int hetoimasia_glfw_post_empty_event(unsigned long long mark);

/* The wake mark of the post running on the calling thread, or zero. It reads
 * thread-local storage and calls nothing. */
unsigned long long hetoimasia_glfw_current_wake_mark(void);

/* For the native examples only: the odd sequence number of the production wait
 * in progress, if its thread is blocked inside GLFW's wait, otherwise zero. It
 * observes only; it posts nothing. */
unsigned long hetoimasia_glfw_blocked_wait_for_check(void);

/* For the native examples only: the sequence number of the most recent
 * production wait to return, and through woken whether a production wake was
 * posted while that wait was in progress, cleared by reading it. */
unsigned long hetoimasia_glfw_take_last_wait_for_check(int* woken);

/* For the native examples only: how many production wake calls have entered
 * glfwPostEmptyEvent and how many have returned from it, process-wide. */
void hetoimasia_glfw_wake_counts_for_check(unsigned long* entered, unsigned long* returned);

/* For the native examples only: record progress in the wait in progress, only
 * while its thread is blocked inside GLFW's wait, and wake that wait. Non-zero
 * when a note landed. Any thread may call it during a session. */
int hetoimasia_glfw_note_progress_for_check(void);

/* For the native examples only: whether a progress note landed in the most
 * recent wait to return, cleared by reading it. */
int hetoimasia_glfw_take_wait_noted_for_check(void);

#endif
