# Security policy

## Reporting a vulnerability

Do not report suspected vulnerabilities through public issues, discussions, or
pull requests.

Use [GitHub private vulnerability reporting](https://github.com/bailycase/shepherd/security/advisories/new).
If private reporting is unavailable, open a public issue stating only that you
need a private security contact. Do not include technical details.

Include:

- The affected Shepherd version or commit.
- The expected security boundary.
- The observed behavior and potential impact.
- Reproduction steps or a minimal reproducer.
- Any prerequisites required for exploitation.
- A proposed mitigation, if known.

Use test credentials and remove real tokens, private prompts, repository contents,
and personal information from supporting material.

## Documented security boundaries

The following behavior is part of Shepherd's current design:

- Remote access uses a bearer token but does not provide TLS. It assumes a VPN or
  trusted network as the transport boundary.
- The remote listener binds on all interfaces when enabled.
- The local Unix socket is same-user IPC and is not an authentication boundary.
- A process running as the same macOS user may be able to access local Shepherd
  state and sessions.

A report concerning one of these areas should show behavior outside the documented
boundary or a way to bypass its stated protections.

## Disclosure

Please allow time to investigate and prepare a fix before publishing vulnerability
details. Coordinate disclosure through the private advisory.
