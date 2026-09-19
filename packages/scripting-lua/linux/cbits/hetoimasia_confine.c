/*
** See hetoimasia_confine.h for what this is and why it is shaped this way.
*/
#define _GNU_SOURCE

#include "hetoimasia_confine.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/capability.h>
#include <linux/seccomp.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef MS_REC
#define MS_REC 16384
#endif
#ifndef MNT_DETACH
#define MNT_DETACH 2
#endif
/* A filter arriving on an architecture it was not written for is refused
** outright. Killing the process is the right answer and the one modern kernels
** offer; a kernel that only knows how to kill the thread still ends the call
** rather than allowing it. */
#ifndef SECCOMP_RET_KILL_PROCESS
#define SECCOMP_RET_KILL_PROCESS SECCOMP_RET_KILL_THREAD
#endif
#ifndef SECCOMP_RET_KILL_THREAD
#define SECCOMP_RET_KILL_THREAD 0x00000000U
#endif
/* Spelled out rather than taken from a header: the capability bitmap's index
** and mask macros belong to the kernel's own copy of <linux/capability.h>, not
** to the one installed for userspace, and libcap is a provisioning dependency
** this repository does not carry. */
#define HETOIMASIA_CAP_INDEX(capability) ((capability) >> 5)
#define HETOIMASIA_CAP_MASK(capability) (1U << ((capability)&31))

/* The audit architecture this filter is written for. A filter is only
** meaningful for the architecture whose syscall numbers it names, so a call
** arriving on any other one is refused outright rather than falling through a
** table that means nothing for it. */
#if defined(__x86_64__)
#define HETOIMASIA_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define HETOIMASIA_AUDIT_ARCH AUDIT_ARCH_AARCH64
#else
#define HETOIMASIA_AUDIT_ARCH 0
#endif

/* The namespace-creating bits of `clone`'s flag word. Denying `clone` outright
** is not open to us -- every OS thread the threaded RTS starts is one -- so the
** filter reads the flags instead and refuses exactly the calls that would hand
** the child a namespace of its own. */
#define HETOIMASIA_CLONE_NAMESPACE_FLAGS                                       \
  (CLONE_NEWNS | CLONE_NEWCGROUP | CLONE_NEWUTS | CLONE_NEWIPC |               \
   CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNET)

/* How large a private root's tmpfs may be, and how much of it the child may
** write. A disposable working area with a bound, as P-13 asks for. */
#define HETOIMASIA_PRIVATE_ROOT_OPTIONS "mode=0755,size=64m"

#define HETOIMASIA_PATH_MAX 4096

/* What the pre-exec child reports to the parent when a layer refuses. */
struct hetoimasia_refusal {
  int layer;
  int error;
};

const char *hetoimasia_confine_layer_name(int layer) {
  switch (layer) {
  case HETOIMASIA_LAYER_NONE:
    return "none";
  case HETOIMASIA_LAYER_NO_NEW_PRIVS:
    return "no-new-privs";
  case HETOIMASIA_LAYER_USER_NS:
    return "user-namespace";
  case HETOIMASIA_LAYER_MOUNT_NS:
    return "mount-namespace";
  case HETOIMASIA_LAYER_NET_NS:
    return "network-namespace";
  case HETOIMASIA_LAYER_IPC_NS:
    return "ipc-namespace";
  case HETOIMASIA_LAYER_UTS_NS:
    return "uts-namespace";
  case HETOIMASIA_LAYER_PRIVATE_ROOT:
    return "private-root";
  case HETOIMASIA_LAYER_RESOURCE_LIMITS:
    return "resource-limits";
  case HETOIMASIA_LAYER_MEMORY_LIMIT:
    return "memory-limit";
  case HETOIMASIA_LAYER_SECCOMP:
    return "seccomp-filter";
  case HETOIMASIA_LAYER_EXEC:
    return "exec";
  case HETOIMASIA_LAYER_PID_NS:
    return "pid-namespace";
  case HETOIMASIA_LAYER_SUPERVISOR:
    return "supervisor";
  default:
    return "unknown";
  }
}

/* ------------------------------------------------------------------------ */
/* The pre-exec child                                                        */

/* Join `root` and `tail` into `out`. Answers 0, or -1 when the result would
** not fit, which is a refusal rather than a truncation. */
static int hetoimasia_join(char *out, size_t length, const char *root,
                           const char *tail) {
  int written = snprintf(out, length, "%s%s", root, tail);
  if (written < 0 || (size_t)written >= length) {
    errno = ENAMETOOLONG;
    return -1;
  }
  return 0;
}

