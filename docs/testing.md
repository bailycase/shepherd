# Testing

> Read when you write or change a test, pick a test tier, touch CI, or need the coverage that must not be dropped.

Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), never XCTest.
Tests come in tiers, and the switch is `--filter` on target names.

For the Browser's disk persistence checks, run `python3 scripts/test-browser-persistence.py`.
It runs the app's Browser tests with a shared scratch home for WebKit, including two fresh processes
that write and read a saved project cookie. Ordinary runs skip the disk checks so they never
write website data under the user's home. The disk checks need macOS 27+ because identified
stores crashed macOS 26's bundle-less test runner; the bundled app still uses persistent stores.

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
  It lets a raw `ExtensionClient` speak as any agent (`extensionPeerCheck`, which a real server
  leaves `nil`: a connection speaks only for the agent whose pi opened it); a test of the rule
  itself calls `useRealPeerCheck()` and runs stub pis (`ExtensionIdentityTests`).
  Its default `PiSetup.app` shares the process's scratch session home. A test asserting an exact
  Projects listing passes a `PiSetup` with a per-test home: listing intentionally imports old
  session headers, including those other suites left in a shared home. `AppHarness` instead
  defaults to a per-harness pi home (removed by `stop()`), isolating session history and pi
  settings across app suites; pass `pi: .app` explicitly when testing process-home sharing.
- `StubPi.command`: runs `Resources/stub-pi.py`, a scripted `pi --mode rpc` driven by prompt
  keywords (`ask`, `select`, `hang`, `die`, `big`, `slow`, `widgets`, `fill`, `newsession`, …).
  `speak` (and `STUB_PI_SPEAK`, or `speak` in `stub-pi-startup.json`) has it talk on the
  extension socket as an agent, from its own process and from one it starts, and write what
  each request was answered.
  `STUB_PI_LOG` records what it received, and `STUB_PI_HISTORY_BYTES` seeds a long history.
  `STUB_PI_STARTUP_DELAY`/`_GATE`/`_EXIT` hold or fail its boot, `_STDERR` is what it says
  before that exit, `_NEW_SESSION` prints pi's warning that it found no session for its
  `--session-id`, and `_REQUIRE_AUTH` exits "No models available." unless its pi home's
  `auth.json` holds a login (`stub-pi-startup.json` in its cwd does the same for a pi launched
  the way the app launches it).
  `StubPi.installAsEngine()` installs it as the engine `SHEPHERD_PI_ENGINE` names (answering
  `--list-models`), for code that launches pi the way the app does (`PiLaunch`, through the
  launcher in the scratch `support/pi`). Each launch is recorded, argv, cwd and environment, in
  `TestProcess.piLaunches` (`StubPi.launches()`).
- `makeScratchRepo()` and `git(_:in:)`: a git repository with one commit. A failing git call
  throws `CommandFailure` with git's stderr.
- `makeScratchDirectory()`: a `mkdtemp` directory inside the process's scratch root, short
  because `sun_path` caps socket paths at 104 bytes.
- `ExtensionClient`: a raw extension-socket client, which is the test process and so not any
  agent's pi.
- `LoopbackServer` and `DevServerFixture`: a server on the loopback and an ephemeral port standing in
  for a host's dev server in tunnel tests (HTTP GET and a POST of any size with its SHA-256, a
  WebSocket echo, an echo, a firehose, one that never reads), IPv4 or IPv6, or on a chosen address
  or port. Every tunnel and forwarder test uses it, never the network.
