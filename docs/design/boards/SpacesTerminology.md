# Spaces terminology (prerequisite for Projects)

The old folder-based "project" is a **Space** in every visible string. The new **Project** (a
conversation plus goal, memory, spaces and automations) owns the name. Boards:
`ProjectLead-*.png` (14, saved by the parent). The boards win over this file and over the old UI.

Status: checklist only. Nothing below is built or verified yet.

## Never renamed

`Space`, `SpaceID`, `projects.json`, `projects.v1` and the other capabilities, `ProjectEdit`,
`registerProject` and the other protocol messages, `project_*` tool names and ids, the raw
`projects` sidebar style value, test method names, `docs/design/boards/*.png` and old evidence.
`.pi` paths stay (PR #244). "Xcode project", Claude Design project, "project trust" (pi's own
term) and the `.pi/` and `.mcp.json` file formats keep their words.

## Per board: what it draws, and whether the copy is a safe prerequisite

| Board | Draws | Safe now (old UI copy) | Needs the new Projects UI or data |
| --- | --- | --- | --- |
| Activity | Needs you / Working / Done, then a Projects section (header with a "New project" text button, rows "1 needs you", "1 working"), Recents, Designs. **No Spaces tree.** Done rows carry a mono project chip. Right pane "Welcome back" with Waiting on you and Resolved. | none | all of it |
| AddsSpace | Projects (`+`) over a Spaces tree: payments 4, dashboard-web 2, shepherd 3, folder glyph, chevron, count only. Offer card "gamecards-web, ~/code/gamecards-web, This Mac" with Not now and "Add to project". | Spaces header and tree title | Projects section, offer card, project conversation |
| EmptyV2 | Project overview: goal line, a Spaces row ("gamecards-api, add more in settings"), "Instructions, memory", Suggestions, right pane "Nothing running yet." | none | all |
| New | "New project" dialog: Name, Goal (optional), Spaces (optional) with "Folders threads work in. Leave it empty and the project adds spaces as the work needs them; it asks you first." and an "Add a space…" menu. Cancel, "Create project". | "Add a space…" menu wording | the dialog |
| Started | Gamecards expanded with three working threads, count 3, right pane "3 threads are working." | none | all |
| ThreadRunning | Thread detail in the right pane (breadcrumb, "Steer this thread…", stop). | none | all |
| Question | Question card A/B/C, "2 of 3 done · 1 needs you" strip, amber dot and "answer" on the child row. | none | all |
| Paused | Banner "Paused. Threads stopped at a safe point…" with Resume, composer "Paused. Your message waits until you resume…", pane footer "The project is paused." | none | all |
| Resolved | Thread detail with "This thread is resolved. Reopen it to send more messages." and Reopen. File chip "checkout-widget.html · gamecards-web" (a space name). | none | all |
| RunElsewhere | "Run on another host" sheet, host list, "Push the branch and continue there", "Start over there", "Move to This Mac". | none | all (host sheet is not an old project string) |
| Settings General | Project settings tabs General, Spaces, Memory, Automations. Goal, models, Threads at once, Pause project, Delete project ("Threads stay in their spaces"). | none | all |
| Settings Spaces | "SPACES" list: name, path, hosts, "Added by you" or "Added by the project", Remove. "Add a space…", "The project can add spaces", Hosts. | the wording "space" for a folder | the per-project page and its data |
| Settings Memory | "PROJECT INSTRUCTIONS" "…after each space's AGENTS.md", "WHAT THE PROJECT REMEMBERS", Forget. | "space's AGENTS.md" is the same folder file | the page |
| Settings Automations | Rows with a toggle, per project. | none | the page |

## Old surfaces that become Spaces now (safe prerequisite)

Each is a visible string for the old folder. Test per row: copy test or ControlPress label.

- [ ] Sidebar: `NWProjectsHeader` title and its `+` help and label ("Add Space"), the organize-by
  style title and summary (`NWSidebarStyle.projects`: raw value stays), Add / Rename / Remove /
  Add Child / Show / "New Thread in" menu items, move and hide persistence descriptions.
