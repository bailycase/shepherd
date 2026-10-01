# Settings: Instructions

> Read when you change Settings ▸ Instructions or its per-host view.

## Instructions (SettingsInstructions)

The page (`SettingsInstructions.swift`, `InstructionsModel`) edits the two root instruction files
Shepherd hands every agent it starts: `AGENTS.md` ("how you work") and `APPEND_SYSTEM.md` ("rules
that override everything else"). They are Shepherd's own copies, never pi's: they live in
`instructions/` in Shepherd's support directory (`ShepherdPaths.instructionsDirectory`), and the
instructions extension (`shepherd-instructions.ts`) adds them to each session Shepherd starts, so
`~/.pi/agent` is never written, and pi run by hand in a terminal doesn't read them. The page sits
between Pi and Skills in the nav, with `doc.text`. Header: "Instructions", then "The agent’s root
files, read at the start of every session Shepherd starts: `AGENTS.md` for how you work,
`APPEND_SYSTEM.md` for rules that override everything else. Repos can still add their own
AGENTS.md." (file names in mono; see the departures).

- **Same on every host:** a flat card (`NWGroupCard` on `bgWindow`) holding one settings row: "Same
  on every host", under it "Save once; Shepherd writes both files to every host. Offline hosts
  catch up when they're back.", and the switch trailing. On by default, and remembered.
- **Host chips** under it, 8pt apart and wrapping (`InstructionsHostChip`): one per machine, This
  Mac and then each remote host in the sidebar's order. A chip is at least 34pt, radius `m`,
  `NW.Space.l` side padding and 8pt gaps: a 13pt `desktopcomputer` glyph in `textSecondary`, the
  host's name in mono 12.5, a 7pt state dot, and its state word in Geist 11 in the state's color
  (`InstructionsPresentation.hostChip`). With Same on every host on, the chips report the sync and
  pick nothing: This Mac says "synced" once every connected host matches ("not synced" in
  `textTertiary` until then); a host "synced" or "synced 2m ago" (`done`), "differs · 3 lines"
  (`lanternText`), "offline · will sync" or "offline" (`textTertiary`), "needs update" for a host
  whose Shepherd predates Instructions (`textTertiary`), "checking…" (`running`), or "couldn't read"
  (`failed`). The machine whose copy is open (This Mac) is selected: a 1px `textPrimary` line on
  `bgSelected`, its name semibold; the others have a `lineStrong` line on no fill, names at 500.
- **A host that drifted** (an addition): with Same on every host on, connected hosts whose files
  differ from This Mac's (saved there by another client, or kept different before the switch was
  turned on) are named under the chips in the footnote style ("build-01 differs from This Mac.")
  beside a small secondary **Sync now**, which writes This Mac's files there. Any save does the
  same for every host, since it writes both files.
- **File tabs:** `AGENTS.md` and `APPEND_SYSTEM.md` as underline tabs 22pt apart over a
  `lineSubtle` rule. A tab is the file name in mono 13 (semibold `textPrimary` and a 2pt
  `textPrimary` underline when chosen; 500 `textSecondary` otherwise) over a Geist 11.5
  `textTertiary` note of what it is for and its size, live as you type: "how you work · ~640
  tokens", "rules that win · ~90 tokens", "… · empty" (`InstructionsText.sizeNote`: about four
  characters a token, tens past a hundred).
- **The editor**, 12pt under the tabs, filling the column and never under 180pt: a card with a 1px
  `lineStrong` line, radius `m`, on `bgWindow`.
  - Its header (`bgSunken`, a `lineSubtle` rule under it, 8pt × 12pt padding): the file's path in
    mono 12 `textSecondary`, middle-truncated with the whole path on hover
    (`~/Library/Application Support/Shepherd/instructions/AGENTS.md`); "● edited" in Geist 11.5
    `lanternText` while there are unsaved changes; then trailing, 24pt buttons: History and Revert
    (ghost, 12/500 `textSecondary`), and the primary Save, which names where it writes ("Save to 3
    hosts", "Save" when This Mac is the only machine, "Save to build-01" per host) with its ⌘S in
    mono 10.5 at 60% inside the button (lantern fill, `textOnLantern`, 12/600). With nothing
    edited, Save and Revert disable (honest affordances); ⌘S saves while the page is open. Unsaved
    edits are kept per machine and file while Shepherd runs, so switching tabs, hosts or pages
    loses nothing. Undo belongs to the mounted file and host, never the window's shared undo
    stack. Switching documents cannot undo text into the new file, even when their contents
    match; callbacks from an old editor remain bound to its original document.
  - **History** (with Same on every host on; per host the side column lists it) opens a popover on
    `bgRaised`, 380pt wide, scrolling past 340pt: This Mac's saves of the open file as the per-host
    History list draws them. Restore puts a version back as a new save ("Restored the Sep 19
    version"), sent to every host with Same on every host on. A machine keeps the newest 30 saves
    of each file.
  - Its body (`InstructionsEditor`, a TextKit 1 `NSTextView`): the file as plain Markdown text,
    mono 12.5 on 21pt lines, 10pt above and below, with a 34pt gutter of line numbers (mono 10.5,
    `textTertiary`, right-aligned, 12pt before the text), and no smart quotes, dashes or
    corrections. Highlighting is light (`InstructionsText.highlight`): heading markers in
    `textTertiary` and heading text semibold `textPrimary`; list bullets and numbers in
    `lanternText`; code spans in `synString`; everything else `textSecondary`. A line changed since
    the last save is tinted `lanternTint` across the editor (`InstructionsText.changedLines`).
  - A machine whose files can't be shown says why in their place, centered in `caption`
    `textTertiary`: "horizon is offline. Its files show here once it's connected.", "horizon runs
    a Shepherd from before Instructions. Update it there to edit its files from here.", "Reading
    horizon's files…" over a spinner, or "Couldn't read horizon's files: …" with Try again.
  - A save, copy or restore that fails says so under the card (`NWInlineProblem`).
- **How the agent reads them** (the side column, 330pt): five steps in order, each a small card (radius
  `m`, a `lineSubtle` line, `bgRaised`, 8pt × 10pt padding) joined by a 10pt connector (a 1.5pt
  `lineStrong` line 17pt in, under the number column): the step number in mono 10.5 `textTertiary`
  (16pt wide), a title in mono 11.5 semibold (truncating) over a note in Geist 11 `textTertiary`:
  1. "Agent’s system prompt", "built in"
  2. "Shepherd's AGENTS.md", "this file · every repo"
  3. "AGENTS.md in parent folders", "if any"
  4. "the repo's AGENTS.md", "most specific context"
  5. "Shepherd's APPEND_SYSTEM.md", "appended last · wins"

  The open file's step is marked: a `lanternText` line on `lanternTint` (step 2 for `AGENTS.md`,
  step 5 for `APPEND_SYSTEM.md`, whose note then leads with "this file · " instead). Under the
  steps, a 12/1.5 `textTertiary` note: "Later files win. pi's own files in Shepherd's pi home
  still load, each just before Shepherd's. A session reads them when it starts: running agents
  keep the version they started with, new agents and automations get this one." (Shepherd's pi
  home, not the user's `~/.pi/agent`: agents run Shepherd's own pi, docs/pi-home.md.)
