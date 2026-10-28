/* The C side of pond_read.goose: the OpenBSD sandbox, and the time of the
   last change of a file. A Goose bool is a uint8_t in C. */
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

static int pond_cpath(char *p, sl_u8 path) {
    if (path.len < 0 || path.len >= PATH_MAX) return 0;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    return 1;
}

/* Only the entries and the template are visible, read only, and the
   program cannot write or open a socket. An unveil of a path that is not
   there fails, and then that path stays hidden, which is what we want.
   On other systems this does nothing. */
uint8_t pond_sandbox(sl_u8 entries, sl_u8 template) {
#ifdef __OpenBSD__
    char p[PATH_MAX];
    if (pond_cpath(p, entries)) unveil(p, "r");
    if (pond_cpath(p, template)) unveil(p, "r");
    return unveil(NULL, NULL) == 0 && pledge("stdio rpath", NULL) == 0;
#else
    (void)entries;
    (void)template;
    return 1;
#endif
}

/* Seconds since the epoch of the last change of the file, or 0. */
int64_t pond_mtime(sl_u8 path) {
    char p[PATH_MAX];
    struct stat st;
    if (!pond_cpath(p, path) || stat(p, &st) != 0) return 0;
    return (int64_t)st.st_mtime;
}
