# Native subagents

Shepherd bundles a subagent runtime as pi extensions. A parent agent can start child
`pi --mode rpc` processes, steer them, wait for them, and script them into workflows. Shepherd
itself does not run subagents. The parent's extension owns every child process, and the app
installs the extension modules and displays what they report. There is no daemon, scheduler,
watchdog, automatic goal loop, nested delegation, or automatic worktree management. No mission
or workflow grants permission to commit, merge, deploy, or otherwise mutate a repository.

Requires pi 0.85.1 or newer. No npm dependencies are installed.

## Two switches

Settings ▸ Pi ▸ Bundled extensions has two independent switches. Both are on by default, and
both apply when an agent next launches.

- **Native subagents** loads `shepherd-children.ts` together with its modules:
  `shepherd-children-config.ts`, `shepherd-children-ui.ts`, `shepherd-workflow.ts`,
  `shepherd-missions.ts`, and the `shepherd-inspect.mjs` view helpers. It sets
  `SHEPHERD_NATIVE_CHILDREN=1` and the `SHEPHERD_CHILD_*` defaults below. Turning it off stops
  Shepherd loading the runtime; it does not install anything else. If you have installed the
  pi-subagents package yourself, it keeps working as before.
- **Subagent display** loads `shepherd-subagents.ts`, the only publisher of `setAgentChildren`.
  It merges native children with pi-subagents reports into the rows behind the sidebar, the
  thread's cards, the ledger, and the inspector. With display off, children still run but none
  of that UI appears, and card commands fail because the server only accepts runs that were
  published.

**Native subagent defaults** appear only while Native subagents is on. They apply on the next
parent launch.

| Setting | Values | Default |
| --- | --- | --- |
| Concurrency | 1–16 (stepper) | 4 |
| Model | Inherit parent, or a model ID | Inherit parent |
| Thinking | Inherit parent, Off, Minimal, Low, Medium, High, Xhigh, Max | Inherit parent |
| Context | Fresh, Fork | Fresh |
| Agent discovery | User + project, User, Project, Bundled only | User + project |

Concurrency is shared across direct calls and workflows. A parent retains up to 64 child records
and 32 workflows, and runs at most four workflows at once.

## Profiles and discovery

For model, thinking, and context, the most specific source wins: the explicit call, then the
agent file, then Shepherd's settings, then the parent's model and thinking.

- A thinking suffix on the model (`provider/model:thinking`) is used before a separate thinking
  default. An explicit `thinking` still wins over the suffix.
- `model: inherit` selects the parent's current model. Other forms go through pi's own model
  resolver, including unqualified IDs. Provider IDs stay opaque to Shepherd.
- Each child checks the exact resolved model against its own catalog before accepting the task.

At every child launch and resume, pi's resource resolver supplies the user's enabled
extensions. It respects package filters and skips missing packages without installing anything.
Children load those paths explicitly under `--no-extensions`, so extension-registered providers
keep pi's own configuration and authentication. This also inherits user extension hooks, so it
is not a provider-only sandbox. Project and parent CLI-only extensions still need explicit
profile `extensions` entries.

`shepherd_child_agents` lists effective profiles, where each came from, and any diagnostics.
Agent Markdown files stay the source of truth, and Shepherd never edits them. Pi's agent
directory comes from `getAgentDir()`, which honors `PI_CODING_AGENT_DIR`.

Discovery order, from lowest to highest precedence:

1. Shepherd's bundled scout, reviewer, planner, and worker profiles.
2. Agent directories declared by configured, already installed pi packages
   (`pi-subagents.agents` or `pi.subagents.agents`). Nothing is installed and no registry is
   scanned.
3. `PI_SUBAGENT_EXTRA_AGENT_DIRS`, then `<pi agent dir>/agents`, then `~/.agents`.
4. The nearest project root's `.agents`, then `.pi/agents` (`.pi/agents` wins within the
   project). Pi's `CONFIG_DIR_NAME` replaces `.pi` on rebranded distributions.

The Agent discovery setting selects user, project, both, or bundled only; package scope follows
the same choice.

- **What is read:** Markdown files, recursively. `.chain.md`, skill directories, `.git`,
  `node_modules`, and nested project roots are skipped.
