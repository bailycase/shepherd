# Destination pages

> Read when you change New thread, Automations, Hosts, Designs or the Missions page.

## Destination pages

Each destination opens a page in the main column, in place of a thread (NavNewThread,
NavAutomations, NavHosts; Missions and Designs are hidden until built). A page covers the whole
column, the thread toolbar included, while every mounted layout stays mounted and hidden under it
(`MainDestination`, `WorkspaceSelection.destination`), so leaving it is a flip; picking a row
leaves it. The pages share one frame (ShepherdUI's Pages components, `NWPageMetrics`):

- **Page header** (`NWPageHeader`, through the app's `DestinationPageHeader`): 52pt (the thread
  toolbar is 44) on `bgWindow`, with a hairline beneath, 24pt leading and 16pt trailing padding,
  and 12pt between items. It holds the page title in `title` (Geist 15 semibold); an optional
  subtitle in 12.5 `textTertiary` ("3 hosts · 1 offline"); a spacer; and the page's own controls: a
  filter field ("Filter automations"; 220×28, radius 6, padded 10pt, a 1pt `lineSubtle` border and
  no fill, a 12pt `textTertiary` magnifying glass 8pt before a 12pt `textTertiary` placeholder) and
  the page's one primary button (`.nw(.primary)`, 28pt, radius 6, padded 10pt, a 13pt `plus` 6pt
  before the label in 12.5 semibold: "New automation", "Add host"). New thread has neither. The
  field is `NWPageFilterField`, lighter than `NWSearchField` as the board draws it. While the
  sidebar is not docked the header leads with the Show sidebar button and clears the window
  controls, as the toolbar does, and its empty area drags the window.
- **State tabs** (Missions; the Automations page has none, since automations have no schedule), under the header, padded 16pt above, 12pt below, and 24pt
  at the sides. They are 28pt tall, padded 10pt at the sides, radius 6, and 2pt apart. Each is the
  label in 12.5 and its count in mono 10.5 `textTertiary`. The selected tab is `bgSelected`,
  `textPrimary` and semibold; the others are `textSecondary`.
- **Tables** (Missions, Automations): column labels in mono 10.5 caps, 5% tracking, `textTertiary`,
  padded 24pt at the sides and 8pt below. Rows have a hairline above, 24pt side padding, and the
  columns' gap. The selected row is `bgSelected`.
- **Cards** (Designs, Hosts): a 1pt `lineSubtle` border at radius 10 (the boards' value, between
  `NW.Radius.m` 8 and `.l` 12), clipped. The page body is padded 20pt above and below and 24pt at
  the sides.

## New thread page

`NewThreadPage` (`NewThreadPage.swift`; NavNewThread, "⌘N or the first destination"), its draft in
`NewThreadState` (`NewThreadModel.swift`), kept while the page is away. ⌘N, the New thread
destination, the palette's New thread and File ▸ New Thread open it with the field focused; a space
from the palette or the Space menu opens it in that project, and adding a folder opens it in the new
one. The New agent sheet (⇧⌘T) stays for its directory and base fields.

- The header reads "New thread". The body centres one column vertically, padded 40pt at the sides
  and 80pt below, with 24pt gaps.
- **Heading:** "What should the agent work on?" in Geist 26 semibold, tracked −2%. This is outside
  the ramp; set it with `Font.nwSans`.
