# Rules that are easy to break

> Read when your change touches a contract, an extension, the server's queue, terminals, the browser, layouts or repository mutation, or builds a feature that acts on its own.

Each rule says what to do and what silently breaks it. The mechanism behind a rule is in the
code; ARCHITECTURE.md says where each feature lives.

## Contracts

`ShepherdCore` and `ShepherdProtocol` couple the server, the app, the extensions and the remote
clients. Change them deliberately and update every consumer and the round-trip tests in the same
change.

- A new extension message needs its enum case, `Kind` and `CodingKeys` entries, both init/encode
  arms, a row in the protocol round-trip table, and its lines in `speaksFor` (the agent it acts
  as; `nil` only when it names none) and `replyID`. Replies (`ExtensionReply`) are the same without
  the last part. Remote messages follow the same rules, plus the capabilities, both clients and the
  listener tests ([remote-protocol](remote-protocol.md)).
- A new `SessionServer` mutation needs an integration test.
- New persisted fields decode with defaults, so older `state.json` files keep loading.

## Embedded extensions have one copy

`Extensions/` holds every pi extension and node script Shepherd ships, and the design skill in
`Extensions/design-skill/`. `Sources/ShepherdSessions/Extensions` is a symlink to it, declared as a
processed resource. SwiftPM flattens the filenames into `Shepherd_ShepherdSessions.bundle`;
`EmbeddedExtensions.source(name)` resolves logical paths by basename. Each `*Extension.swift` installs its file into the support directory (or the private pi
home, for `GoalExtension` and `ServiceTierExtension`) and rewrites it when
the content differs. Editing a `.ts` file is the whole change.

- Extensions stay dependency-free and inert without their environment variables.
- They never throw into pi or keep the process alive (unref sockets and timers).
- The panes extension speaks the request/reply half of `ExtensionMessage`/`ExtensionReply`: extend
  both enums, `SessionServer.handleLine` and the protocol tests together.

## Design tokens only

Never hardcode a color, font size, dimension, duration or chord in a view. Colors are `Color.sh.<role>`;
fonts `Font.sh(_:)` or `.shText(_:)`; spacing, radii and heights `SH.Space`, `SH.Radius`, `SH.Height`;
a Mac screen's own dimensions `AppLayout+<Domain>.swift`; a component's own measures its metrics enum
in ShepherdUI. Status colors come from `AgentState` (`textColor`, `color`, `tint`), never a role with an
alpha. A new color is a role on `ThemeColors` in both variants with a contrast rule if it carries text.
A glyph more than one view draws is an `SHGlyph` case, named once. ShepherdUI imports no Shepherd module.

`DesignRulesTests` fails on a literal font size, a status color with `.opacity(…)`, a raw color and a
registered glyph named as a string. `DesignRuleAllowlist` only shrinks: never add an entry for code
you wrote.

## State is Observation

The stores are `@MainActor @Observable` classes, owned with `@State` and bound with `@Bindable`.
Never `ObservableObject`, `@Published`, `@StateObject` or `@ObservedObject` in the Mac app or the
iOS client (TerminalSurfaceKit's `TerminalSurfaceModel` is the one exception, because Ghostty's is).

- Observe only what views draw: bookkeeping is `@ObservationIgnored`, and a property is written
  only when its value changes, so a poll or a status report never re-renders a view it didn't touch.
- Views take plain `Equatable` values and do no parsing, filtering or highlighting in `body`; stores
  derive rows once per change. Menus read cached values from `MenuState`.
- A list that can outgrow a screen is a lazy stack whose `ForEach` makes exactly one view per
  element (wrap an `if` or `switch` in a container); highlight and selection arrive as a `Bool`,
  hover stays in the row, closures stay out of `==`. Add a `ListPerformanceTests` budget with any
  new long list.

## Keybindings resolve through the store

Menus, palette keycaps, Settings ▸ Keyboard and the Ghostty unbind list all read `KeybindingsStore`;
a chord in a view is a bug. A rebound chord includes ⌘ (⇧⇥ for Cycle thinking is the exception) and
avoids ⌘1–9, ⌘, and the system chords. Every chord the chrome uses is in `appOwnedChords`
(`TerminalSurfaceModel.swift`), or a focused Ghostty surface eats it. Rebinding reconfigures live
surfaces in place, never a remount.

