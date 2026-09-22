# The native thread

Every Shepherd agent is `pi --mode rpc` on plain pipes, and Shepherd is its only UI. This
document follows one agent from process launch to pixels. Visuals and interaction are specified
in [DESIGN.md](../DESIGN.md); subagent execution in [native-subagents.md](native-subagents.md).

```text
pi --mode rpc                                   ShepherdSessions
  → RPCSession            stdin/stdout JSONL pipes, owned in-process
  → RPCThreadState        pi events → NativeThreadSnapshot; requests → RPC commands
  → SessionServer.nativeThread (local, direct)   |   RemoteRequest.nativeThread (TCP)
  → NativeThreadStore     poll, page, echo, settle            ShepherdRemote
  → ThreadView · Composer · SubagentInspector                ShepherdApp
```

There is no terminal rendering of an agent anywhere, no Terminal/Native switch, and no
`shepherd-native` bridge extension: the server speaks pi's RPC protocol directly.

## Launch

`TerminalSessionStore` spawns an agent's primary pane as an RPC session (`SessionRuntime.rpc`);
every other pane is a login shell on a PTY. The command (`StatusExtension.command`) runs through
the user's login shell so `PATH` resolves:

```sh
zsh -l -c "exec pi --mode rpc --session-id <id> [--model … --thinking …] -e shepherd-status.ts -e …"
```

- `--session-id` is stable per agent. `PiSessionFile` seeds a minimal session header if pi has
  not written one yet, so relaunch resumes the same conversation and palette search can read it.
  `--model`/`--thinking` are passed only for a fresh session.
- Extensions ride `-e` flags (status always; panes, review, subagents, native children, and the
  namer per Settings ▸ Pi). Nothing is installed into `~/.pi/agent/`.
- `SHEPHERD_AGENT_ID` and `SHEPHERD_SOCKET` connect the extensions to the app's socket.
- The opening prompt is the first native `send`, not a positional argument (RPC mode ignores
  positional messages).

On app quit every child dies with the app; on relaunch each agent respawns in its pi session.
Agents persisted by the terminal era (`"runtime": "terminal"`) decode unchanged — `Agent`
ignores the key — and relaunch over RPC with their history intact.
`LegacyTerminalAgents.forgetPresentationPreferences` clears the old per-agent view defaults.

## RPCSession

Owns the child process and its pipes: JSONL commands in on stdin, responses and events out on
stdout, one record per LF with the NDJSON 1 MiB cap. Requests carry deadlines and fail cleanly
when the process exits. stderr is diagnostics only (logged line by line, runaway lines cut).
`kill()` sends SIGTERM, then SIGKILL after a grace period. Like `PTYSession`, all mutable state
is confined to a queue that targets the server's serial queue.

## RPCThreadState

The server-side projection of one agent's thread, confined to the same queue.

- **Bootstrap** on spawn or resume: `get_state` (pi session ID, model, thinking level,
  streaming), `get_messages` (history), `get_session_stats` (context usage, tokens, cost), and
  `get_commands` (the slash-command registry, capped and byte-limited).
- **Events** update the projection in place: `agent_start`/`agent_end`/`agent_settled` drive
  `running`; `message_start`/`message_update`/`message_end` stream the current assistant message
  as a *provisional* entry; `tool_execution_*` upsert running and finished tool calls (with the
  start time for live durations); `extension_ui_request` carries questions and widgets. Thinking
  spans are timed as they stream so history keeps "Thought for Ns".
- **Questions**: `select`, `confirm`, `input`, and `editor` requests become
  `NativeThreadDialog`s (at most 8, 48 KiB; oversized ones render as unavailable). A request with
  a timeout disappears when pi resolves it on its own.
- **Widgets**: `setWidget` text (ANSI stripped) becomes a `NativeThreadWidget` (16 items, 4 KiB
  each, 32 KiB total). Machine payloads, `setStatus` footer text, and `notify` toasts are dropped:
  they belong to pi's TUI chrome, not the conversation.
- **Snapshots** are bounded (240 KiB, 16 KiB per text field; clipped output is flagged) and
  carry a monotonically increasing `revision`, the pi session ID, and a `generation` that
  changes whenever pi switches sessions, so nothing from an old session can be acted on.
  History pages 50 entries at a time.
