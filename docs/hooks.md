# Hooks

> Read when you change how hooks are found, trusted, run or shown. Boards: the Hooks section of
> the "Not yet implemented" page in the "Shepherd chat UI" design (`Hooks*.dc.html`,
> `HookThreadScene.dc.html`, `HooksStates.dc.html` is the reference).

Hooks are commands that run at set points in a thread, in the format Claude Code and Codex use:
an event, a matcher, and handlers that get the event as JSON on stdin. Shepherd reads its own
hooks files and the Claude Code and Codex files it finds, runs a hook only once the person
trusts its exact entry, and shows what each hook did in the thread.

Three parts share this contract:

| Part | Where |
| --- | --- |
| Runtime: runs hooks on the agent's events, proposes hooks | `Extensions/shepherd-hooks.ts`, installed by `HooksExtension.swift` |
| Catalog: finds files, parses entries, hashes, trust, writes | `Sources/ShepherdSessions/Hooks/` |
| UI: Settings › Hooks, Sources, Edit, Review, the space's Hooks tab, thread rows, proposal card, composer glyph | `Sources/ShepherdApp/Hooks*.swift`, `Thread/` |

The runtime and the catalog each implement parsing and hashing; the shared vectors in
`Tests/Fixtures/hooks/` keep them equal.

## Files

Hooks are read on the host where the agent runs.

| Scope | Path | Format |
| --- | --- | --- |
| This Mac | `~/.shepherd/hooks.json` | Shepherd |
| This Mac | `~/.claude/settings.json` | Claude Code |
| This Mac | `~/.codex/hooks.json`, `~/.codex/config.toml` (`[hooks]` tables) | Codex |
| Space | `<root>/.shepherd/hooks.json` | Shepherd |
| Space | `<root>/.claude/settings.json`, `<root>/.claude/settings.local.json` | Claude Code |
| Space | `<root>/.codex/hooks.json`, `<root>/.codex/config.toml` | Codex |

`<root>` is the nearest folder at or above the thread's cwd that holds `.git`, searched below the
home folder without running git; else the cwd. The home folder and anything above it is never a
space. Space files load only when pi's `trust.json` trusts `<root>`: the nearest decision at or
above it wins. In the hash, This Mac paths are `$HOME` as given (never resolved) joined with the
relative path; space paths are the real path of `<root>` joined with it. `~/.claude/settings.local.json`
is not read. Claude Code files and Codex files are
read only while their reader is on (Settings › Hooks › Sources).

Every file uses one shape (JSON; the TOML `[[hooks.<Event>]]` tables map to it):

```json
{ "hooks": { "<Event>": [ { "matcher": "Edit|Write", "hooks": [ { "type": "command", "command": "…", "timeout": 10, "statusMessage": "…", "async": false } ] } ] } }
```

The TOML subset is single-line basic and literal strings, numbers and booleans inside hook tables;
anything else there makes the file unreadable. Handler `type` is `command` or `mcp_tool` (`server`, `tool`, `input` with `${field.path}`
placeholders). `prompt` and `agent` handlers are listed but never run. Unknown keys are kept on
write. A file that doesn't parse is reported (`Couldn't read: line N, …`) and contributes nothing.

## Events

| Event | Runs on pi's | Matcher matches | The hook can |
| --- | --- | --- | --- |
| `SessionStart` | `session_start` (source `startup`, `resume`), after compaction (`compact`) | source | add context |
| `UserPromptSubmit` | `input` | – | block the message, add context |
| `PreToolUse` | `tool_call` | tool name | allow, deny, ask, change input |
| `PermissionRequest` | – (Shepherd tools never ask) | tool name | loaded, never fires |
| `PostToolUse` | `tool_result` | tool name | send feedback to the agent |
| `PreCompact`, `PostCompact` | `session_before_compact`, `session_compact` | `manual`, `auto` | notify |
| `SubagentStart`, `SubagentStop` | the children extension's start and finish of a native subagent | profile name | add context; send back |
| `Stop` | `agent_before_settle` | – | send the agent back (at most 3 in a row) |
| `Notification` | the agent's status turning to needs-you (question, failed, signed out) | that reason | notify |
| `SessionEnd` | `session_shutdown` | – | notify; 1 s limit |

A matcher is a regular expression tested against the whole name (`^(?:…)$`); empty or `*` matches
everything. Claude Code tool names match the agent's tools: `Bash`→`bash`, `Read`→`read`,
`Edit`/`MultiEdit`→`edit`, `Write`→`write`, `Grep`→`grep`, `Glob`→`find`, `LS`→`ls`; `mcp__…` names
are the same. A matcher matches when it matches either name.

## What a hook gets and gives back

stdin is one JSON object: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, and per event
`tool_name` (the Claude Code name when one exists), `tool_input` (with `file_path` mirrored from
`path`), `tool_response`, `prompt`, `source`, `trigger`, `stop_hook_active`, `reason`. The command
runs in `<root>` with `CLAUDE_PROJECT_DIR=<root>` and `SHEPHERD_HOOK_EVENT=<Event>`.

| Hook | Shepherd |
| --- | --- |
| exit 0 | goes ahead; stdout JSON is read; for `SessionStart` and `UserPromptSubmit`, non-JSON stdout is context |
| exit 2 | blocks; stderr is the reason the agent reads; on `Stop` the agent keeps working |
| other exit, timeout, spawn error | goes ahead; the thread shows "A hook failed" |
| `decision: "block"`, `reason` | as exit 2 |
| `hookSpecificOutput.permissionDecision` `allow`/`deny`/`ask`, `permissionDecisionReason` | `PreToolUse`; `ask` asks the person in the composer's place |
| `hookSpecificOutput.updatedInput` | `PreToolUse`; the tool runs with it |
| `hookSpecificOutput.additionalContext` (or top-level `additionalContext`) | the agent reads it; over 10,000 characters it gets a file path instead |
| `systemMessage` | shown to the person, not sent to the agent |
| `continue: false`, `stopReason` | stops the agent after this step |

Matching hooks run concurrently. Any deny wins over ask, ask over allow; with no one to answer
(automations), ask is deny. `updatedInput` is merged into the call's input. Default timeout 60 s,
at most 600 s; `SessionEnd` 1 s (max 3 s). Output is capped at 64 KiB per stream. The Stop
send-back count resets when the person sends a message. Hooks also run for nested tool calls.

Known limits: `mcp_tool` handlers report "A hook failed" until pi gives event handlers
`executeTool`. `SubagentStart` context and `SubagentStop` send-backs reach the parent thread as
rows, not the subagent. `trust.json` writes are atomic and re-read first, but not locked.

## Identity and trust

A hook is one handler. Its **slot** is `<file path>#<Event>/<group index>/<handler index>`. Its
**hash** is the lowercase hex SHA-256 of the UTF-8 bytes of

