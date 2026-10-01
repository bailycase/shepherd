# Shepherd's own pi

Shepherd runs its own pi, in its own home, so that nothing it does changes the user's pi, and
nothing in the user's pi can break Shepherd. The engine (Node plus pi's bundle) ships inside the
app ([pi-engine.md](pi-engine.md)); this page is about where it runs and how it's started.

This is the "Bundled pi, isolated home" plan's phases 3 to 7: the switch, the imports from the
user's pi, the first launch's sheet, the user's extensions, opt-in, and native sign-in. Open in
terminal (8) comes later.

## Service tiers

`PiHome.install` also writes `shepherd-service-tier.ts`, which an agent's own pi (not the
launcher, so never a draft or a native child) loads with `-e`. The host keeps
`service-tier/<agent id>.json` (`{"tier":"fast"}`, mode 0600) for each agent in the home and
names it in `SHEPHERD_EXT_SERVICE_TIER`; the extension reads it on every provider request and
adds `service_tier` for the providers that take it (docs/service-tier.md). The file goes with its
agent. It reads the managed provider's `owned_by` from `shepherd-cliproxyapi.json` through the
launcher's `SHEPHERD_CLIPROXYAPI_CONFIG`, and never its key.

## Optional CLIProxyAPI

Settings ▸ Pi ▸ Sign-in connects to an existing CLIProxyAPI server with its address and API key.
`CLIProxyAPIStore` checks its `/models` endpoint on Connect and Refresh, with bounded responses,
timeouts and no redirects. A failed check leaves the previous connection unchanged.
`shepherd-cliproxyapi.json` in Shepherd's pi home holds the enabled flag, URL, literal key and last
successful model list together, written atomically with mode 0600. It is not part of imports.
Turn off keeps the connection; Forget removes it. Neither changes the external server.

`PiHome.install` installs `shepherd-cliproxyapi.ts` beside that file. The launcher supplies its
path with `-e` and pins `SHEPHERD_CLIPROXYAPI_CONFIG` for every pi it starts: agents, the model
catalog and drafts. Native helpers (subagents; [native-subagents.md](native-subagents.md)) are
not started through the launcher, so `shepherd-children.ts` does the same for them
(`managedProvider`, `childLaunch`): from the parent's pinned `SHEPHERD_CLIPROXYAPI_CONFIG` it passes
`-e <home>/shepherd-cliproxyapi.ts` (the extension beside the connection file) and keeps that one
variable after it has dropped every other `SHEPHERD_*` variable, and only while both files exist. A
helper can therefore run on a `cliproxyapi/<id>` model; with no connection it is launched exactly as
before, and a `cliproxyapi/…` model it can't see is refused with the providers it does have. The
extension is inert without configuration. It registers the distinct provider
`cliproxyapi`, so an imported `cpa` provider and its credentials remain untouched. Native provider
authentication uses the saved key literally, never as an environment reference or shell command.
Connect accepts only a key of printable ASCII, the characters a request header can carry: a
proxy's model list may not check keys, so discovery alone can't catch a pasted curly quote or
ellipsis, and pi's fetch would fail every request with only "Connection error." A key saved before
this check gets its cause in the turn's error instead.
The extension reads pi's bundled model metadata without fetching another catalog. A model newer
than that catalog (`gpt-6.1-sol` beside a known `gpt-6-sol`) takes the capabilities and thinking
levels of its owner's nearest earlier version of the same family, where a family is the name with
its version numbers set aside and a release date is never a version. It keeps its own name. Other
unknown models use conservative text-only defaults. Known proxy compatibility rules cover DeepSeek's role and
reasoning fields and Responses tool schemas. Only session-mode instances watch the local config;
updates wait until idle and never redirect an in-flight turn. The model catalog's fingerprint
includes the connection file. Configuration and credentials never travel to remote clients.

### Moving from an imported pi provider

There is no automatic migration of `pi-cliproxyapi-provider`. Both providers can coexist while
you verify the new connection. Existing `cpa/...` sessions keep their original provider until
you explicitly select a model under `cliproxyapi`.

