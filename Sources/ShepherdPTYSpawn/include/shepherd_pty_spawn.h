#ifndef SHEPHERD_PTY_SPAWN_H
#define SHEPHERD_PTY_SPAWN_H

#include <sys/types.h>
#include <sys/ioctl.h>

/// forkpty + exec with the child side in C. Between fork and exec the child may only make
/// async-signal-safe calls; Swift code there (even a `for` loop in an unoptimised build) can
/// take a runtime lock another thread held at fork time and deadlock or crash the child.
///
/// The child resets every signal disposition to SIG_DFL and clears the signal mask (the app may
/// ignore or block signals, and those survive exec), changes to `cwd` when given, and execs
/// `path`; on failure it writes `exec_fail_message` (if given) to stderr and exits 127.
///
/// Returns the child's pid in the parent and stores the pty's master side in `master_fd`, or -1
/// with errno set when forkpty fails. Every pointer must be valid C memory owned by the caller.
pid_t shepherd_forkpty_exec(int *master_fd,
                            struct winsize *size,
                            const char *path,
                            char *const argv[],
                            char *const envp[],
                            const char *cwd,
                            const char *exec_fail_message);

#endif
