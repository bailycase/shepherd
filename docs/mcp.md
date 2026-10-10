# MCP servers

> Read when you change Settings ▸ MCP servers, how an agent gets its MCP tools, the pi engine's MCP support, or what MCP costs in a prompt.

Agents use MCP servers through **pi's own MCP implementation** (built into pi 1.0). Shepherd adds
what pi has no equivalent of: the page that edits the servers, the Keychain for their secrets, the
sign-in sheet, the status and tool list per server, and the switch for a repo's `.mcp.json`. This
page is the evidence about pi's MCP, observed on the pinned engine (`Tests/Extensions/pi-mcp.test.mjs`
runs real pi in RPC mode against local stand-in servers and fails when a pi bump changes any of it),
and the layering built on it.

## The layering

```text
~/.config/mcp/mcp.json                  the file the user owns, shared with other MCP clients
   │   Settings ▸ MCP servers edits it (MCPConfigFile: atomic, unknown keys kept, Shepherd's fields
   │   under each entry's `shepherd` key); secrets are ${keychain:…} references into Shepherd's Keychain
   ▼
MCPPiConfig.derive                      pure: that file + the page's choices → pi's format
   │   writes <pi home>/mcp.json (never the other direction; no secret value in it) and names the
   ▼   environment variables (SHEPHERD_MCP_SECRET_*) the Keychain values travel in
<pi home>/mcp.json ── read by pi's built-in MCP ── connects, lists, searches, calls, signs in
   ▲                         ▲
   │ pi mcp list --json      │ every agent launch: -e builtin:mcp -e builtin:tool-search, the secrets
   │ pi mcp login / logout   │ in the environment, and (switch on) shepherd-mcp-project.ts for the repo's
   │ (the page's status,     │ .mcp.json
   │  tool list, sign-in)    │
Settings ▸ MCP servers ──────┘
```

Nothing of Shepherd's runs a server, speaks MCP or stores a token. Servers a user adds, edits, switches
off or removes in the page are in `<home>/mcp.json` at the next agent launch; a running thread keeps the
servers it started with until it restarts (pi reads its config when a session starts, and no RPC command
reloads it).

## What pi's MCP does

Read from pi 1.0's docs (`.build/pi-engine/Resources/pi-engine/docs/mcp.md`) and its bundle, and checked
by `pi-mcp.test.mjs`.

**Files and trust.** pi reads `<agent dir>/mcp.json` (Shepherd's home, because `PI_CODING_AGENT_DIR` is its
own) and, only in a space pi trusts, `<project>/.pi/mcp.json`. No flag or variable names another file,
so Shepherd cannot point pi at `~/.config/mcp/mcp.json`: the file in the home is derived. The format is
`{"mcpServers": {name: entry}}`. Names are `[A-Za-z0-9_-]+`; two names that differ only by `-` and `_` are
one server. A bad entry is reported and skipped, the others run. pi never reads `~/.pi` here: its home is
the one it was given.

**Entries.** Stdio: `command`, `args`, `env`, `cwd`. HTTP (Streamable HTTP only): `url`, `headers`,
`oauth`. Both: `enabled`, `timeout` (seconds, default 60; progress resets it), `exposure`,
`toolExposure`, `description`. **A server with `"type": "sse"` is rejected** ("legacy SSE transport is not
supported"): the old Shepherd client spoke it; a user with such a server must use its Streamable HTTP URL.

**Where `${VAR}` expands.** Only in `env` and `headers` values, from pi's own environment (the login
shell's, since Shepherd starts pi from one). Not in `command`, `args`, `cwd` or `url` (a `${…}` in a URL
makes the entry fail to connect). `${VAR:-default}` is not a form: it reaches the server literally. A
variable that is not set fails the server ("Failed to resolve … from environment variable: NAME"). A
value that is entirely `!command` runs the command in `/bin/sh` (10 s, result cached for the process)
and uses its output; that is how a default or a quoted expansion can be had.