- **Requests** (`NativeThreadRequest`): `snapshot`, `send` (follow-up or steer delivery, optional
  images), `abort`, `answer`, `setModel`, `setThinking`, `subagentCommand` (message / cancel / resume /
  pause / continue, routed to the children extension's control connection, never the parent
  model), and `subagentTranscript` (one page of a child's session file). Every mutating request
  carries an operation ID; replays return the recorded result instead of acting twice. An
  accepted result means pi accepted the command, not that the work finished. The snapshot's
  `supportedActions` tells clients what they may offer.
- **Subagents**: the rows the children extension publishes (`setAgentChildren`) ride the
  snapshot as `subagents`.

## Serving

`SessionServer.nativeThread(agentID:request:)` answers the local GUI directly on the server
queue — no socket, no TCP, no authentication. Authenticated remote clients send the same
`NativeThreadRequest` inside `RemoteRequest.nativeThread` and get the same result; only the
transport differs. Requests are size-checked with the TCP envelope budget (64 KiB, 12 MiB for
image sends). A missing or dead pi process answers `native_unavailable`.

## NativeThreadStore

The platform-neutral client (ShepherdRemote), one per agent for the agent's lifetime
(`NativeThreadStores` for local agents, `remoteThreadStores` for remote ones), so drafts,
history pages, and scroll state survive switching and cold parking.

- The visible view's task polls: every 500 ms while the agent runs, a question is pending, or a
  subagent is live; every 2 s otherwise. Polls pass the last revision and ignore older
  snapshots.
- `messages` are paged history (`loadOlder`); `displayedMessages` is history, then optimistic
  echoes of accepted sends (`pending`), then pi's provisional entries — in an order that never
  flips when pi persists a message, so the tail never re-lays out.
- `settledRunning` holds `running` true for 400 ms after it drops, so tool boundaries never
  flicker the pill, the working row, or the Stop button.
- `draft` and `delivery` (follow-up or steer) belong to the store; `supports(_:)` gates every
  control on the snapshot's `supportedActions`.
- Transport failures surface as `loadError` (the header's Error pill and the composer's
  Reconnect banner); a stale response is ignored and never retried automatically.

## Presentation and views

`NativeThreadPresentation` (ShepherdRemote) holds the pure derivations: turns and turn items,
tool-row previews, results and durations, DiffStat from edit payloads, the status pill state,
subagent card/strip/ledger models, and `NativeScrollFollower` (detach only on a live scroll
gesture; momentum, content replacement, composer resizes, and growth are layout, never intent).
They are unit-tested in `NativePresentationTests` and shared with iOS.

`ShepherdApp/Thread/` renders them: `ThreadView` (the scroll view, following, turn jumping),
`ThreadTurns` (user bubble, agent turn, thinking, footer, working row), `ThreadTools` (tool
groups and rows), `ThreadMarkdown` (prose and code blocks), `Composer` (field, chips, slash
menu, model picker, question panel, widgets), `Subagents` (cards, runs strip, ledger), and
`SubagentInspector` in the right pane. `ThreadHeader` sits above. A remote agent uses the same
views with requests sent to its host.

## Testing

- `Tests/ShepherdSessionsTests/RPCSessionTests.swift` and `RPCAgentThreadTests.swift` cover the
  pipes and the projection.
- `NativePresentationTests` cover the derivations; `NativeScrollTests` open real windows to check
  following (opens at the bottom with no trailing space, growth keeps the tail pinned until a
  trackpad gesture, sending re-attaches).
- **Real session render** (opt-in):
  `SHEPHERD_REAL_SESSION=<session.jsonl> SHEPHERD_NATIVE_SCREENSHOT_DIR=/tmp/x swift test --filter realSessionRenders`
  projects the last page of a real pi session and captures `real-session.png` at 1500pt — for
  problems fixtures never produce (provider errors, pi system entries, long output).
- **Live end to end** (opt-in):
  `SHEPHERD_E2E=1 SHEPHERD_NATIVE_SCREENSHOT_DIR=/tmp/e2e swift test --filter LiveEndToEndTests`
  builds the real view model and `RootView` over a real `SessionServer`, starts an RPC agent with
  the bundled children extension against the scripted local provider
  `Tests/Extensions/e2e-provider.mjs` (scratch `PI_CODING_AGENT_DIR` and `SHEPHERD_SUPPORT_DIR`,
  no network), finds controls by visible text with Vision OCR, and clicks them with real mouse
  events — so hidden or clipped buttons fail the run. It spawns three children, inspects and
  pauses the running worker, answers the reviewer's question, waits for the ledger, opens a
  finished child, and sends a follow-up, capturing `e2e-1-live-cards` through `e2e-6-followup`.

Neither opt-in test touches the user's pi configuration, sessions, or a running Shepherd.
