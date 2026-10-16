# Testing

> Read when you write or change a test, pick a test tier, or touch CI.

Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), never XCTest.
Tests come in tiers, and the switch is `--filter` on target names.

| Tier | Targets | What belongs there |
| --- | --- | --- |
| Unit | `*UnitTests` | Pure logic: models, parsers, projections, presentation, keybindings. No `Process`, sockets, `SessionServer.start()`, `NSWindow`, git, timers, `Task.sleep` or polling. Well under 50 ms each. |
| Integration | `ShepherdSessionsIntegrationTests`, `ShepherdAppIntegrationTests`, `DesignSurfaceKitIntegrationTests` | A real `SessionServer`, the stub pi, git, off-screen windows, web views. |
| Previews | `ShepherdPreviewTests` | Off-screen renders of every surface, light and dark, as PNGs. Skipped unless `SHEPHERD_PREVIEW_DIR` is set. |
| Extensions | `Tests/Extensions/*.test.mjs` | The bundled pi extensions against the staged engine and a local fake provider (`PI_PACKAGE_DIR`). |
| Release | `Tests/Release` (Python `unittest`) | `scripts/release.py`, `pi_engine.py`, `ci_plan.py`, packaging checks and the docs guards. |

Which tier: a model, parser, projection or presentation change gets a unit test; a server
mutation, process lifecycle, socket, remote-protocol or git flow gets an integration test; a
visible change gets a preview render in both appearances. Name a test as a sentence of the
behavior (`deletingASpaceKeepsNestedSpaces`). A test that finds a real bug stays, with the failing
part in `withKnownIssue`.

```bash
swift test --filter UnitTests
swift test --filter IntegrationTests
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter ThreadPreviewTests
PI_PACKAGE_DIR=/path/to/pinned/pi/package node --test Tests/Extensions/*.test.mjs
python3 -m unittest discover -s Tests/Release
CI=true swift test            # what CI runs: timing-sensitive tests skipped
```

## Helpers

Unit targets may use `Tests/ShepherdTestKit` (no Shepherd dependency): `ScratchDefaults`,
`makeScratchDirectory()`, `Locked`, `CommandFailure`, `TestProcess`.
Integration and preview targets use `Tests/ShepherdTestSupport`, which re-exports it:

- `ScratchServer`: a real `SessionServer` on scratch paths that records every broadcast state. It
  lets a raw `ExtensionClient` speak as any agent (`extensionPeerCheck`); a test of the identity
  rule itself calls `useRealPeerCheck()` and runs stub pis. Tests asserting an exact Projects
  listing pass a per-test `PiSetup`, since the shared home collects other suites' session headers.
- `StubPi.command`: `Resources/stub-pi.py`, a scripted `pi --mode rpc` driven by prompt keywords
  (`ask`, `select`, `hang`, `die`, `big`, `slow`, `tools:N`, …). `STUB_PI_*` variables seed a long
  history, delay or fail its boot, or make it speak on the extension socket as an agent.
  `StubPi.installAsEngine()` installs it as `SHEPHERD_PI_ENGINE` for code that launches pi the
  way the app does; launches are recorded in `TestProcess.piLaunches`.
- `makeScratchRepo()` and `git(_:in:)`: a repository with one commit; a failing call throws
  `CommandFailure` with git's stderr.
- `makeScratchDirectory()`: a short `mkdtemp` path, because `sun_path` caps socket paths at 104 bytes.
- `LoopbackServer`, `DevServerFixture`: a loopback stand-in for a host's dev server in tunnel and
  browser tests. Never the network.
- `eventually("what", …)` and `eventuallyOnMain`: named 10 ms polls that throw `WaitTimeout` saying
  what never happened. Never sleep a fixed amount.
- `AppHarness`: the Mac app's stores and views over a scratch server, with a per-harness pi home.
- `OffscreenWindow`, `ControlPress`: an off-screen window and a press through the accessibility
  tree (below).
- `ScrollTrace`: a thread's scroll view recorded as it changes, for scroll-rule tests.
- `NWRenderProbe.tick("sidebar.row")` at the top of a row's `body` counts row bodies; the
  `ListPerformanceTests` budgets read it. Counts hold on a busy runner; timings don't, so budgets
  are counts.