## Server concurrency

One serial queue owns all server state; every `PTYSession` and `RPCSession` queue targets it, so
callbacks, extension handlers and remote connections exclude each other without locks.

- Never `.sync` between these queues: it deadlocks.
- The main thread never waits on the server queue. `SessionServer.state` is the copy `StateStore`
  publishes under a lock; code on the queue reads `store.state`.
- Nothing slow runs on the queue: records of 256 KiB or more decode on a concurrent queue, in order.
- Attach is atomic: snapshot, registration and output watermark in one queue turn.
- Callbacks hop to the main queue in FIFO order; never call them from the server queue. `onThreadRevision`
  is paced (once per display frame) and carries no state.
- As its host's client, the app never blocks the main thread on `host.sock`: every
  request is async, as to a paired Mac.

## PTY children

`PTYSession` resets every child signal disposition to `SIG_DFL` and clears the mask before exec,
with async-signal-safe calls only. Otherwise children inherit ignored dispositions and every kill
escalates to SIGKILL.

## Module boundaries

- Only `Sources/ShepherdApp/TerminalHost.swift` imports TerminalSurfaceKit, and only `DesignHost.swift`
  imports DesignSurfaceKit. Never import GhosttyTerminal beside TerminalSurfaceKit.
- Boards are untrusted HTML and JS: each design renders in its own non-persistent store, loads only
  through `shepherd-design://<design>/`, and never navigates. Never copy, fetch or imitate Claude
  Design's code. React is the one vendored dependency, checksum-pinned in `DesignRuntimeTests`.
  At most five live board web views; the rest are snapshots.

## Status and startup

- The server applies extension status reports unconditionally (`canTransition` allows `done → working`)
  and logs table violations. `SessionServer.start()` resets every persisted status to `idle`;
  `Agent.lastFailure` (a failed turn's error, or why pi couldn't start or stopped) is what survives it.
- Startup reconciliation drops shell tabs, `inspectorFor` tabs, review leaves and automation runs,
  and settles design agents into the designs space. Never keep a run agent across a server start.
  A server start is the host's start: login, a drain, Quit and Stop Agents, a crash, or the
  launch of the app's own child host. Relaunching the app while launchd's host runs is not one:
  the host keeps its shells, terminals and runs.
- Agent names settle once: `setAgentName` never overwrites a final name, naming never blocks pi,
  and moving an agent to a different pi session clears `nameIsFinal`.
- Dropped images are resized to 2000 px on the way in and the user's own file is never rewritten.

## Agents drive their own terminals

