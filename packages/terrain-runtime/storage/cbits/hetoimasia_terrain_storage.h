/* The native layer of the terrain storage backend: every raw descriptor
 * operation it performs, and nothing else. Each function returns 0 (or a
 * count) on success and the negated errno on failure, so Haskell never reads
 * errno after a safe foreign call, when another Haskell thread on the same
 * capability could have overwritten it.
 *
 * Every function is called through a `safe` foreign import: a call may block in
 * the kernel for as long as the filesystem takes, and a `safe` call lets the
 * other Haskell threads keep running on the other capabilities while it does.
 * None is `interruptible`: an asynchronous exception never tries to interrupt a
 * call in progress, and no call here may be abandoned (packages/terrain-runtime
 * README, "The storage backend").
 *
 * The reservation is a native allocation and nothing else: F_PREALLOCATE with
 * F_ALLOCATEALL on macOS, fallocate(2) with mode 0 on Linux. There is no
 * posix_fallocate (which zero-writes a file in user space or in libc when the
 * filesystem lacks the call) and no write loop: a platform or filesystem
 * without the native call reports ENOTSUP. */
#ifndef HETOIMASIA_TERRAIN_STORAGE_H
#define HETOIMASIA_TERRAIN_STORAGE_H

#include <stddef.h>
#include <stdint.h>

/* The number of words hts_stat fills. */
#define HTS_STAT_WORDS 6
/* The number of words hts_statfs fills, and the capacity of its name buffer. */
#define HTS_STATFS_WORDS 4
#define HTS_FSNAME_CAP 32

/* Create dir/name exclusively (O_CREAT|O_EXCL), read-write, mode 0600,
 * close-on-exec, never following a symbolic link in the final component. */
int hts_create(const char *dir, const char *name, int *fd);

/* Unlink dir/name. */
int hts_unlink(const char *dir, const char *name);

/* fcntl(F_GETFD): *flag is 1 when FD_CLOEXEC is set, else 0. */
int hts_cloexec(int fd, int *flag);

/* fstat: out = device, size, allocated bytes (st_blocks * 512), link count,
 * mode, owner. */
int hts_stat(int fd, uint64_t out[HTS_STAT_WORDS]);

/* fstatfs on the descriptor itself (never a path): out = block size (the
 * fragment size where the platform reports one), total bytes, bytes available
 * to an unprivileged process (f_bavail, never f_bfree), the platform's
 * filesystem type number (f_type on Linux, 0 on macOS). name receives the
 * filesystem type name where the platform reports one (f_fstypename on macOS;
 * empty on Linux), NUL-terminated. */
int hts_statfs(int fd, uint64_t out[HTS_STATFS_WORDS], char name[HTS_FSNAME_CAP]);

/* Reserve [off, off + len) natively. On macOS the range must start at the
 * current end of the file (the call allocates from EOF and the file length is
 * unchanged); off is checked against the file size and a mismatch is EINVAL.
 * On Linux the range is allocated in place and the file grows to off + len when
 * it was shorter. *reported is the platform's own count of the bytes it
 * allocated (fst_bytesalloc on macOS; len on Linux, which reports none). Offsets
 * beyond the signed file offset (off_t) are EOVERFLOW. */
int hts_reserve(int fd, uint64_t off, uint64_t len, uint64_t *reported);

/* ftruncate to len (the signed offset limit is checked). */
int hts_set_length(int fd, uint64_t len);

/* One pread(2) / pwrite(2): the byte count (possibly short, and 0 at end of
 * file for pread) or a negated errno, EINTR included. The caller loops. */
int64_t hts_pread(int fd, void *buf, size_t n, uint64_t off);
int64_t hts_pwrite(int fd, const void *buf, size_t n, uint64_t off);

/* close(2), once. A failure is reported and never retried: the descriptor may
 * already be released. */
int hts_close(int fd);

#endif
