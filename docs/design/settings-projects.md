# Settings > Spaces

> Read when: changing the Spaces list, space editors, host scoping or their previews.

Source: `SettingsProjects.dc.html`, Shepherd chat UI revision 492. The user supplied this board.
The reference image is `boards/SettingsProjects.png`. The list replaces the older implication
that Spaces only lives under Appearance. [ProjectInstructions](project-instructions.md),
revision 562, defines the detail screen and replaces the first implementation.

## Implementation checklist

- Settings navigation in order: Appearance, Terminal, Agents, Subagents, Worktrees, Spaces,
  Pi, Instructions, Skills, MCP servers, Remote, Keyboard, Advanced, Experiments.
  Pi's subpages, Sign-in, From your pi and Slash commands, stay visible from every page.
  Search still filters them.
  Spaces uses the outline `folder` glyph. Subagents uses outline `arrow.turn.down.right`.
  Existing page glyphs remain their registered settings symbols.
- The existing 232pt navigation, 44pt top strip, 32pt nav rows, search and version footer.
  The footer comes from the app bundle and bundled pi, never the board's example versions.
- Spaces fills the available width with the same 40pt side gutters as Skills and Instructions,
  44pt top and 48pt bottom. The user's latest full-width request supersedes the board's 860pt
  cap. The list scrolls vertically, not a fixed-width column horizontally. Blocks are 22pt apart. Header title is Geist 22/600, tracking -1%; explanation is
  Geist 13.5 with 1.5 line height, at most 700pt wide.
- Header 22pt; explanation 13.5pt. Exact header: "Spaces". Exact explanation: "Every folder Shepherd has run an agent in.
  Open one to edit what applies only there: its instructions, pi settings, skills, extensions
  and MCP servers."
- Toolbar: "Filter spaces" field, outline `magnifyingglass`, 302pt including border/padding;
  10pt gap; host segments with "All hosts", "This Mac" and the configured host names;
  trailing "Add space…". Controls are 32pt tall and use Night Watch's settings controls.
  Search matches space name/path and host. Host selection filters without changing data.
  Adding uses the existing local/remote directory browser and stays in Settings.
- Table: 10pt corners, `borderSubtle`, header `bgSunken`, 32pt header, 58pt minimum rows,
  16pt sides and column gaps. Columns are space and host at 1.5:1, summary at 230pt,
  disclosure at 20pt. Header labels are "SPACE", "HOST", "SET ONLY HERE" in mono 10.5,
  tracked 6%. Row names are Geist 13.5/500, paths mono 11.5 `textTertiary`, hosts Geist 12.5
  `textSecondary`, summaries mono 11.5, outline `chevron.right` at 10pt `textMuted`.
  A whole row is a button. Long names/paths truncate with their full accessibility labels.
- Summaries stay on one line and truncate visually. The row tooltip has the full summary.
- Rows come from host-owned space history, visible and sidebar-hidden Spaces and actual
  primary agent working directories. Reserved design/automation container Spaces and auxiliary
  terminal directories are excluded. Space identity is host plus absolute directory, not name.
  Summaries come from files in that directory, not copied sample rows.
- Footer, Geist 12.5/1.55, `textTertiary`, max 700pt: "Instructions in AGENTS.md and settings in
  a space's .pi folder apply only to that space. Each one is stored on the host the space
  lives on."
- Additional states: loading, empty, no filter matches, missing directory, unreachable host,
  older host requiring an update, file loading/error, dirty editor, save conflict and invalid JSON.
  Detail tabs: Instructions, Pi settings, Resources, MCP servers. MCP uses the shared server
  cards and forms, not a raw JSON editor. See [Space MCP](project-mcp.md). Reads and saves
  always name the selected space's host and directory. Save never overwrites another writer's
  changes. Closing/switching a dirty file asks before discarding.
- Render normal, empty, filtered, long text, remote offline/update-required, detail and errors in
  light/dark and text scale 1.3. Press navigation, host segments, every row, Add space, detail
  category/file selection, editor selection, Open in editor, Refresh, Save and discard controls through accessibility.

## Add child space

The user's create-or-add request extends the local **Add subspace** action. It opens the
shared [Add child space dialog](child-projects.md), also reachable from a local space's
sidebar menu. Remote rows retain the existing directory picker. Registered local rows expose
Rename Space… and Remove Space… in their context menu and accessibility actions, using
the shared dialogs. Explicit display parenting is reflected at each level without changing
folder/config inheritance; inherited-server labels still name the actual configuration ancestor.
The header explains "Organize spaces without moving folders. Settings still follow folder ancestry.".
The footer says "Space grouping changes only Shepherd. Instructions and settings follow folders on disk.".
Removal retains folder contents and Settings history; history-only and remote rows omit it.

## Codemode override

The user requested global codemode on by default and a per-space override. Before the Pi settings
editor, a Tools group has a Codemode row with Use global default, On and Off. It edits
`codemode.enabled` in the JSON draft. Save uses the existing conflict checks and host-owned file
service. Invalid JSON disables the picker without replacing the draft. Start or restart the agent
to apply the saved value. [Checklist and decisions](codemode-settings.md).

## Data and scope

The space service retains previously observed directories independently of workspace deletion.
Space configuration is a bounded, allowlisted file API, not arbitrary filesystem access. Global
pi instructions, global settings, auth and the user's other configuration are never editor targets.
Remote access uses an additive `projects.v1` capability. Offline and older-host state is explicit.

## Evidence

Validation results and links to the running-app screenshots and preview matrix are recorded in
this change's pull request. No screenshot is a substitute for a ControlPress assertion.
