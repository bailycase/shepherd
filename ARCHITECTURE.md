# Architecture

Shepherd is a native macOS app with one in-process session server. The app owns the workspace, every agent's `pi --mode rpc` process, the shells' PTYs, persistence, the extension socket, and the views, and can optionally serve the fleet to remote clients over an authenticated TCP listener. There is no daemon: quitting Shepherd ends every child process.

`DESIGN.md` governs visuals and interaction. This document governs code ownership, dependency direction, and mutation paths.

## Dependency direction

```text
ShepherdCore ───────┐
                    ├── ShepherdRemote ── ShepherdSessions ── ShepherdApp
ShepherdProtocol ───┘                                         ├── ShepherdDesign ── ShepherdCore
                                                              ├── TerminalSurfaceKit
                                                              └── SwiftUI/AppKit

TerminalSurfaceKit ── GhosttyTerminal
ShepherdSessions ─── SwiftTerm
shepherd-cli ─────── ShepherdCore, ShepherdProtocol
```

- `ShepherdCore`: Codable workspace models, typed IDs, `PaneNode`, status transitions, and structural validation. No dependencies.
- `ShepherdProtocol`: extension messages and replies, the remote request/reply protocol (version, capabilities, token path), the native thread contract (`NativeThreadRequest`/`NativeThreadResult`/`NativeThreadSnapshot`), pi's RPC wire types, NDJSON framing, and support-directory paths. Depends on Core where IDs or models cross the wire.
- `ShepherdRemote`: the TCP remote client, plus the platform-neutral thread client (`NativeThreadStore`) and its pure presentation derivations (`NativeThreadPresentation`), shared by local, remote, and iOS views.
- `ShepherdDesign`: the design system — theme model and Basalt, `ThemeStore`, `Tokens`, `Fonts`, `Metrics`/`Radius`, and the shared SwiftUI components. SwiftUI only: no AppKit views, no app state.
- `ShepherdSessions`: the authoritative workspace store, agent RPC processes and their thread projection, shell PTY processes, terminal screen snapshots, persistence, the extension socket, and the optional remote TCP listener (token handshake, remote attachments, per-viewer minimum-grid PTY sizing, remote mutation handlers).
- `TerminalSurfaceKit`: the libghostty adapter used for shell panes. It does not know about Shepherd workspaces or agents.
- `ShepherdApp`: SwiftUI state, selection, the thread and pane presentation, settings, appearance, and the bridge between layouts and sessions.
- `shepherd-cli`: a small offline tool (`--import herdr`) that writes `state.json` while the app is not running.

Dependencies point inward. Core and Protocol must not import Sessions or App. Sessions must not import App, Design, or TerminalSurfaceKit. Design must not import App or Sessions.

## State ownership

`SessionServer` is the source of truth for persisted `ShepherdState` and every live session. Its serial queue owns all server state. Each session — a `PTYSession` for a shell, an `RPCSession` plus its `RPCThreadState` for an agent — has its own queue targeting that server queue, which preserves ordering without locks.

`ShepherdViewModel` owns only app presentation state: current selection, focused pane, collapsed spaces, the right pane (subagent inspector or review), sheets, settings, and appearance. It receives authoritative snapshots from `SessionServer`. Its persistence task tail keeps user mutations ordered; a rejected mutation reconciles the view model and `TerminalSessionStore` from `server.state`.