- `ScrollTrace` (`ShepherdAppIntegrationTests/Support`): a thread's scroll view recorded as it
  changes (offset, content height, insets, stamped with the test's step), with the states a display
  could draw (one per run-loop turn) kept apart from every change in between. Read a scroll rule
  from it, not from where the view ended: a retreat (the offset fell and the view ended farther
  from its tail), the time spent away from the tail, where it came to rest. The lazy stack's total
  height takes values thousands of points off inside one layout pass. `ThreadSendScrollTests` and
  `ThreadScrollAuditTests` judge a thread that way over `FlowHost`'s fake host, and
  `ThreadSendHostTests` over `RealThreadRig` (a real server and the stub pi, whose
  `tools:N` prompt makes N tool calls that wait for `tool-<k>` files).
- `eventually("what", …)` and `eventuallyOnMain`: named 10 ms polls that throw `WaitTimeout`
  saying what never happened. Never sleep a fixed amount; wait on a callback or `eventually`.
  Keep timeouts generous (they default to 30 s), but make the happy path fast. Disclosure controls
  update model state before SwiftUI finishes updating its accessibility tree: wait for a nested
  row to disappear or reappear before asserting its visibility or pressing it; layout alone is
  not that boundary (`NestedProjectsFlowTests`). Completion probes
  wait for the final text in WindowServer pixels without forcing layout; the guard's multi-step
  recovery is not guaranteed to finish in a fixed one-second delay. The real-workspace completion
  probe saves its last polled image on success or timeout, so failure evidence is the pixels that
  failed the paint condition. Turn-navigation probes wait
  for the viewport to land above the bottom band, not merely for the navigation intent to detach
  following while its first animated frames are still at the tail. The off-screen scroll harness
  declares wheel intent through the same `ThreadInput.readerScrolled(upward:)` method as the native
  monitor before moving the clip view. A clip-view movement without that signal is layout, not
  a reader gesture, and must not re-attach following.
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
  `ShepherdTestKit`) points `SHEPHERD_SUPPORT_DIR` (and with it Shepherd's pi home,
  `support/pi`, whose `skills/` Settings ▸ Skills manages), `SHEPHERD_MCP_CONFIG`, `SHEPHERD_YOUR_PI` and
  `PI_CODING_AGENT_DIR` (both "your pi", `pi-agent/`: the second a decoy the app must ignore), and
  `ZDOTDIR` at a scratch root for that process, and clears the
  agent-only `SHEPHERD_*` variables a run started from a Shepherd agent inherits. It clears
  inherited `GIT_*` controls, installs empty scratch global/system Git configuration and
  scratch templates, and disables credential prompts. Tests may still configure local hooks
  explicitly inside their scratch repositories. It also puts a
  `bin/` first on `PATH`, holding stand-ins for `gh` and `pi` that refuse to run, and the scratch
  `ZDOTDIR`'s `.zshenv` and `.zlogin` keep it first in every zsh a test starts. Without them, a
  login shell from a minimal environment (Xcode, launchd) reaches the user's own `gh` and `pi`,
  because the system startup files rebuild PATH. Normal scratch interactive zsh shells also
  unset `GLOBAL_RCS`, preventing a machine's later global completion/security prompts from
  consuming the fixture's commands. Local scratch startup files still run; noninteractive
  login shells and opt-in live-model runs retain global startup coverage. The root is removed
  at exit. `TerminalSessionTests` checks both interactive and noninteractive modes.
- The app's engine in a test is `SHEPHERD_PI_ENGINE`, set to `bin/pi-engine`, which refuses to
  run until a test installs the stub over it. No app-level test reaches pi through PATH, and
  nothing a test does may write into `pi-agent/` ("your pi"; `PiHomeLaunchTests` checks it stays
  byte-identical).
- The scratch startup files also carry decoys, as a user's might: `.zshenv` exports
  `PI_CODING_AGENT_DIR`, `PI_PACKAGE_DIR`, `NODE_OPTIONS`, `PI_OFFLINE=0`, `JITI_ALIAS` and
  `PI_EXPERIMENTAL` pointing into `pi-decoy/` (never the scratch `pi-agent/`), and `.zlogin` moves
  a shell that starts Shepherd's pi (`*/pi/bin/pi*`) to `/`. They are harmless where they land;
  the launcher must win over them (`TestIsolationTests`, `PiHomeLaunchTests`). The live-model run
  gets neither the engine nor the decoys.
- A target depends on `ShepherdTestKit` when the code it tests can reach the support directory,
  pi's directory, `UserDefaults`, the drop directory, or a shell. With the swiftbuild build
  system each target is its own test bundle, so a target without it gets no isolation.
