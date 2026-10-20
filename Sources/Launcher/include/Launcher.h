#ifndef LAUNCHER_H
#define LAUNCHER_H

/// Makes this process its own "responsible process" for privacy permissions.
///
/// macOS charges a child process's TCC permissions (here: Reminders) to the app that started
/// it: Claude Code, a terminal, an agent host. Those apps may have no Reminders usage string,
/// in which case the request is refused without a prompt. This function starts a copy of the
/// running executable with responsibility disclaimed (a private but long-standing spawn
/// attribute), so the copy's own code signature and Info.plist decide, then waits for it and
/// exits with its status. The copy shares stdin, stdout and stderr, so a stdio server keeps
/// working. The copy sees `marker` in its environment and returns at once; so does a process
/// where spawning is impossible (then the parent's permissions apply). Loader variables
/// (DYLD_*) are not passed on to the copy.
///
/// Returns only in the process that should go on running.
void launcher_become_responsible(const char *marker);

#endif
