/* The native layer of hetoimasia-content: every raw descriptor operation the
 * package performs, and nothing else. Each function returns 0 (or a count) on
 * success and the negated errno on failure, so Haskell never reads errno after
 * a safe foreign call, when another Haskell thread on the same capability could
 * have overwritten it. See packages/content/README.md for the flag choices. */
#ifndef HETOIMASIA_CONTENT_H
#define HETOIMASIA_CONTENT_H

#include <stddef.h>
#include <stdint.h>

/* The kinds hetc_fstat and hetc_fstatat_nofollow report in out[0]. */
enum {
  HETC_KIND_REGULAR = 0,
  HETC_KIND_DIRECTORY = 1,
  HETC_KIND_SYMLINK = 2,
  HETC_KIND_FIFO = 3,
  HETC_KIND_SOCKET = 4,
  HETC_KIND_CHAR_DEVICE = 5,
  HETC_KIND_BLOCK_DEVICE = 6,
  HETC_KIND_OTHER = 7
};

/* Open the launcher-selected path, following symbolic links anywhere in it,
 * as a directory. Close-on-exec. */
int hetc_open_root(const char *path, int *fd);

/* Open name beneath the directory dirfd without following a symbolic link in
 * the final component. want_dir adds O_DIRECTORY. The open never blocks on a
 * FIFO (O_NONBLOCK) and never makes a terminal the controlling terminal
 * (O_NOCTTY). Read-only; close-on-exec. */
int hetc_openat(int dirfd, const char *name, int want_dir, int *fd);

/* fstat of an opened descriptor. out receives kind, device, inode, size and
 * link count. */
int hetc_fstat(int fd, uint64_t out[5]);

/* A no-follow type query for name relative to dirfd. It classifies an entry
 * and never authorizes an open. */
int hetc_fstatat_nofollow(int dirfd, const char *name, uint64_t out[5]);

/* fdopendir: on success the stream owns fd; on failure fd is untouched. */
int hetc_fdopendir(int fd, void **dir);

/* The descriptor a stream owns, for fstat and directory-relative opens. It is
 * valid until hetc_closedir and must never be closed separately. */
int hetc_dirfd(void *dir);

/* The next name of a stream, structural entries included, copied into buf of
 * capacity cap (NUL excluded). Returns 0 with *len set, 1 at the end of the
 * stream, or a negated errno. */
int hetc_readdir(void *dir, char *buf, size_t cap, size_t *len);

/* closedir: releases the stream and its descriptor even when it reports an
 * error. */
int hetc_closedir(void *dir);

/* read(2), retried on EINTR. Returns the byte count (0 at end of file) or a
 * negated errno. */
int64_t hetc_read(int fd, void *buf, size_t n);

/* close(2). The descriptor is released even when this reports an error, and an
 * EINTR is therefore success: retrying could close a descriptor another thread
 * has since been given. */
int hetc_close(int fd);

/* The pathname the kernel reports for an opened descriptor, a diagnostic that
 * can be stale as soon as it returns. Returns its length or a negated errno. */
int hetc_fd_path(int fd, char *buf, size_t cap);

#endif