- Otherwise pass state in: `ShepherdPaths.supportDirectory(environment:)`,
  `PiConfig.agentDirectory(environment:)`, `TerminalImageDrop.resolve(_:directory:)`. Shepherd's
  pi home, the engine, "your pi" and the catalog come in as a `PiSetup` (`SessionServer(pi:)`,
  `PiSetup.app` in the app).
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
- `Preview.render` draws light and dark; `Preview.renderMatrix` also draws each text scale (1 and
  1.3 by default, the Mac's largest Text size; `ThemeStore.shared.textScale`, put back afterwards) as
  `<surface>-x1.3-<light|dark>.png`; `modelSettingsPopoverStates` is the example. A preview of a
  feature's copy is driven from the real producer (the store, the extension's output, the
  formatter, as `ThreadView` over a `ThreadFixture` is), never from strings copied from the board.
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

**Engine smoke:** `EngineSmokeTests` runs the shipped engine for real, opt-in, gated on
`SHEPHERD_ENGINE_SMOKE` (a built `Shepherd.app`, or the staged `.build/pi-engine`). Its node and
pi run against a scratch pi home, with the child's `HOME`, `TMPDIR` and working directory scratch
too: `get_state`, a TypeScript fixture extension loaded through jiti, and an RPC `bash` command.
It also starts the engine through the real launcher in a scratch Shepherd home, with a
`NODE_OPTIONS` pi must not see: an RPC `bash` command there finds `pi` at the launcher and gets
that `NODE_OPTIONS` back (`restore-env.sh`).
It also runs a scratch copy signed with the hardened runtime (`scripts/sign-engine.sh`), so the
engine's entitlements are checked too. It never reaches
a model: the home's one provider points at a closed port and no prompt is sent. The same engine
also runs when the pin changes through the real `SessionServer` and the thread's projection
(`EngineThreadTests`, same switch): a scripted provider on the loopback
(`Tests/Extensions/engine-provider.mjs`) drives a turn, a tool call, a reasoning block, Stop with a
queued message, an extension's question, a command's notice, a prompt template, a skill and
Compact, so what the stub pi models is checked against the real thing. Run both, and the
extension tests, on every bump (docs/pi-engine.md › Bumping the pin).

**Long lists** (docs/design/performance.md › Performance) are measured, not guessed:

- `NWRenderProbe` (ShepherdUI, debug builds only) counts row bodies while a test records:
  `let _ = NWRenderProbe.tick("sidebar.row")` at the top of a row's `body`. It also counts
  derivation passes that must not scale with a change (`sidebar.spaceScan`, `sidebar.spaceForest`),
  and a sidebar section header's body (`sidebar.header`).
- `ListPerformanceTests` pins each long list's budget as a count of rows built or redrawn
  (opening, scrolling, a highlight or a selection moving, one row changing, a reply streaming).
  Visible-row budgets account for controls' minimum hit areas, not just their drawn glyphs.
  Counts hold on a slow or busy runner; timing budgets do not, so don't add those. Two thread
  budgets differ on macOS 26 (CI) and in Xcode 26 builds whatever the speed, so there they run
  as known issues.
- Goal clock budgets assert that local card/header ticks redraw only their timeline content.
  Five accounting snapshots must redraw no composer bodies/chips, queue bodies/rows or thread
  bodies/row builders. Shared docks read cached goal presence/identity, not the full goal.
- `DesignPerformanceTests` pins the design canvas the same way over a 172-board canvas: at most
  six web views open (five live, one rasterizing), panning recycles them, and one board changing
  redraws one frame (`design.board`) with one snapshot; a Tweak drag redraws no frame and its
  release only the tweaked board's; a board dragged redraws only its own frame, once per step. The Designs grid's and the Comments tab's budgets are in
  `ListPerformanceTests` (`design.card`, `design.comment`). Snapshot and live rewrites share one
  fresh canvas but reset target selection, redraw counts and the snapshot baseline between cases.
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

**Goal safety regressions** use `GoalServerTests` for actual SessionServer widget/status/
notification/queue/Stop/Steer boundaries, and `GoalControlsTests` for offscreen accessibility
presses, condition editing, confirmation and stale controls. `GoalExperimentTests` and the
Experiments ControlPress scenario cover default off, live on/off, late widget rejection and
preserved Paused goals without process restarts, held tools/ordinary queues, rejected hidden-command
queue edits and fenced slash text remaining ordinary content. `GoalPolicyBackpressureTests` fills stdin,
then verifies a retained disable barrier before the final On policy with one write-drain retry and no
ordinary-record loss or abort. `goal-runtime.test.mjs` runs the pinned pi RPC
process against scratch homes and loopback fake providers: compaction, real truncated reads,
auto-retry 529 recovery, uncapped accounting/legacy caps, ordinary work after Pause/disable,
live experiment/Checking cancellation, busy Set/Edit/Resume cancellation, always-not-met 25 checks,
queue yield/delete/steer recipes and manufactured-proof rejection. No external model calls or
user credentials are needed. The runtime fixture preserves display-only details and feeds real
RPC/native projection in previews. Device-level iOS interaction/notification delivery is a
separate check, not a consequence of passing Mac AX tests.