**Stdio servers inherit pi's whole environment.** pi starts a stdio server with its own environment plus the
entry's `env` (observed: a variable set only on pi was visible to the server, `NODE_OPTIONS` and
`PI_CODING_AGENT_DIR` included). So a secret handed to pi in the environment is visible to every stdio
server unless something removes it first (below).

**Exposure** decides what a server's tools cost in a prompt:

| Exposure | Declared to the model | Reached by | Notes |
| --- | --- | --- | --- |
| `codemode` (default) | nothing | `codemode` scripts, or `tool_search` | Reachable through native codemode when enabled. With codemode off and no deferred server, nothing can call them. Shepherd never writes it |
| `deferred` | nothing until `tool_search` loads a match | `tool_search`, then the tool by name | A search loads the best 8; they stay declared for the rest of the branch; an unloaded tool answers "Tool … not found" |
| `direct` | every tool, like a built-in | by name | |
| `hidden` | nothing | nothing | `toolExposure` can still expose chosen tools of a hidden server |

`toolExposure` maps tool names (or `*` patterns) to an exposure and wins over the server's. A server on
`hidden` with `toolExposure: {"search_code": "direct"}` offers exactly that tool.

pi adds an `mcp_servers` section to the system prompt for servers that are not direct (one line each, with
the server's `description` or the first line of its instructions), activates `tool_search` for a server that
needs it, and `codemode` only for `codemode` servers when that extension is on. Tools are named
`mcp__<server>__<tool>` (every character outside letters, digits and `_` becomes `_`; a collision gets a
hash suffix). A server with resources also gets `list_mcp_resources`, `list_mcp_resource_templates` and
`read_mcp_resource`, with the widest exposure among the servers that have them.

**What a prompt costs**, measured on the wire against a fake provider with one stdio stand-in whose catalog
has 26 tools (a description and a five-property schema each; `Tests/Extensions/fixtures/fake-mcp-catalog.mjs`)
and pi's four default tools, no other extension. Characters of tool declarations plus system prompt:

| | Tools declared | Characters | About tokens (÷4) | Over no MCP |
| --- | --- | --- | --- | --- |
| No MCP | 4 | 5,930 | 1,483 | |
| Before: the one `mcp` tool (the old default) | 5 | 6,731 | 1,683 | +200 |
| Before: each tool on its own | 30 | 23,285 | 5,821 | +4,338 |
| pi `deferred` | 5 | 6,819 | 1,705 | +222 |
| pi `deferred`, after one search (8 loaded) | 13 | 13,103 | 3,276 | +1,793 |
| pi `direct` | 30 | 24,565 | 6,141 | +4,658 |

The context budget guard (`scripts/context-budget.json`, docs/context-budget.md) keeps measuring this on a real pi with three stand-in servers: `tool_search` with its server list is 206 tokens and a Direct server's ten GitHub-shaped tools 1,326.

So Search costs what the old `mcp` tool cost; what it saves is the old "Each tool on its own" (and the
same choice made Direct). A direct tool is about 211 tokens here and grows with the schema.

**Results and events.** A call is an ordinary tool call: `tool_execution_start` with the tool name and
arguments, `tool_execution_end` with `result.content`, `result.details` (`{server, tool}`) and `isError`;
`structuredContent` comes back too. Text over 20 KB loses its middle; images are image blocks. A
`codemode` script's calls are the same events with an id like `call_1/2` and a `parentToolCallId`, beside
`tool_execution_update`s for the script itself. Each nested call has its own activity row.

**OAuth** is pi's: `pi mcp login <server>` registers pi as a client (`oauth.clientName` changes the name),
prints the authorization URL on stdout (`Sign in to MCP server "x" in your browser:` then the URL), opens
it with `open`, waits for the redirect on a loopback port (300 s, `--timeout`), and stores the tokens in
`<home>/mcp-auth.json` (0600), keyed by server name and URL. It runs with no terminal. A server that needs
it reports `needs-auth`; `pi mcp logout` deletes the entry. `oauth` also takes `clientId`, `clientSecret`
(a `${VAR}` or `!command` works), `callbackPort`, `scope` and `authServerMetadataUrl`. Only HTTP servers
with no `Authorization` header use it.

Settings > Spaces > MCP servers also offers Sign in and Sign out for both space file
formats, using the same sheet as global settings. Add and sign in saves first. A host-owned
SDK bridge loads only the selected HTTP entry and uses pi's native OAuth implementation,
without changing global configuration, loading space extensions or calling a model.
Tokens stay in that host's pi home, available to its threads; the viewer receives only status.
Remote sign-in opens the viewer's browser. A loopback-only listener accepts the pending
callback path and state, then returns the redirect to the host. Pi verifies state and PKCE.
The existing remote listener has no TLS. Use trusted/private transport or an encrypted tunnel,
not the public internet. Command-based secret resolvers are not executed by this settings action.
Four active sign-ins per host, one flow per server namespace, a five-minute deadline and
sixteen retained results bound the work. Login-shell-only variables in shared-file URLs resolve
after an explicit sign-in; status checks do not start a shell just to expand them. Cancel, navigation, disconnection and host shutdown close pending work. Restart never
resumes it. Remote hosts advertise `projects.mcp.v1`; older hosts require an update.

### Space approval and thread loading

Saving configuration or signing in does not approve a space. The OAuth bridge explicitly
loads one selected entry, so it can save credentials even while Pi blocks `.pi/mcp.json` in
RPC threads. The space page labels that state "Credentials saved", not a live connection.

For `.pi/mcp.json`, the page checks the selected host's Pi trust decision separately. An
undecided or denied folder shows "Space configuration blocked" and "Trust this space…".
The confirmation explains that trust also allows executable extensions, settings, skills, MCP
commands and configured package installation. It approves only the selected canonical folder
through Pi's `ProjectTrustStore` in `<support>/pi/trust.json`, with Pi's interprocess locking.
No parent-folder approval, global "always" setting or blanket `--approve` launch flag is added.
Pi inherits this decision in descendant folders, which the confirmation also explains.
Inherited saved decisions and Pi's global default are read using Pi's own implementation.
The home folder remains excluded and its threads retain `--no-approve`, even if Pi has a saved
approval or an "always" default.

The check and save use the bundled SDK without creating a Pi session, loading project
resources, connecting MCP servers or calling a provider. They have a ten-second deadline.
Normal new-thread startup then resolves the saved decision, loads `.pi/mcp.json` through
`builtin:mcp`, and registers tools after connection. Deferred tools are available through
`builtin:tool-search` and codemode's `ALL_TOOLS`. Existing threads need restarting. MCP must
also be enabled under Settings > Pi > Bundled extensions. Approval permits loading, but does
not establish a connection or tool catalog; those belong to each thread.

Remote hosts advertise `projects.trust.v1`. Approval goes to that host over the existing
authenticated connection; older hosts show an update-required reason. Failure never turns
into approval, and a confirmation for another host or folder cannot apply to a new selection.
The shared `.mcp.json` file keeps its separate "Also use a repo's .mcp.json" opt-in.

`ProjectMCPTrustTests` uses the bundled Pi RPC startup and a local scripted provider and MCP
server. It verifies that undecided resources stay blocked, approval registers a deferred tool
that search discovers and codemode calls, siblings stay blocked, and home protection wins
over saved approval and the global default. All homes, credentials and space data are scratch.
`ProjectMCPTrustPreviewTests` renders only when `SHEPHERD_PREVIEW_DIR` is set, like the other
preview suites. Normal CI runs the protocol capability checks without rendering screenshots.

**The CLI.** `pi mcp list [--json]` connects to every enabled server and prints each one's name, `state`
(`connected`, `needs-auth`, `failed`, `disabled`, …), `exposure`, `transport`, tool names, `error` and any
config errors; it exits 1 when something is not connected. Tool names only: no descriptions or schemas.
`pi mcp login|logout|add|remove` work without a session and load no extension. **A subcommand must be pi's
first argument:** `pi -e x mcp list` is not a subcommand, which the launcher's own `-e` would cause.

**A tool a search loaded does not survive a restart of pi.** Checked on pi 1.0.0 with a stand-in server: pi starts
again on a session in the RPC mode Shepherd runs (`--session-id`), the transcript records the load, and the first
request declares only the launch's tools, so the model searches again. (pi's docs and changelog say a load survives
`/tree`, resume and fork; `/tree` does.) Shepherd restores its own deferred tools from the transcript
(the status extension), not an MCP server's, which connect after pi starts.

