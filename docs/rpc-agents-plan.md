# Plan: RPC-backed agents, terminal agents kept as the fallback

Goal: Shepherd becomes pi's client. A new agent runs `pi --mode rpc` on plain pipes; Shepherd
owns the transcript, composer, dialogs, and command list on desktop and iOS. The existing
PTY + Ghostty agent path stays, unchanged, as a per-agent fallback for anything RPC cannot
show (extensions that draw their own TUI, users who prefer it). Shells never change.

Read `docs/desktop-native.md` first: the current native view reads a running TUI through
`Extensions/shepherd-native.ts`. That bridge, the pi dialog patch under
`docs/ios/pi-dialog-bridge/`, and the widgets event bus all become unnecessary for RPC
agents and stay only for terminal agents.

## What pi gives us over RPC (from pi's docs/rpc.md, v0.85)

| Need | RPC | Today (TUI + extension) |
| --- | --- | --- |
| Transcript | `get_messages`, `message_start/update/end`, `tool_execution_*` events | extension projects session entries, polled |
| Dialogs (select/confirm/input/editor) | `extension_ui_request` / `extension_ui_response`, built in | our pi patch (`getPendingDialogs/onDialog/resolveDialog`) |
| Status/text widgets | `setStatus`, `setWidget` (string lines), `notify`, `setTitle` | `shepherd:native-ui:*` event bus |
| ctx / tokens / cost | `get_session_stats` | not available (spec items we skipped) |
| Model, thinking, streaming | `get_state`, `set_model`, `set_thinking_level` | read-only chip, "change in Terminal" |
| Slash commands | `get_commands` + `prompt` with `/name` | Terminal fallback |
| Images | `prompt` with `images: [{data, mimeType}]` | Terminal fallback |
| Steer / follow-up / abort | `prompt` with `streamingBehavior`, `abort` | same, via extension |
| Session new / switch / fork / clone | commands | `/new`, `/resume` typed into the TUI |
| Custom TUI components (`ctx.ui.custom`) | returns `undefined` | works |
| pi's own `/settings`, `/hotkeys` | not available | works |

Framing is strict JSONL on LF. Do not use a generic line reader.

## Model changes (ShepherdCore)

- `Agent.runtime: AgentRuntime` with `case terminal, rpc`. Decoded default `.terminal` so old
  `state.json` files keep their agents as terminal agents. Persisted; an agent never changes
  runtime after launch (you cannot attach a TUI to an RPC process later).
- New-agent sheet and ⌘N read the default from Settings ▸ Agents ▸ Default View. The existing
  Terminal/Native per-agent override stays meaningful only for terminal agents; for RPC agents
  the header switch is hidden (there is no terminal to show).
- `Automation` runs pick the same default. Watch agents work either way; RPC is cheaper (no
  Ghostty surface).

## Session layer (ShepherdSessions)

New `RPCSession` beside `PTYSession`, same ownership rules: created, killed, and restarted by
`SessionServer` on its serial queue, callbacks hop to main FIFO.

- Spawn: `zsh -l -c "exec pi --mode rpc --session-id <id> [--model] [--thinking] -e …"` via
  `posix_spawn` with three pipes. No PTY, no signal-mask dance beyond what `PTYSession` already
  does for children. `SHEPHERD_AGENT_ID` / `SHEPHERD_SOCKET` env stay so status, namer, panes,
  subagents extensions keep working unchanged. `shepherd-theme.ts` and `shepherd-native.ts` are
  not passed to RPC agents.
- Reader: split stdout on LF only, cap a record at 1 MiB (same as NDJSON), decode
  `RPCEvent`; unknown event types are logged and dropped, never fatal.
- Writer: bounded queue of `RPCCommand` lines; `id` correlation with a 10 s timeout the same
  way `nativePending` works today.
- The server keeps one `RPCThreadState` per session: last `get_state`, the message list
  (seeded by `get_messages`, then patched by events), the provisional streaming assistant
  message, tool executions in flight, pending `extension_ui_request`s, widgets, session stats.
  This replaces what `shepherd-native.ts` computes inside pi.
- Restart on relaunch: same as PTY agents, `--session-id` resumes the transcript;
  `get_messages` rebuilds history so the `olderCursor` paging path stays as is.

`SessionServer.nativeThread(agentID:request:)` keeps its signature and result type. For a
terminal agent it still dispatches to the extension bridge; for an RPC agent it answers from
`RPCThreadState` directly. This is the seam that keeps both clients untouched.

## Protocol (ShepherdProtocol)

`NativeThreadRequest` / `NativeThreadSnapshot` stay the wire contract for desktop and iOS.
Additive fields, all optional so old iOS builds keep decoding:

- `NativeThreadSnapshot.stats: {contextTokens, contextWindow, contextPercent, totalTokens, cost}?`
  from `get_session_stats`: fills the header "42k ctx" and the spec's turn footer data.
- `NativeThreadSnapshot.commands: [NativeCommand]?` from `get_commands` (name, description,
  source) so the `/` list is native.
