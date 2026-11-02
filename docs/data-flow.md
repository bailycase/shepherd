# Data flow

> Read when you change how an agent launches, how status is reported, how automations run, or what the server owns.

- **The in-process `SessionServer` is the single source of truth** for spaces, per-agent layout
  tabs, agents, and automations (persisted to `state.json`). It owns every PTY and RPC process.
- **The local GUI** calls the server directly, with no socket, and adopts `onStateChanged`
  broadcasts. It owns only view state: selection, focus, collapsed spaces, the side pane,
  sheets, appearance, and keybindings.
- **Remote clients** reach the same server over TCP.
- **Tabs** survive only as per-agent layout containers, plus `inspectorFor` utility terminals the
  host opens for a remote client (a remote `gh auth login`). There is no tab UI: the sidebar is
  navigation.

**Agent launch** (`StatusExtension.command`, from `TerminalSessionStore`, built by
`PiLaunch.agent`):
`/bin/zsh -l -c "cd -- <cwd> && exec '<support>/pi/bin/pi' --mode rpc --session-dir '<support>/pi/sessions/--<cwd>--' --session-id <id> [--model … --thinking …] -e <extensions>"`.

- `<support>/pi/bin/pi` is Shepherd's launcher, in Shepherd's own pi home
  ([docs/pi-home.md](pi-home.md)). It runs under `zsh -f`, sets aside the environment's
  `PI_*`, `JITI_*`, `NODE_*` and `OPENSSL_CONF`, pins Shepherd's (home, package, offline, no
  version check or telemetry), refuses `install`/`remove`/`uninstall`/`update`/`config`, and
  execs the engine the app ships (`SHEPHERD_PI_ENGINE` in a Debug build). Every other launch of
  pi (the catalog, drafts, `pi mcp list/login/logout` for Settings ▸ MCP servers) goes through it
  too, and the node beside it (the sign-in bridge) is the engine's; `PiLaunch` builds them all and
  nothing else names either. Nothing ever runs the user's own `pi` or `npm`.
- Before each launch, `PiSetup.prepare` checks the startup guards (the home and "your pi" never
  overlap, by `realpath`, and "your pi" holds no Shepherd marker) and writes the launcher,
  `restore-env.sh` and Shepherd's keys in the home's `settings.json` (`shellCommandPrefix`, and
  `packages` removed), under pi's own lock. A refused home starts no pi: the agent waits with
  the reason (`homeUnsafe`).
- The `cd` runs after the login shell's startup files, so a `cd` in them can't move pi, and
  `--session-dir` (always passed) wins over the environment and any project's `sessionDir`.
- The session ID is the agent's current pi session. Before any seeding, `PiSessionFile.adopt`
  copies the agent's conversation in from "your pi" if Shepherd's home has none (plain reads,
  bytes not links); then `PiSessionFile` seeds a session header if pi has none yet.
- `--model`/`--thinking` go only to a fresh session.
- Extensions follow Settings ▸ Pi ▸ Bundled extensions. A thread's or an automation's launch (never a design's
  agent's) carries `SHEPHERD_DEFER_TOOLS=1` and `-e builtin:tool-search` while Settings ▸ Agents ▸ Context ▸ Defer
  rarely used tools is on, so the rarely used tools register `deferred` and load by a search
  ([context-budget.md](context-budget.md) › Deferred tools).
- The opening prompt is the first native `send`, not a positional argument. The host holds it
  (`SessionServer.sendOpeningPrompt`) and sends it the moment pi serves, so every client's first
  snapshot shows it; the client that created the agent draws the same pending row meanwhile
  (`OpeningPrompt`, named after the agent). The local sidebar places that new thread in Working
  before its first broadcast, while leaving its reported status unchanged. The temporary marker
  clears on a turn status, a failed start, deletion, or a native-thread revision showing no
  running turn or pending message. Revision subscriptions cover these opening threads even
  when their views are not mounted; no timer or extra polling loop runs.
- A new agent's pi spawns with its creation. At launch settled restored agents and their terminals
  stay dormant without terminal models or Ghostty surfaces, even when their hidden layouts mount.
  Selection starts that agent and its terminals;
  native/remote thread demand starts only its pi. The selected agent starts first; unfinished ordinary
  work starts a few at a time through `AgentStartQueue`. Explicit design/worktree starts still launch
  without selection. Ordinary agents recover unfinished authorized work and
  queued input from atomic `agent-recovery` checkpoints beside `state.json`, after pi has served
  the matching session and history. Active turns use the engine's `get_restart_recovery` /
  `resume_session` continuation without appending user or instruction messages. The engine refuses
  unresolved tool calls, failed tool results not followed by a completed model decision, and
  unknown prior deliveries instead of replaying actions; inputs whose delivery cannot be
  established stay paused, unchanged. Fresh explicit user input supersedes old recovery intent,
  but never authorizes replaying its operation. Queued inputs retain their images and order. Stop persists before
  its asynchronous acknowledgement, waiting/held queues remain paused, and idle or completed
  turns never get a continuation. Recovery attempts are committed before prompting and stop
  after three consecutive interruptions; a completed turn or fresh user input resets the bound.
  Projects, executions, goals, automation runs and design agents do not use ordinary recovery.
  Test harnesses that seed agents only to draw them
  opt out (`restoresAgentsAtLaunch: false`); their pi starts when their thread's session is asked for.
- At the first launch of a build with Shepherd's own pi, the queue (and automations) wait for
  the one-time copy from the user's pi (`welcomesYourPi`, on in the app only;
  `YourPiFirstLaunchTests` turns it on in a harness), bounded by a deadline; then the agents a
  missing sign-in blocks keep waiting (`AgentStartQueue.hold(_:)`) until its sheet closes, or all
  of them when it asks a new user to sign in or couldn't read the user's sign-ins.
