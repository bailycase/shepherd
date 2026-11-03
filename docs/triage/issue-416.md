# Issue #416: BLOCKED triage, not a bug fix

## Summary

Refs #416: https://github.com/bailycase/shepherd/issues/416

The issue was OPEN on 2026-11-03. It is an issue in bailycase/shepherd, not a pull request. Its discussion was empty, its timeline contained only a label event, and the open PR listing and all-state PR search for `416` showed no matching implementation PR. This run handled only #416.

No behavior change or reproduction test is included. The reported Command+N failure remains unverified and unresolved. This report preserves triage because ready-for-review publication crosses the run's explicit no-auto-merge boundary.

### Evidence and affected flow

Inspected fetched `origin/nightly` at `7a6588b30f2129b4390ec90ea3b2d12ce8b30b4c` in the supplied clean isolated worktree.

- `Sources/ShepherdApp/Keybindings.swift`: `ShortcutAction.newAgent` defaults to Command+N. `KeybindingsStore.chord(for:)` uses a saved override when present. Actual user overrides were not read.
- `Sources/ShepherdApp/ShepherdApp.swift`: workspace commands, including `FileCommands`, are installed once `launch.model` exists.
- `Sources/ShepherdApp/AppCommands.swift`: File > New Thread reads the shortcut from the store and schedules `vm.openNewThread()` on the main actor.
- `Sources/ShepherdApp/ShepherdViewModel+Navigation.swift`: `openNewThread()` opens the New thread destination and increments its focus request. The command palette, project/sidebar flows and dialogs also use this shared method. The sidebar destination route calls `openDestination(.newThread)` directly.
- `Sources/TerminalSurfaceKit/TerminalSurfaceModel.swift`: `appOwnedChords` already includes `cmd+n`; custom app-wide overrides also flow through `customGhosttyUnbinds` in the keybinding store.
- `Sources/ShepherdApp/ShepherdViewModel.swift`: the navigation key monitor handles agent digits and adjacent-agent chords, not New Thread. This alone does not establish a routing defect.
- Existing checks in `Tests/ShepherdAppUnitTests/KeybindingsTests.swift` and `Tests/TerminalSurfaceKitUnitTests/TerminalSurfaceConfigTests.swift` cover the default display and configured terminal unbind. Source inspection is not proof of end-to-end shortcut delivery.

The issue does not identify the focused control, any custom binding, whether File > New Thread works, or whether the New thread page was already shown. Adding another binding or intercepting Command+N without reproducing the failure would guess at the cause.

### Reproduction and next implementation steps

1. In an isolated Dev-app or off-screen integration harness, verify File > New Thread and the effective `newAgent` shortcut using scratch defaults, not the installed app's settings.
2. Compare the shortcut from a thread composer, terminal, Browser surface and sidebar. Also test when the New thread page is already shown and after rebinding the shortcut.
3. Determine whether failure occurs before the menu action, inside destination selection, or during composer focus acquisition. Follow existing `ControlPress` and `OffscreenWindow` patterns; do not post input to the user's running app.
4. Fix the shared failing boundary and add the smallest regression test that fails before the fix. Inspect light/dark renders if the fix changes appearance.

### Publication blocker

The canonical workflow at https://github.com/bailycase/shepherd/blob/nightly/.github/workflows/auto-merge.yml runs on ready, non-draft PRs targeting nightly, including PR opening and subsequent updates. For either of its two listed author IDs, it invokes `gh pr merge ... --auto --squash`.

Creating the requested ready PR can therefore enable auto-merge automatically, contrary to this run's explicit prohibition. A draft is also prohibited. Disabling auto-merge after PR creation would introduce a race, not prevent the forbidden side effect. No PR was created and no workflow, repository setting, issue state, label or comment was changed. No merge or auto-merge command was run.

Next step: the user must arrange a repository-side opt-out from automatic merging for this PR before publication. Then open a ready-for-review PR from the preserved branch into nightly titled `docs: BLOCKED triage for issue #416 new-thread shortcut`, using this report to fill the repository PR template. Use Refs #416, not Fixes #416. Do not resume this task unattended.

## Tests run

- Git worktree/status inspection: supplied checkout was isolated and clean before this report.
- GitHub issue, timeline and PR queries: succeeded; results described above.
- `git fetch origin nightly`: succeeded.
- Canonical workflow lookup through GitHub's contents API: succeeded.
- LSP status: no Swift language server configured; source inspection used instead.
- No Swift build, tests, app launch or visual rendering ran. This documentation-only triage does not claim behavior validation.

## Notes for reviewers

Review the publication blocker first, then reproduce shortcut delivery before choosing a fix. No dependencies, providers, automation loops or product behavior were added. No user app-support data, running Shepherd instance or production service was accessed. The remaining work is reproduction, implementation, regression validation and safe ready-for-review PR publication.
