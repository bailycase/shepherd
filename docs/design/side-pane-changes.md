# Side pane: Changes and the subagent inspector

> Read when you change the Changes pane, a diff, a review comment, or the subagent inspector.

One pane per window beside the agent's layout (`RightPaneSplit` around the whole layout in
`AgentLayoutView`, its tabs in `SidePaneView`; PaneStates, the Changes boards, Subagents, SubagentsDone). It
sits at the workspace's trailing edge beside the thread and its terminal panel, at its full
height, and the dock rule measures the main column, never the thread alone. Its sizes and
adaptive rule are in "Window and adaptive layout" above. It shows only the tabs Shepherd has:
**Changes**, the Changes pane, and **Browser** (Side pane: Browser, below) for a local thread and
for a remote thread whose host carries Browser tunnels (an older host: Changes alone). Artifacts and Files are
specified below and are not built, so they have no tab and no placeholder (the user's decision,
2026-09-25: "dont show browser, artifacts, files, etc, only show the things we have"); each joins
`SidePaneTab` when it is. A tray row, a record line, and the footer's "3 subagents" open the
inspector; the tray's Steer opens it with its Steer field focused.

- **Showing and hiding:** ⇧⌘B, the header's side-pane button, or View › Show Side Pane / Hide Side
  Pane. Showing opens the pane on its tab (Changes starts the review); hiding also closes an
  inspected subagent, and discards the review like a cancel. ⌃1 (View › Changes) shows Changes in
  front of an inspected subagent, and ⌃2 (View › Browser) the Browser (a remote thread on a host without tunnels beeps);
  they are fixed, like ⌘1–9, and ⌃3–⌃4 wait for the other tabs.
  Review Changes (a sidebar row's menu), the palette's Review diff, the chip's Show Changes, a
  thread's "review ›" link and the inspector's file links show Changes too.
- **Nothing opens by itself** (PaneStates): when pi opens something for the pane (today, an
  agent's `review_diff`), the review is readied and the Changes tab takes a 6pt `running` dot
  after its count. The pane never opens, and never switches tabs or covers an inspected subagent,
  on its own. While the strip is out of sight (the pane closed, or a subagent inspected over it)
  the header's button takes the dot instead, and a tip hangs under it for 4 seconds and again
  while the button is hovered (`NWPaneNewsTip`: "Agent opened a review in Changes" in `caption` with
  a 12pt glyph and the ⇧⌘B keycaps, on `bgRaised` at radius 12 with the popover shadow). Showing
  the tab clears its dot; a request while Changes is on screen just reloads it.
- **The tab strip** (`NWSidePaneTabs`; SidePaneTabs): 44pt so it lines up with the toolbar, on
  `bgWindow` with a hairline beneath, 10pt side padding, tabs 2pt apart. A tab is 28pt, padding
  0×10, radius 6, 6pt gaps: a 14pt glyph, the label in `ui` medium `textSecondary`, the count in
  `micro` regular `textTertiary` (Changes: the review's files, once loaded), and pi's dot. The
  current tab has the `bgSelected` fill, `textPrimary`, semibold; a tab's tooltip has its ⌃ chord.
  Then a spacer, the pane's ⋯ menu and close ("Hide side pane" with ⇧⌘B), 28pt `nwIcon`s 4pt
  apart; while the pane is maximized (ChangesWide), Restore the thread (a bordered 28pt circle)
  comes before ⋯. **Narrow:** under 480pt the labels drop (padding 0×9); glyphs, counts and dots
  stay.
- **The ⋯ menu** (`SidePaneOptions`, "Pane options"): the current tab's items (Changes: Maximize
  Pane or Restore the Thread, a divider, Expand All Files, Collapse All Files, a divider, Copy Review
  as Text; Browser offers none of its own: the console's chevron shows or hides it), a divider,
  then Reset Width (disabled at the default). Split below, Open pane in its own window and Show
  tabs are left out until they can work (see the departures).
- **The subagent inspector takes the pane over** (Subagents, SubagentsDone) with its own header
  in place of the strip, whichever path inspects a run (⌘I, a tray row or card, the palette).
  Closing it goes back to the tab underneath when the pane was open, and hides the pane when it
  wasn't. The header's button stays lit while it shows.
- **Layout:** the thread keeps running beside the pane. A pane never replaces the thread and
  never changes the persisted layout. The sidebar keeps its width. The pane slides in from the
  trailing edge (`.pane`); when the inspector and a tab swap, or a new review replaces one, its
  content cross-fades (`.content`) while the pane stays put. Stepping between runs is the
  inspector's own motion (below).

**Subagent inspector** (`Thread/SubagentInspector.swift`):

- **`NWInspectorHeader`** (NWAgents), 44pt to line up with the toolbar (`AppLayout.headerHeight`),
  12pt leading and 6pt trailing padding, a hairline beneath: the branch glyph at 13pt in the run's
  state color, then "name · k of n" (the name in Geist 13 semibold, " · 3 of 3" regular
  `textSecondary`; the position only with more than one sibling) over a Geist Mono 10.5
  `textTertiary` line: "model · thinking high · 78 turns · 922k tok" while live, "model · 11
  turns · done 11:02" once finished, the last part in the state's color; the full line is its
  tooltip. A run that has left the list reads "no longer listed". Trailing, 4pt apart:
  Pause/Continue (secondary `s`, with the card's tooltip) and Stop (danger `s`) for a live run (a
  run waiting on its parent has Stop alone: nothing runs to pause, and Stop closes its question),
  ‹ › (28pt `nwIcon`, "Previous subagent", "Next subagent", disabled at the ends) to step through
  siblings, a ⋯ menu (`NWOptionsMenu` "Inspector options": Refresh Transcript while live; Copy
  Transcript and Show Session File in Finder once finished), and close ("Close the inspector").
- **Stepping runs:** inspecting another run swaps it in place, whichever path chose it (‹ ›, a
  card, a strip step, the palette): a sibling nudges in from the side it sits on in spawn order
  (`.list`), any other run cross-fades. Each run starts fresh: its transcript, draft and scroll.
- **`NWRunBrief`** (NWAgents) on `bgSunken`, padding 10×12, 8pt gaps: GOAL (Geist Mono 10, caps,
  0.5pt tracking, `textTertiary`), with "step n / m · 62%" trailing in Geist Mono 10.5
  `textTertiary` while live; the goal in `ui` `textSecondary`, up to six lines, selectable. Once
  finished, RESULT with its label in the state's color and the result in `ui` `textPrimary` as
  inline Markdown (up to eight lines; a failed run's exit reason). A run that asked its parent shows
  its question there instead, under "Asked the parent" (the question as inline Markdown, then "It
  offered: …" with the answers it gave): to read, never to answer. Under it, up to five touched
  files as `running` links in Geist Mono 11, truncated in the middle, each with its diff stat
  (Geist Mono 11): a link opens the review pane at the file ("Review this file"), or reveals it
  in Finder where there is no review. Then "n more files" in Geist Mono 11 `textTertiary`.
- **The run's own transcript**, drawn with the thread's components one step smaller
  (`nwProseSize` `.small`), 14pt padding, turns 16pt apart, times and footers on hover as in the
  thread. A live transcript opens at its end and follows; a finished one opens at its start. A
  live one ends in what the run is doing now (LiveText; `nativeRunLive`, `RunLiveTail`): its call
  in flight as a live activity line ("Building swift build --target ShepherdRemote 11s", from the
  call the run reports; its session file holds only finished calls, so there are no output
  lines). Between calls nothing shows (no "Thinking…" there, and no "Pause requested"), nor while
  it asks or once it has ended. It continues the last turn, under its lines at their spacing
  (`RunLiveTail.gap`), not a turn apart. Its transcript's own thinking is never live. Turns that arrive while it
  follows fade in where they land. With nothing yet it says "No transcript yet." (or "This run is
  no longer listed.") in `caption` `textTertiary`.
- **Its footer line** (28pt, Geist 11 `textTertiary`, 14pt side padding): "72 earlier turns" in
  mono with a Show all link ("Loading…" while it pages) when older turns are not loaded, and
  trailing "Following live" (or "Reading earlier output") while the run is live. Scrolling up
  stops following; scrolling back to the end resumes it.
  - A finished run's whole transcript (SubagentsDone) reads its position instead: "turn 4 of 11"
    in mono (the run's turns, one per reply of the model as the header counts them, up to the
    first reply at or after the topmost turn on screen; `SubagentPresentation.position`), with
    "Scroll for the rest" trailing while there is more below.
- **A Steer composer** while the run is live (Subagents; a run waiting on its parent is live, and
  its Steer is you speaking over the parent): the composer card's anatomy on
  `bgRaised`, radius 8, a `lineStrong` line (`textTertiary` with a 3pt `bgSelected` ring while
  focused), set in 10pt from the top and 12pt from the sides, under a hairline. The field ("Steer
  <name> — delivered before its next turn", the placeholder in `textTertiary`) is `body`, one to
  six lines; ⏎ sends, ⇧⏎ adds a line.
  Beneath it "to: <name> · not the parent" in Geist Mono 11 `textTertiary` and a primary `m`
  Steer, disabled while the draft is empty. A failed send keeps the draft, and the store's notice
  shows under the card in `caption` `textTertiary`.
- **A finished run is read-only:** messages from the parent are captioned "from parent" ("10:58 ·
  from parent" while hovered; your own steers are not), and `NWRunActions` (padding 10×12, a
  hairline above) replaces the composer: Re-run (secondary `s`), Fork (secondary `s` with the
  branch glyph; "Forking…" while it runs, disabled without a session file, tooltip "Fork as a new
  agent with this run's transcript") and Copy transcript (ghost `s`; it loads every page first,
  and says "Couldn't load the full transcript. Nothing was copied." if it can't). A failed fork
  says why under the bar. Remote agents have no Fork.
  - "kept with the thread" in Geist Mono 11 `textTertiary` trails the bar (`NWRunActions`'
    trailing slot; SubagentsDone): the run stays browsable from the thread's record.

**Changes** (the Changes pane: ChangesSplit, ChangesScope, ChangesBase, ChangesUnified,
ChangesLastTurn, ChangesWide and ChangesStates; `ReviewPane` in `DiffReviewView.swift`, state in
`DiffReview.swift`, rows in `ChangesRows.swift`, menus in `ChangesMenus.swift`; parts in
`Components/Review/ChangesToolbar.swift`, `ChangesMenu.swift`, `DiffLines.swift`,
`FileHeader.swift`, `FileStrip.swift`, `InlineComment.swift`). It reads the host's Changes engine
(docs/changes.md): this Mac's `server.changes`, or a remote host's `changes*` queries
(`changes.v1`). Pick what to compare, see it side by side, tick files off, comment on lines, then
send the review.

- **What it compares** (the scope): Branch for a worktree agent with a base, else Uncommitted,
  until the engine's overview names its default; Last turn once the agent has replied to a review
  you sent (the reply's turn settling turns an open pane to Last turn, and a pane opened later
  starts there), unless you picked a scope meanwhile. A card's Review opens the pane on that turn.
- **Toolbar** (`ChangesToolbar`, 44pt, 12pt leading and 10pt trailing padding, 10pt gaps, a
  hairline beneath): the scope button (`NWScopeButton`: 28pt, radius 7, a `lineStrong` line on
  `bgRaised`, the scope's glyph, its name in `ui` semibold, a chevron; ⌘E), the scope's diff stat
  in `code` mono; then "2/5 viewed" (`NWViewedPill`: 24pt capsule on `bgSunken`, an eye, the count
  in mono 11.5, `caption` `textSecondary`), **Commit…** (secondary `s` with the commit glyph), and
  four 28pt `nwIcon` circles 2pt apart: Refresh, Collapse all (Expand all when every file is
  folded), the split toggle (it shows the layout it switches to; ⌥U) and Diff options. A narrow
  pane drops the viewed count, then Commit…'s label. Commit… opens the commit sheet where the host
  commits from review, and otherwise asks the agent to commit; it works on the working tree, so it
  is off for Last turn, Staged, Commits and Pull request.
- **Compare row** (`NWCompareRow`, 32pt on `bgBase`, 12pt sides, 8pt gaps, a hairline beneath):
  head → base in `mono` (the head `textSecondary`, the base `textPrimary`), the base a 22pt picker
  with a chevron on Branch, and "merge base 3f2a91c" trailing in mono 10.5 `textTertiary`. On a
  turn it reads "The agent’s last turn" (12 `textSecondary`, with the turn glyph) and "3:07–3:11 PM
  · after “Wrap errors with context”" in mono 11 `textTertiary` ("since 3:07 PM" while it runs).
  An older host's review reads "Working tree → HEAD", led by the directory when it is not the
  agent's own.
- **Scope menu** (ScopeMenu, `NWChangesMenu` 320pt): Last turn ("What the agent changed since your
  last message"), then Uncommitted, Unstaged and Staged (the last two without a glyph), then
  Commits (its count and a chevron to the Commits menu), Branch ("agent/refund-events vs
  origin/main") and Pull request ("#31 draft"). Each row carries its scope's diff stat from the
  overview, the current one a check; a scope the engine can't compare is dimmed with its reason as
  its second line. Until the overview lands (it asks gh for the pull request) a spinner says
  "Counting each scope…". An older host's menu offers Uncommitted and Pull request.
- **Menus** (`NWChangesMenu`, ChangesMenu.swift): popovers at radius 12 with 6pt padding and the
  popover shadow, 30pt rows (40pt with a subtitle, in 11 `textTertiary`) at radius 6, a 13pt glyph
  9pt from the title in `ui`, trailing a diff stat in mono 11, a tag in mono 10.5 `textTertiary`, a
  check or a chevron; hovering fills `bgHover`, and the row whose submenu is open keeps
  `bgSelected`. Section titles are mono 10 uppercase `textTertiary` (24pt); dividers are hairlines
  with 4pt above and below. They hang from their control; a click anywhere else or esc closes them.
- **Commits menu** (CommitsMenu, 360pt, beside Commits): "On agent/refund-events", All commits on
  the branch, then the branch's commits newest first with "a1c9f2e · 12m", and "Pick two with ⇧
  to see the range between them." A click compares one commit; ⇧-click marks one end and a
  second ⇧-click the other.
- **Base picker** (BasePicker, 316pt, under the base): a 32pt search field ("Search branches"),
  "Compare against", then the default base, recents, and every branch by its last commit (the
  checked-out one left out), mono titles with "default" or "worktree" tags and the current base
  checked; then A commit… (the branch's commits, to compare against one) and The PR's base with
  its ref. ⏎ picks the first match. A pick joins the repository's recents.
- **Diff options** (DiffOptions, 300pt, under More): "Diff", then Word diffs, Hide whitespace
  changes and Load full files ("Expand past folds without a round trip") as switches that leave
  the menu open (the last two load the diff again; Hide whitespace changes also drops a file whose
  only changes are whitespace, as `git diff -w` does, the user's call on 2026-09-25), then Copy git apply command (the patch in a
  `git apply --3way` here-document), Copy as patch, and Open in your editor (⇧⌘O, the current
  file; local reviews). Word diffs and Load full files start on. A patch a remote host had to cut
  is not copied, and says so. **Not built yet:** Rich preview (the engine has no file contents to
  render).
- **File strip** (`NWFileStrip`, 38pt: 26pt chips 2pt apart inside 8pt sides, on `bgBase`, a
  hairline beneath, scrolling sideways lazily): the status letter (M `lantern`, A `done`, D
  `failed`, R `running`; mono 10.5 bold), the name in `mono` (`textPrimary` selected,
  `textSecondary` otherwise, `textTertiary` with a `done` check once viewed) and its diff stat in
  mono 10.5, a new file's too; the full path is its tooltip. The selected chip's `bgSelected` fill
  slides to the next (at once for keys; a cross-fade under Reduce Motion), and a 6pt `running` dot
  marks a file the agent is editing now. **Not built yet:** ⌘1–9 to jump to a file (ChangesStates):
  those chords select agents.
- **File headers** (`NWFileHeader`, 36pt on `bgRaised` between hairlines, pinned while their file
  scrolls, and while at the top of the list casting a short shadow onto the rows under it
  (`nwPinnedBackground`: ChangesSplit's 0 6 12 −8 black at 60%, as the popover's shadow color at
  radius 6, 6pt down); 10pt leading and 8pt trailing padding, 8pt gaps): a 9pt fold chevron, the status letter
  (mono 11 bold), the path in `code` (the directory `textTertiary`, the name semibold
  `textPrimary`, truncated at the head), the file's diff stat in mono 11; then **Viewed**
  (`NWViewedCheckbox`: a 14pt box, radius 4, a 1.5pt `lineStrong` line, lantern with a check once
  ticked and popping as it is; `caption` `textSecondary`; ticking folds the file; V), Comment on the
  file, and Open in your editor (26pt circles). Its context menu: Show Whole File, Revert File…
  (Uncommitted on this Mac only: confirmed with `RevertFileDialog`), Copy Path. A click makes the
  file current. A binary file shows "Binary file" in `caption` `textTertiary`, and one the engine
  cut at 20,000 lines ends with "The rest of this file is left out: it is too long to show."
- **Split** (ChangesSplit, `NWSplitDiffLine`, the pane at 900pt and up until you pick): each side
  a 3pt gutter bar (`done` or `failed` on a changed line, clear otherwise), its line number in a
  34pt gutter (mono 10.5 `textTertiary`, right-aligned, 8pt in), then the code in `code`; a 1px
  `lineSubtle` rule between the halves. Unchanged lines sit beside themselves; a run of removals
  pairs line for line with the additions after it, and the longer side's extra lines face filler
  hatched in `lineSubtle` diagonals 7pt apart (`NWDiffHatch`), so rows line up.
- **Unified** (ChangesUnified, `NWDiffLine`): the gutter bar, the old and new numbers, a 16pt sign
  (+ `done`, a true minus `failed`) and the code. Lines are 21pt (× density), never wrapped.
  Unified diffs scroll horizontally to expose long lines. In split view, each file's old and
  new code columns scroll independently inside their fixed half-width containers. Horizontal
  wheel input affects the column under the pointer; each side also has its own native scrollbar
  below the file. Numbers, center divider, headers and comments stay fixed. One shared vertical
  scroll keeps old/new pairs aligned. The split content and headers fit that scroll view's
  viewport, excluding the vertical scrollbar when the Mac is set to show scrollbars Always.
  Source widths are cached per file and text scale. Removals sit on `failedTint` and additions on
  `doneTint`; with Word diffs on, a paired line's changed words take a second layer of the same
  tint (`DiffWords`, computed with the syntax colors once per file off the main thread).
- **Folds** (FoldRow, `NWDiffFoldRow`, 26pt on `bgSunken` between hairlines): unchanged lines
  between hunks, and in a whole file every run more than three lines from a change (four at
  least), fold to "28 unmodified lines" in `caption` `textTertiary` (`textSecondary` hovered) after
  a 37pt column of reveal arrows: up shows the 20 lines at the fold's bottom edge, down the 20 at
  its top (a fold at the top of the file has only up, one at its end only down), and the label shows
  all of them. Lines between hunks came without the diff: opening their fold fetches the file whole
  from the same revision first (Load full files brings every file whole to begin with).
- **Comments:** hovering a line shows an 18pt lantern `+` in a slot that is always laid out, and
  double-clicking the line (or C, on the current change's first changed line) comments. The
  comment sits under its row, 6pt down, 40pt in, 12pt from the edge, between hairlines: a
  `bgRaised` card with a `lineStrong` line, radius 8, padding 8×10 (`NWInlineComment`): a 16pt
  lantern avatar with the account name's initial, "You" in `caption` semibold, "line 103 · just
  now" in mono 10.5 `textSecondary`, and Edit (Delete joins it on hover); the comment in `ui`,
  selectable. The editor (`NWCommentEditor`) is that card with a lantern line and a 3pt
  `lanternTint` ring: the field ("Comment for the agent on this line"), then "on line 103" in mono
  10.5 `textTertiary`, Cancel (ghost `s`) and Add comment (secondary `s`). ⏎ saves, ⇧⏎ adds a line,
  Esc cancels, and saving an empty comment removes it. Comment on the file puts the same card under
  the file's header ("file · just now"). Comments follow their lines when a file is fetched again
  or the scope changes, by side, number and text.
- **Send bar** (ReviewSendBar, `NWReviewSendBar`, 48pt on `bgRaised` under a `lineStrong` line,
  14pt leading and 10pt trailing padding): only while there are unsent comments. "**1 comment** on
  outbox.go, not sent yet" (or "on 2 files") in `ui`, then Discard (ghost `s`) and **Send to agent**
  (primary `s`, ⌘↩). There is no overall comment: anything else is said in the thread. Sending
  makes the comments the agent's next message (queued if it is mid-turn), under the scope they
  were written against ("Diff review (Branch · vs main):"); once the send succeeds the comments
  clear and the pane stays, and the agent's reply turns it to Last turn. A failed send keeps them.
- **Maximized** (ChangesWide): the pane's ⋯ menu has Maximize Pane; the pane then covers the
  thread (hidden, never unmounted) and the tab strip gains Restore the thread (a bordered circle
  before ⋯). The strip gives way to a 260pt file list (`NWChangesFileList`): "5 FILES" with the
  scope's stat over 46pt rows at radius 6 (the status letter; the name in `code` semibold over its
  directory in mono 10.5 `textTertiary`; the stat over a `running` comment count or a `done`
  check), the current file on `bgSelected`. The pane then takes the whole window: a 52pt rail
  (`NWSidePaneRail`) replaces the sidebar and the toolbar, on `bgBase` with a `lineStrong` edge,
  holding the window controls stacked at its top (12pt circles 6pt apart, 14pt down; Shepherd draws
  them, `NWWindowControls`, and hides the window's own while the rail shows; none in full screen)
  and, 28pt under them (a 10pt gap, an 8pt spacer, a 10pt gap), Back to the thread (a 32pt bordered circle with `text.bubble`), which
  restores the pane beside the thread as Restore the thread does. Hidden layouts keep the column's
  size meanwhile, so only the visible layout relays out.
- **Commit… sheet** (`ReviewCommitSheet`, 520pt, from the toolbar's Commit…; derived from the
  iPadCommit board; parts in `Components/Review/CommitForm.swift`): "Commit n files" over "On <branch> in <repository>."
  - Titles: "Commit n files" (or "Commit"), "Committing…" while it runs, "Committed" or "Pull
    request opened" when done, "Commit stopped" when a step fails. While it reads the checkout
    the subtitle and the footer say "Reading the checkout…" (a spinner in the footer); running,
    the subtitle is "Each step must succeed before the next runs. Nothing is ever
    force-pushed.", and after a failure "A step failed, so the rest didn't run."
  - The message card (`NWCommitMessageEditor`, a raised card with a strong line): the summary in
    semibold over the description, both editable, each growing to its lines whenever its text
    changes (typed, or filled in by the host), and a note: "Drafted from the diff · edit
    anything" (a sparkle), "Written from the file list · edit anything", or a spinner with
    "Drafting from the diff…". The plain message shows at once and follows the ticked files
    until someone edits it; the drafted one replaces it only if nothing was typed meanwhile.
    Drafting follows Settings ▸ Worktrees ▸ Generate PR descriptions and its model.
  - A message nobody edited follows the ticks. The plain one is rewritten at once. A drafted one
    is drafted again for the ticked files once they stay put for 600 ms, so ticking several
    files costs one draft; the old draft stays (spinner, and Commit waits with "Redrafting the
    message…") until the new one arrives. An answer for earlier ticks is dropped, and a failed
    draft puts the plain message for the ticked files in its place. An edited message is never
    rewritten: once a file it was written for is unticked, its note reads "May mention files you
    unticked" (an exclamation circle, as quiet as the other notes).
  - "Files" with "n of m" and Select All/None, then a card of `NWCommitFileRow`s (a row-high
    checkbox row: lantern checkbox, the name in mono, its directory in tertiary, the diff stat;
    the whole row toggles). Every file starts ticked; the list scrolls past 232pt.
  - A card of two `NWCommitOptionRow`s: **Push after commit** over the upstream in mono
    ("origin/main", or "origin/feat · sets upstream"), and **Open a pull request instead** over
    what it does ("pushes feat, opens a PR into main", or "creates shepherd/<slug>, opens a PR
    into main" on the default branch). The PR option turns the push on and disables its switch;
    an option with nowhere to go is disabled.
  - An agent still working puts an attention banner ("The agent is working": its files may
    still change, and Shepherd commits them as they were when the sheet opened and stops if one
    changed) above the message and a "Commit while it works" checkbox that Commit waits for. A
    checkout the host refuses (detached HEAD, a merge or rebase in progress, unmerged paths) is a
    failed "Can't commit here" banner over the disabled form ("Can't commit from here", alone,
    when the host can't commit at all); a refused commit comes back as a failed "Nothing was
    committed" banner.
  - While the steps run, an answer that never came is an attention "Outcome not yet known"
    banner under them.
  - Footer: why Commit waits (caption), then Ask Agent to Commit (ghost), Cancel (⎋), and the
    primary: **Commit**, **Commit & push** or **Commit & open PR** (⏎).
  - Running, the body becomes the host's steps as `NWChecklistRow`s (check the checkout, create
    branch, commit n files, push to …, open a pull request into …) with each one's detail, a
    failed "Stopped" banner saying what was kept, then Open Pull Request and Done. Close while it
    runs leaves it running; Commit… shows it again. A finished commit reloads the review.
- **States:** "Loading the diff…" in `caption` `textTertiary` beside a 12pt spinner; "No changes"
  (`NWEmptyState` without the crook) with the scope's sentence ("The working tree matches HEAD.",
  "This branch matches main.", "The agent’s turn changed no files."); a scope with nothing to
  compare ("No turn yet.", not a repository) as "Nothing to compare"; and anything else as a
  `failed` `NWBanner`, 12pt in. Loading, the diff, "No changes" and an error cross-fade, as does one
  scope's diff for another; a reload of the same scope changes in place.
- **Following the agent:** a turn that ends, an Undo and a Redo reload a working-tree scope and
  Last turn. Refresh reloads by hand. Reads never wait on git: the engine runs off the server queue
  and the main thread, and a list and its files land together.
- **Keys** (ChangesStates › Keys, while the pane has focus and no comment is being written): J / K
  the next and previous file, N / P the next and previous change, V viewed, C comment on the
  current change, ⌥U split or unified, ⌘E the scope menu, ⇧⌘O open the current file in your
  editor, ⌘↩ send; Esc closes a menu, then returns to the thread's composer. Keyboard moves land at
  once.
- **Repository changes:** only per-file Revert (above), Commit… (the commit sheet) and a card's
  Undo and Redo (Thread › Changes card) touch a repository; the engine's reads leave the index,
  HEAD, refs and every file alone (docs/changes.md).

A review an agent opens (`review_diff`) is the host's view state; remote viewers open their own
with ⇧⌘B. An agent may point its review at another repository or worktree (`cwd`); a new target
starts the review over (comments, viewed marks, folds), and asking again reloads it in place,
marking the tab again while it is out of sight. A `review_diff` naming a git reference other than
the pull request (and a review from a host without `changes.v1`) loads that diff the old way under
the same chrome, its scope menu offering Uncommitted and Pull request. Hiding the pane discards its
review.
