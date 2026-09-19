/* See hetoimasia_macos_probe.h for the two return conventions. */

#include "hetoimasia_macos_probe.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/* Neither of the two mechanisms under test is declared by the active SDK.
 *
 * `sandbox_init_with_parameters` is absent from <sandbox.h>, which declares
 * only `sandbox_init` and marks the whole family "No longer supported"; the
 * symbol is nonetheless exported by the shared cache. `posix_spawnattr_setjetsam_ext`
 * is absent from <spawn.h> and exported by libsystem_kernel. Both are therefore
 * resolved through dlsym rather than linked, so a system that stops exporting
 * one produces this probe's typed refusal instead of a link failure -- which is
 * also the only way the "missing prerequisite" row can be observed at all. */
typedef int (*confine_fn)(const char *, uint64_t, const char *const *, char **);
typedef int (*jetsam_fn)(posix_spawnattr_t *, short, int, int, int);

/* Observed on macOS 26.6 (25G5065a): 0x04 alone is what makes the limit fatal
 * while the process is active, 0x08 alone never fires because a spawned child
 * is active. Both are set so the limit is terminal either way. */
#define HETOIMASIA_JETSAM_MEMLIMIT_ACTIVE_FATAL 0x04
#define HETOIMASIA_JETSAM_MEMLIMIT_INACTIVE_FATAL 0x08
#define HETOIMASIA_JETSAM_FLAGS \
  (HETOIMASIA_JETSAM_MEMLIMIT_ACTIVE_FATAL | HETOIMASIA_JETSAM_MEMLIMIT_INACTIVE_FATAL)

/* The jetsam band a mod helper is admitted into. It is deliberately a low,
 * ordinary band: the limit this probe measures is the fatal per-process cap,
 * not a claim about system-wide eviction order. */
#define HETOIMASIA_JETSAM_PRIORITY 40

static confine_fn lookup_confine(void)
{
  return (confine_fn)dlsym(RTLD_DEFAULT, "sandbox_init_with_parameters");
}

static jetsam_fn lookup_jetsam(void)
{
  return (jetsam_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_setjetsam_ext");
}

int hetoimasia_macos_confine_available(void)
{
  return lookup_confine() != NULL ? 1 : 0;
}

int hetoimasia_macos_confine(const char *profile, const char *const *parameters, char **error_out)
{
  if (error_out != NULL) {
    *error_out = NULL;
  }
  confine_fn confine = lookup_confine();
  if (confine == NULL) {
    if (error_out != NULL) {
      *error_out = strdup("sandbox_init_with_parameters is not exported by this system");
    }
    return -1;
  }
  char *reason = NULL;
  if (confine(profile, 0, parameters, &reason) != 0) {
    if (error_out != NULL) {
      *error_out = strdup(reason != NULL ? reason : "sandbox_init_with_parameters failed");
    }
    return -1;
  }
  return 0;
}

void hetoimasia_macos_confine_free(char *error)
{
  free(error);
}

int hetoimasia_macos_probe_read_file(const char *path)
{
  int descriptor = open(path, O_RDONLY | O_CLOEXEC);
  if (descriptor < 0) {
    return errno != 0 ? errno : EPERM;
  }
  /* A readable path is only evidence if it really yields its bytes. */
  char scratch[1];
  ssize_t taken = read(descriptor, scratch, sizeof scratch);
  int failure = taken < 0 ? (errno != 0 ? errno : EPERM) : 0;
  close(descriptor);
  return failure;
}

int hetoimasia_macos_probe_connect_unix(const char *path)
{
  int endpoint = socket(AF_UNIX, SOCK_STREAM, 0);
  if (endpoint < 0) {
    return errno != 0 ? errno : EPERM;
  }
  struct sockaddr_un address;
  memset(&address, 0, sizeof address);
  address.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof address.sun_path) {
    close(endpoint);
    return ENAMETOOLONG;
  }
  strncpy(address.sun_path, path, sizeof address.sun_path - 1);
  int failure = connect(endpoint, (struct sockaddr *)&address, (socklen_t)sizeof address) == 0
                  ? 0
                  : (errno != 0 ? errno : EPERM);
  close(endpoint);
  return failure;
}

int hetoimasia_macos_probe_exec(const char *path)
{
  pid_t child = 0;
  char *const argv[] = {(char *)path, NULL};
  /* posix_spawn reports the sandbox's refusal as its return value rather than
   * through errno, and never creates the child when it refuses. */
  int failure = posix_spawn(&child, path, NULL, NULL, argv, environ);
  if (failure != 0) {
    return failure;
  }
  int status = 0;
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
    /* retry */
  }
  return 0;
}

int hetoimasia_macos_probe_dlopen(const char *path, char *message, size_t message_len)
{
  if (message != NULL && message_len > 0) {
    message[0] = '\0';
  }
  dlerror();
  void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (handle != NULL) {
    dlclose(handle);
    return 0;
  }
  const char *reason = dlerror();
  if (message != NULL && message_len > 0) {
    snprintf(message, message_len, "%s", reason != NULL ? reason : "dlopen failed");
  }
  return 1;
}