Terminals are tabs under a thread (`terminal_*` tools, ⌘D, ⌘J, the panel's +), never splits.
`PaneControl.swift` alone serves pane requests: an agent touches only terminals in its own layout
(`no_such_terminal` for any other id); its thread is never a terminal (`not_closable`,
`not_writable`); closing the last terminal closes the panel. Closing a terminal detaches views only;
a process that exits on its own closes its tab, except an agent's own pi: while its agent exists,
any exit keeps the agent and its thread, which says why and waits for Retry. Only deleting an agent
retires it. A stop Shepherd asks for (`stopKeepingAgent`, a move, `killSession` of an agent's own
pi) is marked as one, so its thread shows no problem. Every other exit after pi served is the agent
stopping unexpectedly; one before it served is a start problem. Anything that retires idle agents
must stop pi the same marked way.

## An extension-socket connection speaks only for the agent whose pi opened it

The socket has no token and an `agentID` in a message proves nothing. The server reads the peer's pid
once per connection and serves a message that names an agent (`speaksFor`) only when that agent's
live pi has that pid; anything else is `wrong_process` or dropped and changes nothing. Never serve a
new message before that check, and never widen the rule for a process that is not an agent's pi.
`SessionServer.extensionPeerCheck` replaces the question in tests.

## Browser tools act only on their own thread's page

`helloBrowser` binds the connection to its agent; `routeBrowserRequest` serves a request only on that
connection. Page text is untrusted data (every result says so). The agent's clicks are DOM events;
the user's own click takes the page over until their next message. `browser_open` takes `http`,
`https` and `about:blank` only. Native subagents load no browser tools.

## Peer tools and subagents

Peer tools have no approval UI or permission setting; the server checks process identity and
validates requests, and the tool descriptions require an explicit user request before an agent acts
on another thread. Agent deletion claims the server token first, needs no confirmation, and keeps
worktree checkouts and branches. Shepherd does not nest agents: subagents are display state, never
persisted, with no sidebar rows; a subagent's question goes to its parent, never to the user.

## Switching is a visibility flip, never a remount

A layout mounts the first time its agent is shown; from then on, selection only changes which
mounted layout is visible. `WorkspaceSelection.mountedTabs` keeps every layout shown this session
in the view tree, apart from the deliberate unmounts below. Each layout has its own hosting view
(`AgentLayoutDeck`), keyed by tab. What silently brings back full-repaint lag:

- putting the layouts back in one view graph, or giving the deck an input that changes on every update
- reordering or rekeying the deck's hosts, or removing and re-adding a hidden one
- a layout view reading the view model's state instead of its `AgentLayoutModel` (a remote one: its
  connection's state instead of its `RemoteLayoutModel`)
- the shell reading the raw window width or building an object per update

At launch only the visible layout mounts, and nothing but showing an agent mounts one. An agent
nobody has opened has no mounted layout, so nothing may wait for its layout to draw: its pi, its
terminals (a terminal a tool or another device opens starts its own shell), its browser page, its
status and notifications, and remote clients all work without one. During a live resize hidden
layouts keep their frozen size. The deliberate unmounts are cold parking, only for a layout holding
a terminal (`WorkspaceSelection.coldParkCandidates`), and a Project's threads, which its Project
page draws: its coordinator never mounts here, and a worker only while it is the one open.

A hidden thread keeps its host, page, history and draft, but its rows are bounded: past
`NativeThreadStores.mountedBudget` (an eighth of the memory, at most 2 GiB, counted by
`NativeThreadStore.mountedCost`) the least recently shown hidden threads let their rows go
(`releaseTranscript`), one thread a pass and `releaseStep` bytes of it, and not while the person types
or scrolls, however long that lasts, or while a thread on screen, local or remote, streams
(`NativeThreadStores.busy`: only a stream gives out, after ten seconds a pass, so that a long one cannot hold the budget off for
good): unpinned ones first, then readers left scrolled up beyond the two most recently shown; the thread shown before the current one, and the one on screen, never. A thread
keeps its last screen built (`NativeThreadStore.keptRows`: at most four rows within 16 MiB, or a last
row of up to 64 MiB alone; a larger reply goes with the rest), which still counts against the budget. Showing one draws that last screen in the pass that shows it and
builds nothing there (the deck lays the host out as it unhides one that let rows go, so no frame
has the layout without them; a thread whose rest costs no more than a step draws it all there instead);
the rows above come back after that frame, newest first, a step of
rows at a time (`ThreadRestore`, which also waits for keystrokes and for a reader away from the tail,
and starts again from the last screen if a pass lets its rows go again meanwhile), with the thread
at the bottom of its window while it does (`ThreadTailAnchor`), and a reader taken
this way comes back at its tail. The pass
loads, sends and resumes nothing. Each of the local and the remote thread stores has its own budget.

A remote agent's thread (a paired Mac's, or this Mac's own while the app is the background
service's client) is a page of its own deck (`RemoteLayoutDeck`), keyed by `RemoteAgentRef`. A page
mounts the first time it is shown in that deck and stays while its host has the agent; nothing
mounts one hidden. Hidden, its thread stops polling, its subagent inspector stops following and
its terminals detach, so a hidden page never counts toward the host's smallest-viewer grid; shown
again, they attach and the host replays their screens. A host's designs, its utility terminal and
Project workers still draw over the deck and rebuild when shown.

## Only these paths mutate repositories

Worktree add (`GitWorktree.swift`), Delete Worktree Agent (confirmed), per-file Revert in the Changes pane (confirmed),
Commit from review (`ReviewCommit.swift`: only the ticked files, refuses a dirty HEAD state, never
force-pushes), a shared design's own repository under `<designs>/.git/<id>/`, the Changes engine's
snapshots (its own index file; the user's index, tree, HEAD, refs and stash are never written),
Undo and Redo of a turn (the turn's own files only: what changed while it ran, less what Shepherd wrote for the person; while another agent's turn ran in the same working tree, another agent's edit, write or subagent landed in it, or the person ran a branch action or a commit in it, only the files its own edit and write calls (and its own subagents) named and no other call or subagent named; refused when any changed since), Save in the Files
tab (`FileTreeModel.save`: the person's Save, Save chord or Overwrite; one existing local text file inside
the thread's folder, written in place only while it still holds the version the editor expected; a paired
device's Save reaches the host's server as `fileWrite`, `ThreadFileSystem.save`, under the same rule), Add child project
(one empty directory), an explicit project folder transfer, and Issues & PRs' GitHub changes
(`Forge/ForgeService.swift`, each on the person's click, through their gh with `--repo` from `/`, so
no local checkout or branch is touched; bodies go on stdin): comment, review, merge (method, merge
when ready, and deleting the head branch on GitHub only when the person ticks it), Clean up's
deletion of a merged pull request's head branch on GitHub (never a fork's), convert to draft and
mark ready, close and reopen, edit a title, and re-run a run's failed jobs. Its Remove the worktree
is the confirmed Delete Worktree. The branch card's actions (`BranchGit.swift`, in the agent's own
checkout, each on the person's click; branch names pass `check-ref-format` and never reach git as
options): Commit (`commit --only` of the ticked files, new ones intent-to-add first and taken back
if the commit fails; refused while a rebase or merge is stopped), Amend the last commit (`commit
--amend`; refused with no commit or while a rebase or merge is stopped; once a remote-tracking ref
has the commit, Commit & push is off and the card's Push is refused, never forced, with how to
replace it by hand), Push (`push -u origin` of the current branch, never forced), Update from the base (fetch
the base, then rebase or merge onto it; refused on a dirty tree; a conflict stops, and Abort runs
`rebase --abort` or `merge --abort`), Switch branch (`switch`, a remote branch to a tracking local
copy), New branch from here (`switch -c`), Rename branch (`branch -m`, local only), and Fetch from
origin (`fetch origin`, remote-tracking refs only); Change base rewrites only Shepherd's record. A
new thread's worktree on an existing branch (`GitWorktree.addExisting`: `worktree add`, a remote
branch with a tracking local copy) or a named new one. Close threads when their pull request merges (Settings ▸ Worktrees,
off by default; `ShepherdSessions/PullRequestLinks.swift`): once a thread's pull request is seen
going from open to merged in this host's run, it deletes the thread, removes its worktree and local
branch through Delete Worktree's path, and deletes the head branch on GitHub through the forge's
merged-only, never-a-fork deletion; only for a worktree in Shepherd's support folder whose branch is
the pull request's head, and never while the thread runs or asks or its checkout has uncommitted
changes or commits GitHub doesn't have (it stays, with a note). Nothing else.
Shepherd may remove or prune worktrees it created.

