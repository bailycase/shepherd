# iOS client: the team's map

The iOS client's first release (iPhone and iPad) is built by feature tracks in parallel, on
top of one foundation. This page says who owns what, how screens are reached, and where one
track plugs into another's screen, so every track can open its own PR into `nightly` without
colliding. [README.md](README.md) describes the app; [VALIDATION.md](VALIDATION.md) the checks.

## The one rule

**A track edits only its own folders, plus new files anywhere under them. Everything else goes
through a hook.** A hook is a type or function with a fixed name and signature that lives in the
folder of the track that fills it; the screen that shows it just calls it. Changing a hook's
signature, or anything in a folder you do not own, is a change to this contract: say so in your
PR and update this page in the same change.

`App/iOS` is one synchronized folder in `Shepherd.xcodeproj`: a Swift file added anywhere under
it (a new subfolder included) joins the `Shepherd iOS` target without editing `project.pbxproj`.
Never commit a `project.pbxproj` change for a new file.

## Who owns what

| Track | Owns | Builds |
| --- | --- | --- |
| Foundation | `App/`, `Support/`, `Hosts/MobileHosts.swift`, `Hosts/HostTokens.swift`, `Thread/ThreadStores.swift`, `Tests/ShepherdIOSChecks/{run.sh,run-simulator.sh,MobileHostsCheck.swift,ThreadSimulatorFixture.swift,FixtureHost.swift,Fixtures/FixtureData.swift}`, this page | the shell, navigation, hosts store, fixtures harness |
| A. Home & hosts | `Home/`, `Settings/`, `Hosts/` (UI files), `Fixtures/HomeFixtures.swift`, `Fixtures/SettingsFixtures.swift` | Home, Needs you, Recents, the iPad sidebar and overview, Settings, the hosts list and form |
| B. Thread & composer | `Thread/` (not `ThreadStores.swift`), `Composer/`, `Fixtures/ThreadFixtures.swift` | the thread screen, composer, queue and steer, model and thinking, images, slash commands, the question panel |
| C. New thread | `NewThread/`, `Fixtures/NewThreadFixtures.swift` | the creation flow and Where it runs |
| D. Subagents | `Subagents/`, `Fixtures/SubagentsFixtures.swift` | the cards in a thread, the list, one run's transcript and steer |
| E. Review | `Review/`, `Fixtures/ReviewFixtures.swift`, `Fixtures/ChangesFixtures.swift`, the `DiffFile` move into a shared module | the Changes pane: scopes and the base picker, the diff reader, comments and the send bar, Commit as a turn on older hosts, Finalize, the pane docked and full screen on iPad, the "Edited N files" card's Undo |
| F. Search & actions | `Search/`, `Fixtures/SearchFixtures.swift` | search across agents, rename and delete, the iPad ⌘K palette |
| G. Commit | `Commit/`, `Fixtures/CommitFixtures.swift`, and the Commit… entry points in `Review/` | commit from review: the iPhone sheet, the iPad popover |
| H. Automations | `Automations/`, `Fixtures/AutomationsFixtures.swift` | the Automations list (Home's `.automations` destination), the iPad list and detail, one automation with its runs, the form |
| I. Windows | `Windows/`, `Fixtures/WindowsFixtures.swift` | several iPad windows: the scene, each window's navigator and restoration, Open in new window, Send to…, text dropped on a composer |
| J. Terminal | `Terminal/`, `Fixtures/TerminalFixtures.swift` | terminal panes: the iPad panel under a thread, the iPhone's full-screen panes, the key row |

Shared modules (`ShepherdUI`, `ShepherdRemote`, `ShepherdProtocol`, `ShepherdCore`) belong to no
track and are also the Mac's. A track may add to them (a component under
`Packages/ShepherdUI/Sources/ShepherdUI/Components/<Domain>/` with a `#Preview` in both
appearances, pure logic with unit tests in `ShepherdRemote`), but every such change keeps the Mac
build, the touched targets' unit tests and the affected Mac preview suites green, with Mac
visuals unchanged. Prefer a new file to editing a shared one another track may also touch.

## Navigation

One route model serves iPhone and iPad (`App/MobileRoute.swift`, `App/MobileNavigator.swift`).

