# Security policy

## Reporting a vulnerability

Do not report suspected vulnerabilities in public issues, discussions, or pull requests. Use
[GitHub private vulnerability reporting](https://github.com/bailycase/shepherd/security/advisories/new).
If private reporting is unavailable, open a public issue that says only that you need a private
security contact, with no technical details.

Please include:

- the Shepherd version or commit
- the security boundary you expected, and what happened instead
- the potential impact
- reproduction steps or a minimal reproducer
- any prerequisites for exploitation
- a proposed mitigation, if you have one

Use test credentials. Remove real tokens, private prompts, repository contents, and personal
information from anything you attach. Allow time for a fix before publishing details, and
coordinate disclosure through the private advisory.

## What Shepherd trusts

Shepherd runs coding agents with your permissions. Each agent is a `pi` process started by the
app as your macOS user. The agent's tools, its extensions, and any native subagents it starts can
read and write whatever you can. Shepherd adds no sandbox. The workflow runner in the native
subagent extension is restricted JavaScript execution, not an OS sandbox
([native-subagents.md](docs/native-subagents.md)). Run untrusted work in an OS-contained
environment.

The boundaries below are deliberate. A report about one of them should show behavior outside
what is described here, or a way around the protection it states.

### The local extension socket

pi extensions report to the app over a Unix socket, `shepherd.sock` in Shepherd's support
directory (by default `~/Library/Application Support/Shepherd`, or `Shepherd Nightly` for
Shepherd Nightly, or wherever `SHEPHERD_SUPPORT_DIR` points).

- The support directory is created mode `0700`, and the socket is `0600`.
- The socket has **no authentication**. Any process running as the same macOS user that can
  reach it can speak as a known agent. That means reporting status, requesting panes, typing
  into that agent's terminal panes, messaging other agents, and managing automations.
- It is same-user IPC, not a security boundary. Keep `SHEPHERD_SUPPORT_DIR` private and under
  your own control.
- `state.json`, the installed extensions, and native subagent artifacts live in the same
  directory.

### The remote listener

A Mac can serve its agents to other devices. It is **off by default**. Turn it on in
Settings ▸ Remote ▸ Serve this Mac ▸ Listener.

- **Binding:** it binds TCP on **all IPv4 interfaces**, port 7433 by default (7434 in Shepherd
  Nightly).
- **Authentication:** a shared bearer token. The first frame must be a `hello` carrying the
  token from `remote-token` in the support directory. The token is 32 random bytes as hex,
  created with mode `0600` on first use. Any other first frame, or a wrong token, closes the
  connection.
- **No TLS.** The token and all traffic, including prompts, transcripts, terminal input and
  output, and uploaded files, cross the network in cleartext. The design assumes a VPN or
  trusted network is the transport boundary. **Never expose the listener to the internet.** The
  token only keeps other devices on that trusted network honest.
- **A token grants everything your user can do on the host.** A client can:
  - type into terminal panes
  - create agents that run pi with your credentials
  - send agents instructions
  - list host directories
  - upload files (up to 32 MiB each, into a private `0700` directory)
  - review diffs and revert files
  - create, finalize (commit, push, open PRs), and delete worktrees
- **Revoking:** delete `remote-token`, then turn the listener off and on (or relaunch
  Shepherd). A new token is generated, and every client must be given it again. The token is
  read when the listener starts, so deleting the file alone does not disconnect anyone.
- **Bind errors** appear in Settings ▸ Remote rather than being ignored.

### Stored credentials on clients

- **macOS client:** host configurations, *including their tokens*, are stored as JSON in
  UserDefaults (`shepherd.remote.hosts`), not in the Keychain. Treat Shepherd's preferences as
  secrets.
- **iOS client (deferred; see [docs/ios](docs/ios/README.md)):** the host's name, address, and
  port go in UserDefaults. The token goes in the Keychain, device-only, available when unlocked.

### Everything else Shepherd writes

- **Repository changes:** Shepherd changes repositories only through its worktree flows
  (create, finalize, delete; [worktrees.md](docs/worktrees.md)) and the review pane's
  confirmed per-file Revert. Finalize never deletes a remote branch, and Shepherd never prunes
  worktrees.
- **pi configuration:** Shepherd installs nothing into `~/.pi/agent/` and does not edit your
  shell startup files. Extensions load through per-session `-e` flags. Terminal panes get their
  startup files from Shepherd's support directory. `PiSessionFile` writes session files under
  pi's sessions directory, which pi treats as data.
