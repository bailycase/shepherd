# Projects width correction

The user resupplied `ProjectBrowser.dc.html`, revision 572, after reporting that the Projects
pane's width and spacing were still wrong. The original image is saved unchanged at
`docs/design/boards/ProjectBrowser.png`.

## Checklist before implementation

- Validate through `RootView` and its in-window Settings overlay, not only a standalone
  `SettingsView`. Use the real `SessionServer`, project files and WebKit project cookie store.
- At the board's 1440 by 900 size, Settings navigation is 232pt. The project's header,
  Browser intro, toolbar, table and footer share one centered 860pt column, starting at
  approximately x406. The page starts 36pt down. Header height is 128pt and Browser groups
  have 24pt gaps. Use `AppLayout` and `NW.Space` tokens for those dimensions.
- Preserve the breadcrumb, outlined `folder` in its 32pt content square, 34pt with the border,
  actual project name/path
  and host, and tabs in order: Instructions, Settings, Resources, MCP servers, Browser.
  The Browser tab's 2pt underline uses `lantern`.
- Intro is `Browser cookies`, 15pt semibold, then the actual project-name description in
  13.5pt text, a 620pt maximum and 1.55 line height. Trailing badge is `This Mac only`, with
  outlined `desktopcomputer` at 12pt, 11.5pt text, 8pt horizontal and 6pt vertical insets.
- Toolbar has `Filter sites`, outlined `magnifyingglass`, a 260pt by 32pt field, real
  site/cookie totals and trailing `Clear all cookies…`. The field filters without changing
  totals. The clear action opens confirmation and does not delete on the initial press.
- Table is 860pt at board size, radius 10pt, `lineStrong` border. Header has `Site` and
  `Cookies`, height 32pt and `bgSunken`. Rows have a 58pt minimum, 16pt insets and column
  gaps, a flexible site column, 100pt cookie counts and 136pt actions. Site text is 13pt
  mono. An outlined `globe`, 14pt, sits in a 28pt sunken square with 6pt radius. Counts
  come from the project's WebKit store. Each `Clear cookies…` asks before deleting.
- Footer has outlined `lock` at 14pt, 8pt gap and 11.5pt secondary text. Exact strings are
  `Cookies stay in Shepherd on this Mac, not in your repository. Cookie values are never
  shown here.` and `Clearing cookies leaves local storage and cache unchanged.`
- Keep the existing real-data states and controls. Loading shows `Loading cookies…`;
  empty shows `No cookies yet`; filtering to no results shows `No matching sites`;
  unavailable scope or read failure shows `Project cookies unavailable`. Confirmation
  identifies the project and viewer Mac. Cancel changes nothing. Confirm clears only
  cookies in the selected scope. Model-generated success/error strings are unchanged.
- Cover the populated board, empty, long domains/project names, filtering, confirmation,
  success and unavailable scope in light/dark and text scale 1.3. Exercise list/detail
  navigation and resize the real RootView host, including a window narrower than the board.
- Assert the rendered table width and alignment at the board size. A geometry regression
  must fail when the actual Settings container gives Projects the wrong width. Run the
  existing accessibility control tests and capture the bundled Dev app without focus or
  synthetic mouse/keyboard events.

## Results

The root-window frame checks pass at widths 1050, 1267, 1440 and 1800pt and at text scale
1.3. At 1440pt the list and Browser table are 860pt wide; the table starts at x406 and y335.
At narrower widths Projects preserves the column and exposes native horizontal scrolling.
Instructions stacks its context column when that column no longer fits. The 232pt Settings
navigation includes its divider rather than adding the divider outside that width.

The first geometry regression failed before the correction, when the column shrank at 1050pt.
The final focused run passed 73 tests in 12 suites. It includes real list/detail navigation,
filtering, cancellation, site and all-cookie deletion, isolation and empty-table geometry.
Confirm and Cancel stay inside the visible viewport at 720 and 900pt with legacy native
scrollbars enabled. Unit checks cover cookie errors/races and project presentation.

The shipping Dev Xcode build passed with locked package versions. Release/documentation
checks passed, 421 tests. `git diff --check` passed. The temporary capture entry point is
removed from the shipping build. Local runtime validation used macOS 27.0.1; macOS 26 was
not available here.

## Images

- [Board beside the running Dev app](board-and-app.png).
- [Browser, both appearances and large text](gallery-browser.png).
- [Narrow windows and viewport confirmations](gallery-narrow.png).
- [Project list and Instructions](gallery-list-and-instructions.png).

`app/` has 32 running-app images, captured from the bundled executable, a live scratch server,
project-file IO and WebKit project cookies. `app/capture.txt` records the running application
and fonts. Native view-cache capture keeps the complete window at its actual size. Windows
stay off-screen and no event or focus is posted. Widths are 1440, 1050 and 720pt, plus 1440pt
at text scale 1.3, in light and dark.

`previews/` has 136 RootView renders in light/dark and text scales 1.0/1.3. The Browser set
covers populated, empty, filtered, long, one/all confirmations, success, unavailable and narrow.
The Projects set covers local/remote/offline history, long names, empty/loading/error states,
editing/conflict/discard and every file category. The following images are representative:

- [Empty Browser](previews/project-browser-empty-dark.png).
- [Long sites at large text](previews/project-browser-long-x1.3-dark.png).
- [Narrow Instructions](previews/projects-detail-narrow-light.png).

## Departures

The width and narrow-window behavior now follow the board. Native SF Symbols have different
contours from its SVGs, although their identities and fill variants agree. The native text
renderer wraps the description one word earlier in the same 620pt box. Device-pixel dividers
are thinner than the board's CSS separators. These remain visible in the comparison, and the
render is not pixel-identical. They use the existing native symbols, fonts and divider tokens;
this change does not substitute custom SVG or text rendering.

Names, counts, paths and versions differ when the fixture data differs. They come from the
actual producers rather than copied board values.
