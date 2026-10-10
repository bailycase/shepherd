# Projects > MCP servers

> Read when changing project MCP cards, forms or the Pi settings navigation.

The user's reference is Settings > MCP servers, not the old project JSON editor. Reuse its
server rows, expandable details and Add/Edit sheet. The existing reference render is
[evidence/settings-full-width/app/app-mcp-light.png](evidence/settings-full-width/app/app-mcp-light.png).
The same request keeps Pi's Sign-in, From your pi and Slash commands links visible on every
Settings page when search is empty.

## Implementation checklist

- Keep the full-width project header, tab order, file tabs and host identity. Pi's three indented
  navigation links stay in their existing order and use `NWSettingsNavSubRow`, including its
  selected state and Sign-in attention dot. Searching still filters navigation.
- Replace the MCP category's JSON editor with the same `MCPServerListHeader`, `MCPServerRow`
  and `MCPServerDetail` used in Settings. Use `NWMCPMetrics` for columns, type, spacing and hit
  areas, `AppLayout.mcpCardRadius` for the card and existing theme roles for fills and borders.
  Reuse the existing switch, status dot, Remote/Local badge and disclosure glyphs exactly.
  The shared switch keeps its 30 by 18 drawing inside a minimum 24pt pointer hit area.
- Show a server filter and primary "Add server" action. Add and Edit reuse `AddMCPServerSheet`
  with Remote, Local and Paste JSON choices, named URL/command fields, headers and environment
  variable rows. The project footer keeps "Open in editor" and "Save" for external editing and
  retries. "Reload" rereads the selected project file through the existing discard guard.
- Take server names, endpoints, credentials metadata and enabled state from the selected file,
  not the global store. A missing file starts empty. Opening a native file runs only a bounded
  SDK trust check, never project resources, MCP connections, a browser, a model or the global
  Keychain. Editing configuration starts no server.
- Connection status is "Blocked", "Unchecked" or "Off". Tool count is unknown. The detail explains
  that live status belongs to threads on the project's host; it does not offer a nonfunctional
  Reconnect or pretend to know the tool catalog. HTTP servers without an Authorization header
  offer the same Sign in sheet as global MCP settings, and Sign out when the host holds tokens.
  Older hosts explain that an update is required instead of offering inactive controls.
  Saved OAuth rows say "Credentials saved" and explain that tokens do not establish a thread
  connection. Native project files show a separate approval card, with the block reason and
  "Trust this project…" confirmation. Approval covers all Pi protected project resources, not
  only MCP, and is saved on the selected host. The checklist and all required states are in
  [ProjectMCPTrust](boards/ProjectMCPTrust.md). Native screenshots in `evidence/project-mcp-trust/`
  cover 22 cases in light and dark at text scales 1.0 and 1.3. The sign-in requirement and control checklist
  are in [ProjectMCPSignIn](boards/ProjectMCPSignIn.md).
- Structured edits preserve unknown JSON keys and the existing project's format. Native
  `.shepherd/mcp.json` uses `enabled`, `exposure`, `timeout` and `oauth`; shared `.mcp.json` uses
  `disabled` and its existing deferred-tool behavior. Do not silently write global-only
  `shepherd` options or Keychain references into either file. Preserve fractional timeouts and
  values above 300 seconds through unrelated edits.
- Project credentials stay in the project file or use `${VAR}` references from the host's
  environment. OAuth credentials stay in the selected host's pi home, never in the project file
  or viewer. State that distinction in the form, conceal secret values and preserve existing
  values when unchanged. Removing a project entry never deletes global credentials.
  Adding an HTTP server with OAuth uses "Add and sign in", after saving successfully. Remote
  sign-in opens the viewer's browser and forwards only the matching loopback OAuth callback.
  Cancellation, switching projects, disconnection and the five-minute limit stop pending work.
  Model calls, notifications and automatic restart are not part of sign-in.
- Add, Edit, on/off and exposure controls save through `ProjectsModel` to the selected host and
  directory with the existing expected-content check. Do not close an unsuccessful edit or
  discard its draft. Remove asks for confirmation. Other hosts and the global file stay intact.
- Empty, filtered, loading, invalid JSON, unavailable host, save error/conflict and long-name
  states remain explicit. Invalid files cannot be overwritten by structured edits; Open in
  editor and Reload remain available where supported. Existing dirty-file navigation still
  offers "Keep editing" and "Discard".
- Render populated, empty, filtered, error, long and expanded states in light/dark and text
  scale 1.3, through real project-file requests. Render Add/Edit forms and Pi links while a
  non-Pi page is selected. Press navigation, file selection, filter, Add/Edit, variable rows,
  on/off, exposure, Remove/Cancel, Save, Reload and discard controls through accessibility.