`TerminalSessionStore` owns the pane-to-session lifecycle. It creates or adopts sessions (RPC for an agent's primary pane, a login shell otherwise), attaches shell surfaces, handles early exits and rebuild races, and explicitly retires dead sessions after the final snapshot is no longer needed. An agent's thread pane has no surface; `NativeThreadStores` keeps one `NativeThreadStore` per agent for the agent's lifetime so drafts, history pages, and scroll state survive switching and cold parking.

`ThemeStore.shared` (ShepherdDesign) holds the theme, text scale, and density that views read; `ThemeManager` (app) holds the System/Light/Dark choice and pushes the resolved variant to Ghostty surfaces and the pi theme file.

## Workspace mutation paths

Use a named `SessionServer` mutation rather than editing `server.state` from the app.

- Atomic domain actions such as creating a space and its first layout use one server mutation (`addSpace(_:withTab:)`).
- Agent rename and deletion are server-authoritative operations.
- Automations are persisted `ShepherdCore` models mutated through the server. Agent-side
  automation management arrives as `AutomationRequest` over the extension socket and routes
  through `onAutomationRequest`, mirroring the pane-request path. Automation agents live in a
  reserved hidden space; their runs are reset at startup like every other session.
- A layout has two kinds of writes:
  - `updateLayoutStructure(tabID:layout:)` changes split/leaf structure while preserving existing pane `sessionID` bindings.
  - `updatePaneSession(tabID:paneID:sessionID:)` changes one runtime binding without replacing the tree.
- State is validated before persistence. `StateStore` writes a candidate atomically before replacing in-memory state or publishing callbacks.
- Invalid or corrupt startup state is quarantined. If quarantine fails, further writes are blocked rather than overwriting evidence.

New persistent fields belong in `ShepherdCore`. Add validation only for invariants the type system and constructors do not already enforce. Include decoding coverage when changing stored JSON; old unknown keys are intentionally ignored. The terminal era's per-agent `runtime` key is one of them: `Agent` ignores it on decode (still encoding `"rpc"` for older remote clients), so those agents relaunch over RPC in their existing pi session.

## Agent thread flow

```text
pi --mode rpc (login shell, --session-id, -e extensions)
  → RPCSession (stdin/stdout JSONL pipes, bounded)
  → RPCThreadState (events → NativeThreadSnapshot; requests → RPC commands)
  → SessionServer.nativeThread (local, direct)  |  RemoteRequest.nativeThread (TCP)
  → NativeThreadStore (poll, page, echo, settle)
  → ThreadView / Composer / SubagentInspector
```

`RPCSession` owns the child and its pipes; `RPCThreadState` projects pi's event stream into a bounded, revisioned `NativeThreadSnapshot` and serves requests (send, answer, abort, model/thinking, subagent commands and transcripts) with session/generation checks so a stale action can never land in a new pi session. The local GUI and remote clients use the same request path; only the transport differs. See [docs/native-thread.md](docs/native-thread.md).

## PTY and terminal output flow (shells)

```text
child process
  → PTY master read source
  → PTYSession (bounded reads per event)
  → SessionScreen.feed (authoritative attach snapshot)
  → SessionServer per-session output queue
  → one main-queue delivery in flight
  → TerminalSessionStore / terminal surface
```

`PTYSession` owns the process group and all master-FD sources. Input uses an ordered nonblocking buffer. Output is lossless and bounded: pending plus in-flight bytes are counted, the read source is suspended at the high-water mark, and resumed below the low-water mark. A suspended dispatch source must be resumed before cancellation.

`SessionScreen` is the only replay model; its snapshot is a self-contained ANSI reconstruction of the emulated screen (styled scrollback, alt screen, cursor, modes), not raw byte replay. Attach snapshots, attachment registration, and an output-sequence watermark are captured in one server-queue turn — for local and remote viewers alike. The app discards buffered callbacks represented by that watermark and feeds only later output, preventing replay duplication or loss during surface replacement. A dead session remains attachable until its consumer calls `retireSession(sessionID:)`.

Exit delivery waits for buffered output. Shutdown cancels queued deliveries, balances suspended sources, terminates process groups with TERM/KILL escalation, and reaps children.

`SessionServer.swift` and `TerminalSessions.swift` remain relatively large because each is a single queue/lifecycle owner. Split them only if the ownership and ordering rules remain visible in one place; do not divide them into generic services.

## Extension socket

The Unix socket is same-user, filesystem-confined IPC, not an authentication boundary. The support directory is mode `0700` and the socket is `0600`, but another process running as the same macOS user and able to reach the socket can impersonate an agent. It is not remote access. Remote access is the separate TCP listener: shared-token authenticated (`remote-token`, mode 0600), no TLS, bound on all interfaces — the user's VPN/network is the transport boundary. Remote protocol changes update `RemoteMessage.swift`, capabilities, server handling, both clients, and `RemoteProtocolTests`.

Frames are newline-delimited JSON with explicit payload limits. Each client has ordered, bounded nonblocking replies. Framing and payload-limit violations disconnect the client; invalid decoded messages are logged and ignored. Oversized replies become correlated errors.

To add a protocol message:

1. Update `ExtensionMessage` or the pane request/reply contracts, including every Codable discriminator arm.
2. Update `SessionServer.handleLine` and the relevant app handler.
3. Add protocol round-trip and server behavior tests.
4. Update the canonical TypeScript extension and its embedded Swift literal together. They must remain byte-identical.

## Terminal engine boundary

`Sources/ShepherdApp/TerminalHost.swift` is the only app file allowed to import `TerminalSurfaceKit`. Other app code uses `AppTerminalModel` and `AppTerminalView`. `TerminalSurfaceKit` is the only package that imports GhosttyTerminal.

This boundary keeps engine API changes local. App-owned keyboard chords must also be unbound in `TerminalSurfaceModel.appOwnedChords`, or a focused terminal will consume them.

## App file map

- `ShepherdViewModel.swift`: observable state, dependencies, initialization, callbacks, teardown.
- `ShepherdViewModel+Navigation.swift`: hierarchy lookups, sidebar ordering, selection, focus.
- `ShepherdViewModel+Creation.swift`: ordered persistence, spaces, quick creation, new agents, settings reset.
- `ShepherdViewModel+Workspace.swift`: panes, session exits, rename, deletion, cold parking.
- `ShepherdViewModel+RightPane.swift`, `+Review.swift`, `+ChildInspector.swift`, `ChildRuns.swift`: the right pane (review or subagent inspector), thread keyboard commands, review sessions, subagent rows and forks.
- `ShepherdViewModel+Palette.swift`, `CommandPalette.swift`, `CommandPaletteView.swift`, `PaletteContentSearch.swift`: command palette model, view, and transcript search.
- `ShepherdViewModel+Automations.swift`: automation lifecycle, hidden-space agents.
- `ShepherdViewModel+Remote*.swift`: remote agent actions, inspection queries, remote worktrees.
- `RootView.swift`, `SidebarView.swift`, `ThreadHeader.swift`, `WorkspaceView.swift`, `WorkspaceSelection.swift`: the window shell, sidebar, header, pane trees, and mounted-layout identity and visibility rules.
- `Thread/`: `ThreadView`, `Composer` (with the slash menu, model picker, question panel), `ThreadTurns`, `ThreadTools`, `ThreadMarkdown`, `Subagents` (cards, strip, ledger), `SubagentInspector` (plus `RightPaneSplit`). `NativeThreadStores.swift` keeps one store per agent.
- `DiffReview.swift`, `DiffReviewView.swift`, `GitDiff.swift`, `CodeHighlight.swift`: the review pane and its diff/syntax model.
- `Keybindings.swift`: `KeybindingsStore`, chord validation, ghostty unbinds.
- `RemoteHostStore.swift`, `RemoteSidebarSection.swift`, `RemoteDirectoryPicker.swift`, `SettingsRemote.swift`: remote host configs, sidebar host sections, remote pickers, listener settings.
- `StatusExtension.swift`, `NamerExtension.swift`, `PanesExtension.swift`, `ReviewExtension.swift`, `ThemeExtension.swift`, `SubagentsExtension.swift`, `ChildrenExtension.swift`, `InspectExtension.swift`: embedded copies of the canonical `Extensions/*` sources.
- `TerminalSessions.swift`: pane/session adoption, agent launch commands, attachment, surface rebuild, retirement.
- `PaneControl.swift`: extension-driven pane authorization and routing.
- `SettingsView.swift`, `SettingsComponents.swift`, `Settings*.swift`: the in-window Settings surface and its pages.
- `Themes.swift`, `ShepherdPiTheme.swift`: appearance mode, the resolved variant for Ghostty, the pi theme file and variant marker.
- `LegacyDesign.swift`: deprecated aliases for pre-redesign token names; delete with the last call site.
- `ComponentGallery.swift`: every shared component in every state (Debug menu).
- `NewAgentSheet.swift`, `NewWorktreeSheet.swift`, `FinalizeWorktreeSheet.swift`, `GitWorktree.swift`, `WorktreeFinalize.swift`, `DialogSheet.swift`: creation, worktree, and confirmation flows.

## Where a new feature belongs

- Pure model, ID, tree operation, or invariant: `ShepherdCore`.
- Wire message or framing rule: `ShepherdProtocol` plus all consumers and round-trip tests.
- Persisted mutation, process, PTY, RPC projection, socket, or screen behavior: `ShepherdSessions`.
- Thread-client behavior or a pure presentation rule shared with remote/iOS: `ShepherdRemote`.
- A color role, type token, size, or reusable control: `ShepherdDesign` (roles in every theme, contrast tests where text is involved).
- Ghostty configuration or surface behavior: `TerminalSurfaceKit`, exposed through `TerminalHost.swift` if the app needs it.
- Selection, presentation, settings, or user interaction: `ShepherdApp`, in the narrowest existing responsibility file.

Keep one-use logic inline. Add a helper or abstraction only when it has multiple callers or an existing local pattern requires it. Every new server mutation needs a focused state-management test; every lifecycle change needs a real-session test. Run `swift test` and the `Shepherd (Dev)` Xcode build before finishing.