**In a session.** `/mcp` over RPC answers (`disposition: handled`) with a notice listing this thread's
servers: `name: connected, 9 tools (deferred)`, a failure with its stderr tail, `disabled`. `/mcp reconnect
<server>` works the same way. pi reads `mcp.json` once, at `session_start`; editing the file under a running
pi changes nothing, and `/reload` over RPC is not handled (it is sent to the model as a prompt). pi tells
the user once at startup which servers failed or need sign-in.

**Extensions.** `pi.registerMcpServer(name, config)` adds a server for the session, in the same shape as an
entry, connected with the file's; a server of the same name in `mcp.json` wins. `pi mcp` does not see
registered servers.

**The built-ins are loaded by default and switched off by `-builtin:mcp` in the `extensions` setting** (what
Shepherd's home carries, so helpers and the model catalog start none). An explicit `-e builtin:mcp` on the
command line wins over that switch; `--no-extensions` loads none unless named.

## How Shepherd maps onto it

**The derived file** (`MCPPiConfig`, written to `<home>/mcp.json` whenever it differs, by temp file and
rename, so a half-written file is never read):

| In the user's file | In pi's |
| --- | --- |
| `mcpServers` and VS Code's `servers`, `type`, `command`, `args`, `cwd`, `url`, `headers`, `env` | the same entry, only the keys pi knows |
| `shepherd.enabled: false` | `enabled: false` |
| `shepherd.exposure`: `proxy` (the old default) or absent | `exposure: "deferred"`, always written, never pi's default |
| `shepherd.exposure: "direct"` | `exposure: "direct"` |
| `shepherd.tools` (Choose which tools…) | `exposure: "hidden"` and `toolExposure` giving each chosen tool the server's mode |
| `shepherd.timeoutSeconds`, when set | `timeout` |
| `shepherd.oauth` (client ID, secret, scopes) | `oauth.clientId`, `oauth.clientSecret`, `oauth.scope`, and `oauth.clientName: "Shepherd"` on a server that signs in |
| `shepherd.start`, `shepherd.idleMinutes` | dropped: pi connects every enabled server when a session starts and keeps it |
| `${keychain:<server>/<NAME>}` in `env` or a header | `${SHEPHERD_MCP_SECRET_<SERVER>_<NAME>}` |
| `${VAR:-default}` in `env` or a header | the whole value as `!printf '%s' "…"`, which `/bin/sh` expands |
| `${…}` in `command` or `args` | the server is started through `zsh -f -c` that expands them first (below) |
| `${…}` in `url`, or in `cwd`; `type: "sse"`; a name pi rejects | not written; the page shows why on that server's row |

**Secrets** stay in the Keychain (`MCPSecretStore`, unchanged: same service, same account names, so every
saved secret still works). At an agent launch the app reads the Keychain values the derived file refers to
and puts them in pi's environment as `SHEPHERD_MCP_SECRET_*`; nothing writes one to disk. Two things keep
them from spreading:

- The model's shell commands: `restore-env.sh` unsets every `SHEPHERD_MCP_SECRET_*` before each bash
  command. (`ps` on the same user can still show a process's environment; so can a stdio server's own
  configuration, which is the same trust the user gave the server.)
- Other servers: with any secret in play, every stdio entry is started as `/bin/zsh -f -c '<assign
  arguments>; unset -m "SHEPHERD_MCP_SECRET_*"; exec "${a[@]}"'`, so a server gets the secrets its own `env`
  names (pi expanded them into other variable names) and never the others'. Native subagents and drafts
  drop every `SHEPHERD_*` variable already.

**OAuth tokens** are pi's, in `<home>/mcp-auth.json` beside `auth.json`. The Keychain items Shepherd's own
OAuth kept (`oauth/<server>`) are not carried over (they belong to a client registration pi cannot reuse),
so each OAuth server asks for one new sign-in, and the items are deleted. Signing in and out run `pi mcp
login` and `pi mcp logout` in the home, through the launcher.

**The page's status and tool list** are `pi mcp list --json` run in the home with the same environment,
once when the page opens (and after any edit, Reconnect, or sign-in): `connected` with its tool names,
`needs-auth` as Needs sign-in, `failed` with pi's error, `disabled` as Off. Nothing is cached on disk.

**Which agents get it.** An agent Shepherd starts (a thread, an automation) gets `-e builtin:mcp -e
builtin:tool-search` while Settings ▸ Pi ▸ Bundled extensions ▸ MCP servers is on. `tool_search` also loads
Shepherd's own deferred tools (the browser, other-thread, automation and review tools, docs/context-budget.md ›
Deferred tools), so with Settings ▸ Agents ▸ Defer rarely used tools on a thread's or an automation's launch has
`-e builtin:tool-search` even with MCP off (it wins over the home's `-builtin:tool-search`, like MCP's). A design's agent, a
native subagent, a draft and the model catalog do not (`--no-extensions` or no flag). Native codemode
defaults on for primary agents, with a global switch and trusted-space override. To keep a space's
`.pi/mcp.json` server reachable when codemode is off, set its `exposure` to `deferred` or `direct`.

