# Project MCP review evidence

The user's request and checklist are in [project-mcp](../../project-mcp.md).
The saved PNGs show the real project-file model, shared MCP cards and shared Add/Edit forms.
The page images include the persistent Pi links while Projects is selected. Form and detail
images use text scale 1.3 in both appearances.

## Validation

- `ProjectMCPTests` passes for both project file formats, missing and malformed files, concurrent
  edits, unknown fields and colliding imports. It verifies the host, directory, file and expected
  content sent on save.
- `ProjectMCPControlTests` presses cards, switches, Search/Direct, Add, Edit, Copy JSON,
  Remove/Cancel and Reload. Form checks enter commands, environment variables, headers and JSON,
  switch transports, hide/show/remove values, retry a failed save and preserve a 700.5-second
  timeout. The tests assert pointer hit areas and keep windows off-screen without taking focus.
- `ProjectsRemoteControlTests` changes an MCP server through a loopback remote scratch server
  and verifies that the local project stays untouched.
- `SettingsFullWidthTests` presses each navigation item directly, with all Pi children visible
  first. No click on Pi is needed to reveal them.
- Existing global MCP control tests, MCP store tests, project controls and DesignRulesTests pass.
- The preview suite renders populated, disabled, expanded, empty, filtered, malformed, conflicting,
  offline and long-name project states, native/shared files, narrow width and Add/Edit forms.
  Matrices cover light/dark and normal/1.3 text. The full set is reproducible with
  `SHEPHERD_PREVIEW_DIR=/tmp/shepherd-projects-mcp-final swift test --filter
  ProjectsPreviewTests/projectMCPMatchesTheSettingsCardsAndForms`.
- The Dev `xcodebuild` succeeds. Tests use scratch data, not the running app or the user's MCP
  servers. Live authentication and connections to actual MCP services were not attempted.

## Departures from the global page

The cards and forms are the same components. Project-specific labels name the selected host
and file rather than the global config. Project credentials use the project's existing JSON
format or environment references, not this Mac's global Keychain.

Project server processes belong to threads on their host. The page therefore shows unchecked
status, no fabricated tool count, and no global Sign in, Reconnect or Choose tools actions.
Shared `.mcp.json` keeps Search exposure fixed because its loader does not support the native
per-server exposure and OAuth options. These differences avoid controls that write ignored
settings or act on a different server instance.
