# ProjectLead UI checklist

Source: the 14 unchanged `ProjectLead-*.png` boards (macOS, revision 1406) and the boards' exported HTML (`01-ProjectActivity.html` ...
`14-ProjectSettingsSpacesV2.html`, read-only, in the parent's `shepherd-project-original-markup-*` scratch folder). Acceptance is 1:1. Every
number below is measured from that markup in headless Chromium at 1x (CSS pixels = points: each element's rect, computed type, color, border,
radius, padding and gap) and checked against the PNGs (3200x1800 for the 1600x900pt window boards, 2880x1800 for the Settings boards; 2 px per
pt). A value is a named token, or a named `NWLeadMetrics` / `NWProjectMetrics` constant holding the measured number; none is rounded to a
neighbour. **The user's approved departures:** macOS-only hosts (no Linux daemon); the Activity **Designs group first**; and **no subagents in
Projects** (the boards' subagent-count pill and child controls are not drawn; ordinary threads are unchanged).
Early-lane rows below that say "measured from the PNGs" or "nearest token" are the first pass, kept for history; "Measurement method" and the
latest pass at the end supersede them.

Status key: **P** = built in this change, **B** = blocked on a runtime seam (named), **L** = later lane.

## Shared measurements (dark, pt)

| Item | Measured | Token |
| --- | --- | --- |
| Sidebar width, bg | 232, (10,11,12) | `AppLayout.sidebarDefaultWidth`, `bgBase` |
| Main column bg | (13,14,16) | `bgWindow` |
| Sidebar divider | 1, (31,34,38) | `lineSubtle` |
| Selected sidebar row | x 10..221 (211 wide), y 176..204 (28 tall), fill (29,30,31) | density `rowHeight` 28, `bgSelected` |
| Project row glyph | 10 x 12.5, x 15.5, outline, 1pt stroke; lantern when selected, `textTertiary` otherwise | see Glyph |
| Project row name | starts x 36.5, 13.5pt, selected = semibold white | row font |
| Folder (Space) row | chevron x 19..23.5, folder x 36..~46 | existing `NWProjectRow` |
| Count | mono 10.5, `textTertiary`, trailing 8 | `NWProjectMetrics` |
| Project settings column | 1440pt-wide board: card left 456, right 1215 (**759pt wide**), centered in the 1208pt main area (232..1440). Title top 52, tab row text baseline ~93, tab rule y 114, first card top 131 | settings page column (`AppLayout+Settings`), measured per render |
| Card border (44,48,53), fill (21,23,26), radius ~10 | 1pt `lineStrong`, `bgRaised`. `.nwCard()` is `lineSubtle`/radius 8: **difference to resolve** (the existing Settings cards use radius 10 per DESIGN.md) | `NWCardRow` settings card |
| Settings row dividers | 1pt (31,34,38) = `lineSubtle` | `NWCardRow` |
| Tab underline | 2pt `lantern` (242,169,59) at y 112..114, from x 456 to 516 under "General" (60pt = label + 11pt side pads); a 1pt `lineSubtle` rule at y 114 spans the card width | `lantern`, `lineSubtle` |
| Page title "Project settings" | Geist 22/600 | `AppLayout.settingsTitleSize` |
| Breadcrumb "Gamecards" over it | 13.5 `textSecondary` | |

The Settings boards are 2880x1800 = 1440x900pt (px/2 = pt). The window boards are 3200x1800 = 1600x900pt.

## Glyph decisions (flagged, not silently swapped)

- **Project (logical)**: the board draws a stacked outline: a rounded-rect body with two short horizontal
  caps above it (like a jar or a stack of cards). The nearest SF Symbols are `tray.2` (two stacked trays,
  too wide), `square.stack` (offset squares, wrong shape), `cylinder` (curved, wrong), and
  `archivebox` (a lid over a box, closest overall). **Chosen: a native `Shape` drawn from the board
  (NWGlyph-style, outline, 1pt stroke, template-tinted)**, because no SF Symbol matches the double cap.
  **Ambiguous: please confirm** that a drawn shape is acceptable instead of `archivebox`. Never `folder`.
- **Space**: `folder`, outline (as drawn, and as the existing Spaces tree uses).
- **Overview toolbar**: `list.bullet` (outline) beside "Overview"; settings `gearshape`. To confirm on zoom.
- **Suggestions**: `sparkle` (small four-point star), outline.
- **Instructions, memory row**: `doc.text` outline.
- **Menu chevron on Add a space…**: `chevron.up.chevron.down`.

## Sidebar

### Activity (board: Activity.png) -- final order: Designs / Needs you / Working / Done / Projects / Recents
1. Fixed navigation, exactly as the boards draw it: New thread, Designs (while the Design tool is on), Automations. The old More row
   (Hosts, Design systems, Extensions) is removed; the command palette opens those pages. **Decision for the user:** alternatives are a
   Hosts/Extensions item in the footer Settings menu, or More shown only while a host is offline.
2. **Designs group** first (user override). Visibility and fold rules unchanged.
3. Needs you (lantern header and count), Working (pulse), Done ("Mark all seen" chip), then **Projects** (header
   "Projects", count, and a text chip "New project" in the same chip style as "Mark all seen"), then Recents.
4. **Pinned** is a functional state kept for users who pin; it is **not drawn by the board** and must not
   displace a drawn group: it goes immediately after Done and before Projects, and only exists when something is pinned.
5. Project row: glyph, name (semibold when selected), trailing summary in mono 10: `1 needs you` (lantern text)
   or `1 working` (`textTertiary`). **P** structure; the status text is computed from real thread state only
   when the coordinator/task lifecycle exists (**B**). Until then the trailing text is the real thread count the
   project owns, or nothing: never a synthetic badge.
6. A project row opens the Project page (below).

### Folder mode (boards: AddsSpace, Started, Paused, Question, Settings*)
1. Fixed navigation.
2. **Projects** header (18pt `+` circle opens New project, per the board) over the project rows, then a **Spaces**
   header over the existing folder tree. **No `+` on the Spaces header** (the board draws none); Add Space, Rename,
   Remove and Add Child stay in Settings > Spaces and the existing menus.
3. Spaces rows: chevron, `folder` glyph, semibold name, count only (as drawn). The existing needs-you rollup dot on
   a collapsed row is not drawn by the board; **kept as existing behavior, flagged** as an undrawn state.
4. An expanded project lists its task threads indented one level, with the amber dot and `answer` (Question,
   Paused boards): **B** until tasks exist.

## Surfaces

| Board | Producer (real) | Status |
| --- | --- | --- |
| New (sheet) | `LogicalProjectsModel` create: Name (required), Goal, Spaces (existing non-hidden local Spaces), `Create project`; atomic selected-space creation through `logicalProjects(.create(linkedSpaceIDs:))` | **P** |
| EmptyV2 (overview) | project name, goal, linked-space row, "Instructions, memory" row, 3 suggestions, `Welcome back, <user>.` pane | **P** (suggestions are static *prompts*, each sends nothing until a conversation exists, see below) |
| Started / ThreadRunning / Question / Paused / Resolved | project conversation (native thread store for `coordinatorAgentID`), task list, question card, pause banner, Reopen | **B**: needs `ProjectCoordinatorController` + task list |
| AddsSpace (offer card) | a project's *proposal* to link a Space ("Not now", "Add to project") | **B**: needs a pending-proposal value |
| RunElsewhere | host list from real hosts, macOS only | **B**: needs worker/host adapter |
| Settings General | goal, conversation model, thread model (real catalogs), threads at once 1...6, Pause, Delete (retained files disclosure) | **P** |
| Settings Spaces | linked spaces list (provenance, linked date, Remove), "Add a space…", `The project can add spaces` toggle, Hosts | **P** except Hosts control (**B**, see below) |
| Settings Memory | instructions text with real `n of 16,000`, memory list with Forget | **P** |
| Settings Automations | project automations list with toggles | **B**: Automation has no project association; shows the empty state until one exists |

## Strings, by producer

- Sheet title `New project`; fields `Name`, `Goal` + muted `optional`, `Spaces` + muted `optional`; help
  `Folders threads work in. Leave it empty and the project adds spaces as the work needs them; it asks you first.`;
  menu `Add a space…`; buttons `Cancel`, `Create project`; close `xmark` circle button, label `Close`.
  Create is disabled while Name is blank, and while a create is in flight.
- Create failure: the host's own message (`LogicalProjectsError`), kept in the sheet; retry reuses one generated ID.
- General: `Goal` / `One line the project works toward. Optional.`; `Conversation model` / `Plans the work and talks with
  you.`; `Thread model` / `Each thread uses it unless the task says otherwise.`; `Threads at once` / `More wait for a
  slot. Counts across every host.`; `Pause project` / `Stops threads at a safe point and skips automation runs until you
  resume.` button `Pause` (`Resume` when paused); `Delete project` / **truthful**: `Removes the conversation, memory and
  automations. Threads stay in their spaces; branches and PRs are untouched.` **plus** `The project's files stay on this
  host.` button `Delete…`. The board's sentence is extended only to disclose retained files (required by the contract).
- Spaces: `SPACES` label; rows `name`, `path · host`, `Added by you`, `Remove`; `Add a space…`; toggle `The project can
  add spaces` / `When work needs a folder that isn't here, the project asks in the conversation. With this off it only
  suggests.`; `Hosts` / `Where threads may run. A space must be set up on a host first.` (**B**: no field for it; the
  row is shown only when a real host-allowlist exists, and the gap is reported).
- Memory: `PROJECT INSTRUCTIONS` label; footnote `Sent to the conversation and to every new thread, after each space's
  AGENTS.md. {n} of 16,000 characters.` (n from the actual text); `WHAT THE PROJECT REMEMBERS`; `Forget`.
- Empty overview: `Spaces` row detail `{names} · add more in settings`; `Instructions, memory` / `In project settings`;
  `Suggestions`: `Set up this project from my recent threads`, `Help me work out a plan for this project`, `Look around
  {first space} and suggest first threads`. Pane: `Welcome back, {first name}.` / `Nothing running yet.` / `Threads the
  project starts show here, grouped by what they need from you.` Composer placeholder `Ask {name} a question or start a
  task…`.

## Controls and pressing (each through `ControlPress`)

New project: `Add project`-style `+` / `New project` chip opens the sheet; `Close`, `Cancel`, `Create project`, name/goal
fields, `Add a space…` menu and each chosen space's remove. Settings: each tab, goal field, both model pickers,
Threads at once stepper (1...6), Pause/Resume, Delete… and its confirmation, Remove, Add a space…, toggle, instructions
editor, Forget. Sidebar: project row open, header chip, context menu. A revision is carried by every mutation; a stale
refusal re-reads the project and shows the host message; the draft is kept, nothing is overwritten.

## Open questions (current)

Settled by the exported HTML, not open: the Project glyph is the supplied 40-unit contour (`NWProjectGlyph`), and every size is measured, so
there is no "nearest token" or "No token, ask" row. Still awaiting the user: RunElsewhere (board 10) and the structured Automation trigger
choices. Owned by the Settings author, not this lane: the `Hosts` row on Spaces settings and the project <-> automation link.

## Measurement method (the exact HTML, not nearest tokens)

The parent saved the boards' exported HTML (`01-ProjectActivity.html` ... `14-ProjectSettingsSpacesV2.html`) read-only. Each was
opened in headless Chromium on a scratch copy and every element's rect, computed type, color, border, radius, padding and gap was
read at 1x (CSS pixels = points). The Chromium run rasterises a board to within a few pixels of the supplied PNG, so the markup is
the same design. Values that no token holds are named in `NWLeadMetrics` (ShepherdUI) or `NWProjectMetrics`/`AppLayout+LogicalProjects`,
not rounded to a neighbour. The two measured facts that overturned my first pass:

- The Project icon is the supplied 40-unit contour (4 sub-paths, bbox 13.5..26.62 x 11.5..27.88, aspect 0.801). `square.stack` is 0.756,
  `archivebox` another shape. It is drawn as `NWProjectGlyph`, the contour point for point, in a 14pt slot at 0.857pt a unit.
- The sidebar rows are 28pt in a 215pt column with 8pt side padding and 9pt gaps (Activity) or 6pt left, 8 right and 8 gaps
  (Spaces mode); headers are 34pt with the title at the bottom. Section headers are `12.5/500 textTertiary`, 24pt `+` buttons.

## Evidence for review (renders are 2x, PNG, from the real producers)

`SHEPHERD_PREVIEW_SCALE=2 SHEPHERD_PREVIEW_DIR=<dir> swift test --filter LogicalProjectPreviewTests` writes `<surface>-<light|dark>.png` and
`-x1.3-` variants. Board comparisons were made with `PIL` crops of the board PNG against the same box of the render. The latest set
used in this review is in `/tmp/ui-final` (70 PNGs): `lead-started`, `lead-question`, `lead-paused`, `lead-overview-*`,
`lead-settings-*`, `lead-new-project-*`, `lead-sidebar-*`, `lead-delete-project`.

## Status after the conversation slice (rendered, pressed, compared; not 1:1 yet)

| Surface | Built from real data | Open differences (named, not accepted) |
| --- | --- | --- |
| Sidebar, Activity | Designs, Needs you, Working, Done, Projects, Recents; Pinned after Done; "New project" chip; Project rows with the supplied glyph, summary `N needs you` / `N working` counted from tasks | Row summary tone and spacing are measured; the chip and header text weights match. 2x pixel diff not zero (system font substitution below) |
| Sidebar, Spaces mode | Projects `+` above Spaces; Project rows with count (open threads) and a lantern dot; selected Project lists its task threads indented with `answer` | The Spaces rows' needs-you dot (existing behaviour the board does not draw) |
| New project sheet | Real create with chosen Spaces | First-pass sizes; re-measured against `03-ProjectNew.html` in a later pass (see the latest pass below) |
| Overview (Empty) | Name, goal, Spaces row, Instructions row, Suggestions (fill the composer; send nothing) in the shared thread's empty state | Spacing measured; the 12pt radius and 34/29pt rows match |
| Conversation (Started, Question, Paused) | The coordinator's own native thread (`ThreadView` over `conversationStore`); composer send through `sendProjectMessage` with one operation identity per text; Paused banner, placeholder and Resume; the summary strip counted from tasks; each waiting task's own native question as a lettered-option card answered through `answerProjectQuestion` | The board shows task **cards** inside the conversation ("Gift card market scan  gift-card-platforms.md", "View thread"): the runtime has no such message in the native transcript, so they are not drawn (blocked, below) |
| Threads pane | Welcome back, status sentence, Waiting on you / Working / Resolved groups, rows with the worker's own latest activity, age, Blocked + the worker's question; Close; Paused footer with Resume | The header's Files, New thread, Search, Filter, Expand have no behaviour yet and are **not drawn** (no dead controls); the "Y 2" branch pill needs a per-task host or worktree count |
| Thread detail (ThreadRunning, Resolved) | Breadcrumb Threads > title, the worker's ordinary native thread with its own composer, Resolve / Reopen / Open as a thread / Close, the Resolved footer card with Reopen | Not rendered against the board yet |
| Settings General, Spaces, Memory, Automations | Real CRUD (earlier slice) | Hosts row, Added by the project, the project's automations: waiting on the backend; see below |
| AddsSpace offer card, RunElsewhere | **Not built** | Waiting on `Project.spaceProposals` and the owner-adapter host list |

### What the real data cannot yet show (named, reported)

1. **Paused with a question.** The Paused board draws a paused Project that still has a waiting question. The runtime's Pause aborts running
   turns, so a worker that was only asking ends its turn and the task becomes `.settled`. Reported to the parent with a recommendation
   (do not abort a turn that is only waiting on the user). Until then the render shows what the runtime really does.
2. **Task cards in the conversation.** The boards' "Gift card market scan" cards with file chips come from messages the coordinator
   writes. The runtime keeps the coordinator conversation-only and creates tasks through the user's own `assign`, so the transcript
   holds no card. A model-facing task tool (planned) would give the cards a source. Not faked.
3. **Branch pill and file chips** need per-task host/worktree data and published-file records.

### Fonts

Geist is installed in the package (`Packages/ShepherdUI/Sources/ShepherdUI/Resources/Fonts`). The boards' CSS names `Geist`, which
the headless browser here substituted with a system font because the Google Fonts link is offline. The measured *sizes, weights and
boxes* are therefore exact but glyph advance widths in my browser measurements are the browser's fallback; the app's own render uses
real Geist. A 2x pixel difference remains in text edges for that reason and is not a layout difference.

### Seams still needed from the parent (plain values and actions)

- A pause that keeps a pure-asking task `.waiting` (above).
- `Project.spaceProposals` + accept/deny for the AddsSpace card, `settings.hostPolicy` + the owner's connected-host names for the Hosts row,
  `Automation.projectID` + `LogicalProjectsRequest.automation(...)` for the Automations rows (rows will use `ProjectAutomationSnapshot.rows`).
- The generic sidebar Stop for an automation with a `projectID` must be suppressed or routed through the scoped API with the displayed
  Project revision (noted; my sidebar does not draw one for Projects).


## Open gaps at the Phase 3 UI checkpoint

Not "complete". See `docs/project-lead.md`, Slice 6, for each: Project messages carry no images yet (paperclip opens the picker; an image
stays with its draft and the reason is shown), the offer card is docked above the composer instead of inline, Files and the three
task cards wait on the merged producers, and the Settings tabs, New project sheet Goal/Spaces, Resolved Reopen and Paused question
boards are not yet compared against the original HTML. Nav decision for the user: More removed; alternatives are a Hosts and Extensions
item in the footer Settings menu, or More shown only while a host is offline.

## Settings fidelity pass (General, Spaces, Memory, Automations): scoped checklist

Written before the code. Source of every number: the boards' own exported markup (`11`-`14-ProjectSettings*.html`, data only, never
copied), loaded in headless Chromium with the bundled Geist at 1x and 2x, then each computed box and style read, and the 2x screenshot
diffed against the four PNGs (`/tmp/psf/measure.js`; the boards and the markup agree to the pixel). The reviewer's finding V2 said
tab weight 500; the markup and the PNG both say **400** (selected differs by color only), so 400 is built. Tokens: new values live
in `NWProjectSettingsMetrics` (ShepherdUI, new file). No global token changes; every value that equals an existing token uses it.

