#ifndef HETOIMASIA_CONTENT_TEST_H
#define HETOIMASIA_CONTENT_TEST_H

/* Bind a UNIX-domain socket node at path and close the socket, leaving the
 * node behind. Returns 0, or the negated errno. */
int hetct_make_socket(const char *path);

#endif