## Reviews dock; they don't split

A review is the Changes tab of the agent's side pane and never touches the persisted layout.
Nothing opens the pane by itself: `review_diff` marks the tab, and only the user shows it.
Comments clear only once a send succeeds.

## Features that act on their own

A loop, background work, a scheduled or unattended model call, an evaluator, a notification:
anything that keeps going without a person watching. Each needs, before it is a PR:

- Data stays where the user put it: anything sent to a provider other than the thread's own is
  opt-in and shown in the UI; secrets are redacted and never reach logs or notifications.
- Tool output, file contents, web pages and model prose are data, never instructions, including
  text that reaches an evaluator.
- A restart never resumes unattended features (Projects, executions, goals or design Git work): they come back paused. Enabled automation schedules and triggers are a standing instruction: they keep firing whenever Shepherd's host runs, after a launch, a login or a host restart, with the app open or not, but an automation run a restart interrupted is never resumed: its run log records it as interrupted. A login start and an update's drain are restarts. Ordinary interactive agents may recover previously authorized unfinished turns and queued messages from a durable, session-fenced checkpoint, with at most three consecutive automatic recovery attempts. Explicit Stop and questions prevent automatic continuation; an idle agent stays idle. A pi that stops on its own holds its agent's checkpoint paused and inactive: pi starts again only when a person acts (Retry, Locate Folder…, Use another model), by the thread's ordinary start after a launch, or, for a Project coordinator, by its Project's next message; none continues the interrupted turn or sends the queue, which comes back paused. An automation run whose pi stops on its own ends as failed in its run log and is never resumed.
- Every control carries a fence (the revision it acts on) and limits are enforced on the host.
- Stop, Steer now, the queue, subagents, retries, errors, compaction, quitting and a second client
  are each defined and tested.