- **Limits:** directory symlinks are not followed. A project file symlink that escapes its agent
  directory is rejected. Files are capped at 128 KiB and traversal at 16 levels.
- **Trust:** project profiles require pi's saved trust for the current directory. A child
  working in a different directory needs a saved trust decision for that directory or an
  ancestor; the parent's temporary trust does not carry over. A skipped project root produces a
  diagnostic. Children still run with `--no-approve`, and trusting discovery does not enable
  ambient project extensions.

### Supported profile fields

| Field | Behavior |
| --- | --- |
| `name`, `description`, body | Required. The body is the instructions; `prompt` or `systemPrompt` can replace it. |
| `package` | Namespaces the name as `package.name`. |
| `aliases` / `alias` | Comma-separated or a YAML list. Exact names win; an ambiguous alias fails. |
| `model`, `thinking` | Pi model resolution and thinking levels. `thinking: false` means off. |
| `tools` | Intersected with the parent's active allowlist. Omitted means pi's normal built-in tools, not the parent's pane or automation tools. Empty or `false` means no ordinary tools. |
| `systemPromptMode` | `append` or `replace`. Custom profiles default to replace. |
| `inheritProjectContext` | Controls normal AGENTS.md/CLAUDE.md discovery. Custom profiles default to false. |
| `defaultContext` / `context` | `fresh` or `fork`. |
| `skills` / `skill`, `skillPath`, `inheritSkills` | Pi's skill loader resolves named or explicit local skills. There is no package-skill registry discovery. |
| `extensions`, `subagentOnlyExtensions` | Local files, resolved relative to the agent file. They run with the user's permissions. |
| `disabled` | Refuses to launch. |

- **Unknown fields fail the profile**, rather than silently weakening it. This includes runner,
  permissions, budgets, fallback models, memory, timeouts, and recursion policies.
- **`tools: inherit` is rejected.**
- **Custom tools:** a requested custom tool without an explicit extension fails. Startup checks
  that every permitted tool is actually registered.
- **Tool enforcement:** tools are intersected with the parent allowlist at startup and before
  each prompt, and disallowed calls are blocked. Nested delegation tools stay forbidden.
  `shepherd_parent_message` is always available.

`subagents.agentOverrides` entries fill fields that a custom file leaves out; project entries
beat user entries, and explicit file fields still win. Overrides on Shepherd's bundled profiles
fail closed and name the affected agent. `disableBuiltins` is honored. Other pi-subagents
settings produce diagnostics and are not imported. This is not full pi-subagents parity.

## Child tools

| Tool | Behavior |
| --- | --- |
| `shepherd_child_start` | Starts a background child and returns its run ID. `agent` selects a profile (`role` is an alias). `mission:false` opts out of the default mission record. |
| `shepherd_child_message` | Steering or follow-up input. Acceptance is not completion. |
| `shepherd_child_wait` | Waits for any or all of up to 16 children, for up to 60 s (default 30 s). Cancelling a wait does not cancel the children. |
| `shepherd_child_result` | Lists retained runs or reads one result: up to 16 KiB of text per child, 4 KiB inside a wait. `sessionFile` holds the full conversation. |
| `shepherd_child_cancel` | Clears queues, aborts, and terminates the child, waiting for the process to exit. |
| `shepherd_child_resume` | Continues an exited child with its saved profile, model, cwd, and transcript. Tools can only narrow across a resume. |
| `shepherd_child_agents` | Lists profiles, where they came from, and diagnostics. |
| `shepherd_workflow` | Runs a script (below). |
| `shepherd_mission` | Manages mission records (below). |

**Questions.** Children use `shepherd_parent_message` for progress or questions. For a question
the child sets `needsReply`, finishes its turn, and waits for an explicit continuation. Completion
and messages wake the parent. Delivery is not durable, and not exactly-once across a crash.

**Context.** Fresh context is the default unless a profile or setting chooses fork. Fork copies
the selected branch up to the last complete tool batch, using a separate `SessionManager`. It
leaves out in-flight tool calls and never branches the parent's live session.

**Child processes.** Children run with `PI_OFFLINE=1` and with `SHEPHERD_*`, `PI_SUBAGENT*`, and
session and model variables stripped. They get `--no-skills --no-prompt-templates --no-themes
--no-approve`, plus `--no-context-files` when the profile doesn't inherit project context.

