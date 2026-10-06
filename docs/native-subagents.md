# Native subagents

Shepherd owns the subagent runtime, profiles, workflows, control channel, and display publisher.
It bundles the runtime as pi extensions and has no third-party subagent dependency. A parent
agent can start child `pi --mode rpc` processes, steer them, wait for them, and script them into
workflows. The parent's Shepherd extension owns every child process. The app installs the
extension modules and displays what they report. There is no daemon, scheduler,
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
  Shepherd loading the runtime; it does not install anything else.
- **Subagent display** loads `shepherd-subagents.ts`, the only publisher of `setAgentChildren`.
  It publishes only Shepherd-owned children into the runs behind the subagent tray
  above the composer, the thread's record lines, the inspector and the palette's Subagents
  section. With display off, children still run but none of that UI appears, and tray commands
  fail because the server only accepts runs that were published.

**Native subagent defaults** appear only while Native subagents is on. They apply on the next
parent launch.

| Setting | Values | Default |
| --- | --- | --- |
| Concurrency | 1–16 (stepper) | 4 |
| Model | Inherit parent, or a model ID | Inherit parent |
| Thinking | Inherit parent, Off, Minimal, Low, Medium, High, Xhigh, Max | Inherit parent |
| Context | Fresh, Fork | Fresh |

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
is not a provider-only sandbox. Shepherd also explicitly loads its managed CLIProxyAPI provider
from its pi home and retains `SHEPHERD_CLIPROXYAPI_CONFIG`, so direct starts, workflow children and
resumes use the same managed catalog and authentication as the parent. Other project and parent
CLI-only extensions still need explicit profile `extensions` entries.

`shepherd_child_agents` lists effective profiles, their owned source files, and diagnostics.
Settings > Subagents manages the same Markdown definitions. Both use the exported parser in
`shepherd-children-config.ts` and pi's frontmatter parser, not a second YAML implementation.

Only `<Shepherd support>/pi/agents` supplies definitions. Pi's `getAgentDir()` is pinned by
Shepherd's launcher. Project `.pi/agents`, project `.agents`, the user's `~/.agents`, package
agent directories, extra-directory environment variables, and settings overrides are not read. The
retired discovery preference is ignored. This replaces the former multi-source discovery
policy. There is no automatic import or migration from those folders.

On first use, missing scout, reviewer, planner and worker files are created without replacing
existing files, then `.shepherd-defaults-v1` records initialization. These defaults preserve the
original tools, instructions, append mode and project-context inheritance. They are ordinary
editable files. Deleting one persists across launches, with no in-memory fallback. Restore
defaults asks for confirmation, restores those four files and preserves custom files.

Settings filters names, descriptions, filenames and diagnostics. New subagent and open-row
use the native Markdown editor. Save validates before writing and compares a content hash;
a stale save, delete or restore fails rather than replacing another editor's changes. Delete
asks first. Unsaved navigation asks to discard. Show in Finder reveals the owned folder;
Open in editor validates the regular file's identity before passing its URL to macOS. Neither action reads another profile root.
Edits apply to new children. Existing runs and their continuations keep their captured profile.

- Markdown traversal skips hidden folders, skills, node_modules and `.chain.md` files, with at
  most 512 definitions, 512 folders, 16 nesting levels and 128 KiB of UTF-8 per file. File and directory
  symlinks do not supply definitions. Broken files stay visible with their actual diagnostic.
  Duplicate names fail every affected definition rather than selecting a fallback. Save and
  Restore refuse new duplicates and catalog overflow before writing. New paths cannot target
  the `skills` or `node_modules` directories that discovery ignores.
- Settings invokes the bundled node and bundled pi parser locally, with no model call. Parser
  work runs off the main actor and has a 10-second timeout and 8 MiB output limit. File writes
  are descriptor-relative, no-follow, same-directory atomic replacements.
- Profile ownership does not remove project-context or explicit skill/extension support.
  A child working elsewhere still needs that directory's saved pi trust for inherited skills.
  The parent's temporary trust does not carry over. Children still run with `--no-approve`.

### Supported profile fields

