# Architecture

Shepherd is one macOS process with an in-process session server. The app owns:

- the workspace
- every agent's `pi --mode rpc` process
- the PTYs behind the terminal panes
- persistence
- the extension socket
- the views

It can also serve its agents to other devices over an authenticated TCP listener. There is no
daemon: quitting Shepherd ends every child process, and relaunching restores the workspace and
respawns each agent in its pi session.

[DESIGN.md](DESIGN.md) governs visuals and interaction. This document covers module boundaries,
ownership, and data flow. [AGENTS.md](AGENTS.md) lists the rules that are easy to break.

## Modules

```text
ShepherdCore
├── ShepherdProtocol
│   ├── ShepherdRemote
│   │   └── ShepherdSessions ── SwiftTerm, ShepherdPTYSpawn (C)
│   └── shepherd-cli

TerminalSurfaceKit ── GhosttyTerminal (Vendor/libghostty-spm)

ShepherdUI (local package, Packages/ShepherdUI) ── nothing

ShepherdApp ── Core, Protocol, Sessions, ShepherdUI, TerminalSurfaceKit, Sparkle, SwiftTreeSitter
Shepherd iOS (Xcode target) ── Core, Protocol, Remote, ShepherdUI
```

| Module | Owns | Depends on |
| --- | --- | --- |
| `ShepherdCore` | Codable workspace models (`Space`, `Tab`, `Agent`, `Automation`, `ShepherdState`), typed IDs, the `PaneNode` split tree, `AgentStatus` and its transition table, `ThinkingLevel`, and structural validation | nothing |
| `ShepherdProtocol` | Wire contracts: `ExtensionMessage`/`ExtensionReply` (extension socket), `RemoteRequest`/`RemoteReply` and `RemoteProtocol` (version, capabilities), the native thread contract (`NativeThreadRequest`/`Result`/`Snapshot`), pi's RPC wire types (`RPCWire`, decoded leniently), NDJSON framing (1 MiB frame cap), `ShepherdPaths`, `ShepherdEdition` (Shepherd or Shepherd Nightly), Settings ▸ Instructions' files and requests (`Instructions.swift`), Settings ▸ Experiments ▸ Suggested instructions (`Suggestions.swift`), and a host's settings as a client sees them (`HostSettings.swift`) | Core |
| `ShepherdRemote` | `RemoteHostClient` (TCP client: handshake, reconnect, bounded writes), `NativeThreadStore` (the `@Observable` thread client used by local, remote, and iOS views; it derives the rows a thread draws once per change), the pure derivations (`NativeThreadPresentation`, `NativeTurnPresentation` for a turn's items, `NativeActivity` for activity lines and the changes card, `InstructionsText` and `InstructionsPresentation` for Settings ▸ Instructions, `SuggestionsPresentation` for its experiment), and `ShepherdLog` | Core, Protocol |
| `ShepherdUI` | Night Watch, the design system, in its own local package (`Packages/ShepherdUI`, macOS 26 and iOS 27): `ThemeDefinition` and Night Watch, `ThemeStore` (with the resolved `NWPalette` and `NWTypeRamp`), `Color.nw`, `Font.nw` and the bundled Geist faces, the `NW` scales, motion, elevation, `AgentState`, and the shared SwiftUI components by domain (Controls, Status, Containers, Navigation, Thread, Composer, Agents, Review, Dialogs). SwiftUI only; no app state | nothing |
| `ShepherdPTYSpawn` | `shepherd_forkpty_exec`: the PTY child side in C (reset signal dispositions and mask, close stray descriptors, exec), so no Swift runs between fork and exec | nothing |
| `ShepherdSessions` | `SessionServer`, the authoritative state store and every session. Agents run as `RPCSession` + `RPCThreadState`, panes as `PTYSession` + `SessionScreen`. Also `StateStore`, the extension socket, the remote listener, `PiSessionPreview` (a thread read from pi's session file while pi starts), `InstructionsStore` (Settings ▸ Instructions' files and history), `SuggestionsStore` (Suggested instructions), and `PiModelCatalog`/`PiConfig` | Core, Protocol, Remote, ShepherdPTYSpawn, SwiftTerm |
| `TerminalSurfaceKit` | The libghostty adapter for terminal panes (see its [NOTES.md](Sources/TerminalSurfaceKit/NOTES.md)). Knows nothing about agents or workspaces | GhosttyTerminal |
| `ShepherdApp` | Everything on screen: view model, selection, thread views, review, palette, settings, sheets, appearance, keybindings, embedded extensions, the pane-to-session bridge, and the remote host store | all of the above, Sparkle, tree-sitter |
| `shepherd-cli` | `shepherd --import herdr`: writes herdr workspaces into `state.json` while Shepherd is not running | Core, Protocol |

Dependencies point inward:

- Core and Protocol import neither Sessions nor App.
- Sessions imports neither App, ShepherdUI, nor TerminalSurfaceKit; only Sessions imports
  ShepherdPTYSpawn.
- ShepherdUI imports no Shepherd module; the app maps its states onto `AgentState`.
- Only `ShepherdApp/TerminalHost.swift` imports TerminalSurfaceKit.
- Only TerminalSurfaceKit imports GhosttyTerminal.

The Mac app target is a shim, `App/ShepherdLauncher.swift`, that calls `ShepherdMacApp.main()`.
The iOS target compiles `App/iOS` (one synchronized folder) against Core, Protocol, Remote, and
ShepherdUI; it never links ShepherdApp. Its folders and hooks are mapped in
[docs/ios/CONTRACTS.md](docs/ios/CONTRACTS.md).

## Runtime ownership

**`SessionServer` is the single source of truth.** It holds the persisted `ShepherdState`
(spaces, per-agent layout tabs, agents, automations) and every live session. One serial queue
owns all server state. Each session's internal queue targets that queue, so session callbacks,
extension handlers, and remote connections are mutually exclusive without locks. Callbacks
(`onStateChanged`, `onOutput`, …) hop to the main queue in FIFO order. `onThreadRevision` is the
exception: a hint to pull, delivered at most once per display frame and only for the agents the
app watches (its threads on screen).
Nothing waits on the queue from outside: `SessionServer.state` returns the copy `StateStore`
publishes under a lock as it commits, and an RPC record of 256 KiB or more (a long history)
decodes on a concurrent queue while its session holds its later records in order.

**`ShepherdViewModel`** (split across `ShepherdViewModel+*.swift`) holds only presentation state:

- selection and focus
- collapsed spaces
- the right pane (inspector or review)
- sheets, settings, appearance, and remote hosts

It calls the server directly, with no socket, and adopts its `onStateChanged` snapshots. A
persistence task tail keeps user mutations ordered. If the server rejects a mutation, the view
model reconciles itself and `TerminalSessionStore` from `server.state`.

**Observation.** The view model and the app's stores (`NativeThreadStore`, `AppSettings`,
`KeybindingsStore`, `ThemeManager`, `RemoteHostStore`, `PiUpdateManager`, `AppUpdater`, the
worktree models, pane sessions) are `@MainActor @Observable`. Views read only what they draw and
take plain `Equatable` values, so a status report or a poll re-renders just the views whose
values changed. The menu bar reads `MenuState` (`AppCommands.swift`), narrow cached values that
change only when a menu's own value does.

