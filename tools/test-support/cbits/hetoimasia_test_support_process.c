/*
 * Non-reaping looks at a child of this process and at its process group; see
 * the header.
 */
#include "hetoimasia_test_support_process.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

#if defined(__APPLE__)
#include <libproc.h>
#elif defined(__linux__)
#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#endif

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
    *code = info.si_code == CLD_EXITED ? info.si_status : -info.si_status;
  }
  return 1;
}

#if defined(__APPLE__)

int hetoimasia_test_support_group_has_other(pid_t pgid, pid_t leader) {
  /* proc_listpids answers the bytes it filled, so a full buffer may have cut the
   * list short: grow it until it is not full. */
  int capacity = 256;
  for (;;) {
    pid_t *members = malloc((size_t)capacity * sizeof *members);
    if (members == NULL) {
      return -ENOMEM;
    }
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, members, capacity * (int)sizeof *members);
    if (bytes < 0) {
      free(members);
      return -EIO;
    }
    int count = bytes / (int)sizeof *members;
    if (count < capacity) {
      int found = 0;
      for (int index = 0; index < count; index++) {
        if (members[index] != 0 && members[index] != leader) {
          found = 1;
          break;
        }
      }
      free(members);
      return found;
    }
    free(members);
    capacity *= 4;
  }
}

#elif defined(__linux__)

/* The process group of /proc/<pid>/stat, or -1: the fields after the command name, which is
 * parenthesised and may itself hold parentheses and spaces, are "state ppid pgrp". */
static int group_of(const char *entry) {
  char path[64];
  snprintf(path, sizeof path, "/proc/%s/stat", entry);
  FILE *stat = fopen(path, "r");
  if (stat == NULL) {
    return -1;
  }
  char line[1024];
  char *read = fgets(line, sizeof line, stat);
  fclose(stat);
  if (read == NULL) {
    return -1;
  }
  char *close = strrchr(line, ')');
  int ppid = 0;
  int group = 0;
  char state = 0;
  if (close == NULL || sscanf(close + 1, " %c %d %d", &state, &ppid, &group) != 3) {
    return -1;
  }
  return group;
}

int hetoimasia_test_support_group_has_other(pid_t pgid, pid_t leader) {
  DIR *table = opendir("/proc");
  if (table == NULL) {
    return -errno;
  }
  int found = 0;
  struct dirent *entry;
  while (!found && (entry = readdir(table)) != NULL) {
    if (!isdigit((unsigned char)entry->d_name[0])) {
      continue;
    }
    pid_t candidate = (pid_t)atoi(entry->d_name);
    /* An entry that vanished while the table was being read is a process that is gone: not a member. */
    if (candidate != leader && group_of(entry->d_name) == (int)pgid) {
      found = 1;
    }
  }
  closedir(table);
  return found;
}

#else

int hetoimasia_test_support_group_has_other(pid_t pgid, pid_t leader) {
  (void)pgid;
  (void)leader;
  return -ENOSYS;
}

#endif
