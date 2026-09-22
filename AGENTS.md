# AGENTS.md — working on Shepherd

Shepherd is a native macOS app (SwiftUI, macOS 26+) for running and supervising many `pi` coding
agents. Every agent is `pi --mode rpc` on pipes, owned in-process, and Shepherd is its only UI:
the native thread (transcript, composer, questions, subagents). The only terminals are panes an
agent or the user (⌘D) opens beside a thread — real PTYs rendered with libghostty; there are no
global shells or space shell workspaces. There is no daemon process: sessions live and die with
the app — close Shepherd and every agent stops. On relaunch the workspace (spaces, agents, pane
layouts) restores from
`state.json` and every pane respawns a fresh process (agents resume their pi session).
There is no terminal agent anymore: `state.json` files from that era decode unchanged (the
`runtime` key is ignored) and those agents relaunch over RPC in the same pi session.
**Read `DESIGN.md` before touching any UI** — it is the authority on visuals and interaction.

Remote access exists and is optional: the app can serve its fleet over an authenticated TCP
listener (off by default, Settings ▸ Remote); another Mac running Shepherd acts as the
client. See "Remote" below.

## Build, test, run

There is deliberately no Makefile/Taskfile. One Xcode project at the repo root runs the apps;
plain SwiftPM drives everything else.

**The Mac app:** open `Shepherd.xcodeproj`, pick a scheme, destination My Mac, Run. The Mac
target is a thin shim (`App/ShepherdLauncher.swift` is `@main` and calls
`ShepherdMacApp.main()` from the `ShepherdApp` library).

Two Mac schemes, because a stable Shepherd and a build under development cannot share state —
the socket and `state.json` both live in the support directory and the server refuses to
bind over a live socket:

| Scheme | Config | State |
| --- | --- | --- |
| `Shepherd (Dev)` | Debug | `~/Library/Application Support/Shepherd-dev` (via `SHEPHERD_SUPPORT_DIR`) |
| `Shepherd (Prod)` | Release | the default directory |

So ⌘R on Dev never disturbs the agents running in your everyday copy. Use Product → Archive
(or copy the Release build) to install into `/Applications`.

```bash
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' build
```

(The .app lands in DerivedData unless you pass `-derivedDataPath`.)

**Libraries and tests — plain SwiftPM:**

```bash
swift build                          # all package targets
swift test                           # all test bundles, all must pass
```

`ShepherdApp` is a library product — there is no SwiftPM-run path for the GUI; the app runs
only through `Shepherd.xcodeproj`.

Useful envs: `SHEPHERD_THEME=basalt-dark|basalt-light` (force a variant at launch — handy for
screenshots). The extension socket lives at
`~/Library/Application Support/Shepherd/shepherd.sock` and `state.json` beside it; pi children
receive the socket path via `SHEPHERD_SOCKET` (set by the app, not read from the environment).
The socket is same-user, filesystem-confined IPC with no authentication. Keep
`SHEPHERD_SUPPORT_DIR` private and user-controlled. A process running as the same macOS user
that can access the socket can send messages as a known agent, so this endpoint is not a
security boundary. The *remote* TCP listener is a separate thing with its own token — see
"Remote".

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the dependency and runtime map.

