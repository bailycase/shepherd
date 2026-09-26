# The native thread

Every Shepherd agent is `pi --mode rpc` running on plain pipes, and Shepherd is the only UI pi
has. This document follows one agent from process launch to what appears on screen.
[DESIGN.md](../DESIGN.md) specifies how the thread looks; [native-subagents.md](native-subagents.md)
covers how subagents run.

```text
pi --mode rpc                                           ShepherdSessions
  → RPCSession            JSONL over stdin/stdout, owned in-process
  → RPCThreadState        pi events → NativeThreadSnapshot; requests → RPC commands
  → SessionServer.nativeThread (local, direct)  |  RemoteRequest.nativeThread (TCP)
  → NativeThreadStore     poll, page, queue, echo; derive rows  ShepherdRemote
  → ThreadView · Composer · SubagentInspector                   ShepherdApp/Thread
```

Agents never render in a terminal. There is no Terminal/Native switch and no bridge extension:
the server speaks pi's RPC protocol directly.

## Launch

`TerminalSessionStore` (`TerminalSessions.swift`) spawns an agent's primary pane as an RPC
session (`SessionRuntime.rpc`). Every other pane is a PTY running the shell configured in
Settings ▸ Terminal. `StatusExtension.command` builds the agent command. It always goes through
a zsh login shell, so the user's `PATH` resolves:

```sh
/bin/zsh -l -c "exec pi --mode rpc --session-id '<id>' [--model '<m>' --thinking '<t>'] \
  -e '<status>' [-e '<panes>'] [-e '<review>'] [-e '<subagents>'] [-e '<children>'] [-e '<namer>']"
```

- **`--session-id`** is `Agent.effectivePiSessionID`: the pi session the agent was last in, or
  the agent's own ID for a new agent. `PiSessionFile` writes a minimal session header before
  launch if pi has not written one yet, so pi finds the session instead of warning.
  `--model`/`--thinking` are passed only while that file has no conversation (a fresh session).
- **Extensions** are installed into the support directory from embedded literals and loaded
  with `-e`. Nothing is installed into `~/.pi/agent/`. The status extension is always loaded; the
  rest follow Settings ▸ Pi ▸ Bundled extensions: "Panes and agent tools", "Diff review tool",
  "Subagent display", "Native subagents", and "Name agents automatically" (the namer, and only
  for agents whose name is not final).
- **Environment:**
  - Always: `SHEPHERD_AGENT_ID`, `SHEPHERD_SOCKET`, `SHEPHERD_EXT_STATUS`.
  - With the panes extension: `SHEPHERD_EXT_PANES`.
  - With native subagents: `SHEPHERD_NATIVE_CHILDREN=1`, `SHEPHERD_EXT_CHILDREN`, and the
    `SHEPHERD_CHILD_*` defaults.
  - `SHEPHERD_NEEDS_NAME=1` for an agent whose name is not final.
  - `SHEPHERD_AUTOMATION=1` for automation runs.
  - `SHEPHERD_MODEL` when a model is passed.
  - `RPCSession` strips terminal variables (`TMUX`, `STY`, …) and sets no `TERM`.
- **Online:** pi is not launched with `--offline` (`PI_OFFLINE=1`). In RPC mode pi already
  refreshes its model catalogs in the background, so offline mode buys little of its boot, and
  it would cost the agent for its whole life: no catalog refresh (a model published since the
  last one could not be picked, though Shepherd's picker lists it), no install of a package
  newly added to pi's settings, and a `PI_OFFLINE` that every extension and subagent inherits
  (pi-subagents then stops finding agents and skills in the global npm root). A slow boot is
  covered instead by the thread drawing at once (below).
- **The opening prompt** is the first native `send`. It is not a positional argument, because RPC
  mode ignores positional messages. The app hands it to the host with the new pi
  (`SessionServer.sendOpeningPrompt`), which holds it until the thread serves and sends it in
  the same queue turn, before it answers any request: the first snapshot any client gets shows
  it, pending until pi starts it, and none shows the thread without it. Its send's operation id
  is the agent's id (`OpeningPrompt`), so the client that created the agent (the Mac's New
  Agent, a remote Mac's or iOS's New thread) previews the same pending row while pi starts, and
  the row keeps its identity when the host's lands and when pi starts the turn.

Quitting the app kills every child. On relaunch each agent respawns in its pi session with its
history intact. State files from before RPC agents decode unchanged: `Agent` ignores the
per-agent `runtime` key (and always encodes `"rpc"` so older remote clients never try to attach
a PTY). `LegacyTerminalAgents.forgetPresentationPreferences` clears the old per-agent view
defaults.

The view model starts every restored agent's pi on its first adoption of the workspace, whatever
has mounted, through `AgentStartQueue`. Thirty pi processes booting at once each take several
times longer than one alone, so the agent on screen starts first, alone, and the rest wait until
it serves or exits (or two seconds pass), then start a few at a time (half the cores, 2 to 8),
each holding its slot until its pi serves or exits, or five seconds pass. Selecting an agent
that is still waiting starts it at once, ahead of the rest. A new agent's pi spawns with its
creation and never waits in the queue.

## Status and session reporting

`shepherd-status.ts` connects to the extension socket and reports fire-and-forget NDJSON
messages:

| pi event | Status reported |
| --- | --- |
| `session_start` | `idle`, plus `setAgentSession` with the pi session ID |
| `agent_start` | `working` |
| `agent_settled` | `done` |
| `tool_execution_start` for an ask/question-style tool | `blocked` |
| `tool_execution_end` for that tool | `working` (once no waits remain) |
| `session_shutdown` | `idle` |

The server applies each status even when `AgentStatus.canTransition` disallows the transition,
and logs a warning. `setAgentSession` persists the new `piSessionID`, so `/new` or `/resume`
survives a relaunch. It also clears `nameIsFinal`, because a different session is a different
conversation.

## RPCSession

`RPCSession` owns the child process and its pipes. JSONL commands go in on stdin; responses and
events come out on stdout, one record per LF.

- **Record size:** stdout records may be up to 256 MiB. `get_messages` returns a long session's
  whole history as a single record, far beyond the 1 MiB NDJSON cap that still applies to the
  extension socket and TCP frames. A larger record is logged and skipped.
- **Stdin:** queued up to 8 MiB. A command beyond that is dropped.
- **Requests:** each has a 10 s deadline and fails cleanly on timeout or when the process exits.
- **stderr:** used for diagnostics only, logged line by line. A line is cut at 64 KiB.
- **Shutdown:** `kill()` sends SIGTERM to the process group, then SIGKILL after 2 s.
- **Queueing:** like `PTYSession`, all mutable state is confined to a queue that targets the
  server's serial queue.

## RPCThreadState

`RPCThreadState` is the server-side projection of one agent's thread, confined to the same queue.

- **Bootstrap** runs on spawn or resume. It sends `get_available_thinking_levels` (the levels
  pi offers the current model, in pi's order; asked just before every `get_state`, whose answer
  follows it and commits both, so the levels never move the revision on their own; a pi without
  the command leaves them unsaid), `get_state` (session ID, model, thinking level, streaming), `get_messages` (history), `get_session_stats` (context, tokens, cost; a context of 0, pi's
  estimate before its first reply, is sent as unknown), and
  `get_commands` (the slash-command registry, capped at 128 commands). Until `get_state` and
  `get_messages` have answered, requests fail with `native_starting` ("The agent is starting."): pi
  answers `get_state` first, and a thread served before a long history arrives would show a
  resumed agent as a new, empty one. pi reads stdin only once it has started, so a pi slower
  than the 10 s request deadline answers requests already given up on; when `get_state` times
  out, the bootstrap asks again.
- **Events** update the projection in place. The run pi is streaming is one ordered list of
  live rows (`provisional`), in the order pi produced them:
  - `message_start`, `message_update`, and `message_end` stream the current assistant message
    as a live row.
  - `tool_execution_*` upserts running and finished tool calls, with start times for live
    durations.
  - A user `message_start` is pi reading a user message: it joins the run there, with the id
    history will give it (`user:<ms>`, `#<n>` for a second one stamped in the same millisecond),
    and with where it came from when Shepherd delivered it (`origin`, `operationID`; see The
    queue). This is the only way a user message enters the thread; nothing is matched by text
    or position after the fact.
  - `agent_start` sets `running`; `agent_settled`, not `agent_end`, clears it. Between the two
    pi may retry, compact, or continue, and a prompt without a streaming behavior is refused
    ("Agent is already processing"). `agent_end` re-fetches messages, state, and stats, which
    settles the ended live rows into history.
  - `queue_update` tells the host which text pi queued for a steer (see The queue).
  - Thinking spans are timed as they stream, so history can show "Thought for Ns".
  - What a Stop ends reads as stopped, not failed: pi ends a run stopped mid-tool-call with a
    failed call ("Command aborted") and an error reply ("This operation was aborted"). While the
    user's stop is in effect, the host projects both with status `aborted` (in history too, for
    as long as this pi runs), and a reply pi itself marks `aborted` carries no error text.
    Clients read `aborted` as stopped: the call's line says "stopped" and the turn ends in a
    quiet "Stopped" note, never an error with Retry. After a relaunch, history read from pi
    shows such a run as pi recorded it.
  - `compaction_start` and `compaction_end` run a compaction as a live row and land it in
    history (see Context and compaction). An assistant `message_end` asks for `get_session_stats`
    again, so the context moves once per reply, never per token.
  - `turn_*` events are ignored, and so is anything the lenient `RPCWire` decoder doesn't know.
- **Session switches** are detected whenever `get_state` reports a new session ID. The
  projection resets and gets a new `generation`.