/* Create `path` and every directory above it. An existing directory is not a
** failure; anything else is. */
static int hetoimasia_make_directories(const char *path) {
  char buffer[HETOIMASIA_PATH_MAX];
  size_t length = strlen(path);
  if (length >= sizeof(buffer)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(buffer, path, length + 1);
  for (size_t index = 1; index <= length; index++) {
    if (buffer[index] != '/' && buffer[index] != '\0') {
      continue;
    }
    char separator = buffer[index];
    buffer[index] = '\0';
    if (mkdir(buffer, 0755) != 0 && errno != EEXIST) {
      return -1;
    }
    buffer[index] = separator;
  }
  return 0;
}

/* Create an empty file at `path`, and the directories above it, so a file bind
** mount has somewhere to land. */
static int hetoimasia_make_file(const char *path) {
  char buffer[HETOIMASIA_PATH_MAX];
  size_t length = strlen(path);
  if (length >= sizeof(buffer)) {
    errno = ENAMETOOLONG;
    return -1;
  }
  memcpy(buffer, path, length + 1);
  char *separator = strrchr(buffer, '/');
  if (separator != NULL && separator != buffer) {
    *separator = '\0';
    if (hetoimasia_make_directories(buffer) != 0) {
      return -1;
    }
  }
  int descriptor = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
  if (descriptor < 0) {
    return -1;
  }
  close(descriptor);
  return 0;
}

/* The mount flags a remount inside this user namespace may not drop.
**
** Every mount this namespace inherited is locked: the kernel refuses a
** bind-remount that would clear its nosuid, nodev, noexec, or access-time
** settings, and a remount that simply names the flags it wants is asking to
** clear whichever of those it did not name. Almost every Linux filesystem is
** mounted `relatime`, so a remount that forgot it would fail with EPERM on
** almost every Linux -- as a refusal to install the private root, which is a
** confusing way to be told about a missing flag.
**
** So the current settings are read back and carried forward. Only `read-only`
** is added, which locking permits because it narrows. */
static unsigned long hetoimasia_locked_flags(const char *path) {
  struct statvfs current;
  unsigned long flags = 0;
  if (statvfs(path, &current) != 0) {
    /* Unknown is not the same as none: carrying the common defaults forward is
    ** the safe direction, since adding an access-time flag the mount already
    ** has is a no-op and dropping one it has is the failure. */
    return MS_RELATIME;
  }
  if (current.f_flag & ST_NOSUID) {
    flags |= MS_NOSUID;
  }
  if (current.f_flag & ST_NODEV) {
    flags |= MS_NODEV;
  }
  if (current.f_flag & ST_NOEXEC) {
    flags |= MS_NOEXEC;
  }
  if (current.f_flag & ST_NOATIME) {
    flags |= MS_NOATIME;
  }
  if (current.f_flag & ST_NODIRATIME) {
    flags |= MS_NODIRATIME;
  }
#ifdef ST_RELATIME
  if (current.f_flag & ST_RELATIME) {
    flags |= MS_RELATIME;
  }
#endif
  return flags;
}

/* Bind `source` into the private root, read-only.
**
** The remount is a second call because a bind mount does not take its flags
** from the first one: MS_RDONLY on the initial bind is silently the source's
** own setting, and only MS_REMOUNT|MS_BIND makes the new mount read-only. */
static int hetoimasia_bind_read_only(const char *root, const char *source) {
  char target[HETOIMASIA_PATH_MAX];
  struct stat details;
  if (stat(source, &details) != 0) {
    /* A path this machine does not have is not a refusal: the caller offers a
    ** list of candidates and the child uses whichever exist. */
    return 0;
  }
  if (hetoimasia_join(target, sizeof(target), root, source) != 0) {
    return -1;
  }
  if (S_ISDIR(details.st_mode)) {
    if (hetoimasia_make_directories(target) != 0) {
      return -1;
    }
  } else if (hetoimasia_make_file(target) != 0) {
    return -1;
  }
  if (mount(source, target, NULL, MS_BIND | MS_REC, NULL) != 0) {
    return -1;
  }
  if (mount(NULL, target, NULL,
            MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV |
              hetoimasia_locked_flags(target),
            NULL) != 0) {
    return -1;
  }
  return 0;
}

/* Write `contents` to `path`, whole. Used for the user namespace's identity
** maps, each of which must be written in one call. */
static int hetoimasia_write_whole(const char *path, const char *contents) {
  int descriptor = open(path, O_WRONLY | O_CLOEXEC);
  if (descriptor < 0) {
    return -1;
  }
  size_t length = strlen(contents);
  ssize_t written = write(descriptor, contents, length);
  int saved = errno;
  close(descriptor);
  if (written < 0 || (size_t)written != length) {
    errno = written < 0 ? saved : EIO;
    return -1;
  }
  return 0;
}

/* The confined process, as the supervisor between it and the caller knows it.
**
** Written once before the supervisor's handler can run and read only there. */
static volatile pid_t hetoimasia_supervised = 0;

/* Pass a cooperative stop through to the confined process.
**
** The supervisor is not the process the caller is trying to stop, and a
** supervisor that simply died of the signal would take the confined process
** with it through its parent-death signal -- ending it on the cooperative
** request, which is exactly the escalation the execution-limit experiment
** exists to observe. So the signal is forwarded and the supervisor stays. */
static void hetoimasia_forward_stop(int signal_number) {
  if (hetoimasia_supervised > 0) {
    kill(hetoimasia_supervised, signal_number);
  }
}

/* Report a refusal to the parent and end this pre-exec child.
**
** Nothing here can usefully continue: every path out of this function has
** already failed to install a layer, and continuing would be exactly the
** unconfined child the contract forbids. */
static void hetoimasia_refuse(int report, int layer, int error) {
  struct hetoimasia_refusal refusal;
  refusal.layer = layer;
  refusal.error = error;
  ssize_t ignored = write(report, &refusal, sizeof(refusal));
  (void)ignored;
  _exit(127);
}

/* Everything between the fork and the exec. Never returns. */
static void hetoimasia_confine_child(const char *program, char *const argv[],
                                     char *const envp[],
                                     const char *root_directory,
                                     const char *const *read_only_paths,
                                     long memory_limit_bytes, int ipc_socket,
                                     int input, int output, int report) {
  char path[HETOIMASIA_PATH_MAX];
  char identity[64];
  uid_t outer_uid = geteuid();
  gid_t outer_gid = getegid();
  /* Read before the limits below narrow it: lowering RLIMIT_NOFILE closes
  ** nothing that is already open, so the range that has to be swept is the one
  ** the caller could have opened into, not the one the child will be allowed. */
  rlim_t inherited_ceiling = 1024;
  {
    struct rlimit descriptors;
    if (getrlimit(RLIMIT_NOFILE, &descriptors) == 0 &&
        descriptors.rlim_max != RLIM_INFINITY) {
      inherited_ceiling = descriptors.rlim_max;
    } else {
      inherited_ceiling = 1048576;
    }
  }

  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_NO_NEW_PRIVS, errno);
  }

  /* The user namespace comes first and is what makes the rest legal: every
  ** namespace below, and the private root above it, needs CAP_SYS_ADMIN, and
  ** an unprivileged process can only hold that inside a user namespace it
  ** created. Skipped when this process already holds it -- a root CI container
  ** is the case that matters -- because then the namespace buys nothing and
  ** its absence is worth recording accurately rather than papering over. */
  if (!hetoimasia_confine_has_sys_admin()) {
    if (unshare(CLONE_NEWUSER) != 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_USER_NS, errno);
    }
    /* setgroups must be denied before a gid map may be written by a process
    ** that is not privileged in the parent namespace. */
    if (hetoimasia_write_whole("/proc/self/setgroups", "deny") != 0 &&
        errno != ENOENT) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_USER_NS, errno);
    }
    snprintf(identity, sizeof(identity), "0 %u 1\n", (unsigned)outer_uid);
    if (hetoimasia_write_whole("/proc/self/uid_map", identity) != 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_USER_NS, errno);
    }
    snprintf(identity, sizeof(identity), "0 %u 1\n", (unsigned)outer_gid);
    if (hetoimasia_write_whole("/proc/self/gid_map", identity) != 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_USER_NS, errno);
    }
  }

  if (unshare(CLONE_NEWNS) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_MOUNT_NS, errno);
  }
  if (unshare(CLONE_NEWNET) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_NET_NS, errno);
  }
  if (unshare(CLONE_NEWIPC) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_IPC_NS, errno);
  }
  if (unshare(CLONE_NEWUTS) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_UTS_NS, errno);
  }
  /* A PID namespace is what makes "cannot reach another instance" a property
  ** of the kernel rather than of the child's ignorance. Without one the child
  ** shares the host's process numbering and the caller's own user id, so every
  ** signalling call -- `kill`, down to `kill(-1, ...)` -- can reach a sibling,
  ** the engine, or anything else that user is running; a filter cannot tell
  ** those apart from the process signalling itself, because it cannot see who
  ** is asking. Inside its own namespace there is nothing else to name.
  **
  ** `unshare` moves the caller's *children* into the new namespace rather than
  ** the caller, which is why there is a second fork below. */
  if (unshare(CLONE_NEWPID) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_PID_NS, errno);
  }

  /* Nothing this child mounts may propagate back to the host's tree. */
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_PRIVATE_ROOT, errno);
  }
  if (mount("tmpfs", root_directory, "tmpfs", MS_NOSUID | MS_NODEV,
            HETOIMASIA_PRIVATE_ROOT_OPTIONS) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_PRIVATE_ROOT, errno);
  }
  for (size_t index = 0; read_only_paths[index] != NULL; index++) {
    if (hetoimasia_bind_read_only(root_directory, read_only_paths[index]) != 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_PRIVATE_ROOT, errno);
    }
  }
  /* The program itself, at a fixed name. The child never learns where it came
  ** from on the host, and no other executable is reachable at all. */
  if (hetoimasia_join(path, sizeof(path), root_directory, "/probe") != 0 ||
      hetoimasia_make_file(path) != 0 ||
      mount(program, path, NULL, MS_BIND, NULL) != 0 ||
      mount(NULL, path, NULL,
            MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID |
              hetoimasia_locked_flags(path),
            NULL) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_PRIVATE_ROOT, errno);
  }
  /* The private disposable working area, and the pivot's parking space. */
  if (hetoimasia_join(path, sizeof(path), root_directory, "/work") != 0 ||
      mkdir(path, 0700) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_PRIVATE_ROOT, errno);
  }
  if (hetoimasia_join(path, sizeof(path), root_directory, "/oldroot") != 0 ||
      mkdir(path, 0700) != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_PRIVATE_ROOT, errno);
  }
  if (chdir(root_directory) != 0 ||
      syscall(SYS_pivot_root, ".", "oldroot") != 0 || chdir("/") != 0 ||
      umount2("/oldroot", MNT_DETACH) != 0 || rmdir("/oldroot") != 0 ||
      chdir("/work") != 0) {
    hetoimasia_refuse(report, HETOIMASIA_LAYER_PRIVATE_ROOT, errno);
  }

  {
    struct rlimit limit;
    /* Enough for the runtime's own descriptors -- an event manager per
    ** capability, its timers and its wake-up pipes -- plus the handful this
    ** probe opens, and far short of what a descriptor exhaustion would need. */
    limit.rlim_cur = 256;
    limit.rlim_max = 256;
    if (setrlimit(RLIMIT_NOFILE, &limit) != 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_RESOURCE_LIMITS, errno);
    }
    limit.rlim_cur = 0;
    limit.rlim_max = 0;
    if (setrlimit(RLIMIT_CORE, &limit) != 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_RESOURCE_LIMITS, errno);
    }
    limit.rlim_cur = 8u * 1024u * 1024u;
    limit.rlim_max = 8u * 1024u * 1024u;
    if (setrlimit(RLIMIT_FSIZE, &limit) != 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_RESOURCE_LIMITS, errno);
    }
    if (memory_limit_bytes > 0) {
      limit.rlim_cur = (rlim_t)memory_limit_bytes;
      limit.rlim_max = (rlim_t)memory_limit_bytes;
      if (setrlimit(RLIMIT_AS, &limit) != 0) {
        hetoimasia_refuse(report, HETOIMASIA_LAYER_MEMORY_LIMIT, errno);
      }
    }
  }

  /* The four descriptors the child is given, at the four numbers it expects.
  **
  ** Each is first moved out of the 0-3 range, because the parent's own
  ** numbering is not this function's to assume and a dup2 onto a descriptor
  ** another one of these still occupies would destroy it. */
  {
    int moved_input = fcntl(input, F_DUPFD_CLOEXEC, 16);
    int moved_output = fcntl(output, F_DUPFD_CLOEXEC, 16);
    int moved_ipc = fcntl(ipc_socket, F_DUPFD_CLOEXEC, 16);
    int moved_report = fcntl(report, F_DUPFD_CLOEXEC, 16);
    if (moved_input < 0 || moved_output < 0 || moved_ipc < 0 ||
        moved_report < 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_RESOURCE_LIMITS, errno);
    }
    report = moved_report;
    if (dup2(moved_input, 0) < 0 || dup2(moved_output, 1) < 0 ||
        dup2(moved_output, 2) < 0 ||
        dup2(moved_ipc, HETOIMASIA_CONFINE_IPC_FD) < 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_RESOURCE_LIMITS, errno);
    }
    /* The report pipe moves to a fixed number of its own so that the sweep
    ** below can be a range rather than a list with a hole in it. `dup2` clears
    ** close-on-exec, and the exec closing this descriptor is the whole success
    ** signal, so it is set again explicitly. */
    if (dup2(report, HETOIMASIA_CONFINE_REPORT_FD) < 0 ||
        fcntl(HETOIMASIA_CONFINE_REPORT_FD, F_SETFD, FD_CLOEXEC) != 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_RESOURCE_LIMITS, errno);
    }
    report = HETOIMASIA_CONFINE_REPORT_FD;
  }
  /* Everything above them goes, so no descriptor the caller happened to hold
  ** becomes an ambient capability of the child.
  **
  ** The whole range, not a guess at it. A caller's descriptor can sit at any
  ** number its own limit allows, and one above a swept range survives the exec
  ** as exactly the ambient capability this is here to prevent. `close_range`
  ** says "everything from here up" in one call; where the kernel does not have
  ** it, the ceiling read before the limits narrowed it is what bounds the
  ** loop. */
  {
    int first = HETOIMASIA_CONFINE_REPORT_FD + 1;
    int swept = -1;
#ifdef SYS_close_range
    swept = (int)syscall(SYS_close_range, (unsigned int)first, ~0U, 0);
#endif
    if (swept != 0) {
      for (rlim_t descriptor = (rlim_t)first; descriptor < inherited_ceiling;
           descriptor++) {
        close((int)descriptor);
      }
    }
  }

  /* The second fork, and the reason there is one.
  **
  ** `unshare(CLONE_NEWPID)` put this process's *children* in the new namespace,
  ** not this process, and a namespace's first process is its init -- which must
  ** have a parent outside it. So the confined program is the child below, and
  ** what remains here is a supervisor: it holds no Lua, loads no source, and
  ** exists to make the confined process's own termination visible to a caller
  ** that cannot wait on a process in a namespace it is not in. */
  {
    pid_t confined = fork();
    if (confined < 0) {
      hetoimasia_refuse(report, HETOIMASIA_LAYER_SUPERVISOR, errno);
    }
    if (confined == 0) {
      /* A supervisor that dies must not leave the confined process running:
      ** the caller's handle is the supervisor, so an orphan here would be a
      ** process nothing is accounting for. */
      if (prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) {
        hetoimasia_refuse(report, HETOIMASIA_LAYER_SUPERVISOR, errno);
      }
      execve("/probe", argv, envp);
      hetoimasia_refuse(report, HETOIMASIA_LAYER_EXEC, errno);
    }

    hetoimasia_supervised = confined;
    /* The exec's silence is the success signal, and it is only silence once
    ** every copy of the write end is gone. This one is the last. */
    close(report);
    {
      struct sigaction forwarding;
      memset(&forwarding, 0, sizeof(forwarding));
      forwarding.sa_handler = hetoimasia_forward_stop;
      sigemptyset(&forwarding.sa_mask);
      forwarding.sa_flags = SA_RESTART;
      sigaction(SIGTERM, &forwarding, NULL);
      sigaction(SIGINT, &forwarding, NULL);
      sigaction(SIGHUP, &forwarding, NULL);
    }
    {
      int status = 0;
      while (waitpid(confined, &status, 0) < 0) {
        if (errno != EINTR) {
          _exit(126);
        }
      }
      /* Reproduced rather than summarised. A caller reading an exit status is
      ** reading the confined process's, including the signal that ended it. */
      if (WIFEXITED(status)) {
        _exit(WEXITSTATUS(status));
      }
      if (WIFSIGNALED(status)) {
        struct sigaction ending;
        memset(&ending, 0, sizeof(ending));
        ending.sa_handler = SIG_DFL;
        sigemptyset(&ending.sa_mask);
        sigaction(WTERMSIG(status), &ending, NULL);
        raise(WTERMSIG(status));
      }
      _exit(126);
    }
  }
}

