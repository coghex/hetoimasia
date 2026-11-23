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
  /* proc_listpids answers the bytes it filled: zero is an empty group or a failure, which only errno tells apart (an undersized
   * buffer fails with ENOMEM), and a full buffer may have cut the list short. Grow it until the answer is neither. */
  int capacity = 256;
  for (;;) {
    pid_t *members = malloc((size_t)capacity * sizeof *members);
    if (members == NULL) {
      return -ENOMEM;
    }
    errno = 0;
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, members, capacity * (int)sizeof *members);
    int failure = errno;
    if (bytes < 0 || (bytes == 0 && failure != 0)) {
      free(members);
      if (failure == ENOMEM && capacity < (1 << 20)) {
        capacity *= 4;
        continue;
      }
      return -(failure != 0 ? failure : EIO);
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
    if (capacity >= (1 << 20)) {
      return -ENOMEM;
    }
    capacity *= 4;
  }
}

#elif defined(__linux__)

/* The process group of /proc/<pid>/stat: a group (>= 0), -1 when the process is gone (not a member), -2 when it cannot be read.
 * The whole file is read, not a line: the command name is parenthesised and may hold parentheses, spaces and newlines, so the fields
 * "state ppid pgrp" are found after the last ')'. */
static int group_of(const char *entry) {
  char path[64];
  snprintf(path, sizeof path, "/proc/%s/stat", entry);
  FILE *stat = fopen(path, "r");
  if (stat == NULL) {
    return (errno == ENOENT || errno == ESRCH) ? -1 : -2;
  }
  char text[4096];
  size_t length = fread(text, 1, sizeof text - 1, stat);
  int failure = ferror(stat) ? errno : 0;
  fclose(stat);
  if (failure != 0) {
    return failure == ESRCH ? -1 : -2;
  }
  text[length] = '\0';
  char *close = strrchr(text, ')');
  int ppid = 0;
  int group = 0;
  char state = 0;
  if (close == NULL || sscanf(close + 1, " %c %d %d", &state, &ppid, &group) != 3) {
    return -2;
  }
  return group;
}

int hetoimasia_test_support_group_has_other(pid_t pgid, pid_t leader) {
  DIR *table = opendir("/proc");
  if (table == NULL) {
    return -errno;
  }
  int found = 0;
  int unknown = 0;
  struct dirent *entry;
  errno = 0;
  while (!found && (entry = readdir(table)) != NULL) {
    if (!isdigit((unsigned char)entry->d_name[0])) {
      continue;
    }
    pid_t candidate = (pid_t)atoi(entry->d_name);
    if (candidate == leader) {
      continue;
    }
    int group = group_of(entry->d_name);
    if (group == (int)pgid) {
      found = 1;
    } else if (group == -2) {
      unknown = 1;
    }
    errno = 0;
  }
  int failure = errno;
  closedir(table);
  if (found) {
    return 1;
  }
  /* A miss certifies nothing when a process could not be read or the table could not be walked to its end. */
  if (failure != 0) {
    return -failure;
  }
  return unknown ? -EIO : 0;
}

#else

int hetoimasia_test_support_group_has_other(pid_t pgid, pid_t leader) {
  (void)pgid;
  (void)leader;
  return -ENOSYS;
}

#endif
