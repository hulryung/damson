// SCM_RIGHTS fd passing. Lives in C because CMSG_SPACE/CMSG_LEN/CMSG_DATA are
// alignment macros that Swift does not import; hand-rolling their arithmetic in
// Swift is exactly the class of bug this file exists to avoid.

#include "include/cfdpass.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// How long cfd_send waits for the peer to make room: 200 rounds of at most 10 ms.
#define CFD_SEND_ROUNDS 200
#define CFD_SEND_ROUND_MS 10

long cfd_send(int sock, int fd, const void *payload, size_t n) {
    if (n == 0) {
        errno = EINVAL;
        return -1;
    }
    struct iovec iov = {.iov_base = (void *)payload, .iov_len = n};
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } ctrl;
    memset(&ctrl, 0, sizeof(ctrl));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl.buf;
    msg.msg_controllen = CMSG_SPACE(sizeof(int));

    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_SOCKET;
    cm->cmsg_type = SCM_RIGHTS;
    cm->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cm), &fd, sizeof(int));

    // A stream socket that has less room left than the control message does not block the
    // way a plain write would: macOS refuses the fd outright with EMSGSIZE. Every caller
    // sends a line just before the fd, and a line longer than the socket buffer is still
    // being read when this runs, so the refusal only means "not yet". Wait for the reader
    // to make room, but not forever — a peer that stopped reading is not coming back.
    // (Our control message is 16 bytes, never too large for an empty buffer, so EMSGSIZE
    // here is always this case.)
    for (int round = 0;; round++) {
        ssize_t r = sendmsg(sock, &msg, 0);
        if (r >= 0) return r;
        if (errno == EINTR) continue;
        if ((errno != EMSGSIZE && errno != ENOBUFS) || round >= CFD_SEND_ROUNDS) return -1;
        struct pollfd p = {.fd = sock, .events = POLLOUT, .revents = 0};
        (void)poll(&p, 1, CFD_SEND_ROUND_MS);
    }
}

long cfd_recv(int sock, int *out_fd, void *payload, size_t cap) {
    *out_fd = -1;
    struct iovec iov = {.iov_base = payload, .iov_len = cap};
    union {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } ctrl;
    memset(&ctrl, 0, sizeof(ctrl));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl.buf;
    msg.msg_controllen = CMSG_SPACE(sizeof(int));

    ssize_t r;
    do {
        r = recvmsg(sock, &msg, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0) return -1;

    for (struct cmsghdr *cm = CMSG_FIRSTHDR(&msg); cm != NULL; cm = CMSG_NXTHDR(&msg, cm)) {
        if (cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS &&
            cm->cmsg_len >= CMSG_LEN(sizeof(int))) {
            int fd;
            memcpy(&fd, CMSG_DATA(cm), sizeof(int));
            fcntl(fd, F_SETFD, FD_CLOEXEC);
            *out_fd = fd;
            break;
        }
    }
    if (msg.msg_flags & MSG_CTRUNC) {
        if (*out_fd >= 0) {
            close(*out_fd);
            *out_fd = -1;
        }
        errno = EMSGSIZE;
        return -1;
    }
    return r;
}
