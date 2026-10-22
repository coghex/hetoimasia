#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "hetoimasia_content.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_CLOEXEC
#error "hetoimasia-content needs O_CLOEXEC"
#endif
#ifndef O_NOFOLLOW
#error "hetoimasia-content needs O_NOFOLLOW"
#endif
#ifndef O_DIRECTORY
#error "hetoimasia-content needs O_DIRECTORY"
#endif

static int kind_of(mode_t mode) {
  switch (mode & S_IFMT) {
    case S_IFREG: return HETC_KIND_REGULAR;
    case S_IFDIR: return HETC_KIND_DIRECTORY;
    case S_IFLNK: return HETC_KIND_SYMLINK;
    case S_IFIFO: return HETC_KIND_FIFO;
    case S_IFSOCK: return HETC_KIND_SOCKET;
    case S_IFCHR: return HETC_KIND_CHAR_DEVICE;
    case S_IFBLK: return HETC_KIND_BLOCK_DEVICE;
    default: return HETC_KIND_OTHER;
  }
}

static void report(const struct stat *st, uint64_t out[5]) {
  out[0] = (uint64_t)kind_of(st->st_mode);
  out[1] = (uint64_t)st->st_dev;
  out[2] = (uint64_t)st->st_ino;
  out[3] = st->st_size < 0 ? 0 : (uint64_t)st->st_size;
  out[4] = (uint64_t)st->st_nlink;
}

int hetc_open_root(const char *path, int *fd) {
  int opened;
  do {
    opened = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  } while (opened < 0 && errno == EINTR);
  if (opened < 0) return -errno;
  *fd = opened;
  return 0;
}

int hetc_openat(int dirfd, const char *name, int want_dir, int *fd) {
  int flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY;
  if (want_dir) flags |= O_DIRECTORY;
  int opened;
  do {
    opened = openat(dirfd, name, flags);
  } while (opened < 0 && errno == EINTR);
  if (opened < 0) return -errno;
  *fd = opened;
  return 0;
}

int hetc_fstat(int fd, uint64_t out[5]) {
  struct stat st;
  if (fstat(fd, &st) != 0) return -errno;
  report(&st, out);
  return 0;
}

int hetc_fstatat_nofollow(int dirfd, const char *name, uint64_t out[5]) {
  struct stat st;
  if (fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return -errno;
  report(&st, out);
  return 0;
}

int hetc_fdopendir(int fd, void **dir) {
  DIR *stream = fdopendir(fd);
  if (stream == NULL) return -errno;
  *dir = stream;
  return 0;
}

int hetc_dirfd(void *dir) { return dirfd((DIR *)dir); }

int hetc_readdir(void *dir, char *buf, size_t cap, size_t *len) {
  errno = 0;
  struct dirent *entry = readdir((DIR *)dir);
  if (entry == NULL) return errno == 0 ? 1 : -errno;
  size_t n = strlen(entry->d_name);
  if (n > cap) return -ENAMETOOLONG;
  memcpy(buf, entry->d_name, n);
  *len = n;
  return 0;
}

int hetc_closedir(void *dir) {
  if (closedir((DIR *)dir) != 0) return errno == EINTR ? 0 : -errno;
  return 0;
}

int64_t hetc_read(int fd, void *buf, size_t n) {
  ssize_t got;
  do {
    got = read(fd, buf, n);
  } while (got < 0 && errno == EINTR);
  if (got < 0) return -(int64_t)errno;
  return (int64_t)got;
}

int hetc_close(int fd) {
  if (close(fd) != 0) return errno == EINTR ? 0 : -errno;
  return 0;
}

int hetc_fd_path(int fd, char *buf, size_t cap) {
#if defined(__APPLE__)
  char path[PATH_MAX];
  if (fcntl(fd, F_GETPATH, path) != 0) return -errno;
  size_t n = strlen(path);
  if (n > cap) return -ENAMETOOLONG;
  memcpy(buf, path, n);
  return (int)n;
#elif defined(__linux__)
  char link[64];
  snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
  ssize_t n = readlink(link, buf, cap);
  if (n < 0) return -errno;
  if ((size_t)n == cap) return -ENAMETOOLONG;
  return (int)n;
#else
  (void)fd; (void)buf; (void)cap;
  return -ENOSYS;
#endif
}
