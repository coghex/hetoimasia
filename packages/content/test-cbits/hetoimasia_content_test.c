/* Test-only native helpers of the hetoimasia-content suite: the one fixture the
 * unix package cannot create, a UNIX-domain socket node. */
#include "hetoimasia_content_test.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int hetct_make_socket(const char *path) {
  struct sockaddr_un address;
  memset(&address, 0, sizeof address);
  address.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof address.sun_path) return -ENAMETOOLONG;
  strcpy(address.sun_path, path);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -errno;
  int status = bind(fd, (struct sockaddr *)&address, sizeof address);
  int saved = errno;
  close(fd);
  return status == 0 ? 0 : -saved;
}
