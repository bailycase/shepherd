# Side pane: Artifacts, Files (not built yet)

> Read only when asked to build the Artifacts or Files tabs.

**Not built yet.** The page boards give the side pane two more tabs beside Changes and Browser
(PaneStates, PaneArtifacts, PaneArtifactEdit, PaneFiles). Neither is shown until it is built. When
one is, it joins the strip and the ⋯ menu above and follows this section; where the boards leave a
choice open, it says so. The boards draw these surfaces at radius 10 (9 and 5 for some tiles and
rows) beside a 52pt toolbar. This section gives their other values as drawn and maps radii onto the
radius scale (8 for cards, panes and tiles, 6 for rows and controls, 12 for popovers), as the
departures table records for the page boards.

- **Their tabs** (`SidePaneTabs`, PaneStates): Artifacts (with its count of new artifacts) and
  Files, after Browser, taking ⌃3–⌃4. A tab the agent opened something in gets the dot and a brief
  popover under it ("Agent opened localhost:5173/checkout" with the URL in mono and its age in
  `textTertiary`; Geist 12, a 12pt glyph).
- **The rest of the ⋯ menu** (`SidePaneOptions`), once there is more than one tab: Split below,
  Open pane in its own window (⇧⌘O), Reset width, a divider, then "Show tabs" with a checkable row
  per tab. Changes can't be hidden while the thread has edits.
- **Split** (`SidePane · split`): drag a tab to the pane's bottom edge to split it (Browser over
  Files). The divider is 12pt on `bgBase` with a 36×4pt `lineStrong` grip (radius 2) between
  hairlines; the lower pane has a 34pt header (a 13pt glyph, the name in Geist Mono 12 semibold,
  the unsaved dot, and a 24pt Close split).
- **Widths** (PaneStates): 760pt default for Files (tree plus editor); double-clicking the divider
  sets half the window; the thread keeps at least 520pt. Each thread remembers its tabs, split and
  width. The pop-out window conflicts with the one-window rule (Window and adaptive layout): decide
  before building it.
- **Keys**, shown in menus and tooltips, never under the composer: ⌃3–4 switch to these tabs,
  ⌘P go to file, ⌘S save a file or artifact, ⇧⌘O pane in its own window. ⌃3–4 are fixed like ⌃1;
  the rest go through `KeybindingsStore`, and each must be added to `appOwnedChords` so a focused
  terminal doesn't eat it. (The Browser's ⌘L and ⇧⌘C are built: Side pane: Browser.)

**Artifacts** (PaneArtifacts, PaneArtifactEdit, PaneStates): reports, plans, diagrams and images
pi makes along the way. Each is a file on the thread's host, versioned on every save by you or
pi. Open one from the thread or the list; edit it in place.

- **In the thread:** an activity line "Made an artifact · Load test report · v2", and a card
  (`bgRaised`, a `lineStrong` line, radius 8, padding 10×12, 12pt gaps): a 34pt `bgSelected` tile
  (radius 8) with a 17pt kind glyph, the name in `body` semibold over "HTML · v2 · 6m ago" in
  Geist 12 `textTertiary` (the version in mono), and Open (secondary `s`, with a glyph).
- **The list** (`ArtifactList`): "This thread · 4", then "From the mission · <mission>" as
  section labels (Geist Mono 10.5 caps, 0.5pt tracking, `textTertiary`, padding 10/8/4/8), newest
  first. Rows are at least 48pt, padding 6×8, radius 8, 10pt gaps: a 30pt `bgSelected` tile
  (radius 8) with a 15pt glyph, the name in Geist 13 medium (semibold when open, on
  `bgSelected`) over "Markdown · v4 · just now" in `caption` `textTertiary`, plus "edited by you"
  in `micro` `lanternText` after a save of yours, and a 24pt ⋯ trailing.
- **An open artifact:** a 44pt bar under the tabs (8pt padding and gaps): All artifacts (28pt
  `nwIcon`, back to the list), a 22pt kind tile (radius 6), the name in Geist 13 semibold
  (truncating), a 22pt version chip (radius 6, `lineSubtle`, a clock glyph, "v2 · 6m ago" in
  Geist Mono 11 `textSecondary`, a chevron) that opens its versions, then a small Preview | Source
  `NWSegmentedPicker`, Edit and Open in a window (28pt `nwIcon`). Diagrams and Markdown render in
  Night Watch colors, so they follow light and dark; HTML artifacts keep their own styles, on
  their own background with 18pt padding.
- **Versions** (`ArtifactVersions`, a 280pt popover): the file's name in `caption` semibold
  `textSecondary`, then one 38pt row per version, newest first: a check on the one shown, "v4"
  over "You · 2 lines" (or "Agent · open question added") in Geist 11 `textTertiary`, and its age
  trailing in Geist Mono 11. Then Compare v3 with v4 and Restore v3. Restoring makes a new version.
