# Rules that are easy to break

> Read when your change touches a contract, an extension, the server's queue, terminals, the browser, layouts or repository mutation, or builds a feature that acts on its own.

**Contracts.** `ShepherdCore` and `ShepherdProtocol` couple the server, GUI, extensions, and
remote clients. Change them deliberately, and update every consumer and the round-trip tests in
the same change.

- A new extension message needs the enum case, its `Kind` and `CodingKeys` entries, both
  init/encode arms, a row in the protocol round-trip table, and its lines in `speaksFor` (the
  agent it acts as, `nil` only when it names none) and `replyID`: the server serves it only from
  that agent's own pi. Replies are the same (`ExtensionReply`), without the last part.
- Remote messages follow the same rules.
- A new `SessionServer` mutation needs an integration test.
- New persisted fields decode with defaults, so older `state.json` files keep loading.

**Embedded extensions have one canonical copy.** The twenty-one files in `Extensions/` are canonical,
and so is the design skill in `Extensions/design-skill/`.
pi loads the copies that the thirteen `Sources/ShepherdApp/*Extension.swift` files write to the
support directory from embedded string literals. `installedPath()` rewrites an installed copy
whenever its content differs, so drift ships bugs. `ChildrenExtension.swift` carries children,
children-config, children-ui, workflow, and missions, and installs `InspectExtension`'s
`shepherd-inspect.mjs`. `DesignExtension.swift` also writes the design skill's `SKILL.md` and
`format.md` to the support directory's `design-skill/`. `MCPExtension.swift` carries
`shepherd-mcp.ts` and `shepherd-mcp-client.mjs`, installed side by side. `BrowserExtension.swift`
carries `shepherd-browser.ts` (docs/browser.md). The sign-in bridge,
`shepherd-sign-in.mjs`, isn't an extension: `PiSignInScript` (ShepherdSessions' `PiSignIn.swift`)
carries it and installs it beside them, and the app runs it on the engine's node.
`CLIProxyAPIExtension` in ShepherdSessions embeds `shepherd-cliproxyapi.ts`; `PiHome.install`
writes it directly in the pi home and the launcher explicitly loads it, including for isolated
children and drafts. It is inert until Settings ▸ Pi ▸ Sign-in connects a server. Its atomic,
private connection file is `shepherd-cliproxyapi.json`, named by `SHEPHERD_CLIPROXYAPI_CONFIG`.
The managed provider is `cliproxyapi`, separate from imported `cpa` providers. No proxy process
is installed or managed, and credentials never leave the host. See docs/pi-home.md.
`ServiceTierExtension` (ShepherdSessions) embeds `shepherd-service-tier.ts`, the Speed control's
half in pi: `PiHome.install` writes it, and an agent's own pi (only) loads it with
`SHEPHERD_EXT_SERVICE_TIER` naming the agent's tier file under the pi home's `service-tier/`,
which the host keeps current and pi reads on every provider request (docs/service-tier.md). Its
support table is `ServiceTierSupport`'s, and the two are tested against one JSON table.

- Edit a `.ts`/`.mjs` file (or a design skill file) and its literal in the same change, with
  `scripts/sync-embedded-extension.py`. A unit test enforces byte identity for all twenty-one pairs
  and the skill's two files.
