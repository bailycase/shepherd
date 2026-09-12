# Native subagents

Enable **native subagents** in Settings > Pi for newly launched agents. It is off by default and separate from **subagent display**. Existing pi-subagents tools, settings and mission records remain unchanged. Pi 0.85.1 or newer with public npm package APIs is required. No additional npm dependencies are installed.

The parent extension owns child `pi --mode rpc` processes. Swift installs the extension modules and displays their reports. There is no daemon, scheduler, watchdog, automatic goal loop, nested delegation or automatic worktree management. No mission or workflow grants permission to commit, merge, deploy or mutate a repository.

## Settings and agent files

Settings > Pi exposes concurrency, model, thinking, fresh/fork context and discovery scope. These apply on the next parent launch. Concurrency is shared across direct calls and workflows, defaults to four and permits 1–16 children. Up to 64 child records and 32 workflows are retained per parent; at most four workflows run concurrently.

For model, thinking and context, precedence is explicit call, then agent file, then Shepherd Settings, then parent model/thinking. A thinking suffix on the selected model is used before a separate profile thinking default. Explicit `thinking` wins over the suffix. `model: inherit` selects the current parent model. Other model forms use Pi's public CLI resolver, including unqualified IDs and `provider/model:thinking`. Pi resolves ambiguity and errors; children check the exact resolved model against their own catalog before accepting the task. Builtin and models.json providers work. Parent-only provider extensions do not transfer automatically.

`shepherd_child_agents` lists effective profiles, provenance and diagnostics. Agent Markdown stays the source of truth; Shepherd never edits it. Pi's configured agent directory comes from `getAgentDir()`, including `PI_CODING_AGENT_DIR`.

Discovery precedence, low to high:

1. Shepherd's bundled scout, reviewer, planner and worker defaults.
2. Agent directories declared by **configured, already installed** Pi packages using `pi-subagents.agents` or `pi.subagents.agents`. No installation or registry scan occurs.
3. `PI_SUBAGENT_EXTRA_AGENT_DIRS`, then `<Pi agent dir>/agents`, then `~/.agents`. This global legacy-last ordering matches installed pi-subagents 0.51.0.
4. The nearest project configuration root's `.agents`, then `.pi/agents`. `.pi/agents` wins within that project. Pi's `CONFIG_DIR_NAME` replaces `.pi` on rebranded distributions.

Scope is user, project, both or bundled only. Package scope follows the same selection. Discovery recursively reads Markdown, excluding `.chain.md`, skill directories, `.git`, node_modules and nested `.pi`/`.agents` project roots. Directory symlinks are not followed. Project file symlinks that escape their agent directory are rejected. Files are capped at 128 KiB and traversal at 16 directories deep.

Project profiles require active Pi trust for the current canonical cwd. A different child cwd requires an explicit saved Pi trust decision for that cwd or an ancestor, read through `ProjectTrustStore`. A parent's temporary trust does not authorize another cwd. Native discovery deliberately does not treat the absence of Pi's usual trust-requiring resources as approval to load agent files. A skipped project root produces a diagnostic. Child runtime still uses `--no-approve`; trusting discovery does not enable ambient project extensions.

### Supported profile subset

| Field | Behavior |
| --- | --- |
| `name`, `description`, Markdown body | Required identity metadata; body supplies instructions. `prompt` or `systemPrompt` can replace the body. |
| `package` | Namespaces the runtime name as `package.name`. |
| `aliases` / `alias` | Comma-separated or YAML list. Exact names win; ambiguous aliases fail. |
| `model`, `thinking` | Pi model resolution; thinking accepts Pi levels. `thinking: false` means off. |
| `tools` | Explicit names are intersected with the parent's active allowlist. Omitted uses Pi's normal global builtin defaults, not parent pane/automation tools. Empty or false means no ordinary tools. |
| `systemPromptMode` | append or replace. Custom profiles default to replace; delegate defaults to append. |
| `inheritProjectContext` | Controls ordinary AGENTS.md/CLAUDE.md discovery. Custom profiles default false; delegate defaults true. |
| `defaultContext` / `context` | fresh or fork. |
| `skills` / `skill`, `skillPath`, `inheritSkills` | Pi's public skill loader resolves named or explicit local skills. User paths and trusted target project paths are considered. Explicit skillPath skills are included. No package-skill registry discovery. |
| `extensions`, `subagentOnlyExtensions` | Explicit local files resolved relative to the agent file. No package strings or directories. These files execute with the user's permissions and must be trusted. |
| `disabled` | Refuses launch. |