1. In Settings ▸ Pi ▸ Sign-in ▸ CLIProxyAPI, enter your existing proxy address and API key,
   then Connect. Verify a new thread using a `cliproxyapi` model before retiring the old setup.
2. Change Settings ▸ Agents' default model and any explicit native-subagent default, agent
   profile, workflow or environment override using `cpa/...`. Switch the model in existing
   threads you plan to keep before disabling their old provider. Conversation history stays.
3. In Settings ▸ Pi ▸ From your pi ▸ Extensions, turn off `pi-cliproxyapi-provider`. This removes
   it from subsequent launches; existing processes keep loaded extension code until `/reload`
   or an app relaunch. Finish active work before relaunching.
4. The disabled extension's copied files and old `cpa` credential can remain without powering
   the new provider. Settings currently disables imported extensions, rather than deleting their
   copied files. Removing the package from your terminal pi alone does not remove Shepherd's
   independent copy. Nothing in this cutover requires deleting the terminal's configuration.

The old package can read `~/.pi/agent/pi-cliproxyapi-provider/config.json` and `~/.cache` even
when its code runs from Shepherd's imported copy. The managed provider reads neither. It also
does not import that package's aliases, per-model overrides, custom headers or environment
settings. A custom model alias that pi's bundled catalog cannot identify receives conservative
metadata; verify those models before switching. Don't disable the old provider first: restored
old `cpa` sessions follow pi's existing fallback rules, not the new provider's fallback guard.

## The home

Shepherd's pi home is `<support directory>/pi`, always: `~/Library/Application Support/Shepherd/pi`,
`…/Shepherd Nightly/pi`, `…/Shepherd-dev/pi` for the Dev scheme (which sets
`SHEPHERD_SUPPORT_DIR`), and the scratch `support/pi` in tests. It never comes from the app's own
`PI_CODING_AGENT_DIR`, which a Shepherd started from an agent's shell inherits. Nothing is shared
between editions.

pi keeps all of its state there: `settings.json`, `auth.json`, `models.json`, `sessions/`, and the
rest. Shepherd writes, whenever they differ (`PiHome.install`):

| File | What it is |
| --- | --- |
| `bin/pi` | The launcher: every pi Shepherd starts, and every `pi` an agent types, runs through it |
| `restore-env.sh` | Gives an agent's shell commands back what the launcher set aside |
| `.shepherd-pi-home` | The marker that names the folder as Shepherd's |
| `settings.json` | Shepherd's keys only: `shellCommandPrefix` (sourcing `restore-env.sh`), the `skills` filter that turns off `~/.agents/skills` (below), the user's switched-on extensions under `extensions`, and `packages` removed |
| `keychain-certificates.pem` | Every certificate the Mac's keychain trusts (a private CA for an internal proxy or MCP server), PEM, so Node — which otherwise trusts only its own bundled CAs — can trust it too. Missing, or empty, when the keychain holds none |

