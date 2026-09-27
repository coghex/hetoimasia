#ifndef HETOIMASIA_GLFW_TEST_PROCESS_H
#define HETOIMASIA_GLFW_TEST_PROCESS_H

/* A test-only process helper for glfw-native-tests, compiled into that test
 * suite alone. */

#include <sys/types.h>

/* Block until pid, a child of this process, has exited, without reaping it:
 * it is a zombie when this returns 0, and stays one until it is waited for.
 * Otherwise this returns the errno waitid left. */
int hetoimasia_glfw_test_await_unreaped_exit(pid_t pid);

#endif
