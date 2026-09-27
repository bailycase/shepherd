#ifndef SHEPHERD_TEST_ISOLATION_H
#define SHEPHERD_TEST_ISOLATION_H

/// The per-process scratch root the load-time constructor created (see ShepherdTestIsolation.c).
/// Holds `support/` (SHEPHERD_SUPPORT_DIR), `bin/` (first on PATH; its `pi-engine` is
/// SHEPHERD_PI_ENGINE), `zdotdir/` (ZDOTDIR), `pi-agent/` (PI_CODING_AGENT_DIR), and `pi-decoy/`
/// (where the startup files' decoys point).
const char *shepherd_test_isolation_root(void);

#endif
