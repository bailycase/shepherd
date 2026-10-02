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
- The socket has **no token**. Instead, a connection speaks only for the agent whose `pi`
  process opened it: for every message that names an agent, the app checks that the process on
  the other end (the pid the kernel recorded when it connected) is the `pi` it started for that
  agent. A process an agent starts, such as its bash tool, can read `SHEPHERD_SOCKET` and the
  other agents' ids, and is refused for status, names, terminals, messages to peers, review,
  design requests and the browser, and cannot displace the real connection.
- **What is not covered.** The automation requests name no agent, so any process running as the
  same macOS user that can reach the socket can list, create, edit, start and stop automations.
  A same-user process that takes over an agent's own `pi` (a debugger, injection) is that agent.
  This is same-user IPC, not a sandbox. Keep `SHEPHERD_SUPPORT_DIR` private and under your own
  control.
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
  - type into terminals
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

### The Browser over the remote connection

A thread's Browser tab works across Macs ([browser.md](docs/browser.md#remote)), in two directions.
Both ride the authenticated connection (no TLS, so the same VPN or trusted network as everything
above) and neither has a switch yet.

- **A client reaching the host's ports.** A connected client can ask the host to carry a connection
  to one of the host's own **loopback** ports (`127.0.0.1`, then `::1`, never another address, so the
  host is not a proxy to its LAN, a metadata service or the internet), for a thread the client sees.
  It is capped (64 tunnels per client, 256 per host) and closed when idle. A token already lets a
  client type into the host's terminals, so this adds no privilege. On the viewing Mac the page's
  traffic to `localhost:<port>` goes through a listener on that Mac's own loopback at the same
  port: any program or page on the viewing Mac can reach the host's port through it while it is
  held, as with `ssh -L`.