**Artifacts.** Each child gets `<support dir>/children/native-<uuid>/`, holding the transcript,
prompt, status, inspector controls, and a writer lease.

- Paths come from IDs, never task text.
- The writer lease rejects a second writer and is not reclaimed automatically after a hard
  crash. Check that the old process is gone before removing an interrupted lease by hand.
- Nothing is deleted automatically.

## Scripted workflows

`shepherd_workflow` starts asynchronously by default, or waits with `async:false`.
`action: status|wait|cancel` targets a workflow this parent owns. Waits are capped at 60 s, and
each run has a deadline of at most 30 minutes (`timeoutSeconds` can lower it).

```js
{
  workflowScript: `
    const scan = await runs.run("scan", { agent: "scout", task: "Find the API contract" });
    const reviews = await runs.all([
      { key: "correctness", agent: "reviewer", task: "Review: " + scan.output },
      { key: "tests", agent: "reviewer", task: "Check tests for: " + scan.output }
    ]);
    await state.set("reviewed", reviews.map(r => r.ok));
    return reviews;
  `
}
```

- **`runs.run(key, params)`** resolves after the child exits cleanly, or rejects on failure. A
  result has `key`, `id`/`runId`, `agent`, `ok`, `state`, `output`, and `error`.
- **`runs.all([...])`** runs a batch of at most 16. It returns per-child outcomes in order,
  without failing siblings on ordinary errors. A failed item carries only `key`, `ok:false`,
  `state:"failed"`, and `error`.
- **`runs.steer(key, message, {mode})`**, **`runs.status(key)`**, and **`runs.cancel(key)`**
  address a child by its key. Steering accepts or queues input; it does not prove the model
  complied.
- **Pending work:** a normal return while calls or children are still pending fails and cancels
  them.
- **Keys:** duplicate keys are rejected. A key starts with a letter or digit and may contain
  letters, digits, `.`, `_`, and `-`, up to 128 characters.
- **Size limits:** a workflow may create at most 64 children and make 512 bridge calls. The
  script may be up to 32 KiB and its result up to 64 KiB.
- **Not supported:** nested workflows, worktree, gate, and output-schema options, and
  workflow-level resume. `shepherd_child_resume` still works after the workflow finishes.

**Cancellation** closes admission, terminates the evaluator, waits for in-flight starts, and stops
only the children that workflow owns. Child completions inside a workflow do not start their own
parent turns; the workflow sends one completion notification. Workflows never restart or replay
on reload.

**Execution boundary.** The script runs in a VM context inside a dedicated Node Worker. Only
bounded JSON strings cross its mailbox. The script has no host callbacks, `process`, `require`,
filesystem, or network access, and imports and code generation are disabled. An outer deadline
stops synchronous loops, loops after an `await`, and promises that never settle. This is
restricted execution, **not an OS sandbox**: children still use their normal tools with the
user's permissions, and explicit extension files run with full permissions.

## Missions

`shepherd_mission` supports create, list, show, update, close, attach-run, and attachment. Records
live at `<support dir>/shepherd-native/missions/<sha256 of the parent cwd>/mission-<uuid>.json`
and never touch pi-subagents' mission data.

- **Contents:** a title, objective, status (planned, active, waiting, needs_decision, complete,
  or cancelled), summary, run links, descriptive attachments, and bounded JSON state.
- **Size:** a record is capped at 256 KiB and 64 attachments.
- **Listing:** shows up to 200 records.
- **Writes:** each update takes an exclusive lock, rereads, and atomically replaces the file
  (mode 0600).

**Mission lifecycle:**

- Closing a mission records a conclusion; it does not cancel processes.
- Direct children never move a mission past `active` on their own.
- A successful workflow moves its open mission to `waiting`, and a failure requests attention.

**Which runs get a mission:**

- A child or workflow creates a mission unless given `mission:false`. A workflow creates one
  mission for all its children.
- `missionId` attaches an existing mission, and `mission:{title,objective}` creates one.
- If automatic creation fails, the run still happens and returns a warning. If an explicit
  request fails, the run doesn't start.

Workflows can read and write mission state with `state.get(key)` and `state.set(key, value)`.
State is data only.