Unknown fields fail the profile rather than silently weakening it. This includes runner, permissions, budgets, acceptance policies, fallbackModels, memory, automatic outputs/defaultReads, timeouts and recursion policies. `tools: inherit` is rejected because its reference meaning includes ambient extension loading. Use omitted tools for normal builtins, or list tool names and their explicit providers. A requested custom tool without a provider fails; startup also checks that every permitted tool is actually registered in the child. Parent permission hooks and custom implementations are not inherited. `shepherd_parent_message` is always available.

Supported `subagents.agentOverrides` fields fill fields omitted by custom files, with project override entries taking priority over user entries. Explicit custom file fields still win. Overrides on Shepherd bundled defaults fail closed and name the affected agent; define a user agent file instead. `disableBuiltins` is honored. Other pi-subagents settings produce diagnostics and are not imported. Shepherd Settings own native defaults. This is not full pi-subagents configuration parity: unmanaged package scans, git-root discovery policy, ambient extensions, package-skill resolution and the reference's management UI are not implemented.

## Terminal commands

Commands call the native runtime directly. They do not ask the parent model to invoke a tool.

| Command | Behavior |
| --- | --- |
| `/subagents [agent]` | Read-only profile list, details, source file and discovery diagnostics. No argument opens a picker in TUI mode. Names and aliases resolve like child launch. |
| `/run <agent> <task...> [--bg] [--fork]` | One-child scripted workflow. Foreground by default with `async:false`; `--bg` uses `async:true`. `--fork` selects fork context. Without it, profile and Settings context still apply. |
| `/subagents-fleet [id]` | Live list and selected transcript for this parent's retained children. An ID preselects that child. |
| `/subagents-stop [id]` | Select one active child or name its ID, then confirm stopping its owned process tree. Workflow ownership is shown before confirmation because stopping one workflow child may cancel its siblings. It never targets unrelated children. |
| `/subagents-models [agent]` | Effective configured/resolved models from the local parent catalog, including inherited models. No network probes. Isolated-child availability is checked again at launch. |
| `/subagents-doctor` | Pi version support, installed bridge, project trust, defaults, discovery errors, retained counts and actual command names. No repairs. |
| `/missions [id]` | Read-only native mission list or full record. A record is not a running process. |
| `/workflows [id]` | Read-only retained workflow list or status/output. Previous-parent workflows are not replayed. |

`/run` strips only trailing standalone `--bg` and `--fork` flags, repeatedly. Flags inside task text remain task text. Task text is JSON-encoded into the existing workflow runner, never interpolated as JavaScript. Inline bracket configuration such as `worker[model=...]` is rejected explicitly. Use the supported agent-file fields instead. Slash workflow completion reports do not trigger a parent model turn. Existing LLM workflow tools keep their notification behavior.

Command registration happens at `session_start`, after extension factories load. If an existing command name conflicts, or the pi-subagents `subagent` tool is registered, the entire native command family uses `shepherd-` names, for example `/shepherd-run`, `/shepherd-subagents-fleet`, `/shepherd-missions`. Existing commands remain untouched. Further prefixing avoids an already occupied native alias. Doctor lists the actual names. This deliberately avoids Pi's ambiguous numeric duplicate-name suffixes; a third-party extension that registers a conflicting command later at runtime still requires a reload after resolving that configuration.

Custom UI opens only when `ctx.mode === "tui"`. RPC receives text notifications, with supported basic confirmation dialogs for stop. Print/JSON receive text reports without triggering a turn; stop refuses without interactive confirmation. TUI reports use custom entries outside model context. Print/JSON fallback custom messages remain in the session context for a later turn.

### Fleet interaction

The overlay is a flat, stacked list and transcript, with no cards, meters or permanent panel. Rows show state, task, elapsed duration and latest tool. Reply-required children come first, then running/queued children, then failed children, then complete/stopped history. Selection tracks the child ID when sorting changes. Terminal duration freezes at the recorded end; `?` means older artifacts lack an end timestamp.