**`TerminalSessionStore`** (`TerminalSessions.swift`) owns the pane-to-session lifecycle:

- It creates or adopts sessions: RPC for an agent's primary pane, a PTY running the configured
  shell for the others. Restored agents' pi start in `AgentStartQueue`'s order at launch (the
  agent on screen first), and the server's servable signal wakes the agent's thread store.
- It attaches terminal surfaces, handles early exits and rebuild races, and retires dead
  sessions once their final snapshot is no longer needed.
- An agent's thread pane has no surface. `NativeThreadStores` keeps one `NativeThreadStore` per
  agent for the agent's lifetime, so drafts, pages, and scroll state survive switching and cold
  parking.

**`WorkspaceSelection`** decides which layouts are mounted and which one is visible. Switching
agents flips visibility (opacity, hit-testing, and Ghostty's render loop); it never remounts. A
layout that has been hidden for 30 s and is outside the four most recently shown is
*cold-parked*: its terminal surfaces are dropped while its processes and host-side screens keep
running.

**Appearance.** `ThemeStore.shared` (ShepherdUI) holds the theme, text scale, and density
that views read; `AppSettings` feeds it the Text size and Density settings. `ThemeManager` (app)
holds the System/Light/Dark choice. It pushes the resolved variant to what cannot follow
SwiftUI's appearance by itself: Ghostty surfaces (a live `setTheme`) and the pi theme file used
by pi run by hand in a terminal pane.

**Layout.** `RootView` lays the window out itself: the sidebar, the toolbar, the workspace, and
the right pane (`RightPaneSplit`). `ShellLayout` (`AppLayout+Navigation.swift`) is the pure
function that decides, from the window's width, whether the sidebar docks or overlays and
whether the right pane docks or overlays the agent's layout. The right pane wraps the whole
layout (`AgentLayoutView` in `WorkspaceView.swift`), never one of its panes, so a terminal split
beside the thread never narrows what the dock rule measures.

## The agent thread

```text
pi --mode rpc  (/bin/zsh -l -c, --session-id, -e extensions)
  → RPCSession        stdin/stdout JSONL; stdout records up to 256 MiB, long ones decoded off the queue
  → RPCThreadState    events → bounded, revisioned NativeThreadSnapshot (rows hashed and sized once);
                      requests → RPC commands; each new revision of a thread on screen pushed
                      as onThreadRevision, at most once per frame
  → SessionServer.nativeThread (local, direct)  |  RemoteRequest.nativeThread (TCP)
  → NativeThreadStore (poll, or pull on a push; page, queue, echo, settle; derive rows, activity
                      lines, placements)
  → ThreadView · Composer (+ QueueStack, "Up next") · Subagents · SubagentInspector
```

- **Requests:** send, answer, abort, model and thinking changes, subagent commands, and queue
  changes. Each carries an operation ID plus the expected session and generation, so a stale
  action can never land in a new pi session.
- **The queue:** messages sent while pi works wait in a queue the host holds (every client sees
  and edits the same one) and go when pi settles, or are steered in. The composer draws it as
  "Up next" above its card, where each message can be steered, edited, reordered, or deleted.
- **One path for every client:** the local GUI and remote clients use the same request path;
  only the transport differs.
- **Detail:** [docs/native-thread.md](docs/native-thread.md) walks the pipeline, and
  [docs/native-subagents.md](docs/native-subagents.md) covers the children the extensions run.

## Terminal panes

```text
shell process
  → PTY master read source
  → PTYSession            bounded reads; ordered nonblocking input
  → SessionScreen.feed    headless SwiftTerm screen, the attach/replay model
  → SessionServer         per-session output queue, one main-queue delivery in flight
  → TerminalSessionStore → AppTerminalModel (TerminalHost.swift) → Ghostty surface
```

- **Process ownership:** `PTYSession` owns the process group and every master-FD source.
- **Backpressure:** output is lossless and bounded. Pending plus in-flight bytes are counted, the
  read source is suspended at a high-water mark and resumed below a low-water mark. A suspended
  dispatch source must be resumed before it is cancelled.
- **Child signals:** before exec, the child resets all signal dispositions to `SIG_DFL` and
  clears the signal mask. That child side is C (`ShepherdPTYSpawn`), because only
  async-signal-safe calls may run between fork and exec.
- **Replay:** `SessionScreen.snapshot()` is the only replay model: a self-contained ANSI
  reconstruction (up to 2000 lines of styled scrollback, the alt screen, cursor, and modes), not
  raw bytes.
- **Attach:** taking the snapshot, registering the attachment, and capturing an output-sequence
  watermark happen in one server-queue turn, for local and remote viewers alike. The viewer drops
  buffered output at or below the watermark and feeds what follows, so nothing is duplicated or
  lost when a surface is replaced.
- **A command for a fresh shell** (a pane opened with a command, `gh auth login`) goes through
  `SessionServer.typeCommand`, which waits until the shell's line editor has the terminal (the
  pty has left canonical mode and turned its echo off) and then types it. Written sooner, the terminal echoes it above the
  prompt and the line editor shows it again. A shell with no line editor gets it after 5 s.
