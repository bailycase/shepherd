# iPhone: Needs you, Search, More and Settings

> Read when you change the iPhone's Needs you, Search, More, Settings, Instructions, Skills or Experiments.

## iPhone: Needs you (MobileInbox)

`Home/NeedsYouScreen.swift`, pushed from Home's Needs you. Every question and blocked thread on the
connected hosts, newest first.

- **Header:** the large title "Needs you", then "4 things are waiting on you" ("1 thing is waiting
  on you"). On `bgWindow`, 14pt sides, cards 10pt apart. Pull to refresh.
- **A card** (`NWAttentionCard`): `bgRaised`, 1px `lineSubtle`, 12pt corners, 10×14 padding, 6pt
  apart inside:
  - The origin line: a 14pt `lanternText` glyph (a bolt for an automation run, a folded map for a
    mission; a glowing 8pt `lantern` dot for a thread) and
    "Thread", "Automation · Triage new Sentry issues" (12
    `textTertiary`), with the time since trailing ("now", "2m", "14m", "1h"). The app adds the
    host's badge when there are several hosts (`NWAttentionCard`).
  - The title (15/600): the thread's name. An automation's card is
    titled by its question ("Is this a regression from #231?") over the asker's context ("NilPointer
    in PlaceOrder started 40 minutes after #231 merged.").
  - The question (13.5/1.4 `textSecondary`), and the asker's message under it.
  - The answers that fit in place, 8pt apart and wrapping, at 28pt: a select with at most three
    short options shows them (the first primary); a confirm shows Yes (primary) and No (a pi confirm
    carries no labels of its own). Then Open (ghost; secondary when it is the only action), which
    goes where the question can be answered. Input and editor questions show Open alone.
- **Not built yet:** a mission's item ("Mission", "Checkout funnel events", "orders is stuck after 3
  tries. The planner suggests a retry with a hint.", Retry with hint and Open), and a thread's plan
  approval ("Plan ready: …", Approve plan and Read plan). They wait for Missions and plan approval
  on the Mac.
- **Empty:** "Nothing needs you" ("Questions and blocked threads from every host show here.").

## iPhone: Search (MobileSearch)

`Search/MobileSearchScreen.swift`, pushed from Home's Search. No navigation bar and no tab bar; the
keyboard is up while the query is empty.

- **Field row:** 58pt from the top, 14pt sides, 10pt gap: the field (`NWTouchSearchField`: 40pt,
  10pt corners, `bgSelected`, a 15pt magnifier and a 12pt clear ×, both `textTertiary`, the query at
  16 with a `lantern` caret; placeholder "Search threads"), then Cancel (16 `running`).
- **Results:** sections 8pt apart, each a head and a card of 52pt rows (a 16pt glyph in a 20pt
  column, the title at 15/500 over a 12.5 `textTertiary` detail, a chevron). The match is
  `lanternText` at 600 in titles and snippets.
  - "In conversations": a speech-bubble glyph, the thread's name and who said it ("Checkout funnel
    events · validator"), and the snippet in quotes with ellipses ("…funnel rows can't be joined…").
    The app shows the host's badge in place of the speaker, and adds a "Threads" section of title
    matches first.
  - A tap pushes the thread over search; Back returns to the results.
- **Not built yet:** the Missions section (a folded-map glyph in `lanternText` for one that needs
  you; "needs you · orders is stuck"), the Designs section (a diamond; "acme-web · 4 boards"), and
  Actions: "New mission" ("“funnel” as the goal") and "New design" ("“funnel” as the brief"), each
  with a plus or diamond glyph. They wait for Missions and the Design tool.
- **States:** before a query, "Search every host" ("Find a thread by its title, or by a line from
  its conversation (three letters or more)."); nothing found, "No results" ("Nothing on your hosts
  matches “q”."); while hosts answer, "Searching conversations · 3 of 12" with a spinner, and a line
  for each host left out.

## iPhone: More (MobileMore)

`Home/MoreScreen.swift`, pushed from Home's More.

- **Hosts:** the head "Hosts" with "Add host" (13 `running`) trailing, then a card per host
  (`NWHostCard`; 12×14 padding, 6pt apart, 10pt between cards):
  - A 15pt display glyph in `textSecondary`, the name (mono 15/600), what it is ("Shepherd app · agent
    0.87", 12 `textTertiary`), and the connection trailing (a 7pt dot and "Connected" in `done`,
    "Unreachable" in `failed`, 12). The app shows the address and port where the board has what it
    is, and says "Offline".
  - What runs there: "2 threads running · shepherd, dashboard-web" (12.5 `textSecondary`).
  - Unreachable: "Last seen today 07:12 · 1 automation paused" (12.5), then Retry (32pt secondary
    with a retry glyph) and Wake on LAN (32pt ghost). The app shows why it cannot connect in
    `failed`, then "Last seen today 7:12 AM" (12.5 `textSecondary`: when this device's connection
    to it last ended, kept on the device; "yesterday 6:42 PM", or the day), and Retry at 24pt
    (`.s`). The board's "1 automation paused" is not shown.
  - A tap opens the host's form (edit, forget). Pull to refresh retries every host. Under the cards:
    "Hosts connect over your LAN or VPN. The connection has no TLS."
- **Not built yet:** a daemon host's card ("daemon · Linux", "2 missions · 5 stations running · load
  6 of 16 cores") until the Mac has daemon hosts; Wake on LAN on an unreachable host, which sends
  the host's magic packet and then retries; a host's kind and pi version, which need the host to
  report them.
- **Under the hosts** (and under their note), a card of 52pt rows: Extensions ("6 installed", a
  puzzle glyph: the settings host's bundled extensions that are on and its installed ones, once it
  has answered), which opens Settings ▸ Extensions (the bundled and installed pi extensions each
  host loads). The card shows while any host is set up.
- **Not built yet:** the card's Design systems ("2 · acme-web, Night Watch", a palette glyph) and
  Archive ("41 threads", a box glyph) rows, each pushing its list; they wait for the Mac.

## iPhone: Settings (MobileSettings)

`Settings/SettingsScreen.swift`, the Settings tab's root: the large title "Settings" on `bgBase`,
14pt sides, cards of 48pt rows, each a 17pt `textSecondary` glyph, the name, its value trailing (14
`textTertiary`) and a chevron.

- **First card** (no head): Appearance (a palette glyph; "System", "Light" or "Dark"), then
  Notifications (a bell; "Needs you").
- **Agents:** Defaults (a sparkle; the default model, "claude-opus"), Instructions (a page;
  "AGENTS.md, APPEND"), Skills (a graduation cap; "8 · 2 updates"), Extensions (a puzzle; "6").
- **Machines:** Hosts (a display; "1 offline", or the count), then Worktrees (a branch).
- **A card of its own:** Experiments (a flask; "1 on").
- **About:** a 24pt Shepherd icon (the crook in `lantern` on `textOnLantern`'s dark, 6pt corners),
  "Shepherd 0.1.0", and "agent 0.87.1" (mono 13 `textTertiary`) trailing.
- **In the app** the screen is `bgWindow` with 16pt sides, a value is 12 (`.caption`), Hosts shows
  "1 offline" as a problem (mono `failed`) or the host count ("None" with no hosts), and
  Appearance keeps the half-filled circle the Mac's Settings uses. A value shows once a host has
  answered (`SettingsStore`): Defaults, Extensions and About's agent are the settings host's (the
  one their pages last showed, else the first that serves its settings), Instructions the first
  host whose files read, and Experiments "1 on" or "Off" once any host serves suggestions. About
  says "build N" until a host reports its agent's version. Every Settings screen reads every host as it
  appears, again as a host connects, and on pull to refresh.
- **Not built yet:** Notifications (which events notify: Needs you by default; it waits for push
  notifications; see Settings ▸ Notifications).

### A host's settings (Defaults, Worktrees, Extensions)

No board draws these pages: they are the Mac's Settings ▸ Agents, Worktrees and Pi (SettingsAgents,
SettingsWorktrees, SettingsPi) as a host keeps them (`hostSettings.v1`), in iOS Settings' anatomy
(`Settings/HostSettingsScreens.swift`): a large title and an explanation (`.caption`,
`textSecondary`), then `SettingsSection` heads over `NWListCard`s of rows, each the title at `ui`
over a note (12.5/1.45 `textTertiary`, its `code` and **names** marked as the Mac marks them,
`NWMarkupText`) with its control trailing: an `.nwSwitch`, or a menu naming the current value
beside up-down chevrons.

- **Which host:** with several hosts, a first card, Host, whose menu lists them ("horizon ·
  offline"); the three pages share the choice. With one host there is no card.
- **Defaults:** New threads: Model (a menu of "Use the agent’s default", then the host's catalog,
  keeping the current model when the catalog lacks it; mono) and Thinking (Off … Max). While the
  agent is working:
  When a turn ends, send the queue (One per turn, All at once).
- **Worktrees:** New worktrees: Base branch (Remote default, Current branch) and Fetch before
  creating. Finalize: Commit remaining work, Generate PR descriptions, Delete local branch, Merge PR
  automatically and, while that is on, Merge method (Squash, Merge, Rebase), over "Shepherd never
  deletes the remote branch: merging the PR cleans it up on GitHub."
- **Extensions:** Bundled with Shepherd: a switch for each extension the host bundles, with its
  note. Installed on <host>: the host's own packages and extensions in mono ("None yet…" without).
  Updates explains that the agent engine and bundled extensions update with Shepherd on the
  host, over "<host> runs agent 0.87.1." No daily-update switches: current hosts bundle pi and
  intentionally ignore those legacy settings.
- **States:** a spinner while the host answers; offline, "<host> is offline. Its settings show here
  once it's back."; a Shepherd from before `hostSettings.v1`, "…is too old to share its settings.
  Update it to change them here."; a failed read, its reason in `failed`. A change shows at once
  and goes to the host; one it refuses springs back, its reason in a banner.

## iPhone: Instructions (MobileInstructions, MobileInstructionsEdit)

With Per host selected, each window chooses its own instruction host. Drafts for the same file
and host remain shared; switching hosts in another window never retargets this window's Save
or Restore. Save and Restore keep the scope and recipient list selected at invocation, even
if another window changes Same on every host while the request waits. Explicitly forgetting a
host removes its drafts and owed copies, never another
host's, and late replies cannot bring the forgotten host's data back.

Settings ▸ Instructions edits the root instructions every session Shepherd starts reads, on
every host (`Settings/InstructionsScreens.swift`; the Mac's page is SettingsInstructions). Each
host keeps Shepherd's own copies in its support folder and serves them over `instructions.v1`;
`ClientInstructions` (ShepherdRemote) holds every rule.

- **The page** (MobileInstructions): "‹ Settings", the large title "Instructions", on `bgBase` with
  14pt sides and 10pt apart. "The agent reads these at the start of every session, on every host."
  (13.5/1.5 `textSecondary`, 4pt sides). A card with one 60pt row: "Same on every host" (15) over
  "Save once, written to each host's ~/.pi/agent/" (12.5 `textTertiary`), and its switch, on.
- **Files:** a card of 64pt rows: a 17pt page glyph, the file (mono 15/600) over what it is and its
  size ("How you work · ~640 tokens", "Rules that win · ~90 tokens"; 12.5 `textTertiary`), a
  chevron: AGENTS.md, APPEND_SYSTEM.md. A row opens the editor.
- **Hosts:** a card of 52pt rows: a display glyph, the host (mono 15), and its sync state trailing
  (13): "synced" and "synced 2m ago" in `done`, "offline · will sync" in `textTertiary`.
- **The editor** (MobileInstructionsEdit): an inline header with "‹ Back" (90pt slot), the file
  (mono 15/600) over "every host · edited" (11.5 `textTertiary`), and Save (16/600 `running`)
  trailing. The file in mono 13 on 21pt lines with a 28pt number column (10.5 `textTertiary`,
  right-aligned, 8pt after); Markdown marks in `textTertiary` (`#`) or `lanternText` (`-`), headings
  600 `textPrimary`, list text `textSecondary`, code spans in the syntax string color; the line
  being edited on `lanternTint`; a `lantern` caret. Over the keyboard, a key row on `bgSunken` with
  a `lineSubtle` rule: 32pt keys at least 38pt wide on `bgRaised`, 6pt corners, mono 14: `#`, `-`,
  `` ` ``, `**`, Tab.
- **In the app** the page is `bgWindow` with 16pt sides and reads "The agent reads these at the
  start of every session Shepherd starts, on every host.", and the switch's note is
  "Save once, written to every host." ("Each host keeps its own." when off): Shepherd writes its
  own copies, never `~/.pi/agent` (departures). With Same on every host on (the default, kept per
  device) the page edits the first host whose files read and a save writes both files to every
  host; a host offline then is owed them ("offline · will sync", remembered on the device) and
  takes them the next time the page reads it. A host whose files differ reads "differs · 2 lines"
  in `lanternText`, and Sync now under the card gives each such host the first host's files. Off,
  a host's row shows the files it holds ("AGENTS · APPEND"), and a tap picks the host the page
  edits (a `lantern` check). A file's row says "edited" in `lanternText` while its draft waits;
  drafts last until saved, or until the app quits.
- **The app's editor** (`InstructionsTextEditor`, TextKit) draws as the Mac's does: its
  highlighting, and every line changed since the last save tinted, not only the one being typed;
  its sizes follow Dynamic Type up to 22pt. The key row is the terminal's (`NWTerminalKeyRow`);
  `` ` `` and `**` wrap a selection, and Tab indents two spaces. Save reads "Save" whatever the scope
  (VoiceOver hears "Save to 3 hosts"), and a spinner takes its place while it writes; a failed save
  shows its reason in a banner over the file.

## iPhone: Skills (MobileSkills)

Settings ▸ Skills on the phone and the iPad (`Settings/SkillsScreens.swift`; the Mac's page is
SettingsSkills): every host's agent skills, the same on every host, over `skills.v1`.
`ClientSkills` (ShepherdRemote) holds every rule, as on the Mac.

- **The page** (MobileSkills): "‹ Settings", the large title "Skills" and a 36pt round + (Add from
  repo) in the bar, on `bgBase` with 14pt sides, 10pt apart. "Global: every host gets the same
  skills. Tap one for how it’s used, its files and hosts." (13.5/1.5 `textSecondary`), a 40pt search
  field on a filled track at radius 10 ("Search skills.sh", 15), then "Installed · 8" (13/600
  `textSecondary`) with "Update 2" (13.5/500 `running`) trailing, over a card of rows at least 58pt
  (8pt × 14pt padding, 10pt gaps): the name in mono 14/600 over its description at 12.5
  `textTertiary` ("/skill only · House style for table-driven Go tests." for one only /skill
  loads), the Update pill (22pt, 12/600) while a newer commit waits, and its switch (off: the
  track in `lineStrong`). Under the card: "horizon is offline. It gets changes when it’s back."
  (12.5/1.5 `textTertiary`).
- **In the app** the page is `bgWindow` with 16pt sides; the field is the touch search field
  (`NWTouchSearchField`); Installed · 8 and Update 2 are the lists' header and link; "Updating"
  shimmers in a row while its update goes; and several hosts away read "horizon, build-02 are
  offline. They get changes when they’re back." A tap on a row opens the skill, its switch turns it
  on or off on every host, and Update N installs every newer commit. Removing a skill (from its
  detail) comes back to the list with "Removed pdf from every host" and Undo in a banner. Without a
  host, or with none online, too old or unreadable, the page says so in place of the list, and
  reads every host again on pull to refresh.
- **pi's own skills** (the user's decision of 2026-09-26, as on the Mac): under Installed, "From
  your pi setup · 2" and "From pi packages · 1" (the lists' header) over read-only cards of the
  first host's own pi's skills: rows at least 58pt with the name in mono 14/600, the description
  at 12.5 `textTertiary` ("/skill only · …", or "Not used: pi uses the one in …" for one pi passes
  over), and where it comes from in mono 11.5 `textTertiary` (the folder, or the package); no
  switch, and a tap does nothing. Under them: "Read-only: from studio’s own pi, which Shepherd
  never changes." and the note that a repository's own skills load only in its threads; why pi
  couldn't be asked in `failed`; a host too old to report them says so.
- **Search:** typing asks skills.sh (a quarter second after the last key): "9 skills for
  “postgres”" over a card of results, the name in mono 14/600 with the search's matches in
  `lanternText` and the Official seal, "supabase/agent-skills · 71K installs" under it, and a 96pt
  end with Install (small secondary), "1 of 3 hosts" shimmering while it installs, "Installed"
  with a check in `done`, or the Update pill. Clearing the field shows the installed skills again.
- **A result** (no board draws it) opens its preview: the name in mono 17/600 with the seal, the
  line under it, and the description; Use it (Automatically or Only with /skill, a menu row, with
  what it means), Install (large primary) and where it goes ("Studio, build-01 now · MacBook Air
  when it's back"), or Installed with Open, or Update; while it installs, "Installing · 1 of 3
  hosts" with Cancel over a card of each host's step. Then SKILL.md (a card: the file and "~1,400
  tokens when used" in a 36pt header on `bgSunken`, its first 60 lines numbered in a 28pt column,
  mono 12 on 19pt lines with the instructions editor's highlighting, and "40 more lines"), Files as
  chips with what its scripts are, Pick from all of anthropics/skills (Add from repo on it) and View
  on skills.sh.
- **A skill** (no board draws it) opens its detail: the name in mono 17/600 and its description;
  On (a switch: "Agents can use it." or "No agent sees it until it's back on."); Use it, the Mac's
  two radio options in a card; Version (the repository and folder, "Installed 3f2a91c · Aug 30",
  and "New 8c04e1d · Sep 22 · 3 files changed" in `lanternText` with Update and What changed; or
  Local); Hosts (a display glyph, the host in mono, its state trailing: "installed" in `done`,
  "updating" in `running`, "offline · updates later" in `textTertiary`); Files as chips; and
  "Remove from every host" (large danger).
- **Add from repo** (no board draws it): "A GitHub owner/repo or URL. Shepherd copies the skills
  you pick into its own pi's skills on every host.", a 44pt mono field on `bgRaised` with Look up,
  then "3 of 13 new skills" with Select all new over a card of the repository's skills (a tick
  circle, the name in mono 14/600, "Installed" or "Installed · update" for one already here,
  dimmed and fixed, and the description), "16 skills · main @ 8c04e1d", Use them (a menu row),
  where they go, and "Install 3 skills" (large primary). While it installs, each host's step shows
  in place; the screen closes once every host that could take them has them. A repository with one
  new skill ticks it; a URL into a skill's folder ticks that one. The phone has no folders to add.
- **On iPad** the page shows beside the Settings list (Skills after Instructions), and a skill, a
  result or Add from repo opens over the detail.
- **Not built yet:** Same skills on every host as a switch on the phone and the iPad, which follow
  it on (the Mac's option is kept per Mac); skills.sh's ranked lists.

## iPhone: Experiments (MobileExperiments)

Settings ▸ Experiments: features still being tried, each off until turned on
(`Settings/ExperimentsScreens.swift`; the Mac's page is SettingsExperiments). Its one experiment
spans every host (`suggestions.v1`); `ClientSuggestions` (ShepherdRemote) holds every rule.

- **The page:** "‹ Settings", the large title "Experiments", on `bgBase`, 14pt sides, 10pt apart.
  "Still being tried out. Each is off until you turn it on." (13.5/1.5 `textSecondary`).
- **An experiment:** a card with one row (14pt padding, 12pt apart, top-aligned): a 30pt square on
  `lanternTint` with 8pt corners holding a 16pt `lanternText` flask, then "Suggested instructions"
  (15/600) over "Agents draft a line for your root AGENTS.md when they learn something the hard way.
  Nothing is written until you add it." (12.5/1.45 `textTertiary`), and its switch.
- **Learn from:** a card of 46pt rows, Missions, Threads, Automations (15), each with a 15pt
  `running` checkmark when chosen.
- **Waiting for you:** the head with "Add all" (13 `running`), then a card of rows (12×14,
  top-aligned): the source's glyph, 16pt (a folded map in `lanternText` for a mission; a speech
  bubble for a thread and a bolt for an automation in `textSecondary`), the suggested line in mono
  13/1.45 with a `done` "+ " before it and code spans in the syntax string color, where it came from
  under it ("Checkout funnel events · AGENTS.md", "… · build-01"; 12 `textTertiary`), and a chevron
  that opens it to add or dismiss. Nothing is written until you add it.
- **In the app** the page is `bgWindow` with 16pt sides, and Learn from lists Threads and
  Automations (Missions aren't built). The switch and the choices change every host that serves
  suggestions, and show at once. A line leaves off its Markdown bullet and names its host once
  more than one host serves suggestions. Add all shows from two lines up; with none, "Nothing is
  waiting. When an agent learns something the hard way, its line shows up here." While it is on,
  Open Instructions follows the lines. With no host serving suggestions the switch is off and
  dimmed, over why (no host online, or a Shepherd too old).
- **A suggestion** (no board; pushed from its row, titled "Suggestion"): the source's glyph and
  name with its host's badge over "thread · 2h ago"; The line (mono 13 on `doneTint`, editable, one
  line: Return ends the edit); Why (the agent's reason at `body` in `textSecondary`); Goes to (a
  File menu, AGENTS.md or APPEND_SYSTEM.md, noted "On <host>. Nothing is written until you add
  it."); then Add to AGENTS.md (primary, naming the file) and Dismiss (ghost). Either goes back to
  the list; a refusal stays, with its reason. A line added or dismissed elsewhere reads "This line
  was added or dismissed."