- Up/down or j/k selects a child. Page up/down scrolls its transcript. End resumes following. Each child keeps its scroll anchor while switching selection. Scrolling pauses transcript movement, not lifecycle or control updates. `paused · N new` counts newly rendered lines.
- Tools collapse by default. `e` toggles full text output, including errors. Failed results have an explicit error label. Expanded output still obeys the viewer's 2 MiB input and 8,000-line tail limits. Omission notices identify bounded output. `p` toggles a wrapped, scrollable saved transcript path for the full evidence. Non-text attachments are not rendered.
- `s` composes with a visible recipient and short run ID. Running children use `steer` or `followUp`; Tab changes mode. Settled or exited children show `reply · resumes <id>` and continue their saved session with the answer after observed exit. Enter sends; Escape keeps that child's draft. Trust, active workflow ownership, concurrency, transcript and writer-lease failures appear with their runtime reason and keep the draft. Navigation shortcuts do not steal draft text. The reply says `accepted or queued` only after the runtime acknowledgement; it never claims delivery or completion.
- `x` asks to stop the named child. The confirmation names its owning workflow, if any, and warns that workflow cleanup may cancel siblings. Only `y` confirms. Escape cancels. Escape or Ctrl+C closes the overlay without stopping children.

Status uses a colored dot beside a neutral word. Fleet dots use existing Pi theme names: `success` for running/queued green, `accent` for needs-reply orange, `dim` for idle, and `mdLink` for completed slate blue. Failed and stopped dots also use orange. The standalone inspector reads the same four colors from Shepherd's active pi theme JSON on each refresh and emits 24-bit ANSI dots. If the file or a role's hex color is unavailable, it falls back to ANSI palette indices 107, 173, 240 and 103 for those roles. All other content stays neutral. Optional metadata truncates before the short run ID; hints occupy two lines at 80 columns. Transcripts remove bold, inline-code and link markers and wrap at word boundaries, with hard breaks for long tokens.

Shared selection/submit/cancel/tab hints follow Pi's injected keybinding manager. Fleet-only letter and transcript-navigation keys are local to the overlay.

## Child tools and continuation

- `shepherd_child_start` returns a background run ID. `agent` selects a profile; `role` remains an alias for existing callers. `mission:false` opts out of the default mission record.
- `shepherd_child_message` accepts steering or follow-up input. Acceptance is not completion.
- `shepherd_child_wait` waits for any or all selected children, at most 16 IDs and 60 seconds. Cancelling a wait does not cancel the children.
- `shepherd_child_result` lists retained runs or reads a result. Text is capped at 16 KiB per child, 4 KiB in wait. `sessionFile` contains the full conversation.
- `shepherd_child_cancel` clears queues, aborts and terminates the owned child. It waits for observed process exit.
- `shepherd_child_resume` continues an exited child's saved profile, model, cwd and transcript. It does not adopt edits to the profile. Tools only narrow, including across parent reload. A live workflow retains ownership through cleanup; rejected resume cannot detach its child.

Children use `shepherd_parent_message` for progress or questions. For a question they set `needsReply`, finish the turn, and await an explicit parent continuation. This is not pi-subagents' blocking contact_supervisor protocol. Completion and messages wake the originating parent; delivery is not durable or exactly once across a crash.

Fresh context is the default unless a profile or Settings chooses fork. Fork copies the selected branch through the last complete tool batch using a separate public `SessionManager`; it omits in-flight tool calls and partial sibling results. It never branches the parent's live manager. The receipt reports omitted entries.

Artifacts live beside the socket under `children/native-<uuid>`, with transcript, prompt, status, inspector controls and writer lease. IDs, not user task text, form paths. Session metadata records descriptors. A writer lease rejects concurrent writers and is not automatically reclaimed after a hard crash. Verify that the old process is gone before manually removing an interrupted lease. No artifacts are automatically deleted.

## Scripted workflows

`shepherd_workflow` starts asynchronously by default, or waits with `async:false`. `action: status|wait|cancel` targets a workflow ID owned by this parent. Wait is capped at 60 seconds. Each execution has a deadline of at most 30 minutes, configurable downward with `timeoutSeconds`.

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

