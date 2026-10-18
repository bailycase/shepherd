# Side pane: Browser

> Read when you change the Browser tab or how an agent drives it.

**Browser** (PaneBrowser, PaneStates › Browser; `BrowserPane.swift`, the page in
`BrowserHost.swift` (the only app file that imports WebKit), its rules in `BrowserModel.swift`, the
page's scripts in `BrowserScripts.swift`; parts in ShepherdUI `Components/Browser/Browser.swift`):
a thread's own web page, beside it. The Browser tab (`globe`, ⌃2) follows Changes (Artifacts, ⌃3, and Subagents, ⌃4, follow it). A remote thread
has it too, when its host carries Browser tunnels (Remote threads, below); an older host shows
Changes alone.

- **One page per thread, saved data per project:** a WebKit view made the first time the thread
  opens something. Threads in the same project, including its worktrees, share an identified
  persistent website data store (`WKWebsiteDataStore(forIdentifier:)`) for cookies, local storage
  and cache. Each keeps its own page, history, session storage and agent controls. Project identity
  is its stable space ID, not its name or checkout path. Saved data survives Shepherd restarts and
  deletion of the project's last thread; removing the project removes its store. The bundled app
  persists on macOS 26 too. Only macOS 26's bundle-less test runner retains the temporary-store
  crash workaround (`BrowserHost.swift`). Older per-thread stores are not merged into the shared
  store; sign in once per project. Websites still control cookie expiry and logout.
  The view belongs to the thread, not the pane: hiding the pane, another tab, another thread on
  screen or a parked layout only take it out of the window (the visibility-flip rule), so the page
  never reloads. A remote thread's page is made here too, in a store keyed on its host and project,
  separate from every local project and other host. A disconnect keeps its data; removing its
  project or configured host removes it. Automation runs use the project holding their folder;
  threads outside a project retain isolated data. Every agent in a project can use its logins.
- **Toolbar** (`NWBrowserToolbar`), 44pt, 8pt side padding, a hairline beneath: Back, Forward and
  Reload (28pt `nwIcon`; one that can't act is at 40%; Reload is Stop loading, an ×, while the page
  loads), 6pt, the address field, 6pt, then Select an element, Viewport size and Open in your
  browser (28pt `nwIcon`). Select an element, while on, is `lanternTint` with a `lanternText`
  glyph; the Viewport button is `bgSelected` while its menu is open. Open in your browser hands
  the URL to the default browser.
- **Address field** (`NWBrowserAddressField`): a 30pt capsule on `bgSunken` with a `lineSubtle`
  line: a 12pt `textTertiary` globe, the URL in Geist Mono 12 (the host with its port in
  `textPrimary`, the path, query and fragment in `textSecondary`; the scheme left out for http and
  https, a lone "/" left out), truncating, and a 20pt capsule host chip on `bgRaised` with a
  `lineSubtle` line (a 10pt display glyph, "This Mac" in Geist 11 `textSecondary`; a remote thread's
  page at a `localhost`, `127.0.0.1` or `[::1]` address, or nothing open, says the host's name,
  "build-01"). Empty, it reads "Search or enter a URL" in `textTertiary`. ⌘L or a click edits the whole URL; ↩ opens, Esc
  gives up. It takes a URL with a scheme; a host with a port or a path (loopback, a private IPv4
  address, `.local`, `.test` and `.localhost` names go over http, others over https); ":5173" for a
  port on this Mac; anything else is a search (Google).
- **Nothing open** (`NWBrowserEmpty`): centered, 14pt apart: a 44pt `bgSelected` circle with a
  20pt `textSecondary` globe, "No page open" (Geist 14 semibold), and a line (`ui` `textSecondary`,
  at most 330pt, centered), the board's words exactly: "The agent opens pages here when it starts
  a dev server. Ports on remote hosts are forwarded for you." ("Waiting for localhost:5173 to
  answer. Its page opens here when it does." after Start). Then, at most 400pt wide and 8pt apart,
  a card per dev server (`NWDevServerCard`: `bgRaised`, `lineSubtle`, radius 8, padding 10×12; a
  12pt terminal glyph, "pnpm dev" in Geist Mono 12 over "from package.json · acme-web" in Geist 11
  `textTertiary`, and "Start on This Mac", secondary `s` with a play glyph ("Start on build-01"
  on a remote thread), and an "Open a URL" row the same way with the ⌘L keycaps.
  - **Dev servers** (`DevServerDiscovery`): the `dev`, `start`, `serve` and `preview` scripts, in
    that order, of the thread's folder's package.json and then each `apps/*/package.json` (at most
    six), read off the main thread. The command follows the lockfile beside it, else the
    repository's: pnpm, yarn or bun (`bun run`), else npm (`npm run dev`, `npm start`). A remote
    thread's are read on its host, in the thread's folder there (`RemoteAgentQuery.devServers`).
  - **Start** runs the command in a new terminal of the thread's layout, the same path an
    agent's `terminal_open` takes (`PaneControl`), so the terminal panel opens on it. When the script's
    port is known (its `--port`, `-p` or `PORT=`, else its tool's default: Vite 5173 and its
    preview 4173, Next, Nuxt, Remix and create-react-app 3000, Astro 4321, Angular 4200,
    Storybook 6006, webpack 8080, …), the page opens by itself once that port answers, tried every
    half second for 90 seconds. On a remote thread the command runs in a new terminal on the
    host (`RemoteAgentAction.openTerminal`), in the folder the script was found in, and the port is
    forwarded here and tried through the tunnel.
- **Viewport** (`NWViewportMenu`, a 220pt popover 4pt under the toolbar, its trailing edge under
  the button): Fit the pane (the default), iPhone 16 · 393, iPad mini · 744, Laptop · 1280 (the
  check leading, widths trailing in Geist Mono 11 `textTertiary`), a divider, and Dark appearance
  (the page's `prefers-color-scheme`; off is light, whatever Shepherd's appearance). A chosen width
  centers the page on `bgSunken` in a frame 14pt in from the pane's sides and top, with 14pt top
  corners and a `lineStrong` line. A width wider than that room lays the page out at the chosen
  width and shrinks it to fit (the page's zoom), so its media queries see the width. The selection
  and the console keep working. A click outside or Esc closes the menu.
- **Selecting an element** (⇧⌘C, or the button): the element under the pointer takes a 2pt
  `running` outline (radius 10, 4pt outside it, a `runningTint` fill) with a 20pt `running` tag
  above it (below it at the page's top): its label and size ("button.pay 240 × 44", Geist Mono
  10.5, the size at 75%, the text in `textOnRunning`). Shepherd's script draws them inside the page,
  in a closed shadow root, in the theme's colors. While selecting, the page's clicks and presses go
  to the picker, and Esc stops. A click picks: selecting ends, the outline stays, and a popover
  (`NWElementPopover`: 188pt, padding 8, radius 12, the popover's fill and shadow) sits beside the
  element (to its right, else its left, else under it, inside the page), following it as the page
  scrolls: the source location ("Checkout.tsx:88", Geist Mono 10.5 `textTertiary`, the file and
  line only) when the page provides one, Add to message (primary `s`) and Copy selector (ghost
  `s`). A click elsewhere or Esc dismisses it, and a new document drops it.
  - **The source** comes from a `data-source` attribute, react-dev-inspector's
    `data-inspector-relative-path` and `data-inspector-line`, or a React dev build's fiber
    (`_debugSource`, React 18 and earlier), the nearest one up the tree; otherwise the line is
    hidden, and the chip shows the label alone (the user's decision, 2026-09-29).
  - **The selector** is the shortest unique path: an id when it is unique, else the tag with up to
    two stable classes (and `:nth-of-type` where siblings need it), walking up until it finds one
    element. The label is the tag with its id or first stable class ("button.pay", "input#promo").
  - **Scripts:** the picker and the network count run in a content world of Shepherd's own,
    which the page can't see or call, and post to a handler only that world has. Only the page's
    own world can read what its `console` says and a React fiber, so a small shim runs there: it
    wraps `console`, reports errors to a console-only handler, and answers the picker's source
    question through a DOM attribute it takes off again. A page can at most forge a console line.
- **Add to message** puts the element in the thread's composer as a chip (Composer, questions,
  and menus › The element chip), at most five (the same element picked again replaces its chip). It goes to pi with the
  message: the host fences each element ahead of the words as data, never instructions (its page's
  URL, the selector and label, the source when known, its size, and the start of its outer HTML,
  cut at 1,500 bytes), and a message carrying elements goes to pi on its own, never joined in the
  queue. No board draws a sent message's elements as a chip, so the sent bubble shows only its
  words (the user's decision, 2026-09-29): elements sent alone send "1 page element attached.",
  which the bubble still shows as its text, with nothing standing in for the element.
- **Console drawer** (`NWConsoleBar`, `NWConsoleRow`), under the page while one is open: a 32pt bar
  on `bgBase` under a `lineStrong` line: "Console" (Geist 12 semibold), "Network" with its count
  (the document and each resource it loaded; Geist Mono 10.5 `textTertiary`), and "1 warning" in
  `lanternText` (Geist 11.5, a 12pt glyph, only when there is one). No board draws a separate
  error count or red rows (the user's decision, 2026-09-29): the page's own errors show as warning
  rows and count in "N warning(s)" too. Hide console (24pt; Show console, a chevron up, while
  hidden) collapses the rows and leaves the bar; the ⋯ menu offers nothing of its own for it. Its
  rows, a lazy list 136pt tall that opens at its newest line, are at least 22pt with 14pt side
  padding in Geist Mono 11: the time (24-hour) in `textTertiary`, the message in `textSecondary`,
  truncating (the whole line is its tooltip). A warning row (an error included) is `lanternTint`
  with its text in `lanternText`. It keeps the last 500 lines, and a new document starts it over,
  counts included.
- **Keys:** ⌃2 shows the tab (fixed). ⌘L (the address field) and ⇧⌘C (Select an element) go
  through `KeybindingsStore`, scoped to the Browser while it is on screen, whatever has the
  keyboard in the window; both are in `appOwnedChords`, so a focused terminal lets them through.
  The design canvas's ⇧⌘C (Copy reference) never meets this one: a design's layout has no Browser.
- **The tab's dot** ("Agent opened a page in Browser" under the header's button) is for pages pi
  opens (`browser_open`). Nothing opens the pane by itself: the Browser tab takes a 6pt `running`
  dot and, with the pane closed or on another tab, the header's side-pane button takes its 8pt
  one, each with a brief tip under it for four seconds (and again while hovered). The button's is
  the sentence, "Agent opened a page in Browser", with the pane's chord. The tab's
  (`NWPaneTabTip`, PaneStates › SidePaneTabs · the agent opened a tab) hangs under the tab, 300pt
  wide, a popover with padding 4: a row of 4×6 with a 12pt `textSecondary` globe, "Agent opened"
  and the page in Geist Mono 12 (`localhost:5173/checkout`, the host, port, path and query as the
  address field shows them), and its age in `textTertiary` ("10s", "2m", "1h", counting up). It
  moves left when the strip is too narrow for it. On a remote thread whose host offers
  `browser.drive.v1` the same dot and tip mark the viewer's tab for a page the agent opened in the
  host's own browser (no Mac owned it), and for one it opened through this Mac's claim while the tab
  was out of sight.
- **Remote threads** (docs/browser.md › Remote): the tab shows when the host lists
  `browser.tunnel.v1`. The page is a web view on this Mac whose URL stays `localhost:5173/checkout`;
  its traffic to the host's loopback ports goes to the host through the authenticated connection
  (WebKit sends loopback past every proxy, so this Mac listens on the port itself). Everything on
  the local tab works as it does there: the picker, the console drawer, the viewport, Add to message
  and the composer's chip, ⌃2, ⌘L and ⇧⌘C. A port on this Mac has one owner: a port another program
  listens on, one below 1024 or one another thread's page holds is refused, nothing loads, and a
  notice card (`NWBrowserNotice`: a 12pt `lanternText` glyph, the reason in `ui`, a close button;
  `bgRaised`, radius 12, a `lantern` line, 12pt from the pane's sides) says why. A port a page names is
  held until the thread or its host goes away. **The agent drives this page**, on a host that offers
  `browser.drive.v1` (the agent is using it, below): the tab on screen claims the agent's browser on the
  host, and the agent's tools run on this Mac's page, with the ring, the pointer, the bar and Take
  over; the claim is let go 30 seconds after the tab is out of sight, and another Mac that claims the
  browser takes it (this tab's notice card says so, and showing the tab again takes it back). A tab
  with nothing open opens the page the agent left on the host (cookies are not carried over), and a
  page the agent opens on the host while no Mac owns its browser marks the Browser tab with the dot
  and its tip, like a local thread's, never opening the pane by itself. A host's agent may open only
  that host's own loopback ports and public addresses here, never this Mac's network (docs/browser.md
  › Remote). On an older host the agent drives the host's own page, which this tab does not show, and
  the dot and the tip stay off (a review pi opens on a host is likewise the host's view state).
- **Tabs** (BrowserTabsAgent, -Elsewhere, -Full, -Opened, -Popup, -Two, saved in `docs/design/boards/`;
  `NWBrowserTabStrip`, `NWBrowserTabMenu`, `NWBrowserTabsNote`, `NWAgentBar`, `NWAgentElsewhere` in ShepherdUI
  `Components/Browser/BrowserTabs.swift`; checklist in `docs/design/boards/BrowserTabs-checklist.md`; the pane
  is `BrowserPane.swift` over `BrowserTabs`: the strip, the list, the toolbar, the page and the console are
  `tabs.selectedPage`; the remote claim is the root's). ⌘T (`browserNewTab`, scoped to the Browser, in
  `appOwnedChords`) opens a tab and focuses its address field.
  - **Tile:** a 12pt tile with the first letter of the page's site name (the label before its public suffix:
    "stripe" for docs.stripe.com, "localhost" for localhost, "·" for no page). Loopback is `running`; every
    other site gets `done`, `tabTileViolet` (#635bff) or `tabTileOrange` (#f46800) by a fixed hash of its site
    name, so a site keeps its color. The boards color by brand and letter by the page's own name ("A" for Acme
    payments). The user approved site initials and stable themed colors rather than adding icon fetching.
  - **Strip:** 38pt under the pane's tabs, 8pt side padding, a hairline beneath. Tabs are 26pt, radius 6, 2pt apart,
    64 to 200pt wide: a 12pt tile with the page's first letter (radius 4, Geist 8 semibold, a theme role chosen
    from the host, not the site's brand color), the title in `ui` (selected: `textPrimary`, medium, `bgSelected`;
    others `textSecondary`; hover `bgHover`), and a close `xmark` (10pt, 24pt hit) on the selected tab, on hover,
    and on every tab while there are four or fewer. Then New tab (`plus`) and All tabs (`chevron.down`), 24pt
    `nwIcon`. New tab is disabled at the cap, with the tooltip "This thread has the most tabs it keeps". The tab
    the agent is using swaps its tile for a 12pt spinner; a page the agent opened and nobody has looked at has a
    6pt `running` dot after its title (VoiceOver: "Refund overview, new"). The tooltip is the address, then
    "opened by the agent" or "opened by a link".
  - **List** (All tabs, 260pt popover, 12pt from the pane's side, 4pt under the strip): a row per tab with a check
    leading, the title in `ui` over the address in mono 10.5 `textTertiary`, and "Agent" or "Link" trailing; a
    divider; "Close other tabs" (disabled with one tab); and "N of 8 tabs · sign-ins shared across the space" in
    mono 10.5. Rows keep their height; the list scrolls past 420pt.
  - **Note** under the strip (`bgSunken`, hairline beneath, 12pt sides): a 13pt glyph, the words in `caption`, an
    optional action and Dismiss. "The agent opened <title> in a new tab." with **Show it** (`globe`), "A link
    opened a new window. Shepherd opened it as a tab." (`globe`), and "This thread has 8 tabs, the most it keeps.
    New links open in this tab." (`exclamationmark.triangle`).
  - **Agent bar:** while the agent uses the shown page, a 32pt bar over the console (`runningTint`, a hairline
    above, an 11pt spinner, "Agent is filling the checkout form", Take over) replaces the floating card the
    earlier board drew under the toolbar (see "The agent is using it", below); the ring and pointer stay. While the agent works in a tab
    that is not shown, "Agent is in Checkout" (secondary `s`, a spinner) sits over the page's lower trailing
    corner and shows that tab when pressed. The thread's own notice (another Mac took the agent's browser) stays
    in view on whichever tab is shown.
- **Not built yet:** Throttle to 3G (see the departures), and Split below and the pane's own window
  (below).
- **The agent is using it** (`NWAgentRing`, `NWAgentPointer`, `NWBrowserAgentOverlay` in ShepherdUI
  `Components/Browser/BrowserAgent.swift`, and `NWAgentBar` in `BrowserTabs.swift`; BrowserTabsAgent, the
  board that replaced PaneStates › BrowserPane · the agent is
  using it; docs/browser.md): the agent drives the same page you see, through its `browser_*` tools
  (on its own thread's page; on a remote thread, the page this Mac shows, through a claim). While a tool runs, and for four seconds after the
  last (a run of tools keeps it up), the pane draws over and under the page, natively and never in it:
  - a 2pt `running` ring inset the page area (above the console drawer, below the toolbar), and
    an 18pt `running` pointer glyph (the board's arrow, a white edge) at the last click's or
    typing's target, following the page's zoom;
  - a full-width bar under the page and above the console drawer, 32pt (`NWAgentBar`: `runningTint`, a
    hairline above, 12pt leading and 6pt trailing padding, 8pt between): an 11pt `running` spinner, "Agent
    is filling the checkout form" (`caption`, one line, truncating) and **Take over** (secondary `s`, with
    a hand glyph). It is the page's own: it shows only while the tab on screen is the one the agent is using;
    while the agent works in another tab, "Agent is in Checkout" (`NWAgentElsewhere`) sits over the page's
    lower trailing corner and shows that tab when pressed. The ring and pointer take no clicks.
  - The words are the tool's optional `note` ("clicking through checkout"), else derived from the
    action and its target: `clicking “Pay $148.00”`, `double-clicking …`, `typing in “Email”`,
    `pressing Enter`, `scrolling down`, `opening localhost:5173`, `reading the page`, `waiting for
    “Order placed”`, `taking a screenshot`, `running a script`, `going back`. Every tool shows the
    bar (the board draws one phrase only); a note is cut at 60 characters.
  - **Take over:** the bar's button, or the user's own click or key in the page while the bar is
    up (a trusted event: the agent's dispatched events are not). The ring, pointer and bar go, and
    the agent's clicks, typing, keys, scrolling, navigation and scripts are refused
    (`taken_over`, "The user took over the browser. Wait for their next message before acting on
    it; browser_read, browser_screenshot and browser_console still work.") until the user sends
    that thread another message; reading, waiting, screenshots and the console still work and
    show no bar. Only the bar's button takes clicks: the ring and pointer let the page have them.
  - The page keeps running when nothing shows it (a hidden pane, another tab or thread): it moves
    into an off-screen window and never reloads.
- **In the thread**, pi's browser work reads as activity lines with the globe (NWActivityLine
  `.browser`): "Opened localhost:5173/checkout in Browser", "Read the page", "Clicked “Pay
  $148.00”", "Typed in “Email”" (never what was typed), "Pressed Enter", "Scrolled down",
  "Waited for “Order placed”", "Took a screenshot", "Read the console", "Ran a script in the page",
  "Went back", "Reloaded the page". A failed call is "Browser click failed" with the reason, a
  stopped one "Browser click stopped", and consecutive calls of one tool are one line ("Clicked 3
  elements", "Read the page 4 times"). A screenshot's image is not drawn in the thread, as an MCP
  tool's images are not (the result's text says what it took). "Started the dev server · pnpm dev ·
  :5173 on build-01" is still to come.