```swift
enum MobileRoute: Hashable, Codable {
    case thread(AgentRef)                 // Thread track: ThreadScreen
    case home(HomeRoute)                  // Home/HomeRoute.swift
    case newThread(NewThreadRoute)        // NewThread/NewThreadRoute.swift
    case subagents(SubagentsRoute)        // Subagents/SubagentsRoute.swift
    case review(ReviewRoute)              // Review/ReviewRoute.swift
    case search(SearchRoute)              // Search/SearchRoute.swift
    case settings(SettingsRoute)          // Settings/SettingsRoute.swift
    case automations(AutomationsRoute)    // Automations/AutomationsRoute.swift
    case terminal(TerminalRoute)          // Terminal/TerminalRoute.swift
}
```

Each track owns its route enum and its destination view (`HomeDestination`,
`NewThreadDestination`, `SubagentsDestination`, `ReviewDestination`, `SearchDestination`,
`SettingsDestination`, `AutomationsDestination`, `TerminalDestination`) in its folder. **To add a screen, add a case to your own enum and handle
it in your own destination.** The shell never changes. Keep your enum `Hashable` and `Codable`
(fixtures name routes), and keep `thread` on `SubagentsRoute`, `ReviewRoute` and `TerminalRoute`: forgetting a
host closes the screens of its threads through it.

Routes today:

| Route | Shows |
| --- | --- |
| `.thread(AgentRef)` | one agent's thread |
| `.home(.needsYou / .automations / .more / .recents)` | Home's destinations, and every recent thread |
| `.newThread(.compose(host: UUID?))` | New thread (presented modally) |
| `.subagents(.list(AgentRef) / .run(AgentRef, runID:))` | a thread's runs, one run |
| `.review(.changes(AgentRef, file: String?) / .diff(AgentRef, path:))` | changes, one file's diff (the scope is the review store's: `ReviewStore.pick`, `show(turn:)`) |
| `.review(.finalize(AgentRef))` | Finalize a worktree agent (presented) |
| `.review(.commit(AgentRef))` | Commit from review (presented on iPhone; iPad uses the popover) |
| `.search(.search(query:))` | search (iPhone, pushed) |
| `.search(.palette(query:))` | the ⌘K palette (iPad, presented) |
| `.search(.rename(AgentRef) / .delete(AgentRef))` | rename, delete or Delete Worktree Agent (presented) |
| `.search(.problem(title:message:))` | an agent action from a menu that failed (presented) |
| `.settings(.root / .hosts / .host(UUID?) / .appearance)` | Settings, hosts, a host's form (nil adds one), appearance |
| `.automations(.detail(host:automation:))` | one automation, its runs, Run now and Stop (iPhone, pushed; the iPad shows it beside the list) |
| `.automations(.edit(host:automation:))` | the form: a new automation (both nil, or a host), or an existing one's fields (presented) |
| `.terminal(.panes(AgentRef))` | a thread's terminal panes full screen (iPhone; iPad shows them in the panel) |

Screens reach each other only through `MobileNavigator` (in the environment):

- `navigator.open(route)`: iPhone pushes it on the current tab's stack (Settings routes switch to
  the Settings tab); iPad makes a thread the detail and pushes anything else over it. A
  thread's runs or review (`MobileRoute.thread`) opened from elsewhere, such as Needs you or the
  palette, first makes its thread the detail, so the sidebar marks it and closing returns to it.
- `navigator.present(route)`: modal, with its own stack (New thread, forms).
- `navigator.selectedThread`: the thread on screen, for highlighting rows.
- A `NavigationLink(value: MobileRoute…)` works too; every stack applies `.mobileDestinations()`.

The shell: iPhone (compact width) is `PhoneShell`, a `TabView` with Home (`HomeScreen`) and
Settings (`SettingsScreen`), each a `NavigationStack`. iPad (regular width) is `PadShell`, a
`NavigationSplitView` with `PadSidebar` beside the detail: the selected thread, or `PadOverview`
when none is. Landscape shows both columns; in portrait the thread keeps the width and the
sidebar slides over it, and choosing a row hides it again. With no thread chosen, the sidebar
is out in portrait too.