| Field | Behavior |
| --- | --- |
| `name`, `description`, body | Required. The body is the instructions; `prompt` or `systemPrompt` can replace it. |
| `package` | Namespaces the name as `package.name`. |
| `aliases` / `alias` | Comma-separated or a YAML list. Exact names win; an ambiguous alias fails. |
| `model`, `thinking` | Pi model resolution and thinking levels. `thinking: false` means off. |
| `tools` | Intersected with the parent's active allowlist. Omitted means pi's normal built-in tools, not the parent's terminal or automation tools. Empty or `false` means no ordinary tools. |
| `systemPromptMode` | `append` or `replace`. Custom profiles default to replace. |
| `inheritProjectContext` | Controls normal AGENTS.md/CLAUDE.md discovery. Custom profiles default to false. |
| `defaultContext` / `context` | `fresh` or `fork`. |
| `skills` / `skill`, `skillPath`, `inheritSkills` | Pi's skill loader resolves named or explicit local skills. There is no package-skill registry discovery. |
| `extensions`, `subagentOnlyExtensions` | Local files, resolved relative to the agent file. They run with the user's permissions. |
| `disabled` | Refuses to launch. |

- **Unknown fields fail the profile**, rather than silently weakening it. This includes runner,
  permissions, budgets, fallback models, memory, timeouts, and recursion policies.
- **`tools: inherit` is rejected.**
- **Custom tools:** a requested custom tool without an explicit extension fails (a design
  agent's design tools are the exception: see Child processes). Startup checks
  that every permitted tool is actually registered.
- **Tool enforcement:** tools are intersected with the parent allowlist at startup and before
  each prompt, and disallowed calls are blocked. Nested delegation tools stay forbidden.
  `shepherd_parent_message` is always available.

Agent files are the source of profile configuration. Edit or delete the Shepherd-owned files
in Settings instead. Third-party settings do not affect native definitions.

## Child tools

| Tool | Behavior |
| --- | --- |
| `shepherd_child_start` | Starts a background child and returns its run ID. `agent` selects a profile (`role` is an alias). |
| `shepherd_child_message` | Steering or follow-up input. Acceptance is not completion. |
| `shepherd_child_wait` | Waits for any or all of up to 16 children, for up to 60 s (default 30 s). Cancelling a wait does not cancel the children. |
| `shepherd_child_result` | Lists retained runs or reads one result: up to 16 KiB of text per child, 4 KiB inside a wait. `sessionFile` holds the full conversation. |
| `shepherd_child_cancel` | Clears queues, aborts, and terminates the child, waiting for the process to exit. |
| `shepherd_child_resume` | Continues an exited child with its saved profile, model, cwd, and transcript. Tools can only narrow across a resume. |
| `shepherd_child_agents` | Lists profiles, where they came from, and diagnostics. |
| `shepherd_workflow` | Runs a script (below). |
| `shepherd_mission` | Manages mission records (below). Not registered unless `SHEPHERD_MISSIONS=1`. |

**Questions and results.** A subagent never reaches the user: it asks its parent, and the parent
answers it or asks the user itself, in its own thread, then passes the answer down. Routine
`shepherd_parent_message` progress updates only the child record, without waking the parent or
appending a chat message. For a question the child sets `needsReply` (with `options` when it has
a few answers, and optionally `short`, 1–3 words), finishes its turn, and waits for an explicit
continuation. The child is told so in its prompt and in its tool:

> You never talk to the user: nothing you write reaches them. When you are blocked on a question,
> or on a decision that is not yours to make, ask your parent, never the user: call
> `shepherd_parent_message` with `needsReply: true` and your question (`options:` when it has a few
> possible answers), then finish your turn. Your parent answers it, or asks the user and passes the
> answer down, and your work continues with the answer. A question inside your final answer is read
> as a result, not as a question. Don't guess when the answer matters, and don't ask what you can
> find out yourself.

Any other way a child could ask fails closed. A human dialog its pi opens (`select`, `confirm`,
`input`, `editor`, which an ask-style tool of a user extension uses) is refused and stops the child
with "A child never reaches the user: ask your parent with shepherd_parent_message (needsReply:
true) and finish your turn", which the parent reads in the child's result. Project permission
prompts never open (`--no-approve`), and a child's tools are only those of its profile.

**What the parent is told.** The question reaches the parent as a hidden coordination notice (it
stays in its context, so a question outlives the turn in which the parent asks the user), with
the child's id, the question, the answers it offered, its attempt and its `questionID`, and
instructions that come once per delivery, however many children asked:

> Each child above that needs a reply asked you, its parent, a question it cannot settle itself.
> It never reaches the user, so it is waiting on you.
> - Answer it yourself if you can, from what you know, the files or your tools: call
>   `shepherd_child_resume` with the child's id, your answer as `message` and its `questionID`
>   (`shepherd_child_message` takes the same arguments).
> - Only if you cannot, ask the USER yourself, in your own reply: your question tool if you have
>   one, otherwise a plain question in your message. Then end your turn; the question stays
>   pending. When the user answers, pass the answer down the same way, with the same id and
>   `questionID`.
> - Do not ignore a question, and do not ask the user what you can answer. With several questions,
>   answer what you can and put the rest in one message to the user, naming each child.

