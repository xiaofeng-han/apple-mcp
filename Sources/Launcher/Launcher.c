#include "Launcher.h"

#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// Private libsystem SPI, present since macOS 10.14; looked up at run time so a missing symbol
// degrades to running without a separate identity instead of failing to launch.
typedef int (*disclaim_fn)(posix_spawnattr_t *attrs, int disclaim);

static volatile sig_atomic_t child = 0;

static void pass_on(int sig) {
    if (child > 0) kill((pid_t)child, sig);
}

static char **environment_for_child(const char *marker) {
    char **parent = *_NSGetEnviron();
    size_t count = 0;
    while (parent[count]) count++;
    char **env = calloc(count + 2, sizeof(char *));
    if (!env) return NULL;
    size_t used = 0;
    for (size_t i = 0; i < count; i++) {
        if (strncmp(parent[i], "DYLD_", 5) == 0) continue;
        env[used++] = parent[i];
    }
    size_t length = strlen(marker) + 3;
    char *flag = malloc(length);
    if (!flag) {
        free(env);
        return NULL;
    }
    snprintf(flag, length, "%s=1", marker);
    env[used++] = flag;
    env[used] = NULL;
    return env;
}

void launcher_become_responsible(const char *marker) {
    if (getenv(marker)) return;
    disclaim_fn disclaim = (disclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (!disclaim) return;

    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), path, sizeof path) <= 0) return;

    posix_spawnattr_t attrs;
    if (posix_spawnattr_init(&attrs) != 0) return;
    if (disclaim(&attrs, 1) != 0) {
        posix_spawnattr_destroy(&attrs);
        return;
    }
    char **env = environment_for_child(marker);
    if (!env) {
        posix_spawnattr_destroy(&attrs);
        return;
    }

    // Forward the usual termination signals to the copy while waiting for it.
    struct sigaction forward = {0};
    forward.sa_handler = pass_on;
    sigemptyset(&forward.sa_mask);
    int forwarded[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};
    for (size_t i = 0; i < sizeof forwarded / sizeof forwarded[0]; i++) sigaction(forwarded[i], &forward, NULL);

    char **argv = *_NSGetArgv();
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, path, NULL, &attrs, argv, env);
    posix_spawnattr_destroy(&attrs);
    if (spawned != 0) {
        // Run here after all, with the parent's permissions.
        struct sigaction standard = {0};
        standard.sa_handler = SIG_DFL;
        for (size_t i = 0; i < sizeof forwarded / sizeof forwarded[0]; i++) sigaction(forwarded[i], &standard, NULL);
        return;
    }
    child = pid;

    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (WIFEXITED(status)) _exit(WEXITSTATUS(status));
    // Die the same way, without a crash report of our own: that would be named like the copy's
    // and replace it.
    _exit(128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 1));
}