`runs.run(key, params)` resolves after clean child exit or rejects on failure. `runs.all` validates its batch and returns ordered per-child success/failure outcomes without failing siblings for ordinary child errors. Fanout queues against the shared child limit. Results include key, run ID, state, output and error; successful runs also expose `ok` and `agent`.

Ordinary JavaScript handles sequencing, branching, Promise.all and Promise.race. `runs.steer(key,message,{mode})` accepts steer, follow_up, followUp or auto. It targets a host-owned stable key, never a script-supplied artifact path. `runs.status(key)` and `runs.cancel(key)` use the same mapping. Start a promise, await evidence, steer the running child, then await the original promise. Steering accepts or queues input; it does not prove model compliance.

Await or return calls. A normal return while calls or children are pending fails and cancels them. This is a pending-work rule, not the reference's complete promise-observation analysis: a fire-and-forget operation that already finished before return is not detected. Duplicate keys reject, even with identical parameters. Keys support letters, digits, dot, underscore and hyphen, up to 128 characters. Batch size is at most 16; a workflow can create at most 64 children and issue 512 bridge calls. Nested workflows, worktree/gate/outputSchema options and workflow-level child resume are rejected. Explicit `shepherd_child_resume` remains available after workflow cleanup.

Cancellation closes admission before cleanup, terminates the evaluator, waits for in-flight child starts and stops only children owned by that workflow. Shutdown suppresses notifications to the old parent. Child completions inside a workflow do not trigger independent model turns; the workflow sends one completion notification. Workflows do not restart or replay on reload. Missions retain recovery data, not executable scripts or runtime authority.

### Actual execution boundary

A dedicated Node Worker contains a VM context. API functions, promises, decoded replies and errors are created **inside** the VM. Only bounded JSON strings cross its mailbox. The script has no host callbacks, process, require, filesystem or network API. Imports and string/Wasm code generation are disabled. Serialization stays inside the worker. An outer deadline terminates synchronous loops, post-await loops and never-settling promises independently of host dispatch.

This is restricted execution, **not an OS sandbox**. Node does not promise that vm contains hostile code, and Worker heap limits are not a complete process-memory quota. Approved children still use their normal tools with the user's account permissions. Explicit extension files also run with full permissions. Run untrusted work in an OS-contained environment.

## Missions

`shepherd_mission` supports create, list, show, update, close, attach-run and attachment. Records persist under `<Shepherd support>/shepherd-native/missions/<sha256 canonical parent cwd>/mission-<uuid>.json`. They never read or mutate pi-subagents mission data. Parent cwd determines the mission namespace even when a child works elsewhere.

Records include title, objective, status, summary, run links, descriptive attachments and bounded JSON state. Status values are planned, active, waiting, needs_decision, complete and cancelled. Close defaults to complete and does not cancel processes. A successful workflow moves an open mission to waiting, not complete; explicit closure records the human or parent conclusion. Failure requests attention. Attach-run accepts only this parent's retained child IDs; attachment stores `{title,uri}` without reading or executing its target.

Normal children and workflows create a mission unless `mission:false`. A workflow creates one enclosing mission, not one per child. `missionId` attaches an existing open mission; `mission:{title,objective?}` creates an explicit one. Automatic creation failures return missionWarning and allow the run; explicit requests fail before launch. Later ledger-write failures are visible warnings and do not claim durable success.

Mission workflows expose `state.get(key)` and `state.set(key,value)`. Missing keys return undefined. State is data only; no key changes process permissions or paths. Reserved prototype keys are rejected. Each update exclusively locks, rereads and atomically replaces the record with mode 0600 under private directories. The entire record is capped at 256 KiB, attachments at 64, list output at 200 records. Lock contention fails with retry guidance; crash locks require manual verification. There is no global pointer index, goal budget, automatic coordination loop or cross-parent resume authority.

On parent restoration, retained nonterminal children without a live writer lease are marked stopped and their mission links reconciled as interrupted. A live lease is treated conservatively and is not overwritten merely because another parent is inspecting the mission. Old missions can be listed from a new parent in the same canonical cwd, but their run links do not authorize that parent to steer or resume another parent's process.

## Process lifetime, sidebar and inspector

