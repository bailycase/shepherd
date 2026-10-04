# Project Browser full-fidelity pass

Revision 572, the PNG sent in this thread, is the appearance requirement. The HTML provides
geometry and static glyph paths, not a second UI implementation. The supplied PNG remains
unchanged at `docs/design/boards/ProjectBrowser.png`.

## Checklist before implementation

- Settings navigation occupies 232pt including its 1pt divider. Match the 44pt top inset,
  30pt Back row, 34pt search border box, 32pt navigation rows, 28pt nested Pi rows, gaps and
  single-line version footer. Projects uses the PNG's selected fill and medium text weight.
- Use the supplied outline artwork with its exact view boxes, line caps and strokes. The
  navigation glyphs are Back 10x12, search 13x13, and each main row 15x15. The Settings assets
  have no fill except the appearance glyph's left half. Native buttons and fields retain their
  existing accessibility actions; no board HTML runs in the app.
- Retain the 860pt column at x406 in the 1440pt board, 36pt detail top inset, 22pt breadcrumb,
  46pt identity row, 34pt folder border box, 18pt path, 34pt tabs and 2pt active underline.
- Breadcrumb uses its 8x10 chevron. Identity uses the supplied 16x16 folder drawing. The name is
  Geist 22/600 with -0.22pt tracking. Path and host are mono 11.5. The path starts 44pt past the
  column edge. Tab titles are 13pt, selected at 500; counts are mono 10.5. Project name, path,
  host and counts come from the live model, not the board's examples.
- Keep fractional font sizes. Bundled Geist/Geist Mono and the board's webfonts have the same
  advances. `Font.custom(size:)` rounds 13.5pt up to 14pt on this Mac; the helper must use its
  explicitly scaled fixed size. iOS keeps Dynamic Type.
- Browser title is 15/600 in a 21pt line box. Description is 13.5pt regular with a 20.925pt
  line height, 620pt measure and 6pt title gap. Privacy footer is 11.5pt regular with 17.825pt
  line height and its explicit line break.
- Local-only badge uses the supplied 12x12 computer, regular 11.5pt text, 6pt glyph gap,
  8pt horizontal and 6pt vertical padding, 1pt border and 6pt corners.
- Filter sites is 260x32 including its 1pt border, 10pt inner inset, 8pt glyph/text gap,
  7pt radius and the supplied 14x14 search drawing. Counts are regular 11.5pt text. The
  destructive toolbar and row actions are text-only, 12.5/500, 28pt, with 10pt side padding.
  They have no visible resting fill or border; hover uses failedTint.
- Table is an 860pt border box with 1pt strong border and 10pt corners. Header is 32pt plus
  its 1pt separator. Count and action columns are 100pt and 136pt with 16pt gaps/insets. Each
  site row body is 58pt with a 1pt divider; the last row has none. Site glyphs are the supplied
  14x14 globe in a 28pt sunken square. Domains are mono 13pt, counts mono 12pt.
- Footer has the supplied 14x14 lock, 8pt gap and 2pt glyph top inset. Preserve both sentences.
  Site/cookie totals are in the toolbar, not an invented footer control.
- Confirmations remain viewport-safe with native Cancel/Escape and destructive Confirm,
  live project scope, readback/error handling and underlying accessibility isolation.
- Cover populated, empty, filtered/no matches, long domains, unavailable/error, cleared,
  confirmations, narrow/minimum width, both appearances and text scale 1.3.
- Use Settings navigation, Back, project tabs, filter/clear search, clear-one, clear-all,
  Cancel and Confirm through their native accessibility paths. Check hit areas and cookie
  isolation/readback. Production strings stay in the model and view.

## Verification

The shipping Dev build passes after removing the temporary capture hook. The focused Swift
selection passes, 113 tests in 13 suites. Python release/documentation checks pass, 421 tests.

The running app captures use `RootView`, live scratch project files, a `SessionServer` and
the shared WebKit cookie store. `app/` has 32 captures. `previews/` has 136 project renders
covering both appearances and text scales 1.0 and 1.3. See `board-and-app.png` and
`full-fidelity-measurements.json` for the comparison.

Measured table edges match the supplied PNG at 2x: 335/336pt outer top, 368/369pt header
separator, 427/428pt and 486/487pt row separators, and 545/546pt bottom border. The sampled
page, sidebar, selected row, table header, border and divider colors match exactly.

Native accessibility checks use the real Settings overlay and project navigation. They press
Back, project tabs, filter clearing, clear-one, clear-all, Cancel and Confirm, verify hit
areas, and read WebKit cookies afterward. The Settings search check uses a unique row name
because searching "Projects" correctly also matches Appearance's "Organize by" keyword.
No test moves focus, posts input events or changes the running user's settings.

The reviewer found no remaining defects in the final icon/guide, hover and confirmation
inset fixes. Hover appearance is source-verified, not simulated with mouse events. macOS
27.0.1 was available locally; macOS 26 was not.

## Departures

No substitute glyphs, rounded font sizes, intentional geometry or token differences remain
on the drawn page. Native text rasterization is not the browser's rasterization; this is not
a claim that every antialiased text pixel is identical. Actual project counts and version
strings differ with the live data, as required by the project instructions.