- Every product decision nobody asked for is listed in the PR; the user decides.

Traps the first such feature hit: a limit stop must end the feature, not the thread's ordinary
turns; a waiting state names what ends it; transient provider errors retry inside the bound; a
check names the model that made it; a banner shows only while the feature is acting; nothing moves
a transcript to a cheaper provider silently.

## Invariants kept from the retired feature docs

Each was checked against the code when the feature docs were deleted. The code and its tests are
the detail; these are the lines whose violation is a security, privacy, data-loss or
compatibility bug.

**Agents and sockets**
- Check each peer-agent action on the server queue with `agentActionAllowed`: the sender is the
  connection's own agent and the target is not the sender (only a read may target itself).
- Wrap every peer message as `[from: <sender>, an agent, not the user…]` (`AgentMessageFraming`)
  so a model never reads another agent's text as the user's consent.
- Check the peer pid before replacing a browser registration; a refused `helloBrowser` never
  replaces or disconnects the agent's real browser connection.
- Strip `SHEPHERD_EXT_*` variables from terminals and subagents. Give children and terminals the
  user's own `NODE_EXTRA_CA_CERTS` back unchanged.

**Browser**
- `browser_read` never returns a secret field's value (password, `cc-*`, `one-time-code`,
  `current-password`, `new-password`, `-webkit-text-security`): it shows `value=[hidden]`.
- A page navigates its own main frame only to `http`, `https`, `about` or `blob`; any other scheme
  it starts (`file:`, `javascript:`, `data:`), history steps included, is cancelled.

**Designs**
- Serve a design socket message only to the agent whose `designID` is that design
  (`not_your_design`), and validate the board path before any read.
- Never relay `comment_reply`, `markup_propose` or `checkpoint_restore` from a helper; only the
  design's own agent may call them.
- Viewer comments reach the design agent behind `DesignCommentFence`, as their own message, never
  inside a running turn and never as a pi command.
- Never follow a symlink in `design-systems/` or design files. Only the owning design writes a
  system (`not_your_system`); built-ins are read-only (`read_only_system`).
- Restore and undo only while each board still has the hash `ifCurrent` names (`stale_revision`).

**Repositories**
- Every client-sent revision or base passes `ChangesService.isSafeName`, so it never reaches git
  as an option. Remote clients may not set a review `cwd`.
- Worktree branches are created `--no-track`, never force-reset, with full `refs/heads/` refs
  passed as arguments to `/usr/bin/git` by absolute path.

**Projects**
- Refuse Project or Space file requests from a client that has not acknowledged `projects.v2`,
  before any file access; keep serving `projects.v1` hosts.
- Refuse to publish an artifact that contains secret-bearing text. Publication opens each path
  component `O_NOFOLLOW`, refuses links and special files, and creates `O_EXCL`.
- Address a remote executor only when host ID and persisted `bindingID` both match; never fall
  back to a local path or agent. An owner without placement support refuses a host argument.

**Secrets and diagnostics**
- MCP secrets live in Shepherd's Keychain; config files hold only `${keychain:<server>/<NAME>}`.
  Import moves plaintext secrets into the Keychain and never writes them back.
- Never write a secret into the private home's `mcp.json`; `bin/pi` keeps refusing
  `pi mcp add` and `pi mcp remove`.
- iOS stores each host token as a `WhenUnlockedThisDeviceOnly` Keychain item, never in
  UserDefaults.
- Diagnostics start only after explicit opt-in in a configured build and never restart in the
  same process after opt-out. Each consent has its own cache directory, so a report from before
  opt-out is never sent after a later opt-in.
- Diagnostics never collect prompts, replies, tool output, terminal or file contents, command
  lines, process names, paths or argv, and accept no third-party transaction.

**Wire compatibility**
- Strip designs, design agents and their layouts from remote state unless the host serves
  `designs.v1` and the client reads designs.
- Always encode agent `runtime: "rpc"`, so older clients never attach a terminal bridge.
- Send `initialImages` only to hosts with `agent.create.images.v1`, in one 1 MiB frame.
- Keep decoding the legacy goal `checking` state, `checkedBy`, confirmation fields and
  `goalCrossProviderEvaluation`; never emit them. Remote goal controls need `native.goal.v1`.