pid_t hetoimasia_confine_spawn(const char *program, char *const argv[],
                               char *const envp[], const char *root_directory,
                               long memory_limit_bytes, int ipc_socket,
                               int input, int output, int *failed_layer,
                               int *failed_errno) {
  /* The read-only runtime view. Directories, never files a person owns: the
  ** child needs its loader and its shared libraries and nothing else, and every
  ** path a test treats as "outside the view" is outside this list. */
  static const char *const read_only_paths[] = {
      "/usr", "/lib", "/lib64", "/bin", "/opt", "/etc/ld.so.cache", NULL};
  int channel[2];

  *failed_layer = HETOIMASIA_LAYER_NONE;
  *failed_errno = 0;

  if (pipe2(channel, O_CLOEXEC) != 0) {
    *failed_layer = HETOIMASIA_LAYER_NONE;
    *failed_errno = errno;
    return -1;
  }

  pid_t child = fork();
  if (child < 0) {
    int saved = errno;
    close(channel[0]);
    close(channel[1]);
    *failed_layer = HETOIMASIA_LAYER_NONE;
    *failed_errno = saved;
    return -1;
  }
  if (child == 0) {
    close(channel[0]);
    hetoimasia_confine_child(program, argv, envp, root_directory,
                             read_only_paths, memory_limit_bytes, ipc_socket,
                             input, output, channel[1]);
    _exit(127); /* unreachable */
  }

  close(channel[1]);
  struct hetoimasia_refusal refusal;
  ssize_t read_bytes;
  do {
    read_bytes = read(channel[0], &refusal, sizeof(refusal));
  } while (read_bytes < 0 && errno == EINTR);
  close(channel[0]);

  if (read_bytes == (ssize_t)sizeof(refusal)) {
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
    }
    *failed_layer = refusal.layer;
    *failed_errno = refusal.error;
    return -1;
  }
  if (read_bytes != 0) {
    /* A short or failed read is not evidence that the child is confined, so it
    ** is treated exactly like a refusal: the child is ended and reaped. */
    int status = 0;
    kill(child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
    }
    *failed_layer = HETOIMASIA_LAYER_NONE;
    *failed_errno = EIO;
    return -1;
  }
  return child;
}

