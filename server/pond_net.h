/* The C side of the sockets of pond_node.goose and pond_shadow.goose: TCP
   on a numeric IPv4 or IPv6 address. Each connection has a time limit of
   5 s on each read and each write, so that a slow client cannot hold a
   thread. A Goose bool is a uint8_t in C. */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

/* A write to a closed connection gives EPIPE, not a signal that kills
   the process. */
void pond_no_sigpipe(void) {
    signal(SIGPIPE, SIG_IGN);
}

static struct addrinfo *pond_resolve(sl_u8 host, int32_t port, int passive) {
    char h[64], p[16];
    if (host.len <= 0 || host.len >= (int64_t)sizeof h) return NULL;
    memcpy(h, host.data, (size_t)host.len);
    h[host.len] = 0;
    snprintf(p, sizeof p, "%d", (int)port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV | (passive ? AI_PASSIVE : 0);
    if (getaddrinfo(h, p, &hints, &res) != 0) return NULL;
    return res;
}

static void pond_limit_time(int fd) {
    struct timeval tv = {5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

/* A listening socket on host and port, or -1. The address must be numeric,
   and not the unspecified address (0.0.0.0 or ::), so that the daemon
   listens only on the addresses that it is given. */
int32_t pond_listen(sl_u8 host, int32_t port) {
    struct addrinfo *a = pond_resolve(host, port, 1);
    if (a == NULL) return -1;
    int any = a->ai_family == AF_INET
        ? ((struct sockaddr_in *)a->ai_addr)->sin_addr.s_addr == htonl(INADDR_ANY)
        : IN6_IS_ADDR_UNSPECIFIED(&((struct sockaddr_in6 *)a->ai_addr)->sin6_addr);
    int fd = any ? -1 : socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    int on = 1;
    if (fd >= 0 && (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on) != 0
                    || bind(fd, a->ai_addr, a->ai_addrlen) != 0 || listen(fd, 128) != 0)) {
        close(fd);
        fd = -1;
    }
    freeaddrinfo(a);
    return (int32_t)fd;
}

/* The port of a listening socket: the one that the system chose for port 0. */
int32_t pond_bound_port(int32_t fd) {
    struct sockaddr_storage ss;
    socklen_t n = sizeof ss;
    if (getsockname(fd, (struct sockaddr *)&ss, &n) != 0) return -1;
    if (ss.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&ss)->sin_port);
    return ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
}

/* Waits for a connection on listener a or b (b can be -1), and accepts it.
   -1 if the wait or the accept fails. */
int32_t pond_accept(int32_t a, int32_t b) {
    struct pollfd p[2] = {{a, POLLIN, 0}, {b, POLLIN, 0}};
    if (poll(p, b >= 0 ? 2 : 1, -1) <= 0) return -1;
    int from = (p[0].revents & POLLIN) ? a : b;
    int fd = accept(from, NULL, NULL);
    if (fd >= 0) pond_limit_time(fd);
    return (int32_t)fd;
}

/* A connection to host and port, or -1 after 5 s. The connect does not
   block: on OpenBSD 8.0, a blocking connect on loopback from a process with
   many threads sometimes slept forever after the connection was made. Thus
   the wait is a poll of 100 ms at a time, and each time the socket itself
   tells if it is connected. */
int32_t pond_connect(sl_u8 host, int32_t port) {
    struct addrinfo *a = pond_resolve(host, port, 0);
    if (a == NULL) return -1;
    int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
    int flags = fd >= 0 ? fcntl(fd, F_GETFL) : -1;
    int ok = flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
    if (ok && connect(fd, a->ai_addr, a->ai_addrlen) != 0) {
        ok = 0;
        for (int i = 0; i < 50 && (errno == EINPROGRESS || errno == EINTR || errno == EALREADY); i++) {
            struct pollfd p = {fd, POLLOUT, 0};
            poll(&p, 1, 100);
            struct sockaddr_storage peer;
            socklen_t n = sizeof peer;
            int err = 0;
            socklen_t en = sizeof err;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &en) != 0 || err != 0) break;
            if (getpeername(fd, (struct sockaddr *)&peer, &n) == 0) { ok = 1; break; }
            errno = EINPROGRESS;
        }
    }
    freeaddrinfo(a);
    if (ok && fcntl(fd, F_SETFL, flags) == 0) {
        pond_limit_time(fd);
        return (int32_t)fd;
    }
    if (fd >= 0) close(fd);
    return -1;
}

/* Appends at most max bytes that came in to out. The count, 0 at the end
   of the input, or -1 on an error or at the time limit. */
int64_t pond_recv(int32_t fd, int64_t max, gs_rref out) {
    uint8_t buf[16384];
    size_t want = max < (int64_t)sizeof buf ? (size_t)max : sizeof buf;
    for (;;) {
        ssize_t got = recv(fd, buf, want, 0);
        if (got < 0 && errno == EINTR) continue;
        if (got > 0) gs_bld_append(out, buf, (int64_t)got);
        return (int64_t)got;
    }
}

/* Sends all of data. */
uint8_t pond_send(int32_t fd, sl_u8 data) {
    const uint8_t *p = data.data;
    int64_t n = data.len;
    while (n > 0) {
        ssize_t w = send(fd, p, (size_t)n, 0);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return 0;
        p += w;
        n -= w;
    }
    return 1;
}

void pond_close(int32_t fd) {
    if (fd >= 0) close(fd);
}