```
<file path>\n<Event>\n<matcher or "">\n<canonical JSON of the handler object>
```

Canonical JSON: object keys sorted by UTF-16 code units, no whitespace, strings escaped as
`JSON.stringify` does (`\"`, `\\`, `\b \f \n \r \t`, other code points below U+0020 as
`\u00XX` lowercase, nothing else escaped), integers without a fraction, other numbers as
`JSON.stringify` prints them, `true`/`false`/`null`. `Tests/Fixtures/hooks/hash-vectors.json` holds
inputs and expected hashes; both implementations test against it.

`<support>/hooks/trust.json` (support = Shepherd's Application Support folder; the runtime gets it
in `SHEPHERD_HOOKS_DIR`):

```json
{ "version": 1,
  "trusted": { "<hash>": { "slot": "…", "entry": "<canonical JSON of the handler>", "matcher": "…", "at": "<ISO date>", "by": "review" | "proposal" | "edit" } },
  "off": ["<hash>"],
  "readers": { "claude": true, "codex": true } }
```

- A hook runs only if its hash is in `trusted` and not in `off`.
- **New**: no trusted entry has its slot. **Changed**: a trusted entry has its slot with another
  hash; the UI diffs the stored `entry` against the current one.
- Writing a hook from Settings (Add, Edit, a proposal) trusts the written hash at once. A file an
  agent or editor changes outside Shepherd is new or changed until reviewed.
- The file is written whole, atomically (temp file and rename), by the app and by the runtime's
  proposal path; readers tolerate a missing or invalid file as empty.

## In the thread

The runtime posts `pi.sendMessage({ customType: "shepherd.hook", display: true, content, details }, { triggerTurn: false })`.
`content` is the readable line (also what remote clients and exports show); `details`:

```json
{ "kind": "ran" | "denied" | "sentBack" | "added" | "failed" | "context" | "asked" | "running" | "systemMessage",
  "event": "PreToolUse", "name": "<hook name: statusMessage, else the command's first word>",
  "detail": "Edit|Write · edit .env", "lines": ["…"], "meta": "<command> · exit 2 · 41 ms", "hash": "…", "file": "…" }
```

`running` is shown only while the hook runs, as an extension status (`ctx.ui.setStatus` with key
`shepherd.hook`, cleared with no text) that the thread draws as its working line, never as a
stored row. Only `context` and `sentBack` rows reach the model. Runs with no visible effect (exit 0, no output)
collapse into one `ran` row per event and turn.

`PreToolUse` `ask` uses `ctx.ui.select(title, ["Deny", "Allow once"])` with title
`A hook asks before this runs\n\n<command or tool call>\n\n<reason>\n\n<hook file>`.

## Proposals

The `hook_propose` tool (runtime) takes `{ name, event, matcher?, command, statusMessage?, timeout?, scope: "space" | "mac", sample? }`.
It runs the command once against a sample event (the given one or a built-in one for the event)
in a scratch copy where it can (`PostToolUse`/`PreToolUse` on a file: a temp copy of that file), then
asks with `ctx.ui.select` whose title begins with the marker line `shepherd.hook.proposal` and a
JSON object `{ name, event, matcher, command, statusMessage, timeout, scopes: { space: <path>, mac: <path> }, scope, test: { ok, summary, exit, ms } }`.
Options: `Add to this space`, `Add to this Mac`, `Not now` (`Edit…` opens Settings with the draft).
The app draws that request as the proposal card instead of a question. On add, the runtime writes
the entry to the chosen file, trusts its hash (`by: "proposal"`) and posts an `added` row.
The tool tells the model to ask one question first (with the ask tool) when the request leaves the
event open.

## Composer glyph

The composer shows the hook glyph when at least one hook that would run in the thread's space is
configured and on (This Mac files plus that space's, readers applied). A dot in the lantern color
marks hooks waiting for review. Hover says how many; click opens Settings › Hooks filtered to the
space. No hooks, no glyph.
