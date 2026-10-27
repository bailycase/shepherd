# Browser tabs checklist

Boards (saved as given): [BrowserTabsAgent](BrowserTabsAgent.png) (81), [BrowserTabsElsewhere](BrowserTabsElsewhere.png) (82),
[BrowserTabsFull](BrowserTabsFull.png) (83), [BrowserTabsOpened](BrowserTabsOpened.png) (84),
[BrowserTabsPopup](BrowserTabsPopup.png) (85), [BrowserTabsTwo](BrowserTabsTwo.png) (86).
Components: `Packages/ShepherdUI/.../Components/Browser/BrowserTabs.swift`. Host: `Sources/ShepherdApp/BrowserPane.swift`.

## Order, top to bottom

1. Side pane tabs (unchanged).
2. **Strip** `SHBrowserTabStrip`: 38pt, 8pt side padding, hairline below. Tabs (26pt, radius 6, 2pt apart, 48 to 200pt wide), then New tab and All tabs (24pt `shIcon`).
3. **Note** `SHBrowserTabsNote`, only when there is one: `bgSunken`, hairline below, 12pt sides, 6pt vertical.
4. Toolbar and address field (unchanged), the page, **agent bar** `SHAgentBar` (replaces the floating card, see Departures), console drawer.
5. Over the page, trailing bottom: **Agent is in X** chip `SHAgentElsewhere`, when the agent works in a tab that is not shown.
6. Over everything: **tab list** `SHBrowserTabMenu`, 260pt, 12pt in from the trailing edge, 4pt under the strip.

## Tab

- Favicon 12pt tile, radius 4 (`SH.Radius.xs`), the first letter in Geist 8 semibold `bgBase`, on a theme role chosen from the host (`SHBrowserTabTint`: running, done, lantern, synKeyword, synFunction). The board colors tiles by brand; no brand color is a token.
- Title `ui`; selected is `textPrimary` medium on `bgSelected`, others `textSecondary` regular, hover `bgHover`.
- Agent is using the page: `shSpinner` 12pt replaces the tile. Agent opened it and nobody looked: 6pt `running` dot after the title (no glyph; the dot plus VoiceOver "new").
- Close: `xmark` 10pt medium, 24 × 26pt hit (board 20pt; 24 is the desktop minimum). Shown on the selected tab, on hover, and on all tabs while there are at most 4.
- Tooltip: "localhost:3000/checkout · opened by the agent" / "· opened by a link".
- VoiceOver: "Refund overview, new, agent is using it"; selected has the selected trait; close is "Close <title>".

## Glyphs (SF Symbol, fill)

`plus` (outline) New tab · `chevron.down` (outline) All tabs · `xmark` close and dismiss · `checkmark` list check ·
`globe` note (agent opened, popup) · `exclamationmark.triangle` note (cap) · `hand.raised` Take over (`SHAgentBar.glyph`).
The tab close and the note's dismiss share one view, `SHBrowserTabClose` (the outline `xmark`), so the glyph is named once here. It is not an
`SHGlyph` case: that registry rejects a raw `"xmark"` everywhere, and 45 older uses outside this change would fail it. The board's own
spinner is the existing `shSpinner`.

## Tokens

Space: `SH.Space.xxs/s/m/l` (2, 6, 8, 12). Radius: `s` 6, `xs` 4, popover `l` 12. Heights: strip 38, tab 26, agent bar 32 (= console bar), icon buttons `controlS` 24.
Color: `bgSelected`, `bgHover`, `bgSunken`, `runningTint`, `running`, `textPrimary/Secondary/Tertiary`. Font: `ui`, `caption`, mono 10.5 (menu address, tag, footer).

## Strings, per state (producer in brackets)

| State | String | From |
| --- | --- | --- |
| Tab title | page title, else host, else "New tab" | `BrowserSession.tabTitle` (model) |
| List address | `BrowserAddress.display` host+path | app |
| List tag | "Agent", "Link", none | `SHBrowserTabSource.tag` from `tabSource` |
| List footer | "N of 8 tabs · sign-ins shared across the space" | N = `tabs.pages.count`, 8 = `maxTabs` |
| Opened note | "The agent opened <title> in a new tab." + Show it | `tabs.openedPage` |
| Popup note | "A link opened a new window. Shepherd opened it as a tab." | `tabs.notice` |
| Cap note | "This thread has 8 tabs, the most it keeps. New links open in this tab." | `tabs.notice` |
| Agent bar | "Agent is <note>" | existing `BrowserAgentOverlay.note` |
| Elsewhere chip | "Agent is in <title>" | `tabs.agentPage` not selected |