Normal RPC completion waits for `agent_settled`, closes stdin and observes exit. Provider errors, token exhaustion, malformed protocol, unsupported blocking dialogs and unexpected exit fail the run. Token-limited answers remain available for explicit continuation.

The bundled child bash adapter uses public `createBashTool` and keeps ordinary commands in Shepherd's PTY process group. An EXIT trap waits for background jobs, preserving ancestry for cancellation. Cancellation snapshots descendants of the owned child, never the shared group. Hard owner death closes RPC stdin; app shutdown kills its group. Programs that deliberately daemonize, replace traps or escape ancestry remain outside this guarantee. Cwd is not a filesystem sandbox; coordinate one writer per checkout.

`shepherd-subagents.ts` remains the sole sidebar publisher and merges native children with legacy reports. Active rows have priority. The standalone inspector reads status/transcript and submits steering or stop control files. It retains the Swift launch arguments `node shepherd-inspect.mjs --async-dir <dir> --run-id <id> [--index N]` and accepts optional `--theme-path <file>`. Swift passes the active theme path because inspector shells do not inherit agent launch variables; direct launches can use `SHEPHERD_PI_THEME_PATH` instead. Closing with Ctrl+C never stops work. Disabling display does not disable execution.

The viewer uses the same bounded transcript reader and stable scroll anchors as the fleet. Its header refreshes while paused and reserves state and duration before the task. Needs-reply text, run errors and control failures stay visible. The composer keeps mode and recipient above a horizontally scrolled draft tail and insertion marker. Buffered stdin decoding handles split UTF-8 and escape sequences, coalesced text plus Enter, and bracketed paste. Pasted newlines stay in the draft; pasted confirmation letters never authorize stop. Completed duration uses the recorded end, or says `duration unavailable` for older records without one. Up/down and page up/down scroll; End or Escape follows. Type `:tools` to expand/collapse tool output, `:path` to show the full saved transcript path, and `:stop` to request confirmation. Stop is explicitly **entire run**, including all lanes when inspecting one lane of a legacy parallel run. `y` confirms and Escape cancels. Bare `stop` is ordinary steering text. For native settled or exited runs, the same steer file resumes the saved session with the typed answer; legacy controls keep their existing steer behavior. File writes report only `request written · awaiting runtime`. The native runtime publishes the message request ID together with its outcome after dispatch returns: `accepted or queued` acknowledges Pi's prompt command, not model delivery or completion. For stop, it publishes the request ID with `stop accepted · <state>` after the owned process exits, or with a control failure. An already exited run keeps its terminal state. Intermediate launch and exit status writes retain the previous request ID, so a previous acknowledgement cannot hide a newer pending request or failed write. Status retains only the latest outcome; a runtime exit, failed status write or later request can leave an inspector waiting. Legacy runtimes without request IDs use changed notices as a best-effort acknowledgement. No durable or exactly-once acknowledgement is implied.

## Validation

```sh
PI_PACKAGE_DIR=/path/to/pi-coding-agent node --test Tests/Extensions/native-children.test.mjs Tests/Extensions/native-children-expanded.test.mjs
env -u SHEPHERD_SUPPORT_DIR swift test --filter 'AppSettingsTests|AgentSessionTests|PiThemeTests|ChildRunsTests'
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' build
```

Node tests isolate HOME, Pi settings and extra discovery roots. Real Pi RPC uses a loopback provider only. Coverage includes discovery/trust/precedence, package profiles, overrides, omitted tools under a Shepherd parent, model/default propagation, persisted resume ceilings, mission isolation/interruption, workflow sequencing/all/steering/errors/cancel, malformed API requests, constructor/import probes, thenables and bounded evaluator loops. Command and renderer checks cover flag stripping, safe script encoding, collision aliases, RPC fallback, explicit stop confirmation, attention ordering, Unicode width, stable paused anchors, error expansion and omission notices. A standalone inspector subprocess checks live header updates while paused, run-wide confirmation, literal stop steering, coalesced input, bracketed paste, second-request acknowledgements, failed writes and Ctrl+C exit. Real local-provider checks cover fleet and inspector replies, active steering, concurrency and lease rejection, and stopping one of two workflow children with sibling cleanup. Swift tests cover default persistence, launch environment and byte identity of all embedded modules. No external model request is needed.
