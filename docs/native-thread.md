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
  → NativeThreadStore     poll, page, echo, settle; derive rows ShepherdRemote
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
- **The opening prompt** is the first native `send`, delivered once pi's session is ready (the
  server's servable signal, below, ends the wait). It is not a positional argument, because RPC
  mode ignores positional messages.

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

- **Bootstrap** runs on spawn or resume. It sends `get_state` (session ID, model, thinking
  level, streaming), `get_messages` (history), `get_session_stats` (context, tokens, cost), and
  `get_commands` (the slash-command registry, capped at 128 commands). Until `get_state` and
  `get_messages` have answered, requests fail with `native_starting` ("pi is starting."): pi
  answers `get_state` first, and a thread served before a long history arrives would show a
  resumed agent as a new, empty one. pi reads stdin only once it has started, so a pi slower
  than the 10 s request deadline answers requests already given up on; when `get_state` times
  out, the bootstrap asks again.
- **Events** update the projection in place:
  - `message_start`, `message_update`, and `message_end` stream the current assistant message
    as a provisional entry.
  - `tool_execution_*` upserts running and finished tool calls, with start times for live
    durations.
  - `agent_start` and `agent_end` drive `running`. `agent_end` also re-fetches messages, state,
    and stats, which settles the provisional entries into history.
  - Thinking spans are timed as they stream, so history can show "Thought for Ns".
  - `turn_*` and `queue_update` events are ignored, and so is anything the lenient `RPCWire`
    decoder doesn't know (compaction included).
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
- **Widgets:** `setWidget` text (ANSI stripped) becomes a `NativeThreadWidget`: at most 16, 4 KiB
  of text each, 32 KiB in total. Machine payloads, `notify`, `setStatus`, and `setTitle` are
  dropped, because they belong to pi's TUI chrome.
- **Snapshots** are bounded:
  - 240 KiB in total, of which live content (provisional entries, then dialogs) may use
    120 KiB.
  - One 16 KiB text budget per message, shared across its blocks and tool fields, and at most
    128 blocks per message. Clipped content is flagged.
  - A monotonically increasing `revision`, the pi session ID, and a `generation`, so nothing
    from an old session can be acted on.
  - History pages hold 50 entries, walked with `olderCursor`. A stale cursor gets
    `stale_cursor`.
  - A history entry's id names its message, not its place in pi's list
    (`RPCThreadState.historyEntryID`): a tool result is its call (`t:<call id>`), anything else
    `<role>:<ms>` from pi's timestamp, with `#<n>` on a repeat. So a message keeps its id across
    refreshes and compactions, and history read from pi's session file before pi answers lands
    on the same rows. Only a message without a timestamp, which pi never sends, falls back to
    its position (`m:<index>`).
- **Requests** (`NativeThreadRequest`): `snapshot`, `send` (follow-up or steer delivery, optional
  images), `abort`, `answer`, `setModel`, `setThinking`, `subagentCommand` (message, cancel,
  resume, pause, continue; routed to the children extension's control connection, never the
  parent model), and `subagentTranscript` (one page of a child's session file, read from its
  last 8 MiB).
  - Every mutating request carries an operation ID and the expected session and generation.
    Replaying an ID returns the recorded result; reusing it with a different payload gets
    `operation_conflict`. A session mismatch gets `stale_session`.
  - An accepted result means the command was dispatched, not that the work finished.
  - `supportedActions` lists what clients may offer: `send`, `abort`, `answer`, `setModel`,
    `setThinking`, `sendImages`, `subagents`.
- **Subagents:** the rows the subagent display extension publishes (`setAgentChildren`) ride the
  snapshot as `subagents`.

## Serving

`SessionServer.nativeThread(agentID:request:)` answers the local GUI directly on the server
queue, with no socket, TCP, or authentication involved. An authenticated remote client sends the
same `NativeThreadRequest` inside `RemoteRequest.nativeThread` and gets the same result; only the
transport differs.

- **Size limits:** a request must be under 64 KiB, or 12 MiB when it carries images. Larger
  requests get `native_limit`. Remote requests are also bound by the 1 MiB TCP frame, so
  `RemoteHostClient` rejects larger image sends before sending.
- **Remote capabilities:** remote model, thinking, and image requests need the host's
  `native.thread.v2` capability.
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
    of at its next poll. The opening prompt's wait and the launch queue end on the same signal.
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
reply's subagent `placements`, and `lastPromptAt` (the running pill's start). Views read those
stored values, so a keystroke in the composer re-renders only the composer. What the chrome
draws is cached the same way, one property each (`session`, `dialogs`, `widgets`, `commands`,
`model`, `thinking`, `stats`, `supportedActions`, `clipped`, `running`, `workingLabel`,
`userTurnCount`, …), assigned only when it changes. The snapshot is one value that every
streamed chunk replaces, so the composer and the toolbar never read it: a chunk
redraws the thread and its live row, and a poll that moves only the context count redraws only
the toolbar's counters (`ListPerformanceTests`). A finished tool
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
  not watched, and ignores a push that crosses its suspend. The poll interval stays as the
  fallback, and remote threads keep polling: the remote protocol has no push.
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
  0.8 s after ⌘N and 1 s after a relaunch) does the control row say "Starting pi…", or for
  `AppLayout.blankStartingIndicatorDelay` (half a second) while the thread has no snapshot to
  draw at all (a remote agent's, or a local one with no readable session file). A normal start
  never shows it. `acceptsSend` offers Send whenever
  the thread is not ready yet and has no error: pi starting, the first pull on its way, or a
  preview. A message sent then waits behind the composer's spinner, still in the field and with
  nothing dispatched, and the field's text goes once the first snapshot lands; the draft stays
  if the thread stops or fails first. A new agent's store gets a known-empty preview
  (`PiSessionPreview.empty`, with the model and thinking level its pi launches with) before the
  agent is selected, so its thread draws complete at once. A pi still
  starting after `startingLimit` (a minute) becomes a `loadError`, cleared if it answers later.
- **Preview:** while a local thread has nothing from pi, `run(request:preview:)` reads the
  agent's pi session file alongside the first pull (`PiSessionFile.previewLoader`, off the main
  actor) and `preview(_:)` shows it: `previewing`, not `ready`, so nothing acts on it. pi's
  first snapshot replaces it; its entries carry the same ids, so the rows stay. A preview never
  replaces anything pi served. `PiSessionPreview` (ShepherdSessions) reads only the end of the
  file (1 MiB, growing fourfold while the page reaches further back), follows `parentId` from
  the newest entry as pi does from its leaf, stops at a page or at the start of what pi keeps
  (the first entry, or a compaction and the entries it kept), applies context edits, skips
  lines it cannot parse, and pages with the same budget as a snapshot (`fillPage`). The model
  is the newest on the path, else the newest in the file's head. The thinking level is the
  newest on the path, else the newest `thinking_level_change` before the page, found by
  searching the file backwards for that type and decoding only the lines that hold it (a level
  set long before the page is still the one pi resumes with). A missing file, one that is not
  pi's, or one in an older format (which pi rewrites when it loads it) is no preview: the thread
  waits for pi. Remote clients get no preview; the remote
  protocol is unchanged.
