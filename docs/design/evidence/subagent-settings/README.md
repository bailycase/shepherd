# Subagents Settings evidence

Implements `SubagentsSettings.dc.html@598` on `feat/subagent-settings-manager`.
The unchanged supplied PNG is [`../../boards/SubagentsSettings.png`](../../boards/SubagentsSettings.png).
The element, state, string and action checklist is [`../../settings-subagents.md`](../../settings-subagents.md).

## Running app

`app/` contains 38 captures from the bundled Shepherd Dev executable, hosting the real
RootView and Settings navigation. Profiles come from actual Markdown files in a scratch pi
home through SubagentDefinitionsStore and the bundled runtime parser. No model calls or
user settings, sessions, browser data or profile directories were used.

The window remained off-screen. Captures include light and dark at 1440pt, 1050pt, 720pt and
2400pt, plus text scale 1.3. They cover the populated and no-match lists, existing-profile
editor, new-profile editor and the Pi switches/defaults that remain available there.

- [Dark list](app/app-subagents-populated-board-dark.png)
- [Light list](app/app-subagents-populated-board-light.png)
- [Narrow list](app/app-subagents-populated-narrow-dark.png)
- [Large-text list](app/app-subagents-populated-large-text-light.png)
- [Native editor](app/app-subagents-editor-board-dark.png)
- [New profile, large text](app/app-subagents-new-large-text-light.png)
- [Pi defaults](app/app-subagents-pi-defaults-board-light.png)
- [List gallery](gallery-list.png)
- [Editing gallery](gallery-editing.png)
- [Board and bundled app](board-and-app.png)

The temporary capture source and launcher hook were removed before the shipping build.

## Preview matrix

`previews/` contains 44 renders through the real owned-file store. The matrix covers populated,
filtered-empty, empty, long text, invalid, editor and new states. Both appearances, text scale
1.3 and narrow widths are included. The editor render uses the real file text, not board sample
strings. Invalid files keep their actual diagnostic and filename.

## Controls and file behavior

SubagentSettingsControlTests uses native ControlPress accessibility actions in exit-test
processes. It verifies New, row opening, Show in Finder, Save, Open in editor, Delete,
Restore defaults, Cancel, Back and discard navigation. Assertions cover disk readback,
untouched custom files, canceled actions, dirty drafts, native request URLs and 24pt hit areas.
Editor text remains editable and empty text is not mistaken for a successfully loaded profile.
SettingsFullWidthTests presses every Settings destination while checking page width after
resize; Subagents' initial read does not block navigation. ListPerformanceTests keeps the
300-custom-profile render within the existing lazy-row budget.

Store regressions cover stale save/delete/restore snapshots, no-follow traversal, duplicate
names, unsupported fields, oversized and invalid UTF-8 defaults, concurrent initialization,
persistent default deletion, catalog file/folder bounds and paths that discovery ignores.
The extension regressions exercise the real Pi RPC child lifecycle and single-folder discovery.
The capacity fixture pins its default to four instead of inheriting the supervising agent's
concurrency setting.

## Review and differences

The code review found prospective catalog overflow, ignored-directory saves and duplicate
names during Restore. All now fail before writing, with regression tests. The design review
found the wrong filter magnifier and incomplete keyboard-focus highlighting. The filter now
uses the supplied search drawing at 13pt; focused rows get the drawn background, border and
blue ring.

Departures: none from the supplied list after applying the later all-Settings full-width
requirement. The native editor is an added working screen, not a claimed copy of an unavailable
detail board. Native text antialiasing differs from browser rendering. Counts, filenames,
descriptions and the retained planner default come from actual files rather than the board's
example data.

## Validation

The final focused Swift selection passed 51 tests across 8 suites with CI enabled. The additional
native lazy-list check passed its 1 test. The affected
extension selection passed 58 tests. The release checks passed 421 tests. The shipping Dev
build and refreshed capture checks are recorded in the pull request. Physical macOS 26, a second
Mac and remote profile editing were not verified. The manager edits this viewer Mac's owned
files; it does not synchronize another host's profiles.

One aborted capture attempt used incorrect isolation variables and started the Dev app against
the stable Shepherd support directory. That process exited. No screenshots from that attempt
are included, and user data was not inspected or reverted. The temporary capture entry point
refused incomplete scratch settings with exit code 64 before the successful isolated rerun;
it is removed before shipping.
