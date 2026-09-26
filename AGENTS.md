# AGENTS.md: working on Shepherd

Shepherd is a native macOS app (SwiftUI, macOS 26+) for running and supervising many `pi` coding
agents.

- **Agents:** every agent is `pi --mode rpc` on pipes, owned in-process (`RPCSession` and
  `RPCThreadState` in `ShepherdSessions`), and rendered only as a native thread
  (`Sources/ShepherdApp/Thread/`). There are no terminal agents and no Terminal/Native switch.
- **Terminals:** the only terminals are panes of an agent's layout, opened by the user with ⌘D or
  the terminal panel's + or by an agent's `pane_*` tools. The Mac shows them in the terminal panel
  under the thread (tabs, split, maximize, ⌘J to show or hide; DESIGN.md › Terminal panel), as
  does the iPad; the iPhone opens them full screen. On the Mac they are real PTYs rendered with
  libghostty; the iOS client attaches to the host's over the remote protocol and renders them
  with SwiftTerm. There are no global shells and no space shell workspaces.
- **Spaces** are projects: the folders threads start in. The sidebar has no tree; it lists
  destinations (New thread, Automations, More ▸ Hosts and Extensions), then Needs you and Recents
  (every agent, local and remote, most recently active first). The New thread page's workplace
  chip lists each host's spaces, flat. With no agent on screen, the main column shows New thread.
- **Lifetime:** there is no daemon. Sessions live and die with the app. On relaunch the workspace
  (spaces, agents, pane layouts) restores from `state.json`, every agent resumes its pi session
  over RPC, and every terminal pane respawns a fresh shell.
- **Remote:** Shepherd can serve its agents to other devices over an authenticated TCP listener
  (off by default). The main use is running projects on one Mac and driving them from another
  Mac running Shepherd. The iPhone and iPad client (`App/iOS`) drives them the same way.

**Read [DESIGN.md](DESIGN.md) before touching any UI.** It is the authority on visuals and
interaction. DESIGN.md is the written form of the design canvas, and a change to how the UI looks or
behaves updates DESIGN.md in the same change. [ARCHITECTURE.md](ARCHITECTURE.md) maps modules,
ownership, and data flow.

## Build, run, test

There is deliberately no Makefile or Taskfile. One Xcode project at the repo root runs the apps,
and plain SwiftPM drives everything else.

**The Mac app:** open `Shepherd.xcodeproj`, pick a scheme, choose My Mac, and Run. The Mac target
is a shim (`App/ShepherdLauncher.swift` calls `ShepherdMacApp.main()` from the `ShepherdApp`
library). There is no `swift run` path for the GUI.

A stable Shepherd and a development build cannot share state. The socket and `state.json` live
in the support directory, and the server refuses to bind over a live socket. So there are three
Mac schemes:

| Scheme | Config | App | Support directory |
| --- | --- | --- | --- |
| `Shepherd (Dev)` | Debug | Shepherd | `~/Library/Application Support/Shepherd-dev` (the scheme sets `SHEPHERD_SUPPORT_DIR`) |
| `Shepherd (Prod)` | Release | Shepherd | `~/Library/Application Support/Shepherd` |
| `Shepherd (Nightly)` | Nightly | Shepherd Nightly | `~/Library/Application Support/Shepherd Nightly` |

⌘R on Dev never disturbs the agents in your everyday copy. The Debug configuration also has its
own bundle id, `com.bailycase.shepherd.dev`, because preferences, delivered notifications and
Sparkle's installer are keyed by bundle id: on a shipped id, every Dev launch would prune the
installed app's collapsed spaces and clear its notifications, and a setting changed in Dev
would change it there. `ShepherdEdition` reads the Dev id as Shepherd, and Debug builds have no
updater. `Tests/Release` holds the Debug id apart from both shipped apps'. `Shepherd iOS` builds
the iPhone and iPad client ([docs/ios](docs/ios/README.md); who owns which folder, the routes and
the hooks are in [docs/ios/CONTRACTS.md](docs/ios/CONTRACTS.md)).

**Shepherd Nightly** is the same code built as a second app, so it installs and runs beside
Shepherd. The `Nightly` configuration is Release plus its identity: bundle id
`com.bailycase.shepherd.nightly` (so its own preferences domain), product name
`Shepherd Nightly`, `App/AppIconNightly.icon`, and the `appcast-shepherd-nightly.xml` feed.
Everything else keys off the bundle id through `ShepherdEdition` (`ShepherdProtocol`): the
support directory, the listener's default port (7434 instead of 7433), the window's name, and the
update channel. It starts with an empty support directory; nothing is copied from Shepherd's.
Info.plist takes the executable, the names, and the feed file (`SHEPHERD_APPCAST`) from build
settings, and each configuration compiles only its own icon.

```bash
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -onlyUsePackageVersionsFromResolvedFile build
swift build                                  # every package target
swift test --filter UnitTests                # fast tier: seconds
swift test --filter IntegrationTests         # real server, stub pi, git, off-screen windows
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests
swift test                                   # everything (previews skip without SHEPHERD_PREVIEW_DIR)
CI=true swift test --no-parallel             # what CI runs (in four shards): serially, timing-sensitive tests skipped
PI_PACKAGE_DIR="$(npm root -g)/@earendil-works/pi-coding-agent" node --test Tests/Extensions/*.test.mjs
python3 -m unittest discover -s Tests/Release   # the release workflow's rules (scripts/release.py), CI's stale-link check
```

**Environment variables:**

- **`SHEPHERD_SUPPORT_DIR`** moves the support directory: the socket, `state.json`, installed
  extensions, `remote-token`, `automation-runs.json`, Settings ▸ Instructions' files
  (`instructions/`), Settings ▸ Skills' state and git caches (`skills/`), designs (`designs/`;
  docs/designs.md), design systems (`design-systems/`), and subagent artifacts. It wins over the edition's own folder
  (`Shepherd`, or `Shepherd Nightly` in Shepherd Nightly).
- **`SHEPHERD_SKILLS_DIR`** moves the skills folder Settings ▸ Skills manages (default
  `~/.agents/skills`, the folder pi reads skills from; docs/skills.md). Tests point it at a scratch
  folder; pi itself always reads `~/.agents/skills`.
- **`SHEPHERD_THEME=night-watch-dark|night-watch-light`** forces an appearance at launch (the
  older `shepherd-dark` still means dark), which is handy for screenshots. Resetting settings
  returns to it.
- **Set by the app for pi, never read from the user's environment:**
  - Always: `SHEPHERD_AGENT_ID`, `SHEPHERD_SOCKET`, `SHEPHERD_EXT_STATUS`,
    `SHEPHERD_INSTRUCTIONS_DIR` (where the instructions extension reads Settings ▸ Instructions'
    `AGENTS.md` and `APPEND_SYSTEM.md`).
  - With the matching extension on: `SHEPHERD_EXT_PANES`, `SHEPHERD_NATIVE_CHILDREN`,
    `SHEPHERD_EXT_CHILDREN`, and `SHEPHERD_CHILD_*`.
  - Per agent: `SHEPHERD_NEEDS_NAME`, `SHEPHERD_AUTOMATION`, `SHEPHERD_MODEL`,
    `SHEPHERD_SUGGEST_FILES` (the files its `suggest_instruction` may draft a line for, while
    Settings ▸ Experiments ▸ Suggested instructions is on for its kind of agent), and, for an
    agent that draws a design, `SHEPHERD_DESIGN_ID` and `SHEPHERD_DESIGN_SKILL_DIR` (the design
    skill the app writes to the support directory's `design-skill/`; docs/designs.md).
- **`SHEPHERD_PR_DESCRIPTION_MODEL`** overrides the model that drafts finalize PR bodies.
- **`SHEPHERD_PREVIEW_DIR`**, **`SHEPHERD_LIVE_MODEL`**, and **`SHEPHERD_PERF_REPORT`** switch on
  the preview renders, the live-model run, and the long-list timing report (see Testing).
  **`SHEPHERD_BENCHMARK`** switches on the benchmarks that print timings: `ComposerMenuBenchmarkTests`
  (the composer's menus over a full model catalog), `DataPathBenchmarks` (the server's data path),
  and `PiSessionFileTests`' runtime-state check.
- **`SHEPHERD_DESIGN_CANVAS`** points `DesignCanvasFidelityCheck` at a design folder (one holding
  `project/canvas.json`): it renders every board at its canvas size, with Google Fonts, reports
  what each drew, and with `SHEPHERD_PREVIEW_DIR` set writes each snapshot to
  `design-canvas/<board>.png` there, to compare by eye against the canvas's own thumbnails.
  `DesignStyleEditTests` reads it too, to splice every element of every board of that canvas
  (the folder, or its `project/`).
- **`SHEPHERD_TIMING_TESTS=1`** runs the timing-sensitive tests even where `CI=true` skips them
  (see Testing).
- **`PI_CODING_AGENT_DIR`** is pi's own: it moves pi's config and sessions away from
  `~/.pi/agent`. Shepherd follows it (`PiConfig.agentDirectory`) when it seeds session headers
  and reads pi's models and settings.

## Testing

Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), never XCTest.
Tests come in tiers, and the switch is `--filter` on target names.

