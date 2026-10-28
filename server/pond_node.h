/* The C side of pond_node.goose: the OpenBSD sandbox. A Goose bool is a
   uint8_t in C. */
#include <limits.h>
#include <unistd.h>

#ifdef __OpenBSD__
static int pond_unveil(sl_u8 dir, const char *name, const char *perm) {
    char p[PATH_MAX];
    if (dir.len < 0 || dir.len + strlen(name) >= sizeof p) return 0;
    memcpy(p, dir.data, (size_t)dir.len);
    strcpy(p + dir.len, name);
    return unveil(p, perm) == 0;
}
#endif

/* The daemon sees only the entries and the keys (read only), its store
   (read and write) and the template (read only), and it cannot run a
   program. The template can be missing.
   Call it after the listening sockets are open. On other systems this does
   nothing: systemd and launchd give the limits there. */
uint8_t pond_node_sandbox(sl_u8 pond, sl_u8 store, sl_u8 template) {
#ifdef __OpenBSD__
    if (!pond_unveil(pond, "/entries", "r") || !pond_unveil(pond, "/keys", "r")
        || !pond_unveil(store, "", "rwc")) return 0;
    pond_unveil(template, "", "r");
    return unveil(NULL, NULL) == 0 && pledge("stdio rpath wpath cpath flock inet", NULL) == 0;
#else
    (void)pond;
    (void)store;
    (void)template;
    return 1;
#endif
}