**On parent restore,** only children from the same pi session are restored. A nonterminal child
without a live writer lease is marked stopped, and its mission link is marked interrupted. A
parent in the same directory can list old missions, but it cannot steer or resume another
parent's processes.

## Slash commands

These call the runtime directly, without a model turn. In Shepherd (RPC mode), typing one in the
composer or choosing it from the `/` menu produces a text report. The pickers and fleet overlay
appear only when the same extension runs in pi's interactive TUI.

| Command | Behavior |
| --- | --- |
| `/subagents [agent]` | Profile list or one profile's details, source file, and diagnostics. |
| `/run <agent> <task…> [--bg] [--fork]` | A one-child workflow. Foreground by default (it blocks the command until done); `--bg` runs it in the background, `--fork` uses fork context. Only trailing standalone flags are stripped. Task text is JSON-encoded, never interpolated. |
| `/subagents-fleet [id]` | Live list and transcript of this parent's children. |
| `/subagents-stop [id]` | Stops one active child after confirmation, naming its workflow if stopping it may cancel siblings. |
| `/subagents-models [agent]` | Effective models from the local catalog, with no network probes. |
| `/subagents-doctor` | Pi version, project trust, defaults, discovery errors, retained counts, and the actual command names. It makes no repairs. |
| `/missions [id]` | Mission list or one full record. |
| `/workflows [id]` | Workflow list or one status and output. |

If a command name is already taken, or the pi-subagents `subagent` tool is registered, the whole
family registers with a `shepherd-` prefix instead (`/shepherd-run`, `/shepherd-missions`, …).
`/subagents-doctor` lists the actual names.

## How Shepherd shows them

**Control path.**

- **Publishing:** the children extension publishes up to 20 children, active and needs-reply
  first. `shepherd-subagents.ts` merges them with any pi-subagents reports (also capped at 20)
  and sends `setAgentChildren`. The rows ride the thread snapshot as `subagents` (see
  [native-thread.md](native-thread.md)). Older retained runs drop out of the UI.
- **Commands:** card buttons and the inspector's composer send `subagentCommand` through the
  server to the children extension's `helloChildren` control connection on the Shepherd socket.
  The extension answers `childCommandResult` after calling the same functions the tools use:
  message, cancel, and resume. The parent model is never involved.
- **Errors:** a command times out after 15 s. If the extension is not connected, the command
  fails with "children extension not connected"; the extension reconnects every 2 s.
- **Pause and Continue** are child-only commands. Pause holds the child at its next
  provider-request boundary, after the current tools finish. It sends no OS signals and never
  replays the task. Stop can still abort a paused child.

**Cards.**

- **Placement:** a child's card renders where its `shepherd_child_start` row was. Workflow
  children (including `/run`) sit at the `shepherd_workflow` row. Children with no tool call
  (slash commands, pi-subagents rows) trail the last agent turn.
- **Controls by state:**
  - Running: Inspect (⌘I), Steer…, Pause or Continue, Stop. A paused card reads "Paused ·
    elapsed".
  - Needs you: the child's options as buttons, plus Reply….
  - Failed: Retry (resume with the original task) and Transcript.
- **Grouping:** more than three siblings fold into a runs strip. Needs-you cards stay visible.
- **Ledger:** once every run in a spawn group has finished, the cards become one ledger at the
  first spawn's position. The header shows the state cells, "all done · wall · tokens" (or
  "n done · m failed …"), and the combined DiffStat and file count. Below it, one 44pt row per
  child in spawn order: glyph, role, a one-line summary (or the exit reason), "files · tools ·
  duration". Diff counts come from `edit` calls; `write` lists the file at +0/−0.
- **Turn footer:** reads "time · duration · N tool calls · n subagents". The subagent count
  links to the first child.

**Inspector.** It opens in the right pane beside the thread (`RightPaneSplit`: 600pt default, at
least 480pt, at most half the window, with the width remembered). It shares that slot with the
review, and the inspector wins when both are open. Clicking the inspected card or ledger row again
closes it; sidebar rows always open it.

- **Header:** role, "k of n", and a state word, above a line with context, model, thinking (live
  runs only), turns, tools, and tokens. Live runs have Pause/Continue and Stop.