/* ------------------------------------------------------------------------ */
/* The in-process layers                                                     */

/* One denied syscall: two instructions, and no offset to get wrong. */
#define HETOIMASIA_DENY(number, error)                                         \
  do {                                                                         \
    program[length++] = (struct sock_filter)BPF_JUMP(                          \
        BPF_JMP | BPF_JEQ | BPF_K, (unsigned)(number), 0, 1);                  \
    program[length++] = (struct sock_filter)BPF_STMT(                          \
        BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ((error)&SECCOMP_RET_DATA));      \
  } while (0)

int hetoimasia_confine_seal(int allow_executable_file_mappings,
                            int *installed_layers, int *failed_errno) {
  struct sock_filter program[256];
  size_t length = 0;

  *installed_layers = HETOIMASIA_LAYER_NONE;
  *failed_errno = 0;

  if (HETOIMASIA_AUDIT_ARCH == 0) {
    *failed_errno = ENOSYS;
    return -1;
  }
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
    *failed_errno = errno;
    return -1;
  }
  *installed_layers |= HETOIMASIA_LAYER_NO_NEW_PRIVS;

  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch));
  program[length++] = (struct sock_filter)BPF_JUMP(
      BPF_JMP | BPF_JEQ | BPF_K, HETOIMASIA_AUDIT_ARCH, 1, 0);
  program[length++] =
      (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));

