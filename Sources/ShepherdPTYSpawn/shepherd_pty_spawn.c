#include "shepherd_pty_spawn.h"

#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <util.h>

pid_t shepherd_forkpty_exec(int *master_fd,
                            struct winsize *size,
                            const char *path,
                            char *const argv[],
                            char *const envp[],
                            const char *cwd,
                            const char *exec_fail_message) {
    pid_t pid = forkpty(master_fd, NULL, NULL, size);
    if (pid != 0) {
        return pid;
    }
    for (int sig = 1; sig < NSIG; sig++) {
        signal(sig, SIG_DFL);
    }
    sigset_t mask;
    sigemptyset(&mask);
    sigprocmask(SIG_SETMASK, &mask, NULL);
    // Only the pty (0, 1, 2) survives: an inherited pipe would keep another process's reader
    // waiting for EOF until this shell exits.
    for (int fd = STDERR_FILENO + 1, max = getdtablesize(); fd < max; fd++) {
        (void)close(fd);
    }
    if (cwd != NULL) {
        (void)chdir(cwd);
    }
    execve(path, argv, envp);
    if (exec_fail_message != NULL) {
        (void)write(STDERR_FILENO, exec_fail_message, strlen(exec_fail_message));
    }
    _exit(127);
}
