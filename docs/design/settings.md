# Settings

> Read when you change a Settings page other than Pi, Instructions, Skills, MCP servers and Experiments.

Settings replaces the window content in place (`SettingsView.swift`; the boards SettingsAppearance
through SettingsExperiments). ⌘, toggles it, and "Back to Shepherd" or Esc returns; the swap
cross-fades on the `sheet` motion, and a page picked in the nav cross-fades on `content`. Every row
is wired: a row exists only if changing it changes the app, and a change applies at once, with no
Save or Apply (the one exception is Instructions, which edits files and saves with ⌘S).

- **Navigation** (the same on every Settings board): a 232pt column on `bgBase` with a `lineSubtle`
  hairline (`NWHairline`) on its trailing edge, its contents 10pt in from either side
  (`NWSettingsNavMetrics.sidePadding`). Top to bottom:
  - the 44pt strip for the window controls: it drags the window and holds nothing else
  - **Back to Shepherd**: `chevron.left` in a 10pt column, then 8pt after it the words in Geist 13,
    `textSecondary`, in a 30pt row 8pt in (Esc does the same)
  - the search field (`NWSearchField` at the Settings scale: 34pt, radius 8, 10pt in, Geist 13,
    "Search settings", a plain mono 11 "⌘F" in `textTertiary` trailing while it is empty), 10pt
    under Back and `NW.Space.l` above the pages; it takes focus when Settings opens, so typing
    filters at once
  - the pages, one `NWSettingsNavRow` each, `NW.Space.xxs` apart, in this order: Appearance
    (`circle.lefthalf.filled`) · Terminal (`terminal`) · Agents (`person.2`) · Worktrees
    (`arrow.branch`) · Pi (`pi`), with its three pages under it, Sign-in, From your pi and Slash commands (SettingsPi:
    rows 28pt × density, 35pt in, Geist 12.5 `textSecondary`, the selected one `textPrimary` at 500
    on `bgSelected`; Sign-in carries a 6pt `lantern` dot trailing while a provider an agent of
    this Mac needs isn't signed in or a sign-in expired) · Instructions (`doc.text`) · Skills (`graduationcap`) · MCP servers
    (`server.rack`) · Remote
    (`dot.radiowaves.left.and.right`) · Keyboard (`keyboard`) · Advanced (`gearshape`) ·
    Experiments (`flask`). A row is 32pt × density (`NW.Height.scaled(32)`), radius `s`, 10pt in:
    a 13pt symbol in a 15pt box in `textSecondary` (`textPrimary` when selected), then, 10pt after
    it, the name in Geist 13 `textPrimary`. The selected page sits on `bgSelected` with its name at
    medium (500) weight; hover is `bgHover` (`NWSettingsNavMetrics`).
  - "Shepherd x.y.z · agent x.y.z" pinned at the bottom in mono `micro`, `textTertiary`, aligned with
    the rows' icons: the app's own name, so "Shepherd Nightly …" there.
- **Search:** typing narrows the nav to pages with a match (a row's title, or a keyword such as
  "dark" for Mode or "tailscale" for Hosts) and lists the matching rows as buttons under their page
  (`caption`, `textSecondary`, indented past the icon); clicking one opens its page. When the page
  on screen has no match, the first page that does opens at once (no cross-fade per keystroke). With
  nothing matching, the nav says "No matching settings" in `caption`/`textTertiary`.
- **Content** (every page but Instructions, Skills, MCP servers and Experiments): the page on `bgWindow`, a 720pt column
  centered in it, 44pt from the top, 48pt from the sides and the bottom; the page scrolls, and the
  strip at its top still drags the window. Top to bottom:
  - the header: the page's name in Geist 22/600, tracked −1% (`Font.nwSans(22, .semibold)`,
    `textPrimary`, a header for VoiceOver), and `NW.Space.xs` under it one line in
    Geist 13.5/1.5 `textSecondary` that says what the page is for
  - groups, 28pt apart (from the header too). A group is a section label (`NWSectionHeader` with
    `style: .settings`: `nwSettingsLabel()`, Geist 11/600 caps tracked 6% in `textSecondary`,
    `NW.Space.xs` in from the card's edge), `NW.Space.m` above an `NWGroupCard`, and an optional
    footnote `NW.Space.m` under the card, `NW.Space.xs` in. The card is radius 10
    (`NWCardRowMetrics.settingsCardRadius`) with a 1px `lineSubtle` line, filled `bgWindow` like the
    page it sits on: flat, drawn by its line alone. `NWHairline`s separate its rows.
  - a row (`NWCardRow` with `style: .settings`, through `SettingsRow`): its content at least 52pt ×
    density, 10pt above and below it (`NWCardRowFrame`; so 72pt at the least, as the canvas renders
    the boards' rows) and `NW.Space.xl` at the sides, the text and the control
    `NW.Space.xxl` apart. The title in Geist 13.5/500 (`Font.nw(.body, weight: .medium)`,
    `textPrimary`), `NW.Space.xxs` over its description in Geist 12.5/1.45 (`textSecondary`). A row
    may have no description (Sidebar width, Port, Thinking). The control trails, centered on the
    row. The card row's default style is the compact one sheets and the phone's forms use.
  - inside a description, a flag, file or tool name is inline code: mono 11.5 on `bgSunken`, radius
    `xs`, `NW.Space.xs` side padding and no line, lighter than the standalone `NWInlineCode`
    ("passes no `--model` at all", "with `review_diff`", "Needs pi 0.85.1+"). Where a
    description explains the options, their names are set at medium (500) weight, a step brighter
    than the text around them (`textPrimary`; the board's #c1c5cb is off the palette): "**Remote
    default** starts clean…". Descriptions and page explanations are written with that markup
    (`` `code` ``, `**name**`) and drawn by `NWMarkupText`, which parses each string once and pads
    the code's fill by kerning the characters around it. Code breaks only at its spaces, never
    after a hyphen (`--model` stays whole).
  - rows without a title (a form's Add host, pi's version and update buttons, a remote host) are
    `SettingsActionRow`s: the same padding and minimum height, their own content leading, actions
    trailing `NW.Space.s` apart.
  - The building blocks are in `SettingsComponents.swift`: `SettingsPage`, `SettingsGroup`,
    `SettingsRow`, `SettingsActionRow`, `SettingsNote`, `SettingsSwitch`, `SettingsTextField`,
    `PathRow`. A page composes these and the shared components; a part only one page has (the font
    preview, the shortcut recorder, a remote host's row) is built from the same tokens.
- **Controls** are the shared components at the Settings boards' sizes: `SettingsPage` and
  `SettingsGroup` set `.nwControlScale(.settings)`, and every Night Watch control inside takes the
  size these boards draw (`NWSettingsControlMetrics`), nothing hand-drawn per page:
  - `NWSegmentedPicker`: 26pt segments 12pt in, 2pt apart, on a `lineSubtle` track 3pt in at
    radius 8; the chosen one on `bgWindow` at radius 6 with the knob's small shadow, in semibold
    `textPrimary`, the others 500 `textSecondary`. Advanced's Update channel alone keeps the
    Controls board's control, as SettingsAdvanced draws it (`.nwControlScale(.standard)`).
  - `NWPopupMenu` for longer lists: 32pt at radius 7 on `bgRaised` with a `lineStrong` line, sized
    to its value (12pt before it, up-down chevrons in `textTertiary` 10pt after); the value in mono
    when it is an id (a model, a shell path), in Geist 13 when it is a word ("Use the agent’s
    default · …", "Inherit parent", "System font"); a fallback, where there is one, comes first,
    then a divider, then the choices
  - the lantern switch (`SettingsSwitch`, `.nwSwitch`, 30×18) for booleans; the row's title is its
    accessibility label
  - `NWStepper` for a small count (30pt at radius 7: 30pt buttons around a 34pt mono 13 value,
    `lineSubtle` rules between), and `NWValueSlider` for a range: a 180 × 4 `lineSubtle` track
    filled with lantern to an 18pt knob in a 1px `lineStrong` line, centered on the value, and the
    value 12pt after it in mono 12 (44pt, right-aligned) with its unit ("105%", "239 pt");
    double-clicking the value returns it to its neutral value, and only that reset animates
  - `SettingsTextField`: 240pt fields (a port 100pt), 30pt at radius 7, 10pt in, 12.5 whether mono
    or not, labelled for VoiceOver, with an example as the prompt; mono for addresses, ports, and
    tokens; a token is a secure field
  - `NWKeycap`s for shortcuts, one 22pt cap per key (at least 22 wide, radius 5, mono 11.5 in
    `textPrimary`, 4pt apart: ⇧ ⌘ N)
  - buttons, whatever their size: 32pt at radius 7, 12pt in, Geist 13/500 on `bgWindow` with a
    `lineStrong` line: `.secondary` for actions (Reveal, Check now, Edit), `.danger` for one that
    removes or resets (Remove, Reset…), `.ghost` for Cancel, `.nwLink` for a text action inside a
    row (a shortcut's Reset, Geist 12, 6pt either side)
- **Footnotes and problems:** a footnote is Geist 12/1.5 (`nwText(size:lineHeight:)`) in
  `textTertiary`: a sentence or two about the whole group, never a mono paragraph. An inline problem
  (the listener's bind error) sits in its row, `NW.Space.xs` under the description
  (`NWInlineProblem`): an `xmark` glyph (12pt, `failed`), then, `NW.Space.s` after it, one sentence
  in the description's size in `failed` that says what happened in plain words ("Couldn't start:
  port 7433 is already in use."). It discloses, and the card grows with it (`disclosure`). Never
  show an errno or a raw error as the message; the technical reason is the line's tooltip
  (`RemoteListenerFailure` words the listener's).
- **Status inside a row** is its word in the state's text color: a remote host's connection (the
  word alone, as SettingsRemote draws it), pi's update status (led by a 6pt `NWStatusDot`, as
  SettingsPi draws it). A failed remote host adds what happened
  and what to do as its problem ("studio refused the token. Edit the host to paste its current
  token."), with the client's technical reason only as that line's tooltip.
- **Never in `body`:** the installed font families are enumerated once per launch
  (`TerminalFontCatalog`), and pi's config and model catalog load in a task.

The pages, in nav order. Each names its board; the strings in quotes are the boards' copy.

## Appearance (SettingsAppearance)

"How Shepherd looks. The terminal has its own font settings."

- **Theme:** Mode, "System follows your Mac and switches with it.": System · Light · Dark, default
  System (`ThemeManager`; the Appearance menu sets the same thing). Above it the app adds a Theme
  row, "Night Watch ships with Shepherd, in light and dark.", naming the theme in
  `ui`/`textSecondary`: a name, not a popup, while one theme ships.
- **Sidebar** (SettingsAppearance, SettingsAppearanceProjects):
  - Organize by, "What the sidebar lists under New thread and the destinations. Also in View ▸
    Organize Sidebar By.", its control under the words (12pt above, 16 around): two cards
    (`NWSidebarStylePicker`), Activity ("Needs you, then Recents: every kind, newest first.") and
    Projects ("A folder for each project with its threads inside."), each a 104pt drawing of the
    sidebar it makes (its rows shrink together to fit the height, as the board's column does) over
    a radio, its name in Geist 13 semibold and the line in 12
    `textSecondary`, on `bgSunken` at radius 10 with a 1pt `lineSubtle` ring, 1.5pt `lantern` when
    chosen, 12pt apart. `AppSettings.sidebarStyle`, default Activity.
  - For Projects only: Group by host, "A section for each Mac or server, its projects inside. Off
    shows the host as a tag on the row." (a switch, off), and Keep idle threads, "Then they leave
    the sidebar; ⌘K still finds them. Running threads and anything waiting on you stay." (a popup:
    1, 3, 7, 14 or 30 days, or Forever; 7 days). Reset settings returns all three.
- **Layout** (see Density and row settings):
  - Sidebar rows, "Compact 22 · Standard 28 · Comfortable 36 pt, for the sidebar and menus.":
    Compact · Standard · Comfortable.
  - Density, "Row heights across the sidebar and chrome. Lower fits more agents.": a slider, 80–150%
    in 5% steps, neutral 100%.
  - Text size, "App chrome only.": a slider, 85–130% in 5% steps, neutral 100%.
  - Sidebar width, no description: a slider in points ("239 pt"), 190–340, neutral 232. Dragging the
    sidebar's edge moves it too.

## Terminal

No board draws this page; the nav lists it. "Terminals under a thread: their font and which
shell they run."

- **Font** (footnote "Font changes apply to open terminals in place; running processes are
  untouched."): Font family, "Fixed-pitch families installed on this Mac. Ghostty falls back if a
  family can't be loaded.", a popup with System font, a divider, then the installed families (a
  configured family that is missing stays listed); Font size, a slider in points ("12.5 pt"), 9–24
  in 0.5pt steps; Preview, "Updates as you change the family and size.", a 320pt card on `bgWindow`
  (radius `s`) with four shell lines in the chosen font and the theme's terminal colors.
- **Shell** (footnote "A new shell applies to terminals opened afterwards."): Shell, "Used by ⌘D
  and the terminals an agent opens." (the chord read from `KeybindingsStore`), a popup of known shells
  by path, in mono.

## Agents (SettingsAgents, with QueueStates' settings card)

"Defaults for agents you create with ⌘N or the New Agent sheet. Existing agents keep their
settings." The chord is read from `KeybindingsStore`, so a rebind never leaves the copy wrong.

- **New agents:**
  - Default model, "Preselected in the New Agent sheet. “Use the agent’s default” passes no `--model` at
    all.": a popup whose first item is "Use the agent’s default · <pi's own default model>", then a divider
    and the catalog's model ids. The catalog and pi's default load in a task, never in `body`.
  - Default thinking level, "Can be changed per agent from the composer.": Off · Minimal · Low ·
    Medium · High · Extra high · Max, default Medium (pi uses the nearest level a model has).
  - Speed for new threads, "New threads start on this speed. Each thread keeps its own after
    that.": Standard · Fast, default Standard (ComposerSpeed, the same row and segmented control as
    the thinking level). A thread whose model offers no service tier ignores it; a thread a remote
    client or an automation starts on this Mac takes it too.
- **While the agent is working** (the queue's setting; QueueStates' Settings card still draws the
  retired Return row beside it):
  - There is no Return setting any more (the user's call, 2026-09-30): ↩ always queues and ⌘↩ is
    always Steer now, so the page has one row here. A value an earlier version stored for "Return
    while the agent is working" (`steer` or `queue`) is discarded at launch and means nothing. The
    keys are Settings ▸ Keyboard's, and searching "steer" or "queue" finds Keyboard's Shortcuts.
  - When a turn ends, send the queue, "All at once arrives as one turn, in the order you queued
    it.": One per turn · All at once, default All at once. It is the
    host's default for its agents; Up next's ••• menu sets one agent's own.
- **Context** (no board draws it; the user's decision, 2026-10-01, with the Context card's parts
  list; docs/context-budget.md). Both rows apply to agents started after a change; a running agent
  keeps what it started with and follows at its next launch.
  - Compact at, "How full an agent lets its context get before it compacts on its own, as a share
    of the model’s window. pi’s default leaves 16k tokens free, about 94% of a 272k window. New
    agents follow a change; running ones at their next launch.": a segmented control, pi’s
    default · 60% · 70% · 80% · 90%, default pi’s default. It is written into Shepherd's pi home as
    pi's per-model `compaction.modelOverrides` (`PiCompactionThreshold`), never `reserveTokens`
    for every model, since a share of one model's window is not a share of another's; a share never
    leaves less room than pi's own 16,384 tokens, and a reserve the user set for a model is left
    alone. The Context card's auto-compact mark reads the same file, so a share moves the mark.
    On the iPhone and iPad it is not offered (a host's Context card shows its mark).
  - Trim old tool output from the model’s context, "Clips one huge tool result in what the model is
    sent and, as the context fills, replaces the oldest tool output, file contents, reasoning and
    screenshots with a line saying what they were. The thread keeps all of it. New agents follow a
    change; running ones at their next launch.": a switch, default on (`AppSettings.trimToolOutput`).
    A client lists it among a host's Bundled extensions (`HostSettings.bundledExtensions` id
    `context`, changed with `bundledExtension`), so it is remote-changeable like the Pi switches.

## Worktrees (SettingsWorktrees)

"How new worktrees are created, and what Finalize does when an agent's work is done." Every
automated step of the worktree flows can be turned off here.

- **New worktrees:**
  - Base branch, "**Remote default** starts clean from origin's default branch. **Current branch**
    stacks on your checkout's in-progress work. The New Worktree sheet lets you override it.":
    Remote default · Current branch, default Remote default.
  - Fetch before creating, "Fetch the base branch first so “remote default” is the remote's latest,
    not a stale local ref.": a switch, on.
- **Finalize** (footnote "The remote branch is never deleted by Shepherd — merging the PR cleans it
  up on GitHub. Per-repo GitHub settings live in the Finalize sheet."), switches:
  - Commit remaining work, "Commits anything left in the worktree using the PR title. Off stops
    Finalize on a dirty worktree.": on.
  - Generate PR descriptions, "Drafts an editable description from the branch's commits and diff;
    falls back to commit subjects.": on. Its model is `SHEPHERD_PR_DESCRIPTION_MODEL`, not a row.
  - Delete local branch, "After the worktree is removed, once Finalize has verified everything is on
    the remote.": on.
  - Merge PR automatically, "Tries GitHub auto-merge, so branch protection and required checks still
    gate it. A PR that can't merge is left open.": off. While it is on, the app discloses a Merge
    method row under it, "Must be allowed by the repository's settings.": Squash · Merge · Rebase,
    default Squash.

## Remote (SettingsRemote)

"Connect to agents on other Macs over your VPN, or let other Macs connect to this one."

- **Hosts:** one row per host (`RemoteHostRow`, a `SettingsActionRow`): the name as its title; under
  it a line: the address in mono 12
  (`horizon.starlight.internal:7433`), then " · " and the connection's word in its state's text
  color, and " · 5 agents" while connected, in the description's Geist. The words: connected (done),
  connecting… (running), disconnected (idle), or a failure's headline in lower case (unreachable,
  token refused, update needed, no token, token locked; failed). A failed host adds its sentence
  under the line as the row's problem ("Shepherd isn't running on horizon, or it can't be reached.",
  "horizon refused the token. Edit the host to paste its current token.", "horizon runs a newer
  Shepherd. Update Shepherd here to connect."), with the client's reason as its tooltip. Actions:
  Edit and Reconnect (secondary), Remove (danger), each labelled with the host's name for VoiceOver.
  With no hosts the app shows one row, "No remote hosts", "Add a Mac running Shepherd below. Its
  agents appear in the sidebar under its name." Hosts arrive and leave on `list`.
- **Add host:** Name, "Shown as the sidebar section label." (prompt "mac mini"); Address,
  "VPN-reachable IP or hostname." (mono, "100.x.y.z"); Port, no description (mono, prompt "7433", or
  "7434" in Shepherd Nightly; digits only, so a pasted "7,433" never becomes another port); Token,
  "Contents of the host's remote-token file." (mono, secure, "paste token"); then an action row with
  Add host (secondary), disabled until all four are valid. Edit loads a host into the same form: the
  group is titled Edit host, and its action row reads Cancel (ghost) and Save.
- **Serve this Mac** (footnote "Remote sessions run on the host Mac; your VPN is the transport and
  the token keeps other devices out."):
  - Listener, "Let other Macs with your token connect to agents here.": a switch. While it is bound
    the description reads "Serving on port 7433. Other Macs with your token connect to agents here."
    A bind failure is the row's problem, "Couldn't start: port 7433 is already in use."
  - Token, "Paste this into the other Mac's Token field. To revoke every client, delete the file and
    turn the listener off and on." (the board: "Delete the file to revoke every client."; see the
    departures): a `PathRow` for `remote-token` with Reveal.
  - What a token opens, for the Browser: a connected client can ask this Mac to carry a connection
    to one of its own **loopback** ports (`127.0.0.1` or `::1`, never another address) for a thread
    it sees, so its page there reaches a dev server here (Side pane: Browser › Remote threads;
    docs/browser.md › Remote). It adds no privilege beyond what a token already grants (a client can
    type into this Mac's terminals), it is capped (64 tunnels per client, 256 in all) and closed when
    idle, and every one ends when the client disconnects. There is no switch for it yet.
  - What a token opens, the other way: a connected client that shows a thread's Browser tab can
    **own that agent's browser** on this Mac (`browser.drive.v1`): this Mac then hands the agent's
    browser tools to that client instead of its own page, and the client's answers become the tools'
    results. One client owns an agent's browser at a time (the last to claim), at most 32 agents per
    client, and it ends with the client's connection or 30 seconds after its tab is out of sight. It
    adds no privilege beyond what a token already grants (a client can already message the agent), and
    it lets this Mac's agent act on the client's web view, which the client confines to this Mac's
    own loopback ports and public addresses (docs/browser.md › Remote; SECURITY.md). There is no
    switch for it yet either.

## Keyboard (SettingsKeyboard)

"Click a shortcut to record a new one. Shortcuts must include ⌘."

- **A shortcut row:** the action's name as its title, in sentence case with "…" when it opens a
  sheet ("New agent with options…"), and its keycaps trailing. Clicking the keycaps records: they
  become "Press keys…" (`caption` in `running` on `runningTint`, a `running` hairline, radius `xs`),
  the next chord is proposed, and ⎋ cancels. A chord the rules reject (Keyboard) is refused with its
  reason as the row's problem. A changed shortcut shows Reset (`.nwLink`, Geist 12, 6pt either
  side) just before its keycaps, `NW.Space.xs` away. A change reaches every menu, keycap, and
  terminal surface at once.
- **Groups on the board:**
  - Agents: New agent in current checkout ⌘N · New agent with options… ⇧⌘T · New space… ⇧⌘N · Rename
    agent… ⌘R · Next agent · Previous agent · Command palette. The board shows Next agent, Previous
    agent, and Command palette rebound (⌘J, ⌘K, ⌘P) with Reset beside them; their defaults are ⌘↓,
    ⌘↑, and ⌘K.
  - Terminal (the board calls it Panes and draws Split vertically ⌘D · Split horizontally ⇧⌘D ·
    Close pane ⌘W · Focus next pane ⌥⌘→ · Focus previous pane ⌥⌘←; terminals are tabs only, so the
    app's group reads New terminal ⌘D · Close terminal ⌘W · Next terminal ⇧⌘] · Previous terminal
    ⇧⌘[, and a stored override of the removed Split horizontally is ignored; see the departures).
  - Fixed, not recordable: Select agent 1–9, "Sidebar order; hold ⌘ to see the numbers." (⌘ 1–9) ·
    Settings (⌘ ,) · Confirm / cancel in sheets (⏎ esc).
  - Under the last group, trailing: Reset all shortcuts, a secondary button, disabled while nothing
    is changed. An individual Reset checks for conflicts just like a new assignment. If another
    action now uses that default, the row shows the existing conflict message and keeps its chord.
- **Every rebindable action is listed**, in the menu bar's groups: the app adds Delete agent ⇧⌘W to
  Agents, a Thread group (Stop agent, Model picker, Previous turn, Next turn, Inspect subagent),
  While the agent is working (QueueStates' Keyboard card, in its order: ↩ and ⌘↩ named for what they do,
  "Queue it, the agent takes it when the turn ends" and "Send and steer now"; Edit the last queued message ↑;
  Move the focused message ⌥↑↓; Delete the focused message ⌫; Steer the focused message ⌘↩; Stop the
  agent Esc; only ⌘↩ records), a Window group (Show or hide the sidebar, the side pane), and Show or hide
  terminal ⌘J and Maximize or restore terminal ⇧⌘↩ in Terminal. Its Fixed group (agents ⌘1–9, the side
  pane's Changes ⌃1, Settings, sheets) has the footnote "Changes apply immediately, everywhere a
  shortcut is shown."

## Advanced (SettingsAdvanced)

"Files, resets and app updates. Quitting Shepherd stops every agent."

- **Files:** Workspace state, "Spaces, agents and terminals restored on relaunch.", and Extension
  socket, "Where each agent process reports status and terminal requests.": `PathRow`s, the file's name in
  mono `textSecondary` (`state.json`, `shepherd.sock`; the full path as its tooltip) and Reveal,
  which selects it in Finder.
- **Updates:** Check for updates automatically, a switch; Update channel, "Stable: tagged releases.
  Beta: pre-releases, plus newer stable builds. Nightly builds are a separate app, Shepherd
  Nightly.": Stable · Beta. Shepherd Nightly names its one channel instead ("Nightly", in
  `ui`/`textSecondary`), "Every push to the integration branch, least tested. Tagged releases ship
  as Shepherd." Last, "Version 0.1.0 (1)" (the short version and the build) with Check for updates.
  Debug builds have no updater: the group holds only the version row, with no button, and Sparkle's
  rows disclose once it reports it can update.
- **Reset:** Reset settings, "Restores appearance, terminal, agent, worktree, extension and keyboard
  preferences. Spaces, agents, layouts and Remote are untouched." (the board: "Restores appearance,
  font, agent and keyboard preferences. Spaces, agents and layouts are untouched."; see the
  departures): Reset… (danger) opens `ResetSettingsDialog` ("Reset settings to defaults?", "Your
  spaces, agents and terminals are not affected.", Cancel and a destructive Reset). Remote's
  hosts and its listener stay as they are (`AppSettings.Key.resettable`).

## Wide pages: Instructions, Skills, MCP servers and Experiments

These four pages are wider than the 720pt column (`SettingsSection.isWide`): the page fills the detail area on `bgWindow`, 44pt from the top, 40pt at the sides, 32pt at
the bottom, with its blocks 20pt apart (`AppLayout.settingsWide*`). It doesn't scroll as a whole:
its editor and its side column scroll inside themselves, and the strip at its top still drags the
window. Under the header (the same 22/600 title and `body` explanation, capped at 820pt) sits a main column
that takes the room and a fixed side column of reference and history (330pt on Instructions, 280pt
on Skills and MCP servers, 320pt on Experiments), 28pt apart (32pt on Experiments). Their section labels (`nwSettingsLabel()`; a list's column heads and a detail's labels are
`nwSettingsLabel(table: true)`, 10.5 in `textTertiary`) sit `NW.Space.xxs` in and `NW.Space.m`
above what they label, and a label may carry a trailing text action ("Add all"). Lists in the side
column (files, history, steps, what was added) are bare rows separated by `lineSubtle` hairlines,
not cards; only Instructions' reading order uses small cards.