#if defined(__x86_64__)
  /* The x32 ABI reaches the same kernel under the same audit architecture, with
  ** its own syscall numbers formed by setting the high bit. Every comparison
  ** below is against an ordinary number, so an x32 call would match none of
  ** them and fall through to the allow -- which is the whole table bypassed by
  ** setting one bit. There is nothing here for x32 to do, so it is refused
  ** before the table rather than filtered through it. */
  program[length++] =
      (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1);
  program[length++] =
      (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
#endif

  /* Launching another program, in either spelling. */
  HETOIMASIA_DENY(__NR_execve, EACCES);
#ifdef __NR_execveat
  HETOIMASIA_DENY(__NR_execveat, EACCES);
#endif
  /* Reaching into another process. */
#ifdef __NR_ptrace
  HETOIMASIA_DENY(__NR_ptrace, EPERM);
#endif
#ifdef __NR_process_vm_readv
  HETOIMASIA_DENY(__NR_process_vm_readv, EPERM);
#endif
#ifdef __NR_process_vm_writev
  HETOIMASIA_DENY(__NR_process_vm_writev, EPERM);
#endif
  /* Reconfiguring, escaping, or re-entering the confinement itself. */
  HETOIMASIA_DENY(__NR_unshare, EPERM);
#ifdef __NR_setns
  HETOIMASIA_DENY(__NR_setns, EPERM);
#endif
  HETOIMASIA_DENY(__NR_mount, EPERM);
#ifdef __NR_umount2
  HETOIMASIA_DENY(__NR_umount2, EPERM);
#endif
#ifdef __NR_pivot_root
  HETOIMASIA_DENY(__NR_pivot_root, EPERM);
#endif
#ifdef __NR_chroot
  HETOIMASIA_DENY(__NR_chroot, EPERM);
#endif
#ifdef __NR_mount_setattr
  HETOIMASIA_DENY(__NR_mount_setattr, EPERM);
#endif
#ifdef __NR_move_mount
  HETOIMASIA_DENY(__NR_move_mount, EPERM);
#endif
#ifdef __NR_open_tree
  HETOIMASIA_DENY(__NR_open_tree, EPERM);
#endif
#ifdef __NR_fsopen
  HETOIMASIA_DENY(__NR_fsopen, EPERM);
#endif
#ifdef __NR_fsconfig
  HETOIMASIA_DENY(__NR_fsconfig, EPERM);
#endif
#ifdef __NR_fsmount
  HETOIMASIA_DENY(__NR_fsmount, EPERM);
#endif
  /* Naming a file by handle sidesteps the directory tree the mount namespace
  ** is what restricts, so it goes with the mount calls rather than the file
  ** ones. */
#ifdef __NR_name_to_handle_at
  HETOIMASIA_DENY(__NR_name_to_handle_at, EPERM);
#endif
#ifdef __NR_open_by_handle_at
  HETOIMASIA_DENY(__NR_open_by_handle_at, EPERM);
#endif
  /* Reaching another process by descriptor rather than by number. The PID
  ** namespace is what makes the numbers useless; these would be a way around
  ** it if one ever leaked in. */
#ifdef __NR_pidfd_open
  HETOIMASIA_DENY(__NR_pidfd_open, EPERM);
#endif
#ifdef __NR_pidfd_getfd
  HETOIMASIA_DENY(__NR_pidfd_getfd, EPERM);
#endif
#ifdef __NR_pidfd_send_signal
  HETOIMASIA_DENY(__NR_pidfd_send_signal, EPERM);
#endif
  /* Kernel surfaces with no business inside a mod. */
#ifdef __NR_bpf
  HETOIMASIA_DENY(__NR_bpf, EPERM);
#endif
#ifdef __NR_perf_event_open
  HETOIMASIA_DENY(__NR_perf_event_open, EPERM);
#endif
#ifdef __NR_keyctl
  HETOIMASIA_DENY(__NR_keyctl, EPERM);
#endif
#ifdef __NR_add_key
  HETOIMASIA_DENY(__NR_add_key, EPERM);
#endif
#ifdef __NR_request_key
  HETOIMASIA_DENY(__NR_request_key, EPERM);
#endif
#ifdef __NR_init_module
  HETOIMASIA_DENY(__NR_init_module, EPERM);
#endif
#ifdef __NR_finit_module
  HETOIMASIA_DENY(__NR_finit_module, EPERM);
#endif
#ifdef __NR_delete_module
  HETOIMASIA_DENY(__NR_delete_module, EPERM);
#endif
#ifdef __NR_kexec_load
  HETOIMASIA_DENY(__NR_kexec_load, EPERM);
#endif
#ifdef __NR_kexec_file_load
  HETOIMASIA_DENY(__NR_kexec_file_load, EPERM);
#endif
#ifdef __NR_reboot
  HETOIMASIA_DENY(__NR_reboot, EPERM);
#endif
#ifdef __NR_settimeofday
  HETOIMASIA_DENY(__NR_settimeofday, EPERM);
#endif
#ifdef __NR_clock_settime
  HETOIMASIA_DENY(__NR_clock_settime, EPERM);
#endif
#ifdef __NR_swapon
  HETOIMASIA_DENY(__NR_swapon, EPERM);
#endif
#ifdef __NR_swapoff
  HETOIMASIA_DENY(__NR_swapoff, EPERM);
#endif
#ifdef __NR_syslog
  HETOIMASIA_DENY(__NR_syslog, EPERM);
#endif
#ifdef __NR_acct
  HETOIMASIA_DENY(__NR_acct, EPERM);
#endif
#ifdef __NR_userfaultfd
  HETOIMASIA_DENY(__NR_userfaultfd, EPERM);
#endif
#ifdef __NR_modify_ldt
  HETOIMASIA_DENY(__NR_modify_ldt, EPERM);
#endif
#ifdef __NR_iopl
  HETOIMASIA_DENY(__NR_iopl, EPERM);
#endif
#ifdef __NR_ioperm
  HETOIMASIA_DENY(__NR_ioperm, EPERM);
#endif
  /* ENOSYS rather than EPERM, and the difference is load-bearing: glibc reaches
  ** for `clone3` first and falls back to `clone` only when the kernel says it
  ** does not have it. EPERM here would fail every thread the RTS starts. */
#ifdef __NR_clone3
  HETOIMASIA_DENY(__NR_clone3, ENOSYS);
#endif

  /* `socket`, by domain. AF_UNIX stays available because the child's own IPC
  ** endpoint and the peer-reachability question are both AF_UNIX, and because
  ** a unix socket inside an empty network namespace reaches nothing the child
  ** does not already have. Every other domain is refused here, so a network
  ** denial is attributable to this filter and not only to an empty namespace.
  **
  ** Both halves of the domain argument are read. The kernel hands the filter
  ** the raw register, whose upper half is not guaranteed to be clear, and an
  ** allow decision taken on the lower half alone would be one a caller could
  ** aim at. */
  program[length++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                                   (unsigned)__NR_socket, 0, 6);
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0]) + 4);
  program[length++] =
      (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 0, 2);
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0]));
  program[length++] =
      (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_UNIX, 1, 0);
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EACCES & SECCOMP_RET_DATA));
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));

  /* `clone`, by flags: every thread the RTS starts is one of these, so the
  ** decision has to be about what the call would create rather than about the
  ** call. */
  program[length++] = (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K,
                                                   (unsigned)__NR_clone, 0, 5);
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0]));
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_ALU | BPF_AND | BPF_K, HETOIMASIA_CLONE_NAMESPACE_FLAGS);
  program[length++] =
      (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 1, 0);
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA));
  program[length++] = (struct sock_filter)BPF_STMT(
      BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));

  /* File-backed executable mappings: the mechanism that answers "load a native
  ** module" with something better than "that path is not in your view". The
  ** loader finished its work before this filter existed, and the RTS's own
  ** executable pages are anonymous, so the rule costs the running program
  ** nothing and costs a mod every `dlopen` there is. */
  if (!allow_executable_file_mappings) {
    program[length++] = (struct sock_filter)BPF_JUMP(
        BPF_JMP | BPF_JEQ | BPF_K, (unsigned)__NR_mmap, 0, 8);
    program[length++] = (struct sock_filter)BPF_STMT(
        BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[2]));
    program[length++] =
        (struct sock_filter)BPF_STMT(BPF_ALU | BPF_AND | BPF_K, PROT_EXEC);
    program[length++] =
        (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 4, 0);
    program[length++] = (struct sock_filter)BPF_STMT(
        BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[3]));
    program[length++] =
        (struct sock_filter)BPF_STMT(BPF_ALU | BPF_AND | BPF_K, MAP_ANONYMOUS);
    program[length++] =
        (struct sock_filter)BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 0, 0, 1);
    program[length++] = (struct sock_filter)BPF_STMT(
        BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EACCES & SECCOMP_RET_DATA));
    program[length++] = (struct sock_filter)BPF_STMT(
        BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr));
  }

  program[length++] =
      (struct sock_filter)BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);

  {
    struct sock_fprog blob;
    blob.len = (unsigned short)length;
    blob.filter = program;
    /* TSYNC is the whole-child part of the claim. Without it the filter binds
    ** the calling thread alone, and the threaded RTS has others already
    ** running; with it every thread that exists now carries the filter, and
    ** every thread started afterwards inherits it. */
    if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC,
                &blob) != 0) {
      *failed_errno = errno;
      return -1;
    }
  }
  *installed_layers |= HETOIMASIA_LAYER_SECCOMP;
  return 0;
}

