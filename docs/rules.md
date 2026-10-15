# Rules that are easy to break

> Read when your change touches a contract, an extension, the server's queue, terminals, the browser, layouts or repository mutation, or builds a feature that acts on its own.

Each rule says what to do and what silently breaks it. The mechanism behind a rule is in the
feature's own doc or in ARCHITECTURE.md.

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
resource, so the files ride in `Shepherd_ShepherdSessions.bundle` and `EmbeddedExtensions.source(name)`
reads them. Each `*Extension.swift` installs its file into the support directory (or the private pi
home, for `CLIProxyAPIExtension`, `GoalExtension` and `ServiceTierExtension`) and rewrites it when
the content differs. Editing a `.ts` file is the whole change.

- Extensions stay dependency-free and inert without their environment variables.
- They never throw into pi or keep the process alive (unref sockets and timers).
- The panes extension speaks the request/reply half of `ExtensionMessage`/`ExtensionReply`: extend
  both enums, `SessionServer.handleLine` and the protocol tests together.

## Design tokens only

Never hardcode a color, font size, dimension, duration or chord in a view. Colors are `Color.nw.<role>`;
fonts `Font.nw(_:)` or `.nwText(_:)`; spacing, radii and heights `NW.Space`, `NW.Radius`, `NW.Height`;
a Mac screen's own dimensions `AppLayout+<Domain>.swift`; a component's own measures its metrics enum
in ShepherdUI. Status colors come from `AgentState` (`textColor`, `color`, `tint`), never a role with an
alpha. A new color is a role on `ThemeColors` in both variants with a contrast rule if it carries text.
A glyph more than one view draws is an `NWGlyph` case, named once. ShepherdUI imports no Shepherd module.

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
  new long list ([performance](design/performance.md)).

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
  and logs table violations. `SessionServer.start()` resets every persisted status to `idle`.
- Startup reconciliation drops shell tabs, `inspectorFor` tabs, review leaves and automation runs,
  and settles design agents into the designs space. Never keep a run agent across launches.
- Agent names settle once: `setAgentName` never overwrites a final name, naming never blocks pi,
  and moving an agent to a different pi session clears `nameIsFinal`.
- Dropped images are resized to 2000 px on the way in and the user's own file is never rewritten.

## Agents drive their own terminals

Terminals are tabs under a thread (`terminal_*` tools, ⌘D, ⌘J, the panel's +), never splits.
`PaneControl.swift` alone serves pane requests: an agent touches only terminals in its own layout
(`no_such_terminal` for any other id); its thread is never a terminal (`not_closable`,
`not_writable`); closing the last terminal closes the panel. Closing a terminal detaches views only;
a process that exits on its own closes its tab, except a pi that exits before its thread serves,
which keeps its agent with Retry.

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
`https` and `about:blank` only. Native subagents load no browser tools ([browser](browser.md)).

## Peer tools and subagents

Peer tools have no approval UI or permission setting; the server checks process identity and
validates requests, and the tool descriptions require an explicit user request before an agent acts
on another thread. Agent deletion claims the server token first, needs no confirmation, and keeps
worktree checkouts and branches. Shepherd does not nest agents: subagents are display state, never
persisted, with no sidebar rows; a subagent's question goes to its parent, never to the user
([native-subagents](native-subagents.md)).

## Switching is a visibility flip, never a remount

`WorkspaceSelection.mountedTabs` keeps every mounted layout in the view tree; selection changes
which one is visible. Each layout has its own hosting view (`AgentLayoutDeck`), keyed by tab. What
silently brings back full-repaint lag:

- putting the layouts back in one view graph, or giving the deck an input that changes on every update
- reordering or rekeying the deck's hosts, or removing and re-adding a hidden one
- a layout view reading the view model's state instead of its `AgentLayoutModel`
- the shell reading the raw window width or building an object per update

During a live resize hidden layouts keep their frozen size. At launch only the visible layout mounts
in the first frame; the rest mount two per run-loop turn. The one deliberate unmount is cold parking,
and only for a layout holding a terminal (`WorkspaceSelection.coldParkCandidates`).

## Only these paths mutate repositories

Worktree add (`GitWorktree.swift`), Delete Worktree Agent (confirmed), Finalize Worktree (each step
gates the next; the remote branch is never deleted), per-file Revert in the Changes pane (confirmed),
Commit from review (`ReviewCommit.swift`: only the ticked files, refuses a dirty HEAD state, never
force-pushes), a shared design's own repository under `<designs>/.git/<id>/`, the Changes engine's
snapshots (its own index file; the user's index, tree, HEAD, refs and stash are never written),
Undo and Redo of a turn (the turn's files only; refused when any changed since), Add child project
(one empty directory), and an explicit project folder transfer. Nothing else, and Shepherd never
prunes worktrees ([worktrees](worktrees.md), [changes](changes.md)).

## Reviews dock; they don't split

A review is the Changes tab of the agent's side pane and never touches the persisted layout.
Nothing opens the pane by itself: `review_diff` marks the tab, and only the user shows it.
Comments clear only once a send succeeds.

## Features that act on their own

A loop, background work, a scheduled or unattended model call, an evaluator, a notification:
anything that keeps going without a person watching. Each needs, before it is a PR:

- A default bound on iterations, time and spend, and a test that reaches it with the worst case
  (a judge that never says done, a provider that is down). An unbounded default is a bug.
- Data stays where the user put it: anything sent to a provider other than the thread's own is
  opt-in and shown in the UI; secrets are redacted and never reach logs or notifications.
- Tool output, file contents, web pages and model prose are data, never instructions, including
  text that reaches an evaluator: success needs evidence the agent cannot write itself.
- A restart never resumes unattended work: it comes back paused.
- Every control carries a fence (the revision it acts on) and limits are enforced on the host.
- Stop, Steer now, the queue, subagents, retries, errors, compaction, quitting and a second client
  are each defined and tested.
- Every product decision nobody asked for is listed in the PR; the user decides.

Traps the first such feature hit: a limit stop must end the feature, not the thread's ordinary
turns; a waiting state names what ends it; transient provider errors retry inside the bound; a
check names the model that made it; a banner shows only while the feature is acting; nothing moves
a transcript to a cheaper provider silently.