- **A host's agent acting on the client's web view.** A client that shows a remote thread's Browser
  tab can own that thread's agent's browser, and then the host's agent drives a web view **on the
  client's Mac** (`browser.drive.v1`): it opens pages, reads them, clicks, types and runs script in
  them. What that lets a host (or anything that can make its agent say something, such as a page
  the agent reads) do to the client's Mac:
  - **It can** load the thread's host's own `localhost` ports (through the tunnel) and **public**
    addresses, and act on those pages as a person at a browser would, including pages the user signed
    in to in that tab. A public page it opens is an ordinary web page: it can send requests from the
    client's Mac to the client's own network, as any website can (blind requests; it cannot read the
    answers of another origin), and this is not blocked.
  - **It cannot** make the client open, read or act on a private, link-local, carrier-grade NAT,
    unique-local or reserved address, the client's own loopback or interface addresses, a
    local-network name, a hostname that resolves to any of those, or any scheme but `http`, `https`
    and `about:blank`. The client checks the address of the request, every redirect, every history
    step, every iframe and a script's own navigation, and a page it is on that is not allowed (an
    address or `file:` page the user opened) is never read back, not its text, title or address.
    The user's own address field is unbound. Only the host's own loopback ports, at most eight per
    page, are ever forwarded for an agent, and a port another program on the client already uses is
    refused.
  - **It cannot** drive a page the user has not left in front of it: ownership lasts while the tab is
    on screen and 30 seconds after, ends with the connection, is held by the most recent viewer to
    claim it, and the user's own click in the page, or Take over, stops the agent's actions until
    their next message. The ring and card are drawn over the page whenever the agent acts.
  - **Known gaps.** A name is resolved when it is checked and again when WebKit connects, so DNS
    rebinding is not caught by the check; subresource requests of a public page are not checked
    (WebKit's navigation policy does not see them); and a host can learn whether a loopback port is
    in use on the client's Mac by whether it may be forwarded. Do not connect a client Mac to a host
    you do not trust with the pages you open in that tab.

### Stored credentials on clients

- **macOS client:** host configurations, *including their tokens*, are stored as JSON in
  UserDefaults (`shepherd.remote.hosts`), not in the Keychain. Treat Shepherd's preferences as
  secrets.
- **iOS client (internal TestFlight; see [docs/ios](docs/ios/README.md)):** the host's name, address, and
  port go in UserDefaults. The token goes in the Keychain, device-only, available when unlocked.

### MCP server secrets

- **Where they live.** A header or environment value written as `${keychain:<server>/<NAME>}` in
  Settings ▸ MCP servers' file is stored in the Keychain on the host, never in the file. At an
  agent's launch the app puts the values the derived `mcp.json` refers to into pi's environment as
  `SHEPHERD_MCP_SECRET_<SERVER>_<NAME>`; the derived file in Shepherd's pi home holds only the
  names. OAuth tokens are pi's (`mcp-auth.json` in that home, mode `0600`).
- **Who can read them.** The model's shell commands run with every `SHEPHERD_MCP_SECRET_*`
  unset, and a local server is started so that it gets only the secrets its own entry names.
  Another process of the same user can still read a running process's environment (`ps eww`), and a
  server you point at a secret can do anything with it: this is the trust you gave the server.
  Native subagents and drafts get none.
- **A repo's own servers.** With Settings ▸ MCP servers ▸ Also use a repo's .mcp.json on (off by
  default) a repo's file can start any command as you, so turn it on only for repos you trust.
  Shepherd still keeps the app's values from it: its servers start with every Keychain value
  blanked, and its `env`, `headers` and `command` cannot refer to a `SHEPHERD_*` variable
  (`Tests/Extensions/mcp-project.test.mjs`). pi's trust prompt for a project's `.pi/mcp.json` is
  pi's own ([docs/mcp.md](docs/mcp.md)).

### Everything else Shepherd writes

- **Repository changes:** worktree creation, confirmed deletion and Finalize can change
  checkouts, commits and branches ([worktrees.md](docs/worktrees.md)). The Changes pane also
  supports confirmed per-file Revert, selected-file Commit with optional push/PR, and Undo/Redo
  of a recorded agent turn. Undo requires no extra confirmation and refuses when the turn's
  files changed afterward. Reading changes creates unreachable loose git objects through a
  private index; it does not write the user's index, working tree, HEAD, refs, stash or config.
  See [changes.md](docs/changes.md) for these separate mutation and refusal rules. Finalize
  never deletes a remote branch, and Shepherd never prunes worktrees.
- **pi configuration:** Shepherd runs its own pi, shipped inside the app, in its own home
  (`<support directory>/pi`: its settings, sign-ins, models and conversations;
  [pi-home.md](docs/pi-home.md)). It never runs your `pi` or `npm`, and never writes your pi's
  folder (`~/.pi/agent`, or wherever your `PI_CODING_AGENT_DIR` points), lock folders included.
  It reads it only as plain files: to copy an agent's earlier conversation into its own home once;
  at its first launch, to copy your logins (API keys and subscription sign-ins, as stored),
  custom providers, default model, trusted folders, instructions, skills, prompts, themes and
  extensions (these switched off) into its own home once (again only when you choose Re-import in
  Settings ▸ Pi); after that its pi reads only its own home. A copied subscription sign-in is a
  second holder of the same grant: when either pi refreshes it, the other may be signed out.
  Signing in (Settings ▸ Pi ▸ Sign-in, `/login`) runs pi's own login in Shepherd's home through a
  small script on the bundled node: the credential goes from pi straight into Shepherd's
  `auth.json`, and what you type (a key, a pasted code) goes to that script and nowhere else.
  Sign out removes only Shepherd's credential. Shepherd never logs a credential's value and shows
  a key only masked (its prefix and last four). Its launcher sets aside your shell's `PI_*`, `JITI_*` and `NODE_*`
  variables for pi itself and gives them back to an agent's shell commands. Extensions load
  through per-session `-e` flags, and Shepherd's pi loads no pi packages. It does not edit your
  shell startup files; terminals get theirs from Shepherd's support directory, and `pi` in a
  terminal is your own.
