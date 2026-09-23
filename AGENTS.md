# AGENTS.md: working on Shepherd

Shepherd is a native macOS app (SwiftUI, macOS 26+) for running and supervising many `pi` coding
agents.

- **Agents:** every agent is `pi --mode rpc` on pipes, owned in-process (`RPCSession` and
  `RPCThreadState` in `ShepherdSessions`), and rendered only as a native thread
  (`Sources/ShepherdApp/Thread/`). There are no terminal agents and no Terminal/Native switch.
- **Terminals:** the only terminals are panes beside a thread, opened by the user with ⌘D or by an
  agent's `pane_*` tools. They are real PTYs rendered with libghostty. There are no global shells
  and no space shell workspaces.
- **Spaces** are plain groups in the sidebar. With no agent selected, the workspace shows an
  empty state.
- **Lifetime:** there is no daemon. Sessions live and die with the app. On relaunch the workspace
  (spaces, agents, pane layouts) restores from `state.json`, every agent resumes its pi session
  over RPC, and every terminal pane respawns a fresh shell.
- **Remote:** Shepherd can serve its agents to other devices over an authenticated TCP listener
  (off by default). The main use is running projects on one Mac and driving them from another
  Mac running Shepherd; iOS comes later.

**Read [DESIGN.md](DESIGN.md) before touching any UI.** It is the authority on visuals and
interaction. [ARCHITECTURE.md](ARCHITECTURE.md) maps modules, ownership, and data flow.

## Build, run, test

There is deliberately no Makefile or Taskfile. One Xcode project at the repo root runs the apps,
and plain SwiftPM drives everything else.

**The Mac app:** open `Shepherd.xcodeproj`, pick a scheme, choose My Mac, and Run. The Mac target
is a shim (`App/ShepherdLauncher.swift` calls `ShepherdMacApp.main()` from the `ShepherdApp`
library). There is no `swift run` path for the GUI.

A stable Shepherd and a development build cannot share state. The socket and `state.json` live
in the support directory, and the server refuses to bind over a live socket. So there are two
schemes:

| Scheme | Config | Support directory |
| --- | --- | --- |
| `Shepherd (Dev)` | Debug | `~/Library/Application Support/Shepherd-dev` (the scheme sets `SHEPHERD_SUPPORT_DIR`) |
| `Shepherd (Prod)` | Release | `~/Library/Application Support/Shepherd` |

⌘R on Dev never disturbs the agents in your everyday copy. `Shepherd iOS` builds the deferred iOS
client ([docs/ios](docs/ios/README.md)).

```bash
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' build
swift build                                  # every package target
swift test --filter UnitTests                # fast tier: seconds
swift test --filter IntegrationTests         # real server, stub pi, git, off-screen windows
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests
swift test                                   # everything (previews skip without SHEPHERD_PREVIEW_DIR)
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent" node --test Tests/Extensions/*.test.mjs
```

**Environment variables:**

- **`SHEPHERD_SUPPORT_DIR`** moves the support directory: the socket, `state.json`, installed
  extensions, `remote-token`, and subagent artifacts.
- **`SHEPHERD_THEME=night-watch-dark|night-watch-light`** forces an appearance at launch, which is
  handy for screenshots.
- **Set by the app for pi, never read from the user's environment:**
  - Always: `SHEPHERD_AGENT_ID`, `SHEPHERD_SOCKET`, `SHEPHERD_EXT_STATUS`.
  - With the matching extension on: `SHEPHERD_EXT_PANES`, `SHEPHERD_NATIVE_CHILDREN`,
    `SHEPHERD_EXT_CHILDREN`, and `SHEPHERD_CHILD_*`.
  - Per agent: `SHEPHERD_NEEDS_NAME`, `SHEPHERD_AUTOMATION`, `SHEPHERD_MODEL`.
- **`SHEPHERD_PR_DESCRIPTION_MODEL`** overrides the model that drafts finalize PR bodies.

## Testing

Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), never XCTest.
Tests come in tiers, and the switch is `--filter` on target names.