/* ------------------------------------------------------------------------ */
/* The probes                                                                */

int hetoimasia_probe_read_file(const char *path) {
  char byte;
  int descriptor = open(path, O_RDONLY | O_CLOEXEC);
  if (descriptor < 0) {
    return errno;
  }
  ssize_t read_bytes = read(descriptor, &byte, 1);
  int saved = read_bytes < 0 ? errno : 0;
  close(descriptor);
  return saved;
}

int hetoimasia_probe_open_socket(int domain) {
  int descriptor = socket(domain, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (descriptor < 0) {
    return errno;
  }
  close(descriptor);
  return 0;
}

/* Fill `address` with the abstract name `name`, and answer its length.
**
** An abstract name is a leading NUL followed by the bytes, and the address
** length is what delimits it -- there is no terminator. */
static socklen_t hetoimasia_abstract_address(struct sockaddr_un *address,
                                             const char *name) {
  size_t length = strlen(name);
  if (length > sizeof(address->sun_path) - 1) {
    length = sizeof(address->sun_path) - 1;
  }
  memset(address, 0, sizeof(*address));
  address->sun_family = AF_UNIX;
  memcpy(address->sun_path + 1, name, length);
  return (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + length);
}

int hetoimasia_probe_bind_abstract(const char *name) {
  struct sockaddr_un address;
  socklen_t length = hetoimasia_abstract_address(&address, name);
  int descriptor = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (descriptor < 0) {
    return errno;
  }
  if (bind(descriptor, (struct sockaddr *)&address, length) != 0 ||
      listen(descriptor, 4) != 0) {
    int saved = errno;
    close(descriptor);
    return saved;
  }
  /* Deliberately left open: an abstract name exists for exactly as long as the
  ** socket holding it, and the peer question is asked while both are alive. */
  return 0;
}

int hetoimasia_probe_connect_abstract(const char *name) {
  struct sockaddr_un address;
  socklen_t length = hetoimasia_abstract_address(&address, name);
  int descriptor = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (descriptor < 0) {
    return errno;
  }
  int outcome = connect(descriptor, (struct sockaddr *)&address, length);
  int saved = outcome != 0 ? errno : 0;
  close(descriptor);
  return saved;
}

int hetoimasia_probe_execute(const char *program) {
  int channel[2];
  if (pipe2(channel, O_CLOEXEC) != 0) {
    return errno;
  }
  pid_t child = fork();
  if (child < 0) {
    int saved = errno;
    close(channel[0]);
    close(channel[1]);
    return saved;
  }
  if (child == 0) {
    char *const arguments[] = {(char *)program, NULL};
    char *const environment[] = {NULL};
    close(channel[0]);
    execve(program, arguments, environment);
    {
      int failure = errno;
      ssize_t ignored = write(channel[1], &failure, sizeof(failure));
      (void)ignored;
    }
    _exit(127);
  }
  close(channel[1]);
  int failure = 0;
  ssize_t read_bytes;
  do {
    read_bytes = read(channel[0], &failure, sizeof(failure));
  } while (read_bytes < 0 && errno == EINTR);
  close(channel[0]);
  {
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
    }
  }
  return read_bytes == (ssize_t)sizeof(failure) ? failure : 0;
}