- **Dead sessions** stay attachable until their consumer calls `retireSession(sessionID:)`.
- **Exit and shutdown:** exit delivery waits for buffered output. Shutdown cancels queued
  deliveries, balances suspended sources, and escalates TERM to KILL on each process group, then
  reaps.

`SessionServer.swift` and `TerminalSessions.swift` are large because each is a single queue and
lifecycle owner. Split them only if ordering rules stay visible in one place.

## Extensions and the extension socket

The bundled pi extensions report to the app over `shepherd.sock` in the support directory. The
directory is mode `0700` and the socket `0600`. The socket is same-user IPC, not an
authentication boundary ([SECURITY.md](SECURITY.md)).

- **`shepherd-status.ts`:** agent status and the active pi session.
- **`shepherd-namer.ts`:** proposes a title.
- **`shepherd-panes.ts`:**
  - `pane_*` tools, answered by `PaneControl.swift` through `onPaneRequest`
  - peer tools: `agent_list`, `agent_send`, and `agent_spawn` through `onAgentPeerRequest`
  - live coordination (`agent_read`, `agent_steer`, `agent_interrupt`, `agent_wait`): the server
    relays `coordinateAgent` to the target's own panes connection as `agentRequest` under a
    token of its own, and returns the target's `agentResponse` to the caller as `agentResult`
  - `agent_delete`, through `onAgentPeerRequest` to the Delete agent dialog; deletion happens
    only after the dialog claims the token ([docs/agent-coordination.md](docs/agent-coordination.md))
  - `automation_*`, through `onAutomationRequest`
  - `notify`
