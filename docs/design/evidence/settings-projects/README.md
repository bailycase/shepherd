# Projects validation evidence

> Read when: reviewing Settings > Projects, its detail editors or Browser cookie settings.

The supplied boards are [SettingsProjects, revision 492](../../boards/SettingsProjects.png),
[ProjectInstructions, revision 562](../../boards/ProjectInstructions.png) and
[ProjectBrowser, revision 572](../../boards/ProjectBrowser.png).
The implementation checklists are [Projects](../../settings-projects.md),
[Instructions](../../project-instructions.md) and [Browser](../../project-browser.md).
Behavior and file-access rules are in [Projects](../../../projects.md).

## Running Dev app

[All 16 app screenshots](gallery-app.png) come from the Xcode-built `Shepherd.app`, not the
Swift test runner. The Projects list uses `RootView`. Refreshed detail screenshots mount the
actual `SettingsView` with a live local `SessionServer`, real project files and an authenticated
loopback peer. Browser screenshots read a real WebKit project cookie store. Windows stayed
off-screen and took no focus. No agent or model ran.

The latest capture reports `NSApplication.isRunning: true` and `Fonts available: true` in
[app-capture.txt](app-capture.txt). The temporary capture entry point was removed and the
shipping app rebuilt. Fixture names are inputs; paths, inventory counts, comparisons, file
contents and cookie totals come from the production data paths. No cookie names or values
appear in the images.

| Surface | Dark | Light |
| --- | --- | --- |
| Projects | [Screenshot](app/app-projects-dark.png) | [Screenshot](app/app-projects-light.png) |
| Instructions | [Screenshot](app/app-detail-instructions-dark.png) | [Screenshot](app/app-detail-instructions-light.png) |
| Settings | [Screenshot](app/app-detail-pi-dark.png) | [Screenshot](app/app-detail-pi-light.png) |
| Resources, skill | [Screenshot](app/app-detail-skills-dark.png) | [Screenshot](app/app-detail-skills-light.png) |
| Resources, extension | [Screenshot](app/app-detail-extensions-dark.png) | [Screenshot](app/app-detail-extensions-light.png) |
| MCP servers | [Screenshot](app/app-detail-mcp-dark.png) | [Screenshot](app/app-detail-mcp-light.png) |
| Browser | [Screenshot](app/app-project-browser-dark.png) | [Screenshot](app/app-project-browser-light.png) |
| Browser at 1.3 text scale | [Screenshot](app/app-project-browser-dark-x1.3.png) | [Screenshot](app/app-project-browser-light-x1.3.png) |

[Browser board and running app side by side](browser-design-comparison.png).

## Preview matrix

All 136 full-size previews are in [previews](previews/). Each state has light and dark renders
at text scales 1.0 and 1.3. Open the PNGs at their original resolution.

- [List gallery](gallery-list.png), [large text](gallery-list-large-text.png). Populated, empty,
  long names/paths, no results, offline and older hosts, narrow windows and missing directories.
- [Detail gallery](gallery-detail.png), [large text](gallery-detail-large-text.png).
  Instructions, settings, skills and extensions within Resources, MCP servers, long project
  names and the narrow editor with its context column stacked below.
- [Editing gallery](gallery-editing.png), [large text](gallery-editing-large-text.png).
  Edited, discard, saved, invalid JSON, missing skills/files, external conflicts and symlinks.
- [Browser gallery](gallery-browser.png), [large text](gallery-browser-large-text.png).
  Populated, empty, filtered, long domain, site/all confirmation, cleared and narrow states.
  [Unavailable](previews/project-browser-unsupported-dark.png) also has all four variants.
  Confirmations are staged after mount so the page's forced reload cannot erase the state.
- [Subagents gallery](gallery-subagents.png), [large text](gallery-subagents-large-text.png).
  The existing settings moved to the top-level navigation drawn by the Projects board.

## Validation

- Final `Shepherd (Dev)` Xcode build with locked package versions passed after removing the
  temporary capture hook.
- Combined focused Swift Testing passed, 153 tests in 22 suites. It covers protocol round trips,
  project history, file IO and conflicts,
  JSON comments/BOM, global-directory isolation, host identity, instruction context, local and
  remote accessibility controls, cookie scope/read failures, search, design rules and previews.
- Browser accessibility checks mount the complete Settings screen. They edit Filter sites,
  cancel and confirm site deletion, confirm project deletion, inspect hit areas, and assert
  that the sidebar and background controls disappear from the confirmation accessibility tree.
  Cookie names and values do not appear there. A sibling thread shares the same store; another
  project's cookies survive both Clear actions.
- The readback bound test reaches all 20 refresh attempts. Model tests cover a project switch
  during deletion and a failed refresh after successful deletion without stale displayed counts.
- Additional affected Browser and remote Browser checks passed, 43 tests in four suites.
- Fresh-process persistence checks passed, 8 tests in one suite. The cookie backend also covers
  localStorage/cache preservation, per-project and remote namespaces, and persistent deletion.
- Python release/documentation checks passed, 421 tests. `git diff --check` passed.

A compiler/runtime crash in a Swift Testing expectation comparing a temporary mapped array
was reproduced twice. Naming the mapped array before `#expect` preserves the assertion and
passes the history regression. A Browser control fixture initially selected the protected
support directory as a project; it now uses an ordinary child project directory.

Full CI, macOS 26 runtime behavior, a physical second Mac and iOS are not local validation.
This Mac runs macOS 27.0.1. Remote tests used authenticated TCP loopback, not a LAN host.

## Departures

No intentional layout departure from the supplied boards. Runtime names, paths, dates, counts,
context rows and versions are data, not copied samples. The custom SVG glyphs use native outline
SF Symbols, including `antenna.radiowaves.left.and.right` for Remote. Their contours and native
font rasterization are not pixel-identical to the browser's SVG/text rendering.
