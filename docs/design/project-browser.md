# Spaces > Browser

> Read when: changing space cookie settings, site filtering or clearing controls.

User board `ProjectBrowser.dc.html`, revision 572. Saved as
[ProjectBrowser.png](boards/ProjectBrowser.png). It overrides older per-thread cookie docs.

## Implementation checklist

- Reuse the space header and Settings navigation. Add Browser after MCP servers. The active
  Browser tab has a 2pt lantern underline. Body fills the remaining width with 40pt side
  gutters, page top 36pt, header height 128pt and body groups 24pt apart. The 232pt navigation
  includes its divider. The user's full-width Settings request supersedes the board's 860pt
  cap. At 1440pt, content starts at x=272 and spans 1128pt. There is no editor or right-hand
  context column in this tab.
- Heading "Browser cookies", 15pt semibold. Explanation 13.5pt with 1.55 line height, maximum
  620pt width. Real space name replaces the board's sample name. Exact explanation:
  "Browser tabs in all threads and worktrees for <name> share cookies on this Mac. Other
  spaces use separate cookies."
- Trailing "This Mac only" badge. Supplied computer vector, `NWGlyph.Settings.computer`,
  12pt, 11.5pt text, horizontal 8pt and
  vertical 6pt insets, 6pt radius, lineSubtle border. This is the viewer Mac even when the space
  lives on a remote host. Cookies never go through the remote protocol.
- Toolbar: Filter sites search field, 260pt wide and 32pt high, 13pt text, supplied 14pt search vector,
  10pt horizontal inset, 7pt radius, bgRaised, lineStrong border. Then actual total site/cookie
  count in 11.5pt secondary text. Trailing "Clear all cookies…" action, 28pt high, 10pt
  horizontal inset, 12.5pt medium text, destructive foreground, no resting fill.
- Table: lineStrong border, 10pt corners, 1pt border insets outside its content. Header 32pt,
  bgSunken, lineSubtle bottom separator.
  Columns Site, Cookies, unnamed actions. Cookies column 100pt, actions column 136pt, 16pt
  column gaps and insets. Site grows. Counts right aligned, 12pt mono; domain 13pt mono,
  single line, complete domain in tooltip. Rows 58pt minimum and lineSubtle separators.
  Supplied globe vector, 14pt inside 28pt bgSunken square with 6pt corners. Row action "Clear cookies…" has
  accessibility label "Clear cookies for <site>". No cookie names or values appear.
- Footer: supplied lock vector, 14pt, 8pt gap, 11.5pt secondary text, 1.55 line height. Exact strings:
  "Cookies stay in Shepherd on this Mac, not in your repository. Cookie values are never shown
  here." and "Clearing cookies leaves local storage and cache unchanged."
- The empty table's 200pt body includes its padding. Empty/no-match/loading/unavailable
  states keep the header and local scope. No cookie values
  or page contents enter error text. Remembered folders without a currently owned SpaceID
  cannot pick an unrelated or name-derived store. Show a safe unavailable state.
- Clear one site and clear all first ask for confirmation. No deletion on the first action.
  Confirmation is 480pt, bgWindow, 24pt inset, 12pt corners, 17pt title, project/host scope,
  Cancel and a 32pt Clear cookies button. Center and shade the whole Settings viewport,
  outside the horizontally scrolling column, so both controls stay visible at the minimum
  window width. Quiet destructive text mixes 80% failed with text-primary; confirmation fill
  mixes 75% failed with text-on-lantern. Cancel changes no cookie. Clear deletes
  cookies only, not localStorage or cache, and then reloads counts. Status stays on this page.
- BrowserSessions owns WebKit calls in BrowserHost.swift. Use the same cached space store as
  thread pages, keyed by stable SpaceID and configured remote hostID. Cookie domain grouping
  and site deletion use the same normalization, including leading-dot and case handling.
  Tests seed the real store, use AX controls and verify another space and storage survive.
- Render populated, empty, filtered, long domains, site/all confirmations, clearing/error,
  success and unavailable states in light/dark and text scale 1.3. Capture the running Dev app.

All drawn glyphs use the supplied static SVG outlines via `NWGlyph.Settings`, not approximate
SF Symbols. Assets contain no board HTML or script. The bundled Geist and Geist Mono faces keep
fractional point sizes on macOS and apply the selected text scale once. Baseline adjustments
preserve the board's text positions. Borders and table rules use 1pt CSS widths at 1x and 2x.

## Decisions

Site totals describe the whole space store, independent of the text filter. Clear all clears
that store, not only the filtered rows. Sites sort by count descending, then domain. Only sites
and counts leave BrowserHost's cookie APIs.

## Clearing and failures

Confirming Clear blocks tab and sidebar navigation and hides the background from accessibility.
Reopening Browser rereads the store. Closing the page cancels pending confirmation. A failed
read invalidates counts and disables Clear instead of showing cached zero or stale counts.

WebKit's post-delete list can lag. The model checks it at most 20 times with a 100ms interval.
The intervals add at most 1.9 seconds of polling delay; WebKit callbacks take their own time.
Cookie writers can create new cookies during that window. The UI then reports the
current sites and counts with a new-cookie notice, not a false deletion failure. Readback errors
keep the completed deletion notice but mark the counts unavailable until the tab reloads.