Previews: each domain has a suite in `Tests/ShepherdPreviewTests` (`ThreadPreviewTests`,
`NavigationPreviewTests`, `AgentsPreviewTests`, `ReviewPreviewTests`, `SettingsPreviewTests`,
`DesignPreviewTests`, `PreviewTests` for the rest). `Preview.render` draws light and dark;
`Preview.renderMatrix` adds text scale 1.3. Drive a preview from the real producer (a store, an
extension's output, a formatter), not strings copied from a design.

## Rules

**Process-wide state is set once, never by a test.** No `setenv`, `unsetenv`, `signal`, `chdir`
or `umask`. `Tests/ShepherdTestIsolation` (linked through `ShepherdTestKit`) points the support
directory, Shepherd's pi home, "your pi", `ZDOTDIR` and git's global config at a scratch root
before any test runs, puts stand-ins for `gh` and `pi` that refuse to run first on `PATH`, and sets
`SHEPHERD_PI_ENGINE` to a stub that refuses until a test installs over it. A target depends on
`ShepherdTestKit` whenever the code it tests can reach the support directory, pi's directory,
`UserDefaults`, the drop directory or a shell. Otherwise pass state in (`PiSetup`,
`ShepherdPaths.supportDirectory(environment:)`). A store that takes `UserDefaults` gets
`ScratchDefaults()`, never a named suite (cfprefsd writes it back under `~/Library/Preferences`).
A test that needs process-wide state anyway runs as an exit test
(`await #expect(processExitsWith: .success) { … }`) wrapped in `recordingErrors`.

**Tests never take the user's focus or drive their mouse or keyboard.** Windows sit off-screen
(`x: -30_000`), borderless, `orderBack`; never `makeKey`, `orderFront` or a posted event. Nothing
touches the user's support directory, preferences, pi configuration, `~/.agents` or a running Shepherd.

**Time limits.** Integration and preview suites carry `.integrationTimeLimit` (two minutes per
test, so a hang fails by name). `@MainActor` suites carry `.mainActorExclusive` instead and never
a `.timeLimit` beside it: that clock also runs while the test waits for the main thread.
`.serialized` orders tests within a suite and isolates nothing; every suite of a target shares
one process.

**Timing-sensitive tests** (`.timingSensitive`: motion frame sampling, wall-clock budgets) are
skipped when `CI=true` unless `SHEPHERD_TIMING_TESTS=1`. Never mark a test timing-sensitive to
hide a short wait; give it a condition to wait on.

**Opt-in runs.** `SHEPHERD_LIVE_MODEL` runs the use-case suite against a real model.
`SHEPHERD_ENGINE_SMOKE` runs `EngineSmokeTests` and `EngineThreadTests` against the shipped engine
(run both and the extension tests on every pin bump). `SHEPHERD_PERF_REPORT=1 … --filter
ListPerformanceReport` prints list timings; `SHEPHERD_BENCHMARK=1` the data-path benchmarks.
`python3 scripts/test-browser-persistence.py` runs the Browser's disk-persistence checks
(macOS 27+).

## Pressing a control

`ControlPress` finds a control in the window's accessibility tree by label and runs its press
action, as VoiceOver does; nothing is posted. SwiftUI only builds that tree while an assistive
client is attached, and attaching is process-wide, so each scenario is an exit test:

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

`press("Fast", in: "Speed")` scopes to a group, `press("Edit", nth: 1)` picks among equals,
`press(_, role:)` chooses a role. A missing, disabled or hidden control throws a
`ControlPressError` listing every control the window offers. `window.controls()` lists them with
frames; `ControlPress.undersized(_, minimum: .desktop)` (24pt) or `.touch` (44pt) names those too
small. A combined row's hover buttons are its accessibility actions:
`ControlPress.perform("Reply", onLabelContaining: "reviewer", under: host)`. Run the body with
`completingScenario` and check `expectScenarioCompleted` in the parent, since a child that exits
early with status 0 also passes. `ModelSettingsPopoverTests` is the worked example.

## CI

`scripts/ci_plan.py` picks what runs from the changed paths: docs, templates and the Xcode
project run no Swift; a pull request runs the unit suites, the startup and identity smoke tests
and the integration suites of the areas its paths touch, and a path no area claims runs its
module's suites. Broad app, sessions and remote selections use four filtered lanes, not one serial
runner. Remote-client unit tests remain in every Swift run. Shared contracts (`ShepherdCore`, `ShepherdProtocol`, the test
support, `Package.swift`, the engine pin, the script itself), `master`, the daily run and a
`full-ci` label run everything across four hosted lanes. The pixel-scanning suites in
`ci_plan.DEEP` (the completion matrix and reproduction, tail flow, send scrolling, blank screen,
design performance) normally run only there and on the manual UI diagnostics dispatch. A changed
test file still runs its own tests, including slow diagnostics. `nightly` ships without rerunning tests. Failed Swift runs keep the log and the
completion captures as a seven-day artifact.

Hosted builds restore timestamps only for tracked files whose bytes match the cached input
manifest, so a fresh checkout does not re-emit unchanged modules or recopy resources. Changed
files keep their checkout timestamps; missing metadata uses normal invalidation. Swift file
hashing and dependency checks stay enabled. Only one lane saves the shared build cache.