- An agent whose pi can't start because nothing signs in for its model waits in Needs you, and
  starts again by itself when a sign-in lands for its provider (`PiAuthStore.onSignedIn`).
- An agent whose folder is the user's home runs with `--no-approve`: its project folder, `~/.pi`,
  is the user's own pi.
- Starting is quiet: a thread draws what it knows at once (a new agent's empty state, a
  resuming agent's history read from pi's session file), accepts a send that waits for pi, and
  says "Starting…" only when pi is slow (docs/design/thread.md › Thread, Composer).

`RPCThreadState` projects pi's events into the `NativeThreadSnapshot` that
`SessionServer.nativeThread` serves locally and, over TCP, remotely
([docs/native-thread.md](native-thread.md)). Messages sent while pi works wait in a queue
the host holds (never pi's own, whose modes write the user's pi settings) and go when pi
settles, or go at once after pi is stopped (Steer now); a user message joins the thread only when pi starts it
(docs/native-thread.md › The queue).

**Status reporting.** The status extension reports `setAgentStatus` fire-and-forget (the server
takes it only from that agent's own pi; a report from any other process is dropped):

| pi event | Status |
| --- | --- |
| `session_start` | `idle` |
| `agent_start` | `working` |
| `agent_settled` | `done` |
| ask/question-style `tool_execution_*` | `blocked` |
| `session_shutdown` | `idle` |

It also reports `setAgentSession` with the live pi session ID, so `/new` or `/resume` survives a
relaunch.

A status is live state (`StateStore.updateLive`): broadcast and readable at once, but neither
validated nor written to `state.json` on its own, since every turn reports twice and `start()`
resets statuses anyway. The next structural mutation writes it along with its own change. Keep
anything that must survive a relaunch out of that path.

**Terminals** run the shell from Settings ▸ Terminal as a login shell, without wrapping
`pi` or injecting a theme. The user's rc files and pi settings are never edited, and agent-only
variables are blanked, as are pi's `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR`,
`PI_PACKAGE_DIR` and `PI_OFFLINE`: `pi` in a terminal is the user's own.

**Automations** are saved prompts (`ShepherdState.automations`).

- **A run** spawns an ordinary agent, in a reserved hidden space when the automation's cwd
  matches no user space. It is launched with `SHEPHERD_AUTOMATION=1`, which keeps the terminal and
  notify tools but withholds the `automation_*` tools.
- **One-shot watchers:** `automation_create(deleteAfterRun: true)` (default false) saves the flag
  and deletes the unscoped automation after the watcher's actual terminal turn settles, including
  a settled failure. This is the watcher finishing, not the creator receiving or answering its
  report. Startup idle, blocked questions, live retries, start failure and explicit Stop do not
  trigger cleanup. Queued turns must settle first. Cleanup keeps the agent and its transcript,
  so notifications and reports are not cut short; like ordinary deletion, it prunes the
  automation's run log. Project-owned records are never removed through this legacy path.
- **Management:** agent requests arrive as `AutomationRequest` through
  `SessionServer.onAutomationRequest` and are served by `ShepherdViewModel+Automations.swift`.
  The Automations sidebar section is their only surface on the host. Remote clients change them
  through the same handler (`RemoteRequest.automation`, below), after the server checks what it
  can (the automation exists; a new or edited one has a name, a prompt and a directory on the
  host). The extension-socket automation messages name no agent, so they are the one thing on
  that socket any process that reaches it may send (`ExtensionMessage.speaksFor` is `nil`).
- **Run now** (`startAutomation`) follows `AutomationRun.isLive`: a run whose agent works, asks,
  or has not settled a turn yet refuses ("already running"), and so does a second start while
  one is starting. A settled run is replaced once the new run exists: the automation moves to
  the new run (the log closes the old one as finished), the host's selection follows if the old
  run was on screen, and only then is the old run's agent deleted, so nothing else is drawn in
  between. Clients offer Run now or Stop by the same rule (`AutomationAbilities`), so a
  finished run never offers only Stop.
- **Runs are kept** (`AutomationRunLog`, `automation-runs.json`, the newest 30 per automation):
  a run opens when an automation gains an agent, follows that agent's status (running, needs
  you, finished), and closes when the automation loses that agent, to deletion or to its next
  run (finished if its turn had finished, else stopped). At startup every run still open closes
  as interrupted. The server records them from every committed state, so no caller records a
  run by hand; removing an automation forgets its runs. Remote clients read them with
  `RemoteAutomationRequest.runs`.