**A repo's `.mcp.json`** (Settings ▸ MCP servers ▸ Also use a repo's .mcp.json, off by default): with
the switch on, `shepherd-mcp-project.ts` registers the servers of the `.mcp.json` found at the agent's
folder or the nearest ancestor holding `.git`, through `pi.registerMcpServer`, as `deferred`, minus
names the user's file defines. It reads nothing of the Keychain and never writes the repo. It is the one
piece of MCP that runs in the agent's pi. The repo's file is not trusted with the app's values: pi starts a
stdio server with its own whole environment, which carries the `SHEPHERD_MCP_SECRET_*` values, so the
extension blanks each of them in the server's `env`, and it expands a `${SHEPHERD_*}` reference in the file to
its default or nothing (checked against the version without both: the server read the token). A repo's file
can still start any command as the user, which is why the switch is off by default.

## In the thread

A server's tool is an ordinary tool call, so it reads as an activity line (`NativeMCPActivity`, shared with
the iOS client): "Called search_issues" with "github · label:bug" (the server, then the first of the call's
`query`, `q`, `url`, `path`, `pattern`, `name`, `title`, `text` or `command`), "Calling …" while it runs, "…
failed" with pi's reason. The server and tool come from the call's name (`mcp__<server>__<tool>`, pi's
sanitized spelling), because the projection keeps no result `details`. `tool_search` is "Searched tools" with
the query, and "8 loaded" on its expanded row. Calls nested in a script have independent rows,
including failures the script handles. Pi's saved `nestedCalls` restores call arguments and status;
Shepherd retains bounded text excerpts in the parent's display-only details. Older native logs show
when output was not saved. See [codemode settings](design/codemode-settings.md).

## Not covered

Servers whose only transport is legacy SSE; `${…}` in a URL; `shepherd.start` (a server starts with each
session instead of when first used, so every enabled stdio server runs once per agent: switch off the ones
that are rarely wanted); a refreshed list in a running thread; Shepherd's own tool search and cache.
