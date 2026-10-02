# Projects validation evidence

> Read when: reviewing the Settings > Projects implementation and its rendered states.

Source design: [SettingsProjects, revision 492](../../boards/SettingsProjects.png).
Implementation checklist: [Settings > Projects](../../settings-projects.md).
Behavior and safety: [Projects](../../../projects.md).

## Running Dev app

[All 12 app screenshots](gallery-app.png) show the Projects list and all five editor categories
in light and dark. They come from the Xcode-built `Shepherd.app`, not the Swift test runner.
The app rendered `RootView` with real project files, a live local `SessionServer` and an
authenticated loopback remote host. Its windows stayed off-screen and took no focus.
No agent or model ran. The temporary capture entry point is not part of the shipped change.

The capture process reported `NSApplication.isRunning: true` and `Fonts available: true`.
The footer's versions come from the app. Scratch project names and host names are fixtures;
paths, inventory counts and summaries come from the actual project-file API.

| Surface | Dark | Light |
| --- | --- | --- |
| Projects | [Screenshot](app/app-projects-dark.png) | [Screenshot](app/app-projects-light.png) |
| Instructions | [Screenshot](app/app-detail-instructions-dark.png) | [Screenshot](app/app-detail-instructions-light.png) |
| Pi settings | [Screenshot](app/app-detail-pi-dark.png) | [Screenshot](app/app-detail-pi-light.png) |
| Skills | [Screenshot](app/app-detail-skills-dark.png) | [Screenshot](app/app-detail-skills-light.png) |
| Extensions | [Screenshot](app/app-detail-extensions-dark.png) | [Screenshot](app/app-detail-extensions-light.png) |
| MCP servers | [Screenshot](app/app-detail-mcp-dark.png) | [Screenshot](app/app-detail-mcp-light.png) |

## Preview matrix

All 92 full-size previews are in [previews](previews/). Each state has light and dark renders
at text scales 1.0 and 1.3. Open the PNGs to inspect them at their original resolution.

- [List gallery](gallery-list.png): populated, empty, long names and paths, no filter results,
  offline host, older host without `projects.v1`, narrow window and missing directory.
- [Editor gallery](gallery-detail.png): instructions, pi settings, skills, extensions and MCP.
- [Editing gallery](gallery-editing.png): edited, discard confirmation, saved, invalid JSON,
  no project skills, missing instruction file, external-edit conflict and rejected symlink.
- [Subagents gallery](gallery-subagents.png): the existing settings moved to the navigation
  location drawn by the Projects board, with the feature on and off.

## Validation

- `xcodebuild`, Shepherd Dev scheme, locked package versions: passed, including the final
  shipping code after removal of the temporary capture entry point.
- Focused Swift Testing runs: protocol round trips and capability inventory, project history,
  allowlisted files, conflicts, JSON comments and BOM, global-directory isolation, model
  navigation, stale host identity, real local and remote accessibility controls, search,
  design-rule checks and the 300-project lazy-render budget.
- Final combined run: 93 tests in 12 suites passed. The broader preceding run passed 141 tests.
- Python release and documentation checks: 421 tests passed.
- Full CI and a physical second Mac are not local validation. Remote tests used TCP loopback.

The accessibility tests press rows, category and file controls, Save, Revert, discard choices,
host filters, filter-clear, Add project and the directory picker. They edit through the native
text view and assert the resulting files. A remote Save changes only the selected host's project.

## Departures

No intentional layout departure from the supplied Projects list board. Runtime project names,
paths, summaries and versions are data, not strings copied from the board. File editors reuse
Shepherd's existing line-numbered editor and controls because no project-detail board was shared.