- `NativeThreadSnapshot.runtime: "terminal" | "rpc"`, so clients know whether Terminal
  fallback exists and whether model/thinking are settable.
- `NativeThreadRequest`: `.setModel(id)`, `.setThinking(level)`, `.sendImages(...)` gated by
  `supportedActions` exactly as `abort` is today. Terminal agents report them unsupported.
- Remote capability `native.thread.v2` alongside v1. `RemoteProtocolTests` rows for every arm.

`NativeThreadDialog` maps 1:1 from `extension_ui_request` (`select`/`confirm`/`input`/`editor`
+ `timeout`); `NativeDialogAnswer` maps to `extension_ui_response`. No new dialog kinds.

## App (ShepherdApp)

- `TerminalSessions.createAgentSession` branches on runtime: RPC agents get no Ghostty surface
  and no grid wait; the pane's `sessionID` binds to the `RPCSession` instead. `WorkspaceView`
  mounts `DesktopNativeThreadView` for them unconditionally; the Terminal/Native switch and
  "Show Terminal" links are hidden for RPC agents (`snapshot.runtime == .rpc`).
- `DesktopNativeThreadView`: model chip becomes a menu when `setModel` is supported; `/ commands`
  chip opens a native list from `snapshot.commands` and inserts `/name`; the image-drop path
  that today falls back to Terminal sends `prompt` with images. Header shows ctx from `stats`.
- Cold parking, viewport sizing, replay, and `mountedTabs` rules apply only to terminal panes;
  RPC agents have no surface to park.
- iOS: same view changes off the same snapshot; the "attach" icon appears when
  `supportedActions` contains `sendImages`.
- Extensions: `shepherd-status.ts` already keys on session events, works as is. Verify
  `shepherd-panes.ts` tools run under RPC (they use the socket, not the TUI). pi-subagents'
  inspector uses `ctx.ui.custom`, which returns `undefined` in RPC mode; the sidebar
  projection (`shepherd-subagents.ts`) still works, the inline inspector does not, so the
  inspector tab is offered only for terminal agents.

## Order of work

1. `ShepherdCore`: `AgentRuntime` on `Agent`, default `.terminal`, decoding test with an old
   `state.json`.
2. `ShepherdSessions`: `RPCSession` + `RPCThreadState` + JSONL codec, with a fake `pi` script
   in tests (a node/python stub that speaks the documented protocol) so the session tests
   never depend on an installed pi. Cover: spawn/kill, LF-only framing with U+2028 inside a
   string, `id` correlation and timeout, streaming `message_update` coalescing, dialog
   round-trip, unknown event tolerance, restart-resume via `get_messages`.
3. `SessionServer.nativeThread` branch for RPC agents; existing `LocalNativeThreadTests` pass
   unchanged for terminal agents, a sibling suite runs the same requests against an RPC stub.
4. Protocol additions + capability v2 + round-trip tests; both clients decode old and new.
5. App: create path, workspace mounting, header/composer changes, iOS attach. Screenshots via
   the existing fixtures plus an RPC stub fixture.
6. Settings ▸ Agents ▸ Default View gains the runtime meaning ("Native (RPC)" vs "Terminal");
   the current per-agent override keeps working for terminal agents.
7. Docs: `ARCHITECTURE.md` runtime map, `AGENTS.md` rules (one process per agent, RPC has no
   surface, do not sync between queues), `DESIGN.md` exceptions, `docs/desktop-native.md`.

Steps 1–4 are safe to land without any UI change and are where the risk is. The app steps can
be split desktop / iOS.

## Decisions (confirmed)

- D1 RPC is opt-in for now: Terminal stays the default for new agents; Settings ▸ Agents ▸
  Default View and the New Agent sheet choose the runtime. Flip the default once RPC agents
  have run a nightly.
- D2 No hidden PTY for RPC agents. "Restart as Terminal agent" from the context menu, same pi
  session id, transcript intact. Extension audit (Shepherd's six plus everything in
  `~/.pi/agent`): the only TUI-only extension is lumen-review (`ctx.ui.custom`), which already
  checks `ctx.mode !== "tui"` and reports it; statusline's `setFooter`/`setEditorComponent`/
  `setWorkingIndicator` are no-ops under RPC; pi-subagents, pi-mcp-adapter, the cliproxy
  provider and teach-me use only bridged UI calls. shepherd-theme and shepherd-native are not
  passed to RPC agents.
- D3 RPC agents' widgets come from pi's `setWidget`/`setStatus`/`notify`; the
  `shepherd:native-ui:*` bus stays for terminal agents only.
- D4 The pi dialog patch (`docs/ios/pi-dialog-bridge/`, a source diff against pi v0.85.1 that
  adds `getPendingDialogs/onDialog/resolveDialog` so an outside client can answer another
  extension's dialog) is what makes native answering work for terminal agents. RPC needs none
  of it (`extension_ui_request/response` is built in). Keep the patch until terminal agents'
  native answering is retired, then delete it.
