/*
 * The one header the private GLFW binding's foreign imports name.
 *
 * It includes the installed GLFW 3.4 header with no client API header, so every
 * constant and function declaration the binding uses comes from GLFW itself,
 * and declares the thread-identity shim beside it.
 */
#ifndef HETOIMASIA_GLFW_H
#define HETOIMASIA_GLFW_H

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

/* Non-zero when the calling OS thread is the one that entered the process
 * main function. It reads the thread's identity and nothing else. */
int hetoimasia_glfw_is_process_main_thread(void);

#endif