- [ ] Settings nav title and search keywords, the page header, filter, host picker, count
  ("1 space"), empty and loading copy, row accessibility labels, Add / Open / Add subspace actions,
  Rename and Remove menus, the per-space detail ("Back to Spaces", category labels, cookies, file
  editor, MCP trust, peers) and their errors.
- [ ] Dialogs: rename, remove, child space sheet, remote directory picker, trust confirmation.
- [ ] Palette: Rename and Remove actions on the New thread page.
- [ ] New thread: the place chip ("Choose a space"), "Add a space to start a thread.", "That space
  is gone.", design reference notes, "Where it runs: <space> on <host>" (`PlaceMenu`), the New
  agent sheet, implement sheet field and empty text, design page help text.
- [ ] iOS `App/iOS/NewThread`: it already says "repo"; check "Where it runs" copy agrees.
- [ ] Remote errors in `RemoteHostClient` (update required, unexpected reply), `RemoteHostStore`.
- [ ] Docs: DESIGN.md, `docs/projects.md`, `settings-projects.md`, `child-projects.md`,
  `project-*.md`, `sidebar.md`, `dialogs-and-palette.md`, `agent-coordination.md` headings and
  strings. No file renames.
- [ ] Extensions: `shepherd-panes.ts` descriptions and `PanesExtension.swift` literal only if a
  description tells the model the user's folder is a "project"; sync with the script.

## Decisions from the user

1. The boards are two sidebar modes. **Activity** orders Needs you, Working, Done, Projects, Recents,
   Designs. The **folder-organized** mode has Projects above Spaces. Both keep working. The raw
   `projects` preference value stays; its visible name is Spaces. This change builds neither new
   Projects section, so the final sidebar is not claimed to match.
2. Settings ▸ Projects becomes **Spaces** with its SettingsProjects layout. The four per-project
   pages (General, Spaces, Memory, Automations) are separate in-workspace pages with horizontal tabs
   and never reuse the old global table.
3. Existing entry points and context-menu actions stay and are relabelled Space. No new visible
   controls, nothing removed. The new sidebar adds no Spaces header `+` (the boards draw none);
   adding and managing spaces stays in Settings ▸ Spaces and the existing menus. The relabelled
   folder menus are a temporary foundation, not the delivered sidebar. No departure is approved
   except excluding Linux (RunElsewhere draws a Linux host; this repo has no Linux runtime).
4. The offer card button stays **Add to project** (EmptyV2, AddsSpace). Never rename it Add space.

## Placeholders the new Projects UI must tell apart

- Project conversation: `Ask {project} a question or start a task…`
- Paused: `Paused. Your message waits until you resume…`
- Worker thread: `Steer this thread…`
- Paused keeps the question card and both Resume controls (banner and pane footer).
- Resolved replaces the worker composer with "This thread is resolved. Reopen it to send more messages." and Reopen.

## Full Projects implementation, later (not this change)

Needs the real data and contract, not a rename:
- Activity: Projects section between Done and Recents with "New project" and "1 needs you / 1 working" rows;
  Done rows carry a mono project chip.
- Folder mode: Projects (with `+`) above Spaces; expanded project rows list their threads, count 3, amber dot and "answer".
- Overview in the main column, right pane Threads tab (Waiting on you, Resolved, Working), pause banner and footer.
- New project dialog, offer card (Not now, Add to project), Run on another host sheet, thread detail with Reopen.
- Project settings: General, Spaces, Memory, Automations tabs ("Added by you / by the project", "The project can add spaces", Forget).
- Not drawn, so ask before inventing: space-row needs-you indicators, child and hidden spaces in the folder tree,
  the Spaces tree in Activity, any Spaces header menu, per-space file settings entry.
- Agent tools `project_register`, `project_edit` and the rest manage spaces. Their ids stay; the new Projects contract decides names.