- **`shepherd-review.ts`:** `review_diff`, which opens the review pane.
- **`shepherd-subagents.ts`:** publishes subagent runs with `setAgentChildren`.
- **`shepherd-children.ts`:** opens a `helloChildren` control connection for subagent commands.
- **`shepherd-theme.ts`:** loaded only by pi run by hand in a terminal pane.
- **`shepherd-instructions.ts`:** reads Settings ▸ Instructions' `AGENTS.md` and
  `APPEND_SYSTEM.md` from `SHEPHERD_INSTRUCTIONS_DIR` when a session starts and adds them to pi's
  context files (right after pi's own root `AGENTS.md`) and system prompt (after pi's own
  `APPEND_SYSTEM.md`), so Shepherd never writes `~/.pi/agent`. While Settings ▸ Experiments ▸
  Suggested instructions is on for the agent (`SHEPHERD_SUGGEST_FILES`), its `suggest_instruction`
  sends `suggestInstruction` and reads back what became of the line; the server keeps it in
  `SuggestionsStore` until the user adds or dismisses it.

The server owns PTYs but not layouts, so pane requests from an agent (and from remote clients,
through `onRemotePaneRequest`) are forwarded to the GUI and answered with a `PaneOutcome`.

**Framing.** Frames are newline-delimited JSON capped at 1 MiB. Each client has ordered, bounded,
nonblocking replies. A framing or size violation disconnects the client; a frame that fails to
decode is logged and ignored.

**Installation.** Each extension's canonical source is in `Extensions/`, and pi loads a copy that
the matching `*Extension.swift` writes to the support directory from an embedded string literal.

**Adding an extension message:**

1. Add the case to `ExtensionMessage` or `ExtensionReply`, including every Codable arm.
2. Handle it in `SessionServer.handleLine` and the app handler it routes to.
3. Add a round-trip row and a server behavior test.
4. Update the canonical extension and its embedded literal together
   (`scripts/sync-embedded-extension.py`).

## Remote

`SessionServer.startRemoteListener(port:tokenURL:)` binds TCP on all interfaces (default port
7433, or 7434 in Shepherd Nightly). The first frame must be a `hello` with the shared token from `remote-token`, and the
protocol version must match `RemoteProtocol.version`. The `hello` also lists what the client
understands (`RemoteProtocol.clientCapabilities`), so the host can serve an older client in a
way it can still read. There is no TLS, so a VPN or trusted network
is the transport boundary.

The protocol is NDJSON (`RemoteMessage.swift`):

- a state fetch plus pushed `stateChanged`
- native thread requests
- terminal attach, detach, input, resize, and acknowledged paste
- pane open, close, and split resize
- directory listing, models, `addSpace`, and `createAgent` with creation options
- chunked uploads
- agent queries and actions: rename, delete, reorder, review, subagents, search, worktrees
- automations, and Settings ▸ Instructions' files (`instructions.v1`: fetch, save, restore)
- Settings ▸ Experiments ▸ Suggested instructions (`suggestions.v1`: fetch, configure, add, add all,
  dismiss, undo)
- the host's settings (`hostSettings.v1`: Settings ▸ Agents, Worktrees and Pi, the pi packages it
  loads, its versions; one change at a time)

Capabilities gate newer features. A client falls back (raw bracketed paste) or refuses (pane
control) against an older host. Output frames are chunked at 256 KiB to stay under the frame cap.

- **Viewport sizing** is smallest-viewer-wins. Each attached remote viewer reports its grid, and
  the PTY takes the minimum; with no remote viewers, the local window's size rules. Resize
  reports from unattached clients are ignored.
- **Host-side handlers:** remote pane and agent-creation requests go through
  `onRemotePaneRequest` and `onRemoteCreateAgent`, with the same authorization as local
  requests, and host settings through `onRemoteHostSettings`. A server without the GUI rejects
  them.
