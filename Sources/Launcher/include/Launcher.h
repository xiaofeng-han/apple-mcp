#ifndef LAUNCHER_H
#define LAUNCHER_H

#include <sys/types.h>

/// Makes this process its own "responsible process" for privacy permissions.
///
/// macOS charges a child process's TCC permissions (Full Disk Access, Automation, Reminders) to
/// the app that started it: Claude Code, a terminal, an agent host. Those permissions would then
/// have to be granted to each of those apps, and many have no usage string for them, so the
/// request is refused without a prompt. This function starts a copy of the
/// running executable with responsibility disclaimed (a private but long-standing spawn
/// attribute), so the copy's own code signature and Info.plist decide, then waits for it and
/// exits with its status. The copy shares stdin, stdout and stderr, so a stdio server keeps
/// working. The copy sees `marker` in its environment and returns at once; so does a process
/// where spawning is impossible (then the parent's permissions apply). Loader variables
/// (DYLD_*) are not passed on to the copy.
///
/// Returns only in the process that should go on running.
void launcher_become_responsible(const char *marker);

/// Starts `path` with `argv` and `envp` (both NULL-terminated) in `directory`, with its
/// responsibility for privacy permissions disclaimed, so it gets none of this app's (Full
/// Disk Access, Automation, Reminders). It runs in a session of its own, with no terminal: stdin is /dev/null, and
/// stdout and stderr go to `output_fd`. No other descriptor is inherited. Returns 0 and sets `*pid`,
/// or returns an errno value.
int launcher_spawn_disclaimed(const char *path, char *const argv[], char *const envp[], const char *directory, int output_fd,
                              pid_t *pid);

/// Whether this process runs in a sandbox (an agent's, such as Codex's seatbelt profile). There,
/// macOS keeps the app's permissions out of reach (the Notes database, Automation, Reminders: they
/// read as never asked, and asking fails). 0 when the check is unavailable.
int launcher_is_sandboxed(void);

#endif
