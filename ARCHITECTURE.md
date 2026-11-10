# Architecture

Shepherd runs its session server in one of two processes. Whichever holds `<support>/server.lock`
owns:

- the workspace
- every agent's `pi --mode rpc` process
- the PTYs behind the terminals
- persistence
- the extension socket
- the remote listeners

**Background service** (Shepherd Nightly, while Login Items allows it): the app's own executable,
run by launchd as `Shepherd --host` (`SessionHost`, `ShepherdHost`; the LaunchAgent is
`Contents/Library/LaunchAgents/<bundle id>.host.plist`, registered by `BackgroundService`). It owns
everything above and has no UI. The app is its client over `<support>/host.sock`, through the same
remote-host paths it uses for a paired Mac, plus `local.v1` for what only this Mac's app gets (the
Browser and design drawing run in the app's web views). Quitting the app leaves agents running;
the host drains and restarts on its own when an update replaces the bundle (`HostDrain`).

**In process** (Shepherd and Dev, the service off in Login Items, or tests): the app owns
everything above itself. Quitting Shepherd ends every child process, and relaunching restores the
workspace and respawns each agent in its pi session. `SHEPHERD_BACKGROUND_HOST=1` lets any build be
a running host's client.

Either owner can also serve its agents to other devices over an authenticated TCP listener.

[DESIGN.md](DESIGN.md) holds the UI rules. This document covers module boundaries, ownership,
and where each feature lives. The code and its tests are the detail. [AGENTS.md](AGENTS.md) is
the short rule sheet; [docs/rules.md](docs/rules.md) has the rules that are easy to break.

## Modules

```text
ShepherdCore
├── ShepherdProtocol
│   ├── ShepherdRemote
│   │   └── ShepherdSessions ── SwiftTerm, ShepherdPTYSpawn (C)
│   └── shepherd-cli

TerminalSurfaceKit ── GhosttyTerminal (Vendor/libghostty-spm)

DesignSurfaceKit ── Core, Protocol, WebKit (+ React 18.3.1 UMD, a resource)

ShepherdUI (local package, Packages/ShepherdUI) ── nothing

ShepherdApp ── Core, Protocol, Sessions, ShepherdUI, TerminalSurfaceKit, DesignSurfaceKit, WebKit (the Browser), Sparkle, SwiftTreeSitter
Shepherd iOS (Xcode target) ── Core, Protocol, Remote, ShepherdUI, DesignSurfaceKit, SwiftTerm
```

