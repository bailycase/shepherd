// Process-wide test isolation, installed once when the test bundle loads: before any test runs
// and before any thread could be reading the environment, which is the only safe moment to call
// setenv. Tests never mutate the environment themselves (see AGENTS.md "Testing").
//
// Every test process (and every exit-test child) gets its own scratch root:
//   support/  SHEPHERD_SUPPORT_DIR: extensions, themes, and shell integration install here,
//             never into the user's ~/Library/Application Support/Shepherd(-dev), even when the
//             run inherited SHEPHERD_SUPPORT_DIR from a Shepherd agent.
//   bin/      first on PATH, holding stand-ins that refuse to run for `gh` and `pi`, so no test
//             reaches the user's GitHub credentials or pi through a login shell. Tests that launch
//             pi the way the app does replace the `pi` one with the stub (StubPi.installOnPath).
//   zdotdir/  ZDOTDIR, so login shells spawned by tests never run the user's dotfiles. Its
//             .zshenv and .zlogin put bin/ back first: from a minimal environment (Xcode, launchd)
//             nix-darwin's /etc/zshenv replaces PATH, and macOS's path_helper in /etc/zprofile
//             moves the system directories ahead of it, either of which would find the real tools.
//   pi-agent/ PI_CODING_AGENT_DIR, so the session headers the app seeds and the pi config it
//             reads are scratch, never ~/.pi/agent. Skipped for the opt-in live-model use case
//             (SHEPHERD_LIVE_MODEL), which runs the user's real pi with their configuration.
//   agent-skills/  SHEPHERD_SKILLS_DIR, so Settings ▸ Skills installs, turns off and removes
//             skills there, never in the user's ~/.agents/skills.
// The root is removed when the process exits. Variables a Shepherd sets for its agents (a run
// started by an agent inherits them) are cleared, so nothing can reach the running Shepherd's
// socket through the environment.

#include "ShepherdTestIsolation.h"

#include <fcntl.h>
#include <removefile.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

static char root[512];

const char *shepherd_test_isolation_root(void) { return root; }

static void remove_root(void) {
    if (root[0] != '\0') removefile(root, NULL, REMOVEFILE_RECURSIVE);
}

static void fail(const char *what) {
    fprintf(stderr, "ShepherdTestIsolation: %s failed; refusing to run tests against the user's directories\n", what);
    abort();
}

static void make(const char *name, char *out, size_t size) {
    if ((size_t)snprintf(out, size, "%s/%s", root, name) >= size) fail("path");
    if (mkdir(out, 0700) != 0) fail("mkdir");
}

static void write_file(const char *directory, const char *name, const char *contents, mode_t mode) {
    char path[700];
    if ((size_t)snprintf(path, sizeof path, "%s/%s", directory, name) >= sizeof path) fail("path");
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, mode);
    if (fd < 0) fail("open");
    size_t length = strlen(contents);
    if (write(fd, contents, length) != (ssize_t)length) fail("write");
    if (close(fd) != 0) fail("close");
}

/// A `command` in bin/ that says why it will not run and exits 127, as a missing command would.
static void refuse(const char *bin, const char *command) {
    char script[256];
    if ((size_t)snprintf(script, sizeof script,
                         "#!/bin/sh\necho \"%s: out of reach of Shepherd's tests (Tests/ShepherdTestIsolation)\" >&2\nexit 127\n",
                         command) >= sizeof script) fail("path");
    write_file(bin, command, script, 0755);
}

/// Agent-only variables (AGENTS.md "Environment variables"), matched by prefix.
static const char *const agentVariables[] = {
    "SHEPHERD_AGENT_ID=", "SHEPHERD_SOCKET=", "SHEPHERD_EXT_", "SHEPHERD_NATIVE_CHILDREN=", "SHEPHERD_CHILD_",
    "SHEPHERD_NEEDS_NAME=", "SHEPHERD_AUTOMATION=", "SHEPHERD_MODEL=", "SHEPHERD_PI_THEME_",
    "SHEPHERD_INSTRUCTIONS_DIR=", "SHEPHERD_SUGGEST_FILES=",
};

/// The name of the first agent-only variable in the environment, or an empty string.
static void next_agent_variable(char *name, size_t size) {
    name[0] = '\0';
    for (char **entry = environ; *entry != NULL; entry++) {
        for (size_t i = 0; i < sizeof agentVariables / sizeof *agentVariables; i++) {
            if (strncmp(*entry, agentVariables[i], strlen(agentVariables[i])) != 0) continue;
            size_t length = strcspn(*entry, "=");
            if (length >= size) fail("unsetenv");
            memcpy(name, *entry, length);
            name[length] = '\0';
            return;
        }
    }
}

__attribute__((constructor))
static void shepherd_test_isolation_install(void) {
    char name[256];
    for (next_agent_variable(name, sizeof name); name[0] != '\0'; next_agent_variable(name, sizeof name)) {
        if (unsetenv(name) != 0) fail("unsetenv");
    }

    // sun_path caps socket paths at 104 bytes, and the support directory can hold one.
    const char *tmp = getenv("TMPDIR");
    const char *base = (tmp != NULL && tmp[0] != '\0' && strlen(tmp) <= 60) ? tmp : "/tmp";
    int length = (int)strlen(base);
    while (length > 1 && base[length - 1] == '/') length--;
    if ((size_t)snprintf(root, sizeof root, "%.*s/shepherd-tests-XXXXXX", length, base) >= sizeof root) fail("path");
    if (mkdtemp(root) == NULL) {
        root[0] = '\0';
        fail("mkdtemp");
    }
    atexit(remove_root);

    char support[600], bin[600], zdotdir[600], skills[600];
    make("support", support, sizeof support);
    make("bin", bin, sizeof bin);
    make("zdotdir", zdotdir, sizeof zdotdir);
    make("agent-skills", skills, sizeof skills);

    const char *path = getenv("PATH");
    if (path == NULL || path[0] == '\0') path = "/usr/bin:/bin";
    size_t pathSize = strlen(bin) + 1 + strlen(path) + 1;
    char *newPath = malloc(pathSize);
    if (newPath == NULL) fail("malloc");
    snprintf(newPath, pathSize, "%s:%s", bin, path);

    if (setenv("SHEPHERD_SUPPORT_DIR", support, 1) != 0 || setenv("ZDOTDIR", zdotdir, 1) != 0
        || setenv("SHEPHERD_SKILLS_DIR", skills, 1) != 0 || setenv("PATH", newPath, 1) != 0) fail("setenv");
    free(newPath);

    // zsh reads .zshenv for every shell and .zlogin last for a login shell, after the system files.
    if (strchr(bin, '\'') != NULL) fail("path");
    char startup[1400];
    if ((size_t)snprintf(startup, sizeof startup, "path=('%s' ${path:#'%s'})\n", bin, bin) >= sizeof startup) fail("path");
    write_file(zdotdir, ".zshenv", startup, 0600);
    write_file(zdotdir, ".zlogin", startup, 0600);
    refuse(bin, "gh");

    // The opt-in live-model run drives the user's real pi with their configuration.
    const char *liveModel = getenv("SHEPHERD_LIVE_MODEL");
    if (liveModel == NULL || liveModel[0] == '\0') {
        char piAgent[600];
        make("pi-agent", piAgent, sizeof piAgent);
        if (setenv("PI_CODING_AGENT_DIR", piAgent, 1) != 0) fail("setenv");
        refuse(bin, "pi");
    }
}