Portrait means the window is taller than it is wide (`PadSplitLayout.sidebarOverlays`, so a
narrow Split View or Stage Manager window counts too), measured with the keyboard's safe area
ignored (`.ignoresSafeArea(.keyboard)` around the reader; each column still keeps its content
above the keyboard). The keyboard only shortens what content has left: a portrait iPad minus the
keyboard reads wider than tall, and switching the split view's style as the composer took focus
dropped the focus again, so no keyboard ever stayed up in portrait. Never key a layout mode (a
style, which columns show) off a size the keyboard shrinks; sizing within a mode (the composer's
share of the thread, the terminal panel's clamp) should follow what is left.

A change of style (turning the iPad, or resizing a window across square) builds the split view's
columns anew: the selection and pushed screens stay, but the views under them are new. So a
composer that had the focus takes it back as it mounts (`navigator.focusedComposer` and
`refocusComposer`, set by `ThreadComposer` and `PadShell`), and the keyboard stays up through a
turn mid-draft.

## App state

`MobileApp` (App/) makes the stores once and puts them in the environment. Every window shares
them except the navigator, which is each window's own ([Windows](#windows-ipad)):

| Store | Read with | Holds |
| --- | --- | --- |
| `MobileHosts` | `@Environment(MobileHosts.self)` | every host (`MobileHost`: `record`, `phase`, `state`, `session`, `capabilities`, `connectedClient`, `agent(_:)`), `add`, `edit`, `forget`, `retry`, `retryAll`, `disconnect`, `token(for:)` |
| `MobileNavigator` | `@Environment(MobileNavigator.self)` | this window's routes and selection (above) |
| `ThreadStores` | `@Environment(ThreadStores.self)` | one `NativeThreadStore` per `AgentRef`: `store(for:)`, and `viewers(for:)`, which runs its poll loop |
| `MobileAppearance` | `@Environment(MobileAppearance.self)` | System, Light or Dark |
| `MobileWindows` | `@Environment(MobileWindows.self)` | the open windows: `open` (each seed and navigator), `window(showing:except:)`, `targets(from:excluding:)` |
| `MobileApp` | `@Environment(\.mobileApp)` | `forget(host:)`, which clears a host from every store and every window |

`@Environment(\.mobileWindow)` is the window a view is in (its `MobileWindowSeed`).

- The terminal track (`MobileTerminals`) owns every client's `onOutput` and `onSessionExited`,
  wiring each new connection's client on its first attach: nothing else sets them.
- Talk to a host with `hosts.host(ref.host)?.connectedClient` (a `RemoteHostClient`). Key work
  tied to one connection on `host.session`: it changes with every new connection.
- Check capabilities with `host.supports(RemoteProtocol.…Capability)` before offering a feature.
- Run a thread's store through `threads.viewers(for: ref).run(connection: host.session) { … }`,
  never `store.run` from a screen: the same thread can be on screen in two windows, and a
  second `store.run` ends the first. A view on the connection the loop already runs over joins
  it. `viewers.rest(detached:)` is what a screen that can't run it calls (it suspends only once
  no window runs it).
- `MobileHosts`' API only grows: add members in an extension in your own folder rather than
  editing `MobileHosts.swift`, and ask the foundation to change what exists.
- A track that needs its own app-lifetime state defines an `@MainActor @Observable` store in its
  folder and reaches it without touching `MobileApp` (a `static let shared`, or one per
  `AgentRef` kept in the store itself).

## Hooks

