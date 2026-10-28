/* The C side of pond_shadow.goose: run a CGI program as slowcgi runs it,
   with only the CGI variables, no input, and a pipe for its output. A
   Goose bool is a uint8_t in C. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

/* Other threads can run programs at the same time. This lock keeps the
   pipe of one child out of the others: no child starts between the pipe
   and the close-on-exec flag. */
static pthread_mutex_t pond_spawn_lock = PTHREAD_MUTEX_INITIALIZER;

/* Runs program with the variables in env (one NAME=value on each line),
   and appends its output to out. False if it cannot run, or if it does
   not exit with 0. */
uint8_t pond_run_cgi(sl_u8 program, sl_u8 env, gs_rref out) {
    char prog[PATH_MAX], vars[8192], *envp[32];
    if (program.len <= 0 || program.len >= (int64_t)sizeof prog || env.len >= (int64_t)sizeof vars) return 0;
    memcpy(prog, program.data, (size_t)program.len);
    prog[program.len] = 0;
    memcpy(vars, env.data, (size_t)env.len);
    vars[env.len] = 0;
    int n = 0;
    for (char *s = vars; *s && n < 31; ) {
        envp[n++] = s;
        char *nl = strchr(s, '\n');
        if (!nl) break;
        *nl = 0;
        s = nl + 1;
    }
    envp[n] = NULL;
    int fds[2];
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    char *argv[] = {prog, NULL};
    pid_t pid;
    int spawned = 0;
    pthread_mutex_lock(&pond_spawn_lock);
    if (pipe(fds) == 0) {
        fcntl(fds[0], F_SETFD, FD_CLOEXEC);
        fcntl(fds[1], F_SETFD, FD_CLOEXEC);
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
        spawned = posix_spawn(&pid, prog, &fa, NULL, argv, envp) == 0;
        close(fds[1]);
    } else {
        fds[0] = -1;
    }
    pthread_mutex_unlock(&pond_spawn_lock);
    posix_spawn_file_actions_destroy(&fa);
    if (fds[0] < 0) return 0;
    uint8_t buf[65536];
    ssize_t got;
    while ((got = read(fds[0], buf, sizeof buf)) != 0) {
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) break;
        gs_bld_append(out, buf, (int64_t)got);
    }
    close(fds[0]);
    int status = 0;
    if (!spawned) return 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