- **Message order:** `messages` is the paged history (`loadOlder`). `displayedMessages` is
  history, then optimistic echoes of accepted sends, then pi's provisional entries. This order
  never flips when pi persists a message, so the tail never re-lays out.
- **Running state:** `settledRunning` keeps `running` true for 400 ms after it drops, so tool
  boundaries don't flicker the pill, the working row, or the Stop button.
- **Drafts and gating:** `draft` and `delivery` (follow-up or steer) belong to the store.
  `supports(_:)` gates every control on `supportedActions` and on the store being ready and not
  busy.
- **Errors:** transport failures and a pi that is gone surface as `loadError` (the toolbar's
  Error pill and the composer's Reconnect banner), and action failures as `notice`. Actions are never retried
  automatically; an unknown outcome is reported, not resent. A stale session triggers a fresh
  snapshot.

## Presentation and views

The pure derivations live in ShepherdRemote:

- **`NativeTurnPresentation`:** a reply's items, built once per turn change, in the order they
  happened: thinking (folded into one block at the start of each stretch of work between
  prose), prose (Markdown parsed once), activity lines, the positions of subagent cards (a spawn
  call with a card leaves the activity), notes, and errors. It also carries the changes card,
  the countable tool calls, and the copy text.
- **`NativeActivity`:** tool calls as activity lines. `NativeActivityCall` reads one call (its
  kind, label, path or command, stat, output head, and live tail); `nativeActivityBursts` merges
  consecutive calls of one kind into lines (a failed or running call stands alone);
  `nativeCommandClasses` classifies shell commands (tests, build, commit, push) and the output
  parsers count passed and failed tests; `NativeTurnChanges` is the changes card.
- **`NativeThreadPresentation`:** turns, the Markdown block parser, `DiffStat` from edit
  payloads, the status pill state, subagent state, placement, and rollups, clock and duration
  text, and `NativeScrollFollower` (only a live scroll gesture detaches following; momentum,
  content replacement, composer resizes, and growth are treated as layout, never as intent).
  The iOS client still draws the older turn items and tool rows from here (`nativeTurnItems`,
  `NativeToolRow`).

`Sources/ShepherdApp/Thread/` renders them with ShepherdUI's Thread, Composer, and Agents
components ([DESIGN.md](../DESIGN.md) specifies their look):

- **`ThreadView`:** the scroll view, tail following, turn jumps (⌥⌘↑/↓), notices, and the empty
  thread.
- **`ThreadTurns`:** the user bubble, the agent turn (its parts, then the changes card and the
  footer with copy and retry), and the working row. A turn tracks the pointer over it
  (`MessageHover`): its time and footer show only while it is hovered.
- **`ThreadTools`:** activity lines, their calls, and the sheet for a call's full output or raw
  arguments.
- **`ThreadMarkdown`:** prose (inline Markdown styled once per text) and code blocks, colored by
  tree-sitter off the main actor and cached.
- **`Composer`:**
  - the field, attachments (resized to a 2000 px longest edge; at most 4 images of 2 MiB each)
  - chips: model with its picker on ⇧⌘M, thinking, and delivery (Follow-up / Steer, shown only
    while a turn runs with a draft)
  - the slash menu, fed from pi's command registry
  - the question panel and extension widgets
- **`Subagents`** and **`SubagentPresentation`:** cards, the runs strip, and the ledger, with
  child runs mapped onto the components' values.
- **`SubagentInspector`:** the inspector, hosted with the review in the right pane
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
  questions, hangs, crashes, oversized records, widgets, session switches, and long histories.
  For example, `LargeHistoryTests` loads a 6 MiB history. Its startup options
  (`STUB_PI_STARTUP_DELAY`, `_GATE`, `_EXIT`, or `stub-pi-startup.json` in its cwd for a pi the
  app launches) hold or fail pi's boot, as `ThreadStartupTests` and `AgentStartupTests` do.
- **Previews:** `ShepherdPreviewTests` render thread states offscreen in light and dark into
  `$SHEPHERD_PREVIEW_DIR`.
- **Live model:** the opt-in run is gated on `SHEPHERD_LIVE_MODEL`.

None of these touch the user's pi configuration, sessions, or a running Shepherd.
