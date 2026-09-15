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

/* The production finite event wait: glfwWaitEventsTimeout, recording which OS
 * thread waits and a sequence number for each wait, which only the native
 * examples read. Call it on the session's owner thread. */
void hetoimasia_glfw_wait_events_timeout(double timeout);

/* For the native examples only: record progress in the wait in progress, only
 * while its thread is blocked inside GLFW's wait, and wake that wait. Non-zero
 * when a note landed. Any thread may call it during a session. */
int hetoimasia_glfw_note_progress_for_check(void);

/* For the native examples only: whether a progress note landed in the most
 * recent wait to return, cleared by reading it. */
int hetoimasia_glfw_take_wait_noted_for_check(void);

#endif