- **Composer:** the thread's `NWComposer`, 720pt wide, drawn focused (a `textTertiary` border and a
  3pt `bgSelected` ring). The placeholder is "Describe the task…". Its control row is attach, the
  normal composer's shared model-settings button, a spacer, then the workplace chip. Thinking
  appears only while the model takes a level; the settings popover's Speed row only while the target
  supports choosing a tier at creation and the model offers one. The button uses compact labels when needed to
  fit, with Send outside the fitting candidates. Send is a 28pt `lantern` circle at 35% until there is a prompt and a project. ↩ sends and ⇧↩ adds a
  line. Why Send cannot go is its tooltip ("Describe the task first.", "Add a project to start a
  thread.", "Loading build-01's defaults…"), and a failure shows under the card in `failed`.
- **Images** (the user's decision, 2026-09-25: "Build it (Recommended)") attach as in a thread's
  composer (Composer › Images, `ComposerAttachments`): by drop, paste, or the paperclip, the
  composer's attach button, always shown here; resized on the way in, at most four of 2 MiB each,
  as chips above the field. They go to pi in the opening prompt itself, on this Mac and on a host
  (`createAgent`'s images, docs/native-thread.md). What cannot go shows under the card in `failed`
  and holds Send: the composer's own messages, "The images come to over 5 MiB together. Remove one
  to send.", and on a host from before `agent.create.images.v1` "Update Shepherd on build-01 to
  start a thread with images.", which would otherwise drop them; nothing is created. Images too
  big for one remote request fail the send the same way ("Images exceed the remote payload
  limit. Send fewer or smaller images.").
- **Design references** (the user's report, 2026-10-01; no board draws them), while Settings ▸
  Experiments ▸ Design tool is on: "@" opens a thread's picker (design-tool-references.md › The @
  picker) under the card, in the page's own menus' place, and a pasted `shepherd-design-ref://`
  reference becomes a chip. Chips sit first among the attachments (a 20pt Remove, ⌫ with the caret at
  the start of the words), at most five, each pinned at the revision it was picked at. A design
  alone is enough to press Send, as in a thread's composer ("Describe the task first." says it
  needs neither). Send starts the agent as always, named for the words or the first piece
  (provisional, so pi's namer settles it), and the host sends its opening message once pi serves:
  the fenced record, the copy kept, the prompt and any images as its words
  (`ShepherdViewModel.deliverOpeningDesignReferences`, through the host like Implement's new
  thread, not the thread's store). If that send fails the thread stays, a dialog says why, and the
  words come back into its composer. They are this Mac's designs and reach this Mac's projects
  only: for a project on another host the picker says "Design references go to projects on this
  Mac." and, with a chip attached, Send says the same under the card and in its tooltip.
- **Workplace chip** (`NWPlaceChipLabel`): a 12pt `textSecondary` folder glyph and the project in
  mono ("shepherd"), a `textTertiary` "·", a display glyph and the host in mono ("This Mac"), and a
  10pt `textTertiary` chevron, as a 26pt chip in 12 `textSecondary`. It picks where the thread runs,
  and opens the **workplace menu** (`NWPlaceMenu`, the composer menus' anatomy, 320pt, 8pt under the
  card): one section per host, This Mac then each connected host, listing its projects (its visible
  spaces, nested ones flat, each with its path in mono 11 `textTertiary` and a check on the chosen
  one), each section ending in "Add folder…" (this Mac's directory picker, or the host's); then,
  when the chosen project is a git checkout on this Mac or on a host that makes worktrees, **New
  worktree** with its switch and "Keeps the checkout clean. Merge it from Review.". The board draws
  no worktree control, so it lives in the chip's menu: its branch is generated and its base resolved
  per Settings ▸ Worktrees, as the New agent sheet does. A project on this Mac has a context menu
  with what the sidebar's space rows offered: Rename…, New Worktree… and Import Existing Worktree…
  (git checkouts), and Remove Space…; the palette offers Rename space… and Remove space… for the
  chosen project while the page shows. A host's project offers New Agent with Options….
- The page opens in the project of the thread last on screen (a remote thread's, on its host), else
  the one chosen before, else This Mac's first, else a connected host's first.
- **Model, Thinking and Speed:** the target's defaults (Settings ▸ Agents on this Mac, the host's
  `creationOptions` on a host), changed through the same settings button and popover as the thread composer,
  opening under the card over what is beneath. The model listing comes from pi's composed models
  over RPC, including built-in and provider-extension thinking maps, not a reasoning yes/no guess.
  Send waits for those capabilities to load so an Extra high or Max default is not silently
  downgraded. If the catalog is unavailable, the chosen level stays intact for pi to resolve;
  only a known model's supported set or an older host's Off-to-High limit clamps it. A chosen speed travels with creation before the opening prompt, locally and on a
  host offering `agent.create.serviceTier.v1`; older hosts show no Speed control and keep their
  own default. Reopening keeps explicit choices, and each host has its own defaults. A click
  outside or Esc closes these menus, as in the thread composer.
- **Send** creates the agent with the prompt and its images as its opening message (on this Mac
  `startAgent`, on a host `createAgent`), opens its thread, and clears the draft.
- **Suggestions:** the cards under the composer, 38pt below it (the column's 24pt gap plus 14),
  three to the 720pt row, 10pt apart. Each is padded 12pt above and below and 14pt at the sides,
  radius 8, with a 1pt `lineSubtle` border, hover `bgHover`, and 5pt gaps: a kicker in 11.5
  `textTertiary` with a 12pt `textSecondary` glyph 8pt before it, a title in 13 medium truncating at
  the tail, and a detail in 11 `textTertiary`. Only **Continue** is built: a speech bubble, the most
  recent running thread's title, and "running · 42m" (since its turn began, counting). Clicking it
  opens that thread; with nothing running there is no card. **Start a design** ("Need a mockup
  first?", "Start a design", "HTML boards on a canvas", the nib) is the last card while Settings ▸
  Experiments ▸ Design tool is on, and opens New design. The mission card ("Bigger than one
  thread?") is hidden until Missions is built.

## Missions page

**Not built yet**, and waiting on Missions itself (NavMissions; "every mission, filtered by state").

- **Header:** "Missions", "Filter missions", and **New mission**.
- **Tabs:** All · Needs you · Running · Drafts · Done · Templates, each with its count.
- **Table**, columns Mission · Lanes · Route · Spend · Host (1.7fr · 1.2fr · 160pt · 150pt · 110pt,
  20pt gaps). Rows are padded 14pt above and below.
  - **Mission:** a 14pt map glyph (`lanternText` while it needs you, else `textSecondary`), the name
    in 13.5 semibold, and a 10pt gap before its state pill (`NWStatusPill`): Needs you (glowing),
    Running, Draft (outlined, `textTertiary` dot), or Merged (the `done` pill worded "Merged").
    Under it, indented 24pt, is one line in 12, truncating: the question in `lanternText` while it
    needs you ("retention: 30 days or 13 months?"), else what it is doing or how it ended in
    `textTertiary` ("orders · go test ./... · 3m", "map drafted · 1 question open", "PR #34 merged ·
    2h41").
  - **Lanes:** one chip per repo, wrapping with 4pt gaps. A chip is 20pt, radius 4, a 1pt
    `lineSubtle` border, padded 6pt, with a 10pt repo glyph and the name in mono 10.5
    `textSecondary`.
  - **Route:** a 150pt strip of one 4pt segment per station (radius 2, 2pt apart): `done` for
    passed, `running` for going, `lantern` for waiting on you, `lineStrong` for ahead. Under it, 6pt
    below, "6 of 15 stations" in mono 10.5 `textTertiary`.
  - **Spend:** tokens against the budget ("2.3M / 6M tok") in mono 11 `textSecondary`, over time
    against its budget ("1h12 / 4h") in `textTertiary`, 3pt apart; a draft that has spent nothing
    reads "— / 3M tok" and "— / 2h".
  - **Host:** mono 11 `textSecondary` ("build-01", "This Mac").

## Designs page

**Built behind Settings ▸ Experiments ▸ Design tool** (NavDesigns; "recent designs and design
systems"; `DesignsPage`). The page takes the header above ("Designs", "Filter designs", and **New
design**); its recent designs and design systems are specified with the rest of the design tool,
under Design tool › Designs.

## Automations page

NavAutomations, as `AutomationsPage` (`Sources/ShepherdApp/Pages/`), from the sidebar's
Automations destination. One table holds every host's automations, This Mac's first
(`AutomationsPageModel`, derived per change from `AutomationsModel`, the presentation the iOS
client shares, with This Mac as one more host). Shepherd's automations have no schedule or
trigger: one is on (it starts a run when Shepherd starts on its host) or run by hand. So the
board's When and Next columns and its Scheduled and On an event tabs are left out (the user's
decision, 2026-09-25: "Automations = table + detail with name, host, last run, prompt, runs, Run
now (no schedules, triggers or next-run column)").

- **Header** (`NWPageHeader`): "Automations", "Filter automations" (`NWPageFilterField`: name,
  host or prompt), and **New automation**.
- **Table**, columns Automation · Starts · Host · Last run (`2fr · 76pt · 76pt · 1.15fr`,
  `NWTableColumns`, 16pt gaps), under its labels (`NWTableHead`, 16pt below the header). Each row
  is an `NWAutomationTableRow`, padded 12pt above and below with a hairline above, `bgSelected`
  when selected; a click selects it.
  - **Automation:** its switch (`NWAutomationSwitch`, 30×18), 10pt before the name in 13
    semibold. The switch turns it on or off on its host, disabled while the host can't take it.
  - **Starts:** a speech bubble and "thread" in 12 `textSecondary`: every run starts a thread.
  - **Host:** "This Mac" or the host's name, mono 11 `textSecondary`.
  - **Last run:** a 6pt dot and the run's word with its time in 12, colored by how it went
    (`NWRunOutcomeLabel`): "running · 4m" `running`, "asked you · 1h ago" `lanternText` with a
    glowing `lantern` dot, "finished · 6h ago" `done`, "interrupted · 3d ago" `failed`, and quiet
    (a hollow `textTertiary` dot, `textTertiary` words) for stopped, "not run yet", "off" and
    "host offline". Empty until the host's runs are read.
  - **Context menu:** Open Run while its run's thread exists, Stop while the run is live else Run
    Now, Edit…, and Delete Automation (it stops the run too, including a run still being created), each disabled where the host can't
    take it. These are the actions the sidebar's Automations rows had.
  - **Empty:** "No automations yet. …" or "No automations match “…”." in the table's place.
- **Detail pane:** 360pt at the trailing edge with a hairline on its leading side, for the
  selected row (the first row while none is chosen). Sections are padded 14pt above and below and
  18pt at the sides, with a hairline between them.
  - **Header,** padded 16pt: the name in `title` over "Starts a thread on build-01 when Shepherd
    starts" (or "when you run it") in 12 `textTertiary`.
  - **Prompt:** "PROMPT" (`NWPageSectionLabel`), 8pt above the prompt on `bgSunken` with a
    `lineSubtle` border, radius 8 (`NWPageQuote`).
  - **Facts** (`NWPageFact`, a 90pt label column in `textSecondary`, 6pt apart): When ("When
    Shepherd starts" or "By hand"), Host (mono), Folder (mono, in place of the board's Repos: an
    automation has one folder), and Model (mono) only where its run's thread says which.
  - **Recent runs:** "RECENT RUNS", then every run the host kept, newest first, in 28pt rows
    (`NWAutomationRunLine`): the dot, the start in mono 12 `textSecondary` ("Sep 24 02:00"), the
    word in 12 `textTertiary`, and how long it took in mono 10.5 `textTertiary`. A run whose thread
    still exists opens it. Before the runs arrive: "Reading runs…"; with none: "No runs yet."; from
    a host that can't list them: "Runs aren't available from this host."
  - **Footer** pinned under a hairline, padded 12pt above and below and 14pt at the sides: **Run
    now** (secondary, small, a play glyph; **Stop** while a run is live), why nothing can change
    here when the host is offline or too old, a spacer, and **Edit** (ghost, small).
- **New automation and Edit** open `AutomationEditorSheet`: Host (for a new one, when a connected
  host serves automations), Name, Folder (with Choose…, the directory browser on that host),
  Prompt, and On. Saving never starts a run. This Mac saves through its server; a host through
  `RemoteAutomationRequest.create`/`.update`, the fields the iOS form has.
- The page reads every automation's runs when it opens and whenever a run starts, settles or ends
  (this Mac's run log, each connected host's `runs`).

## Hosts page

NavHosts, as `HostsPage` (`Sources/ShepherdApp/Pages/`), from More ▸ Hosts: This Mac and each
remote host as a card with the facts Shepherd has (`HostsPageModel`). Shepherd has no daemon and
nothing measures load or worktree disk use, so the board's daemon facts, Load, worktree sizes,
Open in Finder, Open terminal and Logs are left out (the user's decision, 2026-09-25: "Hosts =
This Mac and each remote host's card with status, address, threads, Retry, Remove, Add host").
Hosts are still added and edited in Settings ▸ Remote.

- **Header:** "Hosts", the subtitle "3 hosts · 1 offline" (This Mac counts; the offline part only
  while one is), and **Add host**, which opens Settings ▸ Remote's host form. There is no filter.
- **Explainer:** one paragraph in 12.5 `textSecondary`, at most 720pt wide: "Where agents run.
  Threads run on the host you pick when you start them. Remote threads show the host's name as a
  tag in Recents." The board's missions sentence waits on Missions.
- **Host cards** (`NWHostPageCard`), 14pt under the explainer, three to a row with 16pt gaps,
  equal heights, each a 1pt `lineSubtle` border at radius 10.
  - **Head,** padded 14pt above and below and 16pt at the sides, with a hairline beneath: the 30pt
    tile with a display glyph; the name in mono 14 semibold over "Shepherd app · agent 0.8.2"
    (pi's version, This Mac only) or "Shepherd app", plus "· offline 3h" once a host has dropped;
    and the connection trailing in 12 with a 6pt dot: "Connected" `done`, "Connecting" `running`,
    "Not connected" `idle`, or the failure's word in `failed` ("Unreachable", "Token refused",
    "Update needed").
  - **Facts** (`NWPageFact`, 110pt labels, mono 11.5 values, rows at least 26pt): a connected host
    shows Running ("2 threads", or "none"), Worktrees (how many threads work on one, when any),
    Repos (its projects), and, for a remote host, Address. An unreachable one shows Waiting from
    its last state ("2 threads, 1 automation"), Last seen ("Sep 24 07:12", when it dropped this
    launch), and Address. A failure that retrying won't fix (a refused token, another version)
    adds its sentence under the facts; this is where the sidebar's host notices went.
  - **Actions** under a hairline, padded 10pt above and below and 14pt at the sides, 8pt apart,
    small, remote hosts only: Retry (secondary, `arrow.clockwise`) while neither connected nor
    connecting, and Remove (ghost), which asks first ("Remove build-01?"). This Mac has none.