int hetoimasia_macos_open_descriptors(int *sockets, char *summary, size_t summary_len)
{
  /* What this process actually holds, rather than what its policy says it may
   * reach. Descriptors 0, 1 and 2 are the ones the parent granted on purpose;
   * anything above them is something that leaked across the spawn, and a socket
   * above them is a peer endpoint the sandbox never got a chance to refuse. */
  int extra = 0;
  int socket_count = 0;
  size_t written = 0;
  if (summary != NULL && summary_len > 0) {
    summary[0] = '\0';
  }
  struct rlimit descriptors;
  rlim_t ceiling = 4096;
  if (getrlimit(RLIMIT_NOFILE, &descriptors) == 0 && descriptors.rlim_cur < ceiling) {
    ceiling = descriptors.rlim_cur;
  }
  for (int candidate = STDERR_FILENO + 1; (rlim_t)candidate < ceiling; candidate++) {
    if (fcntl(candidate, F_GETFD) < 0) {
      continue;
    }
    extra++;
    int kind = 0;
    socklen_t kind_len = (socklen_t)sizeof kind;
    int is_socket = getsockopt(candidate, SOL_SOCKET, SO_TYPE, &kind, &kind_len) == 0;
    if (is_socket) {
      socket_count++;
    }
    /* Name each one. "How many" cannot distinguish a descriptor the runtime
     * opened for itself after exec from one the parent leaked into it, and the
     * second is the only kind that matters. */
    char path[PATH_MAX];
    const char *what = "anonymous";
    if (is_socket) {
      what = "socket";
    } else if (fcntl(candidate, F_GETPATH, path) == 0) {
      what = path;
    }
    if (summary != NULL && written + 32 < summary_len) {
      int printed = snprintf(
        summary + written,
        summary_len - written,
        "%s%d=%s",
        written == 0 ? "" : ",",
        candidate,
        what);
      if (printed > 0) {
        written += (size_t)printed;
      }
    }
  }
  if (sockets != NULL) {
    *sockets = socket_count;
  }
  if (summary != NULL && summary_len > 0 && summary[0] == '\0') {
    snprintf(summary, summary_len, "none");
  }
  return extra;
}

int hetoimasia_macos_footprint(uint64_t *footprint, uint64_t *virtual_size)
{
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
  if (result != KERN_SUCCESS) {
    return -1;
  }
  if (footprint != NULL) {
    *footprint = (uint64_t)info.phys_footprint;
  }
  if (virtual_size != NULL) {
    *virtual_size = (uint64_t)info.virtual_size;
  }
  return 0;
}

int hetoimasia_macos_rlimit_as_floor(uint64_t *floor_bytes, int *last_errno)
{
  /* rlim_max is carried through unchanged on every attempt. Lowering it would
   * make the next, larger probe fail with EPERM and report a floor that is an
   * artefact of the search rather than of the address space. */
  uint64_t high = 1ULL << 44;
  uint64_t low = 1ULL << 20;
  int rejected = 0;
  struct rlimit current;
  if (getrlimit(RLIMIT_AS, &current) != 0) {
    return -1;
  }
  struct rlimit attempt;
  attempt.rlim_cur = (rlim_t)high;
  attempt.rlim_max = current.rlim_max;
  if (setrlimit(RLIMIT_AS, &attempt) != 0) {
    if (last_errno != NULL) {
      *last_errno = errno;
    }
    return -1;
  }
  while (high - low > (1ULL << 30)) {
    uint64_t middle = low + (high - low) / 2;
    attempt.rlim_cur = (rlim_t)middle;
    attempt.rlim_max = current.rlim_max;
    if (setrlimit(RLIMIT_AS, &attempt) == 0) {
      high = middle;
    } else {
      rejected = errno;
      low = middle;
    }
  }
  /* Leave the process as it was found: the caller goes on to run experiments
   * whose results a stray address-space limit would quietly change. */
  attempt.rlim_cur = current.rlim_cur;
  attempt.rlim_max = current.rlim_max;
  setrlimit(RLIMIT_AS, &attempt);
  if (floor_bytes != NULL) {
    *floor_bytes = high;
  }
  if (last_errno != NULL) {
    *last_errno = rejected;
  }
  return 0;
}

void hetoimasia_macos_errno_text(int code, char *message, size_t message_len)
{
  if (message == NULL || message_len == 0) {
    return;
  }
  if (code == 0) {
    snprintf(message, message_len, "no-error");
    return;
  }
  snprintf(message, message_len, "errno=%d/%s", code, strerror(code));
}