int hetoimasia_probe_load_module(const char *path, char *message,
                                 size_t length) {
  void *handle;
  if (length > 0) {
    message[0] = '\0';
  }
  dlerror();
  errno = 0;
  handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (handle != NULL) {
    dlclose(handle);
    return 0;
  }
  {
    const char *reported = dlerror();
    int saved = errno;
    if (length > 0 && reported != NULL) {
      snprintf(message, length, "%s", reported);
    }
    return saved != 0 ? saved : -1;
  }
}

int hetoimasia_probe_signal(int pid) {
  if (pid <= 0) {
    /* A caller with no process to name is not asking a question, and the
    ** negative and zero forms of `kill` address whole groups rather than one
    ** process. Neither is this probe. */
    return EINVAL;
  }
  errno = 0;
  if (kill((pid_t)pid, 0) == 0) {
    return 0;
  }
  return errno != 0 ? errno : EPERM;
}

int hetoimasia_probe_own_pid(void) { return (int)getpid(); }

int hetoimasia_probe_descriptor_open(int descriptor) {
  errno = 0;
  if (fcntl(descriptor, F_GETFD) != -1) {
    return 0;
  }
  return errno != 0 ? errno : EBADF;
}

int hetoimasia_probe_module_loaded(const char *path) {
  void *handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
  if (handle == NULL) {
    return 0;
  }
  dlclose(handle);
  return 1;
}