```
Sources/
  ShepherdCore/          Pure models: typed IDs, AgentStatus + transition table, PaneNode
                      (binary split tree), Space/Tab/Agent/ShepherdState, state validation.
                      Agent carries model, thinkingLevel, nameIsFinal, piSessionID (and
                      ignores a persisted `runtime` key); Tab carries inspectorFor
                      (ephemeral host-side utility layouts, purged at startup). No
                      dependencies.
  ShepherdProtocol/      Wire contracts: ExtensionMessage/ExtensionReply (local extension
                      socket), RemoteRequest/RemoteReply + RemoteProtocol (TCP remote
                      protocol, version + capabilities), NativeThread (the native thread's
                      requests, results, and NativeThreadSnapshot), RPCWire (pi's
                      `--mode rpc` JSONL, decoded leniently), NDJSON framing (1 MiB payload
                      cap), LineBuffer, ShepherdPaths (incl. remote-token path).
  ShepherdRemote/        Remote client: RemoteHostClient (nonblocking TCP, NDJSON,
                      reconnect/backoff, bounded write queue). Also the platform-neutral
                      thread client shared by local, remote, and iOS views: NativeThreadStore
                      (polling, paging, optimistic echoes, settled running state) and
                      NativeThreadPresentation (pure derivations: turns, tool rows, DiffStat,
                      durations, pill state, subagent cards/ledger, scroll following).
  ShepherdDesign/        The design system (SwiftUI only, no app state): ThemeDefinition
                      (light/dark ThemeVariant: role colors, syntax, terminal, pi colors),
                      Basalt (the one shipped theme), ThemeStore (selected theme, text
                      scale, density), Tokens, Fonts, Metrics/Radius, and Components/
                      (buttons, controls, status, chips, containers).
  ShepherdSessions/      In-process session server: SessionServer (state mutations + PTY
                      and RPC sessions + the extension socket + the optional remote TCP
                      listener), RPCSession (`pi --mode rpc` on pipes), RPCThreadState (pi's
                      event stream → NativeThreadSnapshot), PTYSession (forkpty),
                      SessionScreen (headless SwiftTerm screen model, ANSI snapshot/replay),
                      StateStore (persisted JSON), PiModelCatalog, PiConfig, ShepherdLog.
  TerminalSurfaceKit/   Ghostty adapter: TerminalSurfaceModel/View over GhosttyTerminal's
                      host-managed IO backend, appearance, image/file drops, URL opening.
                      Terminal panes only. See its NOTES.md.
  ShepherdApp/           The Mac app: ShepherdViewModel (split across base, Navigation,
                      Creation, Workspace, Palette, Reorder, Spaces, ChildInspector,
                      RightPane, Review, Automations, Remote*), Thread/ (ThreadView,
                      Composer, ThreadTurns, ThreadTools, ThreadMarkdown, Subagents,
                      SubagentInspector + RightPaneSplit), ThreadHeader, SidebarView,
                      DiffReviewView (the review pane), TerminalSessionStore (pane→session
                      lifecycle), command palette, KeybindingsStore, Themes (ThemeManager:
                      appearance mode, Ghostty + pi theme file), ComponentGallery (Debug
                      menu), Settings
                      (Appearance/Terminal/Agents/Worktrees/Pi/Remote/Keyboard/Advanced),
                      creation/worktree sheets + directory browser, the eight
                      *Extension.swift embeds, TerminalHost (ghostty bridge),
                      RemoteHostStore + remote sidebar/panes.
  shepherd-cli/          `shepherd-cli --import herdr`: imports herdr workspaces into
                      state.json while Shepherd is not running.
Extensions/
  shepherd-status.ts     Reports agent lifecycle status + active pi session ID.
  shepherd-namer.ts      Titles an agent from its opening prompt (setAgentName).
  shepherd-panes.ts      Gives an agent pane_* tools, agent_list/send/spawn peers,
                         automation_* management, and notify.
  shepherd-review.ts     Gives an agent review_diff, which opens the review pane.
  shepherd-theme.ts      Syncs the theme of a pi run by hand in a terminal pane.
  shepherd-subagents.ts  Merges native and pi-subagents child display (setAgentChildren).
  shepherd-children.ts   Native subagents (on by default): extension-owned RPC children, plus
  shepherd-children-config.ts / -ui.ts, shepherd-workflow.ts, shepherd-missions.ts
                         its modules; see docs/native-subagents.md.
  shepherd-inspect.mjs   View helpers imported by the children UI (and a standalone viewer).
```

There is no tab UI: navigation is the sidebar (agent row → that agent's thread and the panes
beside it; a space row is a disclosure with no view of its own — no agent selected shows an
empty workspace). Server-side "tabs" survive purely as per-agent layout containers. Global
shells and space shell workspaces were removed: `SessionServer.start()` drops their tabs from
older state files (`shellTabIDs`: no space, or no agent owns it), and `Tab` ignores their
`name`/`nameIsFinal`/`restoreCommand` keys. Tabs with `inspectorFor` are host-side utility terminals opened for a remote client (a remote
`gh auth login`) and are purged at startup. Subagents open in the right pane beside the
parent's thread (the subagent inspector), never as a layout of their own.

