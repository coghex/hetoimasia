/*
 * A non-reaping look at a child of this process; see the header.
 */
#include "hetoimasia_test_support_process.h"

#include <errno.h>
#include <string.h>
#include <sys/wait.h>

int hetoimasia_test_support_child_state(pid_t pid, int block) {
  siginfo_t info;
  memset(&info, 0, sizeof info);
  /* WNOWAIT leaves the child waitable, so an exited child remains a zombie. */
  int options = WEXITED | WNOWAIT | (block ? 0 : WNOHANG);
  if (waitid(P_PID, (id_t)pid, &info, options) != 0) {
    return -errno;
  }
  return info.si_pid != 0 ? 1 : 0;
}
