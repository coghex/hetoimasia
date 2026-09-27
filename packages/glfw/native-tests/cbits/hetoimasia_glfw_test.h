#ifndef HETOIMASIA_GLFW_TEST_H
#define HETOIMASIA_GLFW_TEST_H

/* Test-only Wayland helpers for glfw-native-tests.
 *
 * They exist for the native examples alone and are compiled into that test
 * suite, never into a library: each does something the Wayland qualification
 * design's D-13 forbids the production shim, which may only read the
 * connection's status. Call them on the live session's owner thread, and only
 * once the session has selected Wayland. They hand back a status and an errno
 * and never a native pointer or descriptor.
 *
 * libwayland-client is the library GLFW 3.4 loads at run time rather than
 * links, so its symbols are resolved once per process from GLFW's own handle,
 * exactly as the production probe resolves its two, and the library is never
 * closed. */

/* What a helper did, or why it could not. */
#define HETOIMASIA_TEST_READY 0
#define HETOIMASIA_TEST_NO_LIBRARY 1
#define HETOIMASIA_TEST_NO_SYMBOL 2
#define HETOIMASIA_TEST_NOT_WAYLAND 3
#define HETOIMASIA_TEST_NO_DISPLAY 4
#define HETOIMASIA_TEST_FAILED 5
#define HETOIMASIA_TEST_UNSUPPORTED_PLATFORM 6

/* A synchronization boundary with the compositor: flush everything the client
 * has sent, then block until the compositor has answered a sync request sent
 * after it, which it does only once it has processed every earlier request.
 * Every event those requests caused has then been read. The events addressed
 * to the display itself, such as the delete_id each destroyed object is
 * answered with, have been dispatched too; the sync's own reply travels on a
 * private queue, and events for GLFW's objects are left queued on GLFW's
 * default queue for the next event processing to dispatch. It posts no GLFW
 * empty event and touches no wait record. On HETOIMASIA_TEST_FAILED, error is
 * the errno libwayland left. */
int hetoimasia_glfw_test_wayland_barrier(int* error);

/* The odd sequence number of the barrier in progress, if the thread running it
 * is blocked in the kernel, and zero otherwise; the same number is read on both
 * sides of observing that thread, as the production shim observes a blocked
 * wait. It observes and posts nothing. The examples resume a paused compositor
 * only once they have seen the owner blocked. */
unsigned long hetoimasia_glfw_test_blocked_barrier(void);

#endif