An idle parent is woken by the question as it is by an unread completion; while the parent works,
the notice joins the batch delivered at `agent_before_settle`, so several children that asked
arrive as one continuation. Questions notify once, without a second completion wake, and in
either delivery mode. `shepherd_child_wait` and `shepherd_child_result` return a child that asked
with `needsReply`, its `questionID` and a `parentAction` naming the exact call that answers it;
`shepherd_child_result` without an id lists who still waits, and a wait for all hands over a
child that asked once it has finished its turn, without holding it for the others. The answer is
`shepherd_child_resume` (or `shepherd_child_message`) with the `questionID`: it waits for the child
to finish the turn it asked in (its process ends when that turn settles, and an answer sent into the
turn would be lost with it, which a prompt parent would otherwise do) and then resumes it. An answer to a question that
changed, was answered, or was closed is refused ("Child question changed"). Stop on a child that
waits for its parent, from the tray, the inspector or `shepherd_child_cancel`, closes the
question and marks the child stopped; the user's own Steer ends it too, since it resumes the
child. Nothing times out: a child whose parent never answers waits until Stopped.

Unread completion wakes an idle parent; while the parent works, pending results are combined at
`agent_before_settle` into one continuation, not separate follow-up turns. Explicit result reads
and completed waits consume their pending notices; a cancelled wait hands its completion back.
Notifications are hidden coordination messages, not user requests, and tell the parent not to
acknowledge receipt. Stop/error settlement suppresses automatic wake until the parent starts
again. Delivery is not durable or exactly-once across a crash.

`delivery: "report"` on a child or workflow stores its completion as hidden context without
starting a parent turn. `"continue"` is the compatible default for dependent work. A question
notifies, and wakes an idle parent, in either mode. Results include an attempt ID and, while
asking, a `questionID`; pass that ID to message/resume when answering to reject an obsolete
question. A workflow's child that asks ends its turn like any other: its `runs.run` result has
`needsReply: true`, `questionID` and `question` (its `output` is not a result), and the workflow's
summary and completion notice list the children that asked, with the same instructions. The
parent answers them once the workflow ends (a child is resumed only after its workflow).

An accepted queued user send while the parent works sends `parentInput` on its registered children
connection. That ends a child/workflow wait with `waitInterrupted: "user_input"` and the Pi
terminate-tool result, without cancelling any child. This host signal is necessary because
host-queued user messages have not yet reached Pi's ordinary input event. Direct Pi streaming
input also ends waits, with its interruption cleared when that user message is consumed. The user turn can then drain normally; background results do not force
a continuation ahead of waiting user input. An unrelated long-running tool is not forcibly
cancelled by this signal.

**Context.** Fresh context is the default unless a profile or setting chooses fork. Fork copies
the selected branch up to the last complete tool batch, using a separate `SessionManager`. It
leaves out in-flight tool calls and never branches the parent's live session.

**Child processes.** A child runs the parent's own engine: `process.execPath` (the engine's node)
with the package's `dist/bundle/cli.js`, never a `pi` from PATH; a parent not running on node, or
with no bundle, can't start one and the run fails saying so. Children inherit the launcher's
pins from the parent's pi, and run with `PI_OFFLINE=1`. They strip `SHEPHERD_*`, session, and
model variables, except the managed provider's config path above. A startup
exit returns its exit diagnostic to pending commands rather than only "Child exited". They get
`--no-skills --no-prompt-templates --no-themes --no-approve`, plus `--no-context-files` when the
profile doesn't inherit project context. [pi-home.md](pi-home.md#the-launcher) lists what a child
inherits and what it doesn't.

- **The managed provider, exactly.** A child isn't started through Shepherd's launcher, which is
  what gives an agent the CLIProxyAPI provider, so `childLaunch` gives it too: from the parent's
  pinned `SHEPHERD_CLIPROXYAPI_CONFIG` it passes `-e <home>/shepherd-cliproxyapi.ts` (beside the
  connection file) and sets the variable after the `SHEPHERD_*` filter, the only one that
  survives. It does so only while both files exist: with no connection a child is launched as it
  always was, and a launch never fails on a missing extension file. A `cliproxyapi/<id>` model then
  works in a child as in its parent; it is the only provider a child gets beyond pi's own, the
  user's enabled extensions and a profile's `extensions`.