- Extensions stay dependency-free and inert without their environment variables.
- They must never throw into pi or keep the process alive (unref'd sockets and timers).
- The panes extension speaks the request/reply half of `ExtensionMessage`/`ExtensionReply`.
  Extend both enums, `SessionServer.handleLine`, and the protocol tests together.

**Design tokens only.** Never hardcode a color, font size, or dimension in a view. Everything comes
from ShepherdUI (Night Watch) or `AppLayout`:

- colors from `Color.nw` (dynamic, resolved against each view's appearance)
- fonts from `Font.nw(_:)` or `.nwText(_:)` (aware of text scale); `Font.nwSans`/`nwMono` only for
  a size the boards give outside the ramp
- spacing, radii, and heights from `NW.Space`, `NW.Radius`, and `NW.Height` (rows scale with
  Density; controls don't)
- a Mac screen's own dimensions from `AppLayout`, in the file for its domain:
  `AppLayout+Navigation.swift` (window, sidebar, toolbar, side pane, palette),
  `AppLayout+Thread.swift` (thread, composer), `AppLayout+Agents.swift` (subagent stack,
  inspector), `AppLayout+Settings.swift` (Settings, sheet sizes), `AppLayout+Pages.swift` (the
  Automations and Hosts pages), and `AppLayout.swift` for anything else. A component's own
  measures stay with it in ShepherdUI (`NWThreadMetrics`, `NWComposerMetrics`,
  `NWSidebarMetrics`, `NWToolbarMetrics`, `NWPaletteMetrics`, `NWDiffMetrics`,
  `NWDialogMetrics`, `NWPageMetrics`).

Use a shared component before hand-rolling chrome. A reusable part goes in the package, under
`Components/<Domain>/` with a `#Preview` in both appearances; composition that knows about agents
or the server stays in the app. ShepherdUI imports no Shepherd module: pass it values, and map
app lifecycles onto `AgentState` in `AgentStateMapping.swift`.

A new color is a role on `ThemeColors`, filled in both variants of every theme (the compiler
enforces completeness), with an `NWPalette` property and a contrast rule if it carries text.
Borders and hovers are theme roles, never ad-hoc alphas. Status colors come from `AgentState`,
never picked per view: `textColor` for the word, `color` for dots and glyphs, `tint` for the fill,
never `Color.nw.lantern.opacity(0.12)`. Night Watch is the only shipped theme. The pre–Night Watch
names (`ShepherdDesign`, `Tokens`, `Fonts`, `Metrics`, `Radius`, Basalt) are gone; never reintroduce
aliases for them.

A glyph that more than one view draws is a case of `NWGlyph` (`Tokens/Glyphs.swift`): the SF Symbol
and fill variant the board names (`bolt` is not `bolt.fill`), drawn through the registry or a
component that wraps it (`NWFastBolt`), never named again as a string.

**`DesignRulesTests` enforces four of these.** It scans `Sources/ShepherdApp`,
`Packages/ShepherdUI/Sources` (not `Tokens/` or `Previews/`) and `App/iOS` and fails, naming the rule
and the fix, for a literal font size (`.nwMono(11)`, `.system(size: 13)`), a status color tinted
with `.opacity(…)` (or an opacity named for a tint, fill or line), a raw color (`Color(red:…)`, a hex
string, `Color.white`, `.foregroundStyle(.gray)`) and a registered glyph named as a raw symbol
string. The offenders that predate it are in `DesignRuleAllowlist`, one entry per file and rule with
a ceiling and a reason: the list only shrinks, so never add an entry for code you wrote. An entry is
for something that is not chrome (a color that is a user's own data), and says why. A size the
boards give outside the ramp is a named constant in the component's metrics enum, not a literal.

**State is Observation.** The view model, `NativeThreadStore`, `AppSettings`,
`KeybindingsStore`, `ThemeManager`, `ThemeStore`, `RemoteHostStore` and its connections,
`AppUpdater`, the worktree models, terminal sessions, and `MenuState`
are `@MainActor @Observable` classes, owned with `@State` and bound with `@Bindable`.

- Don't add `ObservableObject`, `@Published`, `@StateObject`, or `@ObservedObject` to the Mac app
  or the iOS client. TerminalSurfaceKit's `TerminalSurfaceModel` stays one because
  GhosttyTerminal's view state is one. The iOS client's stores (`MobileHosts` and its hosts,
  `MobileNavigator`, `ThreadStores`, `MobileAppearance`) follow the same rules.
- Observe only what views draw: bookkeeping is `@ObservationIgnored`, and a property is written
  only when its value changes, so a poll or a status report never re-renders a view it didn't
  change.
- Views take plain `Equatable` values (sidebar rows, layout leaves, thread rows) and do no parsing,
  filtering, or highlighting in `body`; stores derive rows once per change. Menus read narrow
  cached values from `MenuState`.
- A list that can outgrow a screen is a lazy stack whose `ForEach` makes exactly one view per
  element (wrap an `if` or a `switch` in a container), with rows that compare equal unless they
  changed: highlight and selection arrive as a `Bool`, hover stays in the row, closures stay out
  of `==`. No per-row drop targets or hidden controls; see docs/design/performance.md › Performance. Add a
  `ListPerformanceTests` budget with any new long list.
- `PreferenceObservationTests` checks that a changed preference reaches the views that read it.

**Keybindings resolve through the store.** Menus, palette keycaps, Settings ▸ Keyboard, and the
Ghostty unbind list all read `KeybindingsStore`, and hardcoding a chord in a view is a bug.

- A rebound chord must include ⌘. ⌘1–9 (the first nine rows of Pinned, then Recents), ⌘,, and the
  plain ⌘ system and terminal chords are reserved.
- A focused Ghostty surface eats any key equivalent it has a binding for, so every chord the app
  chrome uses must be unbound in `appOwnedChords` (`TerminalSurfaceModel.swift`). Rebindable
  chords flow in through the store; the fixed ones are listed there. Leave Ghostty's copy and
  paste bindings alone. ⇧⌘D and ⌥⌘←/→ have no app action now (terminals are tabs only) and stay
  listed only because Ghostty's own split and goto bindings are silent no-ops in embedded
  libghostty that would swallow them; Next and Previous Terminal (⇧⌘] and ⇧⌘[) are real chords.
- Rebinding reconfigures live surfaces in place (a Ghostty config update, like theme changes),
  with no remount, replay, or blank frame.

**Server concurrency.** One serial queue owns all server state, and every `PTYSession` and
`RPCSession` queue *targets* it. Session callbacks, extension handlers, and remote connections are
therefore mutually exclusive without locks.

- Never `.sync` between these queues; it deadlocks.
- The main thread never waits on the server queue to read state: a busy queue (a history
  decoding at launch) would stall every frame. `SessionServer.state` reads the copy
  `StateStore` publishes under a lock each time it commits; a mutation the caller awaited is
  always in it. Code on the queue reads `store.state`. (Only `start()`, `stop()`, the remote
  listener's start and stop, and `pushMessage` still run synchronously on the queue.)
- Nothing slow runs on the queue. An RPC record of 256 KiB or more (a long history's
  `get_messages`) decodes on a concurrent queue while its session holds every later record, in
  order, until the decoded one is handled back on the queue; exit and unanswered-request
  failures (and a deadline that passes meanwhile) wait for them too. Stdout is read at most
  1 MiB per queue turn. Only the projection runs on the server queue.
- Attach stays atomic: snapshot, attachment registration, and output watermark in one queue turn.
- Callbacks (`onOutput`, `onStateChanged`, …) hop to the main queue in FIFO order. Never call them
  from the server queue directly. `onThreadRevision` alone is paced instead (at most one delivery
  per display frame, only for watched agents): it says "pull now" and carries no state.

**PTY children.** `PTYSession` resets every child signal disposition to `SIG_DFL` and clears the
signal mask before exec, using async-signal-safe calls only. Without that, children inherit
ignored dispositions and every kill escalates to SIGKILL.

**TerminalSurfaceKit isolation.** `Sources/ShepherdApp/TerminalHost.swift` is the only app file
that imports TerminalSurfaceKit; everything else uses `AppTerminalModel`/`AppTerminalView`, so
engine API drift breaks exactly one file. GhosttyTerminal also exports `TerminalSurfaceView` and
`TerminalSurface`, so never import it alongside TerminalSurfaceKit.

**DesignSurfaceKit is a sandbox.** Boards are untrusted HTML and JS (an agent's, or an imported
canvas). Each design renders in its own non-persistent data store, loads only through
`shepherd-design://<design>/` (plus Google Fonts), and never navigates; the CSP, the content rules
and the navigation policy enforce it together, and `aBoardReachesOnlyItsOwnDesign` proves it.
Shepherd's runtime is written from the documented format only: never copy, fetch or imitate
Claude Design's code (`support.js`, `dc-runtime.js`, `app.js`). React is the one vendored
dependency, loaded only inside board web views; a new version is vetted and its checksum pinned
in `DesignRuntimeTests`. `Sources/ShepherdApp/DesignHost.swift` is the only app file that imports
DesignSurfaceKit, as `TerminalHost.swift` is for TerminalSurfaceKit. A design on screen holds at
most five live web views and one off-screen view renders snapshots for the rest; never let a
canvas hold a web view per board.

**Status transitions.** `AgentStatus.canTransition` allows `done → working` (a finished agent
starting a new turn). The server applies extension reports unconditionally and logs table
violations; keep it that way, because real process lifecycles are messier than the table.
`SessionServer.start()` resets every persisted status to `idle`, because sessions died with the
previous run.

**Startup reconciliation** (`SessionServer.start()`) drops the global-shell and space-shell tabs
of older state files (`shellTabIDs`: no space, or no agent owns the tab). It also purges
`inspectorFor` utility tabs, removes review leaves, and clears automation runs. It keeps design
agents, which live in the reserved designs space (`Space.holdsDesigns`): one an older state.json
kept in a user space moves there with its layout, and one the space holds for a design that is
gone is dropped (`settleDesignAgents`; docs/designs.md). `Tab` ignores the shell keys, and `Agent`
ignores `runtime`.

**Dropped images are resized on the way in.** `TerminalImageDrop`, also reached through
`AppImageDrop` for composer attachments, clamps the longest edge to 2000 px and re-encodes: JPEG
stays JPEG, everything else becomes PNG.

- This is not a rendering optimization. pi writes an attached image into its session, so an
  oversized screenshot is re-sent on every later load of that conversation.
- Resize where the image enters, and never rewrite the user's own file; a copy in the drop
  directory is referenced instead.
- Drop copies prune after 24 h.

**Agents drive their own terminals.** A new agent is exactly one leaf, its thread, and terminals
are tabs under it, one terminal each: they come from the agent (`shepherd-panes.ts`'s
`terminal_*` tools) or the user (⌘D, ⌘J when the thread has none, or the panel's +), never as
splits. Internally the layout is still the `PaneNode` tree: a thread with terminals hung beside
it; a flat terminal list replaces it in phase 2. The server owns PTYs but not layouts, so
terminal requests are forwarded to the GUI via `onPaneRequest` (and `onRemotePaneRequest`) and
answered with a `PaneOutcome`. `PaneControl.swift` is the only place that serves them. Its rules
are load-bearing:

- An agent may touch only terminals in **its own** layout (`no_such_terminal` for any other id).
- Its own thread is not a terminal: it is never listed, it can never be closed or typed into
  (`not_closable`, `not_writable`), and focusing or reading it is `no_such_terminal`.
- Closing the last terminal closes the panel; the layout's thread is never closed.

**An extension-socket connection speaks only for the agent whose pi process opened it**
(ARCHITECTURE.md › Extensions and the extension socket › Who a connection speaks for). The socket
has no token and an agent's bash tool can read `SHEPHERD_SOCKET` and `agent_list`, so an
`agentID` in a message proves nothing. The server reads the peer's pid off each accepted fd once
(`LOCAL_PEERPID`, `ExtensionConnection.peerPID`; it cannot be read after a peer that closed has
gone) and, for every message that names an agent as its actor (`ExtensionMessage.speaksFor`),
serves it only when the agent's live pi has that pid (`SessionServer.isPiProcess`, looked up per
message, so a restarted pi is followed; a pi not yet bound to its thread counts for the agent it was
launched for). Anything else is answered `wrong_process` (a request) or dropped, changes
nothing, and a refused `helloAgent`, `helloChildren` or `helloBrowser` neither registers nor
displaces the real holder. One seam, `SessionServer.extensionPeerCheck`, replaces the question in
tests. The messages that name no agent (the automation requests) are not covered. A new
extension message says whose voice it is (`speaksFor`); never serve one before that check, and
never widen the rule for a process that is not an agent's pi without listing it in ARCHITECTURE.md.

**Browser tools act only on their own thread's page** ([docs/browser.md](browser.md)). No tool
names an agent: `helloBrowser` binds the extension's connection to its agent (from the agent's own
pi, by the rule above), and `SessionServer.routeBrowserRequest`
serves a request only on the connection registered as the agent it names (a design's agent
registers nothing). The page's parked window (`BrowserParkWindow`) can never be key or main and is
not offered to Mission Control, the window lists or accessibility. Native subagents load no browser tools. The
page's text is untrusted data: every result starts with a fixed notice saying so. The agent's
clicks and keys are DOM events (`isTrusted` false), never `NSEvent`s; the user's own click or key
in the page (trusted) takes the page over, and it comes back with the user's next message to the
thread (`SessionServer.onUserMessage`), never a peer's `agent_send`. `browser_open` takes `http`,
`https` and `about:blank` only.

**Agents never delete each other on their own.** `agent_delete` opens `PeerDeleteDialog`; only
its destructive button approves, by claiming the server's token (`claimAgentDeletion`) before
deleting through Delete Agent (never Delete Worktree Agent, so checkouts and branches stay).
Cancel, a lapsed token (caller cancelled or disconnected, 120 s timeout), or a second request
while the dialog is up never deletes. The live coordination tools (`agent_read`, `agent_steer`,
`agent_interrupt`, `agent_wait`) are answered by the target's own panes extension, never inferred
from saved state; the server relays each under its own token and accepts the answer only from
the target's registered connection ([docs/agent-coordination.md](agent-coordination.md)).

Shepherd does not nest agents. pi extensions own subagent execution (the bundled native runtime
is on by default), and the app only *projects* the results: the tray above the parent's
composer, two record lines in its thread, the inspector, and the palette. Subagents have no sidebar rows,
and a subagent never asks the user: its question goes to its parent agent, which answers it or asks
the user in its own thread and passes the answer down ([docs/native-subagents.md](native-subagents.md)
› Questions and results), so a child's question marks no row, posts no notification and takes
nothing over the composer. Child runs are display state and never persisted.

**Switching is a visibility flip, never a remount.** `WorkspaceSelection.mountedTabs` keeps every
mounted agent layout in the view tree, and selection only changes which one is visible (a hosting
view's `isHidden`, `nwMotionPaused`, and `isRendering`, where Ghostty occlusion stops hidden
terminals' render loops). A hidden thread suspends its store (`NativeThreadStore.suspend`) and keeps
what it shows, so showing it again rebuilds the thread and its composer once, and its first pull
catches it up without motion (docs/native-thread.md). The workspace hands each layout an
Equatable `AgentLayoutModel` and nothing observable, so a status report reruns none of them.

Each layout has a hosting view of its own (`AgentLayoutDeck`): an update in the visible one
(a scroll step, a keystroke, a streamed reply) runs its own view graph alone, and a hidden one is
an `isHidden` AppKit view, out of drawing, hit-testing and accessibility. The deck updates only
when a layout's model changes, applies it in the caller's transaction, and hands a hidden layout
the frozen size during a live resize. Before it, every layout shared one graph, and each hidden
agent added about 0.4 M instructions to a scroll step and 1.2 M to a status report
(`HiddenAgentsReport`; `ListPerformanceTests` pins the counts). Hiding a layout that holds the
keyboard gives it up first, so focus never lands on whatever AppKit picks as the next key view.
Taking a hidden host out of the window would be cheaper still, but it fires `onDisappear` (which
stops a thread's store) and replays every appearance on the way back. Things that silently bring
back full-repaint lag:

- putting the layouts back in one view graph (a `ForEach` in the workspace), or giving the deck an
  input that changes on every update
- reordering or rekeying the deck's hosts (they are keyed by tab), or removing and re-adding a
  hidden one
- applying `setRenderingActive` fire-and-forget (the model retries; see
  [NOTES.md](../Sources/TerminalSurfaceKit/NOTES.md))
- a layout view reading the view model's state instead of its model
- the shell (`RootView`, `SidebarView`) reading the raw window width or building an object per
  update: it watches `ShellLayout.layoutWidth`, which stops changing once the sidebar can't

**During a window live resize** hidden layouts keep the column size they had when it began
(`WorkspaceView.frozenSize`), so a drag relays out only the visible layout and a hidden shell
takes one grid (one SIGWINCH) when it ends. A hidden host's frame is AppKit's alone, so a frozen
layout wider than the column never widens the shell.

**At launch** only the visible layout mounts in the first frame; the rest wait in
`pendingMountTabIDs` and mount after it, two per run-loop turn, the visible space first
(`drainPendingMounts`). An agent selected before its turn mounts at once. With forty agents the
first frame built forty layouts and eighty thread bodies (about 400 ms) until it did.

The one deliberate unmount is **cold parking**, and only for a layout holding a terminal. A
layout hidden for 30 s and outside the four most recently shown
(`WorkspaceSelection.coldParkCandidates`) drops its terminals' surfaces via
`TerminalSessionStore.parkPane`. Its processes and host-side screens keep running, and
reselecting it remounts from the server snapshot. A thread-only layout never parks: it has no
surface, its hidden store polls nothing, and its `NativeThreadStore` keeps the draft and
history, so returning to it is always a flip. Measurements are in
[docs/benchmarks](benchmarks/2026-09-03-terminal-baseline.md).

**Sessions and views are separate.** Closing a terminal detaches views only. A process that exits
on its own closes its tab (an agent's pi exiting retires its agent), with one exception: an agent's pi that exits before
its thread serves (or that Shepherd stops) keeps its agent, which waits with the reason and Retry
(`SessionExit.keepsAgent`, docs/design/thread.md › Thread › Can't start). Its thread's session stays `.stopped`, so
the thread never respawns pi on its own. Delete Agent is the explicit way to terminate an
agent and its auxiliary processes while the app runs, and quitting the app terminates everything.

**Only these paths mutate repositories** ([docs/worktrees.md](worktrees.md)):

- **Creating a worktree:** `git worktree add --no-track -b` (`GitWorktree.swift`), from the New
  Agent sheet's worktree option, a project's New Worktree… sheet, or the New thread page's New
  worktree switch. The base is resolved per Settings ▸ Worktrees: `origin/<default>` after a
  fetch by default. It is visible and editable in the sheets (the page takes the resolved base),
  and recorded as `Agent.worktreeBase`.
- **Delete Worktree Agent:** confirmed, and it warns about unreconciled work.
- **Finalize Worktree** (`WorktreeFinalize.swift`): commit → push → `gh pr create` → optional
  opt-in merge → clean gate → remove worktree → delete local branch. Each step gates the next,
  nothing is destroyed before the clean gate, and the remote branch is never deleted (that would
  close the PR).
- **The Changes pane's per-file Revert** (`GitDiff.revert`, a file header's context menu):
  confirmed, local reviews of Uncommitted only. Tracked files return to HEAD, and new files move
  to the Trash.
- **Commit from review** (`ReviewCommit.swift`, served by `ShepherdViewModel+ReviewCommit.swift`
  to the Mac's own review pane and to remote clients alike): confirmed in the Commit… sheet.
  check → (new branch) → commit → (push) → (pull request); each step gates the next and git's
  or gh's stderr is reported.
  - It commits only the ticked files (`git commit --only -- <paths>`; new files join as
    intent-to-add first) and leaves anything staged for other paths staged. A failed commit takes
    back its intent-to-add entries and a branch it created.
  - It refuses a detached HEAD, a merge, rebase, cherry-pick or revert in progress, unmerged
    paths, a HEAD that moved, or a ticked file whose fingerprint changed since the sheet showed
    it. It refuses while the agent is working unless the reviewer confirmed.
  - Push goes to the branch's upstream when it has the branch's own name, else to that name on
    the push remote (origin, else the only remote), setting the upstream; never forced, and never
    to another branch (a feature branch tracking origin/main never pushes to main). A pull request pushes the branch (a new `shepherd/<slug>` branch,
    made with `git switch -c`, when on the default branch) and runs `gh pr create`.
  - It holds the checkout in `hostBusyWorktrees` while it runs, like Finalize.
- **Working-tree snapshots of the Changes engine** (`ChangesService`, [docs/changes.md](changes.md)):
  deliberate and invisible. To compare the working tree (and to record where an agent's turn
  started and ended) the engine runs `git add -A` and `git write-tree` against an index file of
  its own in the support directory (`GIT_INDEX_FILE`), seeded once from a copy of the user's, and
  `git write-tree` on a throwaway copy of the user's index for Staged and Unstaged. The only
  trace in the repository is loose objects in `.git/objects`: unreachable, pruned by `git gc`
  after its expiry. The user's index, working tree, HEAD, refs, stash and config are never
  written (`ChangesEngineTests` proves it). Untracked files over 16 MiB are left out, so nothing
  big is copied into the object store; clean filters (Git LFS) run as they would for `git add`.
- **Undo and Redo of an agent's last turn** (the "Edited N files" card, `ChangesService.undoTurn`,
  `redoTurn`): the turn's files only. Paths the turn modified or deleted return to the turn's
  starting snapshot (`git restore --source=<tree> --worktree`, through a throwaway index), and
  files it created move to the Trash; Redo reverses that until the next turn starts. Refused,
  naming the files and touching none, when any of them changed after the turn (or the Undo).
  The index, HEAD, refs, the stash and every other file stay as they are.

Nothing else mutates repository state, and Shepherd never prunes worktrees.

**Reviews dock; they don't split.** A review (`ReviewSession`, `ShepherdViewModel+Review.swift`)
is the Changes tab of the agent's side pane beside its whole layout (thread and terminals);
an inspected subagent takes the pane over and closing it goes back to Changes. It never touches
the persisted layout. **Nothing opens the pane by itself:** an agent's `review_diff` readies the
review and marks the Changes tab, and with the pane closed the header's side-pane button, with a
dot; only the user shows it (⇧⌘B, ⌃1, the button, a link).
It reads the Changes engine (`server.changes` here, `changes*` from a `changes.v1` host; a
`review_diff` naming another git reference, or an older host, loads the old way under the same
chrome). Send to agent and Ask agent to commit (Commit… on a host without commit from review)
send the agent a follow-up turn; the comments clear only once the send succeeds, so they survive a
failed send, and the pane stays (the agent's reply turns it to Last turn). Commit… commits
directly (above) and reloads the review once it finishes. A
review an agent opens on a host is that host's view state: remote viewers are deliberately not
notified and open their own with ⇧⌘B.

**Agent names settle once.** A new agent wears its opening prompt (truncated by
`ShepherdViewModel.provisionalName`) with `nameIsFinal == false`. Only such agents get the namer
extension (`SHEPHERD_NEEDS_NAME=1`). It proposes a title on the first turn, and the server
applies it once, setting `nameIsFinal`. A manual rename also sets it.

- `setAgentName` never overwrites a final name.
- Naming never blocks pi's first turn: the namer runs detached and swallows every failure.
- Agents from a pre-autoname `state.json` decode as final.
- A `setAgentSession` that moves an agent to a *different* pi session (`/new`, `/resume`) clears
  `nameIsFinal`, because the old name described the old conversation.

**Features that act on their own** are loops, background work, scheduled or unattended model
calls, evaluators and notifications: anything that keeps going without a person watching. They
spend money and time and act on what they read, so each needs these before it is a PR:

- **A default bound.** A cap on iterations, time and spend that applies unless the user raises it,
  and a test that reaches it with the worst case (a judge that never says done, a worker that
  always "progresses", a provider that is down). An unbounded default is a bug.
- **Data stays where the user put it.** Anything sent to a provider other than the thread's own is
  opt-in and shown in the UI; secrets are redacted before anything is sent, and never reach logs,
  session files or notifications.
- **Tool output, file contents, web pages and model prose are data, never instructions.** That
  includes text that reaches an evaluator: it can echo "success", so success needs evidence the
  agent cannot write itself, and a planted string must not pass it.
- **A restart never resumes unattended work.** What was running comes back paused, and the user
  resumes it. Persisted state is bounded in size.
- **Every control carries a fence.** Start, edit, stop and clear name the revision they act on and
  are refused when it is stale; limits are enforced on the host, not by the client.
- **Define and test the interactions:** Stop, Steer now, the queue, subagents (and their
  questions), retries, errors, compaction, quitting and a second client. List every combination
  that strands the feature or breaks ordinary use afterwards.
- **List every product decision nobody asked for** (a default cap, a model choice, a notification)
  under Decisions in the PR body. The user decides, as with a departure from a design.

The first such feature, Goal (PR #189), hit these traps, so the next one need not:

- **A limit stop must not abort ordinary turns.** Hitting the cap ends the feature, not the thread:
  the next ordinary turn runs as it always did. A limit that keeps aborting normal turns is a bug
  in the limit.
- **A yield or queue state needs an exit.** A state where the feature waits (for an answer, for the
  queue, for a child) names what ends it (the answer, Stop, a timeout) and a test reaches it.
  Otherwise the thread is stranded with no way out.
- **Transient provider errors are not terminal.** A rate limit, an overload or a dropped connection
  retries inside the bound and then says so; it never marks the work failed or unmet on the first.
- **A check names the model that made it.** The record of an evaluation carries the checking
  model's id and what evidence it saw; evidence that is incomplete is reported as incomplete, and
  blames the evidence, not the work.
- **A banner is restricted to active states.** A banner or pill shows while the feature is acting
  or needs the user, and does not linger over a state the thread has moved past.
- **Nothing is sent to a cheaper or other provider silently.** A feature that moves a transcript to
  another model to save cost asks first, in the UI.

Before opening the PR, run the `risk-reviewer` helper (skill `risk-review`) when installed;
otherwise review the change against this list yourself. Fix what it finds or report it.