- **Questions:** `extension_ui_request` with `select`, `confirm`, `input`, or `editor` becomes a
  `NativeThreadDialog`.
  - A snapshot carries at most 8. One larger than 48 KiB renders as unavailable
    ("payload-limit").
  - A question with a timeout disappears when pi resolves it on its own.
  - The first answer wins, whether it comes from this Mac or a remote client. A second answer
    gets `dialog_unavailable`.
  - Questions need no pi patch; they are part of pi's RPC protocol.
  - **The record** (QuestionAnswered): once a question ends, the thread keeps it where pi asked,
    as a row of role `"question"` with entry id `q:<dialog id>`, no blocks, stamped when it
    ended, carrying a `NativeQuestionRecord` (kind, the question, the chosen option or typed
    text or Yes/No, when pi asked, and the outcome: `answered`, `dismissed` for a Dismiss, or
    `expired` when the timeout passed, stamped at pi's timeout). It joins the live rows when
    it ends and moves into history under the same id at the next refresh, placed before the
    first message that started once it ended (a tool result counts from its call), so after the
    call that asked and before pi's next reply, where the live thread showed it. A question too
    large to show here is not recorded. Older clients have no role for the row and leave it out
    (it has no blocks); older hosts send none. pi's session holds no UI dialogs, so the host
    keeps the records beside the origins (below, newest 256 per session) and places them again
    after a relaunch; one from before a compaction's kept messages went with what was
    summarized.
- **Widgets:** `setWidget` text (ANSI stripped) becomes a `NativeThreadWidget`: at most 16, 4 KiB
  of text each, 32 KiB in total. Machine payloads, `notify`, `setStatus`, and `setTitle` are
  dropped, because they belong to pi's TUI chrome.
- **Snapshots** are bounded:
  - 240 KiB in total, of which live content (live rows, then dialogs) may use 120 KiB. A page
    each of live assistant messages and tool calls stays; user rows always stay, because they
    open the turns the rest belong to.
  - One 16 KiB text budget per message, shared across its blocks and tool fields, and at most
    128 blocks per message. Clipped content is flagged.
  - A monotonically increasing `revision`, the pi session ID, and a `generation`, so nothing
    from an old session can be acted on. Anything a snapshot shows moves it, the queue and
    where a message came from included, so a queue change is pushed like one of pi's events.
    Each part is hashed once per change (a live row when it changes, the queue when it differs
    from the one last hashed), and each row and the queue are sized once, so a streamed delta
    beside a full queue rehashes and measures only the message it grew (and the snapshot's small
    fixed part).
  - History pages hold 50 entries, walked with `olderCursor`. A stale cursor gets
    `stale_cursor`.
  - A history entry's id names its message, not its place in pi's list
    (`RPCThreadState.historyEntryID`): a tool result is its call (`t:<call id>`), anything else
    `<role>:<ms>` from pi's timestamp, with `#<n>` on a repeat. So a message keeps its id across
    refreshes and compactions, and history read from pi's session file before pi answers lands
    on the same rows. Only a message without a timestamp, which pi never sends, falls back to
    its position (`m:<index>`).
- **Requests** (`NativeThreadRequest`): `snapshot`, `send` (follow-up or steer delivery, optional
  images; see The queue), `abort` (see The queue), `answer`, `setModel`, `setThinking`,
  `subagentCommand` (message, cancel, resume, pause, continue; routed to the children
  extension's control connection, never the parent model), `compact` (pi's `compact`, with what
  to keep; see Context and compaction), `subagentTranscript` (one page of a
  child's session file, read from its last 8 MiB; a message the user sent the child, recorded
  in `user-messages.jsonl` beside the session, carries `origin: .user`), and `queue`
  (`NativeQueueAction`).
  - Every mutating request carries an operation ID and the expected session and generation.
    Replaying an ID returns the recorded result; reusing it with a different payload gets
    `operation_conflict`. A session mismatch gets `stale_session`.
  - An accepted result means the command was dispatched, not that the work finished.
  - A refusal from pi is `dispatch_failed` with pi's own reason. No answer within the deadline
    (10 s, 30 s for a prompt: pi answers a prompt only after its preflight) is
    `outcome_unknown`, never reported as a refusal: pi may still run it.
  - `supportedActions` lists what clients may offer: `send`, `abort`, `answer`, `setModel`,
    `setThinking`, `sendImages`, `subagents`, `queue`, `compact`.
- **Subagents:** the rows the subagent display extension publishes (`setAgentChildren`) ride the
  snapshot as `subagents`.

## The queue

Messages sent while pi works wait on the host (`RPCThreadState+Queue.swift`), not in pi, so
every client (this Mac, a remote Mac, later iOS) sees and edits one queue, and it survives
switching agents. Nothing in it has reached pi except a steering item. The snapshot carries it
as `queue` (`NativeQueue`: items, mode, paused, notice); a snapshot without one comes from an
older host, which sends every message straight to pi.

pi 0.87.1's own queues are text-only lists with no edit, remove, or reorder
(`clear_queue` empties both), and `set_steering_mode` / `set_follow_up_mode` write the user's
pi `settings.json`, so Shepherd never sends them and keeps its own queue instead, handing pi
one prompt at a time.

- **Send** (`send`): while pi is idle (`running` false and no prompt of ours on its way) the
  message goes to pi at once as a prompt, with `streamingBehavior: followUp` so a pi that has
  just started a run of its own queues it rather than refusing it (idle, pi treats it as a
  plain prompt). While pi works, a follow-up is appended to the queue and answered at once; a
  steer is handed to pi (below). The queued item's id is the send's operation id. A send also
  resumes a paused queue. At most 32 items and 64 KiB of text wait (`queue_full`).
- **Delivery:** when pi settles (`agent_settled`) and the queue is not paused, not held, and no
  question is pending, the queue goes as one prompt:
  - **One per turn** (`oneAtATime`): the head.
  - **All at once** (`all`, the default): every item from the head that can go together,
    joined with a blank line (`NativeQueueRules.batchCount`): an item that begins with "/"
    goes alone (pi runs a command or expands a template only at the start of a message), and
    a delivery carries at most 4 images and 64 KiB. So does a message from an older remote
    client (its `hello` lists no `native.queue.v1`): such a client knows nothing of the queue
    and removes its own copy of a send only when a user message with the same text appears,
    so its messages always reach pi alone and as they were sent. pi runs one turn for it: it is one user
    message, and every model call of that turn reads it (checked against real pi 0.87.1).
    pi's own follow-up queue could not do this without writing the user's settings: in its
    default one-at-a-time mode each queued follow-up opens its own model call.
  - The mode is the agent's own choice (`setMode`), else the host's default
    (`SessionServer.setDefaultQueueMode`, for the app's Settings to set).
  - Until pi starts the message, the host shows it as a pending row (`pending:<id>`, status
    `pending`). When pi starts it, it joins the run with `origin: .queue(parts)`: each part is
    one queued message with its own text, send time, and image count, so the thread can show
    them apart even though pi has one message. A refusal puts the items back at the head,
    pauses the queue, and says why (`notice`).
- **Steer:** the item is marked steering (steering items sit above the queue, in the order
  they were steered) and sent as `prompt` with `streamingBehavior: steer`. pi's `queue_update`
  names the text it queued for it (pi expands templates first), and the user message pi later
  starts with that text is the item landing: it leaves the queue and joins the run with
  `origin: .steered`, after the tool calls pi was running. pi runs every call of a batch and
  reads steering only after the whole batch (it has not skipped calls since 0.58.4), so there
  is no "skipped" work to show. A steer to a pi whose run has not started yet (a prompt of
  ours still on its way) waits at the head of the queue instead.
- **Back to the queue** (`unsteer`): `clear_queue`; the item returns to the head of the queue
  if pi still held it, and everything else pi returned is handed back in order. If pi already
  read it, even just before the clear arrived, the request is refused (`queue_item_unavailable`)
  and the message lands where pi read it.
- **Stop** (`abort`): `clear_queue` first, then `abort` (pi's recipe; `abort` alone delivers a
  queued steer into the aborted turn and keeps follow-ups for a later run). Steering items pi
  still held return to the head, anything else pi had queued joins the queue, and the queue
  pauses. A turn that ends in a provider error pauses it too, and says so (`notice`); a
  stopped run does not, although pi ends a run stopped mid-tool-call with an error reply.
- **Settle:** prompts pi accepted but never started as a message (an extension command, an
  input handler that took it) drop their pending rows; so does a prompt pi answered while idle
  (checked with `get_state`). A steer pi queued after its last look at its queue is stranded
  there: the host takes it back with `clear_queue` and sends it as the next turn.
- **Editing:** `edit`, `delete`, `restore` (undo of a delete or `clear`; the host keeps the
  last 64 removed items), `move` (indexes count queued items only), `hold` (an editor is open:
  the queue waits; a hold lapses after two minutes unless renewed), `steer`, `unsteer`,
  `clear`, `setMode`, and `sendNow` (pi idle: these open the next turn, and the rest resumes
  after it). A missing item gets `queue_item_unavailable`.
- **Status:** between queued turns pi settles for a moment. While the queue goes next,
  `SessionServer` holds back the status extension's "done" (no "Agent finished" banner), and
  reports it once the queue does not go after all. It also holds a "done" that arrives before
  pi's own `agent_settled` on stdout (the two travel apart), because the settle says how the
  turn ended: a "done" whose turn's last reply failed (`stopReason: "error"`, and not a stop
  the user asked for) reaches the app with a `TurnFailure` carrying pi's error.
- **Where a message came from** outlives the app: the host records each delivered message's
  origin by entry id in the support directory's `thread-origins/<pi session>.json` (newest 512
  per session; the same file keeps the session's question records) and applies it to history, so after a relaunch a queue delivery still shows its
  parts and a steer is still marked steered. pi's session has no room for it. A part is kept as
  its length, id, send time, and image count; its text is pi's message split where it was
  joined, and a message that no longer splits there gets no origin.
- **The queue itself is not persisted.** Like pi's own queue, it lives with the process: the
  app kills pi on quit (asking first while agents work), and on relaunch every agent resumes
  idle, so a restored queue could only come back paused against a run that no longer exists.

## Context and compaction

What fills the model's context window rides the snapshot as `context` (`NativeThreadContext`,
`RPCThreadState+Context.swift`); a snapshot without one comes from an older host, and clients
draw no context meter.

