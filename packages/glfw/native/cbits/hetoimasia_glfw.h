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

/* Ask the platform to close a window, as its close button would, for the
 * native examples only. GLFW reports the request through the window's close
 * callback and destroys nothing. Call it on the session's owner thread. */
void hetoimasia_glfw_request_close_for_check(GLFWwindow* window);

/* glfwWaitEventsTimeout, bracketed for the native examples only: non-zero when
 * hetoimasia_glfw_note_progress_for_check succeeded while this call was inside
 * the wait. Call it on the session's owner thread. */
int hetoimasia_glfw_wait_events_probed_for_check(double timeout);

/* Record progress only while the owner is inside the probed wait, and wake that
 * wait; non-zero when it did. Any thread may call it during a session. */
int hetoimasia_glfw_note_progress_for_check(void);

#endif