pi writes `settings.json` too (the TUI's `/settings`, the first `/login`), so Shepherd changes it
read-modify-write under pi's own lock (proper-lockfile's `settings.json.lock` folder, taken over
after 10 s as pi's is), by temp file and rename, and only when its keys differ. A `packages` key is
removed at every launch, with a note in the log: a user-scope package missing from `<home>/npm`
makes pi load the user's global npm install, even offline. A `bin/` that links out of the home is
refused rather than written through, and the agent waits on the reason.

**Only its own home.** pi reads skills from `$HOME/.agents/skills` besides its agent folder, for
every session (pi: `core/package-manager.js`, `addAutoDiscoveredResources`: `join(getHomeDir(),
".agents", "skills")`, each skill enabled unless `isEnabledByOverrides` finds a `!` pattern in the
global `skills` list matching its absolute path). Shepherd's `settings.json` carries
`!<HOME>/.agents/skills/**` (HOME as pi sees it, and its real path when that differs, escaped for
minimatch), so none of them load; the engine smoke tier proves it, with a control. A trusted
project inside the home folder but outside any repository makes pi look for `.agents/skills` in
every folder above it too; it passes over the home folder's only when that path equals `HOME` as
written (the folder's path is its real one), which holds on a Mac, whose HOME is a real path. The
smoke tier proves that case as well. A HOME that isn't its real path would let that one folder in
for such a project: Shepherd leaves HOME as it is. The children bridge lists only the home's
`skills/`. A trusted project's own `.agents/skills` still loads in its threads, as a project's
files do. Everything else Shepherd's pi reads of the user's (their
instructions, skills, prompts, themes, extensions) is a copy in the home (Imports).

## The launcher

`<home>/bin/pi` runs under `zsh -f`, so no startup file runs between it and pi. In order, it:

1. sets aside every `PI_*`, `JITI_*`, `NODE_*` and `OPENSSL_CONF` it was started with, as
   `_SHEPHERD_STASH_<name>` (their names in `_SHEPHERD_STASH_NAMES`), and unsets them, putting
   `NODE_EXTRA_CA_CERTS` back for corporate CAs — else, when the user set none and
   `keychain-certificates.pem` isn't empty, exporting it as `NODE_EXTRA_CA_CERTS` instead, so pi's
   requests trust what the Mac's keychain trusts (an internal proxy signed by a private root, say)
   as Settings' own checks already do. Node reads one `NODE_EXTRA_CA_CERTS` file, so a user's own
   corporate CA bundle always wins; nothing merges the two. The prefix isn't `SHEPHERD_`, which the
   children extension drops from a child's environment;
2. exports the pins: `PI_CODING_AGENT_DIR` (the home), `PI_PACKAGE_DIR` (the engine's package),
   `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1`, `PI_TELEMETRY=0`, and `PI_SUBAGENTS_TEMP_ROOT`;
3. refuses `install`, `remove`, `uninstall`, `update` and `config` (exit 2), pointing at
   Settings ▸ Pi;
4. execs the engine, or, when its files are missing, says so and exits 127 (the agent then waits
   on "Shepherd can't find its pi").

It is started from a login shell, which carries the user's PATH to pi's tools and their provider
keys to pi, after the shell's startup files have run, so nothing in them can undo the pins. pi puts
`<home>/bin` first on its bash tool's PATH, so a `pi` an agent types is Shepherd's too.

**The bash tool gets the user's environment back.** pi's bash tool runs commands with pi's own
environment, which would strip an agent's `npm test` of the user's `NODE_OPTIONS`. Shepherd's
`shellCommandPrefix` sources `restore-env.sh` before every command: it unsets the pins (and
`NODE_EXTRA_CA_CERTS`, which the launcher may have set to `keychain-certificates.pem` and isn't
one of them) and exports each variable the launcher set aside, as it was — so a command sees
`NODE_EXTRA_CA_CERTS` exactly as the user had it, never Shepherd's keychain export.

The MCP probe and the sign-in bridge (`PiSignIn.swift`) run the engine's node directly, not
through the launcher, so they carry the same fallback themselves (`PiLaunch.clearedEnvironment`).

Every launch is built by `PiLaunch` (pinned in `PiLaunchTests`):

```sh
# an agent
/bin/zsh -l -c "cd -- '<cwd>' && exec '<home>/bin/pi' --mode rpc \
  --session-dir '<home>/sessions/--<cwd>--' --session-id '<id>' [--model … --thinking …] -e …"
# the model catalog, from inside the home so no project's .pi applies
# get_available_models and get_state RPC records on stdin, then EOF; no prompt or saved session
/bin/zsh -l -c "cd -- '<home>' && exec '<home>/bin/pi' --mode rpc --no-session --no-tools --no-skills --no-prompt-templates --no-themes --no-context-files --no-approve"
# PR descriptions and commit messages
/bin/zsh -l -c "exec '<home>/bin/pi' --print --no-session --no-tools … --model '<m>' -- '<prompt>'"
```

`--session-dir` is always passed: pi takes it over `PI_CODING_AGENT_SESSION_DIR` and a project's
`sessionDir`, and Shepherd names the folder with pi's own rule (`PiSessionFolder`), so both agree
by construction. The builder refuses a session folder that resolves outside the home, and nothing
Shepherd sends over RPC names a session file (`RPCCommand`).

Native children run the parent's own engine: `process.execPath` (the engine's node) with the
package's `dist/bundle/cli.js`, never a `pi` from PATH, and inherit the pins from their parent:
`PI_CODING_AGENT_DIR` (the home: settings, sign-ins, models), `PI_PACKAGE_DIR`,
`PI_SKIP_VERSION_CHECK`, `PI_TELEMETRY`, and `NODE_EXTRA_CA_CERTS` (the launcher's keychain
certificates or the user's own, so a private CA works for a helper's requests too); `PI_OFFLINE` is
set to 1. The `_SHEPHERD_STASH_*` variables pass through as well (their prefix isn't `SHEPHERD_`),
so a helper's own shell commands get the user's environment back from `restore-env.sh`. Two sets
are dropped: `PI_SUBAGENT*` (including `PI_SUBAGENTS_TEMP_ROOT`, which only the pi-subagents
package uses), and every `SHEPHERD_*` variable, so a helper is cut off from the host (its agent id,
socket and design are the parent's alone). The one exception is the managed provider's file, above.
What Shepherd sets per agent through its own variables and extensions reaches no helper: a helper
runs with pi's defaults for its model (a service tier Shepherd sets for an agent, for one, isn't
applied to its helpers).
The MCP probe runs on the engine's node too, in a login shell (so the servers it starts find what
an agent's would), and drops the shell's `PI_*`, `JITI_*`, `NODE_*` and `OPENSSL_CONF` first, as
the launcher does: a `NODE_OPTIONS` hook of the user's never loads into Shepherd's node.

## Your pi

"Your pi" is the folder the user's terminal pi uses. Shepherd only ever reads it, as plain files,
and never runs pi's code against it. `YourPiLocator` finds it once per launch of the app: a login
shell, with the app's own `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` removed, prints
what the user's startup files set; with neither it is `~/.pi/agent`. A folder inside any
edition's support folder is refused (logged): Shepherd reads nothing of it, but the guards
still check it, so startup files that point `PI_CODING_AGENT_DIR` at Shepherd's own home stop
every launch rather than share it. Debug builds honour
`SHEPHERD_YOUR_PI`, which the test isolation sets; under the engine override without it there
is none, so a test never reads the real one.

**The startup guards.** Before any pi starts, `PiSetup.check` resolves (`realpath`) the home and
its `sessions/`, and "your pi" and its session folder: if either side is inside the other, or
"your pi" holds the marker, no pi starts in the home and nothing is written to it. The agent waits
with the reason ("Shepherd won't start pi here", `NativeStartProblem.Kind.homeUnsafe`).

**Adoption.** Before any seeding or launch, an agent whose conversation Shepherd's home doesn't
hold yet takes a copy from "your pi" (`PiSessionFile.adopt`): by ID, in the session folder their
pi is set to, then `<your pi>/sessions/--<cwd>--`, then `~/.pi/agent`'s, and the project's own
`sessionDir`, preferring a file with a conversation. pi repairs and appends to any file it loads,
so Shepherd never lets pi open the user's file:

| Shepherd's home has | Your pi has | Shepherd does |
| --- | --- | --- |
| A conversation | Anything | Nothing |
| Nothing, or a header only | A conversation, header version ≤ 3 | Copies it, then resumes it |
| Nothing, or a header only | A conversation from a newer format | Starts fresh (logged) |
| Nothing, or a header only | A header only, or nothing | Starts fresh under the same ID |

The copy reads the source's real path (a symlink is followed and its bytes copied), writes a new
regular file by temp file and rename, with the same name, into the agent's session folder, and
checks it is a single-link regular file; a header Shepherd seeded earlier under another name
goes. A session file in the home that is a link (a symlink, or a hard link the user's pi shares)
is first replaced with a copy of its bytes, and a project folder that resolves outside the home
gets no copy, no seeded header and no fork. From then on the two copies diverge: the user's `pi --resume` shows the conversation as it
stood.

## Imports: what comes from your pi

**The user's decision (2026-09-26), which changes the plan's principle 6 ("never copy a grant"):**
"we need to be able to migrate the users pi logins and stuff into shepherd if they already exist."
Asked how, they chose **copy them once**: at the first launch of a build with Shepherd's own
home, every login in their pi is copied into Shepherd's, subscription (OAuth) sign-ins included;
afterwards the two are independent. The consequence, accepted: providers that rotate refresh
tokens (Anthropic, OpenAI Codex, Kimi, Radius, and xAI when its server rotates) store a new
refresh token on every refresh, so the first refresh on one side can sign the other out, and a
provider may revoke both on reuse. Settings ▸ Pi says so beside each copied subscription, and
Re-import copies that login again.

`YourPiImport` does the copying and `YourPiFiles` the reading. Everything of the user's is read
as plain JSON and plain folders (a BOM and comments allowed, as pi allows them, files over 4 MiB
refused; a link is followed, as pi follows it, and a file is opened without blocking and checked
on its descriptor, so a FIFO or device where a file should be fails at once): never through pi's `AuthStorage`, `SettingsManager` or `ProjectTrustStore`, which
take lock folders even to read, and never by running pi (`pi auth check` refreshes OAuth). Their
pi stays byte-identical: no write, no lock folder. Every write lands in Shepherd's home by temp
file and rename, under pi's own lock for the file (`auth.json.lock`, …), and auth.json is 0600
in the 0700 home. No credential's value reaches a log, a report, the UI or pi's context: they
name a provider and a kind (API key, `$NAME`, "runs a command", subscription), never a value.

**The user's second decision (2026-09-26):** "everything will be ported over, so things like
skills, will only be installed under shepherds application support folder". So their
instructions, skills, prompts, themes and extensions are copied too, and Shepherd's pi reads
only its own home: nothing reads their pi live, and an edit there reaches Shepherd only through
Re-import. `YourPiResources` finds each kind as pi finds it and copies it as plain files
(`YourPiTree`): a link is followed and its target's bytes copied (one that leads nowhere, back
up its own folder, or to a folder above what is copied, `/` or the home folder, is left out),
FIFOs, sockets and devices are never opened, `.git` stays behind, the execute bit is kept and
nothing else of the mode, and a copy is written beside the home and renamed into place, whole or
not at all, within a limit per kind (a skill 64 MB and 5000 files, and as many folders; an
extension, with its `node_modules`, 512 MB and 100000; one file 4 MiB). Finding skills, prompts
and themes never enters a link to the folder searched or above it, and stops after 10000 folders
per folder searched, so a skill linked to `/` can't read the disk or hold the first launch.
Copies wait for one another (the first copy past its deadline and a Re-import, or two rows
pressed at once), each in its own staging folder. An extension's `pi.extensions` entry that
leads out of its package (`../x`, `a/../../x`) is left out, and so are the packages pi hands
every extension itself (`@earendil-works/pi-*`, `typebox`): a peer dependency on pi would drag
pi's whole tree along and never load.

| From your pi | At the first launch | Afterwards |
| --- | --- | --- |
| Logins (auth.json) | Every entry copied as it is: API keys keep their literal, `$ENV` or `!command` value; OAuth entries are copied whole. A provider Shepherd's pi already has keeps Shepherd's | Re-import, per provider, overwrites Shepherd's |
| Custom providers (models.json) | Copied as bytes, unless Shepherd's pi already has some | Re-import replaces them; invalid JSON keeps Shepherd's copy and says why |
| Default model | `defaultProvider`/`defaultModel` copied, unless a sign-in already set one | Re-import |
| Trusted folders (trust.json) | Every decision copied except a `true` for the home folder or a folder above it | Re-import (theirs over Shepherd's) |
| Instructions | The global context file pi would pick (`AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`), `SYSTEM.md` and `APPEND_SYSTEM.md`, copied into the home under their names, where pi and its children read them | Re-import; an earlier copy pi would now pick over theirs is removed, but only when every file copied: one of theirs that can't be read (or none at all) leaves Shepherd's copies as they were |
| Skills | From their `skills/` (folders at any depth, and single `.md` files, which become folders), the `skills` paths in their settings (`!`, `-` and `+` filters applied as near as plain matching gets; globs and URLs left out), the skills of the packages they list, then `~/.agents/skills` (folders only), into the home's `skills/`. The second of one name is passed over, as pi passes it over, and one of Shepherd's own of that name stays | Re-import replaces the copies it made (where they are, on or off in Settings ▸ Skills), adds new ones, removes nothing |
| Prompts and themes | Their `prompts/` (`.md`) or `themes/` (`.json`) folder's top level, the paths in their settings (a folder at any depth), and their packages', into `prompts/` or `themes/`; the second of one file name is passed over | Re-import, the same way |
| Extensions | Their `extensions/` files and folders (with an `index` or a `pi.extensions` manifest), their settings' `extensions` paths, and the packages their settings list (an npm package from `npm/node_modules` with the dependencies npm hoisted beside it, a git one from `git/<host>/<path>`, a local folder), copied into `your-extensions/`, which pi never discovers: all switched off | A switch each (Your extensions); Copy again keeps each switch |

`.shepherd-imports.json` in the home records that the first copy ran, every file it copied (what,
from where, to where), which extensions are on, why one didn't load, and the `extensions` entries
Shepherd wrote, so the first copy never runs again on its own; with no pi of theirs it records
that too. A file there that can't be read counts as a copy that ran, so a damaged one never
brings back a login signed out of since. A state saved before the first copy (a copy past its
deadline) has `copied: false`: the next launch still copies, keeping what it holds. A state of
version 1, from when instructions, skills and prompts were read in place, gets its files copied
once, quietly (no sheet, no login copied again), and the `skills` and `prompts` entries
that pointed Shepherd's settings at the user's pi are removed. A home the startup guards refuse
copies nothing. What couldn't be copied (a file of
theirs unreadable, too large or not JSON, or one of Shepherd's own that isn't a JSON object, which
is left as it is) is reported, file by file and never quoted, in the log and the first launch's sheet.
What was passed over on purpose (a second skill of one name, a package their pi never installed,
a link that leads nowhere) goes to the log, one sentence each. A package's source loses any user
and password in its URL wherever it is shown or logged.

**Instructions.** pi reads a global context file only from its own agent folder, which is
Shepherd's: the copy there is read by every agent and every child that keeps project context
(never one run with `--no-context-files`), as pi reads its own. Shepherd's own root instructions
(Settings ▸ Instructions) follow it.

**Your extensions, opt-in and fail-closed** (the plan's phase 6). Switching one on runs the
user's code with full access, which Settings ▸ Pi says on the row. Before every launch
`PiSetup.prepare` writes the switched-on ones' entry files, by absolute path inside the home, into
`settings.json`'s `extensions` (never `packages`, never npm), replacing only the entries it wrote
before; children get them through `childUserExtensions`. One whose files are gone is left out with
that reason. When an agent's pi stops before it serves with pi's `Failed to load extension
"<path>": …` and the path is one of these, the view model records pi's reason and the files' time
(`YourPiImport.extensionFailed`), which leaves it out of every launch until its files change or
the user tries again, and starts the agent again with no click; the row keeps its switch on and
shows the reason. Any other extension's failure leaves the agent waiting with Retry.

**Trust and the home folder.** An agent whose folder is the user's home runs with
`--no-approve`: its project folder, `~/.pi`, is the user's own pi, so no trust decision loads
code from it.

## The first launch

The view model (`welcomesYourPi`, on in the app) holds `AgentStartQueue` and automations, then
runs the copy off the main thread, bounded by 30 s (past it, agents start anyway, so the gate never
blocks for good). The copy reports each step as it goes (`YourPiImportProgress`: logins and keys,
custom providers, the default model, trust, files, extensions), and the sheet, Bringing over your
pi (`PiImportSheet`, docs/design/dialogs-and-palette.md › Dialogs and sheets), shows them once it's known there's a pi of
the user's to copy. Every held agent says "waiting" in the sidebar and ends its thread in Waiting
to continue. When the copy is over the sheet ends one of five ways, and says who keeps waiting
(`YourPiModel.Hold`):

| Ending | When | Who waits until it closes |
| --- | --- | --- |
| Done | Everything came over and nothing is missing | Nobody: restored agents start at once, the one on screen first |
| Something missing | A provider a restored agent's model (or the default model) uses has nothing in Shepherd's pi to sign in with: no login, no key in the login shell, no custom provider of that name | The agents using those providers (`AgentStartQueue.hold(_:)`); the rest start |
| Failed | Their auth.json couldn't be read or isn't JSON (the rest still came over) | Everyone; Retry copies the logins again and turns it into Done or Something missing |
| New user | No pi of theirs, and nothing can start an agent | Everyone |
| (none) | A later launch, or a new user already signed in with nothing missing | Nobody |

Something missing lists the providers with Sign in each (the sign-in sheet opens over it) and
enables Done once they're all signed in; Skip for now leaves those agents to start and wait on
"not signed in". A new user picks a subscription or an API key; a sign-in that lands closes both
sheets. Providers that sign in with cloud credentials pi doesn't store (Amazon Bedrock, Google
Vertex AI) are never asked for. Nothing on the sheet shows a credential's value: a failed
auth.json names its path and the parser's position ("Unexpected character around line 31,
column 5."), never a character of it.

## Signing in

Settings ▸ Pi ▸ Sign-in, `/login`, a Not signed in agent's card and the first launch's sheet open
one sheet (`PiSignInSheet`, on `PiAuthStore`'s `PiSignInSession`). It never opens pi's TUI. It runs
pi's own login through a bridge: `shepherd-sign-in.mjs`, installed in the support folder, run on
the engine's node in a login shell (so a key's variable and the user's proxy settings are there)
with the shell's pi, jiti and Node settings dropped and Shepherd's pi home pinned
(`PiLaunch.signInBridge`). It imports the engine's `dist/bundle/index.js` and calls
`ModelRuntime.create({authPath, modelsPath})` on the home's files and `login(provider, "oauth" |
"api_key", interaction)`, and speaks JSON lines (`PiSignInCommand`, `PiSignInReply`):

- pi's events (`auth_url`, `device_code`, `info`, `progress`) and prompts (`manual_code`,
  `secret`, `text`, `select`) go to the sheet; a prompt pi no longer needs (the browser's callback
  won) is closed. The sheet answers the ones it shows (a pasted code, a key); the bridge answers
  the rest itself: a login method's `select` with the browser (or the device code), GitHub
  Copilot's Enterprise domain with github.com.
- Before a browser sign-in, the bridge checks the provider's fixed callback port (Anthropic
  53692, OpenAI Codex 1455, Radius 1456) and says it's taken instead of opening the browser;
  Paste a code instead then logs in without the check.
- A key is checked before Save with the smallest request pi can make (`completeSimple`, 16 tokens,
  on the provider's first non-reasoning model, with the key as an override); a 401 or 403 reads
  as rejected, anything else as not reached (Save turns on anyway). A key is stored as pi reads it:
  `$NAME` for a variable, a literal with `$` doubled and a leading `!` escaped
  (`PiKeyInput.stored`).
- `done` carries the credential's type, never the credential: pi writes it into the home's
  `auth.json` under its own lock. A reason sent back loses its stack, any response body, anything
  typed, and anything shaped like a token.
- `logout` removes Shepherd's credential for one provider (pi's own `logout`); the user's pi keeps
  its own.

When a sign-in lands, every agent waiting on "not signed in" for that provider (or for none pi
named) starts again at once, and the sheet counts them; a Re-import of logins does the same. A
turn that fails with pi's "OAuth refresh failed for <provider>" marks that subscription Expired in
Sign-in. The model catalog is kept until `auth.json`, `models.json` or `settings.json` in the home
changes.

Sign-in's rows (`PiSignInPage`) read both sides as plain files: Shepherd's `auth.json` and
`models.json`, and the user's pi for Re-import. A key shows only masked (`PiKeyMask`: its prefix
and last four), a variable by name, a command as its text. How a copy stands against the user's pi
("same as your pi", "newer in your pi", "changed here") compares digests of each item taken when
it was copied (`YourPiImportState.digests`), never values.

## Updates

The engine updates with Shepherd: there is no `pi update` and no version check. The launcher
refuses pi's own package commands, and the pins turn off pi's update check and install telemetry.

## Testing

- Imports: the parsers' tables (`YourPiFilesTests`), each kind of file found as pi finds it and
  copied whole (`YourPiResourcesTests`: a skill folder with links, a skill or skills folder
  linked to `/` or above, a huge skill, too many folders, a FIFO, a package with `node_modules`
  and hoisted dependencies, a package entry leading out of it, pi as a peer dependency, a prompt
  of one name twice), the copy, an override beside `AGENTS.md`, Re-imports at once,
  the marker, Re-import per item, an earlier copy that read files in place, and the extensions'
  switches and failures, against a fixture "your pi" of fake credentials that stays
  byte-identical (`YourPiImportTests`), hostile files (`YourPiImportEdgeTests`: links, a FIFO,
  folder or device for auth.json, a huge, invalid or deeply nested one, unknown OAuth fields, a
  `!command` key, a damaged or early state file, a "your pi" overlapping the home, a package
  token), the first launch through the view model and the stub engine
  (`YourPiFirstLaunchTests`: nothing starts while the copy runs, then restored agents start
  signed in with no click, since the stub refuses to start without a login in the home; a copy
  past its deadline; the default model's missing provider; a later launch; skipping sign-in with
  nothing to copy leaving agents on "not signed in"; an extension of yours that throws at load
  switched off, and the agent started again without it), and the copied instructions in a real
  child (`native-children.test.mjs`).
- Sign-in: the bridge on node against a fake pi SDK (`PiSignInBridgeTests`: the browser's
  callback, a pasted code and one refused, a device code, a taken port, a key checked, escaped and
  never echoed, cancel, sign-out removing only Shepherd's credential, a bridge that can't run), its
  JSON lines (`PiSignInProtocolTests`), the sheet's states (`PiSignInSessionTests`), the rows
  (`PiAuthRowsTests`, `PiSignInCatalogTests`: masking, freshness), `/login` (`SlashLoginTests`),
  the first launch's sheet (`PiImportSheetTests`), and through the app (`PiSignInFlowTests`: an
  agent not signed in starts again when a sign-in lands, `/login` routing, sign-out).
- Unit: the launch lines (`PiLaunchTests`), the launcher's and `restore-env.sh`'s content, the
  guards, "your pi" resolution and `settings.json` writes (`PiHomeTests`), adoption's table
  (`PiSessionAdoptionTests`), and no RPC command naming a session file (`RPCWireTests`).
- Integration: the launcher run for real (`PiLauncherTests`: the pins and the stash, restoring
  in bash and zsh, refusals, a missing engine, a symlinked session folder or `bin/`, the marker,
  startup files that name Shepherd's home as theirs, the MCP probe's environment), and the
  app launching through the stub engine despite the decoy startup files, adopting a restored
  agent's conversation while "your pi" stays byte-identical with no lock taken
  (`PiHomeLaunchTests`).
- Engine smoke (opt-in, `SHEPHERD_ENGINE_SMOKE`): through the real launcher, an RPC `bash`
  command finds `pi` at the launcher and gets back a `NODE_OPTIONS` pi never saw; an agent in
  the user's home folder, whose pi names packages and extensions, loads none of their code, runs
  no npm, and leaves their pi byte-identical; skills load only from the home (a skill in
  `~/.agents/skills` never does, not even for a trusted project inside the home folder, with a
  control that finds it unfiltered, while the copies do);
  and an extension of yours that throws at load is switched off with pi's reason while the one
  that works loads from its copy.
