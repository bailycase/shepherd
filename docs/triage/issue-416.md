# Issue #416: Command+N does not create a new thread

Issue: https://github.com/bailycase/shepherd/issues/416

## Status

Implemented and focused tests pass. Publication safety has been verified against
canonical GitHub state; no repository settings needed changing. The issue has
not been modified.

## Evidence and root cause

- Canonical GitHub state was an open issue in `bailycase/shepherd`, not a PR.
  Discussion and timeline contained no further reproduction evidence or linked
  fix. No active PR for #416 was found.
- `KeybindingsStore` defaults `.newAgent` to Command+N. The File menu invokes
  `openNewThread()`, which selects the New thread page and requests composer
  focus. Default and custom app chords are released by the terminal.
- Asynchronous startup introduced a conditional around **all** workspace command
  groups in `ShepherdMacApp`. At initial scene registration, `launch.model` is
  nil, so those groups are absent.
- An isolated native SwiftUI probe reproduced the missing File menu and an
  unhandled Command+N after its model became ready. A control initialized ready
  handled the shortcut. Registering the items immediately, disabled until ready,
  handled the shortcut after native menu validation. The probe stayed offscreen
  and never activated the application. This reproduces the startup failure, not
  the original reporter's unspecified installed-app focus state.

## Implementation

`WorkspaceCommands` registers the existing menu groups unconditionally. Their
items resolve the launched model and stay disabled until workspace ownership is
acquired. This fixes the shared startup boundary rather than adding another
Command+N handler or changing the saved keybinding contract. Other workspace
menus receive the same correction. Update checks remain deferred until the
model exists.

`FileCreationMenuItems` keeps one copy of the real creation controls, shared by
the File command group and a native-menu regression test. Existing menu actions,
labels and configured chords are preserved after startup.

## Validation

Passed:

```sh
swift test --filter 'WorkspaceCommandStartupTests|TerminalFirstResponderTests/newThreadShortcut|KeybindingsTests|TerminalSurfaceConfigTests|ShepherdLaunchTests|MenuStateTests'
```

59 tests passed across the selected test bundles. The new tests verify that:

- New Thread is registered but disabled before the launch model exists.
- After launch, the native menu dispatches Command+N to New thread exactly once.
- Rebinding updates the native menu and dispatches the replacement chord.
- A focused real Ghostty surface releases Command+N to the app menu.

`swift build --target ShepherdApp` passed on the final source, including the
updater's launch guard. `git diff --check` passed.

Earlier validation failures, investigated without weakening assertions:

- The initial SwiftPM runner could not load
  `@rpath/Sparkle.framework/Versions/B/Sparkle`. Ignored local symlinks under
  `.build/out/Products/Debug/PackageFrameworks` to the built Sparkle and Sentry
  frameworks repaired the runner's framework search layout. No tracked build
  settings changed.
- The first new test harness failed to compile with
  `sending value of non-Sendable type '() async throws -> Void' risks causing data races`.
- The second harness attempted to enter SwiftUI `App.main()` from an asynchronous
  exit test and stalled in `NSApplication.run`. Only the owned test processes
  were terminated. The final harness uses `NSHostingMenu` without an application
  run loop, windows, or posted input, and passes.
- Before the implementation, the broader command
  `swift test --skip-build --filter 'KeybindingsTests|TerminalSurfaceConfigTests|WorkspaceNavigationTests|TerminalFirstResponderTests/newThreadShortcut'`
  found existing failures in `aPageHidesTheThreadAndPickingARowReturnsToIt`
  (`vm.shownDestination == page`, line 85) and
  `switchingAwayAndBackKeepsLoadedHistoryAndScrollPosition`
  (`abs(clip.bounds.origin.y - offset) < 1`, line 336). These unrelated workspace
  expectations were not changed.

## UI and remaining verification

Design: the issue's requirement that the configured shortcut invoke New thread.
Departures: none. The only intended visible difference is that native menu
items exist, disabled, while the workspace opens.

No light/dark menu screenshots or full app smoke test were captured. No running
Shepherd instance or user app-support data was accessed. The tests exercise the
real native menu items and terminal surface, not a focused full app scene.
A reviewer should smoke-test File > New Thread and the configured shortcut after
a cold launch, from both a composer and terminal, in light and dark appearances.
Settings/palette overlay dismissal is unchanged; the original reporter's exact
focus state remains unknown. Use `Refs #416`, rather than claiming the report is
fully resolved, until that app-level check confirms the reported behavior.

## Publication safety

The initial triage incorrectly treated `.github/workflows/auto-merge.yml` on
`nightly` as an active publication blocker. After the user authorized pausing it,
GitHub returned HTTP 404 for both the workflow lookup and disable endpoint.
Canonical verification found no registered auto-merge workflow, and the file is
absent from the default branch, `master`.

[GitHub's current event documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request_target)
states that `pull_request_target` runs in the context of the repository's default
branch. The file on `nightly` therefore cannot enable auto-merge for this PR.
No repository settings or workflow files were changed. Publish the non-draft PR
into `nightly` using the required template, verify its auto-merge state is unset,
and leave it open for human review.
