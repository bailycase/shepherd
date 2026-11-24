# Testing

> Read when you write or change a test, pick a test tier, or touch CI.

Swift Testing only (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`), never XCTest.
Tests come in tiers. Use `--filter` to select the affected suite or test, or a target for broader coverage.

| Tier | Targets | What belongs there |
| --- | --- | --- |
| Unit | `*UnitTests` | Pure logic: models, parsers, projections, presentation, keybindings. No `Process`, sockets, `SessionServer.start()`, `NSWindow`, git, timers, `Task.sleep` or polling. Well under 50 ms each. |
| Integration | `ShepherdSessionsIntegrationTests`, `ShepherdAppIntegrationTests`, `DesignSurfaceKitIntegrationTests` | A real `SessionServer`, the stub pi, git, off-screen windows, web views. |
| Previews | `ShepherdPreviewTests` | Off-screen renders of every surface, light and dark, as PNGs. Skipped unless `SHEPHERD_PREVIEW_DIR` is set. |
| Extensions | `Tests/Extensions/*.test.mjs` | The bundled pi extensions against the staged engine and a local fake provider (`PI_PACKAGE_DIR`). |
| Release | `Tests/Release` (Python `unittest`) | `scripts/release.py`, `pi_engine.py`, `ci_plan.py`, packaging checks and the docs guards. |

Reuse coverage that protects the affected behavior. Add or extend tests for new behavior or
an unprotected regression; behavior-preserving refactors need no new tests just because code moved.
Pure logic belongs in unit tests; server mutations, process lifecycles, sockets, remote protocols
and git flows belong in integration tests. New `SessionServer` mutations need integration tests;
protocol changes keep consumer and round-trip coverage. Visible changes get affected previews in
both appearances. Name a test as a sentence of the behavior (`deletingASpaceKeepsNestedSpaces`).
A test that finds a real bug stays, with the failing part in `withKnownIssue`.

## Local validation

Run the smallest selection that protects the affected behavior. These are independent examples,
not a checklist; replace the suite, test or file with the one relevant to the change:

```bash
scripts/check.py ShepherdCoreUnitTests PaneNodeTests
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews scripts/check.py ShepherdPreviewTests ThreadPreviewTests/threadActivityIdle
python3 scripts/pi_engine.py stage   # once; re-run after the pin changes
PI_PACKAGE_DIR="$PWD/.build/pi-engine/Resources/pi-engine" .build/pi-engine/Helpers/node --test Tests/Extensions/instructions.test.mjs
python3 -m unittest discover -s Tests/Release -p 'test_agent_docs.py'
```

Use the staged Node locally: older Node versions may lack the TypeScript transform mode some extension tests need. Use `Tests/Extensions/*.test.mjs` for the whole suite.

`scripts/check.py <TestTarget> [filter]` builds only that test target (its folder under `Tests/`)
and its dependencies, then runs it with the filter. `swift test --filter` builds every test target
first: about twice the CPU of the app unit target alone, cold. The script holds a per-user lock,
so builds from several worktrees queue instead of competing for every core, and it prints errors,
failing tests and the run summary (`--verbose` prints everything). Validate once edits settle, not
after each one. Check that the summary counts the tests you meant to run.
Use [Xcode](build-and-run.md) when the change needs app-level validation, not as a test prerequisite.
Docs-only changes need the applicable docs guards, not Swift builds or tests.

The five rebuild checks each run one filtered suite and save evidence under `.build/validation/`. Each exits
non-zero on failure. `c-launch` is an optional diagnostic, not a required gate.

| Case | What it holds |
| --- | --- |
| `c-state` | the `state.json` shapes earlier builds wrote still load and rewrite as recorded |
| `c-auth` | the host sockets' refusal corpus |
| `c-settings` | every settings write path |
| `c-wire` | the codec and the request sequences of a scratch host |
| `c-launch` | a scratch host starts under launchd's 256-descriptor soft limit with 150 synced checkouts (30 with a worktree). From host start it answers `host.sock` within 20 s and answers again after Fleet's first scan within 30 s. It checks TCP isolation and descriptor samples, then repeats startup from the oldest `state.json` shape, rebased into scratch. |

`c-launch` was red on `nightly` until the Fleet watcher fix (#884) and the index watcher fix (#880)
merged. Fleet's file watcher opened a descriptor per watched file for every file it added, so a host with 150 synced checkouts
ran out of descriptors and indexed none of them. #879 (start Fleet after `host.sock`
binds) is not merged: once it is, `HostLaunchTests` must pass `startFleet: true` to `SessionHost.run`, as `ShepherdHost.main` will;
without it the test fails on "the index never reached every checkout".

`c-launch` requires a baseline and fresh samples at index readiness and after the first scan. Both counts must stay below 256,
with growth of at most two descriptors per synced space. It fails on a sampled peak within 32 of the limit, a sampled
`open()` probe reporting `EMFILE` or `ENFILE`, or evidence of a TCP listener. Samples can miss spikes between ticks. The host
keeps Bonjour and iCloud lookup off. Run `python3 scripts/validate.py --case c-launch` to opt in.

The child stops when the test process exits, its own deadline expires, or the test writes its `stop` file. Bounded controls
check that both the workspace and child isolation root are gone after each early stop. The test never signals the host by PID.

An unfiltered `swift test -j 4` now finishes in about an hour. It currently reports roughly 900 to
1,000 failures; most of those tests pass when run alone. For PR work, use filtered runs and the
applicable `scripts/validate.py --case` gates. Expand to a whole tier (`--filter UnitTests` or
`--filter IntegrationTests`) when needed. The [CI planner](#ci) selects broader coverage before merge.
`CI=true swift test` still skips timing-sensitive tests, and opt-in suites such as previews stay gated.

## Simulator renders

`bash Tests/ShepherdIOSChecks/run-simulator.sh --platform <iphone|ipad|duo> --set <dir> -o <dir> <screen>...`
renders fixture screens headless and saves light and dark PNGs (`--list` prints the screens).
Devices are created in a custom simulator set (`--set <dir>` or `SHEPHERD_SIMULATOR_SET`)
and deleted afterwards; `-d <udid>` reuses a device you own instead. iPhone and iPad render on
the iOS 27.0 runtime, Duo on iOS 27.1, and Duo poses (`-f`) need Xcode 27.1 (`DEVELOPER_DIR=…`,
SwiftUI 8.0.85+). A platform whose device cannot be created prints `not run` and is skipped.

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
- `AppHarness`: the Mac app's stores and views as the client of a scratch server served as `Shepherd --host` serves (`ShepherdHost.Services`) over a real `host.sock`, with a per-harness pi home.
- `OffscreenWindow`, `ControlPress`: an off-screen window and a press through the accessibility
  tree (below).
- `ScrollTrace`: a thread's scroll view recorded as it changes, for scroll-rule tests.
- `SHRenderProbe.tick("sidebar.row")` at the top of a row's `body` counts row bodies; the
  `ListPerformanceTests` budgets read it. Counts hold on a busy runner; timings don't, so budgets
  are counts.

Previews: each domain has a suite in `Tests/ShepherdPreviewTests` (`ThreadPreviewTests`,
`NavigationPreviewTests`, `AgentsPreviewTests`, `ReviewPreviewTests`, `SettingsPreviewTests`,
`DesignPreviewTests`, `PreviewTests` for the rest). `Preview.render` draws light and dark;
`Preview.renderMatrix` adds text scale 1.3. `PreviewWorkspace` serves its workspace as a host and
draws the view model as its client; the `this-mac-*` renders (`LocalHostRuntimePreviewTests`) compare
against the PNGs in `Tests/ShepherdPreviewTests/Baselines`. Drive a preview from the real producer (a store, an
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
test). Swift Testing records an issue and requests cancellation from the cooperative pool. It
cannot interrupt a blocking call or report on time if that pool is starved. Use async waits;
use `blocking` when testing an API that must block, and `testHop` to access queue-owned
state from an async test. `@MainActor` suites carry `.mainActorExclusive` instead and never
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

PR CI runs only for pull requests targeting `master`, not `nightly`. Pushes to `master`,
the daily schedule and manual dispatch keep their existing triggers.

The hosted `other` lane also runs `Tests/ShepherdIOSChecks/run.sh --sidebar-only`: readiness, host-client and
sidebar loopback checks, with exact completion sentinels. This is not the full iOS checker or rendered UI
validation. Failed compiler outputs and the client-check log are retained in its CI artifact.

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
