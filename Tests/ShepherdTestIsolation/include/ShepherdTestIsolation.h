#ifndef SHEPHERD_TEST_ISOLATION_H
#define SHEPHERD_TEST_ISOLATION_H

/// The per-process scratch root the load-time constructor created (see ShepherdTestIsolation.c).
/// Holds `support/` (SHEPHERD_SUPPORT_DIR), `bin/` (first on PATH), and `zdotdir/` (ZDOTDIR).
const char *shepherd_test_isolation_root(void);

#endif