| Hook | Lives in (filled by) | Called by | Signature |
| --- | --- | --- | --- |
| Composer slot | `Composer/ThreadComposer.swift` (B) | `ThreadScreen`, at the bottom | `ThreadComposer(ref: AgentRef)` |
| Subagent cards | `Subagents/SubagentCards.swift` (D) | `AgentTurnView`, where a turn spawned children and after it | `SubagentCards(thread: AgentRef, runs: [NativeSubagent], turnLive: Bool)` |
| Subagent routes | `Subagents/SubagentsRoute.swift` (D) | the turn footer's "N subagents", the thread's options menu | `SubagentHooks.list(thread:) -> MobileRoute`, `SubagentHooks.run(thread:runID:) -> MobileRoute` |
| Open review | `Review/ReviewRoute.swift` (E) | the changes card's Review and files, an edit line | `ReviewHooks.open(thread: AgentRef, file: String?, navigator: MobileNavigator)`; a recorded turn's card: `ReviewHooks.open(thread:turn:file:navigator:)`, the review scoped to that turn |
| Undo a turn | `Thread/TurnUndo.swift` | the "Edited N files" card's Undo and Redo | `TurnUndoStore.shared.undo(_:ref:hosts:threads:)` / `redo`, and `.turnUndoAlert()` on the thread for a refusal |
| Agent actions | `Search/AgentActionsMenu.swift` (F) | the thread's options menu (menu items only) | `AgentActionsMenu(thread: AgentRef)` |
| Commit from review | `Commit/CommitHooks.swift` (G) | the changes' bar and ••• menu, the iPad composer and full-screen toolbar | `CommitHooks.available(host:) -> Bool`, `CommitHooks.open(thread:navigator:sizeClass:)`, `.commitPopover(ref:arrowEdge:)` on the iPad's Commit… |
| Open search | `Search/SearchRoute.swift` (F) | Home, the iPad sidebar (the palette on iPad, search on iPhone) | `SearchHooks.open(query: String = "", navigator:)` |
| ⌘K | `Search/SearchRoute.swift` (F) | `MobileWindowCommands` (I), for the focused window | `SearchCommands(navigator: MobileNavigator?)` |
| Start a thread | `NewThread/NewThreadRoute.swift` (C) | Home, the iPad sidebar and overview | `NewThreadHooks.open(host: UUID? = nil, navigator:)` |
| Home roots | `Home/` (A) | `PhoneShell`, `PadShell` | `HomeScreen()`, `PadSidebar()`, `PadOverview()` |
| Settings root | `Settings/SettingsScreen.swift` (A) | `PhoneShell` | `SettingsScreen()` |
| Automations root | `Automations/AutomationsScreen.swift` (H) | `HomeDestination` for `.home(.automations)` | `AutomationsScreen()` |
| Open or add an automation | `Automations/AutomationsRoute.swift` (H) | anything that names one | `AutomationsHooks.open(_ key: AutomationKey, navigator:)`, `AutomationsHooks.create(host: UUID? = nil, navigator:)` |
| Open in new window | `Windows/WindowHooks.swift` (I) | the thread's options menu, the iPad sidebar's rows, the palette's rows and preview | `OpenInNewWindowButton(thread: AgentRef, prominent: Bool = false, before: (() -> Void)? = nil)` |
| Send to… and drag | `Windows/WindowHooks.swift` (I) | each turn in `ThreadScreen` | `.turnTransfer(_ row: NativeThreadRow, thread: AgentRef)`, `SendToMenu(text:source:)` |
| Text dropped on a composer | `Windows/WindowHooks.swift` (I) | `ThreadScreen`, on `ThreadComposer` | `.composerTextDrop(_ thread: AgentRef)` |
| Terminal panel | `Terminal/TerminalPanelView.swift` (J) | `ThreadScreen`, on its content (the transcript with the composer) | `.threadTerminal(_ ref: AgentRef)`; adds nothing in compact width |
| Terminal menu item | `Terminal/TerminalRoute.swift` (J) | the thread's options menu (menu items only; the terminal has no header button) | `TerminalMenuItems(thread: AgentRef)` |

Each hook ships with the foundation's minimal version so the app builds and navigates end to end;
the owning track replaces the body. Keep the signature. A hook drawn inside a turn
(`SubagentCards`) compares equal on its plain inputs (`Equatable`), so a streamed chunk never
redraws it unless its values changed; keep it that way.

## Windows (iPad)

iPad runs several Shepherd windows at once, side by side in Split View or in Stage Manager;
iPhone keeps one. `ShepherdIOSApp` has one scene:

```swift
WindowGroup(for: MobileWindowSeed.self) { $seed in MobileWindowRoot(app: app, seed: seed) }
    defaultValue: { MobileWindowSeed() }
```

- **A seed** (`Windows/MobileWindowSeed.swift`) is a window's identity (`id`) and the route it
  opens on (`opening`, nil for a fresh window). The system keeps it with the window's scene.
  Opening the seed of a window already open brings that window forward instead of opening one.
- **Each window has its own `MobileNavigator`** (`MobileWindowRoot`), put in the environment by
  `MobileRoot(app:navigator:window:)` with `mobileEnvironment(_:navigator:window:)`. Everything
  else is the app's and shared: `MobileHosts` keeps one connection per host whatever the number
  of windows, and `ThreadStores` one store per thread, so a draft or a loaded history is the same
  in every window. `MobileApp.navigator` is only for a root made without its own (the fixture
  harness).
- **Restoration:** each window saves `MobileNavigator.Restoration` (the layout, the tab, the
  stacks and the selected thread; not what is presented) in `@SceneStorage`, and puts it back
  when the system restores the window, leaving out the screens of hosts no longer saved. A new
  window opens its seed's route instead.
