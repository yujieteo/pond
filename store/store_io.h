/* The C side of store.goose: the file calls that the os module has no form
   of (a descriptor kept open, pread, flock and unlock, fsync, ftruncate).
   A Goose bool is a uint8_t in C. With -DSTORE_FAULTS, the variable
   STORE_CRASH_AFTER=<n> kills the process with SIGKILL when its writes
   reach n bytes, part way through a record if n falls in one: the crash
   tests use it. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static int store_cpath(char *p, sl_u8 path) {
    if (path.len < 0 || path.len >= PATH_MAX) return 0;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    return 1;
}

/* A descriptor, or -1. To write, the file is made if it is not there, and
   each write goes at its end. */
int32_t store_open(sl_u8 path, uint8_t write) {
    char p[PATH_MAX];
    if (!store_cpath(p, path)) return -1;
    int fd = write ? open(p, O_RDWR | O_CREAT | O_APPEND, 0644) : open(p, O_RDONLY);
    return (int32_t)fd;
}

/* A new empty file for a compaction, in place of any file at that path. */
int32_t store_create(sl_u8 path) {
    char p[PATH_MAX];
    if (!store_cpath(p, path)) return -1;
    return (int32_t)open(p, O_RDWR | O_CREAT | O_TRUNC | O_APPEND, 0644);
}

void store_close(int32_t fd) {
    if (fd >= 0) close(fd);
}

/* An exclusive flock. It locks against each other open of the file, other
   threads of this process included. */
uint8_t store_lock(int32_t fd) {
    while (flock(fd, LOCK_EX) != 0) {
        if (errno != EINTR) return 0;
    }
    return 1;
}

void store_unlock(int32_t fd) {
    flock(fd, LOCK_UN);
}

int64_t store_size(int32_t fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    return (int64_t)st.st_size;
}

/* The inode of an open file and of a path, or -1: a compaction puts a new
   file at the path. */
int64_t store_inode(int32_t fd) {
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    return (int64_t)st.st_ino;
}

int64_t store_path_inode(sl_u8 path) {
    char p[PATH_MAX];
    struct stat st;
    if (!store_cpath(p, path) || stat(p, &st) != 0) return -1;
    return (int64_t)st.st_ino;
}

/* Appends n bytes of the file from offset at to out. */
uint8_t store_read(int32_t fd, int64_t at, int64_t n, gs_rref out) {
    uint8_t buf[65536];
    while (n > 0) {
        size_t want = n < (int64_t)sizeof buf ? (size_t)n : sizeof buf;
        ssize_t got = pread(fd, buf, want, (off_t)at);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return 0;
        gs_bld_append(out, buf, (int64_t)got);
        at += got;
        n -= got;
    }
    return 1;
}

#ifdef STORE_FAULTS
static int64_t store_budget = -2;
#endif

/* Writes all of data at the end of the file. */
uint8_t store_write(int32_t fd, sl_u8 data) {
    const uint8_t *p = data.data;
    int64_t n = data.len;
#ifdef STORE_FAULTS
    if (store_budget == -2) {
        const char *s = getenv("STORE_CRASH_AFTER");
        store_budget = s ? strtoll(s, NULL, 10) : -1;
    }
    int crash = 0;
    if (store_budget >= 0 && n >= store_budget) {
        n = store_budget;
        crash = 1;
    }
    if (store_budget >= 0) store_budget -= n;
#endif
    while (n > 0) {
        ssize_t w = write(fd, p, (size_t)n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return 0;
        p += w;
        n -= w;
    }
#ifdef STORE_FAULTS
    if (crash) kill(getpid(), SIGKILL);
#endif
    return 1;
}

/* The data on the disk, not only in the cache. On macOS, fsync does not
   empty the cache of the disk itself, and F_FULLFSYNC does. */
uint8_t store_sync(int32_t fd) {
#ifdef F_FULLFSYNC
    if (fcntl(fd, F_FULLFSYNC) == 0) return 1;
#endif
    return fsync(fd) == 0;
}

uint8_t store_truncate(int32_t fd, int64_t size) {
    return ftruncate(fd, (off_t)size) == 0 && store_sync(fd);
}

/* A new name or a rename in a directory is on the disk only after an
   fsync of the directory. */
uint8_t store_sync_dir(sl_u8 path) {
    char p[PATH_MAX];
    if (!store_cpath(p, path)) return 0;
    int fd = open(p, O_RDONLY);
    if (fd < 0) return 0;
    int ok = fsync(fd) == 0;
    close(fd);
    return ok;
}