- **Where it writes:** This Mac's files are the server's `InstructionsStore` (`AGENTS.md`,
  `APPEND_SYSTEM.md` and `history.json` in `instructions/`); a remote host's are its own store,
  read and saved over the remote protocol (`instructions.v1`: fetch, save, restore). A host that is
  offline when a save goes out is owed both files and takes them when it connects again
  (remembered across launches). A save that arrives from another client shows on the page at once.

## Instructions per host (SettingsInstructionsHosts)

With Same on every host off, each machine keeps its own root files and the page edits one machine
at a time. The explanation reads "Per host: each machine keeps its own root files.", and the
switch's row "Off: each host keeps its own files. Pick a host to edit it."

- **Host chips** pick the machine to edit (the selected chip as above; hover `bgHover`) and report
  how its copy of the open file compares with This Mac's: a `done` dot and no word when they match;
  "differs · 2 lines" (`lanternText` dot and word) when they don't; "kept different"
  (`textTertiary`) once kept; "offline" (`textTertiary`). This Mac's chip, the reference, shows its
  dot alone.
- **Comparing a host that differs:** the editor card's header reads "build-01 compared with This
  Mac" (both names in mono, "compared with" in `textTertiary`, Geist 12.5), with a small segmented
  control (`NWSegmentedPicker` s, 20pt) trailing: Diff · build-01's file. Diff shows the whole file
  as a diff from This Mac's copy to the host's, scrolled to its first difference: mono 12 on 22pt
  lines, a 34pt number gutter 8pt before a 14pt sign column: removed lines `−` in `failed` on
  `failedTint`, added lines `+` in `done` on `doneTint`, context in `textSecondary` with a blank
  sign. "build-01's file" opens that host's file in the editor, with "● edited", Revert and "Save
  to build-01" beside the control.
- **Resolve** (a section label under the editor): three 28pt buttons, wrapping: "Copy This Mac's to
  build-01" and "Copy build-01's to all hosts" (secondary; all hosts includes This Mac), "Keep
  build-01 different" (ghost). Under them a 12/1.5 `textTertiary` note: "A copy replaces AGENTS.md
  there; the version it replaces stays in that host's history. Keep a host different when a line
  only makes sense on it: Shepherd shows the difference once, then stops asking." Keeping is
  remembered by both copies' fingerprint (`InstructionsPresentation.fingerprint`), so a later
  change on either side is flagged again.
- **The side column:**
  - Files on each host: a row per machine, at least 48pt, a hairline above each: a 14pt
    `desktopcomputer` glyph, the name in mono 12.5 semibold over its instructions directory in mono
    10.5 `textTertiary` (middle-truncated); trailing and right-aligned
    (`InstructionsPresentation.hostRow`), when its files last changed in Geist 11.5 ("edited 2m
    ago", "edited Sep 19", "no saves yet"; "last seen 07:12" for an offline host) over a Geist 11
    note: This Mac's files ("AGENTS · APPEND", `textTertiary`), "2 lines differ" (`lanternText`),
    "matches This Mac" or "kept different" (`textTertiary`), or how an offline host last compared
    ("matched This Mac", "1 line differed").
  - The other file's status in one line under its name as a label ("APPEND_SYSTEM.md", then "Same
    on all three hosts.", "Differs on build-01.", or "Same on This Mac and build-01; horizon isn't
    connected." in 12.5 `textSecondary`), once there is a remote host.
  - History · build-01: the chosen machine's saves of the open file, newest first, rows at least
    30pt with a hairline above each: the date in mono `textTertiary` in a 60pt column ("Sep 19", or
    the time for a save today, "14:02"), what changed in 12 `textSecondary` ("Added “Never
    force-push.”", "Synced from This Mac", "Restored the Sep 02 version"), and Restore as a
    trailing `running` text action; the newest reads "current".
