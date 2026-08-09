// SCM_RIGHTS fd passing. Lives in C because CMSG_SPACE/CMSG_LEN/CMSG_DATA are
// alignment macros that Swift does not import; hand-rolling their arithmetic in
// Swift is exactly the class of bug this file exists to avoid.

#include "include/cfdpass.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

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

    ssize_t r;
    do {
        r = sendmsg(sock, &msg, 0);
    } while (r < 0 && errno == EINTR);
    return r;
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