- **⋯ menu:** Refresh Transcript (live runs); Copy Transcript and Show Session File in Finder
  (finished runs).
- **Transcript:** pages the child's session file (its last 8 MiB) 50 entries at a time, using the
  thread's own projection. "N earlier turns · Show all" loads more. Scrolling up stops following
  a live run. Switching children invalidates pending pages, and Copy Transcript loads every page
  first.
- **Live runs** end in a Steer composer addressed to the child ("to: worker · not the parent").
  A failed send keeps the draft.
- **Finished runs** are read-only:
  - ‹ › step through siblings.
  - A Result block shows the summary and touched files (the file links reveal the file in
    Finder).
  - Messages from the parent appear as bubbles captioned "from parent".
  - The bottom bar has Re-run, Fork as new agent, Copy transcript, and "kept with the thread".
- **Re-run** is `shepherd_child_resume` with the original task.
- **Fork as new agent** copies the child's session into pi's session directory under a fresh ID
  (`PiSessionFile.fork`: header rewritten, every entry kept). It starts an RPC agent on it
  (`NewAgentConfig.piSessionID`), provisionally named `<role> (fork)` until the namer retitles
  it. It uses the run's cwd and model, falling back to the parent's. A missing transcript shows
  an error and creates nothing. Remote agents have no Fork.

**Sidebar.** Children nest under their parent with a branch glyph in the state color, and elapsed
time, "needs you", "failed", or a duration trailing. A group stays expanded while any run is live.
Once all are finished it gets a disclosure header ("n subagents · done h:mm"). The header is
expanded for the selected thread and folded for the others, whose agent row then shows "n sub".
Selecting a child selects its parent and opens the inspector.

Child runs are display state reported by the extension. Shepherd never persists them.

## The fleet view in pi's TUI

When the extension runs in an interactive pi session instead of under Shepherd, `/subagents-fleet`
opens an overlay: a flat list and transcript, reply-required children first, then running,
failed, and finished.

| Key | Action |
| --- | --- |
| ↑/↓ or j/k | Select a child |
| Page up/down, End | Scroll the transcript; End follows it again |
| `e` | Toggle full tool output |
| `p` | Show the transcript path |
| `s` | Compose a steer or follow-up (Tab switches mode) |
| `x`, then `y` | Stop the child |
| Esc or Ctrl+C | Close the overlay; the children keep running |

`shepherd-inspect.mjs` holds the overlay's view helpers. Shepherd installs it beside the children
extension but never launches it. You can still run it by hand in a terminal pane to watch one
run:

```sh
node shepherd-inspect.mjs --async-dir <dir> --run-id <id> [--index N] [--theme-path <file>]
```

Colors come from the pi theme JSON passed with `--theme-path` (or `SHEPHERD_PI_THEME_PATH`).
Without one, it falls back to the 256-color palette.

## Process lifetime

- **Completion:** a normal RPC completion waits for `agent_settled`, closes stdin, and observes
  the exit. Provider errors, token exhaustion, malformed protocol, unsupported blocking dialogs,
  and unexpected exits fail the run.
- **Bash:** the bundled child bash tool keeps ordinary commands in Shepherd's PTY process group,
  and an EXIT trap waits for background jobs.
- **Cancellation:** stops the owned child's descendants, never the shared group. App shutdown
  kills the group.
- **Limits:** programs that deliberately daemonize or escape their process ancestry are outside
  this guarantee. A cwd is not a filesystem sandbox, so coordinate one writer per checkout.

## Validation

```sh
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent" \
  node --test Tests/Extensions/*.test.mjs
```

- **Isolation:** the node tests isolate `HOME`, pi settings, and discovery roots, and use a local
  fake provider. No model request is made.
- **Coverage:** discovery, trust and precedence, profile fields and overrides, model and default
  propagation, resume, mission isolation and interruption, workflow sequencing, steering,
  errors and cancellation, evaluator limits, command-name collisions, the RPC fallbacks, and the
  inspector's input handling.
- **Real-model smoke test:** opt-in and uses your existing authentication:
  `PI_SMOKE_MODEL=<provider/model> node Tests/Extensions/native-children.smoke.mjs`.

The Swift unit tests check that every embedded module is byte-identical to its
`Extensions/` source and that the settings reach the launch environment.
