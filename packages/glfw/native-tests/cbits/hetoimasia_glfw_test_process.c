/*
 * A test-only process helper for glfw-native-tests; see the header.
 */
#include "hetoimasia_glfw_test_process.h"

#include <errno.h>
#include <sys/wait.h>

int hetoimasia_glfw_test_await_unreaped_exit(pid_t pid) {
  siginfo_t info;
  for (;;) {
    /* WNOWAIT leaves the child waitable, so it remains a zombie. */
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) == 0) {
      return 0;
    }
    if (errno != EINTR) {
      return errno;
    }
  }
}