| Tier | Targets | What belongs there |
| --- | --- | --- |
| Unit | `ShepherdCoreUnitTests`, `ShepherdProtocolUnitTests`, `ShepherdUIUnitTests`, `ShepherdRemoteUnitTests`, `ShepherdSessionsUnitTests`, `ShepherdAppUnitTests`, `ShepherdCLIUnitTests`, `TerminalSurfaceKitUnitTests`, `DesignSurfaceKitUnitTests` | Pure logic |
| Integration | `ShepherdSessionsIntegrationTests`, `ShepherdAppIntegrationTests`, `DesignSurfaceKitIntegrationTests` | Real processes, sockets, git, windows, web views |
| Previews | `ShepherdPreviewTests` | Offscreen renders of every surface |

**Unit tests** must not use `Process`, sockets, `SessionServer.start()`, `NSWindow` or
`NSHostingView`, git, timers, `Task.sleep`, or polling.

- A tiny scratch file is fine when the unit under test *is* a file format (state.json decoding, a
  pi session file).
- Each test should run well under 50 ms, and a whole target well under a second.
- Prefer table-driven `@Test(arguments:)`, with explicit inputs: never `shuffled()` or random data.
- Unit targets may use `Tests/ShepherdTestKit`, which depends on no Shepherd module:
  `ScratchDefaults`, `makeScratchDirectory()`, `Locked`, `CommandFailure`, and `TestProcess` (the
  process's scratch paths).

**Integration tests** use the helpers in `Tests/ShepherdTestSupport`, which re-exports
`ShepherdTestKit`:

- `ScratchServer`: a real `SessionServer` on scratch paths that records every broadcast state.
  A remote `listModels` gets a fixed stand-in catalog, never pi's (`SessionServer(modelCatalog:)`).
- `StubPi.command`: runs `Resources/stub-pi.py`, a scripted `pi --mode rpc` driven by prompt
  keywords (`ask`, `select`, `hang`, `die`, `big`, `slow`, `widgets`, `fill`, `newsession`, …).
  `STUB_PI_LOG` records what it received, and `STUB_PI_HISTORY_BYTES` seeds a long history.
  `STUB_PI_STARTUP_DELAY`/`_GATE`/`_EXIT` hold or fail its boot (`stub-pi-startup.json` in its
  cwd does the same for a pi launched the way the app launches it).
  `StubPi.installOnPath()` puts it first on `PATH` as `pi` (answering `--list-models`) for code
  that launches pi the way the app does.
- `makeScratchRepo()` and `git(_:in:)`: a git repository with one commit. A failing git call
  throws `CommandFailure` with git's stderr.
- `makeScratchDirectory()`: a `mkdtemp` directory inside the process's scratch root, short
  because `sun_path` caps socket paths at 104 bytes.
- `ExtensionClient`: a raw extension-socket client.
- `eventually("what", …)` and `eventuallyOnMain`: named 10 ms polls that throw `WaitTimeout`
  saying what never happened. Never sleep a fixed amount; wait on a callback or `eventually`.
  Keep timeouts generous (they default to 30 s), but make the happy path fast.
- Every integration and preview suite is time-limited to two minutes per test, so a hang fails
  the test that hung, by name.
  - Most suites carry `.integrationTimeLimit`.
  - `@MainActor` suites carry `.mainActorExclusive` instead. Those tests share the one main
    thread, so they run one at a time across suites while everything else stays parallel. The
    trait starts the clock only when a test gets its turn. Never add a `.timeLimit` beside it:
    that clock also runs while the test waits in the queue, so tests near the back would fail
    without having hung.
- `.serialized` orders the tests inside its own suite and nothing more. It does not isolate a
  suite from any other: every suite of a target (with SwiftPM's native build system, of every
  target) shares one process.

**Process-wide state is set once, never by a test.** Tests never call `setenv`, `unsetenv`,
`signal`, `chdir`, or `umask`, or change any other global that a concurrent test could observe.

- When a test bundle loads, before any test runs, `Tests/ShepherdTestIsolation` (linked through
  `ShepherdTestKit`) points `SHEPHERD_SUPPORT_DIR`, `SHEPHERD_SKILLS_DIR`, `PI_CODING_AGENT_DIR`,
  and `ZDOTDIR` at a scratch root for that process, and clears the agent-only `SHEPHERD_*` variables a run started
  from a Shepherd agent inherits. It also puts a `bin/` first on `PATH`, holding stand-ins for
  `gh` and `pi` that refuse to run, and the scratch `ZDOTDIR`'s `.zshenv` and `.zlogin` keep it
  first in every zsh a test starts. Without them, a login shell from a minimal environment
  (Xcode, launchd) reaches the user's own `gh` and `pi`, because the system startup files
  rebuild PATH. The root is removed at exit.
- A target depends on `ShepherdTestKit` when the code it tests can reach the support directory,
  pi's directory, `UserDefaults`, the drop directory, or a shell. With the swiftbuild build
  system each target is its own test bundle, so a target without it gets no isolation.
- Otherwise pass state in: `ShepherdPaths.supportDirectory(environment:)`,
  `PiConfig.agentDirectory(environment:)`, `TerminalImageDrop.resolve(_:directory:)`.
- A test that needs process-wide state anyway (a signal disposition) or blocks the main queue runs
  as an exit test, in its own process: `await #expect(processExitsWith: .success) { … }`.
  Expectations inside the body are reported as usual. Wrap the body in `recordingErrors { … }`:
  an error thrown out of it kills the child with SIGTRAP, and the parent reports only the signal.
- A store that takes `UserDefaults` gets `ScratchDefaults()`, never `UserDefaults(suiteName:)`
  with a name. Its suite is a plist in the scratch root; a named suite leaks into
  `~/Library/Preferences`, because cfprefsd writes a removed domain back after its plist is
  deleted.

**Previews** render every surface (thread states, review, palette, settings, sheets, sidebar,
empty states) in light and dark to `$SHEPHERD_PREVIEW_DIR/<surface>-<light|dark>.png`. They are
skipped when the variable is unset. Look at them after a UI change; they exist so an agent can
see its work.

- Each domain has its own suite in `Tests/ShepherdPreviewTests` (`ThreadPreviewTests`,
  `NavigationPreviewTests`, `AgentsPreviewTests`, `ReviewPreviewTests`, `SettingsPreviewTests`,
  `DesignPreviewTests`), and `PreviewTests` holds the rest. A capture can't draw a web view, so
  the design previews draw every board from its snapshot (`designLiveCap = 0`). Add a new surface's render to its domain's suite.
- `--filter ThreadPreviewTests` (or any one suite) renders just that domain.
- ShepherdUI's components also have `#Preview`s (`Packages/ShepherdUI/Sources/ShepherdUI/Previews/`)
  for Xcode's canvas; the Debug build's Component Gallery shows the base components live.

**Timing-sensitive tests** check a real rule, but a slow machine can fail them without a
regression, so they carry `.timingSensitive` and CI skips them. `TimingTests.enabled` is false
when `CI=true` (GitHub Actions sets it) unless `SHEPHERD_TIMING_TESTS=1`; every local `swift test`
runs them.

- **Frame sampling:** the motion suites (`*MotionTests`, `MotionProbeTests`, `ThreadHoverTests`)
  must catch a motion between its two ends. A busy shared runner may not, and CI's VM drew slides
  as fades.
- **Wall-clock budgets:** `ComposerMenuPerformanceTests.openingAndClosingTheModelPickerTakeLittleTime`.
- **Instant rules stay on CI:** a terminal's one PTY resize per slide, switching agents as a
  visibility flip, streamed text appearing at once. Their motion controls, which prove the check
  is not vacuous, are separate `.timingSensitive` tests or expectations under
  `if TimingTests.enabled`. So is a count that only measures speed (`OutputDeliveryTests`'
  merged deliveries); the rest of such a test runs everywhere.
- Never mark a test timing-sensitive to hide a short wait: give it a condition to wait on and a
  timeout that fits what the code does.
- On a CI machine, `SHEPHERD_TIMING_TESTS=1 swift test` runs them too.

**Live model:** the opt-in use-case run against a real model is gated on `SHEPHERD_LIVE_MODEL`
(e.g. `cpa/~anthropic/claude-haiku-latest`). It never runs by default.

**Long lists** (DESIGN.md › Performance) are measured, not guessed:

- `NWRenderProbe` (ShepherdUI, debug builds only) counts row bodies while a test records:
  `let _ = NWRenderProbe.tick("sidebar.row")` at the top of a row's `body`. It also counts
  derivation passes that must not scale with a change (`sidebar.spaceScan`, `sidebar.spaceForest`).
- `ListPerformanceTests` pins each long list's budget as a count of rows built or redrawn
  (opening, scrolling, a highlight or a selection moving, one row changing, a reply streaming).
  Counts hold on a slow or busy runner; timing budgets do not, so don't add those. Two thread
  budgets differ on macOS 26 (CI) and in Xcode 26 builds whatever the speed, so there they run
  as known issues.
- `DesignPerformanceTests` pins the design canvas the same way over a 172-board canvas: at most
  six web views open (five live, one rasterizing), panning recycles them, and one board changing
  redraws one frame (`design.board`) with one snapshot; a Tweak drag redraws no frame and its
  release only the tweaked board's; a board dragged redraws only its own frame, once per step. The Designs grid's and the Comments tab's budgets are in
  `ListPerformanceTests` (`design.card`, `design.comment`).
- `SHEPHERD_PERF_REPORT=1 swift test --filter ListPerformanceReport` prints each list's timings
  against large fixtures (`Support/ListFixtures.swift`). `ListPerf` times a change's update,
  layout, and display, and scrolls a list a step at a time by moving its clip view.

**The server's data path** is pinned by counts too: the server queue held by a test hook
(`SessionServer.holdQueue`, `beforeOffQueueDecode`) while reads, connects, and other agents are
served; revisions pushed per change; and, in debug builds, the bytes a commit rehashes and the
JSON encodes a snapshot makes (`RPCThreadState.bytesHashedByLastCommit`,
`encodesByLastSnapshot`). Timings are opt-in: build with `swift build -c release -Xswiftc
-enable-testing --build-tests`, then `SHEPHERD_BENCHMARK=1 swift test -c release --skip-build
--filter DataPathBenchmarks` prints a history's decode, projection and release, a delta's cost
beside many tool results, snapshot round trips, a status report's CPU, the server queue's
latency while a long history reloads, and a relaunch of agents with long histories.

**Extension tests** (`Tests/Extensions/*.test.mjs`, Node's test runner) need `PI_PACKAGE_DIR`
pointing at the installed pi package. They isolate `HOME` and use a local fake provider.
`native-children.smoke.mjs` is an opt-in real-model smoke (`PI_SMOKE_MODEL`).
`Tests/ShepherdIOSChecks` holds the iOS client's scripts ([docs/ios/VALIDATION.md](docs/ios/VALIDATION.md)).

**Release rules** (`Tests/Release/test_release.py`, Python's `unittest`, stdlib only) test
`scripts/release.py`: what each trigger builds (the manual TestFlight run included), which feeds
each release lands in, the legacy aliases, `verify-app`, `verify-ios`, and which TestFlight builds
`retire-testflight` expires (against a local fake App Store Connect). They also read the
Xcode project, `App/Info.plist`, `App/iOS/ExportOptions.plist`, `ShepherdEdition.swift`,
`AppUpdater.swift`, and the Release workflow (its `testflight` input included), so a bundle id,
feed name or signing setting that drifts from the script fails before a release builds.

**Tests never take the user's focus or drive their mouse or keyboard.**

- Windows sit off-screen (`x: -30_000, y: -30_000`), borderless, and ordered back
  (`orderBack`).
- Never call `makeKey` or `orderFront`, and never post synthetic mouse or keyboard events.
- Nothing touches the user's support directory, preferences, pi configuration or sessions,
  `~/.agents/skills`, `$TMPDIR/shepherd-drops`, or a running Shepherd.

**Which tier a change needs:**

- A model, parser, projection, presentation rule, keybinding, or search change needs a unit test.
- A server mutation, process lifecycle, socket, remote-protocol behavior, or git flow needs an
  integration test.
- A visible change needs a preview render checked in both appearances, and a run of the Dev
  build.

Name each test as a sentence of the behavior (`deletingASpaceKeepsNestedSpaces`), and test
contracts rather than copy text. When a test exposes a real bug, keep it running: wrap the
failing part in `withKnownIssue("…")`, tag the test `.bug(…)`, and report it. Unlike
`.disabled`, a known issue still runs, so the test says when the bug is fixed.

**Coverage that must not be dropped:**

- **Round trips:** every `ExtensionMessage`/`ExtensionReply` and `RemoteRequest`/`RemoteReply`
  case (table-driven), plus the `NativeThread` wire types against the golden
  `Tests/Extensions/native-thread-wire.json`.
- **Designs:** canvas.json round trips with unknown keys (the Shepherd canvas among them), the
  board path grammar, and element numbering against the golden `Tests/Designs/element-ids.json`,
  by `DesignTemplate` and by the board runtime (the tids it stamps in a real web view). The board
  sandbox (what a board may reach, and that no navigation leaves it), live reload without a
  navigation, and the vendored React's pinned checksums. In the app: the live-view plan and its
  recycling, the Designs page's cards, design rows in the sidebar (no ⌘-digit; their agents have
  no row), New design and opening a design, the visibility flip, one pushed revision per write,
  and only the changed board reloading. Comments: finding a comment's element again after a
  rewrite (by path and words, else detached), their fence, a comment waiting in the host queue
  while the agent works, and the agent's reply attaching under its pin. Tweak: the style splice
  round-tripping on the real fixture boards (only style attributes change, every tid and path
  kept), token snapping, the data-props values in canvas.json, one write per gesture, the
  stale-revision retry, Reset and Undo, and each board's kept versions. Board actions: a drag
  written once where the board lands, Duplicate adding one board (file and entry, one revision),
  Variations reaching the agent with the board fenced in its record, a Play link moving between
  the design's boards only (a real board view), and pages and notes shown a page at a time.
  Design systems: tokens.json in both shapes (unknown keys kept), the stylesheet reader's lines,
  re-sync, Night Watch complete for every role in both variants, installing into a design (and
  never over a folder installed from elsewhere), system_write only by the owning design's agent,
  the project only read, `<x-import>` in a real board view, and design_check's off-system values
  with their lines. In the app: the systems grid and a system's page (sources, counts, specimens
  as boards), a build from a scratch repository leaving it byte-identical, More ▸ Design systems,
  and New design's tokens-file detection.
  Export: the count following the ticks, a ZIP's contents (pages, tokens.css, uploads, the
  canvas as a project folder that imports again), a PDF's pages (fixed and flow), @2x images,
  boards attached to a thread; import's path rules, unknown keys kept, and a refused folder
  leaving nothing behind.