- **The total is pi's:** `get_session_stats` › `contextUsage` (`tokens`, `window`), asked at the
  bootstrap, after each assistant reply (`message_end`), at `agent_end`, and after a compaction.
  pi reports no window without a model, and its `tokens` are null after a compaction until its
  next reply: then `estimate` stands in (pi's `estimatedTokensAfter` for a compaction this host
  saw, else the host's own sizing) and `before` is the size it replaced.
- **The auto-compact mark** is `window − compaction.reserveTokens`, from pi's settings as pi
  resolves them (`PiConfig.compactionSettings`: the project's `.pi/settings.json` over the agent
  directory's, a `modelOverrides` entry for the model over both, 16,384 by default), read once per
  model and never written. `autoCompact` is `get_state`'s `autoCompactionEnabled`; `keepRecent` is
  `keepRecentTokens` (20,000 by default).
- **The split and the largest items are the host's estimate** (`RPCThreadState.estimate`), taken
  from `get_messages` with each history refresh: four characters a token, as pi estimates. pi
  0.87's structured system prompt rides the message list as `system` messages (sections, a null
  removing one, and the tools added or removed); the host folds them, counts the
  `project_context` section as instructions (naming its `<project_instructions path>` files) and
  the rest, with the tools' definitions, as the system prompt; user and assistant messages, the
  agent's calls, and summaries as messages; and tool results as tool results. Every part is
  scaled to pi's total. `largest` is the three largest tool results, named by the file they read
  or wrote or the command they ran (the same name's results add up, found at the largest), each
  with its thread entry (`t:<call id>`) so a client can find it. System messages never become
  thread rows.
- **A compaction** (`compaction_start` › `compaction_end`): `context.compacting` holds its reason
  and start, and a live row (role `compaction`, `NativeCompaction` phase `running`) sits at the
  tail. When it ends, a success refreshes history, state and stats, and the live row goes with the
  refresh; a stopped one (`aborted`) or a failed one (`errorMessage`) stays as a live row, phase
  `stopped` or `failed`, until the next run. In history pi's `compactionSummary` message carries
  `compaction` (phase `done`, its summary clipped to the text limit, `tokensBefore`, and, for one
  this host saw, its reason and `tokensAfter`), and older clients ignore it.
- **Where it happened:** pi lists its latest compaction first, then what it kept; the host moves
  the summary after the kept messages written before it (`RPCThreadState.chronological`, the
  preview from pi's session file too). After a compaction pi's list starts at what it kept; the
  host keeps the history it had shown before it, above the compaction, for as long as this pi
  runs (`keepingSummarized`). After a relaunch the thread starts at the latest compaction.
- **Compact now** (`compact`, with optional `instructions`, up to 16 KiB): pi's `compact` with
  `customInstructions`. pi aborts a running turn to compact, so the host takes it only while pi is
  idle and no prompt of its own is on its way (`busy` otherwise, or while a compaction runs). The
  answer is the dispatch: pi answers `compact` only once the summary is written, and reports the
  compaction as events meanwhile.
- **Never `set_auto_compaction`:** pi 0.87.1 handles it with
  `SettingsManager.setCompactionEnabled`, which writes `compaction.enabled` into the user's global
  `settings.json` (`~/.pi/agent`, or `PI_CODING_AGENT_DIR`). Shepherd never writes pi's settings, so
  there is no Compact automatically switch (the user's call, 2026-09-25).
- **Clients** derive the ring and its details once per change in ShepherdRemote
  (`NativeContextMeter`, `NativeContextDetails`, `NativeCompactionRow`), so the Mac and the iOS
  client draw the same states from the same snapshot; a host without `native.context.v1` sends no
  `context`, and neither draws a ring.

## Turn changes

The host records each run of an RPC agent in a git repository: the Changes engine snapshots the
working tree when pi starts it (`agent_start`) and when it settles (`agent_settled`), and names
the turn by its first user message (`RPCThreadState.onTurnEvent`). The snapshot's `turnChanges`
carries the agent's recent turns, oldest first, with each turn's first files, counts, state and
whether Undo or Redo applies: the "Edited N files" card ([changes.md](changes.md) › Turns).
`nil` from an older host, and for an agent outside a repository. A turn's state change moves the
revision like any other part of the snapshot.

## Serving

`SessionServer.nativeThread(agentID:request:)` answers the local GUI directly on the server
queue, with no socket, TCP, or authentication involved. An authenticated remote client sends the
same `NativeThreadRequest` inside `RemoteRequest.nativeThread` and gets the same result; only the
transport differs.

- **Size limits:** a request must be under 64 KiB, or 12 MiB when it carries images. Larger
  requests get `native_limit`. Remote requests are also bound by the 1 MiB TCP frame, so
  `RemoteHostClient` rejects larger image sends before sending.
- **Remote capabilities:** remote model, thinking, and image requests need the host's
  `native.thread.v2` capability, `queue` requests its `native.queue.v1`, and `compact` its
  `native.context.v1`, which also says the host sends `context` (`RemoteHostClient` refuses them
  against an older host with `update_required`, `RemoteHostClient.missingCapability`).
- **Models:** `listModels` answers the host's catalog as "provider/id", its default in the same
  form, and `withoutThinking`, the models that take no thinking level (`ModelListing`). A host
  from before that field sends none, and clients then keep the thinking control for every model.
  `thinkingLevels` names the levels of the models whose models.json `thinkingLevelMap` says
  (pi's `getSupportedThinkingLevels`: xhigh and max only where mapped); another reasoning model
  is offered off, minimal, low, medium and high before its session starts.
- **Thinking levels:** the snapshot's `thinkingLevels` is what pi offers the current model;
  clients offer exactly those, or off/low/medium/high from a host that sends none. `setThinking`
  takes any of pi's seven (off, minimal, low, medium, high, xhigh, max), and pi clamps a level
  the model lacks. `createAgent` takes minimal, xhigh and max only from a host that lists
  `thinking.levels.v1`; clients offer an older host Off to High. Clients list it in `hello`
  too: a client that does not is sent state and creation options with each level clamped to
  Off to High, as pi clamps (minimal reads as low, xhigh and max as high), since it cannot
  decode the others. pi reporting only Off (a model without reasoning) hides the thinking chip.
- **Starting and unavailable agents** (`NativeThreadCode`):
  - `native_starting`: the agent exists but its pi is not serving yet. The app adds a new
    agent before it spawns pi and binds the process to the pane, a restored agent's pane keeps
    the previous run's session until its pi respawns (in the launch queue), and pi itself
    takes a moment to answer `get_state` and `get_messages`. Clients poll from the moment an
    agent appears, so this is never an error.
  - **Servable signal:** the moment an agent's pi serves (and its pane is bound to that pi,
    whichever comes last), `SessionServer.onNativeThreadServable` tells the local app, once per
    pi, after the state broadcast of the binding. The app hands that agent's thread store a
    pushed revision (`revisionAvailable()`, below), so a thread on screen pulls at once instead
    of at its next poll. The launch queue ends on the same signal.
    Remote clients keep polling; the remote protocol has no push for this.
  - `native_unavailable`, with the reason: the agent no longer exists, its pane runs no pi, or
    its pi exited (with the exit code, also after the app retired the session).
  - Hosts advertise `native.thread.starting.v1`. `RemoteHostClient` reads `native_unavailable`
    from an older host as starting: such a host said that while pi started, and it retires an
    agent whose pi exits.

## NativeThreadStore

The platform-neutral client lives in ShepherdRemote. There is one store per agent for the
agent's lifetime: `NativeThreadStores` for local agents, and a separate set for remote agents.
Drafts, history pages, and scroll state therefore survive switching and cold parking.

The store is `@MainActor @Observable`, and it derives what the thread draws once per change:
`turns`, `rows` (`NativeThreadRow`: a turn, and for a reply its `NativeTurnPresentation`), each
reply's subagent `placements`, and `lastPromptAt` (the current turn's start). Views read those
stored values, so a keystroke in the composer re-renders only the composer. What the chrome
draws is cached the same way, one property each (`session`, `dialogs`, `widgets`, `commands`,
`model`, `thinking`, `thinkingLevels`, `stats`, `contextMeter`, `contextDetails`,
`supportedActions`, `clipped`, `running`, `showsThinking`, `userTurnCount`, …), assigned only
when it changes. The snapshot is one value that every streamed chunk replaces, so the composer
and the toolbar never read it: a chunk redraws the thread and its live row, a poll that moves
only the stats' context count redraws no chrome (the header has no counters), and one that moves
the context redraws only the ring beside Send, which reads `contextMeter` alone
(`ListPerformanceTests`). The meter and its details are derived again only when the context, the
model, or whether the agent is replying changes.
`compactions` (`NativeCompactionExpansion`) holds which compactions show what the agent kept;
`compact(instructions:)` sends Compact now. A finished tool
call is parsed once (`NativeActivityCall`, cached by entry); a running call is re-read as its
output grows.

- **Polling:** the visible thread's task polls every 200 ms while pi starts, every 500 ms while
  the agent runs, a question is pending, or a subagent is live, and every 2 s otherwise. Each
  poll passes the last revision; older snapshots are ignored.
- **Pushed revisions:** a local thread on screen pulls each revision its pi reaches within a
  frame instead of at its next poll. The store says when its poll loop runs (`isLive`,
  `onLiveChange`), `NativeThreadStores.live` collects those agents, and the view model hands
  them to the server (`TerminalSessionStore.watchThreadRevisions`), which pushes only watched
  agents: each revision `RPCThreadState` reaches (or a pane bound to a pi) queues its agent, and
  one main-queue delivery a display frame (`SessionServer.revisionPushSpacing`) carries every
  agent queued since, so an agent no one watches costs no main-queue work at all.
  `onThreadRevision` then calls the agent's `revisionAvailable()`
  (`NativeThreadStores.existing(for:)`, which never makes a store). The running poll loop pulls
  at once instead of waiting out its pause, pulls once more after a pull in flight however many
  pushes arrive during it, and pulls at most every `pushedPullSpacing` (33 ms), so a streaming
  reply lands at about 30 Hz instead of in half-second jumps. A hidden thread has no loop, is
  not watched, and ignores a push that crosses its suspend. "On screen" means the selected
  thread, as for polling: a minimized or covered window keeps its thread watched, as it keeps it
  polling. The server paces at a frame, not at `pushedPullSpacing`, so a push that lands during
  a pull's spacing only marks the store to pull once more when the spacing ends. The poll
  interval stays as the fallback, and remote threads keep polling: the remote protocol has no
  push.
- **Switching:** a hidden thread stops polling (`suspend`) and keeps everything it shows: it
  stays ready and running, with the same rows and pages of history, so showing it again is a
  flip that rebuilds the thread and its composer once. The first pull after (`run`) merges the
  newest page onto the history already loaded, as any poll does; another session or
  generation, or a page with no overlap, starts over. That pull also marks where the thread
  caught up (`catchUp`, with `threadVersion` and `chromeVersion`, none of them observed), in the
  same update: what it brought back lands without motion (`CatchUpGate`), and what arrives
  after moves as usual. `stop` is the teardown (an error, a pruned agent, a view that went
  away): nothing is ready or running until it polls again.
- **Starting:** `native_starting` sets `starting`, never `loadError`. `awaitingPi` (starting,
  previewing, or no snapshot yet, without an error) is what the composer watches: only after it
  has held for `AppLayout.startingIndicatorDelay` (two seconds, past a normal start of about
  0.8 s after ⌘N and 1 s after a relaunch) does the control row say "Starting…", or for
  `AppLayout.blankStartingIndicatorDelay` (half a second) while the thread has no snapshot to
  draw at all (a remote agent's, or a local one with no readable session file). A normal start
  never shows it. `acceptsSend` offers Send whenever
  the thread is not ready yet and has no error: pi starting, the first pull on its way, or a
  preview. A message sent then waits behind the composer's spinner, still in the field and with
  nothing dispatched, and the field's text goes once the first snapshot lands; the draft stays
  if the thread stops or fails first. A new agent's store gets a known-empty preview
  (`PiSessionPreview.empty`, with the model and thinking level its pi launches with, and its
  opening prompt's pending row) before the agent is selected, so its thread draws complete at
  once, with what the user asked for. A pi still
  starting after `startingLimit` (a minute) becomes a `loadError`, cleared if it answers later.
- **Preview:** while a local thread has nothing from pi, `run(request:preview:)` reads the
  agent's pi session file alongside the first pull (`PiSessionFile.previewLoader`, off the main
  actor) and `preview(_:)` shows it: `previewing`, not `ready`, so nothing acts on it. pi's
  first snapshot replaces it; its entries carry the same ids, so the rows stay. A preview never
  replaces anything pi served. `PiSessionPreview` (ShepherdSessions) reads only the end of the
  file (1 MiB, growing fourfold while the page reaches further back), follows `parentId` from
  the newest entry as pi does from its leaf, stops at a page or at the start of what pi keeps
  (the first entry, or a compaction and the entries it kept), applies context edits, skips
  lines it cannot parse, and pages by a snapshot's rules (`RPCThreadState.fillPage`: at most
  `pageSize` entries within `snapshotLimit`). The model is the newest on the path, else the
  newest in the file's head. The thinking level is the newest on the path, else the newest
  `thinking_level_change` before the page, found by searching the file backwards for that type
  and decoding only the lines that hold it (a level
  set long before the page is still the one pi resumes with). A missing file, one that is not
  pi's, or one in an older format (which pi rewrites when it loads it) is no preview: the thread
  waits for pi. Remote clients get no preview; the remote
  protocol is unchanged.
- **Message order:** `messages` is the paged history (`loadOlder`). From a host with a queue,
  `displayedMessages` is history, then the host's live rows in pi's order (user messages where
  pi read them, the host's pending rows last), then an echo of an idle send until the host's
  next snapshot. The echo, the host's pending row, and pi's message share one turn identity
  (`pending:<operation id>`, through `operationID`), so the tail never re-lays out. From an
  older host it is history, then echoes, then pi's provisional entries, with follow-up echoes
  ("queued") last.
- **The queue:** `queue` is the host's, with this client's own changes applied at once
  (`editQueued`, `deleteQueued` and `clearQueue` return what an undo restores,
  `restoreQueued`, `moveQueued`, `steerQueued`, `unsteer`, `holdQueued`, `setQueueMode`,
  `sendQueuedNow`) until a snapshot requested after the host answered arrives. A send while pi
  works shows there at once, never as a thread row. Queue actions never make the composer busy.
  `queuedImages(_:)` keeps the images this client queued (the host keeps only their names).
  `supportsQueue` gates all of it. The queue's properties are chrome (`chromeVersion`), so a
  queue that changed while the thread was hidden lands without motion when it catches up.
- **Running state:** `settledRunning` keeps `running` true for 400 ms after it drops, so tool
  boundaries don't flicker the live "Thinking…" or the Stop button.
- **Drafts and gating:** `draft` belongs to the store; `send(images:delivery:)` sends with a
  delivery chosen at send time (the Mac composer's ↩, ⌘↩, or its Send menu). `delivery` is kept
  for the iOS client, which still picks one ahead of time.
  `supports(_:)` gates every control on `supportedActions` and on the store being ready and not
  busy.
- **Errors:** transport failures and a pi that is gone surface as `loadError` (the composer's
  Reconnect banner), and action failures as `notice`. Actions are never retried automatically; an unknown outcome is reported, not resent. A stale session triggers a fresh
  snapshot.

## Presentation and views

The pure derivations live in ShepherdRemote:

- **`NativeTurnPresentation`:** a reply's items, built once per turn change, in the order they
  happened: thinking (folded into one block at the start of each stretch of work between
  prose), prose (Markdown parsed once), activity lines, the subagent record lines (the spawn
  calls they stand for leave the activity), notes, errors, steers (`.steer`: a message the user
  steered in, where pi read it), and question records (`.question`, `NativeQuestionRecordRow`:
  the question and the answer's bubble, or "not answered"). It also carries the changes card,
  the countable tool calls, and the copy text; a record's time is the answer's, so it moves
  neither the turn's end nor its copy.
- **Turns** (`nativeTurns`): a user message the host marks `.steered` stays inside the reply
  it steered, so the reply keeps one footer and one changes card. A user turn's `bubbles` are
  one per message, or one per queued part of a delivery from the queue (each with its own send
  time), and `fromQueue` counts those parts ("From the queue · 2").
- **`NativeQueueRules`:** the queue's rules (what one delivery takes, moves, restores, steers),
  shared by the host and the store's instant edits.
- **`NativeActivity`:** tool calls as activity lines. `NativeActivityCall` reads one call (its
  kind, label, path or command, stat, output head, and live tail); `nativeActivityBursts` merges
  consecutive calls of one kind into lines (a failed or running call stands alone);
  `nativeCommandClasses` classifies shell commands (tests, build, commit, push) and the output
  parsers count passed and failed tests; `NativeTurnChanges` is the changes card.
- **`NativeThreadPresentation`:** turns, the Markdown block parser, `DiffStat` from edit
  payloads, the iOS header pill's state (the Mac toolbar has none), subagent state, placement,
  and rollups, clock and duration text, and `NativeScrollFollower` (only a live scroll gesture detaches following; momentum,
  content replacement, composer resizes, and growth are treated as layout, never as intent).
  The iOS client still draws the older turn items and tool rows from here (`nativeTurnItems`,
  `NativeToolRow`).

`Sources/ShepherdApp/Thread/` renders them with ShepherdUI's Thread, Composer, and Agents
components ([DESIGN.md](../DESIGN.md) specifies their look):

- **`ThreadView`:** the scroll view, tail following, turn jumps (⌥⌘↑/↓), notices, and the empty
  thread.
- **`ThreadTurns`:** the user bubble, the agent turn (its parts, then the changes card and the
  footer with copy and retry), and, between tools, the live "Thinking…" (DESIGN.md › Thread ›
  Live text). A turn tracks the pointer over it
  (`MessageHover`): its time and footer show only while it is hovered.
- **`ThreadTools`:** activity lines, their calls, and the sheet for a call's full output or raw
  arguments.
- **`ThreadMarkdown`:** prose and code blocks. The reply's blocks come parsed from the store
  (`nativeMarkdownParse`, ShepherdRemote: tables, task and nested lists, images, `<details>`,
  footnotes; see DESIGN.md › Rich content in prose); inline Markdown is styled once per text
  (`NWProseInline`), and code blocks are colored by tree-sitter off the main actor and cached.
- **`Composer`:**
  - the field, attachments (resized to a 2000 px longest edge; at most 4 images of 2 MiB each)
  - chips: model with its picker on ⇧⌘M, and thinking
  - Up next (`QueueStack`): the host's queue above the card, with the stack's own view state
    (`QueueStackState`: the editor, Undo rows, expansion, a drag) around `NativeQueueRules`
  - the Send menu, and the keys that send while pi works (↩ per Settings, ⌘↩ the other)
  - the slash menu, fed from pi's command registry
  - the question panel and extension widgets
- **`Subagents`** and **`SubagentPresentation`:** the tray above the composer, with the store's
  tray (`NativeSubagentTray`) mapped onto the components' values.
- **`SubagentInspector`:** the inspector, hosted over the side pane's tabs
  (`RightPaneSplit`).

`ThreadHeader`, the toolbar, sits above the thread. A remote agent uses the same views, with
requests sent to its host.

## Testing

- **Unit (`swift test --filter UnitTests`):** the `RPCThreadState` projection fed recorded pi
  events, `NativeThread` wire round-trips against `Tests/Extensions/native-thread-wire.json`, and
  the presentation derivations (activity lines in `ActivityTests`, the store in
  `NativeThreadStoreTests`).
- **Integration (`swift test --filter IntegrationTests`):** a real `SessionServer`
  (`ScratchServer`) driving the scripted stub pi (`StubPi.command`,
  `Tests/ShepherdTestSupport/Resources/stub-pi.py`). The stub's prompt keywords script
  questions, hangs, crashes, oversized records, widgets, session switches, long histories, a
  context worth sizing ("context", "fill-context"), compactions ("auto-compact",
  "compact-abort", and `compact` itself, held with "hold" in its instructions; `ContextTests`
  drive them), and a pi-like turn whose `ask_user` call asks a select ("question", and
  "question-timeout" with a 150 ms timeout; `QuestionRecordTests`).
  For example, `LargeHistoryTests` loads a 6 MiB history. A "tools:N" prompt runs a pi-like
  agent loop with pi 0.87.1's queues (steering read after each tool batch, follow-ups when the
  run would stop, `queue_update`, `clear_queue`, abort keeping follow-ups, and a stranded steer
  with "hold-settle"); `QueueTests` drive the host's queue against it. Its startup options
  (`STUB_PI_STARTUP_DELAY`, `_GATE`, `_EXIT`, or `stub-pi-startup.json` in its cwd for a pi the
  app launches) hold or fail pi's boot, as `ThreadStartupTests` and `AgentStartupTests` do.
- **Previews:** `ShepherdPreviewTests` render thread states offscreen in light and dark into
  `$SHEPHERD_PREVIEW_DIR`.
- **Live model:** the opt-in run is gated on `SHEPHERD_LIVE_MODEL`.

None of these touch the user's pi configuration, sessions, or a running Shepherd.