- **A design agent's design tools.** A helper has none of its parent's identity, so it can't call
  the design tools itself. A profile of a helper started by a design agent may list them in `tools:`
  (`design_read`, `design_check`, `system_read`, `comment_list`, `board_write`, `board_edit`,
  `boards_edit`, `board_search`, `board_render`, `board_extract`, `checkpoint_create`,
  `checkpoint_list`, `canvas_update`, `system_write`; not `comment_reply`, `markup_propose` or
  `checkpoint_restore`): the parent runs each
  call through its own design extension, on its own connection, and returns the result or error to
  the helper. Nothing else is relayed, nothing to a parent that draws no design, and a profile
  that lists them for one fails at the start, saying why. It needs no `extensions:` line; if one
  names `shepherd-design.ts` it loads inert, as it always did. The mechanism, limits and
  cancellation are in [designs.md](designs.md#helpers). A typical line:
  `tools: read, design_read, board_edit, design_check`.
- **No per-agent settings.** A child gets none of what Shepherd sets for its parent through
  `SHEPHERD_*` variables or its own extensions, such as a model's service tier: it runs with pi's
  defaults for its model.
- **Errors say what to do.** An `agent` and a `role` together fail ("pass either an agent profile
  or a role"). An unknown name lists the roles and the discovered profiles, and the nearest. A model
  that no provider of the parent's pi lists fails at the start, naming who asked for it (the call,
  a profile or the default), the providers that are loaded and, when the same id exists under
  another provider, `provider/id` to use instead (a `cpa/…` model whose id is under `cliproxyapi`
  reads `cliproxyapi/<id>`). A child that dies before it serves returns pi's own stderr, and for a
  model the parent could resolve but pi refused, says the child doesn't load that provider; one
  that starts without the model in its catalog names the providers it does have.

**Artifacts.** Each child gets `<support dir>/children/native-<uuid>/`, holding the transcript,
prompt, status, inspector controls, what the user sent it (`user-messages.jsonl`), and a writer
lease.

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
  result has `key`, `id`/`runId`, `agent`, `ok`, `state`, `output`, and `error`. A child that asked
  its parent a question instead of finishing also has `needsReply: true`, `questionID` and
  `question`: its `output` is not a result, so a script checks `needsReply` before using it.
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
parent turns; an asynchronous workflow sends one completion through the same batched delivery.
A synchronous workflow's returned result is its delivery, with no extra wake. Workflows never restart or replay
on reload.

**Execution boundary.** The script runs in a VM context inside a dedicated Node Worker. Only
bounded JSON strings cross its mailbox. The script has no host callbacks, `process`, `require`,
filesystem, or network access, and imports and code generation are disabled. An outer deadline
stops synchronous loops, loops after an `await`, and promises that never settle. This is
restricted execution, **not an OS sandbox**: children still use their normal tools with the
user's permissions, and explicit extension files run with full permissions.

## Missions

**Missions are off.** They are deferred (no screen shows them), and every request carried the
mission tool and the `mission` and `missionId` parameters of `shepherd_child_start` and
`shepherd_workflow`, about 470 tokens in every thread (docs/context-budget.md). Unless the
environment sets `SHEPHERD_MISSIONS=1`, the runtime registers no `shepherd_mission`, offers none of
those parameters, writes no mission record for a run, and says nothing of missions in a tool
description; the app never sets it. The tests that cover missions set it. Everything below is how
they behave when it is on.

`shepherd_mission` supports create, list, show, update, close, attach-run, and attachment. Records
live at `<support dir>/shepherd-native/missions/<sha256 of the parent cwd>/mission-<uuid>.json`
and belong only to Shepherd.

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
composer or choosing it from the `/` menu leaves its report in the thread as a note: a displayed
message that starts no turn (`pi.sendMessage` with `display: true` and `triggerTurn: false`),
because pi's `ctx.ui.notify` reaches the host as a toast the thread never draws. The note joins
the conversation the model reads, as anything the user pasted would. The pickers and fleet overlay
appear only when the same extension runs in pi's interactive TUI.

| Command | Behavior | Under Shepherd |
| --- | --- | --- |
| `/subagents [agent]` | Profile list or one profile's details, source file, and diagnostics. | Registered |
| `/run <agent> <task…> [--bg] [--fork]` | A one-child workflow. Foreground by default (it blocks the command until done); `--bg` runs it in the background, `--fork` uses fork context. Only trailing standalone flags are stripped. Task text is JSON-encoded, never interpolated. | Registered |
| `/subagents-fleet [id]` | Live list and transcript of this parent's children. | Not registered: the tray and the inspector are the fleet |
| `/subagents-stop [id]` | Stops one active child after confirmation, naming its workflow if stopping it may cancel siblings. | Not registered: each card and the inspector have Stop |
| `/subagents-models [agent]` | Effective models from the local catalog, with no network probes. | Registered |
| `/subagents-doctor` | Pi version, project trust, defaults, discovery errors, retained counts, and the actual command names. It makes no repairs. | Registered |
| `/missions [id]` | Mission list or one full record. | Registered |
| `/workflows [id]` | Workflow list or one status and output. | Registered |

"Under Shepherd" is `SHEPHERD_AGENT_ID` being set, which every agent's pi has
(`listedCommandNames`). Anywhere else the extension registers all eight, as before. A command that
fails reports `error · …` the same way, so none of them is silent.

If a command name is already taken, the whole family registers with a `shepherd-` prefix instead (`/shepherd-run`, `/shepherd-missions`, …); a
name taken only by a command Shepherd leaves out changes nothing. `/subagents-doctor` lists the
actual names.

## How Shepherd shows them

**Control path.**

- **Publishing:** the children extension publishes up to 20 children, active and needs-reply
  first. `shepherd-subagents.ts` accepts only the owning parent's `shepherd:children:v1` reports
  and sends `setAgentChildren`, capped at 20 rows. The rows ride the thread snapshot as
  `subagents` (see [native-thread.md](native-thread.md)). Older retained runs drop out of the UI.
- **Commands:** card buttons and the inspector's composer send `subagentCommand` through the
  server to the children extension's `helloChildren` control connection on the Shepherd socket.
  The extension answers `childCommandResult` after calling the same functions the tools use:
  message, cancel, and resume. The parent model is never involved: these are the user's own Steer
  and Stop. The host still accepts a message to a child that asked (an older client's Answer
  sends one), and resumes the child with it as the user's words.
- **Errors:** a command times out after 15 s. If the extension is not connected, the command
  fails with "children extension not connected"; the extension reconnects every 2 s.
- **Pause and Continue** are child-only commands. Pause holds the child at its next
  provider-request boundary, after the current tools finish. It sends no OS signals and never
  replays the task. Stop can still abort a paused child.

**The tray and the record.** [docs/design/subagents.md](design/subagents.md) specifies how they look; this
is what they do.

- **The tray:** while a turn's children run, they dock above the composer, one row each, in
  the same card as Up next (`NativeSubagentTray`, derived by the thread store). It shows the
  newest spawn group, plus any child still live from an earlier one, and stays once every child
  has finished until the user's next message.
- **Rows by state:** clicking a row inspects the run.
  - Running: the call in flight, from `lastActivity` (`kind: "running"` from its start, `kind:
    "tool"` once it ends), with its file, the child's diff so far (`files`), and its time. Steer,
    Stop and Open on hover; Pause or Continue and Stop in the context menu and accessibility
    actions, and visible in the inspector.
  - Queued or paused: "Waiting to start", or "Paused before its next model request".
  - Asked the parent: "asked the parent:" and its question, quietly, drawn as waiting (the child
    asked its parent, which answers or asks the user in its own thread; the user is never asked
    by a child, so there is no Answer and nothing takes the composer's place). Steer and Stop
    stay: Steer speaks to the child over its parent, and Stop closes the question. On this row
    Steer is labelled **Reply** (tooltip "Answer this subagent yourself. It was waiting on its
    parent."), in the tray, its context menu, the inspector's field and the touch screens: the
    same `message` command with `steer` delivery, so only the words change. The tally
    reads "waiting on parent", and the tray stays until the question is answered.
  - Done: the first sentence of its summary, its diff and duration. Failed: why.
- **The record:** the thread keeps "Started 3 subagents" where the first `shepherd_child_start`
  row was (workflow children, including `/run`, at the `shepherd_workflow` row; children with no
  tool call at the end of the last agent turn), and once every child finished, "3 subagents
  finished" with the span, files and combined diff, where they finished. The spawn calls and the
  parent's `shepherd_child_wait` and `shepherd_child_result` calls leave no activity lines. Both
  lines open the first child in the inspector. Diff counts come from `edit` calls; `write` lists
  the file at +0/−0.
- **Turn footer:** reads "time · duration · N tool calls · n subagents". The subagent count
  links to the first child. Like the rest of the footer, it shows while the turn is hovered.

**Inspector.** It opens in the side pane beside the thread (`RightPaneSplit`: 600pt by default,
at least 380pt, at most half the main column, the width remembered; it overlays the thread when
the column is too narrow). It takes the pane over from its tabs (Changes), and closing it goes
back to them when the pane was open. Clicking the inspected tray row again closes it; a palette pick always opens
it.

- **Header:** the name and "k of n", above a line with the model, the thinking level (live runs
  only), turns, and tokens (live) or "done 11:02" (finished). Live runs have Pause/Continue and
  Stop; ‹ › step through siblings.
- **⋯ menu:** Refresh Transcript (live runs); Copy Transcript and Show Session File in Finder
  (finished runs).
- **Brief:** the goal (with "step n / m · 62%" while live), and once finished the result and up
  to five touched files, which open the review pane at the file.
- **Transcript:** pages the child's session file (its last 8 MiB) 50 entries at a time, using the
  thread's own projection, one type step smaller. "N earlier turns · Show all" loads more.
  Scrolling up stops following a live run. Switching children invalidates pending pages, and
  Copy Transcript loads every page first. A live run's transcript ends in its call in flight,
  drawn as the thread's live line from what the run reports (`nativeRunLive`); nothing shows
  between calls.
- **Live runs** end in a Steer composer addressed to the child ("to: worker · not the parent");
  for a run that asked its parent it is a Reply composer. A failed send keeps the draft.
- **Finished runs** are read-only: messages from the parent are captioned "from parent", and the
  bottom bar has Re-run, Fork, and Copy transcript. Your own steers and answers (from the tray, the
  inspector, `shepherd-inspect`, or the fleet view) are not: the extension appends each to
  `user-messages.jsonl` beside the child's session before sending it, and the host marks the
  matching transcript message `origin: .user` (the first unclaimed message with its text, written
  no earlier than it was sent). Runs from older extensions have no record, so every later message
  reads as the parent's.
- **Re-run** is `shepherd_child_resume` with the original task.
- **Fork** copies the child's session into pi's session directory under a fresh ID
  (`PiSessionFile.fork`: header rewritten, every entry kept). It starts an RPC agent on it
  (`NewAgentConfig.piSessionID`), provisionally named `<role> (fork)` until the namer retitles
  it. It uses the run's cwd and model, falling back to the parent's. A missing transcript shows
  an error and creates nothing. Remote agents have no Fork.

**Sidebar.** Children have no sidebar rows; everything about a run lives in the parent's thread
(and the palette). A child's question marks nothing there, and posts no notification: it goes to
its parent, and only the parent's own question (a thread waiting on you) puts its row in Needs
you. Live, asking and finished children leave the parent's row as it is.

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
extension but never launches it. You can still run it by hand in a terminal to watch one
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
- **Coverage:** owned-folder isolation, initialization, deletion and restoration, profile fields,
  trust and model precedence, model and default
  propagation, resume, mission isolation and interruption, workflow sequencing, steering,
  errors and cancellation, evaluator limits, command-name collisions, the RPC fallbacks, and the
  inspector's input handling. Managed CLIProxyAPI runs exercise start, resume and workflows against
  a local fake provider, with parent controls and ambient project extensions still excluded. On top
  of that: what a child is launched with (which `-e`, which `SHEPHERD_*` survive, the no-connection
  case), the messages for a bad role, profile or model, and a design agent's design tools relayed to
  real children through a real parent (`native-children-provider`, `design-relay` and
  `native-children-design` tests). `native-children-questions` runs real children that ask: the
  rule in the child's prompt and tool, the notice and instructions the parent gets (idle, working,
  `report` delivery, several children at once), `wait` and `result`, the parent's answer by
  `questionID` and the refusal of an obsolete one, a user's Steer and Stop on a child that asked,
  a workflow's child that asks, and a child that opens a human dialog.
  `native-children-questions-parent` does the same loop with a real parent pi on a scripted provider:
  the parent is woken by the question, answers it with the `questionID`, or asks the user in its own
  reply and, in a later turn, finds the question still in its context and passes the user's answer down.
- **Real-model smoke test:** opt-in and uses your existing authentication:
  `PI_SMOKE_MODEL=<provider/model> node Tests/Extensions/native-children.smoke.mjs`.

The Swift unit tests check that every embedded module is byte-identical to its
`Extensions/` source and that the settings reach the launch environment.