- **At startup:** the previous run's agents and their layouts are dropped
  (`SessionServer.automationRunAgentIDs`: every agent in the automations' hidden space, never
  the designs space's, plus any agent an automation still points at), every automation's `agentID` is cleared, and enabled automations
  start fresh runs once the workspace is adopted, except `deleteAfterRun` automations, which
  never auto-start after relaunch even when enabled. Never keep a run agent across launches.
- **Changing them** touches `ShepherdCore`, the extension-message enums, `SessionServer`, the
  panes extension (canonical and embedded), and their tests.

### Automation triggers

An automation's `trigger` decides when a run starts; its prompt decides what the run does.
`.manual` is everything above. `.schedule` (an RFC 5545 RRULE in local time, parsed in
`ShepherdCore/AutomationTrigger.swift` and computed by Foundation's `Calendar.RecurrenceRule`)
and `.github` (1 to 5 triggers: repository, event kinds, labels, authors, title, number) are
fired by `AutomationTriggers` (`ShepherdSessions/AutomationTriggers.swift`), an actor the server
owns and the app starts after adoption (`ShepherdViewModel+AutomationTriggers.swift` is its host).
No model is involved until a run starts.

- **GitHub** is read through the user's own `gh` (login-shell PATH, prompts off), one GraphQL
  call per repository at most once a minute: the 20 issues and 20 pull requests updated most
  recently with their latest labels, comments, reviews and merge (`GitHubActivity`). A pull
  request's new head commit is a commits event. Shepherd stores no GitHub token.
- **Who can fire:** the automation's `authorGate` is checked on GitHub's `author_association`
  before anything reaches a model: owners, members and collaborators by default. A label someone
  other than the author added passes (only triagers label); a label the author's issue template
  applied does not. Comments and reviews are gated on their own author.
- **What fires once:** every event has a key (repository, number, kind, the action's id) and fires
  at most once per automation; keys are kept 30 days. Enabling, editing the trigger, resuming
  and first sight take a new baseline: nothing before it fires. After downtime, catch-up reaches
  back 24 hours; a missed schedule runs once. Activity on an item while this automation's own
  run for it works (its comments, pushes) never fires another run for it.
- **Bounds:** `limits.maxConcurrent` (default 2, 1 to 10) and `limits.maxPerDay` (default 20,
  1 to 200) per automation; more events wait as pending (at most 100, expiring after 7 days)
  and the first refusal each day posts one notification. Run now on a pending event passes
  both caps. A lasting error (gh missing or signed out, repository not found, no origin, the
  destination thread deleted) pauses the automation with its reason and one notification;
  a passing one backs off from a minute to 30. Pause all triggers stops every check.
  State lives in `automation-triggers.json`; triggers resume after relaunch (the user's call:
  they only start new runs, under these bounds).
- **Runs:** `.newThread` (default) starts an ordinary thread per event in the space holding the
  automation's folder (else the hidden Automations space), on a new worktree off a fresh fetch
  of the default branch unless `workspace` is `.local`, named after the event, launched with
  `SHEPHERD_AUTOMATION=1` and marked with `Agent.automationOrigin`. Such threads outlive a
  relaunch, are unattended for message policy and recovery, and their runs keep their link.
  `.thread(agentID)` sends every waiting firing to that thread as one message when it is idle.
  The prompt is the automation's, then the event fenced as untrusted data. Model, thinking and
  speed pins fall back to the defaults at run time; a pinned model that went away uses the
  default. The run log adds each run's trigger, PR link (read with `gh pr view` once its turn
  settles), unread dot (cleared when the thread is opened) and why a run failed to start.
- **Project-owned** automations fire into their Project's own `assign`
  ([project-automations](project-automations.md)) and wait while their Project is paused.