Data flow: the **in-process SessionServer is the single source of truth** for
spaces/tabs/agents/layouts (persisted to state.json) and owns every PTY and RPC process. The
local GUI calls it
directly (no socket) and adopts `onStateChanged` broadcasts; it owns only view state
(selection, focus, grouping, sheets, theme, keybindings). Remote clients reach the same server
over the TCP remote protocol instead. On app quit the server kills every session; on relaunch
the workspace restores from state.json and each pane spawns a fresh process (`pi --mode rpc`
for an agent's primary pane, a login shell for a terminal pane).

Agent sessions run `pi --mode rpc` through a login shell (`zsh -l -c "exec pi --mode rpc …"`
so the user's PATH resolves) with `SHEPHERD_AGENT_ID`/`SHEPHERD_SOCKET` in the env, a stable `--session-id`
(`PiSessionFile` seeds a minimal session header if pi hasn't yet, so relaunch resume and
palette transcript search work), and the extensions passed via `pi -e`. `RPCSession` owns the
pipes and `RPCThreadState` projects pi's events into the `NativeThreadSnapshot` that
`SessionServer.nativeThread` serves to the local GUI and, over TCP, to remote clients. The
opening prompt is the first native `send`, not a positional argument. The status extension
reports `setAgentStatus` (fire-and-forget): `session_start→idle`, `agent_start→working`,
`agent_settled→done`, ask/question-style `tool_execution_*` → `blocked`,
`session_shutdown→idle`. It also reports `setAgentSession` with the live pi session ID.
[docs/native-thread.md](docs/native-thread.md) walks the whole thread pipeline, from pi's
events to `ThreadView`.

## Automations

Automations are saved watch prompts persisted in `ShepherdState.automations` (`ShepherdCore`).
Each run spawns a dedicated agent — in a reserved *hidden* space when the automation's cwd
matches no user space — launched with `SHEPHERD_AUTOMATION=1`, which gives it panes + notify
tools but none of the `automation_*` management tools (recursion guard). Ordinary agents get
`automation_create/list/update/delete/start/stop` from the panes extension; requests arrive as
`AutomationRequest` over the extension socket and route through
`SessionServer.onAutomationRequest`, mirroring the pane-request path.
`ShepherdViewModel+Automations.swift` owns the app side; the AUTOMATIONS sidebar section is a
running automation's only surface. Runs are ephemeral: startup clears every automation's
`agentID` (its process died with the previous app run) and enabled automations restart after
adoption. New automation fields or requests touch `ShepherdCore`, the extension-message enums,
`SessionServer`, the panes extension (canonical + embedded literal), and their tests — same
contract rules as panes.

## Remote

- `SessionServer.startRemoteListener(port:tokenURL:)` binds a TCP listener on **all
  interfaces** (default port 7433, port 0 = ephemeral; actual bound port is returned). The GUI
  toggle lives in Settings ▸ Remote; binding failures are surfaced there, not swallowed.
- Auth is a shared bearer token: first frame must be `hello` with the token from `remote-token`
  in the support directory (auto-generated, 32 random bytes hex, mode 0600). No TLS — the
  design assumes a VPN/trusted network is the transport boundary. Never describe the listener
  as internet-safe; the token only keeps other devices on that network honest.
- The protocol is version-checked NDJSON (`RemoteMessage.swift`): state fetch + pushed
  `stateChanged`, native thread requests (snapshots, sends, answers, model/thinking, subagent
  commands and transcripts), attach/detach, input, debounced resize, scroll, acknowledged
  paste, pane open/close/split-resize, host directory listing, model listing, addSpace,
  createAgent.
  Capabilities gate newer features; the client falls back (raw bracketed paste) or rejects
  (pane control) against older hosts. Output frames chunk at 256 KiB to stay under the 1 MiB
  NDJSON cap.
- **Viewport sizing is smallest-viewer-wins** (tmux semantics): each attached remote
  viewer reports its grid, the PTY gets the minimum cols/rows across them; with no remote
  viewers the local GUI viewport rules. Resize reports from unattached clients are ignored.
  Attach is atomic on the server queue: viewport registration, snapshot, attachment, and
  replay watermark in one turn.
- Remote pane/agent-creation requests route through host-side handlers (`onRemotePaneRequest`,
  `onRemoteCreateAgent`) with the same authorization rules as local extension requests; a
  headless server rejects them. Detaching a remote pane never kills the host session.
- Client side: `RemoteHostStore` persists host configs in UserDefaults
  (`shepherd.remote.hosts`) — the token is stored there too, so treat those defaults as
  secrets. One live `RemoteHostClient` per host, exponential backoff capped at 30s. Remote
  hosts are **not** part of `ShepherdState`.
- Protocol changes touch: the request/reply enums + every Codable arm, `RemoteProtocol`
  capabilities where relevant, server handling, both clients, and `RemoteProtocolTests` (+
  `RemoteListenerTests`/`RemoteSessionStreamTests` for behavior).

## Rules that are easy to break

**Contracts.** `ShepherdCore` and `ShepherdProtocol` are the coupling points between server,
GUI, extensions, and remote clients. Change them deliberately and update all consumers + the
round-trip tests in the same change. New extension messages need: enum case + CodingKeys/Kind +
init/encode arms + a test row in `ProtocolTests` (replies too — `ExtensionReply` has the same
shape). Remote messages need the same in `RemoteProtocolTests`. New SessionServer mutations
need a test in `StateManagementTests`.

**Embedded extensions have one canonical copy.** All twelve `Extensions/*` files are canonical
sources, but pi loads the copies that the eight `Sources/ShepherdApp/*Extension.swift` files
write to Application Support from embedded Swift string literals (`installedPath()` rewrites
the installed copy whenever content differs, so drift ships bugs; `ChildrenExtension.swift`
carries the children, children-config, children-ui, workflow, and missions modules).
`Tests/ShepherdAppTests` (PiThemeTests) enforces byte-identity for every pair. Editing a
`.ts`/`.mjs` file means updating its Swift literal in the same change.
Extensions must stay dependency-free, inert without their env vars, and must never throw into
pi or keep the process alive (unref'd socket/timers). The panes extension speaks the
request/reply half of `ExtensionMessage`/`ExtensionReply` — extend both enums plus
`SessionServer.handleLine` and the protocol tests together.

**Design tokens.** Never hardcode a color, font size, or dimension in a view. Everything comes
from `ShepherdDesign`: colors from `Tokens.*` (dynamic colors from `ThemeStore.shared`'s theme
that resolve against each view's own light/dark appearance), fonts from `Fonts`
(text-scale-aware), sizes from `Metrics` (row heights density-scaled) and `Radius`. Use a
shared component from `ShepherdDesign/Components` before hand-rolling chrome. Adding a color
means adding a role to `ThemeColors`, filling it in both variants of every theme (the
memberwise initializers make the compiler enforce this), and a `Tokens` accessor; roles that
carry text get a contrast rule in `Tests/ShepherdDesignTests`, which enforce WCAG 4.5:1 for text
and the `…Text`-on-`…Bg` pairing. Borders and hover fills are theme roles too (`border*`,
`bgHover*`), never ad-hoc alphas. `ThemeManager` (app) only holds the System/Light/Dark mode and
pushes the resolved variant to Ghostty and the pi theme file. Basalt is the only shipped theme.
The pre-redesign token names (`NativeTokens`, `textDim`, `sidebarBg`, …) are gone; don't
reintroduce aliases for them. Read the "Theme model" section of DESIGN.md before touching
themes.

**Keybindings resolve through the store.** Menus, palette keycaps, Settings ▸ Keyboard, and the
ghostty unbind list all read `KeybindingsStore`; hardcoding a chord in a view is a bug.
Rebindable chords must include ⌘. ⌘1–9 (agents), ⌃⇧1–9 (machine jumps), and ⌘, are reserved. Rebinding reconfigures live
terminal surfaces in place (a ghostty config update, like theme changes) so focused panes
release the old chord with no remount, replay, or blank frame.

**Server concurrency.** One serial queue owns all server state; every PTYSession's and
RPCSession's internal queue *targets* it, so session callbacks, extension handlers, and remote connections are
mutually exclusive without locks. Never `.sync` between these queues (deadlock). Attach must
stay atomic: snapshot the screen, register the attachment, and capture the output watermark in
one queue turn — that's what makes replay exact for local and remote viewers alike. Callbacks
(`onOutput`, `onStateChanged`, …) hop to the main queue FIFO; never call them from the server
queue directly.

**PTY children.** `PTYSession` resets all child signal dispositions to SIG_DFL and clears the
signal mask before exec (async-signal-safe calls only). Don't remove that; without it children
inherit ignored dispositions and every kill escalates to SIGKILL.

**TerminalSurfaceKit isolation.** `Sources/ShepherdApp/TerminalHost.swift` is the ONLY app file
that imports TerminalSurfaceKit; everything else goes through `AppTerminalModel`/
`AppTerminalView`. Keep it that way — engine API drift must break exactly one file. Note the
name collisions: GhosttyTerminal also exports `TerminalSurfaceView` and `TerminalSurface`;
never import GhosttyTerminal alongside TerminalSurfaceKit.

**App-owned keyboard chords.** The ghostty surface consumes key equivalents matching its
bindings while focused. Every ⌘-chord the app chrome uses must be unbound in
`appOwnedChords` (TerminalSurfaceModel.swift) — otherwise a focused terminal silently eats the
shortcut. Rebindable chords flow in through the store; fixed ones (agent digits, machine
jumps, palette, Settings, quit) are listed there. Leave ghostty's copy/paste bindings alone.
Corollary from DESIGN.md: never advertise a hint for a shortcut that isn't wired.

**Status transitions.** The table in `AgentStatus.canTransition` allows `done → working` (a
completed agent starting a new turn). The server applies extension reports unconditionally but
logs table violations — keep it that way; real process lifecycles are messier than the table.
`SessionServer.start()` resets every agent's persisted status to `.idle` — sessions died with
the previous app run, so stale statuses must not survive a relaunch. Startup also purges
utility-terminal (`inspectorFor`) tabs (ephemeral by contract).

**Dropped images are resized on the way in.** `TerminalImageDrop` (reached through
`AppImageDrop` for the composer's attachments) clamps the longest edge to
2000px and re-encodes — JPEG sources stay JPEG, everything else becomes PNG. This is not a
rendering optimization: pi writes an attached image into its session transcript, so an
oversized screenshot is re-emitted as inline graphics on every later load of that conversation.
Resize where the image enters, never by rewriting the user's own file (an oversized dropped
file is copied down into the drop directory and that copy is referenced instead). Drop files
prune after 24h.

**Agents drive their own panes.** A new agent starts as exactly one pane (its native thread);
extra panes are opened by the agent through `shepherd-panes.ts` or by the user with ⌘D. The
server owns PTYs but not layouts, so pane requests are forwarded to the GUI via
`SessionServer.onPaneRequest` (and `onRemotePaneRequest`) and answered through `PaneOutcome`;
`PaneControl.swift` is the only place that serves them. Load-bearing rules there: an agent may
only touch panes in its **own** layout, it can never close or type into the pane running its
own pi process, and the last pane in a layout cannot be closed. Shepherd does not nest agents —
pi extensions own subagent execution; the bundled native helpers (on by default, Settings ▸
Pi) run as RPC child processes. The app only *projects* them (sidebar child
rows via `shepherd-subagents.ts`, cards and the right-pane subagent inspector from the thread
snapshot). Child runs are
ephemeral display state, never persisted.

**Switching is a visibility flip, never a remount.** `WorkspaceSelection.mountedTabs` keeps
every *mounted* agent layout in the view tree; selection only changes which one is visible
(`opacity`, hit-testing, and `isRendering` — ghostty occlusion stops hidden panes' render
loops). Three things silently reintroduce the full-repaint lag if touched: reordering
`mountedTabs` (ForEach identity), using a conditional-branch `.hidden()` instead of
`opacity(0)` (ConditionalContent destroys the subtree), and applying `setRenderingActive`
fire-and-forget (the model retries; see TerminalSurfaceKit/NOTES.md). The one deliberate
unmount is cold parking: a layout hidden for 30s and outside the four most recently shown
(`WorkspaceSelection.coldParkCandidates`) drops its terminal panes' Ghostty surfaces via
`TerminalSessionStore.parkPane` while its processes and host-side screens keep running;
reselecting it remounts from the server snapshot. An agent's thread pane has no surface; its
binding survives parking and its `NativeThreadStore` keeps the draft and history. Measured in docs/benchmarks.

**Sessions/views separation.** Closing panes detaches views only; a process exiting on its own
closes its pane (and retires its agent). Delete Agent is the explicit lifecycle action that
terminates an agent and its auxiliary processes while the app runs; quitting the app terminates
everything. Shepherd does not manage Git worktrees or branches, with one explicit exception:
`git worktree add -b` (GitWorktree.swift) runs when the user asks for an isolated agent — via
the New Agent sheet's worktree option, or the space context menu's New Worktree… sheet
(generated branch, agent named after it, opened immediately — branched from the base resolved
per Settings ▸ Worktrees: origin/<default> after a fetch by default, `--no-track`, visible and
overridable in the sheet, recorded on the agent as `worktreeBase`; see
docs/worktree-base-proposal.md). Its confirmed counterparts are
Delete Worktree Agent (warns about unreconciled work; may remove the worktree and its branch)
and Finalize Worktree (WorktreeFinalize.swift: commit → push → gh PR → optional opt-in merge
(auto-merge first, best-effort, never blocks cleanup) → clean-gate → remove worktree → delete
local branch; every step gates the next, destruction only after the clean
gate, and the remote branch is never deleted — doing so closes an open PR). The finalize
sheet's setup wizard probes prerequisites (git, identity, origin, gh, gh auth) through a
login shell and fixes them in-app. The one other repository mutation is the review pane's
per-file Revert (`GitDiff.revert`, confirmed first, local reviews only): tracked files return
to HEAD, new files move to the Trash — never deleted. Nothing else mutates repository state,
and Shepherd never removes or prunes worktrees — cleanup is the user's.

**Reviews dock, they don't split.** A review (`ReviewSession`, `ShepherdViewModel+Review.swift`)
lives in the agent's right pane beside the thread, sharing the slot with the subagent
inspector (inspector wins; opening a review closes it). It never touches the persisted layout;
startup purges `isReview` leaves left by older builds, and remote clients still render such a
leaf from older hosts. Request changes / Commit send the agent a follow-up turn and close the
review only once the send succeeds, so comments survive a failed send.

**Agent names are generated, and settle once.** A new agent wears its opening prompt (truncated
by `ShepherdViewModel.provisionalName`) with `nameIsFinal == false`. Only such agents launch pi
with `shepherd-namer.ts` (`SHEPHERD_NEEDS_NAME=1`); it proposes a title on the first turn and
the server applies it — once — flipping `nameIsFinal`. A manual rename also sets it. Never let
`setAgentName` overwrite a final name, and never block pi's first turn on naming: the namer
runs detached and swallows every failure. Agents restored from a pre-autoname `state.json`
decode as final so their existing names survive.

## Testing conventions

Swift Testing (`import Testing`, `#expect`, `@Suite`) — not XCTest. Core-logic coverage:
PaneNode operations, status transitions, protocol + remote-protocol round-trips, server
behavior, remote listener/stream behavior, screen snapshots, keybindings, palette search,
child runs, sidebar reorder, native thread presentation (`NativePresentationTests`),
theme validity and contrast (`ShepherdDesignTests`: every built-in variant must meet WCAG 4.5:1
for text and the semantic pairing rules). Server E2E tests drive a real in-process
`SessionServer` on scratch paths (`TestSupport.swift`: `makeScratchDirectory`, `waitUntil`,
`ExtensionClient` for the extension socket), in `.serialized` suites; make tests reliable over
fast (generous timeouts, poll with `waitUntil`). UI/rendering is verified by building +
running, the Debug menu's Component Gallery, and offscreen renders (`renderScreenshot` in
`Tests/ShepherdAppTests/ScreenshotSupport.swift`, which writes PNGs when
`SHEPHERD_NATIVE_SCREENSHOT_DIR` is set) — not by asserting on pixels. Everything must pass via plain `swift test`.

## Git

Conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`), atomic — one logical
change per commit. `nightly` is the integration branch: feature branches (`feat/...`) come
off it and merge back via PR with a merge commit (`--no-ff`); every push to `nightly` also
ships a nightly build. No AI/attribution lines in commit messages.

## Releases

One pipeline (`.github/workflows/release.yml`) serves four Sparkle update channels. The
channel is chosen by **tag name** — releasing is nothing more than tagging `nightly`'s
tested tip and pushing the tag:

| Channel | Cut by | Feed (gh-pages) | Contains |
| --- | --- | --- | --- |
| stable | tag `vX.Y.Z` | `appcast.xml` | stable only |
| rc | tag `vX.Y.Z-rc.N` | `appcast-rc.xml` | rc + stable |
| beta | tag `vX.Y.Z-beta.N` | `appcast-beta.xml` | beta + rc + stable |
| nightly | push to `nightly` | `appcast-nightly.xml` | nightlies (isolated) |

Rules that keep this reliable:

- **Promotion is re-tagging the same commit**: `v0.2.0-beta.1` → `v0.2.0-rc.1` → `v0.2.0`
  as confidence grows. Never rebuild for a promotion; the commit is the release.
- **Pre-release feeds are supersets** (stable ⊂ rc ⊂ beta) so riding beta/rc never strands a
  user behind a stable hotfix. Sparkle picks the newest *build number*
  (`CURRENT_PROJECT_VERSION` = the workflow run number, monotonic) in the chosen feed — so a
  hotfix built after an rc supersedes it for rc riders. Cut a fresh rc after hotfixes.
- **Tags are immutable**: never delete, move, or reuse a version tag. Botched release = new
  tag with the next number.
- The client (`AppUpdater.swift`, `UpdateChannel`) defaults each install to its **birth
  channel** parsed from the marketing version (`-beta.` / `-rc.` / `-nightly.`); a user's
  explicit channel choice in Settings ▸ Advanced is never overwritten.
- Channel plumbing changes touch `release.yml`, `UpdateChannel`/`ChannelDelegate`, the
  Settings ▸ Advanced picker, and `UpdateChannelTests` together — feed names are a contract
  between CI and the app.
- Secrets (Sparkle EdDSA key, Developer ID, notary) already live in the repo; the workflow
  degrades to ad-hoc signing without them. Appcasts publish to the `gh-pages` branch.

## Gotchas

- `sun_path` caps Unix socket paths at 104 bytes — tests build sockets in temp dirs, watch long
  paths.
- Replay into a fresh surface is a `SessionScreen.snapshot()` — a self-contained ANSI
  reconstruction (styled scrollback capped at 2000 lines, alt screen, cursor, modes), not raw
  byte replay. Cosmetic artifacts are acceptable, lost bytes are not; the watermark protocol
  (drop buffered output ≤ watermark, feed later chunks) is what prevents duplication or loss.
- The pi trust system: interactive pi prompts to trust project-local `.pi/` dirs; our `-e` flag
  loads extensions without any trust prompt. Don't install anything into the user's
  `~/.pi/agent/` — extensions ride per-session flags. (`PiSessionFile` writes *session files*
  under `~/.pi/agent/sessions/`, which pi owns as data, not config.)
- `models.json` / `settings.json` parsing (`PiConfig`) and `pi --list-models`
  (`PiModelCatalog`) are defensive by design — pi's formats are not a contract we control.
- Launching the app binary bare from a terminal starts it as a background process; the
  AppDelegate promotes it to `.regular` and activates. Window-capture scripts find it by owner
  name "Shepherd".
- `SessionServer.start()` refuses to bind over a live socket (probe-connect) and replaces stale
  socket files; `state.json` lives beside the socket. The remote listener similarly reports
  bind failures instead of silently serving nothing.
- Palette transcript search reads only the last 512 KB of each agent's pi JSONL session —
  bounded by design; old conversation text is out of scope.