int hetoimasia_probe_executable_mapping(const char *path, int *with_exec,
                                        int *without_exec) {
  char page[64];
  void *mapped;
  int descriptor = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (descriptor < 0) {
    return -1;
  }
  memset(page, 0, sizeof(page));
  if (write(descriptor, page, sizeof(page)) != (ssize_t)sizeof(page)) {
    close(descriptor);
    return -1;
  }

  errno = 0;
  mapped = mmap(NULL, sizeof(page), PROT_READ | PROT_EXEC, MAP_PRIVATE,
                descriptor, 0);
  if (mapped == MAP_FAILED) {
    *with_exec = errno;
  } else {
    *with_exec = 0;
    munmap(mapped, sizeof(page));
  }

  errno = 0;
  mapped = mmap(NULL, sizeof(page), PROT_READ, MAP_PRIVATE, descriptor, 0);
  if (mapped == MAP_FAILED) {
    *without_exec = errno;
  } else {
    *without_exec = 0;
    munmap(mapped, sizeof(page));
  }

  close(descriptor);
  return 0;
}

int hetoimasia_probe_allocate(size_t bytes) {
  char *block = (char *)malloc(bytes);
  if (block == NULL) {
    return errno != 0 ? errno : ENOMEM;
  }
  /* Address space is not memory until something is written to it. */
  for (size_t offset = 0; offset < bytes; offset += 4096) {
    block[offset] = (char)(offset & 0x7f);
  }
  /* Deliberately retained: the experiment is about a limit being reached, and
  ** freeing each block as it is taken would never reach one. */
  return 0;
}

/* Set by the handler and read by nothing: the record is that the signal
** arrived and the process continued, which is what the parent observes from
** outside by having to escalate. */
static volatile sig_atomic_t hetoimasia_term_arrived = 0;

static void hetoimasia_note_term(int signal_number) {
  (void)signal_number;
  hetoimasia_term_arrived = 1;
}

int hetoimasia_confine_hold_term(void) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = hetoimasia_note_term;
  sigemptyset(&action.sa_mask);
  action.sa_flags = SA_RESTART;
  return sigaction(SIGTERM, &action, NULL);
}

unsigned long hetoimasia_raise_descriptor_limit(void) {
  struct rlimit descriptors;
  if (getrlimit(RLIMIT_NOFILE, &descriptors) != 0) {
    return 0;
  }
  if (descriptors.rlim_max != RLIM_INFINITY &&
      descriptors.rlim_cur < descriptors.rlim_max) {
    descriptors.rlim_cur = descriptors.rlim_max;
    (void)setrlimit(RLIMIT_NOFILE, &descriptors);
  }
  if (getrlimit(RLIMIT_NOFILE, &descriptors) != 0) {
    return 0;
  }
  return descriptors.rlim_cur == RLIM_INFINITY
             ? 1048576UL
             : (unsigned long)descriptors.rlim_cur;
}

unsigned long hetoimasia_confine_address_space_limit(void) {
  struct rlimit limit;
  if (getrlimit(RLIMIT_AS, &limit) != 0 || limit.rlim_cur == RLIM_INFINITY) {
    return 0;
  }
  return (unsigned long)limit.rlim_cur;
}

int hetoimasia_confine_has_sys_admin(void) {
  /* `capget` directly rather than libcap, which is a build dependency this
  ** repository does not have and would have to provision for one question.
  ** The effective set is the one that matters: a bounding-set entry the
  ** process does not actually hold would send it down the privileged path and
  ** fail at the first mount. */
  struct __user_cap_header_struct header;
  struct __user_cap_data_struct data[2];
  memset(&header, 0, sizeof(header));
  memset(data, 0, sizeof(data));
  header.version = _LINUX_CAPABILITY_VERSION_3;
  header.pid = 0;
  if (syscall(SYS_capget, &header, data) != 0) {
    return 0;
  }
  return (data[HETOIMASIA_CAP_INDEX(CAP_SYS_ADMIN)].effective &
          HETOIMASIA_CAP_MASK(CAP_SYS_ADMIN)) != 0;
}

int hetoimasia_confine_user_namespace_available(int *observed_errno) {
  int channel[2];
  *observed_errno = 0;
  if (pipe2(channel, O_CLOEXEC) != 0) {
    *observed_errno = errno;
    return 0;
  }
  pid_t child = fork();
  if (child < 0) {
    *observed_errno = errno;
    close(channel[0]);
    close(channel[1]);
    return 0;
  }
  if (child == 0) {
    /* The whole sequence, not just the `unshare`.
    **
    ** Creating the namespace is the easy half and answers the wrong question.
    ** On a distribution that restricts unprivileged user namespaces -- Ubuntu
    ** 24.04 and its derivatives do, by transitioning the creator into an
    ** AppArmor profile that denies every capability -- the `unshare` succeeds
    ** and the process then holds nothing inside the namespace it just made.
    ** What makes a namespace usable for confinement is writing the identity
    ** maps and unsharing a mount namespace under it, so that is what is
    ** attempted here and the first failure is what is reported. */
    char mapping[64];
    int failure = 0;
    if (unshare(CLONE_NEWUSER) != 0) {
      failure = errno;
    } else if (hetoimasia_write_whole("/proc/self/setgroups", "deny") != 0 &&
               errno != ENOENT) {
      failure = errno;
    } else {
      snprintf(mapping, sizeof(mapping), "0 %u 1\n", (unsigned)geteuid());
      if (hetoimasia_write_whole("/proc/self/uid_map", mapping) != 0) {
        failure = errno;
      } else if (unshare(CLONE_NEWNS) != 0) {
        failure = errno;
      }
    }
    ssize_t ignored = write(channel[1], &failure, sizeof(failure));
    (void)ignored;
    _exit(0);
  }
  close(channel[1]);
  int failure = EIO;
  ssize_t read_bytes;
  do {
    read_bytes = read(channel[0], &failure, sizeof(failure));
  } while (read_bytes < 0 && errno == EINTR);
  close(channel[0]);
  {
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
    }
  }
  if (read_bytes != (ssize_t)sizeof(failure)) {
    *observed_errno = EIO;
    return 0;
  }
  *observed_errno = failure;
  return failure == 0;
}