- **Connections:** `MobileWindows` tracks each window's scene phase; the hosts connect while any
  window is active and disconnect once every window is in the background (`WindowPresence`).
- **One thread in two windows** shares one poll loop (`NativeThreadViewers`): a window joins the
  loop already running over the same connection instead of restarting it (a restart would
  report the other window's send in flight as unknown), a window on a newer connection takes
  it over, and another takes it over when the driving one leaves.
- **Per window:** the navigator and the subagent inspector's selection
  (`SubagentInspection.of(navigator)`), so an inspector opened in one window leaves another's
  alone.
- **Reaching another window:** `OpenInNewWindowButton` brings forward the window already showing
  the thread, or opens one on it. "Send to…" (a turn's context menu) lists the threads other
  windows show and adds the text to that thread's composer, then brings its window forward. A
  turn also drags out as text, and a composer takes dropped text into its draft.
- **Commands** read the focused window's navigator (`@FocusedValue(\.mobileNavigator)`), set by
  each `MobileRoot`.
- The window items are drawn only where `supportsMultipleWindows` is true: never on iPhone.

## Rules every track follows

- **Design:** the boards and [DESIGN.md](../../DESIGN.md) are the authority. Tokens only:
  `Color.nw`, `Font.nw`/`.nwText`, `NW.Space`/`Radius`/`Height`, and `MobileLayout` for the
  app's own measures (add yours as an extension in your folder). No hardcoded colors, font
  sizes or dimensions in views. Reuse ShepherdUI components before hand-rolling one.
- **Touch:** 44pt targets (`NW.Height.touch`, `.nwTouchTarget(height:)`), nothing only on hover
  (`NWPlatform.showsHoverDetails` is true on iOS), VoiceOver labels, Dynamic Type, light and
  dark, iPhone and iPad.
- **State:** `@MainActor @Observable` stores; views take plain `Equatable` values and do no
  parsing or filtering in `body`; stores derive rows once per change. No `ObservableObject`.
- **Tests:** Swift Testing only. Pure logic goes into `ShepherdRemote` with unit tests; code that
  needs the app's files goes into `Tests/ShepherdIOSChecks` (see run.sh).
- **Protocol:** changes follow AGENTS.md (every Codable arm, round-trip tests, capabilities).

## Fixture screens

Every screen renders headless from fixture data (`Tests/ShepherdIOSChecks/run-simulator.sh`,
[VALIDATION.md](VALIDATION.md)). To add one, append to your track's list in
`Tests/ShepherdIOSChecks/Fixtures/<Track>Fixtures.swift`:

```swift
extension FixtureCatalog {
    static var review: [FixtureScreen] {
        [
            FixtureScreen(name: "diff",
                          routes: [.thread(FixtureData.ref(FixtureData.preview)),
                                   .review(.diff(FixtureData.ref(FixtureData.preview), path: "App/iOS/ThreadView.swift"))]),
        ]
    }
}
```

- `hosts` defaults to `FixtureData.hosts()`: Studio and build-01 online, MacBook Air offline,
  with agents and threads (`FixtureData.thread()`, `runningThread()`, `questionThread()`).
  Build your own from `FixtureData`'s builders (`user`, `assistant`, `tool`, `snapshot`).
- `routes` open in order once the online hosts connect; `presented` shows one modally; `tab`
  picks the iPhone tab; `prepare` runs anything else (a draft, an expanded row) before the shot.
- A host answers `hello`, `stateFetch`, `nativeThread` snapshots and `listModels` by itself.
  Anything else (agent queries, transcripts, creation options) comes from its `reply` closure:
  return a `RemoteReply` for the requests your screen makes, or nil to fall through.
- The fixture host refuses every request that would change a host, before a `reply` closure
  sees it, and the harness fails a screen that sends one. Screenshots must never depend on a
  mutation.
- A screen that shows a host changing (a relaunch's new layout) pushes the new state from
  `prepare`: `FixtureHost.running(hostID)?.push(state)`, as a host pushes `stateChanged`.
- Screen names are unique across tracks: prefix yours when in doubt (`review-empty`).
- A screen with more windows opens them in `prepare`: `FixtureWindows.shared.openBeside(route)`
  draws a second window beside the first, as Split View does (the simulator can't be put in
  Split View headless), and `FixtureWindows.shared.open(route)` opens a real one, which the
  simulator's full-screen mode shows over the first. Render them with `run-simulator.sh -w`.
