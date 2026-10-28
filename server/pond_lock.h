/* The C side of the entry lock in pond_save.goose: an exclusive flock on
   one lock file. The file stays open, so the lock holds until the process
   exits. A Goose bool is a uint8_t in C. */
#include <fcntl.h>
#include <limits.h>
#include <sys/file.h>

uint8_t pond_lock(sl_u8 path) {
    char p[PATH_MAX];
    if (path.len < 0 || path.len >= (int64_t)sizeof p) return 0;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    int fd = open(p, O_RDWR | O_CREAT, 0600);
    return fd >= 0 && flock(fd, LOCK_EX) == 0;
}