Approved departures: macOS-only hosts, Designs above Activity groups. **No others are taken here.**

### Page (all four tabs), dark, pt, board origin is the main column (x 232, no toolbar)

| Element | Value | Token |
| --- | --- | --- |
| Column | 760 wide (card outer 456..1216), centered, 24 above, 32 each side, 24 below | `columnWidth` 760, `NW.Space.xxl/xxxl` |
| Breadcrumb (project name) | Geist 11.5/400, **`textTertiary`** (#5f656e dark, #9a9ea5 light) | `.nw(.caption)` |
| Title "Project settings" | Geist 15/600 `textPrimary`; 6 under the crumb | `.nw(.title)`, `NW.Space.s` |
| Header to tabs, tabs to content, block to block | 16 | `NW.Space.xl` |
| Tab | label Geist 12.5/**400** (not 500, not bold), `textPrimary` selected, `textSecondary` otherwise; 8 each side; label box 32 tall, **2pt `lantern` rule under the selected one** (the tab is 34), 6 between tabs, so General is 60.11 wide | `.nw(.ui, weight: .regular)`, `tabHeight` 32, `tabRule` 2 |
| Tab rail | 1pt `lineSubtle` under all tabs, below the 2pt rule (rule y 112..114, rail 114..115) | `line` 1 |
| Card | 1pt `lineStrong` border, **radius 12**, fill `bgRaised`; rows sit inside the border | `NW.Radius.l` |
| Row | 12 each side, 8 above and below, 12 between text and control; least 52 tall counting its 1pt top divider; divider `lineSubtle` 1pt | `rowMinHeight` 52 |
| Row title | Geist 12.5/500 `textPrimary`; 2 above its help | `.nw(.ui)`, `NW.Space.xxs` |
| Row help | Geist 11.5/400 on 1.45, **`textTertiary`** | `NWCardRowMetrics.settingsDescriptionLineHeight` |
| Buttons (Pause, Delete, Remove, Forget) | the Controls board size, **not** the Settings 32: 28 tall, radius 6, 10 padding inside a 1pt line (so text + 22 wide), 12.5/500 | `NWButtonStyle` `.m` + 1pt label pad (`buttonBorder`) |
| Popup | 32 tall in a 40 slot, 1pt `lineStrong`, radius 7, `bgRaised`, Geist 13/400, 12 before the value, **36 after** (chevrons live there), width follows the value | `NWSettingsControlMetrics` `controlHeight`, `radius`, `textSize`, `popupLeading`; `popupTrailing` 36, `popupSlot` 40 |
| Popup glyph | `chevron.up.chevron.down` (outline pair), `textTertiary`, ink 7 x 9, centered 16 from the right edge and **3.75 above** the control's center | `popupChevron`, `popupChevronLift` |
| Switch | the `nwSwitch` (30 x 18, 14 knob) in a 24pt slot | existing |

### General (ProjectLead-SettingsGeneral)

1. Card A, rows in order, each string from the producer (`LogicalProjectGeneralTab`): **Goal** / "One line the project works toward. Optional." with a field
   320 x 36.75 (8/12 padding on a 1.5 line, 1pt `lineStrong`, radius 8, fill **`bgSunken`**, text 12.5/400); **Conversation model** / "Plans the work and talks with
   you." popup (value = the record's model or `Default`, items = `Default` + the owner's catalog); **Thread model** / "Each thread uses it unless the task says otherwise." popup;
   **Threads at once** / "More wait for a slot. Counts across every host." popup `1`...`6`. Row heights 52.75, 57, 57, 57.
2. Card B, 16 below: **Pause project** / "Stops threads at a safe point and skips automation runs until you resume." button `Pause` (paused: subtitle "Paused. Nothing
   new starts until you resume.", button `Resume`; the board draws only the not-paused state). **Delete project** / "Removes the conversation, memory and automations. Threads
   stay in their spaces; branches and PRs are untouched." button `Delete…`: `failed` text, **border = failed mixed 30% into `bgRaised`** (board #572d2e), fill `bgRaised`
   (board pixel #15171a; the #1b191b in the brief is not in the board). Rows 52 and 52.67. The extra "The project's files stay on ..." sentence is **removed** from the
   row (the confirmation sheet still says it: that is where the board is silent).
3. Presses: Goal commits on Return (revisioned edit keeping the name); each popup opens a native menu and saves `settings` with the revision shown; Pause/Resume is `setPaused`;
   Delete… opens the confirmation sheet (Cancel closes; Delete project removes the record, files retained).
4. States not drawn by the board and kept as built: disabled while saving, stale-revision failure line (`failed` caption between tabs and card), the Delete confirmation.

### Spaces (ProjectLead-SettingsSpacesV2)

0. **Links are (destination host, SpaceID) pairs.** A row resolves against its own destination (this Mac's Spaces for a local link, the
   owner's `ProjectHostOption.spaces` for a remote one), Remove sends the link's own destination, and Add offers each host's unlinked
   Spaces keyed by destination + SpaceID and links with that host. Nothing resolves by a bare SpaceID, a name or a path. A Space the
   host does not list says so ("A space on build-01, which does not list its spaces"); it is never filled in from this Mac.
1. Label `SPACES` (Geist Mono 10.5/500, uppercase, 6% tracking, `textTertiary`, 4 in, 6 above the card). Card of linked spaces; each row (52): `folder` outline at 12pt in a
   14 box, `textSecondary`; name 12.5/500; under it **mono 10.5/400 on 1.4** `textTertiary`: `~/path · {owner}`; trailing `Added by you` (user) or `Added by the project · Oct 9` (project,
   `linkedAt` as month + day), 11.5 `textTertiary`; ghost `Remove` (`textSecondary`). **Board row 2 (`gamecards-web`, "This Mac · build-01") is NOT built:** it draws one Space on two hosts. A link holds exactly one
   (destination, SpaceID); two Spaces on two hosts are two links with independent SpaceIDs, and nothing in the model says they are the
   same folder. Naming it by name or path, or by joining the allowed hosts, would invent that association, so each link is its own row
   with its one real host. **Open gap for the user and the parent:** an explicit association between host Spaces.
2. `Add a space…` popup (32 in a 40 slot, 8 below the card), items = the owner's unlinked, visible spaces; disabled with a tooltip when none. 16 below it, card: **The project can
   add spaces** (toggle) / "When work needs a folder that isn’t here, the project asks in the conversation. With this off it only suggests."; **Hosts** / "Where threads may run. A space must
   be set up on a host first." popup from `ProjectHostChoices` (`This Mac only`, `Any connected host`, named hosts).
3. Empty: "No spaces yet. Add one, or let the project ask when the work needs a folder." in the card (not drawn by the board).

### Memory (ProjectLead-SettingsMemory)

1. `PROJECT INSTRUCTIONS` label; editor 760 x 149.25 (7 lines on the 18.75 line), 1pt `lineStrong`, radius 8, fill `bgSunken`, 12.5/400, text 12 in and 8 down. 11 below it
   (5 the editor's baseline gap + 6), footnote 11.5/1.45 `textTertiary`, flush with the card: "Sent to the conversation and to every new thread, after each space’s AGENTS.md. {n} of
   16,000 characters." (over the limit: `failed`). Save / Revert (`.nw(.primary)`, `.nw(.ghost)`) appear only while the text differs (not drawn by the board).
2. `WHAT THE PROJECT REMEMBERS` label; card of memory rows (52): text 12.5/**400** on 1.45 `textPrimary`, ghost `Forget`. Empty: "Nothing yet. What you decide and what the project learns is kept here, and you can
   make it forget any of it."
3. Presses: Save writes `instructions`; Forget removes the entry (`forgetMemory`).

### Automations (ProjectLead-SettingsAutomations)

**V14 stays BLOCKED, not approved.** The user has not decided between prompt watchers and structured triggers. What is built is the
existing `.projectAutomations.v1` record (name, prompt, cwd, enabled) with its real run log; the board's clock row, "Mondays 09:00",
"When a PR opens in …" and "passed" are not drawn and no fake rows stand in. Enabling a record starts nothing.

1. One card, one row per **real** project-owned Automation record (53 pitch): leading glyph in a 14 box (12pt, `textSecondary`), name 12.5/500, caption 11.5 `textTertiary`
   (Geist, not mono), trailing 18pt switch. The glyph is `bolt` (`NWGlyph.automation`, outline): the records carry no schedule or trigger, so the board's `clock` row is not drawn.
2. Caption from the record and run log only: `{where it works} · {owner} · {run word} · {age} ago`, or `never run` with no run. Run words are the existing producer's
   (`finished`, `asked you`, `stopped`, `interrupted`, `running`), not the board's `passed`. The board's leading "Mondays 09:00" / "When a PR opens in ..." has no field; it is not drawn and
   nothing here says a trigger works. Execution stays pending: the switch is `setEnabled` through the owner, never a run.
3. Empty: "No automations yet" / "Automations that belong to {project} show here with a switch for each."

### Measurement and test plan

- `ProjectSettingsFidelityPreviewTests` (new): General, Spaces, Memory, Automations x {normal, empty, long} x light/dark x 1/1.3, from the real server, runs and records.
- `ProjectSettingsFidelityControlTests` (new): geometry from the accessibility frames against the numbers above, every control pressed through `ControlPress` and `NativeMenuChoice`
  (Remove, Forget, toggles, Pause/Resume, Delete + confirm, both models, limit, hosts, Add a space…), asserting the request and the 24pt hit area.
- Kept as a known issue where it is not mine: the existing 22pt compact sidebar row (not touched).

### Settings fidelity pass: later changes

- Popup chevrons are `NWGlyph.popupChevrons` (`chevron.up.chevron.down`), the pressed offset is `NWProjectSettingsMetrics.pressOffset` (0.5, as `NWButtonStyle`). The four older files that draw the same pair as a raw string are in `DesignRuleAllowlist`.
- Tab widths use the line's exact typographic width at the current text scale, so the rule under each tab lands on the board's pixel (the 2pt drift under Automations is gone).
- Hosts: the designed normal state is the owner's real two-host `ProjectHostOption` list ("This Mac and build-01"); "This Mac only" (owner reports one host) is its own preview, `settings-spaces-single-host`.


## Conversation details pass (UI9): current evidence and open gaps

Measured from the boards' markup in headless Chromium at 1x and from the saved PNGs; renders from the real producers
(`SHEPHERD_PREVIEW_SCALE=2 swift test --filter LogicalProjectBoardPreviewTests|LogicalProjectPreviewTests`).

- **File chips**: one per `ready` `ProjectArtifactReceipt` of that task (`ProjectTaskRow.files`). Pressing one opens that Project's Files tab
  and previews the owner's file; the request carries its `LogicalProjectRef`, is consumed once, and is dropped when another Project opens
  (test: chip press, preview, Threads and back to Files shows no stale preview, a foreign request previews nothing).
- **Typed task links**: each resolving link is an actual `AXButton` ("Open <title>, working|needs you|resolved") over its chip, found from the
  text's own layout (`Text.LayoutKey`), 24pt tall while the chip stays the board's 21.6pt line box. Pressed through `ControlPress` with duplicate
  titles: each opens its own task ID in the Threads pane. Stale, foreign and half-written links have no control. SwiftUI's own text-link
  node (`AXLink`) is disabled and takes no press (pressing it aborts the off-screen process), so it is not used.
- **Rhythm**: Started cards at y 336, 392 and 424 equal the PNG board's. The paragraph's half-leading is now CSS's fractional value
  (`NWLineSpacing.halfLeading`). The coordinator's replies draw no turn footer (it reserved ~40pt the boards do not draw); worker threads
  and ordinary threads keep theirs.
- **Overview (09, Empty)**: window render from a real created Project at 1x/1.3, light/dark, with a linked Space, with none, and with a long name
  and Space name. Control test: every row and suggestion is a 24pt button at 1x and 1.3, a suggestion fills the composer and sends nothing,
  a row opens its settings tab.
- **Long titles and file names**: card title ellipsizes (tail), file names ellipsize (middle) past `chipNameMaxWidth`, and the card keeps its width
  at 1x, 1.3 and a 1000pt window; a wrapped link title draws its dot once.

Open: the Paused board's banner and first-card geometry were measured (ours starts the second block at 142 against 140.5) but not re-fit; the
ThreadRunning Steps card and composer were not re-measured this pass; the Started status line is 4.5pt lower than the markup render (the PNG
shows no text at that threshold, so it is unresolved); NewProject sheet and AddsSpace were not re-measured against 02/03; RunElsewhere and the
structured Automation board are not built (awaiting the user). Not claimed: 1:1.


## Final pass (UI10): same-state renders and exact remaining differences

Renders come from the real producers (`SHEPHERD_PREVIEW_SCALE=2 swift test --filter LogicalProjectBoardPreviewTests|LogicalProjectPreviewTests`),
full 1600x900 windows, light and dark at text scale 1 and 1.3. Compared with the saved PNGs at 2x.

- **Same state as the boards.** Question/Resolved/Paused play the board's flow through the stub engine: three assigned workers (held until the
  coordinator's book is written), the person's own "lets try it out", the coordinator's reply with the worker's context, the worker's native
  select. Started and ThreadRunning seed a real `project_assign` call and a worker that publishes a plan; the composer names the model through
  the engine's startup config (`claude-sonnet-4-6`, Low for the coordinator, no level for a worker), not a producer-copy change.
- **Assignment as prose.** A worker thread's first user message carries the owner's assignment operation (`ProjectTaskRow.assignmentOperations`);
  a message with one of those is drawn as plain prose, any other user message (a person steering) stays a bubble. A turn that mixed the
  owner's wake-ups with the person's words keeps the person's words (consecutive user messages are one turn).
- **Live line.** "Starting threads" with the muted ellipsis comes from the coordinator's last call being a done `project_assign` with a typed task
  reference (`ProjectRunStatus.justAssigned`), or from the owner holding a queued or reserved task; "Working · 52s" comes from the worker's own
  turn start. Otherwise the ordinary "Thinking…".
- **Rhythm.** Started cards equal the PNG (y 336/392/424). Paused blocks agree within 1-4pt from the first card to the question card (ours 468
  against the board's 467 for its top); the transcript adds no extra gap above the composer in Project threads.
- **Accessibility.** Each separate mention of a task is its own labelled 24pt button; a mention that wraps is one. Test: one task mentioned twice
  plus a long title that wraps (fails when the fragment count is not reset per mention).

Remaining differences are recorded in "Pass UI11" below. RunElsewhere and structured automation triggers await user decisions.

## Pass UI11: measured causes and corrections (not claimed 1:1)

Renders: `/tmp/ui-final11/r` (126 PNGs, full 1600x900 windows at 1 and 1.3, light and dark, from the real producers). Board numbers are read from the
board PNGs and from the original markup in headless Chromium at 1x (CSS px = pt). Each row says what was compared and what is left.

- **Worker composer: the board is built as drawn.** Board 08's worker pane draws the red `stop.fill` Stop (28pt at 1534,855) while its turn runs; the disabled
  arrow is the Project composer on the left (982,855). Both match now (render 1534,855 and 983,855, 1pt off on the arrow). Pressing the worker's Stop aborts only
  that worker (`aRunningWorkersEmptyComposer...`). No departure.
- **Controls row of both composers.** The board's controls row sits 9pt under the field and flush to the 1pt line (Attach 856, Stop 855); ours left 4 above and 6
  below, so every control was 5pt high. Now `NWLeadMetrics.composerControlsTop/Bottom` through `nwComposerControlsInset`, set only for Project and worker composers.
- **Mixed user turns.** One row, drawn per message from the real operation IDs (`ProjectUserOrigins`): assignment plain, the person's words a bubble with their
  images and design references; wake-ups drop out of a mixed coordinator turn and hide a pure one. Tests: `ProjectUserOriginsTests` (5) and
  `aWorkerTurnHolding...` through the real worker store and AX tree. Render: `board-worker-mixed-*`.
- **Worker paragraph wrap: fixed.** Cause: SwiftUI's `Text` avoids a one-word last line (private, always on). Geist 13.5 measures the line "...a partner would" at
  405.92pt in Chromium and in Core Text, and 447pt fits it; `Text` breaks after "partner" (368.3pt) at every width 380...447. A plain Project paragraph is now an
  `NSTextField` with `lineBreakStrategy = []` (`NWPlainParagraph`, only where Project prose has no link, chip, code or emphasis), which breaks where the board does
  (render line 1 ends x 1541.5, board 1541.5; line 2 "embed." ends 1181.5, board 1181.5). Selectable; one AXStaticText; ink colour equals `textPrimary` in both
  appearances. Ordinary threads and paragraphs with task chips keep `Text`. Test: `ProjectProseWrapTests`.
- **Steps card.** Card 447 x 66 at y 184 (was 64, y 188): its 12pt padding sits inside the 1pt line. The pane's first line sits 12pt under the header, not 16
  (`paneThreadTop`). Pinned to the point by `aWorkersPlanFromTheEngines...` (card, rows, live line 15 tall and 16 under the card). The live line's ink is 1.5pt
  lower than the board's (270 against 268.5); the line box is equal, so this is glyph placement inside it and is not fixed.
- **NewProject (03).** Field edges equal at y 84/85, 115/116, 155/156, 186/187; Create 104 x 28 at 440,597 (board 438, 105 wide); footer rule 582. Fixed: the help
  sentence wrapped one word early because fields were 528 wide, the board's 526 (the 1pt border is inside the 560); and the Add a space popup was 122 wide, now
  129 (board 17..146) with its chevrons where the board puts them. Left: title and label ink start 1 to 2pt left of the board's (17 against 18, label 28.5 against
  30.5) from the same SwiftUI/Chrome text origin difference; not changed.
- **AddsSpace (02).** Card 576..1256 wide, 233..283 tall, equal. Add to project 1144..1248 against the board's 1142..1247, 1pt narrower. The card's second line shows
  the long temp path in the render (the board's `~/code/gamecards-web`); that is the fixture's path, not a layout difference.
- **Open at UI11:** see UI12 below, which settles the focus ring, the pane box and the sheet boxes.
- **Not claimed:** 1:1 for any surface above; RunElsewhere and the structured Automation board are not built (awaiting the user).

## Pass UI12: focus ring, pane box, sheet boxes (not claimed 1:1)

User updates stand: macOS-only hosts, Designs first in Activity, no subagents in Projects, Experiments ▸ Projects off by default. Every fixture below sets
`settings.projectsEnabled = true` before the app starts. Renders: `/tmp/ui-final12/r` and `/tmp/ui-final13/r` (full 1600x900 windows, light and dark, 1 and 1.3).
Board numbers come from the board PNGs and the original markup in headless Chromium at 1x. RunElsewhere (board 10) and automation triggers await the
user's workflow decisions; neither is built.

- **Worker focus ring: rendered from state.** `ThreadInput.focus()`, the app's own request, is made while the window never becomes key; the render waits until the
  right pane's field editor is the first responder (`board-thread-running-worker-focus-*`). The card's 3pt ring (y 787, 887) and line (790, 883) equal the board's in
  all four modes; the unfocused render keeps the plain line.
- **Pane box (the layout miss behind the 1pt divider).** In the original 08 markup the pane is `<div style="width:480px; border-left:1px solid var(--line-subtle);
  box-sizing:border-box"><aside style="width:479px">`. `NWLeadMetrics.paneWidth` is now 480 with `paneBorder` 1: the pane's content takes `paneBorder` of
  leading padding and the named hairline draws exactly that 1pt (`NWHairline(.vertical, width:)`; its default is one device pixel). The separator is at x 1120 and the
  content starts at 1121, as the board; the conversation is 888 wide, so its 680 column and the composer card start at 336 (they started at 336.5 beside 479).
  Measured in 07, 08, the focus render and 04 (Paused), light and dark, 1 and 1.3: separator 1120/1121 and the composer card 336..1015 equal the boards'. Pinned by
  `aWorkersPlanFromTheEngines...` (the pane box begins where the page minus 480 ends, four modes) and by the conversation test (column starts at 336 in four modes;
  with the old 479 both read 336.5 and fail). Expanded, the pane still takes the whole page; the Collapse control stays at the page's trailing edge. No ordinary pane or
  global token changed.
- **Steps card, live line, plain paragraph in four modes.** Card 447 wide, 66 tall at 1x and 74 at 1.3, rows 6 apart, live line 16 under the card and 15 tall at 1x.
  Line 1 of the worker paragraph ends where Core Text's greedy break of the same words does, in all four modes; an ordinary thread keeps SwiftUI's own wrap.
- **NewProject (03) and AddsSpace (02) boxes (layout, from the markup's computed boxes).** Fixed: footer buttons were 61 and 104 wide, now label + 10 + 1pt line each
  side (62.7 and 105.4; Not now 71, Add to project 105.1); the header starts 1pt lower (close at y 19); "optional" follows a real space. Pinned in the existing
  `create()` and offer tests (the accessibility frame rounds outward to whole points). Ink differences left, not nudged: the New project title ink is 1pt lower
  than the board's (28 against 27) with the box placed as in the markup; Create's left edge 437 against 438 and Add to project's right edge 1248 against 1247 are
  edge snapping at equal widths.
- **Project composer while the coordinator runs.** The disabled arrow (no Stop), enabled Send and the outlined Stop with a draft, and no pause, checked through
  AX with the engine's `project-action` script held by its own `continue-1` file (no focus, no sleep). Reverting the rule turns the test red.
- **Plain paragraph measurement.** `NWPlainParagraph` no longer uses a numeric size ceiling: the label measures itself with `greatestFiniteMagnitude`; a 300-character
  unbroken token wraps inside a 200pt column (test). Its comment says what was observed, not what SwiftUI does inside.
- **Remaining ink differences (recorded, not approved by this lane):** the live line's ink is about 1.5pt lower than the board's in the dark render (its box is
  pinned); the New project title ink is 1pt low; Create 437 against 438 and Add to project 1248 against 1247 (above); the close mark within 0.5 to 1pt. These are
  glyph or edge placement at equal layout boxes, measured only in the renders named above.
- **Not claimed:** 1:1 for any board; RunElsewhere and the structured Automation board stay unbuilt, awaiting the user.

## Draft PR screenshot audit

A fresh run of the integrated code passed 25 preview tests and produced 202 images. The draft
keeps 32 unchanged light/dark PNGs with hashes in `../evidence/project-lead/`. These are scratch
runtime previews, not live-provider or interactive Dev screenshots. Review exposed two additional
open issues: the resolved preview still draws a worker composer above Reopen, and the narrow
long-title preview puts a Working row beneath "Nothing is running." Neither is accepted as a
design match. The [evidence index](../evidence/project-lead/README.md) lists all retained images,
the reproduction command, and pending workflow decisions.

## Projects experiment (user-authorized gating, not a board change)

Settings ▸ Experiments ▸ Projects (`AppSettings.projectsEnabled`, off by default) gates this whole checklist. The boards are unchanged
while it is on. Off, nothing above is drawn or reachable: no Projects group, header or New project chip in Activity, no Projects block
above Spaces in the Spaces mode, no New project sheet, Project page or Project settings from any entry (row, chip, palette, menu,
`showNewProject`, `openLogicalProject*`, `openDestination`). A leftover Project destination shows and hides nothing. Off closes only the
Project page, settings, New project and New thread sheets and the pane's task and file. Closing the creation sheets discards their unsaved inputs;
saved Projects, files and conversation drafts remain. Re-enabling never reopens the dismissed sheets or resumes work. Spaces (the old "Projects") and ordinary threads are unaffected. RunElsewhere and automation triggers stay unbuilt.