**Extension tests** (`Tests/Extensions/*.test.mjs`, Node's test runner) need `PI_PACKAGE_DIR`
pointing at a Pi package with its modular `dist/index.js` and dependencies. The staged engine
now provides those too. Nothing looks pi up on PATH. They isolate `HOME` and use a local fake
provider. `test_pi_engine_sdk.py` checks SDK imports/session creation against the staged engine
in CI and the signed app during release. The native child extension tests exercise Shepherd-owned
children and workflows with a loopback provider. See [pi-engine.md](pi-engine.md).
`native-children.smoke.mjs` is an opt-in real-model smoke (`PI_SMOKE_MODEL`).
`Tests/ShepherdIOSChecks` holds the iOS client's scripts ([docs/ios/VALIDATION.md](ios/VALIDATION.md)).

**Release rules** (`Tests/Release/test_release.py`, Python's `unittest`, stdlib only) test
`scripts/release.py`: what each trigger builds (the manual TestFlight run included), which feeds
each release lands in, the legacy aliases, the Apple silicon requirement on every feed item,
`verify-app`, `verify-ios`, and which TestFlight builds
`retire-testflight` expires (against a local fake App Store Connect). They also read the
Xcode project, `App/Info.plist`, `App/iOS/ExportOptions.plist`, `ShepherdEdition.swift`,
`AppUpdater.swift`, and the Release workflow (its `testflight` input included), so a bundle id,
feed name or signing setting that drifts from the script fails before a release builds.
`Tests/Release/test_pi_engine.py` tests `scripts/pi_engine.py` against archives built in memory
(what staging keeps and refuses, and `verify-app`'s engine checks), the pin, the engine's
entitlements, `sign-app.sh`'s and `sign-engine.sh`'s signing of node (on macOS), the "Embed pi
engine" phase, and the Release workflow's staging and signing steps.
`Tests/Release/test_check_pr_body.py` tests `scripts/check_pr_body.py`, the `pr-body` workflow's
check that a UI or autonomous-feature PR body says its Departures, Rendered, Controls used,
Bounds, Data, Restart and stop and Decisions, against the PR template and the workflow file.

**Tests never take the user's focus or drive their mouse or keyboard.**

- Windows sit off-screen (`x: -30_000, y: -30_000`), borderless, and ordered back
  (`orderBack`).
- Never call `makeKey` or `orderFront`, and never post synthetic mouse or keyboard events.
- Nothing touches the user's support directory, preferences, pi configuration or sessions,
  `~/.agents`, `$TMPDIR/shepherd-drops`, or a running Shepherd.

**Pressing a control** (`ControlPress`, `Tests/ShepherdTestSupport/ControlPress.swift`) is how a
test proves that a control the design draws is a control, is enabled in the state the design
says, does what it should, and has a hit area a person can hit. It finds the control in the
window's accessibility tree and runs its press action, as VoiceOver does: nothing is posted to
the window, so it never takes the user's pointer or keyboard. A test that says a control cannot
be tested has not tried this. `ModelSettingsPopoverTests` is the worked example,
`ControlPressTests` pins the helper.

- **Opt in with a process of its own.** SwiftUI draws the accessibility tree only while an
  assistive client is attached to the process, and attaching (`AccessibilityNode.enable()`) is
  process-wide, so each scenario is an exit test that calls `enable()` first:

  ```swift
  @Test func pauseSendsPause() async {
      await #expect(processExitsWith: .success) { await recordingErrors { try await Self.pausing() } }
  }
  @MainActor static func pausing() async throws {
      AccessibilityNode.enable()
      let window = OffscreenWindow(size: size, dark: true, MyView(model: model))
      defer { window.close() }
      try window.press("Pause")        // by accessibility label; role defaults to AXButton
      try await eventuallyOnMain("the host to be asked to pause") { model.requests == [.pause] }
  }
  ```

- **Press by label:** `window.press("Fast", in: "Speed")` (a group's label scopes the search),
  `press("Edit", nth: 1)` among equals, `press("Open", role: ControlRole.popUpButton)`. It returns
  the `Control` (role, label, value, frame, enabled). A missing label, a disabled or hidden
  control, a view that only says it is a button and takes no press, and two controls with one label
  each throw a `ControlPressError` that lists every control the window offers. Assert what the press
  did (the request sent, the state left), not only that it pressed.
- **Hit areas:** `window.controls()` lists every actionable control with its frame, and
  `ControlPress.undersized(_, minimum: .desktop)` (24pt) or `.touch` (44pt) names those too small.
  A plain-style button with a clear background and no `.contentShape` answers a click only over its
  label, and its frame says so. Check every state the design draws, since the controls differ.
- **A row's actions:** a row that combines its children is one element, and its hover buttons are
  its accessibility actions (what VoiceOver's action menu offers). `ControlPress.actions(onLabelContaining:under:)`
  lists their names and `ControlPress.perform("Reply", onLabelContaining: "reviewer", under: host)` runs one;
  `SubagentReplyTests` presses a tray row that way. A pointer's hover button is not in the tree,
  so what it reaches is the same closure the action runs.
- A control that is not drawn in a state is not in the tree: assert its absence with `controls()`.

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
  while the agent works, the agent's reply attaching under its pin, and a comment's card ending
  at the first compaction in its reply (the store, and through the server and the stub pi's
  overflow recovery; `NativeThreadStoreTests`, `DesignCommentChatTests`). Tweak: the style splice
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
  leaving nothing behind. Delete and import: a deleted design gone from every surface with its
  agent stopped, Undo within the window restoring it all, the files removed after it, a quit
  within it completing the deletion; Delete design system keeping installed copies and refusing a
  built-in; a ZIP's table of contents checked before unpacking (zip slip, links, sizes), a ZIP
  and a folder importing, every failure leaving nothing, and importing again making a copy.
- **Server:** every `SessionServer` state mutation.
- **Snapshot budget:** a long, edit-heavy thread keeps its newest messages whatever the other
  lists weigh (`SnapshotBudgetTests` over `RPCThreadState.budget` and `fitting`,
  `ThreadSnapshotBudgetTests` over a real server with recorded turns and finished cards,
  `ThreadHeavySnapshotTests` in the real workspace), and a pi slower than the request deadline is
  never served without its history (`SlowStartHistoryTests`).
- **Clipped:** a snapshot says what it shortened and nothing else (`NativeThreadClips` on the
  wire; `SnapshotBudgetTests`, `ThreadEventTests` and `SlowStartHistoryTests` for each cause and
  for its clearing; `NativeClipNoticeTests` for the words, an older host's flag and the store;
  `ThreadClipNoticeTests` in the real workspace over a real server: older pages and a long
  reply raise no notice, a turn's hidden output does until it ends; `ThreadPreviewTests+Clips`
  for each state in both appearances at text scale 1 and 1.3, wide and narrow).
- **Extension identity:** the real check against stub pis (`ExtensionIdentityTests`, and
  `ExtensionIdentityFlowTests` through the app's own launch): a pi's own process is served for
  its agent, a process it starts is refused and displaces no connection, this process claiming
  another agent is refused for every kind of message, a replaced pi speaks no more, a pi not yet
  bound to its thread speaks for the agent it was launched for; each message's `speaksFor` and `replyID`
  against its wire form (`ExtensionMessageTests`). Check the check has teeth by making it allow
  everything: these tests must fail.
- **Agent-to-agent approvals:** `AgentApprovalTests` (the server, over the real socket) for each
  setting (Ask parks, Always allow goes through, Never refuses with no dialog), each gated call
  (send, spawn, read, steer, interrupt), every way a wait ends (allow once, allow for this thread,
  deny, timeout, cancel, disconnect, Never) and that only an allow does the call, once; "Allow for
  this thread" forgotten when the pi restarts or the setting changes; an automation run under Ask
  refused; nothing a socket message sends answers a dialog (`ExtensionIdentityTests` also counts
  the dialogs a process claiming another agent opened: none). `PeerApprovalFlowTests` presses each
  button of the dialog and reads what reached the asking agent and the target.
- **Changes:** every scope on a scratch repository, the proof that reading changes leaves the
  index, HEAD, refs, the stash, `.git` and every file alone, and Undo, Redo and the refusal on a
  turn the stub pi made.
- **Core:** the status transition table, `PaneNode` operations, and state validation.
- **Migration:** terminal-era `runtime` keys, global shells and space shells dropped at startup,
  review leaves, and split terminal layouts flattened into tabs (saved layouts with a split tab
  become one tab per terminal, each keeping its session, folder and title; layouts already made of
  single-terminal tabs are not rewritten; inspector tabs and layouts with no thread are untouched).
- **Extensions:** embedded extensions byte-identical to `Extensions/*` (all twenty-one files, and
  the design skill's two files).
- **Context budget** (docs/context-budget.md): what a thread's first request carries, measured on
  a real pi (`context-budget.test.mjs`: the guard against `scripts/context-budget.json`, and the
  audit `Tests/Extensions/context-tools.json`, which names every tool a launch registers: a tool
  no row lists fails it, and `ContextToolGroupsTests` holds the Context card's groups to the same
  file); the counting, on synthetic captures (`Tests/Release/test_context_budget.py`); context
  clearing against a real pi and a fake provider (`context-trim.test.mjs`: the request shrinks and
  the session file and `get_messages` keep everything, off is byte-identical, a restart, `/new`,
  a branch and a compaction decide the same way, a long run never compacts; `context-mcp.test.mjs`:
  an MCP result is cleared like any other, and a tool a cleared `tool_search` loaded is still
  declared and called); deferred tools against a real pi and a fake provider (`defer-tools.test.mjs`:
  no deferred tool or tool-list line in a thread's first request, one rule line saying they exist, each
  family found by its obvious query, loaded whole and called, a cleared search result not unloading it, a
  restart keeping what was loaded, the switch off or no `tool_search` sending every tool, a watch agent, a
  design's agent, a design reference and a subagent each getting their own set, and the status extension
  alone); the card's estimate
  (`ContextEstimateTests`: the baseline from the first call's usage, reasoning, images and Other),
  its presentation and wire (`ContextPresentationTests`, `NativeThreadWireTests`), and the
  Compact at setting (`PiCompactionThresholdTests`, `CompactionThresholdFlowTests`).
- **Themes:** every theme variant complete, and the WCAG contrast rules met.
- **Design rules:** `DesignRulesTests` scans the Mac app, ShepherdUI and the iOS client for a
  literal font size, a status color tinted by an opacity, a raw color and a registered glyph named
  as a string (`NWGlyph`), with a table pinning each pattern and `DesignRuleAllowlist` for what
  predates them. The allowlist only shrinks; never add an entry for new code.
- **Thread layout:** every kind of row in `LongThreads` (a paragraph with a path and a link that
  cannot break, a table, activity lines whose label names boards or a page, calls with long
  arguments, a compaction, a question, a steer) fits the thread's column, in a design's chat
  (420pt), the narrowest thread column (400pt) and a phone's, at text scales 1 and 1.3, and an
  opened activity line fits too (`ThreadFitTests`: nothing is drawn in the thread's right gutter).
  A row that cannot shrink widens the stack every row shares and runs the whole thread off its pane.
- **Composer menus:** `ComposerMenuTests` checks all window widths without moving the card,
  transcript inset or scroll position, and keeps the menu anchored above the card. Settings-menu
  height uses `ModelCatalog.settingsModels` with the fixture catalog, current model and
  `RecentModels.load()`, plus the All models row: a previous model choice can add a second quick
  choice. Thinking-segment wrapping uses the same row count, not a wider bounds tolerance.
- **App logic:** keybindings (defaults, validation, stored overrides for removed actions
  ignored), palette and settings search, workspace selection and parking, sidebar ordering and
  reveal, pinned threads (their order, persistence and pruning, Needs you winning, the digits),
  review rows and diff parsing, `PiSessionFile` paths, and child runs.
- **Updates and editions:** each channel's feed and Sparkle tag, the channels each app offers,
  the launch migration of every stored channel (`UpdateChannelStore`: rc and nightly to Beta,
  the nightly notice armed once), the support directory and listener port per edition, and the
  release rules (every trigger, feed routing, the legacy aliases, every feed item arm64 only).

CI (`.github/workflows/ci.yml`) is one Swift job beside two Ubuntu ones. `CI` is the one check
to require: it passes when every job passed or was skipped on purpose. There are no workflow
path filters, because a filtered-out workflow never reports `CI`; the `plan` job
(`scripts/ci_plan.py`) decides instead, and a pull request that touches only docs, templates,
the iOS client, `Extensions/`, `Tests/Extensions/`, `Tests/Release/` or the release scripts runs
no Swift (the extension tests and release rules always run). The RPC fixture decodes stdout
and stderr with Node's streaming UTF-8 decoder; `rpc-harness.test.mjs` splits emoji at each
byte boundary through the actual reader. The codemode excerpt test compares every persisted
output, not only the first call. Tests that depend on the machine's
speed skip on CI (`CI=true`, `.timingSensitive`).

- **The Swift job** (`swift tests`) is `swift build --build-tests` on top of the last build, then
  `swift test --no-parallel --skip-build`, once, with a 60-minute ceiling for a cold hosted
  build and full suite. The job stages pi and puts its checksum-pinned Node on `GITHUB_PATH`
  before tests; SDK fixtures that request `node` never depend on a system installation.
  The serial setting prevents Swift 6.3 from launching every process,
  socket and server test together. A full parallel self-hosted run timed out unrelated tests
  and aborted after 51 seconds. The app suites also retain `.mainActorExclusive`. There is no
  retry: a test that fails is red, and a flaky test is a bug to fix in the test. The full
  `swift test` log is uploaded only when the job fails (`ci-swift-test-log`); the step prints
  the last 20 lines on success or 120 on failure. Swift's exit status decides the result,
  never sample failure text printed by tests of the app's log reader. Failed UI tests report
  settle call sites and RGB-change bounds, clipboard selection and a fresh named-board control,
  terminal marker coordinates, paging geometry and hidden-spinner state. They retain their
  assertions and deadlines, and log no raw terminal output or user clipboard contents.
  Settle failures report wake-up, layout and capture durations separately; a delayed timer
  and a slow render are not a reason to change pixel comparisons. The terminal fixture builds
  its output marker with `printf`, so a command echo or shell error cannot satisfy the output
  check, regardless of the visible screen's cursor position.
- **Which tests run:** ordinary PRs into `nightly` retain every unit suite, the previous 13
  smoke suites and the feature/module suites affected by changed paths. The smoke set includes
  `NativeThreadTests`, so RPC child commands never depend on a feature rule. Thread and layout
  rules include hidden-layout, completion-painting and scroll regressions. Shared contracts,
  server core, test support, CI changes and unknown paths run all tests. PRs into `master`,
  `master` pushes, daily/manual runs and the `full-ci` label also run all tests. Clearly non-Swift
  PRs still skip Swift, including docs-only `master` PRs. The planner emits fixed regexes, and
  `swift test list --skip-build` must find a native test ID for every selected pattern before
  `--filter` runs it. A renamed or empty selection fails instead of passing a zero-test gate.
  There are no duration estimates, shards or retry/report databases. Label changes reevaluate
  `full-ci`. Closing a PR supersedes its old run through native concurrency; the closing run
  skips planning and every dependent job, releasing the self-hosted runner without new tests.
- **Where it runs:** a same-repository pull request authored by account ID `19316389` (Baily) or
  `3370624` (Josh), triggered by the same account, runs on the self-hosted Mac (the runner's sole
  custom label, `shepherd-release`). The native `runs-on` expression checks `github.workflow_ref`
  against this repository's `ci.yml` at the pull request's merge ref before checkout; checkout
  code and plan outputs cannot change its decision. Everything else (forks, unknown actors, a
  rerun by the other maintainer, `master` pushes, the daily run, manual runs) runs on
  `macos-26`. An explicit maintainer branch dispatch with `diagnostics=ui` is the only manual
  exception; it uses the same actor, triggering-actor and workflow-identity fence. Its aggregate
  check is named `UI diagnostics`, so it cannot replace the required `CI` check. The planner
  validates its fixed menu, clipboard, pane, paging and idle-cost filters against native test IDs.
  Self-hosted test jobs require the build account's `gui/<uid>` launchd domain and their own
  Aqua bootstrap context before checkout or compilation. A system runner service cannot use
  the account's pasteboard merely because the account is logged in. Use its per-user runner
  agent and keep the account logged in; locking or disconnecting Screen Sharing is fine,
  logging out takes the runner offline. Fast User Switching preserves other sessions.
  The preflight fails with an actionable error; it never logs in an account or takes focus.
  Names alone grant no trust; `Tests/Release/test_ci_runner.py` exercises both
  allowed IDs and each rejected condition without contacting GitHub. The job references
  `SELFHOSTED_HOSTNAME` in its env to mask the machine name in the runner's setup log.
  This is routing, not a platform security boundary: a pull request runs its own copy of the
  workflow and can edit the guard. Keep GitHub's `all_external_contributors` approval policy;
  no workflow guard replaces it.
- **The persistent build:** on the self-hosted runner the checkout, `.build` and the pi engine's
  downloads (`.build/pi-engine-cache`) stay on disk between jobs, so a run is an incremental
  build plus the tests. Measure cold and warm runs before assigning a time budget. The
  runner's hooks leave `build/` and `.build/` alone and remove them only when the disk is under
  40 GiB (a clean build follows); a job never starts under 20 GiB. The swift-build action
  records the toolchain that built `.build` (`.build/ci-toolchain`) and starts over when Xcode
  or the SDK changed, or when a manual run asks for `clean`. Checkout disables ignored-file cleanup
  on the self-hosted runner and retains no repository credentials. SwiftPM's native build system
  reruns a target only when a *direct* dependency's module changes, so a change to
  `ShepherdCore` could leave `ShepherdProtocolUnitTests` (which calls it through
  `ShepherdProtocol`) compiled against the old one; the action removes `swift-version-*.txt`,
  an input of every compile command, before each build so every target's driver runs and
  recompiles what any module it loaded changed (seconds when nothing did). Hosted runners start
  empty and restore the branch's newest `.build` from the Actions cache instead, keyed on the
  toolchain and `Package.resolved`; only pushes save.
- **Nightly publication** runs no test suites on push. Its release workflow skips the Python
  test preflight but keeps signing, notarization and artifact verification. Required PR checks
  still apply before merging. CI competes with the Nightly release for the one runner: a
  release waits up to fifteen minutes for it before building on GitHub instead ([releases](releases.md)).
- **The steer-send soak** runs the real-host send/scroll scenario once on CI, retaining every
  assertion. Local timing-enabled runs repeat it five times; `SHEPHERD_TIMING_TESTS=1` restores
  that repetition on CI too. No thread suite is excluded because it contains known issues.
  The child-command routing test retires its success-phase async-let before starting the
  failure phase, keeping the same assertions without overlapping cleanup allocations.
  The paging regression checks both success and failure without moving the original visible
  turn. Anchor correction completes pending native layout before reading its final position.
  `threadHistoryLayoutMatrix` renders real store-driven empty, idle and long threads in both
  appearances and at text scales 1 and 1.3.
  Scroll tests still inspect rendered text and pill pixels. Only repeated whole-window pill OCR
  polls use a 500 ms interval; position assertions and timeouts are unchanged.
- **The daily run** tests `master` on `macos-26`; `gh workflow run ci.yml --ref <branch>` runs
  the same by hand (`-f clean=true` builds from scratch).
  `gh workflow run ci.yml --ref <branch> -f diagnostics=ui` collects focused failures in the
  real self-hosted runner context without rerunning all suites or changing PR coverage.
- **Release rules** run on `ubuntu-latest` (stdlib Python): the release workflow's, the CI
  workflow's and plan's, the docs' and the embedded extensions'. **Extension tests** run there
  too, with Node 24 and the modular pi package version from `scripts/pi-engine-pin.json`,
  installed with lifecycle scripts disabled and cached on the pin.
- **Checking a CI change:** a pull request's run exercises the pull request's copy of the
  workflow. On the self-hosted runner, push a small source change and read the build step: it
  records the work required by changed source and module inputs. A corrupt persistent build:
  run the workflow by hand with `clean`, or remove `.build` in the idle runner's checkout as the
  build account.