- **Detaching** a remote pane never kills the host's session.
- **Client side:** `RemoteHostStore` persists host configurations, including tokens, in
  UserDefaults (`shepherd.remote.hosts`). It keeps one `RemoteHostClient` per host, reconnecting
  with exponential backoff capped at 30 s, except after a refused token or another protocol
  version, which wait for Edit or Reconnect (`RemoteHostFailure`, shared with the iOS client).
  A failed handshake is reported only by what `connect` throws. Remote hosts are not part of `ShepherdState`; they
  appear as their own sidebar sections, and their agents use the same thread views.
- **Reviews** an agent opens on the host are the host's view state. Remote viewers open their own
  (⇧⌘B).

## Persistence and migration

`state.json` sits beside the socket in the support directory (`ShepherdPaths`;
`SHEPHERD_SUPPORT_DIR` overrides the directory). Each app has its own: `ShepherdEdition` reads
the bundle id, so Shepherd Nightly (`com.bailycase.shepherd.nightly`) uses
`Application Support/Shepherd Nightly` and never reads the everyday app's state.

- **Validation:** state is validated (`ShepherdState.validate()`) before every write. `StateStore`
  encodes the candidate and writes it atomically before replacing in-memory state or publishing
  callbacks. Agent statuses are the exception (`updateLive`): published at once, written only
  with the next structural mutation, since `start()` resets them anyway.
- **Corrupt files:** a state file that is corrupt or invalid at startup is moved aside as
  `state.json.corrupt-<uuid>`. If the move fails, further writes are refused rather than
  overwriting the evidence.
- **Named mutations:** use a named `SessionServer` mutation (`addSpace`,
  `addAgent(_:withTab:)`, `renameAgent`, `deleteAgent`, `reorderAgent`, `addAutomation`, …)
  rather than editing state from the app.
- **Layout writes:** a layout has two kinds of write. `updateLayoutStructure(tabID:layout:)`
  changes split and leaf structure and keeps existing pane `sessionID` bindings.
  `updatePaneSession(tabID:paneID:sessionID:)` changes one binding without replacing the tree.

**Migration** is decode-tolerant, plus a reconciliation in `SessionServer.start()`. Unknown keys
are ignored, and new fields decode with defaults.

- **Terminal-era agents:** the old `runtime` key is ignored, and those agents relaunch over RPC
  in the same pi session.
- **Pre-autoname agents:** agents without `nameIsFinal` decode as final.
- **Worktree fields:** agents without `worktreeBranch`, `worktreeBase`, or `worktreePath` decode
  them as nil.
- **Removed shell tabs:** `Tab` ignores the keys of removed shell tabs (`name`, `nameIsFinal`,
  `restoreCommand`).

At startup the server then:

- resets every agent's status to `idle`, because sessions died with the previous run
- drops global-shell and space-shell tabs (`SessionServer.shellTabIDs`: tabs with no space, or
  tabs no agent owns)
- purges host-side utility terminals (`inspectorFor` tabs)
- removes review leaves left in layouts by older builds
- drops the previous run's automation agents and their layouts (`automationRunAgentIDs`) and
  clears every automation's `agentID`

`LegacyTerminalAgents` also clears the old per-agent view preferences from UserDefaults.

## Where new code belongs

| Change | Place |
| --- | --- |
| A model, ID, tree operation, or invariant | `ShepherdCore` |
| A wire message or framing rule | `ShepherdProtocol`, plus every consumer and its round-trip tests |
| A persisted mutation, process, PTY, RPC projection, socket, or screen behavior | `ShepherdSessions` |
| Thread-client behavior or a pure presentation rule shared with remote and iOS (turn items, activity lines, pills) | `ShepherdRemote` |
| A color role, type token, size, or reusable component | `ShepherdUI` (roles in every theme variant, contrast rules where text is involved; components under `Components/<Domain>/` with a `#Preview`) |
| A surface dimension of a Mac screen | `AppLayout`, in its domain's `AppLayout+<Domain>.swift` |
| Mapping an app lifecycle onto a status color | `AgentStateMapping.swift` (onto `AgentState`) |
| Ghostty configuration or surface behavior | `TerminalSurfaceKit`, exposed through `TerminalHost.swift` |
| Selection, presentation, settings, or interaction | `ShepherdApp`, in the narrowest existing file |

Keep one-use logic inline, and add an abstraction only when it has several callers. Every new
server mutation needs a test, and every lifecycle change needs an integration test against a real
server.
