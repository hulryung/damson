#ifndef CFDPASS_H
#define CFDPASS_H

#include <stddef.h>

/// Send one file descriptor over a SOCK_STREAM unix socket via SCM_RIGHTS,
/// alongside `n` bytes of payload (must be >= 1 — ancillary data cannot travel
/// on an empty message). Returns bytes sent, or -1 with errno set.
long cfd_send(int sock, int fd, const void *payload, size_t n);

/// Receive up to `cap` payload bytes and at most one fd. On return, *out_fd is
/// the received descriptor (with FD_CLOEXEC set) or -1 if the message carried
/// none. Returns bytes received (0 = EOF), or -1 with errno set. If the control
/// message was truncated (MSG_CTRUNC), any received fd is closed and errno is
/// set to EMSGSIZE.
long cfd_recv(int sock, int *out_fd, void *payload, size_t cap);

#endif
