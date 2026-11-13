#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "hetoimasia_terrain_storage.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <sys/mount.h>
#elif defined(__linux__)
#include <sys/vfs.h>
#else
#error "the terrain storage backend qualifies macOS and Linux only"
#endif

#ifndef O_CLOEXEC
#error "the terrain storage backend needs O_CLOEXEC"
#endif
#ifndef O_NOFOLLOW
#error "the terrain storage backend needs O_NOFOLLOW"
#endif

/* The largest offset an off_t holds. off_t is signed; every offset and length
 * is checked against it before it is converted, so nothing wraps. */
#define HTS_OFF_MAX ((uint64_t)INT64_MAX)

static int joined(const char *dir, const char *name, char *path, size_t cap) {
  int n = snprintf(path, cap, "%s/%s", dir, name);
  if (n < 0 || (size_t)n >= cap) return -ENAMETOOLONG;
  return 0;
}

int hts_create(const char *dir, const char *name, int *fd) {
  char path[PATH_MAX];
  int bad = joined(dir, name, path, sizeof path);
  if (bad != 0) return bad;
  int opened = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (opened < 0) return -errno;
  *fd = opened;
  return 0;
}

int hts_unlink(const char *dir, const char *name) {
  char path[PATH_MAX];
  int bad = joined(dir, name, path, sizeof path);
  if (bad != 0) return bad;
  return unlink(path) < 0 ? -errno : 0;
}

int hts_cloexec(int fd, int *flag) {
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0) return -errno;
  *flag = (flags & FD_CLOEXEC) != 0;
  return 0;
}

int hts_stat(int fd, uint64_t out[HTS_STAT_WORDS]) {
  struct stat st;
  if (fstat(fd, &st) < 0) return -errno;
  out[0] = (uint64_t)st.st_dev;
  out[1] = st.st_size < 0 ? 0 : (uint64_t)st.st_size;
  out[2] = st.st_blocks < 0 ? 0 : (uint64_t)st.st_blocks * 512u;
  out[3] = (uint64_t)st.st_nlink;
  out[4] = (uint64_t)st.st_mode;
  out[5] = (uint64_t)st.st_uid;
  return 0;
}

int hts_statfs(int fd, uint64_t out[HTS_STATFS_WORDS], char name[HTS_FSNAME_CAP]) {
  struct statfs sf;
  if (fstatfs(fd, &sf) < 0) return -errno;
  name[0] = '\0';
#if defined(__APPLE__)
  uint64_t unit = (uint64_t)sf.f_bsize;
  out[3] = 0;
  strncpy(name, sf.f_fstypename, HTS_FSNAME_CAP - 1);
  name[HTS_FSNAME_CAP - 1] = '\0';
#else
  uint64_t unit = sf.f_frsize > 0 ? (uint64_t)sf.f_frsize : (uint64_t)sf.f_bsize;
  out[3] = (uint64_t)sf.f_type;
#endif
  out[0] = unit;
  out[1] = (uint64_t)sf.f_blocks * unit;
  out[2] = (uint64_t)sf.f_bavail * unit;
  return 0;
}

int hts_reserve(int fd, uint64_t off, uint64_t len, uint64_t *reported) {
  if (off > HTS_OFF_MAX || len > HTS_OFF_MAX || len > HTS_OFF_MAX - off) return -EOVERFLOW;
  if (len == 0) return -EINVAL;
#if defined(__APPLE__)
  struct stat st;
  if (fstat(fd, &st) < 0) return -errno;
  if (st.st_size < 0 || (uint64_t)st.st_size != off) return -EINVAL;
  fstore_t store;
  memset(&store, 0, sizeof store);
  store.fst_flags = F_ALLOCATEALL;
  store.fst_posmode = F_PEOFPOSMODE;
  store.fst_offset = 0;
  store.fst_length = (off_t)len;
  if (fcntl(fd, F_PREALLOCATE, &store) < 0) return -errno;
  *reported = store.fst_bytesalloc < 0 ? 0 : (uint64_t)store.fst_bytesalloc;
  return 0;
#else
  /* mode 0 allocates the range and extends the file when it ends beyond EOF. */
  if (fallocate(fd, 0, (off_t)off, (off_t)len) < 0) return -errno;
  *reported = len;
  return 0;
#endif
}

int hts_set_length(int fd, uint64_t len) {
  if (len > HTS_OFF_MAX) return -EOVERFLOW;
  return ftruncate(fd, (off_t)len) < 0 ? -errno : 0;
}

int64_t hts_pread(int fd, void *buf, size_t n, uint64_t off) {
  if (off > HTS_OFF_MAX || n > (size_t)SSIZE_MAX || n > HTS_OFF_MAX - off) return -EOVERFLOW;
  ssize_t got = pread(fd, buf, n, (off_t)off);
  return got < 0 ? -(int64_t)errno : (int64_t)got;
}

int64_t hts_pwrite(int fd, const void *buf, size_t n, uint64_t off) {
  if (off > HTS_OFF_MAX || n > (size_t)SSIZE_MAX || n > HTS_OFF_MAX - off) return -EOVERFLOW;
  ssize_t put = pwrite(fd, buf, n, (off_t)off);
  return put < 0 ? -(int64_t)errno : (int64_t)put;
}

int hts_close(int fd) {
  return close(fd) < 0 ? -errno : 0;
}