- **Editing in place** (PaneArtifactEdit; the board widens the pane to 640pt): the bar becomes an
  editing bar on `lanternTint` (44pt, padding 0/10/0/12): a 14pt `lanternText` pencil, "Editing
  retry-plan.md" in Geist 13 semibold (the name in mono), "v3 → v4" in Geist Mono 11
  `lanternText`, then Source | Split | Preview, Cancel (ghost `s`) and "Save v4 ⌘S" (primary `s`,
  its chord in Geist Mono 10.5 at 60%). The source is numbered: lines at least 22pt in Geist Mono
  13, a 3pt change bar, 40pt line numbers (Geist Mono 10.5 `textTertiary`, 12pt right padding);
  Markdown marks in `textTertiary`, headings semibold `textPrimary`, list markers `lanternText`,
  code in the theme's string color, prose `textSecondary`. Your edited lines are `lanternTint`
  with a `lantern` bar, and the caret is a 2pt `lantern` bar. A 30pt footer (a hairline above,
  `caption` `textTertiary`) keys it: "Your edits" with its swatch, and trailing "Ln 15, Col 43 ·
  Markdown" in mono.
- **Your version goes back to pi:** while you edit, the thread shows "You're editing
  retry-plan.md" (`ui` `textSecondary`, a 13pt glyph) with "v4 draft · 2 lines" in Geist Mono 11
  `textTertiary`, and the composer carries a chip for the draft ("retry-plan.md v4") that goes
  with the next message.

**Files** (PaneFiles, PaneStates): the thread's worktree, on whichever host it runs. Edits save
straight to that host. Saving and Revert here would mutate the repository, which only the paths in
docs/rules.md › Only these paths mutate repositories may do: add Files to that list by a decision
before building it (as iOS: iPad › Side pane says).

- **The tree,** 210pt on `bgBase` with a hairline on its trailing side. Its header (padding
  10/10/8/12, a hairline beneath): the repository in Geist Mono 12.5 semibold with Go to file (24pt
  `nwIcon`), over the branch and host in Geist 11 `textTertiary` with 11pt glyphs ("fix/pay-jump"
  in mono · "build-01"). Rows are 24pt, radius 6, 8pt leading padding plus 14pt per level, 6pt
  gaps: a 9pt disclosure chevron (or its space), a folder (13pt `textSecondary`) or file (12pt
  `textTertiary`) glyph, the name in `ui` (semibold on `bgSelected` when open), and trailing an M
  in Geist Mono 10.5 semibold `lanternText` for a changed file and an 11pt `running` pencil for a
  file pi is editing now.
- **Its context menu:** Mention in message (a file chip in the composer), Show in Changes, Show
  history (subtitle "3 commits · 1 by the agent"), a divider, Copy path, Open in your editor.
- **Go to file** (⌘P, a 300pt popover): a 34pt field on `bgSunken` (radius 6, a 13pt glyph, the
  query in Geist Mono 13, a `lantern` caret, the ⌘P keycaps), then 38pt results: a file glyph,
  the name in `ui` over its directory in Geist 11 `textTertiary`, and its status letter trailing.
  It fuzzy-matches across the worktree on the thread's host.
- **Editor tabs** on `bgBase` with a hairline beneath: 36pt tabs, padding 0×12, a hairline on
  their trailing side, a 12pt glyph and the name in Geist Mono 12. The current tab is on
  `bgWindow` in `textPrimary` with a 2pt `lantern` line along its top and a 7pt `lantern` dot
  while unsaved; the others are `textSecondary` with a 9pt close ×, or the `running` pencil while
  pi edits that file.
- **The path bar,** 36pt, a hairline beneath: "src › components › Checkout.tsx" in Geist Mono
  11.5 `textTertiary`, then Revert (ghost `s`) and "Save ⌘S" (secondary `s`).
- **The editor:** lines at least 21pt in Geist Mono 12, a 44pt number gutter (Geist Mono 10.5
  `textTertiary`, 8pt right padding), a 3pt change bar and 10pt gap, syntax colors from the theme.
  The bar is `lantern` for your unsaved lines (which sit on `lanternTint`) and `running` for lines
  pi changed. A 28pt status bar (a hairline above, Geist 11 `textTertiary`) keys them ("yours,
  unsaved", "changed by the agent") and ends with "Ln 94, Col 48 · TSX · Spaces: 2" in mono.
- **The agent changed your file:** an attention banner under the path bar (`lanternTint`, padding 10×12):
  "Agent changed Checkout.tsx while you had unsaved edits." with Compare and Keep mine (secondary
  `s`) and Use the agent’s (ghost `s`). Your unsaved edits are never overwritten; Keep mine saves over
  pi's change and tells pi in the thread.