| Tier | Targets | What belongs there |
| --- | --- | --- |
| Unit | `ShepherdCoreUnitTests`, `ShepherdProtocolUnitTests`, `ShepherdUIUnitTests`, `ShepherdRemoteUnitTests`, `ShepherdSessionsUnitTests`, `ShepherdAppUnitTests`, `ShepherdCLIUnitTests`, `TerminalSurfaceKitUnitTests` | Pure logic |
| Integration | `ShepherdSessionsIntegrationTests`, `ShepherdAppIntegrationTests` | Real processes, sockets, git, windows |
| Previews | `ShepherdPreviewTests` | Offscreen renders of every surface |

**Unit tests** must not use `Process`, sockets, `SessionServer.start()`, `NSWindow` or
`NSHostingView`, git, timers, `Task.sleep`, or polling.

- A tiny scratch file is fine when the unit under test *is* a file format (state.json decoding, a
  pi session file).
- Each test should run well under 50 ms, and a whole target well under a second.
- Prefer table-driven `@Test(arguments:)`.

**Integration tests** use the helpers in `Tests/ShepherdTestSupport`:

- `ScratchServer`: a real `SessionServer` on scratch paths that records every broadcast state.
- `StubPi.command`: runs `Resources/stub-pi.py`, a scripted `pi --mode rpc` driven by prompt
  keywords (`ask`, `select`, `hang`, `die`, `big`, `slow`, `widgets`, `fill`, `newsession`, …).
  `STUB_PI_LOG` records what it received, and `STUB_PI_HISTORY_BYTES` seeds a long history.
- `makeScratchRepo()` and `git(_:in:)`: a git repository with one commit.
- `makeScratchDirectory()`: a short path, because `sun_path` caps socket paths at 104 bytes.
- `ExtensionClient`: a raw extension-socket client.
- `eventually("what", …)` and `eventuallyOnMain`: named 10 ms polls that throw `WaitTimeout`
  saying what never happened. Never sleep a fixed amount; wait on a callback or `eventually`.
  Keep timeouts generous (10–30 s), but make the happy path fast.
- Mark a suite `.serialized` only when it shares process-global state (environment variables, the
  support directory).

**Previews** render every surface (thread states, review, palette, settings, sheets, sidebar,
empty states) in light and dark to `$SHEPHERD_PREVIEW_DIR/<surface>-<light|dark>.png`. They are
skipped when the variable is unset. Look at them after a UI change; they exist so an agent can
see its work.

**Live model:** the opt-in use-case run against a real model is gated on `SHEPHERD_LIVE_MODEL`
(e.g. `cpa/~anthropic/claude-haiku-latest`). It never runs by default.

