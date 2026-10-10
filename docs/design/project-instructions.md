# Project instructions

> Read when: changing the project detail layout, instruction editor or context cards.

Source: `ProjectInstructions.dc.html`, revision 562. The supplied PNG is saved in
[boards/ProjectInstructions.png](boards/ProjectInstructions.png). The HTML has different
sample data from the PNG. Match the PNG layout, not its incidental sample data. Actual text,
counts, paths, dates and host state come from `ProjectSettingsStore` and `ProjectsModel`.

## Checklist

- Settings navigation, including its divider, stays 232pt wide and highlights Projects. Its Pi subpages are visible
  on this detail screen, matching the board.
- The content starts 36pt from the top and fills the remaining width with 40pt side gutters.
  The user's full-width request supersedes the board's fixed header and editor widths.
  The editor expands beside a 250pt context column with a 20pt gap. Stack the context below
  the editor when the available content width is below 938pt. The page no longer scrolls
  a fixed-width column horizontally.
- Breadcrumb `Projects`, the supplied outline chevron, `NWGlyph.Settings.next`, then the
  real project name. Pressing
  Projects returns to the list, with discard confirmation for an unsaved draft.
- Identity uses the supplied outline folder, `NWGlyph.Settings.folder`, in a 32pt raised
  content square, 34pt including its 1pt border,
  with rounded corners, a 22pt semibold project
  name, its monospaced display path, and the host name aligned right.
- Underlined tabs are `Instructions`, `Settings`, `Resources`, `MCP servers` and `Browser`.
  The Browser tab follows [ProjectBrowser](project-browser.md), revision 572. Counts are
  real project resource and MCP configuration counts. The selected underline is the lantern
  token. Resources includes skills and extensions. Tab changes protect unsaved edits.
- File selectors are 26pt tall, 6pt radius, 10pt horizontal padding and 8pt gap. Instruction
  files are `AGENTS.md`, `AGENTS.override.md`, `.shepherd/APPEND_SYSTEM.md` and `.shepherd/SYSTEM.md`.
  Their labels use filenames, their accessibility names preserve paths. A missing file can
  be selected and created. The selected path appears on the trailing edge.
- Editor border uses `lineStrong`, radius 10pt. Body is `#111316`, header `#15171a`. Metadata
  header is 34pt tall, padding 12pt, and contains the format, estimated token count, a 1pt by
  14pt divider and file modification age. No token counts or dates are copied from the board.
- A 44pt line-number gutter and 12pt inset precede 12.5pt monospaced Markdown with 21.25pt line
  height. Editor text uses `projectInstructionText`, headings `projectMarkdownHeading`, inline
  code `projectMarkdownCode`, and the caret lantern. The editor fills the available height.
- Footer is 40pt tall. It says `Saved to the project folder. It takes effect in new turns.`
  with `Open in editor` and `Save`, each 30pt high with 8pt corners. Open in editor sends the
  host-owned, allowlisted file to that host's editor. Save uses the actual file and expected
  contents. The save chord resolves through `KeybindingsStore`.
- Right column starts 36pt below file tabs, blocks 14pt apart. Its heading is
  `WHAT AN AGENT READS HERE`, 10.5pt monospaced with 0.06em tracking.
- Reading card has 10pt corners and 46pt rows. Each row has a 6pt dot, label, and trailing
  scope. Rows come from global-instruction existence metadata and applicable ancestor
  `AGENTS.md` files. The selected project file uses the running color; metadata never includes
  global or ancestor file contents.
- Explanation is `Pi loads every context file from the folder up to the root. A file in a
  folder applies there and below.` It uses 11.5pt text and wraps without truncation.
- Hosts card uses a sunken fill, strong border, 10pt corners, 14pt horizontal and 12pt vertical
  padding. It identifies the selected host and comparable named project copies. `In sync`,
  `Differs`, `Unavailable` or `Unverified` come from file comparisons, never fixture literals.
  The matching dot uses the done color and its label uses the semantic host-comparison color.
- Final note is `APPEND_SYSTEM.md adds to the system prompt and SYSTEM.md replaces it. Both
  live in the project's .shepherd folder.` It wraps at large text sizes.

## States and validation

Render the list and every detail tab in light and dark at both 1.0 and 1.3 text scale. Cover
empty resources, missing files, edited, saved, discard, conflict, invalid JSON, unsafe files,
unavailable hosts, long paths and narrow windows. Use `ControlPress` to select each visible
tab and instruction file, edit native text, save, open the host editor and confirm discard.
The remote details capability protects older hosts from unknown `context` or `open` requests.
