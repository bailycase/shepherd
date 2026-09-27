# Shepherd's own pi

Shepherd runs its own pi, in its own home, so that nothing it does changes the user's pi, and
nothing in the user's pi can break Shepherd. The engine (Node plus pi's bundle) ships inside the
app ([pi-engine.md](pi-engine.md)); this page is about where it runs and how it's started.

This is the "Bundled pi, isolated home" plan's phases 3 to 5: the switch, the imports from the
user's pi, and the first launch's welcome step. The user's extensions (phase 6), the native
sign-in sheet (7) and Open in terminal (8) come later.

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
| `settings.json` | Shepherd's keys only: `shellCommandPrefix` (sourcing `restore-env.sh`), and `packages` removed |

pi writes `settings.json` too (the TUI's `/settings`, the first `/login`), so Shepherd changes it
read-modify-write under pi's own lock (proper-lockfile's `settings.json.lock` folder, taken over
after 10 s as pi's is), by temp file and rename, and only when its keys differ. A `packages` key is
removed at every launch, with a note in the log: a user-scope package missing from `<home>/npm`
makes pi load the user's global npm install, even offline. A `bin/` that links out of the home is
refused rather than written through, and the agent waits on the reason.

## The launcher

`<home>/bin/pi` runs under `zsh -f`, so no startup file runs between it and pi. In order, it:

1. sets aside every `PI_*`, `JITI_*`, `NODE_*` and `OPENSSL_CONF` it was started with, as
   `_SHEPHERD_STASH_<name>` (their names in `_SHEPHERD_STASH_NAMES`), and unsets them, putting
   `NODE_EXTRA_CA_CERTS` back for corporate CAs. The prefix isn't `SHEPHERD_`, which the children
   extension drops from a child's environment;
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
`shellCommandPrefix` sources `restore-env.sh` before every command: it unsets the pins and
exports each variable the launcher set aside, as it was.

Every launch is built by `PiLaunch` (pinned in `PiLaunchTests`):

```sh
# an agent
/bin/zsh -l -c "cd -- '<cwd>' && exec '<home>/bin/pi' --mode rpc \
  --session-dir '<home>/sessions/--<cwd>--' --session-id '<id>' [--model … --thinking …] -e …"
# the model catalog, from inside the home so no project's .pi applies
/bin/zsh -l -c "cd -- '<home>' && exec '<home>/bin/pi' --list-models"
# PR descriptions and commit messages
/bin/zsh -l -c "exec '<home>/bin/pi' --print --no-session --no-tools … --model '<m>' -- '<prompt>'"
```

`--session-dir` is always passed: pi takes it over `PI_CODING_AGENT_SESSION_DIR` and a project's
`sessionDir`, and Shepherd names the folder with pi's own rule (`PiSessionFolder`), so both agree
by construction. The builder refuses a session folder that resolves outside the home, and nothing
Shepherd sends over RPC names a session file (`RPCCommand`).

Native children run the parent's own engine: `process.execPath` (the engine's node) with the
package's `dist/bundle/cli.js`, never a `pi` from PATH, and inherit the pins from their parent.
The MCP probe and the Skills reader run on the engine's node too. The probe runs in a login shell
(so the servers it starts find what an agent's would) and drops the shell's `PI_*`, `JITI_*`,
`NODE_*` and `OPENSSL_CONF` first, as the launcher does: a `NODE_OPTIONS` hook of the user's never
loads into Shepherd's node. The Skills reader readies the home first (`PiSetup.prepare`), so it
never resolves a `packages` key.

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

**Settings ▸ Skills' From your pi setup** reads the user's `skills/` and the `skills` paths in
their `settings.json` as files; the skills Shepherd's own pi loads are asked of the engine.

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

| From your pi | At the first launch | Afterwards |
| --- | --- | --- |
| Logins (auth.json) | Every entry copied as it is: API keys keep their literal, `$ENV` or `!command` value; OAuth entries are copied whole. A provider Shepherd's pi already has keeps Shepherd's | Re-import, per provider, overwrites Shepherd's |
| Custom providers (models.json) | Copied as bytes, unless Shepherd's pi already has some | Re-import replaces them; invalid JSON keeps Shepherd's copy and says why |
| Default model | `defaultProvider`/`defaultModel` copied, unless a sign-in already set one | Re-import |
| Trusted folders (trust.json) | Every decision copied except a `true` for the home folder or a folder above it | Re-import (theirs over Shepherd's) |
| Global instructions | Read live, before every run (below) | A switch |
| Skills and prompts | Read in place: their `skills/` and `prompts/` folders and the paths in their settings, as absolute paths (`+`, `-` and `!` filters kept) in Shepherd's `settings.json` | A switch each; the entries Shepherd added are tracked, so one the user added stays |
| Extensions | Listed, off | Phase 6 |

`.shepherd-imports.json` in the home records that the first copy ran (and the switches, and the
settings entries Shepherd added), so it never runs again on its own; with no pi of theirs it
records that too. A file there that can't be read counts as a copy that ran, so a damaged one
never brings back a login signed out of since. A switch saved before the first copy (a copy past
its deadline) writes the file with `copied: false`: the next launch still copies, keeping the
switch. A home the startup guards refuse copies nothing. What couldn't be copied (a file of
theirs unreadable, too large or not JSON, or one of Shepherd's own that isn't a JSON object, which
is left as it is) is reported, file by file and never quoted, in the log and the welcome step.
A package source listed under Your extensions loses any user and password in its URL.

**Instructions.** pi reads a global context file only from its own agent folder, which is now
Shepherd's. Each agent gets `SHEPHERD_YOUR_PI_INSTRUCTIONS`, the user's pi folder, while the
switch is on; before every run the status extension reads the file pi would pick there
(`AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`; 256 KiB at most) and
adds it after pi's own root file, with its real path. The children bridge does the same for a
child that keeps project context (never one run with `--no-context-files`), and Shepherd's own
root instructions (Settings ▸ Instructions) follow the user's.

**Trust and the home folder.** An agent whose folder is the user's home runs with
`--no-approve`: its project folder, `~/.pi`, is the user's own pi, so no trust decision loads
code from it.

## The first launch

The view model (`welcomesYourPi`, on in the app) holds `AgentStartQueue` and automations, then
runs the copy off the main thread, bounded by 30 s (past it, agents start anyway, so the gate never
blocks for good). What happens next depends on whether anything can start an agent (a login in
Shepherd's pi, a provider key the user's login shell sets, or a custom provider):

- **Something can:** restored agents start at once, the one on screen first, signed in with what
  came over, while the welcome step shows. An existing user whose logins came over never clicks
  for their agents.
- **Nothing can:** they wait until the welcome step closes, whichever way, so the user can sign
  in first. A skipped sign-in is safe: an agent that can't start waits on "not signed in", with
  Retry.

The welcome step shows only when this launch did the copy: one sentence ("Shepherd now runs its
own copy of pi. The pi in your terminal is untouched."), what came over, the provider key
variables the user's login shell sets (names only, found by the same login shell that finds "your
pi"), and a sign-in ask only for what's missing: the provider of the default model (Settings ▸
Agents' own, else pi's) when nothing covers it, or every provider when nothing can start an agent.
Providers that sign in with cloud credentials pi doesn't store (Amazon Bedrock, Google Vertex AI)
are never asked for. A new user with no pi sees only sign-in. A later launch copies nothing and
holds nothing.

## Signing in

pi signs in only in its TUI (`/login`). Settings ▸ Pi ▸ Sign in (and Sign in… on a "not signed
in" banner) opens a terminal pane beside the selected agent running Shepherd's pi with no session
(`(cd -- '<home>' && exec '<home>/bin/pi' --no-session)`, in the home so an agent's folder of `~`
never makes `~/.pi` the TUI's project), where the user types `/login`. The sign-in lands in the home's
`auth.json`; the terminal's pi keeps its own. A native sign-in sheet is a later phase. The model
catalog is kept until `auth.json`, `models.json` or `settings.json` in the home changes.

## Updates

The engine updates with Shepherd: there is no `pi update` and no version check. The launcher
refuses pi's own package commands, and the pins turn off pi's update check and install telemetry.

## Testing

- Imports: the parsers' tables (`YourPiFilesTests`), the copy, the marker, Re-import and the
  switches against a fixture "your pi" of fake credentials that stays byte-identical
  (`YourPiImportTests`), hostile files (`YourPiImportEdgeTests`: links, a FIFO, folder or device
  for auth.json, a huge, invalid or deeply nested one, unknown OAuth fields, a `!command` key, a
  damaged or early state file, a "your pi" overlapping the home, a package token), the first launch through the view model and the stub engine
  (`YourPiFirstLaunchTests`: nothing starts while the copy runs, then restored agents start
  signed in with no click, since the stub refuses to start without a login in the home; a copy
  past its deadline; the default model's missing provider; a later launch; skipping sign-in with
  nothing to copy leaving agents on "not signed in"), and the
  instructions in a parent and a real child (`your-pi-instructions.test.mjs`,
  `native-children.test.mjs`).
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
  no npm, and leaves their pi byte-identical.
