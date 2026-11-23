/*
 * A non-reaping look at a child of this process; see the header.
 */
#include "hetoimasia_test_support_process.h"

#include <errno.h>
#include <string.h>
#include <sys/wait.h>

int hetoimasia_test_support_child_state(pid_t pid, int block, int *code) {
  siginfo_t info;
  memset(&info, 0, sizeof info);
  /* WNOWAIT leaves the child waitable, so an exited child remains a zombie. */
  int options = WEXITED | WNOWAIT | (block ? 0 : WNOHANG);
  if (waitid(P_PID, (id_t)pid, &info, options) != 0) {
    return -errno;
  }
  if (info.si_pid == 0) {
    return 0;
  }
  if (code != NULL) {
    /* The status waitpid's WEXITSTATUS and WTERMSIG give the process library: an exit code of eight bits (waitid on macOS answers
     * the value the child passed, not its low byte), and the negated number of a signal that ended it. */
    *code = info.si_code == CLD_EXITED ? (info.si_status & 0xff) : -info.si_status;
  }
  return 1;
}
