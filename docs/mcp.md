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
own) and, only in a project pi trusts, `<project>/.pi/mcp.json`. No flag or variable names another file,
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
| `codemode` (default) | nothing | `codemode` scripts, or `tool_search` | With pi's codemode extension off (Shepherd's default) and no deferred server, nothing can call them, yet the system prompt still says to use codemode scripts. Shepherd never writes it |
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

So Search costs what the old `mcp` tool cost; what it saves is the old "Each tool on its own" (and the
same choice made Direct). A direct tool is about 211 tokens here and grows with the schema.

**Results and events.** A call is an ordinary tool call: `tool_execution_start` with the tool name and
arguments, `tool_execution_end` with `result.content`, `result.details` (`{server, tool}`) and `isError`;
`structuredContent` comes back too. Text over 20 KB loses its middle; images are image blocks. A
`codemode` script's calls are the same events with an id like `call_1/2` and a `parentToolCallId`, beside
`tool_execution_update`s for the script itself (checked with codemode on; Shepherd leaves it off).

**OAuth** is pi's: `pi mcp login <server>` registers pi as a client (`oauth.clientName` changes the name),
prints the authorization URL on stdout (`Sign in to MCP server "x" in your browser:` then the URL), opens
it with `open`, waits for the redirect on a loopback port (300 s, `--timeout`), and stores the tokens in
`<home>/mcp-auth.json` (0600), keyed by server name and URL. It runs with no terminal. A server that needs
it reports `needs-auth`; `pi mcp logout` deletes the entry. `oauth` also takes `clientId`, `clientSecret`
(a `${VAR}` or `!command` works), `callbackPort`, `scope` and `authServerMetadataUrl`. Only HTTP servers
with no `Authorization` header use it.

**The CLI.** `pi mcp list [--json]` connects to every enabled server and prints each one's name, `state`
(`connected`, `needs-auth`, `failed`, `disabled`, …), `exposure`, `transport`, tool names, `error` and any
config errors; it exits 1 when something is not connected. Tool names only: no descriptions or schemas.
`pi mcp login|logout|add|remove` work without a session and load no extension. **A subcommand must be pi's
first argument:** `pi -e x mcp list` is not a subcommand, which the launcher's own `-e` would cause.

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
builtin:tool-search` while Settings ▸ Pi ▸ Bundled extensions ▸ MCP servers is on. A design's agent, a
native subagent, a draft and the model catalog do not (`--no-extensions` or no flag). `codemode` stays off:
a trusted project's own `.pi/mcp.json` server with pi's default exposure is then unreachable, so a
project that wants one sets `exposure` to `deferred` or `direct` in that file.

**A repo's `.mcp.json`** (Settings ▸ MCP servers ▸ Also use a repo's .mcp.json, off by default): with
the switch on, `shepherd-mcp-project.ts` registers the servers of the `.mcp.json` found at the agent's
folder or the nearest ancestor holding `.git`, through `pi.registerMcpServer`, as `deferred`, minus
names the user's file defines. It reads nothing of the Keychain and never writes the repo. It is the one
piece of MCP that runs in the agent's pi. The repo's file is not trusted with the app's values: pi starts a
stdio server with its own whole environment, which carries the `SHEPHERD_MCP_SECRET_*` values, so the
extension blanks each of them in the server's `env`, and it expands a `${SHEPHERD_*}` reference in the file to
its default or nothing (checked against the version without both: the server read the token). A repo's file
can still start any command as the user, which is why the switch is off by default.

## Not covered

Servers whose only transport is legacy SSE; `${…}` in a URL; `shepherd.start` (a server starts with each
session instead of when first used, so every enabled stdio server runs once per agent: switch off the ones
that are rarely wanted); a refreshed list in a running thread; Shepherd's own tool search and cache.
