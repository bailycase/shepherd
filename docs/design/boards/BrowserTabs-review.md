# Browser tabs design review

Spec: user boards 81 through 86, saved as BrowserTabsAgent, BrowserTabsElsewhere,
BrowserTabsFull, BrowserTabsOpened, BrowserTabsPopup and BrowserTabsTwo in this folder.
The checklist is [BrowserTabs-checklist.md](BrowserTabs-checklist.md).

## Comparison

The final matrix comes from real `BrowserSession` instances, local HTTP pages, WebKit titles,
`BrowserTabs` mutations and `BrowserAgentPresence`. It covers two tabs, eight tabs and the list,
agent-opened and popup notes, agent active here and elsewhere, long titles and a new empty tab.
Every state has light, dark and text scale 1.3 renders. Plain-value renders additionally exercise
non-loopback tile colors; they are not evidence of browser behavior.

| Element | Design and implementation | Result |
| --- | --- | --- |
| Strip below pane header | 38pt strip, 26pt tabs, 2pt gaps, 8pt horizontal padding, 6pt radius | Matches tokens and measured layout |
| Selected and inactive titles | Selected medium/primary/selected background; inactive regular/secondary; single-line truncation | Matches, including long text and scale 1.3 |
| Tile | 12pt colored letter tile; spinner replaces it while the agent acts | User approved site initials/colors instead of brand-specific examples |
| Close | Small outline `xmark`, selected/hovered or all tabs when at most four | User approved 24pt hit target instead of board's 20pt drawing |
| New and list buttons | Outline `plus` and `chevron.down`, disabled New at eight | Matches; Command-T follows the board tooltip and is rebindable |
| All-tabs list | 260pt menu, checkmark, title/address, Agent/Link tags, Close other tabs, count and sharing footer | Matches; eight rows fit and enlarged text wraps the footer |
| Opened note | Globe, real title, Show it, Dismiss | Matches; Show it selects the actual newly opened page |
| Popup/cap notes | Globe or warning triangle, actual model notice, Dismiss | Matches; ninth popup stays in the originating tab |
| Agent in selected tab | Ring and pointer over page, full-width bar above console, spinner and Take over | Matches board 81; removes the previous floating card |
| Agent elsewhere | Lower trailing chip, actual active page title, select on press | Matches board 82 without changing the agent's target |
| Existing browser chrome | Toolbar, address/host pill, viewport and selection controls, console | Preserved per selected page; root remote notice remains visible |
| Empty tab | Existing No page open state with address action | Additional state, consistent with existing Browser empty state |

Measurements use the saved board HTML and `NWBrowserTabsMetrics`; production values use shared
ShepherdUI tokens. The glyph/IPv6/doc findings from this review were fixed before final validation.
Tab close and notice dismiss share a single close-glyph component. No new dependency was added.

## Controls and accessibility

`BrowserTabsControlTests` presses the component states with `ControlPress`, checks callback values,
disabled controls and desktop hit targets. `BrowserPaneTabsTests` presses the real pane and verifies
its selected page, tab membership, last-tab replacement, cap, opened/popup notices, agent bar and
chip, takeover, root notice and address-field state. Its keybinding scenario exercises the installed
BrowserKeys handler without posting an event. Windows remain off-screen.

Icon-only controls have labels, tab selection has a selected trait, unseen/active states have spoken
labels, and transitions use existing reduced-motion-aware animation tokens. Keybindings tests cover
Command-T scope, rebinding/conflicts and terminal pass-through. DesignRulesTests and theme/token
suites check the new components and color roles.

## Limits of verification

Off-screen captures draw WebKit page content blank. They verify native chrome, not the rendered
website's visual content. Real WebKit integration tests exercise page DOM, history, cookies,
popups and per-tab isolation separately. No interactive Dev app launch was performed: validation
must not focus a window or touch a running Shepherd. The Dev scheme was built with pinned package
versions. A real second-Mac browser claim was not manually exercised; existing remote suites and
the added host-capability/privacy regressions exercise the request boundaries.

The user approved the site tile and 24pt close hit target departures. New violet and orange palette
roles reproduce the boards' colors; Command-T and the full-width agent bar are specified by the
boards, not additional design departures.