`tabs.notice` carries the words today. UI shows it as given and picks the glyph by content, which is a guess. Asked of the model owner:
a `kind` (`popup`, `cap`) so the glyph is not inferred.

## States drawn

One tab (strip shows one tab and its close), two, eight (all narrow, selected keeps room), list open, list with one tab (Close other tabs disabled),
opened note with unseen dot, popup note, cap note with New tab disabled, agent on the shown page (bar, ring, pointer), agent elsewhere (chip).
Not drawn by any board and built anyway: a long title (truncates, tooltip has the address), empty title ("New tab"), 1.3 text scale.

## Controls

| Control | Press does |
| --- | --- |
| Tab | `tabs.select(id)`; clears its dot |
| Close <title> | `tabs.close(id)` (no confirm, reversible by reopening); last tab closing is the model's rule |
| New tab | `tabs.newTab()`; disabled at 8 |
| All tabs | opens the list; Esc or a click outside closes it |
| List row | `tabs.select(id)`, closes the list |
| Close other tabs | `tabs.closeOthers()`, closes the list; disabled with one tab |
| Show it | `tabs.showOpenedPage()` |
| Note Dismiss | `tabs.dismissNotice()` (opened note: `tabs.openedPage = nil` via the same) |
| Take over | existing `takeOverBrowser(page)` |
| Agent is in X | `tabs.select(agentPage)` |

## Departures to report (the user decides)

1. Board 81 draws the agent as a full-width bar above the console with a ring. The shipped card floats under the toolbar. Built the bar; the ring and pointer stay.
2. Favicon tile color is a theme role by host, not the site's brand color.
3. Close hit area 24pt, board 20pt.
4. New tab shows no ⌘T: no such chord is wired (honest affordance). The board's tooltip reads "New tab ⌘T".
5. The board draws the unseen dot after the title and before close; same here.

## Verified

- `swift build --build-tests` passes. Component, design-rule, keybinding, theme and token tests pass.
- `BrowserPaneTabsTests` (real `BrowserSession` root and `BrowserTabs`, real web views on a loopback server, the
  real `BrowserPane`, `ControlPress`, five scenarios) passes: tab select, close, New tab, All tabs, list row, Close
  other tabs, last-tab close, cap (New tab disabled and refuses), cap and popup notes, opened note and Show it,
  the unseen "new" label, the agent bar and Take over on the agent's page only, "Agent is in X" and its press, the
  root's own notice staying in view on another tab (and which Dismiss clears), the address text following the
  tab, and ⌘T through the real `BrowserKeys` watcher (on, off screen, and ⇧⌘T left alone).
- `BrowserTabsControlTests` (components over `SHBrowserTabsBoard`) passes; every control is at least 24pt.
- Renders: `browser-tabs-{two,full,opened,popup,agent,elsewhere,long,new}[-x1.3]-{light,dark}.png` from the real
  model at 2x, and `browser-tabs-board-*` from plain values (the board's tile colors). Compared by eye with the
  boards. Found and fixed: the list hung over the note's row (now under it, as board 83); list rows 3.5pt taller
  than the board's (padding 6); minimum tab width; list rows squeezed at 1.3 (it scrolls past 420pt).

## Not verified

- Strings the model has not produced here: remote notices on a real remote host, the claim, the agent's real tool
  notes. The pane's strings for tabs, notes and the list come from the app's own code and are asserted in the tests.
- Page content: a capture draws a web view blank, so the page area is white in the real renders.
- The running app (`Shepherd (Dev)`).
- At 9 or more tabs (the model caps at 8).

## Departures (the user decides)

1. **Tile letter and color.** The boards letter a tile by the page's own name ("A" for Acme payments) and color it
   by brand. The app has no source for either without fetching icons, so the letter is the site's name and the
   color is `running` for loopback and one of `done`, `tabTileViolet`, `tabTileOrange` by a fixed hash. Real
   pages show "L" for localhost, and a site can land on another color than the board gave it. The user approved
   this difference.
2. **Close hit area** 24pt; the board draws 20pt. The user approved this difference.
3. **Floating agent card removed.** The bar and the ring are board 81. The pointer stays.
4. **New tab ⌘T** is wired and shown in the tooltip (`browserNewTab`, Settings ▸ Keyboard ▸ Browser).
5. **Two new theme roles**, `tabTileViolet` and `tabTileOrange`, the same in both appearances (the boards' two
   brand hexes).