**Extension tests** (`Tests/Extensions/*.test.mjs`, Node's test runner) need `PI_PACKAGE_DIR`
pointing at the installed pi package. They isolate `HOME` and use a local fake provider.
`native-children.smoke.mjs` is an opt-in real-model smoke (`PI_SMOKE_MODEL`).
`Tests/ShepherdIOSChecks` holds the iOS client's scripts ([docs/ios/VALIDATION.md](docs/ios/VALIDATION.md)).

**Tests never take the user's focus or drive their mouse or keyboard.**

- Windows sit off-screen (`x: -30_000, y: -30_000`), borderless, and ordered back
  (`orderBack`).
- Never call `makeKey` or `orderFront`, and never post synthetic mouse or keyboard events.
- Nothing touches the user's pi configuration, sessions, or a running Shepherd.

**Which tier a change needs:**

- A model, parser, projection, presentation rule, keybinding, or search change needs a unit test.
- A server mutation, process lifecycle, socket, remote-protocol behavior, or git flow needs an
  integration test.
- A visible change needs a preview render checked in both appearances, and a run of the Dev
  build.

Name each test as a sentence of the behavior (`deletingASpaceKeepsNestedSpaces`), and test
contracts rather than copy text. When a test exposes a real bug, keep it with
`.disabled("bug: …")` and report it.

**Coverage that must not be dropped:**

- **Round trips:** every `ExtensionMessage`/`ExtensionReply` and `RemoteRequest`/`RemoteReply`
  case (table-driven), plus the `NativeThread` wire types against the golden
  `Tests/Extensions/native-thread-wire.json`.
- **Server:** every `SessionServer` state mutation.
- **Core:** the status transition table, `PaneNode` operations, and state validation.
- **Migration:** terminal-era `runtime` keys, global shells and space shells dropped at startup,
  and review leaves.
- **Extensions:** embedded extensions byte-identical to `Extensions/*` (all twelve).
- **Themes:** every theme variant complete, and the WCAG contrast rules met.
- **App logic:** keybindings (defaults, validation, stored overrides for removed actions
  ignored), palette and settings search, workspace selection and parking, sidebar ordering and
  reveal, review rows and diff parsing, `PiSessionFile` paths, and child runs.

CI (`.github/workflows/ci.yml`) runs `swift build --build-tests` and `swift test --no-parallel` on
pull requests and pushes to `master`.

## Source map

```text
App/
  ShepherdLauncher.swift   Mac @main shim.        iOS/  the deferred iOS client (own target)
Sources/
  ShepherdCore/        Models (Space, Tab, Agent, Automation, ShepherdState), typed IDs, PaneNode
                       (binary split tree; LeafPane carries sessionID/cwd/agentID), AgentStatus +
                       canTransition, ThinkingLevel, SessionRuntime, StateValidation. No deps.
  ShepherdProtocol/    ExtensionMessage/ExtensionReply (+ ChildRun, PaneInfo, …), RemoteMessage
                       (RemoteRequest/RemoteReply, RemoteProtocol version + capabilities),
                       NativeThread (requests, results, NativeThreadSnapshot), RPCWire (pi's
                       JSONL, lenient), Framing (NDJSON, LineBuffer, 1 MiB cap), ShepherdPaths.
  ShepherdRemote/      RemoteHostClient, NativeThreadStore, NativeThreadPresentation, ShepherdLog.
  ShepherdSessions/    SessionServer (state, sessions, extension socket, remote listener),
                       RPCSession, RPCThreadState, PTYSession, SessionScreen (SwiftTerm), StateStore,
                       PaneRequest (pane/review/automation requests + outcomes), RemoteFileUpload,
                       PiModelCatalog, PiConfig.
  TerminalSurfaceKit/  Ghostty adapter for terminal panes; see its NOTES.md.
  ShepherdApp/         The Mac app:
    ShepherdApp.swift, RootView, SidebarView, ThreadHeader, WorkspaceView, WorkspaceSelection
    ShepherdViewModel(+Navigation, +Creation, +Workspace, +Spaces, +Reorder, +Palette,
      +RightPane, +Review, +ChildInspector, +Automations, +RemoteActions, +RemoteInspection,
      +RemoteWorktrees)
    Thread/            ThreadView, Composer, ThreadTurns, ThreadTools, ThreadMarkdown, Subagents,
                       SubagentInspector (+ RightPaneSplit)
    TerminalSessions (TerminalSessionStore), TerminalHost (the only TerminalSurfaceKit import),
      NativeThreadStores (+ LegacyTerminalAgents), PaneControl, PaneFocusMemory
    DiffReview, DiffReviewView (ReviewPane), GitDiff, CodeHighlight (tree-sitter)
    GitWorktree, WorktreeFinalize, NewWorktreeSheet, FinalizeWorktreeSheet, NewAgentSheet,
      RemoteWorktreeSheet, RemoteDirectoryPicker, DialogSheet
    CommandPalette, CommandPaletteView, PaletteContentSearch, Keybindings (KeybindingsStore)
    SettingsView, SettingsWindow, SettingsComponents, Settings{Appearance, Terminal, Agents,
      Worktrees, Pi, Remote, Keyboard, Advanced}, AppSettings
    Themes (ThemeManager, ShepherdTheme), ShepherdPiTheme, ShellIntegration, ComponentGallery
    RemoteHostStore, RemoteSidebarSection, AgentPeers, AgentNotifications, ChildRuns,
      PiSessionFile, PiUpdateManager, AppUpdater (Sparkle channels)
    Status/Namer/Panes/Review/Theme/Subagents/Children/InspectExtension.swift  embedded extensions
  shepherd-cli/        `shepherd --import herdr` (writes state.json while Shepherd is not running).
Packages/
  ShepherdUI/          Night Watch, its own local package (module ShepherdUI; macOS 26, iOS 27):
                       Tokens/ (ThemeDefinition, NightWatch, ThemeStore + NWPalette, Colors
                       (Color.nw), Typography (Font.nw, bundled Geist), Metrics (NW.Space/Radius/
                       Height), Motion, Elevation, AgentState, HexColor), Resources/Fonts,
                       Components/ (Controls, Status, Containers, Thread, Composer, Agents),
                       Previews/. Its unit tests live in the root (Tests/ShepherdUIUnitTests).
Extensions/            Canonical pi extensions (TypeScript/ESM, dependency-free):
  shepherd-status.ts      status + active pi session       shepherd-namer.ts   agent titles
  shepherd-panes.ts       pane_*, agent_list/send/spawn, automation_*, notify
  shepherd-review.ts      review_diff (opens the review pane)
  shepherd-subagents.ts   setAgentChildren (native + pi-subagents rows)
  shepherd-children.ts (+ -config, -ui, shepherd-workflow, shepherd-missions, shepherd-inspect.mjs)
                          native subagent runtime; see docs/native-subagents.md
  shepherd-theme.ts       theme sync for pi run by hand in a terminal pane
Tests/                 Test tiers above; LegacyTests/ holds the pre-rewrite suites (not built).
```

## Data flow

- **The in-process `SessionServer` is the single source of truth** for spaces, per-agent layout
  tabs, agents, and automations (persisted to `state.json`). It owns every PTY and RPC process.
- **The local GUI** calls the server directly, with no socket, and adopts `onStateChanged`
  broadcasts. It owns only view state: selection, focus, collapsed spaces, the right pane,
  sheets, appearance, and keybindings.
- **Remote clients** reach the same server over TCP.
- **Tabs** survive only as per-agent layout containers, plus `inspectorFor` utility terminals the
  host opens for a remote client (a remote `gh auth login`). There is no tab UI: the sidebar is
  navigation.

**Agent launch** (`StatusExtension.command`, from `TerminalSessionStore`):
`/bin/zsh -l -c "exec pi --mode rpc --session-id <id> [--model … --thinking …] -e <extensions>"`.

- The session ID is the agent's current pi session. `PiSessionFile` seeds a session header if
  pi has none yet.
- `--model`/`--thinking` go only to a fresh session.
- Extensions follow Settings ▸ Pi ▸ Bundled extensions.
- The opening prompt is the first native `send`, not a positional argument.

`RPCThreadState` projects pi's events into the `NativeThreadSnapshot` that
`SessionServer.nativeThread` serves locally and, over TCP, remotely
([docs/native-thread.md](docs/native-thread.md)).

**Status reporting.** The status extension reports `setAgentStatus` fire-and-forget:

| pi event | Status |
| --- | --- |
| `session_start` | `idle` |
| `agent_start` | `working` |
| `agent_settled` | `done` |
| ask/question-style `tool_execution_*` | `blocked` |
| `session_shutdown` | `idle` |

It also reports `setAgentSession` with the live pi session ID, so `/new` or `/resume` survives a
relaunch.

**Terminal panes** run the shell from Settings ▸ Terminal as a login shell. Startup files in the
support directory's `shell-integration/` wrap `pi` so pi run by hand picks up Shepherd's theme.
The user's rc files and pi settings are never edited, and agent-only variables are blanked.

**Automations** are saved prompts (`ShepherdState.automations`).

- **A run** spawns an ordinary agent, in a reserved hidden space when the automation's cwd
  matches no user space. It is launched with `SHEPHERD_AUTOMATION=1`, which keeps the pane and
  notify tools but withholds the `automation_*` tools.
- **Management:** agent requests arrive as `AutomationRequest` through
  `SessionServer.onAutomationRequest` and are served by `ShepherdViewModel+Automations.swift`.
  The Automations sidebar section is their only surface.
- **At startup:** the previous run's agents and their layouts are dropped
  (`SessionServer.automationRunAgentIDs`: every agent in the hidden space, plus any agent an
  automation still points at), every automation's `agentID` is cleared, and enabled automations
  start fresh runs once the workspace is adopted. Never keep a run agent across launches.
- **Changing them** touches `ShepherdCore`, the extension-message enums, `SessionServer`, the
  panes extension (canonical and embedded), and their tests.

## Remote

- **Listener:** `SessionServer.startRemoteListener(port:tokenURL:)` binds TCP on **all
  interfaces** (default 7433; port 0 picks an ephemeral port, and the bound port is returned).
  Settings ▸ Remote ▸ Serve this Mac toggles it, and bind failures show there.
- **Auth:** the first frame must be `hello` with the token from `remote-token` in the support
  directory (32 random bytes as hex, mode 0600, created on first use) and a matching
  `RemoteProtocol.version`. **There is no TLS.** A VPN or trusted network is the transport
  boundary. Never describe the listener as internet-safe.
- **Protocol** (NDJSON, `RemoteMessage.swift`):
  - state fetch and pushed `stateChanged`
  - native thread requests
  - attach, detach, input, resize, and acknowledged paste
  - pane open, close, and split resize
  - `listDir`, `listModels`, `addSpace`, and `createAgent` with `creationOptions`
  - chunked uploads (32 MiB per file)
  - `agentQuery`/`agentAction`: rename, delete, reorder, review, subagents, search, worktree
    info/setup/finalize/delete

  Capabilities gate newer features. The client falls back (raw bracketed paste) or refuses (pane
  control) against older hosts. Output frames chunk at 256 KiB to stay under the 1 MiB frame cap.
- **Sizing:** viewports are smallest-viewer-wins. Each attached remote viewer reports its grid,
  and the PTY takes the minimum; with no remote viewers, the local viewport rules. Resize reports
  from unattached clients are ignored.
- **Attach is atomic** on the server queue: viewport registration, snapshot, attachment, and
  replay watermark happen in one turn.
- **Host-side handlers:** remote pane and agent-creation requests go through
  `onRemotePaneRequest` and `onRemoteCreateAgent` with the same authorization as local requests.
  A server without those handlers rejects them. Detaching a remote pane never kills the host
  session.
- **Client:** `RemoteHostStore` persists host configs, **including tokens**, in UserDefaults
  (`shepherd.remote.hosts`). It keeps one `RemoteHostClient` per host, with exponential backoff
  capped at 30 s. Remote hosts are not part of `ShepherdState`.
- **Protocol changes** touch the request and reply enums with every Codable arm, `RemoteProtocol`
  capabilities where relevant, server handling, `RemoteHostClient` (Mac and iOS), and the
  round-trip and listener tests.

## Rules that are easy to break

**Contracts.** `ShepherdCore` and `ShepherdProtocol` couple the server, GUI, extensions, and
remote clients. Change them deliberately, and update every consumer and the round-trip tests in
the same change.

- A new extension message needs the enum case, its `Kind` and `CodingKeys` entries, both
  init/encode arms, and a row in the protocol round-trip table. Replies are the same
  (`ExtensionReply`).
- Remote messages follow the same rules.
- A new `SessionServer` mutation needs an integration test.
- New persisted fields decode with defaults, so older `state.json` files keep loading.

**Embedded extensions have one canonical copy.** The twelve files in `Extensions/` are canonical.
pi loads the copies that the eight `Sources/ShepherdApp/*Extension.swift` files write to the
support directory from embedded string literals. `installedPath()` rewrites an installed copy
whenever its content differs, so drift ships bugs. `ChildrenExtension.swift` carries children,
children-config, children-ui, workflow, and missions, and installs `InspectExtension`'s
`shepherd-inspect.mjs`.

- Edit a `.ts`/`.mjs` file and its literal in the same change, with
  `scripts/sync-embedded-extension.py`. A unit test enforces byte identity for all twelve pairs.
- Extensions stay dependency-free and inert without their environment variables.
- They must never throw into pi or keep the process alive (unref'd sockets and timers).
- The panes extension speaks the request/reply half of `ExtensionMessage`/`ExtensionReply`.
  Extend both enums, `SessionServer.handleLine`, and the protocol tests together.

**Design tokens only.** Never hardcode a color, font size, or dimension in a view. Everything comes
from ShepherdUI (Night Watch):

- colors from `Color.nw` (dynamic, resolved against each view's appearance)
- fonts from `Font.nw(_:)` (aware of text scale)
- sizes from `NW.Space`, `NW.Radius`, and `NW.Height` (density-scaled rows), and the app's surface
  dimensions from `AppLayout`

Use a shared component before hand-rolling chrome. A new color is a role on `ThemeColors`,
filled in both variants of every theme (the compiler enforces completeness), with an `NWPalette`
property and a contrast rule if it carries text. Borders and hovers are theme roles, never ad-hoc
alphas. Status colors come from `AgentState`, never picked per view. Night Watch is the only
shipped theme. The pre–Night Watch names (`Tokens`, `Fonts`, `Metrics`, `Radius`, Basalt) are gone;
never reintroduce aliases for them.

**Keybindings resolve through the store.** Menus, palette keycaps, Settings ▸ Keyboard, and the
Ghostty unbind list all read `KeybindingsStore`, and hardcoding a chord in a view is a bug.

- A rebound chord must include ⌘. ⌘1–9 (agents), ⌃⇧1–9 (machine jumps), ⌘,, and the plain ⌘
  system and terminal chords are reserved.
- A focused Ghostty surface eats any key equivalent it has a binding for, so every chord the app
  chrome uses must be unbound in `appOwnedChords` (`TerminalSurfaceModel.swift`). Rebindable
  chords flow in through the store; the fixed ones are listed there. Leave Ghostty's copy and
  paste bindings alone.
- Rebinding reconfigures live surfaces in place (a Ghostty config update, like theme changes),
  with no remount, replay, or blank frame.

**Server concurrency.** One serial queue owns all server state, and every `PTYSession` and
`RPCSession` queue *targets* it. Session callbacks, extension handlers, and remote connections are
therefore mutually exclusive without locks.

- Never `.sync` between these queues; it deadlocks.
- Attach stays atomic: snapshot, attachment registration, and output watermark in one queue turn.
- Callbacks (`onOutput`, `onStateChanged`, …) hop to the main queue in FIFO order. Never call them
  from the server queue directly.

**PTY children.** `PTYSession` resets every child signal disposition to `SIG_DFL` and clears the
signal mask before exec, using async-signal-safe calls only. Without that, children inherit
ignored dispositions and every kill escalates to SIGKILL.

**TerminalSurfaceKit isolation.** `Sources/ShepherdApp/TerminalHost.swift` is the only app file
that imports TerminalSurfaceKit; everything else uses `AppTerminalModel`/`AppTerminalView`, so
engine API drift breaks exactly one file. GhosttyTerminal also exports `TerminalSurfaceView` and
`TerminalSurface`, so never import it alongside TerminalSurfaceKit.

**Status transitions.** `AgentStatus.canTransition` allows `done → working` (a finished agent
starting a new turn). The server applies extension reports unconditionally and logs table
violations; keep it that way, because real process lifecycles are messier than the table.
`SessionServer.start()` resets every persisted status to `idle`, because sessions died with the
previous run.

**Startup reconciliation** (`SessionServer.start()`) drops the global-shell and space-shell tabs
of older state files (`shellTabIDs`: no space, or no agent owns the tab). It also purges
`inspectorFor` utility tabs, removes review leaves, and clears automation runs. `Tab` ignores the
shell keys, and `Agent` ignores `runtime`.

**Dropped images are resized on the way in.** `TerminalImageDrop`, also reached through
`AppImageDrop` for composer attachments, clamps the longest edge to 2000 px and re-encodes: JPEG
stays JPEG, everything else becomes PNG.

- This is not a rendering optimization. pi writes an attached image into its session, so an
  oversized screenshot is re-sent on every later load of that conversation.
- Resize where the image enters, and never rewrite the user's own file; a copy in the drop
  directory is referenced instead.
- Drop copies prune after 24 h.

**Agents drive their own panes.** A new agent is exactly one pane, its thread. Extra panes come
from the agent (`shepherd-panes.ts`) or the user (⌘D). The server owns PTYs but not layouts, so
pane requests are forwarded to the GUI via `onPaneRequest` (and `onRemotePaneRequest`) and
answered with a `PaneOutcome`. `PaneControl.swift` is the only place that serves them. Its rules
are load-bearing:

- An agent may touch only panes in **its own** layout.
- It can never close or type into the pane running its own pi process.
- The last pane in a layout cannot be closed.

Shepherd does not nest agents. pi extensions own subagent execution (the bundled native runtime
is on by default), and the app only *projects* the results: sidebar rows, cards, and the
inspector. Child runs are display state and never persisted.

**Switching is a visibility flip, never a remount.** `WorkspaceSelection.mountedTabs` keeps every
mounted agent layout in the view tree, and selection only changes which one is visible (opacity,
hit-testing, and `isRendering`, where Ghostty occlusion stops hidden panes' render loops). Three
things silently bring back full-repaint lag:

- reordering `mountedTabs` (ForEach identity)
- using a conditional branch or `.hidden()` instead of `opacity(0)` (ConditionalContent destroys
  the subtree)
- applying `setRenderingActive` fire-and-forget (the model retries; see
  [NOTES.md](Sources/TerminalSurfaceKit/NOTES.md))

The one deliberate unmount is **cold parking**. A layout hidden for 30 s and outside the four
most recently shown (`WorkspaceSelection.coldParkCandidates`) drops its terminal panes' surfaces
via `TerminalSessionStore.parkPane`. Its processes and host-side screens keep running, and
reselecting it remounts from the server snapshot. A thread pane has no surface; its
`NativeThreadStore` keeps the draft and history. Measurements are in
[docs/benchmarks](docs/benchmarks/2026-09-03-terminal-baseline.md).

**Sessions and views are separate.** Closing a pane detaches views only. A process that exits on
its own closes its pane and retires its agent. Delete Agent is the explicit way to terminate an
agent and its auxiliary processes while the app runs, and quitting the app terminates everything.

**Only these paths mutate repositories** ([docs/worktrees.md](docs/worktrees.md)):

- **Creating a worktree:** `git worktree add --no-track -b` (`GitWorktree.swift`), from the New
  Agent sheet's worktree option or a space's New Worktree… sheet. The base is resolved per
  Settings ▸ Worktrees: `origin/<default>` after a fetch by default. It is visible and editable in
  the sheet, and recorded as `Agent.worktreeBase`.
- **Delete Worktree Agent:** confirmed, and it warns about unreconciled work.
- **Finalize Worktree** (`WorktreeFinalize.swift`): commit → push → `gh pr create` → optional
  opt-in merge → clean gate → remove worktree → delete local branch. Each step gates the next,
  nothing is destroyed before the clean gate, and the remote branch is never deleted (that would
  close the PR).
- **The review pane's per-file Revert** (`GitDiff.revert`): confirmed, local working-tree reviews
  only. Tracked files return to HEAD, and new files move to the Trash.

Nothing else mutates repository state, and Shepherd never prunes worktrees.

**Reviews dock; they don't split.** A review (`ReviewSession`, `ShepherdViewModel+Review.swift`)
lives in the agent's right pane beside the thread, in the slot shared with the subagent inspector
(the inspector wins). It never touches the persisted layout. Request changes and Commit send the
agent a follow-up turn, and the review closes only once the send succeeds, so comments survive a
failed send. A review an agent opens on a host is that host's view state: remote viewers are
deliberately not notified and open their own with ⇧⌘B.

**Agent names settle once.** A new agent wears its opening prompt (truncated by
`ShepherdViewModel.provisionalName`) with `nameIsFinal == false`. Only such agents get the namer
extension (`SHEPHERD_NEEDS_NAME=1`). It proposes a title on the first turn, and the server
applies it once, setting `nameIsFinal`. A manual rename also sets it.

- `setAgentName` never overwrites a final name.
- Naming never blocks pi's first turn: the namer runs detached and swallows every failure.
- Agents from a pre-autoname `state.json` decode as final.
- A `setAgentSession` that moves an agent to a *different* pi session (`/new`, `/resume`) clears
  `nameIsFinal`, because the old name described the old conversation.

## Git

Use conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`; `feat!:` for
breaking changes), one logical change per commit, with no AI or attribution lines.

`nightly` is the integration branch. Feature branches (`feat/…`, `fix/…`) come off it and merge
back through a PR with a merge commit (`--no-ff`). Every push to `nightly` ships a nightly build.
CI runs the tests on pull requests and on `master`.

## Releases

One workflow (`.github/workflows/release.yml`) serves four Sparkle channels, chosen by **tag
name**. Releasing means tagging `nightly`'s tested tip and pushing the tag.

| Channel | Cut by | Feed (on `gh-pages`) | Contains |
| --- | --- | --- | --- |
| stable | tag `vX.Y.Z` | `appcast.xml` | stable |
| rc | tag `vX.Y.Z-rc.N` | `appcast-rc.xml` | rc + stable |
| beta | tag `vX.Y.Z-beta.N` | `appcast-beta.xml` | beta + rc + stable |
| nightly | push to `nightly` | `appcast-nightly.xml` | nightlies only |

- **Promotion re-tags the same commit** (`v0.2.0-beta.1` → `v0.2.0-rc.1` → `v0.2.0`). Never
  rebuild for a promotion.
- **Pre-release feeds are supersets**, so riding beta or rc never strands a user behind a stable
  hotfix. Sparkle picks the newest *build number* (`CURRENT_PROJECT_VERSION`, the workflow run
  number), so a hotfix built after an rc supersedes it for rc riders.
- **Tags are immutable.** Never delete, move, or reuse one; a botched release gets the next
  number.
- **Default channel:** the app (`AppUpdater.swift`, `UpdateChannel`) defaults to its birth
  channel, parsed from the marketing version. An explicit choice in Settings ▸ Advanced is never
  overwritten.
- **Channel plumbing** changes `release.yml`, `UpdateChannel`/`ChannelDelegate`, the Advanced
  picker, and their tests together. Feed names are a contract between CI and the app.
- **Signing:** with the Developer ID, notarization, and Sparkle secrets configured, builds are
  signed and notarized. Without them the workflow falls back to ad-hoc signing and skips the
  appcast.

## Gotchas

- **Socket paths:** `sun_path` caps Unix socket paths at 104 bytes. Tests build sockets under
  short temporary paths.
- **Frame sizes:** RPC stdout records may be up to 256 MiB (`get_messages` returns a whole
  history in one record), but extension-socket and TCP frames stay capped at 1 MiB.
- **Replay** into a fresh surface is a `SessionScreen.snapshot()`: an ANSI reconstruction (up to
  2000 lines of styled scrollback, the alt screen, cursor, and modes), not raw bytes. Cosmetic
  artifacts are acceptable; lost bytes are not. The watermark protocol prevents duplication and
  loss.
- **pi's trust prompt:** interactive pi asks to trust project `.pi/` directories, but `-e` loads
  our extensions without one. Never install anything into `~/.pi/agent/`. `PiSessionFile` writes
  only session files, which pi treats as data.
- **pi's formats:** `PiConfig` (models.json, settings.json) and `PiModelCatalog`
  (`pi --list-models`) parse defensively, because pi's formats are not our contract.
- **Binding:** `SessionServer.start()` refuses to bind over a live socket (it probes with a
  connect) and replaces stale socket files. The remote listener reports bind failures rather than
  silently serving nothing.
- **Transcript search** in the palette reads only the last 512 KB of each agent's pi session.
- **Launching the binary bare** from a terminal starts a background process; the `AppDelegate`
  promotes it to `.regular` and activates it.
- **Quitting** while agents are working asks first, because it stops them mid-turn.
