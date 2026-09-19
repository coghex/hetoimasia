/* The macOS confinement probe's native side: the two mechanisms under test and
 * the access attempts that decide whether they enforced anything.
 *
 * Nothing here is a production interface. It exists so LUA-15 can answer Q-5's
 * macOS row with observations rather than assumptions, and it is built only on
 * Darwin.
 *
 * Two conventions run through the probe functions. An access probe returns 0
 * when the operation was ALLOWED and the denying `errno` otherwise, because the
 * proof the issue asks for is a denial with the mechanism that produced it, not
 * a boolean. A `_install` function returns 0 on success and a negative value on
 * a failure the caller must turn into a typed refusal rather than continue past.
 */
#ifndef HETOIMASIA_MACOS_PROBE_H
#define HETOIMASIA_MACOS_PROBE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/* Install the per-instance sandbox profile on the calling process.
 *
 * `parameters` is a NULL-terminated key, value, key, value, ... array. Returns
 * 0 on success; on failure returns -1 and, when `error_out` is not NULL, stores
 * a malloc'd diagnostic the caller frees with hetoimasia_macos_confine_free.
 *
 * The underlying SPI is the one the active SDK marks "No longer supported"; the
 * verdict document, not this header, is where that costs something. */
int hetoimasia_macos_confine(const char *profile, const char *const *parameters, char **error_out);
void hetoimasia_macos_confine_free(char *error);

/* Is the sandbox SPI present at all on this system? 1 yes, 0 no. */
int hetoimasia_macos_confine_available(void);

/* Access attempts. 0 means the operation was ALLOWED; anything else is the
 * errno that denied it. */
int hetoimasia_macos_probe_read_file(const char *path);
int hetoimasia_macos_probe_connect_unix(const char *path);
int hetoimasia_macos_probe_exec(const char *path);

/* dlopen has no errno, so its denial is reported through dyld's own message,
 * which names the mechanism ("blocked by sandbox") when the sandbox is what
 * refused. Returns 0 when the module LOADED, 1 when it did not. */
int hetoimasia_macos_probe_dlopen(const char *path, char *message, size_t message_len);

/* The two ledgers the memory row has to distinguish: the physical footprint
 * jetsam accounts against, and the virtual size the threaded RTS inflates. */
int hetoimasia_macos_footprint(uint64_t *footprint, uint64_t *virtual_size);

/* The smallest RLIMIT_AS this process can install, found by descending search
 * with rlim_max preserved. Stores the last rejecting errno in `last_errno`.
 * Returns 0 on success, -1 when even the opening probe was rejected. */
int hetoimasia_macos_rlimit_as_floor(uint64_t *floor_bytes, int *last_errno);

/* Render an errno as "errno=<n>/<description>", the mechanism text a denial is
 * recorded with. */
void hetoimasia_macos_errno_text(int code, char *message, size_t message_len);

/* Parent side. */

/* Bind and listen on a Unix-domain socket, so a confined child's connect() is
 * answered by a real endpoint rather than by its absence. fd, or -errno. */
int hetoimasia_macos_listen_unix(const char *path);

/* Take one pending connection off an endpoint's backlog and drop it. 0 when one
 * was taken, -1 when the endpoint is gone. A backlog that is never drained
 * starts refusing, and a refusal is not a denial. */
int hetoimasia_macos_accept_and_close(int fd);
void hetoimasia_macos_shutdown_fd(int fd);
void hetoimasia_macos_close_fd(int fd);

/* Is the spawn-time jetsam memory limit SPI present? 1 yes, 0 no. */
int hetoimasia_macos_jetsam_available(void);

/* Spawn `path` with a fatal whole-process memory limit of `memory_mb`.
 *
 * `memory_mb` of 0 spawns with no limit at all. A negative return is the errno
 * that stopped the launch; the caller refuses admission rather than falling
 * back to an unlimited child. */
int hetoimasia_macos_spawn_limited(
  const char *path,
  char *const argv[],
  int memory_mb,
  int output_fd,
  int close_fd,
  pid_t *pid_out);

/* The jetsam flag word hetoimasia_macos_spawn_limited sets, for the record. */
int hetoimasia_macos_jetsam_flags(void);

#endif /* HETOIMASIA_MACOS_PROBE_H */
