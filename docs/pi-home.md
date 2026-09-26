# Shepherd's own pi

Shepherd runs its own pi, in its own home, so that nothing it does changes the user's pi, and
nothing in the user's pi can break Shepherd. The engine (Node plus pi's bundle) ships inside the
app ([pi-engine.md](pi-engine.md)); this page is about where it runs and how it's started.

This is the "Bundled pi, isolated home" plan's phase 3 (the switch). Imports from the user's pi
(API keys, custom providers, instructions, skills, trust) and onboarding come in later phases,
so on this branch every agent starts signed out, and waits on "not signed in" until the user
signs in from Settings ▸ Pi.

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

## Signing in

pi signs in only in its TUI (`/login`). Settings ▸ Pi ▸ Sign in (and Sign in… on a "not signed
in" banner) opens a terminal pane beside the selected agent running Shepherd's pi with no session
(`'<home>/bin/pi' --no-session`), where the user types `/login`. The sign-in lands in the home's
`auth.json`; the terminal's pi keeps its own. A native sign-in sheet is a later phase. The model
catalog is kept until `auth.json`, `models.json` or `settings.json` in the home changes.

## Updates

The engine updates with Shepherd: there is no `pi update` and no version check. The launcher
refuses pi's own package commands, and the pins turn off pi's update check and install telemetry.

## Testing

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