| Module | Owns | Depends on |
| --- | --- | --- |
| `ShepherdCore` | Codable workspace models (`Space`, `Tab`, `Agent`, `Automation`, `Design`, `ShepherdState`), typed IDs, the `PaneNode` layout tree (a thread with its terminals hung beside it), `AgentStatus` and its transition table, `ThinkingLevel`, and structural validation | nothing |
| `ShepherdProtocol` | Wire contracts: `ExtensionMessage`/`ExtensionReply` (extension socket), `RemoteRequest`/`RemoteReply` and `RemoteProtocol` (version, capabilities), the native thread contract (`NativeThreadRequest`/`Result`/`Snapshot`), pi's RPC wire types (`RPCWire`, decoded leniently), NDJSON framing (1 MiB frame cap; 16 MiB from the host to its own app over `host.sock`), `ShepherdPaths`, `ShepherdEdition` (Shepherd or Shepherd Nightly), Settings ▸ Instructions' files and requests (`Instructions.swift`), Settings ▸ Experiments ▸ Suggested instructions (`Suggestions.swift`), Settings ▸ Skills' skills, repositories and requests (`Skills.swift`), a host's settings as a client sees them (`HostSettings.swift`), and the Design tool's format (`DesignIndex`, `DesignPath`, `DesignTemplate`/`DesignElementID`, `DesignBoardCheck`, Tweak's `DesignStyleEdit`, `DesignTokens` and `DesignProps`, and `DesignCanvasLayout`'s pages, notes and a duplicate's place) | Core |
| `ShepherdRemote` | `RemoteHostClient` (TCP client: handshake, reconnect, bounded writes), `TunnelEndpoint`, `BrowserTunnelHub` and `BrowserPortForwarder` (a Browser tunnel's sockets and flow control, a connection's tunnels, and which ports of a remote thread's host are forwarded here), `BrowserDriveClaimant` and `BrowserViewerPolicy` (when a viewer claims an agent's browser, and where a host's agent may take the viewer's page), `NativeThreadStore` (the `@Observable` thread client used by local, remote, and iOS views; it derives the rows a thread draws once per change), the pure derivations (`NativeThreadPresentation`, `NativeTurnPresentation` for a turn's items, `NativeActivity` for activity lines and the changes card, `InstructionsText` and `InstructionsPresentation` for Settings ▸ Instructions, `SuggestionsPresentation` for its experiment), the Settings models the Mac and the iOS client share (`ClientSettings`, and `ClientSkills` with `SkillsText`, `SkillsPresentation` and `SkillsDirectory`, skills.sh's client, for Settings ▸ Skills), a host's designs (`RemoteDesignLibrary`, `RemoteDesignSource` and the per-host, per-design `RemoteDesignCache`), the Tweak tab's model the Mac and the iPad share (`DesignTweakModel` and `DesignTweakControls`), the iPad's live-board plan and design Recents (`DesignTouchPlan.swift`), and `ShepherdLog` | Core, Protocol |
| `ShepherdUI` | Shepherd Design, the design system, in its own local package (`Packages/ShepherdUI`, macOS 26 and iOS 27): `ThemeDefinition` and Shepherd Design, `ThemeStore` (with the resolved `SHPalette` and `SHTypeRamp`), `Color.sh`, `Font.sh` and the bundled Geist faces, the `SH` scales, motion, elevation, `AgentState`, and the shared SwiftUI components by domain (Controls, Status, Containers, Navigation, Thread, Composer, Agents, Review, Dialogs, DesignTool: the design canvas, board frames, cards and header, and a design system's page parts). SwiftUI only; no app state | nothing |
| `ShepherdPTYSpawn` | `shepherd_forkpty_exec`: the PTY child side in C (reset signal dispositions and mask, close stray descriptors, exec), so no Swift runs between fork and exec | nothing |
| `ShepherdSessions` | `SessionServer`, the authoritative state store and every session. Agents run as `RPCSession` + `RPCThreadState`, terminals as `PTYSession` + `SessionScreen`. Also `StateStore`, the extension socket, the remote listener, `PiSessionPreview` (a thread read from pi's session file while pi starts), `InstructionsStore` (Settings ▸ Instructions' files and history), `SuggestionsStore` (Suggested instructions), `SkillsStore` and `SkillsGit` (a host's skills in its pi home's `skills/`, installed from partial clones), `YourPiImport` and `YourPiResources` (the first copy from the user's own pi, Re-import, and their extensions' switches), `PiSignIn` (the sign-in bridge: pi's own login run on the engine's node against Shepherd's pi home, over JSON lines) and `PiSignInCatalog`, `DesignStore` (each design's files and each board's last 20 versions, on its own queue), `DesignSystemStore` (design systems in `design-systems/`, on its own queue; built-ins registered by the app), `PiEngine` (which pi runs) and `PiLaunch` (every line that starts pi or the node beside it), `PiSetup` (the engine, pi's home and its catalog, passed in), and `PiModelCatalog`/`PiConfig` | Core, Protocol, Remote, ShepherdPTYSpawn, SwiftTerm |
| `TerminalSurfaceKit` | The libghostty adapter for terminals (see its [NOTES.md](Sources/TerminalSurfaceKit/NOTES.md)). Knows nothing about agents or workspaces | GhosttyTerminal |
| `DesignSurfaceKit` | The Design tool's board renderer, for macOS and iOS: `DesignSurface` (one design's sandbox, over its folder or over files in memory), `DesignBoardView` (one board's `WKWebView`: load, `replaceSource`, `snapshot`, events), the `shepherd-design://` scheme handler with its CSP and content rules, and Shepherd's clean-room board runtime on vendored React. Reads a design's folder; writes nothing | Core, Protocol, WebKit |
| `ShepherdApp` | Everything on screen: view model, selection, thread views, review, palette, settings, sheets, appearance, keybindings, embedded extensions, the layout-to-session bridge, and the remote host store | all of the above, Sparkle, tree-sitter |
| `shepherd-cli` | `shepherd --import herdr`: writes herdr workspaces into `state.json` while Shepherd is not running | Core, Protocol |

Dependencies point inward:

- Core and Protocol import neither Sessions nor App.
- Sessions imports neither App, ShepherdUI, nor TerminalSurfaceKit; only Sessions imports
  ShepherdPTYSpawn.
- ShepherdUI imports no Shepherd module; the app maps its states onto `AgentState`.
- Only `ShepherdApp/TerminalHost.swift` imports TerminalSurfaceKit, and only
  `ShepherdApp/DesignHost.swift` imports DesignSurfaceKit (on iOS, only
  `App/iOS/Designs/DesignHost.swift` for the iPhone's screens and
  `App/iOS/DesignPad/PadDesignRenderer.swift` for the iPad's).
- Only `ShepherdApp/BrowserHost.swift` imports WebKit in the app: the side pane's Browser.
- Only TerminalSurfaceKit imports GhosttyTerminal.
- DesignSurfaceKit imports neither Sessions nor App: it is handed a design's folder (or a
  design system's files in memory, for its specimens) and serves it read-only.

The Mac app target is a shim, `App/ShepherdLauncher.swift`, that calls `ShepherdMacApp.main()`.
The iOS target compiles `App/iOS` (one synchronized folder) against Core, Protocol, Remote, and
ShepherdUI; it never links ShepherdApp.

## Runtime ownership

**`SessionServer` is the single source of truth.** It holds the persisted `ShepherdState`
(spaces, per-agent layout tabs, agents, automations) and every live session. One serial queue
owns all server state. Each session's internal queue targets that queue, so session callbacks,
extension handlers, and remote connections are mutually exclusive without locks. Callbacks
(`onStateChanged`, `onOutput`, …) hop to the main queue in FIFO order. `onThreadRevision` is the
exception: a hint to pull, delivered at most once per display frame and only for the agents the
app watches (its threads on screen). `onDesignRevision` is paced the same way (one pacer type,
`RevisionPacer`), for the designs on screen.
Nothing waits on the queue from outside: `SessionServer.state` returns the copy `StateStore`
publishes under a lock as it commits, and an RPC record of 256 KiB or more (a long history)
decodes on a concurrent queue while its session holds its later records in order.

**`ShepherdViewModel`** (split across `ShepherdViewModel+*.swift`) holds only presentation state:

- selection and focus
- collapsed spaces
- the side pane (its Changes tab, or the subagent inspector over it) and pi's dots on it
- sheets, settings, appearance, and remote hosts

In process it calls the server directly, with no socket, and adopts its `onStateChanged`
snapshots; as the background service's client it never starts a server (`BackgroundHostClient`)
and takes the host's workspace as its own over `host.sock` (`ShepherdViewModel+LocalHost`). A
persistence task tail keeps user mutations ordered. If the server rejects a mutation, the view
model reconciles itself and `TerminalSessionStore` from `server.state`.

**Observation.** The view model and the app's stores (`NativeThreadStore`, `AppSettings`,
`KeybindingsStore`, `ThemeManager`, `RemoteHostStore`, `AppUpdater`, the
worktree models, terminal sessions) are `@MainActor @Observable`. Views read only what they draw and
take plain `Equatable` values, so a status report or a poll re-renders just the views whose
values changed. The menu bar reads `MenuState` (`AppCommands.swift`), narrow cached values that
change only when a menu's own value does.

## Where each feature lives

Start at these files, then follow the code. There is no per-feature doc.

| Feature | Start at |
| --- | --- |
| Agent thread (pi RPC, turns, queue, questions) | `ShepherdSessions/RPCSession.swift`, `RPCThreadState*.swift`; `ShepherdRemote/NativeThreadStore`; `ShepherdApp/Thread/` |
| Subagents (native children) | `Extensions/shepherd-children*.ts`, `ShepherdSessions/ChildrenExtension.swift`, `ShepherdRemote/NativeSubagent*.swift` |
| Changes pane, Undo/Redo, review | `ShepherdSessions/Changes/`, `ShepherdApp/Changes*.swift`, `ShepherdSessions/ReviewCommit.swift` |
| Worktrees | `ShepherdSessions/GitWorktree.swift`, `ShepherdApp/*Worktree*.swift`, `WorktreeQueries.swift` (also the host's `agentQuery`) |
| Browser | `Extensions/shepherd-browser.ts`, `ShepherdApp/Browser*.swift`, `ShepherdRemote/Browser*.swift` |
| Design tool | `Extensions/shepherd-design*.ts`, `Extensions/design-skill/`, `ShepherdSessions/Design*Store.swift`, `DesignSurfaceKit` |
| Skills, instructions, hooks | `ShepherdSessions/Skills*.swift`, `InstructionsStore.swift`, `Hooks/`; matching `Extensions/shepherd-*.ts` |
| MCP | `Extensions/shepherd-mcp-*`, `ShepherdApp/MCP/`, `ShepherdSessions/ProjectMCP*.swift` |
| Projects, missions, automations | `ShepherdSessions/SessionServer+*Project*.swift`, `SessionServer+Missions.swift`, `SessionServer+Automations.swift` (runs and triggers), `ShepherdApp/Automation*.swift`; the Mission and Project runtime (`ShepherdApp/MissionController*.swift`, `Project*Controller.swift`) runs where the agents run, built by `RuntimeHosting` in the app or in `Shepherd --host` |
| Goals | `Extensions/shepherd-goal.ts`, `ShepherdProtocol/NativeGoal.swift`, `ShepherdApp/Thread/GoalCard.swift` |
| Remote listener and iOS client | `ShepherdSessions/Remote*.swift`, `ShepherdRemote/RemoteHostClient.swift`, `App/iOS/`, [remote protocol](docs/remote-protocol.md) |
| Terminals | `ShepherdSessions/PTYSession.swift`, `ShepherdApp/TerminalSessions.swift`, `TerminalHost.swift` |
| Issues & PRs | `ShepherdSessions/Forge/`, `ShepherdApp/Forge/`; threads' pull request links and close on merge in `ShepherdSessions/PullRequestLinks.swift` |
| Pi engine, launch, home | `PiLaunch.swift`, `PiEngine.swift`, `PiHome.swift`, [pi engine](docs/pi-engine.md) |

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
