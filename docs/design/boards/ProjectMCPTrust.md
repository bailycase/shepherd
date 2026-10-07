# Project MCP approval

The user requested approval in Shepherd's Projects page, reusing Pi's existing folder trust
rather than a separate Shepherd permission system. Saved OAuth credentials must not imply
that a new thread can load the server. Approval covers executable extensions, settings and
packages as well as MCP. No sensitive project names or data appear in this design or its evidence.

## Implementation checklist

- Keep the existing MCP header, Add server, filter, Reload and server cards in their order.
- Between the filter and cards, show project configuration eligibility for `.pi/mcp.json`.
  Use `NW.Space.m`, `NW.Space.l` and `NWDialogMetrics.inset`, `Font.nw(.ui)` and `.caption`, `Color.nw.textPrimary`
  and `.textSecondary`, and the existing `.nwCard()` and `.nw(.secondary)` button style.
  No new glyphs, colors, dimensions or animation.
- Checking: "Checking project approval…". No approval action until the host replies.
- Blocked: "Project configuration blocked" and "This folder hasn't been approved. New threads
  won't load its MCP servers, settings, extensions or packages." Offer "Trust this project…".
- Approved: "Project configuration approved" and "New threads may load this project's MCP
  servers when MCP is enabled. Each thread checks its own connection and tools. Restart
  existing threads to apply this approval." Do not claim a live connection.
- Old host: "Project approval unavailable" and an update-required explanation. No action.
- Failure: show the host's safe failure, with "Check again". Offline: show the host's existing
  unavailable reason and disable approval. Never keep another project's approval while checking.
- Confirmation uses `DialogSheet`, existing dialog tokens and no glyph. Title "Trust this
  project?". Explain the selected host and folder, executable extensions, settings, skills,
  MCP commands and package installation. Explain that Pi inherits approval in descendant
  projects. "Cancel" writes nothing. "Trust project" saves only
  this canonical folder through Pi's locked trust store. Never approve a parent or the home folder.
- Saving disables both confirmation actions and dismissal. Failure keeps the dialog open with
  the safe reason and allows retry. Success closes it and refreshes the page.
- Server OAuth row and expanded detail say "Credentials saved". Detail explains that saved OAuth credentials
  do not establish thread availability. Blocked detail host state says "Blocked". Otherwise it says "Unchecked". The full reason stays in the approval card and tools note.
- Render blocked with and without credentials, approved with and without credentials, checking,
  approval confirmation, saving, failure, old host, offline, empty, long text and narrow layout.
  Use real `ProjectsModel` requests and `ProjectMCPConfiguration` in light/dark and scale 1.3.
- Press approval, Cancel, Trust project, retry and Check again through `ControlPress`; assert
  the selected host/folder request, no write on cancellation, state after save and 24pt hit areas.

Departures: none.
