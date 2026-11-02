#ifndef HETOIMASIA_TEST_SUPPORT_PROCESS_H
#define HETOIMASIA_TEST_SUPPORT_PROCESS_H

/* A non-reaping look at a child of this process, for Test.Support.Subprocess. */

#include <sys/types.h>

/* Whether the child pid has exited, without reaping it (waitid with WNOWAIT, so
 * an exited child stays a zombie and stays waitable).
 *
 * Returns 1 when it has exited and has not been reaped, 0 when it is still
 * running and block is 0, and -errno otherwise: -ECHILD means pid is not a child
 * of this process, which is what a reaped one looks like; -EINTR means a blocking
 * wait was interrupted, so the caller can take a pending asynchronous exception
 * before it waits again. With block non-zero this waits for the exit. */
int hetoimasia_test_support_child_state(pid_t pid, int block);

#endif