int hetoimasia_macos_listen_unix(const char *path)
{
  struct sockaddr_un address;
  memset(&address, 0, sizeof address);
  address.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof address.sun_path) {
    return -ENAMETOOLONG;
  }
  strncpy(address.sun_path, path, sizeof address.sun_path - 1);
  int endpoint = socket(AF_UNIX, SOCK_STREAM, 0);
  if (endpoint < 0) {
    return -(errno != 0 ? errno : EPERM);
  }
  /* The endpoint must never reach a helper as an inherited descriptor. A
   * path-based connect() denial says nothing about a live handle the child
   * already holds, so the sandbox's answer would not be the whole answer. The
   * spawn also asks for close-on-exec by default; this is the half that does
   * not depend on that flag existing. */
  if (fcntl(endpoint, F_SETFD, FD_CLOEXEC) != 0) {
    int failure = errno != 0 ? errno : EPERM;
    close(endpoint);
    return -failure;
  }
  unlink(path);
  if (bind(endpoint, (struct sockaddr *)&address, (socklen_t)sizeof address) != 0) {
    int failure = errno != 0 ? errno : EPERM;
    close(endpoint);
    return -failure;
  }
  /* A backlog and no accept is deliberate: connect() has to succeed for the
   * owner and be refused for everyone else, and nothing is ever sent. */
  if (listen(endpoint, 8) != 0) {
    int failure = errno != 0 ? errno : EPERM;
    close(endpoint);
    return -failure;
  }
  return endpoint;
}

int hetoimasia_macos_accept_and_close(int fd)
{
  /* The endpoint has to keep answering. A listening socket whose backlog is
   * never drained starts refusing with ECONNREFUSED, and a refused connection
   * from a confined helper is indistinguishable from a sandbox denial -- which
   * would turn the isolation proof into an accident of how many helpers had
   * connected before it. Nothing is ever read or written: the connection is
   * accepted and dropped. */
  for (;;) {
    int accepted = accept(fd, NULL, NULL);
    if (accepted >= 0) {
      close(accepted);
      return 0;
    }
    if (errno == EINTR) {
      continue;
    }
    return -1;
  }
}

void hetoimasia_macos_shutdown_fd(int fd)
{
  if (fd >= 0) {
    shutdown(fd, SHUT_RDWR);
  }
}

void hetoimasia_macos_close_fd(int fd)
{
  if (fd >= 0) {
    close(fd);
  }
}

int hetoimasia_macos_jetsam_available(void)
{
  return lookup_jetsam() != NULL ? 1 : 0;
}

int hetoimasia_macos_jetsam_flags(void)
{
  return HETOIMASIA_JETSAM_FLAGS;
}

int hetoimasia_macos_spawn_limited(
  const char *path,
  char *const argv[],
  int memory_mb,
  int output_fd,
  int close_fd,
  pid_t *pid_out)
{
  posix_spawnattr_t attributes;
  if (posix_spawnattr_init(&attributes) != 0) {
    return -(errno != 0 ? errno : EINVAL);
  }
  /* The child's stdout and stderr share one pipe. The protocol lines and an
   * RTS message about why the process died are both evidence, and interleaving
   * them costs nothing because the parser keeps what it cannot parse. */
  /* Everything the child does not explicitly receive is closed at exec.
   * Without it the child inherits whatever the parent happened to hold --
   * including another instance's listening endpoint, which would make the
   * isolation proof a statement about path policy rather than about reachable
   * handles. stdin is re-declared through a self-dup2 because this flag closes
   * it too, and a process whose descriptor 0 is free is a process whose next
   * open() becomes its standard input. */
  posix_spawnattr_setflags(&attributes, (short)POSIX_SPAWN_CLOEXEC_DEFAULT);

  posix_spawn_file_actions_t actions;
  int have_actions = 0;
  if (output_fd >= 0) {
    if (posix_spawn_file_actions_init(&actions) != 0) {
      posix_spawnattr_destroy(&attributes);
      return -(errno != 0 ? errno : EINVAL);
    }
    have_actions = 1;
    if (close_fd >= 0) {
      posix_spawn_file_actions_addclose(&actions, close_fd);
    }
    posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output_fd, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output_fd, STDERR_FILENO);
    if (output_fd != STDOUT_FILENO && output_fd != STDERR_FILENO) {
      posix_spawn_file_actions_addclose(&actions, output_fd);
    }
  }
  if (memory_mb > 0) {
    jetsam_fn jetsam = lookup_jetsam();
    if (jetsam == NULL) {
      posix_spawnattr_destroy(&attributes);
      if (have_actions) {
        posix_spawn_file_actions_destroy(&actions);
      }
      return -ENOSYS;
    }
    int failure = jetsam(
      &attributes,
      (short)HETOIMASIA_JETSAM_FLAGS,
      HETOIMASIA_JETSAM_PRIORITY,
      memory_mb,
      memory_mb);
    if (failure != 0) {
      posix_spawnattr_destroy(&attributes);
      if (have_actions) {
        posix_spawn_file_actions_destroy(&actions);
      }
      return -failure;
    }
  }
  pid_t child = 0;
  int failure = posix_spawn(&child, path, have_actions ? &actions : NULL, &attributes, argv, environ);
  posix_spawnattr_destroy(&attributes);
  if (have_actions) {
    posix_spawn_file_actions_destroy(&actions);
  }
  if (failure != 0) {
    return -failure;
  }
  if (pid_out != NULL) {
    *pid_out = child;
  }
  return 0;
}