- **Server:** every `SessionServer` state mutation.
- **Changes:** every scope on a scratch repository, the proof that reading changes leaves the
  index, HEAD, refs, the stash, `.git` and every file alone, and Undo, Redo and the refusal on a
  turn the stub pi made.
- **Core:** the status transition table, `PaneNode` operations, and state validation.
- **Migration:** terminal-era `runtime` keys, global shells and space shells dropped at startup,
  and review leaves.
- **Extensions:** embedded extensions byte-identical to `Extensions/*` (all thirteen, and the
  design skill's two files).
- **Themes:** every theme variant complete, and the WCAG contrast rules met.
- **App logic:** keybindings (defaults, validation, stored overrides for removed actions
  ignored), palette and settings search, workspace selection and parking, sidebar ordering and
  reveal, review rows and diff parsing, `PiSessionFile` paths, and child runs.
- **Updates and editions:** each channel's feed and Sparkle tag, the channels each app offers,
  the launch migration of every stored channel (`UpdateChannelStore`: rc and nightly to Beta,
  the nightly notice armed once), the support directory and listener port per edition, and the
  release rules (every trigger, feed routing, the legacy aliases).

CI (`.github/workflows/ci.yml`) runs on pull requests and pushes to `master`, skipping the
timing-sensitive tests. Docs-only changes (`docs/**`, `*.md`) don't trigger it.

- **Shards:** four `macos-26` jobs each build (`.github/actions/swift-build`) and run
  `swift test --skip-build --no-parallel` over their share of the suites. W, R and A take the
  App integration suites their regexes name (`W_RE`, `R_RE`, `A_RE` in the workflow); C `--skip`s
  all three and runs everything else, so a new or renamed suite always lands in C. Each shard
  lists its suites' times in the run's summary: when the slowest shard beats the fastest by more
  than 20 s over two runs, move a suite. A shard that runs no tests fails, and so does a C whose
  count differs from what `swift test list` leaves after the three regexes (a dead `--skip`).
- **Serial within a shard:** on the shared 3-core runner, a parallel run queued tests behind one
  another's main-thread work until their waits ran out. A watchdog samples a test host still
  running after 10 minutes, then ends the run.
- **Release rules** run on `ubuntu-latest` (stdlib Python). The `CI` job passes only when every
  shard and the release rules did; it is the one check to require.
- **Caches:** dependency checkouts (keyed on `Package.resolved`) and build products (one entry per
  commit, restored from the nearest earlier one) are cached apart. `scripts/ci_mtimes.py` puts
  each unchanged source's saved mtime back after checkout, so a restored build compiles only
  what changed. SwiftPM's native build system reruns a target only when a *direct* dependency's
  module changes, so a change to `ShepherdCore` could leave `ShepherdProtocolUnitTests` (which
  calls it through `ShepherdProtocol`) compiled against the old one: undefined symbols at link,
  or wrong field offsets that link fine. It reproduces locally with the native build system,
  cache or not. The action therefore removes the restored `swift-version-*.txt`, an input of
  every compile command, so each target's driver runs and recompiles what any module it loaded
  changed (a few seconds when nothing did). A link that still fails with undefined symbols and no
  other error (`scripts/ci_stale_link.py`, tested in `Tests/Release`) gets a `::warning::` and
  one rebuild from scratch that keeps the dependency checkouts; a compile error fails at once.
  A push to `nightly` runs no tests: its `warm` job builds from scratch and saves
  both caches where every PR based on `nightly` can read them. Pull requests save nothing, so
  every push to one restores that entry and compiles the PR's changes on top; a PR into
  `master` reads only `master`'s. Master pushes and manual runs save from shard C, before its
  tests (never on `nightly`, where the warm job saves). Run the workflow by hand with `clean` to
  ignore the build cache. A corrupt cache: bump `CACHE_EPOCH` in the action to orphan every
  entry, build and dependencies, or clear one
  ref's with `gh cache delete --all --ref refs/pull/N/merge` (or `refs/heads/<branch>`).
- **Checking a CI change:** a pull request's run is cold ("Cache not found") until `nightly`
  holds an entry for the same toolchain and epoch, and it saves nothing, so it cannot show an
  incremental build. Before merging, run the workflow by hand on the branch, let it finish (a
  second run on the same ref cancels the first), push a small source change, and run it again:
  its shards restore the first run's entry by prefix, "Restore source mtimes" reports about as
  many new or changed files as the push touched, and the build compiles only their modules. A
  rerun of an unchanged commit is an exact hit and tests nothing. After the merge, the `warm`
  job's entry should be what the next push to any PR into `nightly` restores.

## Source map

```text
App/
  ShepherdLauncher.swift   Mac @main shim.   Shepherd.entitlements   iOS/  the iPhone and iPad client
  Info.plist               names, executable, and feed from build settings
  AppIcon.icon, AppIconNightly.icon   Shepherd's and Shepherd Nightly's icons
Sources/
  ShepherdCore/        Models (Space, Tab, Agent, Automation, Design, ShepherdState), typed IDs, PaneNode
                       (binary split tree; LeafPane carries sessionID/cwd/agentID), AgentStatus +
                       canTransition, ThinkingLevel, SessionRuntime, StateValidation, Reorder.
                       No deps.
  ShepherdProtocol/    ExtensionMessage/ExtensionReply (+ ChildRun, PaneInfo, …), RemoteMessage
                       (RemoteRequest/RemoteReply, RemoteProtocol version + capabilities),
                       NativeThread (requests, results, NativeThreadSnapshot), NativeThreadContext
                       (the context and compactions), RPCWire (pi's
                       JSONL, lenient), Framing (NDJSON, LineBuffer, 1 MiB cap), ShepherdPaths,
                       ShepherdEdition (Shepherd or Shepherd Nightly, from the bundle id),
                       Instructions (Settings ▸ Instructions' files, history and requests),
                       Suggestions (Settings ▸ Experiments ▸ Suggested instructions),
                       Skills (Settings ▸ Skills: installed skills, repositories, requests),
                       HostSettings (a host's settings as a client sees and changes them),
                       DiffFile (a diff's files, hunks and lines), Changes (the Changes pane's
                       scopes, lists, turns and base picker on the wire), DiffWords (word diffs),
                       the Design tool's format (docs/designs.md): DesignIndex (canvas.json v3,
                       unknown keys kept), DesignPath (the board path grammar), DesignTemplate
                       and DesignElementID (a board's elements as `File.dc.html#tid:path`),
                       DesignBoardCheck (what a board may hold), DesignStyle/DesignTokens/DesignProps
                       (Tweak: inline-style splices at parser offsets, token snapping, data-props
                       and canvas.json's tweaks), DesignCanvasLayout (pages, notes, where a
                       duplicate goes), DesignFiles (snapshots, reads, write results),
                       DesignSystemTokens (a design system's tokens.json in Shepherd's schema or a
                       canvas's own shape, tokens.css, the stylesheet reader, re-sync),
                       DesignSystemFiles (a system's files, record, listing, writes),
                       DesignExport (Export's boards, names, what a ZIP carries, tokens.css),
                       DesignPrint (a board's print mode, a flow document's pages) and DesignImport
                       (a Claude Design folder's path rules).
  ShepherdRemote/      RemoteHostClient, NativeThreadStore (@Observable), NativeThreadPresentation,
                       NativeTurnPresentation (a turn's items), NativeMarkdown (the prose
                       parser: tables, lists, images, details, footnotes), NativeActivity
                       (activity lines, the changes card), NativeQueueRules (the queue's rules,
                       host and client), NativeContextPresentation (the context ring, its
                       details, compaction lines), NativeQuestionDock (a question's kind, what
                       its asker takes, the answer and the dock's keys),
                       TerminalPanel (a layout's terminal tabs, the key row's bytes, the panel's
                       height, RemoteTerminalLink), AutomationPresentation (automation rows, runs
                       and what a client may do), AgentBranchPresentation (the header's branch
                       chip), ChangesPresentation (the send bar, the review message, the "Edited
                       N files" card from a recorded turn), InstructionsText (an instruction
                       file's size, diff, changed lines, highlighting and suggested lines),
                       InstructionsPresentation (its host chips and rows),
                       SuggestionsPresentation (Experiments' words), ClientSettings (the iOS
                       client's Settings models: a host's settings, its instructions and
                       suggestions over the remote protocol), HostSettingsPresentation,
                       ClientSkills (Settings ▸ Skills' model on every platform),
                       DesignSystemPresentation ("synced 4m ago", a token's source), SkillsText
                       (SKILL.md's frontmatter, prompt tokens, repository references),
                       SkillsPresentation (its words), SkillsDirectory (skills.sh), ShepherdLog.
                       Shared with the iOS client.
  ShepherdPTYSpawn/    The PTY child side (fork → exec) in C: no Swift runs between the two.
  ShepherdSessions/    SessionServer (state, sessions, extension socket, remote listener),
                       RPCSession, RPCThreadState (+Queue: the queue of messages sent while pi
                       works; +Context: what fills the context, compactions), ThreadOriginStore (where delivered messages came from, kept per pi
                       session), AutomationRunLog (each automation's runs), PTYSession,
                       SessionScreen (SwiftTerm), StateStore,
                       PaneRequest (pane/review/automation requests + outcomes), RemoteFileUpload,
                       PiModelCatalog, PiConfig, PiSessionPreview (a thread from pi's session file),
                       InstructionsStore (Settings ▸ Instructions' files and their history),
                       SuggestionsStore (Suggested instructions: settings, waiting, added),
                       SkillsStore (a host's skills in ~/.agents/skills; docs/skills.md),
                       SkillsGit (the partial clones skills install from),
                       Changes/ (ChangesService: the Changes pane's engine — scopes, snapshots,
                       diffs, the base picker, each agent's turns and their Undo; docs/changes.md),
                       DesignStore (each design's files in the support directory's designs/, on
                       its own queue, with a revision per design, each board's last 20
                       versions, its comments.json, and installed systems under ds/; what an
                       export reads; a Claude Design folder imported; docs/designs.md),
                       DesignSystemStore (design systems in the support directory's
                       design-systems/, their owners and sources, built-ins).
  TerminalSurfaceKit/  Ghostty adapter for terminal panes; see its NOTES.md.
  DesignSurfaceKit/    The Design tool's board renderer (macOS and iOS; docs/designs.md): DesignSurface
                       (a design's sandbox: a non-persistent data store, the shepherd-design://
                       scheme), DesignBoardView (one board's WKWebView: load, replaceSource,
                       snapshot, events; + DesignBoardExport: a standalone page, @2x image and PDF
                       pages, DesignPDF), DesignSchemeHandler, DesignRoute and DesignSandbox (what
                       is served; the CSP and content rules), DesignRuntime. Resources: Shepherd's
                       board runtime (shepherd-dc-runtime.js), the isolated bridge
                       (shepherd-dc-bridge.js), and React 18.3.1 UMD (MIT, pinned).
  ShepherdApp/         The Mac app:
    ShepherdApp.swift (the Window scene, AppDelegate), RootView (+ WorkspaceHeaderView),
      SidebarView (+ SidebarModel: destinations, Needs you, Recents, footer), NewThreadPage (+
      NewThreadModel), ThreadHeader, WorkspaceView, WorkspaceSelection (+ MainDestination),
      RightPaneSplit and SidePane (the side pane and its tabs), CheckoutMonitor (each agent's
      branch and changed files, read off the main thread), AppCommands (menus, MenuState),
      AppDialogs (every sheet)
    AppLayout (+Navigation, +Thread, +Agents, +Settings, +Pages, +Designs; ShellLayout's adaptive
      rules live in +Navigation), AgentStateMapping (app lifecycles → AgentState)
    ShepherdViewModel(+Navigation, +Creation, +Workspace, +Spaces, +Palette, +Shell,
      +RightPane, +Review, +ChildInspector, +Automations, +Dialogs, +RemoteActions,
      +RemoteInspection, +RemoteWorktrees, +RemoteAutomations, +Terminal, +HostSettings,
      +Skills, +Pages, +AgentMenu, +Designs (opening, New design's NewDesignState, revisions),
      +DesignSystems (a system's page, "Build one from a repo", Re-sync, specimens),
      +DesignExport (Export, Attach to a thread, Import Claude Design Folder…))
    Pages/             the sidebar destinations' pages: AutomationsPage, HostsPage and DesignsPage
                       (views over AutomationsPageModel, HostsPageModel and DesignsPageModel,
                       derived per change), their destinations (PageDestinations: runs read,
                       sheets), AutomationEditorSheet, PageHeader (every page's header, New
                       thread's too)
    The Design tool (Settings ▸ Experiments ▸ Design tool; docs/designs.md): NewDesignPage,
      DesignScreen (a design agent's layout: the canvas beside its chat, and the toolbar),
      DesignScreenModel (a design's canvas state and its pulls; the board actions, moves,
      Present and Play, pages), DesignHost (the only DesignSurfaceKit import: live views, the
      rasterizer, snapshots, thumbnails, tweak previews, the presented board, DesignExporter),
      DesignExportSheet (DZExport's sheet over the window, its model), DesignTweak (the Tweak tab's controls, pure), DesignTweakModel (its writes,
      one per gesture, Reset and Undo), DesignTweakPane, DesignProjectTokens (the
      custom properties a design agent's folder declares), NightWatchSystem (Night Watch as a
      built-in design system, from ShepherdUI's tokens), DesignSystemCatalog (the host's systems
      as last read), DesignSystemPageModel (DZSystem as values; specimen boards), DesignSystemPage
      (the Design systems page, a build's layout beside its chat, the header)
    TerminalPanels (each layout's terminal panel: shown, tab, maximized, activity),
      TerminalPanelLayout (TerminalPanelGeometry, pure), TerminalPanelViews (strip, divider)
    Thread/            ThreadView, ThreadTurns, ThreadTools (activity lines), ThreadMarkdown,
                       Composer, QuestionDock (a question in the composer's place),
                       QueueStack ("Up next", the queue above the composer),
                       ContextMeter (the ring beside Send, its details, compaction lines),
                       Subagents, SubagentPresentation, SubagentInspector
    TerminalSessions (TerminalSessionStore), AgentStartQueue (launch order of restored pi),
      TerminalHost (the only TerminalSurfaceKit import),
      NativeThreadStores (+ LegacyTerminalAgents), PaneControl, PaneFocusMemory
    DiffReview (ReviewSession, ChangesEngine, ReviewPaneModel), DiffReviewView (ReviewPane: the
      Changes pane), ChangesRows (split and unified rows, folds), ChangesMenus (scope, commits,
      base and options menus), GitDiff, CodeHighlight (tree-sitter)
    ReviewCommit (ReviewCommitGit, ReviewCommitter), ReviewCommitSheet, +ReviewCommit
    GitWorktree, WorktreeFinalize, ChecklistStatus, NewWorktreeSheet, FinalizeWorktreeSheet,
      NewAgentSheet, RemoteWorktreeSheet, RemoteDirectoryPicker, DialogSheet,
      QuitConfirmation (QuitDialog)
    CommandPalette, CommandPaletteView, PaletteContentSearch, Keybindings (KeybindingsStore)
    SettingsView, SettingsWindow, SettingsComponents, Settings{Appearance, Terminal, Agents,
      Worktrees, Pi, Instructions, Skills, Remote, Keyboard, Advanced, Experiments}, AppSettings,
      InstructionsModel (the Instructions page's files, drafts and sync), InstructionsEditor (its
      NSTextView), SuggestionsModel (the Experiments page's suggestions), SkillsSheets (Browse
      skills.sh, Add from repo)
    Themes (ThemeManager, ShepherdTheme), ShepherdThemeMarker, ShellIntegration, ComponentGallery
    RemoteHostStore, AgentPeers, AgentNotifications, ChildRuns, PiSessionFile, PiUpdateManager,
      AppUpdater (Sparkle: UpdateChannel, UpdateChannelStore, ChannelDelegate),
      NightlyMovedNotice
    Status/Namer/Panes/Review/Subagents/Children/Inspect/Instructions/DesignExtension.swift
      embedded extensions (DesignExtension also carries the design skill)
  shepherd-cli/        `shepherd --import herdr` (writes state.json while Shepherd is not running).
Packages/
  ShepherdUI/          Night Watch, its own local package (module ShepherdUI; macOS 26, iOS 27;
                       SwiftUI only, imports no Shepherd module):
                       Tokens/       ThemeDefinition, NightWatch, ThemeStore, Colors (NWPalette,
                                     Color.nw), Typography (NWTextStyle, Font.nw, NWFonts,
                                     NWProseSize), Metrics (NW.Space/Radius/Height), Motion,
                                     Elevation (.nwCard/.nwPopover/.nwFocusRing, NWHairline),
                                     AgentState, HexColor
                       Resources/Fonts  Geist and Geist Mono (SIL OFL)
                       Components/   Controls, Status, Containers, Navigation, Thread, Composer,
                                     Agents, Review, Dialogs, Automations, Skills, DesignTool
                                     (NWDesignCanvas, NWBoardFrame, NWCanvasToolbar,
                                     NWDesignCard, NWDesignSystemChip, NWDesignHeader,
                                     NWCommentPin, NWCommentThread, NWCommentCard,
                                     NWBoardActions, NWDirectionTile, NWCanvasNote,
                                     NWBoardPresentation, NWSectionRail, NWTokenSwatch,
                                     NWTypeSpecimen, NWComponentSpecimen,
                                     NWDesignSystemBuildTile)
                       Previews/     a #Preview per component, light and dark
                       Diagnostics/  NWRenderProbe (row-body counts for tests; debug only)
                       Its unit tests live in the root package (Tests/ShepherdUIUnitTests).
Extensions/            Canonical pi extensions (TypeScript/ESM, dependency-free):
  shepherd-status.ts      status + active pi session       shepherd-namer.ts   agent titles
  shepherd-panes.ts       pane_*, agent_* (list/send/spawn/read/steer/interrupt/wait/delete),
                          automation_*, notify; see docs/agent-coordination.md
  shepherd-review.ts      review_diff (readies the side pane's Changes tab)
  shepherd-subagents.ts   setAgentChildren (native + pi-subagents runs)
  shepherd-children.ts (+ -config, -ui, shepherd-workflow, shepherd-missions, shepherd-inspect.mjs)
                          native subagent runtime; see docs/native-subagents.md
  shepherd-instructions.ts  Settings ▸ Instructions' AGENTS.md and APPEND_SYSTEM.md, added to
                          every session Shepherd starts (never ~/.pi/agent); suggest_instruction
                          (Settings ▸ Experiments ▸ Suggested instructions)
  shepherd-design.ts      the design agent's design_read, board_write, canvas_update,
                          design_check, comment_list, comment_reply, system_read and
                          system_write; hands pi the design skill
                          (design-skill/: SKILL.md, format.md); see docs/designs.md
Tests/
  <Module>UnitTests/, *IntegrationTests/, ShepherdPreviewTests/   the tiers above
  ShepherdTestIsolation/  C, run when a test bundle loads: scratch root, PATH, ZDOTDIR
  ShepherdTestKit/        ScratchDefaults, makeScratchDirectory, Locked, CommandFailure, TestProcess
  ShepherdTestSupport/    ScratchServer, StubPi (+ Resources/stub-pi.py), ExtensionClient,
                          QueueFixture (a host's queue without pi), eventually, recordingErrors,
                          the time-limit and timing-sensitive traits
  Extensions/             node tests for the bundled extensions (+ native-thread-wire.json)
  Designs/                design fixtures: real and synthetic boards, the Shepherd canvas.json,
                          and element-ids.json (WebKit's numbering of each board's elements)
  DesignSurfaceKitIntegrationTests/Fixtures/  a small design (loops, conditionals, an import)
  Release/                Python tests for scripts/release.py
  ShepherdIOSChecks/      the iOS client's scripts
scripts/               release.py (the release workflow's rules), sign-app.sh (release
                       signing), sync-embedded-extension.py, ci_mtimes.py (CI's incremental builds)
Vendor/libghostty-spm/ GhosttyTerminal (prebuilt libghostty)
```

## Data flow

- **The in-process `SessionServer` is the single source of truth** for spaces, per-agent layout
  tabs, agents, and automations (persisted to `state.json`). It owns every PTY and RPC process.
- **The local GUI** calls the server directly, with no socket, and adopts `onStateChanged`
  broadcasts. It owns only view state: selection, focus, collapsed spaces, the side pane,
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
- The opening prompt is the first native `send`, not a positional argument. The host holds it
  (`SessionServer.sendOpeningPrompt`) and sends it the moment pi serves, so every client's first
  snapshot shows it; the client that created the agent draws the same pending row meanwhile
  (`OpeningPrompt`, named after the agent).
- A new agent's pi spawns with its creation. At launch every restored agent's pi starts from
  the first adoption of the workspace, not when its layout mounts, in `AgentStartQueue`'s
  order: the agent on screen first (and any agent selected while it waits), then the rest a
  few at a time. Every agent still starts. Test harnesses that seed agents only to draw them
  opt out (`restoresAgentsAtLaunch: false`); their pi starts when a pane's session is asked for.
- Starting is quiet: a thread draws what it knows at once (a new agent's empty state, a
  resuming agent's history read from pi's session file), accepts a send that waits for pi, and
  says "Starting…" only when pi is slow (DESIGN.md › Thread, Composer).

`RPCThreadState` projects pi's events into the `NativeThreadSnapshot` that
`SessionServer.nativeThread` serves locally and, over TCP, remotely
([docs/native-thread.md](docs/native-thread.md)). Messages sent while pi works wait in a queue
the host holds (never pi's own, whose modes write the user's pi settings) and go when pi
settles, or are steered in; a user message joins the thread only when pi starts it
(docs/native-thread.md › The queue).

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

A status is live state (`StateStore.updateLive`): broadcast and readable at once, but neither
validated nor written to `state.json` on its own, since every turn reports twice and `start()`
resets statuses anyway. The next structural mutation writes it along with its own change. Keep
anything that must survive a relaunch out of that path.

**Terminal panes** run the shell from Settings ▸ Terminal as a login shell, without wrapping
`pi` or injecting a theme. The user's rc files and pi settings are never edited, and agent-only
variables are blanked.

**Automations** are saved prompts (`ShepherdState.automations`).

- **A run** spawns an ordinary agent, in a reserved hidden space when the automation's cwd
  matches no user space. It is launched with `SHEPHERD_AUTOMATION=1`, which keeps the pane and
  notify tools but withholds the `automation_*` tools.
- **Management:** agent requests arrive as `AutomationRequest` through
  `SessionServer.onAutomationRequest` and are served by `ShepherdViewModel+Automations.swift`.
  The Automations sidebar section is their only surface on the host. Remote clients change them
  through the same handler (`RemoteRequest.automation`, below), after the server checks what it
  can (the automation exists; a new or edited one has a name, a prompt and a directory on the
  host).
- **Run now** (`startAutomation`) follows `AutomationRun.isLive`: a run whose agent works, asks,
  or has not settled a turn yet refuses ("already running"), and so does a second start while
  one is starting. A settled run is replaced once the new run exists: the automation moves to
  the new run (the log closes the old one as finished), the host's selection follows if the old
  run was on screen, and only then is the old run's agent deleted, so nothing else is drawn in
  between. Clients offer Run now or Stop by the same rule (`AutomationAbilities`), so a
  finished run never offers only Stop.
- **Runs are kept** (`AutomationRunLog`, `automation-runs.json`, the newest 30 per automation):
  a run opens when an automation gains an agent, follows that agent's status (running, needs
  you, finished), and closes when the automation loses that agent, to deletion or to its next
  run (finished if its turn had finished, else stopped). At startup every run still open closes
  as interrupted. The server records them from every committed state, so no caller records a
  run by hand; removing an automation forgets its runs. Remote clients read them with
  `RemoteAutomationRequest.runs`.
- **At startup:** the previous run's agents and their layouts are dropped
  (`SessionServer.automationRunAgentIDs`: every agent in the automations' hidden space, never
  the designs space's, plus any agent an automation still points at), every automation's `agentID` is cleared, and enabled automations
  start fresh runs once the workspace is adopted. Never keep a run agent across launches.
- **Changing them** touches `ShepherdCore`, the extension-message enums, `SessionServer`, the
  panes extension (canonical and embedded), and their tests.

## Remote

- **Listener:** `SessionServer.startRemoteListener(port:tokenURL:)` binds TCP on **all
  interfaces** (default 7433, or 7434 in Shepherd Nightly so both apps can serve; port 0 picks
  an ephemeral port, and the bound port is returned).
  Settings ▸ Remote ▸ Serve this Mac toggles it, and bind failures show there.
- **Auth:** the first frame must be `hello` with the token from `remote-token` in the support
  directory (32 random bytes as hex, mode 0600, created on first use) and a matching
  `RemoteProtocol.version`, listing what the client understands
  (`RemoteProtocol.clientCapabilities`; older clients list nothing). **There is no TLS.** A VPN
  or trusted network is the transport boundary. Never describe the listener as internet-safe.
- **Protocol** (NDJSON, `RemoteMessage.swift`):
  - state fetch and pushed `stateChanged`
  - native thread requests, with the context and Compact now behind `native.context.v1`
  - attach, detach, input, resize, and acknowledged paste
  - pane open, close, and split resize
  - `listDir`, `listModels`, `addSpace`, and `createAgent` with `creationOptions` (and the
    opening prompt's images behind `agent.create.images.v1`)
  - chunked uploads (32 MiB per file)
  - `agentQuery`/`agentAction`: rename, delete, reorder, review, subagents, search, worktree
    info/setup/finalize/delete, `terminals` (what each terminal pane runs; answered by the
    server itself, `terminal.activity.v1`), and commit from review (`commitInfo`,
    `commitMessage`, `commit` behind `review.commit.v1`; the commit is an operation polled with
    `worktreeStatus`), and the Changes pane (`changesOverview`, `changesList`, `changesFile`,
    `changesBranches`, `changesPatch`, `changesUndoTurn`, `changesRedoTurn` behind `changes.v1`,
    answered by the server itself; thread snapshots carry `turnChanges`). Older hosts review the
    working tree only (`review`). The terminal panel's own actions on an agent's terminal panes
    ride `agentAction` behind `terminal.control.v1`: `renameTerminal` (Rename tab) and
    `killTerminalProcess` (Kill process), each refused on the agent's thread pane. An older
    client's `typeInTerminal` (Run in terminal, since removed) is answered `unsupported`.
  - `automation` (`automations.v1`): switch on or off, run now, stop, the runs the host kept,
    create, edit, delete. There is no schedule or trigger: an automation that is on starts a run
    when Shepherd launches on the host. The Mac shows a host's automations under its sidebar
    section; the iOS client in Automations. A host without the capability shows them read-only
  - `instructions` (`instructions.v1`): Settings ▸ Instructions' files on the host (fetch, save,
    restore a saved version), answered with the files and their history. The Mac's page syncs
    them to every host, or edits one host at a time
  - `suggestions` (`suggestions.v1`): Settings ▸ Experiments ▸ Suggested instructions on the host
    (fetch, configure, add as edited and retargeted, add all, dismiss, undo), answered with the
    experiment's settings and its lines
  - `hostSettings` (`hostSettings.v1`): what the host's Settings ▸ Agents, Worktrees and Pi set,
    the pi packages its pi loads, and its Shepherd and pi versions; one change per request
    (`HostSettingChange`), applied as the Mac's own Settings would
  - `skills` (`skills.v1`): Settings ▸ Skills on the host (fetch, look up a repository, install
    from one or from files, on or off, how it's used, remove and restore, check for updates,
    Update automatically), answered with the host's skills or the repository's. The server runs
    them on its own queue (they fetch with git) and tells the host's page about each change
    (docs/skills.md)

  Capabilities gate newer features. The client falls back (raw bracketed paste) or refuses (pane
  control) against older hosts. A host answers an authenticated request it cannot decode (a kind
  or action from another version's client) with `unsupported` and keeps the connection; a frame
  with no `id` closes it. Output frames chunk at 256 KiB to stay under the 1 MiB frame cap.
- **Sizing:** viewports are smallest-viewer-wins. Each attached remote viewer reports its grid,
  and the PTY takes the minimum; with no remote viewers, the local viewport rules. Resize reports
  from unattached clients are ignored.
- **Attach is atomic** on the server queue: viewport registration, snapshot, attachment, and
  replay watermark happen in one turn.
- **Host-side handlers:** remote pane and agent-creation requests go through
  `onRemotePaneRequest` and `onRemoteCreateAgent` with the same authorization as local requests,
  and host settings through `onRemoteHostSettings` (the GUI owns `AppSettings`). A server without
  those handlers rejects them. Detaching a remote pane never kills the host session.
- **Client:** `RemoteHostStore` persists host configs, **including tokens**, in UserDefaults
  (`shepherd.remote.hosts`). It keeps one `RemoteHostClient` per host, with exponential backoff
  capped at 30 s. A refused token or another protocol version is not retried: the host shows
  why and waits for Edit or Reconnect. `RemoteHostFailure` (ShepherdRemote) is the one place
  that reads a failed connect as copy and a retry rule, for the Mac and iOS alike. A client
  reports a failed handshake only through what `connect` throws, never `onDisconnected`.
  Remote hosts are not part of `ShepherdState`.
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

**Embedded extensions have one canonical copy.** The thirteen files in `Extensions/` are canonical,
and so is the design skill in `Extensions/design-skill/`.
pi loads the copies that the nine `Sources/ShepherdApp/*Extension.swift` files write to the
support directory from embedded string literals. `installedPath()` rewrites an installed copy
whenever its content differs, so drift ships bugs. `ChildrenExtension.swift` carries children,
children-config, children-ui, workflow, and missions, and installs `InspectExtension`'s
`shepherd-inspect.mjs`. `DesignExtension.swift` also writes the design skill's `SKILL.md` and
`format.md` to the support directory's `design-skill/`.

- Edit a `.ts`/`.mjs` file (or a design skill file) and its literal in the same change, with
  `scripts/sync-embedded-extension.py`. A unit test enforces byte identity for all thirteen pairs
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
never picked per view. Night Watch is the only shipped theme. The pre–Night Watch names
(`ShepherdDesign`, `Tokens`, `Fonts`, `Metrics`, `Radius`, Basalt) are gone; never reintroduce
aliases for them.

**State is Observation.** The view model, `NativeThreadStore`, `AppSettings`,
`KeybindingsStore`, `ThemeManager`, `ThemeStore`, `RemoteHostStore` and its connections,
`PiUpdateManager`, `AppUpdater`, the worktree models, terminal pane sessions, and `MenuState`
are `@MainActor @Observable` classes, owned with `@State` and bound with `@Bindable`.

- Don't add `ObservableObject`, `@Published`, `@StateObject`, or `@ObservedObject` to the Mac app
  or the iOS client. TerminalSurfaceKit's `TerminalSurfaceModel` stays one because
  GhosttyTerminal's view state is one. The iOS client's stores (`MobileHosts` and its hosts,
  `MobileNavigator`, `ThreadStores`, `MobileAppearance`) follow the same rules.
- Observe only what views draw: bookkeeping is `@ObservationIgnored`, and a property is written
  only when its value changes, so a poll or a status report never re-renders a view it didn't
  change.
- Views take plain `Equatable` values (sidebar rows, pane leaves, thread rows) and do no parsing,
  filtering, or highlighting in `body`; stores derive rows once per change. Menus read narrow
  cached values from `MenuState`.
- A list that can outgrow a screen is a lazy stack whose `ForEach` makes exactly one view per
  element (wrap an `if` or a `switch` in a container), with rows that compare equal unless they
  changed: highlight and selection arrive as a `Bool`, hover stays in the row, closures stay out
  of `==`. No per-row drop targets or hidden controls; see DESIGN.md › Performance. Add a
  `ListPerformanceTests` budget with any new long list.
- `PreferenceObservationTests` checks that a changed preference reaches the views that read it.

**Keybindings resolve through the store.** Menus, palette keycaps, Settings ▸ Keyboard, and the
Ghostty unbind list all read `KeybindingsStore`, and hardcoding a chord in a view is a bug.

- A rebound chord must include ⌘. ⌘1–9 (the first nine Recents rows), ⌘,, and the plain ⌘
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

**Agents drive their own panes.** A new agent is exactly one pane, its thread. Extra panes come
from the agent (`shepherd-panes.ts`) or the user (⌘D). The server owns PTYs but not layouts, so
pane requests are forwarded to the GUI via `onPaneRequest` (and `onRemotePaneRequest`) and
answered with a `PaneOutcome`. `PaneControl.swift` is the only place that serves them. Its rules
are load-bearing:

- An agent may touch only panes in **its own** layout.
- It can never close or type into the pane running its own pi process.
- The last pane in a layout cannot be closed.

**Agents never delete each other on their own.** `agent_delete` opens `PeerDeleteDialog`; only
its destructive button approves, by claiming the server's token (`claimAgentDeletion`) before
deleting through Delete Agent (never Delete Worktree Agent, so checkouts and branches stay).
Cancel, a lapsed token (caller cancelled or disconnected, 120 s timeout), or a second request
while the dialog is up never deletes. The live coordination tools (`agent_read`, `agent_steer`,
`agent_interrupt`, `agent_wait`) are answered by the target's own panes extension, never inferred
from saved state; the server relays each under its own token and accepts the answer only from
the target's registered connection ([docs/agent-coordination.md](docs/agent-coordination.md)).

Shepherd does not nest agents. pi extensions own subagent execution (the bundled native runtime
is on by default), and the app only *projects* the results: the tray above the parent's
composer, two record lines in its thread, the inspector, and the palette. Subagents have no sidebar rows; one
waiting on you marks its parent's row. Child runs are display state and never persisted.

**Switching is a visibility flip, never a remount.** `WorkspaceSelection.mountedTabs` keeps every
mounted agent layout in the view tree, and selection only changes which one is visible (a hosting
view's `isHidden`, `nwMotionPaused`, and `isRendering`, where Ghostty occlusion stops hidden
panes' render loops). A hidden thread suspends its store (`NativeThreadStore.suspend`) and keeps
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
  [NOTES.md](Sources/TerminalSurfaceKit/NOTES.md))
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

The one deliberate unmount is **cold parking**, and only for a layout holding a terminal pane. A
layout hidden for 30 s and outside the four most recently shown
(`WorkspaceSelection.coldParkCandidates`) drops its terminal panes' surfaces via
`TerminalSessionStore.parkPane`. Its processes and host-side screens keep running, and
reselecting it remounts from the server snapshot. A thread-only layout never parks: it has no
surface, its hidden store polls nothing, and its `NativeThreadStore` keeps the draft and
history, so returning to it is always a flip. Measurements are in
[docs/benchmarks](docs/benchmarks/2026-09-03-terminal-baseline.md).

**Sessions and views are separate.** Closing a pane detaches views only. A process that exits on
its own closes its pane and retires its agent. Delete Agent is the explicit way to terminate an
agent and its auxiliary processes while the app runs, and quitting the app terminates everything.

**Only these paths mutate repositories** ([docs/worktrees.md](docs/worktrees.md)):

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
- **Working-tree snapshots of the Changes engine** (`ChangesService`, [docs/changes.md](docs/changes.md)):
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
is the Changes tab of the agent's side pane beside its whole layout (thread and terminal panes);
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

## Git

Use conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`; `feat!:` for
breaking changes), one logical change per commit, with no AI or attribution lines.

`nightly` is the integration branch. Feature branches (`feat/…`, `fix/…`) come off it and merge
back through a PR with a merge commit (`--no-ff`). Every push to `nightly` ships a Shepherd
Nightly build. CI runs the tests on pull requests and on `master`; a push to `nightly` only
rebuilds CI's caches.

## Releases

One workflow (`.github/workflows/release.yml`) ships two Mac apps and the iOS client's TestFlight builds. Its rules live in
`scripts/release.py` (tested in `Tests/Release`); the YAML only runs them. A `plan` job decides
from the pushed ref what to build, and the build job is skipped when the answer is nothing.
Releasing Shepherd means tagging `nightly`'s tested tip and pushing the tag.

| App | Channel | Cut by | Feed (on `gh-pages`) | Contains | DMG |
| --- | --- | --- | --- | --- | --- |
| Shepherd | stable (default) | tag `vX.Y.Z` | `appcast.xml` | stable | `Shepherd.dmg` |
| Shepherd | beta | tag `vX.Y.Z-beta.N` | `appcast-beta.xml` | beta + stable | `Shepherd.dmg` |
| Shepherd Nightly | nightly | push to `nightly` | `appcast-shepherd-nightly.xml` | Shepherd Nightly builds | `Shepherd-Nightly.dmg` |
| Shepherd iOS | TestFlight internal | manual run (`gh workflow run release.yml --ref nightly -f testflight=true`) | none (App Store Connect) | Shepherd iOS builds | none |

- **Release candidates are retired.** A `vX.Y.Z-rc.N` tag builds nothing (the plan job says
  why), and old rc releases land in no feed.
- **Only `nightly` ships Shepherd Nightly.** A manual run (`workflow_dispatch`) plans like a
  push of its ref, so on any other branch it builds nothing rather than shipping that branch to
  every Shepherd Nightly.
- **The iOS client uploads only on a manual run.** Apple caps TestFlight uploads per day, and a
  build per nightly push hit it (ITMS-90382, 2026-09-25). So no push uploads `Shepherd iOS`; a
  manual run on `nightly` with the `testflight` input
  (`gh workflow run release.yml --ref nightly -f testflight=true`) uploads it to TestFlight
  internal testing and builds no Mac app. A plain manual run plans like a push. The `testflight`
  job runs on the `xcode-27` runner, archives unsigned, and cloud-signs at export with the
  `APP_STORE_CONNECT_*` key. The plan refuses it on any other ref, without the key, or on a
  re-run (which keeps the build number; start a new run). Its version is the project's
  `MARKETING_VERSION`, and its build number is the run number. Beta tags (external testing) and
  stable tags (the App Store) upload nothing yet ([docs/ios](docs/ios/README.md#distribution)).
- **Only the newest TestFlight build stays installable.** After the testflight job uploads,
  the Release workflow's `retire-testflight` job (`release.py retire-testflight`) waits up to 45
  minutes for Apple to process that build, then expires every older one. If it fails processing
  or never finishes, nothing expires. The first TestFlight run after it lands also clears the
  builds already there. There is no manual run; a dry run (`--dry-run`) works only locally, with
  the App Store Connect key.
- **One build number, one release.** A re-run keeps `github.run_number`, the build number.
  `generate_appcast` refuses a feed directory holding two archives of one build, and that fails
  every feed's update until one ages out. So a nightly re-run whose commit already carries a
  `nightly-*` tag builds nothing (push again instead), and a tag's re-run stops at
  `gh release create`.
- **Runs queue; they never cancel.** A push waits for the release already running, and a newer push
  replaces only the one still waiting, so every started run finishes (a cancelled run can leave a
  TestFlight upload unretired or the feeds half written) and the newest commit ships next. A
  TestFlight run queues in a group of its own, so it never replaces a waiting push or is replaced
  by one.
- **Two apps, never each other's updates.** Shepherd Nightly has its own bundle id, name
  (`Shepherd Nightly.app`), DMG and feed, and every feed carries one app only. Sparkle is not
  the boundary: its installer picks the new app in an archive by the host's *file name* first
  and only then by bundle id, and both apps share the EdDSA key. The distinct file name makes a
  stray cross-app item fail to install rather than replace the app, but the feeds are what keep
  it from being offered, and three guards keep them apart:
  - `release.py route` puts a `nightly-*` release in Shepherd Nightly's feed only through
    `Shepherd-Nightly.dmg`. Nightlies from before the split carry only `Shepherd.dmg` and drop
    out, and an old copy of this workflow (which downloads `Shepherd.dmg`) never picks up a
    Shepherd Nightly build.
  - The build job runs `release.py verify-app` before signing: the bundle id, name, executable
    and `SUFeedURL` must be the planned app's.
  - `ChannelDelegate` computes the feed from the edition, so a Shepherd Nightly build reads its
    own feed even if its `SUFeedURL` were wrong.
- **One EdDSA key** (`SPARKLE_PRIVATE_KEY`, `SUPublicEDKey`) signs both apps.
- **Legacy feeds for installed builds.** Shepherd builds from before the split read
  `appcast-rc.xml` (allowing Sparkle channel `rc`) or `appcast-nightly.xml` (allowing
  `nightly`, or no channel at all in the first nightly builds). Every run still writes both, as
  the beta feed with its items untagged: Sparkle shows default-channel items whatever a build
  allows. So those installs update to a Shepherd beta or stable (never Shepherd Nightly), and
  that build's launch migration moves them to Beta. Keep writing them while such installs may
  exist. A Shepherd install that rode nightly sits at a build number above every existing beta
  and stable, so it waits until the first Shepherd beta or stable built after the split: cut one
  soon after the split lands.
  - Push that tag once the merge's own nightly run has finished. Two runs that write `gh-pages`
    at once collide: the later push is rejected, and its feeds wait for the next run.
  - Tag only commits that contain the split. A tag runs the workflow of its own commit: an
    older one rebuilds `appcast-rc.xml` and `appcast-nightly.xml` the old way until the next run
    here rewrites them, and an rc tag there still cuts an rc.
- **Launch migration** (`UpdateChannelStore`, Shepherd only): a stored `rc` becomes Beta, and a
  stored `nightly` (or the pre-picker nightly bool) becomes Beta and arms a one-time notice
  under the toolbar (`NightlyMovedNotice`) linking to Shepherd Nightly. The birth channel reads
  `-beta.`, `-rc.` and `-nightly.` versions as Beta. Shepherd Nightly always rides nightly and
  stores no channel. Debug builds (the Dev scheme, `com.bailycase.shepherd.dev`) have no
  updater, so they never resolve or migrate a channel.
- **Promotion re-tags the same commit** (`v0.2.0-beta.1` → `v0.2.0`). Never rebuild for a
  promotion.
- **The beta feed is a superset**, so riding beta never strands a user behind a stable hotfix.
  Sparkle picks the newest *build number* (`CURRENT_PROJECT_VERSION`, the workflow run number,
  shared by both apps), so a hotfix built after a beta supersedes it for beta riders.
- **Tags are immutable.** Never delete, move, or reuse one; a botched release gets the next
  number. (Old `nightly-*` releases and their tags are pruned to the latest few; those tags are
  the workflow's own, not release versions.)
- **Default channel:** Shepherd (`AppUpdater.swift`, `UpdateChannel`) defaults to its birth
  channel, parsed from the marketing version. An explicit choice in Settings ▸ Advanced is never
  overwritten, and the picker offers only Stable and Beta.
- **Channel plumbing** changes `scripts/release.py` (and `release.yml` if the steps change),
  `UpdateChannel`/`UpdateChannelStore`/`ChannelDelegate`, the Advanced row, the Xcode
  configurations, and their tests together. Feed names and bundle ids are a contract between CI
  and the apps; `Tests/Release` reads both sides.
- **Signing:** with the Developer ID, notarization, and Sparkle secrets configured, builds are
  signed and notarized. Without them the workflow falls back to ad-hoc signing and skips the
  appcast.
  - `scripts/sign-app.sh` signs inside-out, never with `--deep`: every nested item first, then
    the app with `App/Shepherd.entitlements` (both apps). Only nested apps and XPC services keep
    their own entitlements.
  - The iOS client is archived unsigned and signed only at export, with the team's
    cloud-managed Apple Distribution certificate through the `APP_STORE_CONNECT_*` API key
    (`-allowProvisioningUpdates`). There is no `.p12` and no keychain.
  - Developer ID items get the hardened runtime and a secure timestamp, and both the app and the
    DMG are notarized and stapled. Ad-hoc builds skip the runtime, because library validation
    rejects ad-hoc frameworks, which have no Team ID.
  - Shipped binaries are stripped (`strip -S -x`). Their dSYMs go on each release as
    `Shepherd-dSYMs.zip` or `Shepherd-Nightly-dSYMs.zip`.
- **Appcasts** are rebuilt from every release on each run: one `generate_appcast` per feed
  directory, written to a fixed name (`-o`; left alone it names the file after the app's
  `SUFeedURL`). Deltas go to the feed's newest release, renamed without spaces
  (`Shepherd Nightly63-61.delta` → `Shepherd-Nightly63-61.delta`), because GitHub rewrites
  spaces in asset names.
- **Building Shepherd Nightly locally:** the `Shepherd (Nightly)` scheme, or
  `xcodebuild -scheme 'Shepherd (Nightly)' -configuration Nightly …` as the workflow does.
- **Enhanced Security** is set on the Mac target only, because at project level it would push
  arm64e onto the iOS target. Pointer authentication stays off, since libghostty and Sparkle
  ship no arm64e slice. The real protection is the hardened-process entitlements. The
  compile-time half of `ENABLE_ENHANCED_SECURITY` (stack zero-init, typed allocators, libc++
  hardening) reaches only `App/ShepherdLauncher.swift`: SwiftPM package targets do not inherit
  target settings. So ShepherdPTYSpawn's C and the tree-sitter parsers build without it.

## Gotchas

- **Socket paths:** `sun_path` caps Unix socket paths at 104 bytes. Tests build sockets under
  short temporary paths.
- **Frame sizes:** RPC stdout records may be up to 256 MiB (`get_messages` returns a whole
  history in one record), but extension-socket and TCP frames stay capped at 1 MiB.
- **Replay** into a fresh surface is a `SessionScreen.snapshot()`: an ANSI reconstruction (up to
  2000 lines of styled scrollback, the alt screen, cursor, and modes), not raw bytes. Cosmetic
  artifacts are acceptable; lost bytes are not. The watermark protocol prevents duplication and
  loss.
- **Skills live in `~/.agents/skills`,** the folder pi reads skills from, not `~/.pi/agent`.
  Settings ▸ Skills is the only thing that writes there; everything else it keeps (skills that
  are off, just removed, git caches, records) is in the support directory's `skills/`.
- **pi's trust prompt:** interactive pi asks to trust project `.pi/` directories, but `-e` loads
  our extensions without one. Never install anything into `~/.pi/agent/`. `PiSessionFile` writes
  only session files, which pi treats as data. Settings ▸ Instructions keeps its root files in
  Shepherd's support directory and hands them to the sessions Shepherd starts through
  `shepherd-instructions.ts`; pi run by hand doesn't read them.
- **pi's formats:** `PiConfig` (models.json, settings.json) and `PiModelCatalog`
  (`pi --list-models`) parse defensively, because pi's formats are not our contract.
- **Binding:** `SessionServer.start()` refuses to bind over a live socket (it probes with a
  connect) and replaces stale socket files. The remote listener reports bind failures rather than
  silently serving nothing.
- **Transcript search** in the palette (and a host's answer to a remote `agentQuery(.search)`)
  reads only the last 512 KB of each agent's pi session, and matches only user and assistant
  text (`PaletteContentSearch`), never the system prompt, tools, or JSON around it.
- **Launching the binary bare** from a terminal starts a background process; the `AppDelegate`
  promotes it to `.regular` and activates it.
- **Quitting** while agents are working or blocked asks first, in `QuitDialog` on the main
  window (reopened if it was closed; its own window if the main one isn't back within a second),
  because it stops them mid-turn. A log out, restart or shut down never waits on it
  (`QuitPolicy`; only loginwindow's quit counts as a power-off).
- **xcodebuild and `Package.resolved`:** a build from a fresh DerivedData resolves packages
  again and rewrites the Xcode project's
  `Shepherd.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` with newer
  versions (Sparkle and SwiftTerm, for example). Pass `-onlyUsePackageVersionsFromResolvedFile`,
  and never commit a bumped `Package.resolved` by accident.
