# Command palette, dialogs and sheets

> Read when you change the command palette, a dialog or a sheet.

## Command palette

⌘K (the rebindable `commandPalette`) opens `CommandPaletteView` (`CommandPaletteView.swift`, items
in `ShepherdViewModel+Palette.swift`, matching in `CommandPalette.swift`) through
`.nwCommandPalette(isPresented:)` (NWComposer › Command palette; CommandPalette). It is a jump
surface: every destination and command in it is also in the sidebar or the menus.

- **Placement:** a 620pt `NWPaletteCard` (`.nwPopover()`, radius 12), or the window's width less
  16pt margins, 18% down the window over the 30% `scrim`, and never taller than the window leaves
  room for (at most 14 rows, then the list scrolls; `NWPaletteMetrics.placement`). The card grows
  from its top edge (`overlay`) and the scrim fades (`content`). Clicking the scrim or Esc closes
  it; VoiceOver stays inside it.
- **Search row (44pt):** a 15pt `magnifyingglass` in `textSecondary`, the field in Geist 15
  `textPrimary` with a `lantern` caret ("Search commands, agents, subagents…"), and, trailing, the
  scope control All · Commands · Agents (`NWSegmentedPicker`, small: 20pt; tooltip "Switch scope"
  with ⇥). A hairline divides it from the results, which sit 6pt inside the card.
- **Scopes:** All lists Commands, This thread, and Subagents with no query, and every section once
  there is one; Commands lists Commands and This thread; Agents lists Subagents, Agents, Spaces, and
  Found in conversations, with or without a query.
- **Sections**, in this order, under `NWPaletteSectionHeader` (24pt, mono 10 medium caps, tracked,
  `textTertiary`):
  - **Commands:** New thread ("in <space>/", the project the New thread page last chose, once it
    has chosen one; ⌘N), New agent with options… (⇧⌘T), New space… (⇧⌘N),
    New space on <host>… ("remote", one per connected host), Hide or Show sidebar (⇧⌘S), Settings…
    (⌘,), and Check remote worktree operation (its host) while one is pending. **Not built yet:**
    New mission… (NWComposer; it waits for Missions).
  - **This thread** (the agent on screen): Rename ("<title>", ⌘R), Pin thread or Unpin thread
    (`pin`, `pin.slash`; named for what it does now, no chord; only for a thread the sidebar can pin:
    not an automation's run, and not in the project tree), Choose model… ("<model>", ⇧⌘M),
    Toggle fast mode ("Switch this thread between Standard and Fast", the filled Fast bolt,
    `bolt.fill` through `NWGlyph.fastBolt`, not the automations' outline `bolt`; ComposerSpeed;
    listed only while the thread's model offers a service tier, and it switches the tier as the
    model-settings popover's Speed control would, with no popover), Review diff ("working tree · 4 files", the checkout's changed files as the branch chip counts
    them; ⇧⌘B, the side pane's chord), Review PR changes ("PR #24" once the agent's review has
    found its pull request), and the Terminal menu's commands while a
    thread with a layout is on screen: Show or Hide terminal (⌘J; with none it opens one), New
    terminal (⌘D), and Maximize or Restore terminal (⇧⌘↩, offered only while the thread has a
    terminal), named for what they will do.
  - **Subagents:** each live or recent run: its label, "<parent> · running 37m" ("waiting on parent",
    "done", "failed"; a remote run's parent adds " · <host>"), and `arrow.turn.down.right` in its
    run's state color.
  - **Agents** (with a query, or in the Agents scope): each agent in sidebar order with "<space> ·
    <status>" (running, needs you, idle, done, failed; a working agent adds its time, "running ·
    8m", as its sidebar row counts it), and each remote agent with its host.
  - **Spaces:** the name and its `~/path`.
  - **Found in conversations:** conversation search needs at least 3 characters, runs off the main
    actor 250ms after the last keystroke, and reads the last 512 KB of each agent's pi session. It
    matches only what was said, the user's and the assistant's text, never pi's system prompt, tool
    definitions, thinking, tool calls or results. Its rows (`text.magnifyingglass`, the agent, its
    space) carry a caption line under the title with the match in bold `textPrimary` and the rest
    `textTertiary`; an agent already listed by name is not repeated. A host answers a remote
    client's conversation search the same way.
- **Matching:** a title that starts with the query ranks first, then one with a word that does, then
  one that contains it, then one that holds its letters in order; a match in the context ranks below
  any match in a title. Rows sort by rank within a section; sections keep their order.
- **Rows** (`NWPaletteRow`, the sidebar's row height, radius 6, 8pt side padding): a 13pt stroke
  icon in a 14pt column in `textSecondary`, 10pt, the label in the sidebar row's title font (12.5;
  12 at Compact) in `textPrimary`, dim context in Geist 12 `textTertiary`, and the real shortcut as
  `NWKeycap`s from `KeybindingsStore`. The highlight is `runningTint` with a `running` icon.
  Subagent rows wear their run's state color.
- **Keys:** ↑↓ (and the pointer) move the highlight, ↩ runs it, ⇥ cycles the scope, Esc closes. A
  new query or scope moves the highlight to the top. With nothing to list: "Nothing here yet", or
  "No matches" for a query, in caption tertiary.
- **Motion:** rows arrive, leave, and reorder (`list`), and the card follows their height; the
  highlight moving changes no row, so it lands at once.
- **What it never shows:** footer hints, ⌘1–9 numbering, or any status the sidebar or the thread
  doesn't show.

## Dialogs and sheets

Creation sheets (New Agent, New Worktree, Finalize Worktree, the directory picker, the remote
worktree sheet, the automation editor, the review's Commit…) and every
confirmation share one anatomy, `NWDialog` (`NWDialogMetrics`), flat on `bgWindow`, built from
the Controls and Status & feedback parts (no board draws a Mac dialog). The creation sheets and
Delete Worktree Agent take `.dialogSheetFrame()`: the window is `bgWindow` from the first frame,
and the title stays still while rows disclose.

- **Width:** 460pt by default (`NWDialogMetrics.width`); Rename 420
  (`AppLayout.renameSheetWidth`), Delete Worktree Agent 520 (`confirmSheetWideWidth`), and the
  creation sheets their own (`AppLayout+Settings.swift`: New Agent 560, New Worktree 520,
  Finalize 560, the remote worktree sheet 620, a remote automation 560, the directory picker
  480, Commit… 520).
- **Header:** a 24pt inset (`NWDialogMetrics.inset`) above and at both sides, 12pt below; the
  title in `title`/`textPrimary` (a header to VoiceOver), and 4pt under it an optional
  explanation in `body`/`textSecondary`. Both wrap.
- **Labeled rows** (`NWSheetRow`, aliased `SheetRow`): a 96pt label column in `ui`/
  `textSecondary`, 12pt, then the control filling the rest; 8pt vertical padding, at least 44pt
  (a 28pt control with 8pt above and below), and a hairline underneath from the 24pt inset to
  the trailing edge. `alignment: .firstTextBaseline` for a control that wraps. A read-only value
  (a path, a branch) is `mono`/`textSecondary`, selectable, truncated in the middle with the
  whole value as its tooltip. No form chrome and no grouped boxes.
- **Lists of steps or checks** (`NWChecklistRow`): at least 28pt (`NW.Height.row`): the 14pt
  state glyph (`NWStateGlyph`: spinner, check, cross, ring), 8pt, the label in `ui`
  (`textPrimary` while running or asking, `textSecondary` once done, `failed` when failed,
  `textTertiary` while pending), and a trailing `caption` detail (`textTertiary`, `failed` when
  failed; middle-truncated, the whole as its tooltip). A failed check's remedy discloses
  underneath, indented past the glyph. The glyph pops once when a step passes, and the row
  reads "label, state, detail" to VoiceOver.
- **Footer:** 16pt above, the 24pt inset around: an optional status on the leading edge
  (`NWDialogStatus`: `caption`/`textSecondary`, `failed` for an error, two lines at most,
  selectable: "Checking for unsaved work…", "Creating the worktree…"), and the actions
  trailing, 8pt apart. Actions never truncate; the status wraps instead.
- **Actions** (`DialogAction`): exactly one primary (`.prominent`: `.nw(.primary)`, the ⏎ default);
  Cancel is `.nw(.ghost)` with ⎋, as every board that draws a Cancel has it; any other
  action secondary. A destructive action is the `dangerFill` button (`.destructive`) and never the
  default: destroying things takes a click. While an action runs, its button says so ("Starting…",
  "Creating…") and is disabled.
- **Banners:** anything a destructive action would destroy is called out in an attention
  banner (`DialogBanner`: an `NWBanner` at the 24pt margins, 12pt below what precedes it,
  disclosing when it arrives late); an error is a `failed` banner. Never a system alert.
- **Acting after dismissal:** a confirmation that tears down a mounted layout (Delete Worktree
  Agent, Remove Space, an agent's delete) lets its sheet finish dismissing (300ms) before it
  acts; changing the window under a sheet mid-dismissal wedges the modal session.

New Agent's Model row takes "provider/id" (pi's default, or Settings' default, prefilled in that
form), and its Thinking row follows the composer's model-settings button: it shows only while the chosen
model (blank: the target's default) takes a thinking level, as the target's catalog says. A model
the catalog does not know, or a catalog still loading, keeps it. It offers Off, Minimal, Low, Medium
and High, with Extra high and Max where the target's models.json maps them
(`ModelListing.thinkingLevels`), and Off to High on a host without `thinking.levels.v1`; a chosen
level the model lacks shows (and starts) as the one pi would use. The model suggestions truncate
in the middle, the whole id in each one's tooltip.

**Finalize Worktree** (`FinalizeWorktreeSheet`, 560pt; no board draws it) runs commit → push →
pull request → (merge) → verify clean → remove worktree → delete local branch in one sheet,
titled by phase: "Finalize worktree", "Set up Finalize", "Worktree finalized", "Finalize stopped".

- **Checking:** "Checking prerequisites…", with a spinner and "Checking git, origin and the GitHub
  CLI…" in the footer and Cancel.
- **Set up** (when a check fails): an `NWChecklistRow` per prerequisite (Git installed, Git
  identity, Origin reachable, GitHub CLI, GitHub CLI signed in), each failing row growing its
  remedy (install the command line tools, name and email fields with Apply, "brew install gh"
  with Copy, "Open a terminal for gh login…"), and "Recommended GitHub repo settings"
  (Auto-delete merged branches, Allow auto-merge, each with Enable…). Footer: "All set — ready to
  finalize" once every check passes, then Re-run checks, Cancel, and Continue (primary).
- **Input:** Worktree and Branch rows in mono, Base (a mono field, 200pt at most, with "Will include
  n commits" beside it, in `lanternText` past 20), Title, and Description (a 72pt editor with
  Generate… / Regenerate…, or a spinner and "Generating…"). Footer: Repo setup… on the leading edge,
  Cancel, and Finalize (primary; disabled while the description generates or while the title or the
  base is empty). A checkout another operation holds shows a failed "Finalize can't start yet"
  banner.
- **Running and after:** a checklist row per step ("commit remaining work", "push branch to
  origin", "create pull request", "merge pull request" only when Settings ▸ Worktrees merges
  automatically, "verify nothing is left behind", "remove worktree", "delete local branch"), each
  with its state's glyph (pending, running, done, skipped, failed) and its detail; once done, a
  Pull request row with the URL and Open…, and Done, which closes the sheet and removes the
  agent; after a failure, Close.

`DialogSheet` and `DialogAction` (`DialogSheet.swift`) build a confirmation from that anatomy.
`AppDialogs` (`AppDialogs.swift`) presents the view model's sheets (New Agent, New Worktree,
Finalize, the directory picker and Import existing worktree, renames, deletes, a remote host's
worktree and automation sheets, a failed action), mostly with `sheet(item:)`, so a sheet keeps
the value it opened with while it animates away. The composer presents Stop all, the review
pane its Revert and Commit…, Settings ▸ Advanced its reset, and `QuitConfirmation` the quit
dialog. There is no `.alert`, `confirmationDialog`, or `NSAlert` in the app:

- Rename agent and Rename project (`RenameDialog`, 420pt): one field seeded with the name and
  focused; ⏎ renames, and an empty name cannot. Rename project adds "Display name only. The
  folder name and location stay unchanged.". It is available for registered local parents
  and children in the sidebar menu and Settings context/accessibility actions.
- Delete Worktree Agent (`WorktreeDeleteDialog`, 520pt): "Delete worktree agent", "Stops <agent>.
  “Delete agent and worktree” also removes its checkout and branch.", rows for the Worktree (mono,
  middle-truncated) and the Branch, "Checking for unsaved work…" in the footer while git looks,
  an "Unreconciled work" attention banner ("<what> will be lost with the worktree.") when there
  is some, then Cancel, Delete agent only, and a destructive Delete agent and worktree that stays
  disabled until the check is in
- Remove Project (`SpaceDeleteDialog`): "Remove project", "Removes <project> from the sidebar and
  stops its <n> agent(s). The local folder and all its files are kept. Saved conversations and
  project history remain. Child projects stay registered.", Cancel and a destructive Remove
  project. Count is the selected project's own agents, never its children's. The action keeps
  every folder and saved conversation; only the registration, its own agents/tabs, and live
  sessions are removed. The user's folder-retention requirement applies to parents and children.
- Agent tool calls open no approval modals. Cross-thread calls and deletion act immediately
  after validation, without a permission setting. User-invoked destructive dialogs remain unchanged.
- Stop all (`StopAllDialog`): "Stop the agent and every running subagent?", a live count ("2
  subagents are still running."), Cancel, Stop only the agent, and a destructive Stop all
- The review's Revert (`RevertFileDialog`): "Discard the changes to <path>?", then "The new file
  moves to the Trash." or "The file returns to its last committed version. This cannot be undone
  from Shepherd.", a Repository row (mono, middle-truncated), Cancel and a destructive Discard
  changes. Commit… (`ReviewCommitSheet`) is described with the review pane.
- A failed agent action (`ActionErrorDialog`): "Agent action failed", the error selectable, and
  OK (primary)
- Reset settings (`ResetSettingsDialog`): "Reset settings to defaults?", "Your spaces, agents and
  terminals are not affected.", Cancel and a destructive Reset
- Quitting while agents are working or waiting on you (`QuitDialog`), because quitting stops
  them mid-turn: "Quit and stop every working agent?" ("Quit and stop the working agent?" for
  one), and "<n> agents are still working. Their conversations stay on disk and reopen on next
  launch." It lists the busy agents (five named in `rowCompact` rows, each with its status dot,
  its name in `ui` `textPrimary`, and "working" in `caption` `textTertiary` or "needs you" in
  `lanternText`; "and n more" under them), with Cancel (⎋) and a destructive Quit, so ⏎ never
  quits. `QuitConfirmation` puts it on the main window as a critical sheet, so it shows even over
  another sheet. A closed window is reopened first; if it is not back within a second, the
  dialog opens in a window of its own. While it asks, AppKit disables Quit, so a second ⌘Q does
  nothing. A log out, restart, or shut down quits without asking, and one that begins while the
  dialog is up answers it with Quit.

Git probes and directory listings run off the main thread; the Delete Worktree Agent dialog
keeps its destructive action disabled until the unreconciled-work check is in.

**Bringing over your pi** (`PiImportSheet`, 540pt, 600 for a new user; PiImportProgress,
PiImportDone, PiImportMissing, PiImportNew, PiImportFailed, PiAuthStates): the one onboarding
step, at the first launch of a build that runs its own pi, over the main window. It runs once;
after that the two pis are independent.

- **Anatomy** (every state): a header 22pt in from the top and leading edge (20 trailing): a 38pt
  tile at radius 10 holding the state's glyph (`square.and.arrow.down` on `bgRaised` in a
  `lineStrong` line while it runs and for a new user; `checkmark` on `doneTint`; `key` on
  `lanternTint`; `exclamationmark.triangle` on `failedTint`), then, 14pt after it, the title in
  Geist 17/600 over the subtitle in 13/1.5 `textSecondary`. The body 18pt under it, 22 in. A
  footer on `bgSunken` over a hairline, 14pt above and 16 below its 28pt buttons.
- **The start gate.** Restored agents (and automations) hold their next request until the copy
  is over (`AgentStartQueue`; 30 s at most), each showing "waiting" in the sidebar and Waiting
  to continue at the end of its thread. Then they start, the one on screen first, except: with
  Something missing, the agents whose model uses a provider it asks for keep waiting (the rest
  start); with New user or Failed, or when no provider can start an agent, every one waits. They
  wait until the sheet closes, whichever way. An existing user whose logins came over never
  clicks for the agents those logins cover.
- **In progress**: "Bringing over your pi…", "Once, from `~/.pi/agent`. The pi in your terminal
  isn’t changed." A card (`bgSunken`, radius 10, `lineSubtle`) of `NWImportStepRow`s, one per
  item, 40pt at the least, 6×14 padding, 12 between parts, hairlines between: an 18pt mark, the
  title in Geist 13 over its detail in 12 `textTertiary`, and, once done, a count in mono 11.5
  `textSecondary` trailing. The items: Logins (the subscriptions' names; "3 subscriptions"),
  API keys ("OpenAI, OpenRouter"; "2 keys"), Custom providers ("models.json"; "2 providers"),
  Default model (its id), Trusted folders ("4 folders"), Instructions, skills and prompts
  ("Copied into Shepherd"; "AGENTS.md · 12 · 5"), Extensions ("Listed, switched off"; "3
  found"). Marks: done, a `checkmark` on `doneTint`; now, a `running` ring with a dot and the
  title shimmering (nothing spins); pending, a `lineStrong` ring with the title in
  `textTertiary`; failed, an `xmark` on `failedTint` with the detail in `failed`. An item your pi
  has none of is left out once the copy knows. No footer while it runs, and ⎋ does nothing.
- **Done**: "Your pi is in Shepherd", and the `NWImportSummary` in place of the subtitle: what
  came over in one line, counts in 600 `textPrimary`, the rest `textSecondary`, "·" in
  `textTertiary` between ("**3** logins · **2** API keys · custom providers · default model
  `claude-opus` · **4** trusted folders · instructions, **12** skills, **5** prompts"). The body,
  74pt in (under the title): "Shepherd now runs its own copy of pi. The pi in your terminal is
  untouched." in 13.5 `textPrimary`; then, with extensions, a note card (`bgSunken`, radius 9):
  `puzzlepiece.extension` 13pt, "**3 extensions** came over switched off. They’re code that runs
  with full access, so you turn each one on yourself." and Review extensions (a `running` link
  that closes the sheet and opens Settings ▸ Pi ▸ From your pi). Footer: Done (primary, ⏎; ⎋ too).
- **Something missing**: "Two sign-ins need you" ("A sign-in needs you" for one), "Everything
  else came over. These two didn’t work in Shepherd’s copy of pi, so sign in to them here." A
  card of `NWImportSignInRow`s (10×14, a 28pt badge, the name in 13.5/500 over why in 12
  `textTertiary`, a small button trailing): only providers that still need a sign-in, each with
  Sign in (primary, small), which opens the sign-in sheet over this one; once signed in, the row
  says "Signed in" with a `done` check and its button goes. Under the card the summary in 12
  `textTertiary` with an `info.circle`. Footer: Skip for now (secondary), which closes it and
  leaves those agents Not signed in, and Done (primary, ⏎), enabled once every row is signed in.
  A provider needs a sign-in when an agent restored at this launch or the default model uses it
  and nothing in Shepherd's pi covers it (no login, no key in the environment, no custom
  provider of that name): "Your pi isn't signed in to it" or "Your pi's sign-in couldn't be
  copied".
- **New user** (no pi of theirs): "Sign in to a model provider", "There’s no pi on this Mac, so
  there’s nothing to bring over. Use a subscription you already pay for, or an API key." A
  two-column grid, 8pt apart, of tiles (`NWSignInChoiceTile`: 11×12 padding, radius 10,
  `bgSunken` in `lineSubtle`, a 30pt badge, the name over the plan, a `chevron.right`): the
  subscriptions in Sign-in's order, then Use an API key (a dashed `lineStrong` line, a `key`
  tile, "OpenAI, OpenRouter and 30 more"), whose menu lists the key providers. A tile opens the
  sign-in sheet over this one; a sign-in that lands closes both. Footer: "Change these any time in
  Settings ▸ Pi ▸ Sign-in." in 12 `textTertiary` leading, Skip (ghost) trailing. One already
  signed in, with nothing missing, sees no sheet at all.
- **Failed**: when your pi's `auth.json` can't be read or isn't JSON (the rest still comes over):
  "Couldn’t read your pi’s sign-ins", "Everything else came over. Your file wasn’t changed." A
  `failed` box (radius 9, `failedTint` at half, a `failed` line at a quarter): the file's path in
  mono 12 `textPrimary`, and the parser's reason in mono 11.5 `failed` (never the file's
  contents). "Fix the file and try again, or skip and sign in here instead. Agents that need a
  sign-in wait either way." Then the steps card, Logins and API keys failed ("auth.json isn’t
  valid JSON"). Footer: Show in Finder (ghost, `folder`) leading; Skip (secondary) and Retry
  (primary, ⏎, `arrow.clockwise`), which copies the logins again and, when they come over, turns
  to Done or Something missing.
- Nothing on it shows a credential's value.

**Sign in to <provider>** (`PiSignInSheet`, 500pt; SignInBrowser, SignInDevice, SignInPaste,
SignInKey, SignInPortBusy, PiAuthStates): one sheet, four flows, over Settings or the first
launch's sheet. Shepherd's own pi signs in: a small Node script on the bundled runtime
(`shepherd-sign-in.mjs`) runs pi's own SDK login (`ModelRuntime.login`) against Shepherd's pi
home and passes pi's prompts to the sheet as JSON lines; the credential goes from pi straight
into the home's `auth.json`, and nothing of it crosses to the app. pi's TUI never opens.

- **Header** (every flow): 22pt in, a 38pt badge, then the title "Sign in to Anthropic" in 17/600
  over what it takes ("With your Claude Pro or Max subscription", "With an API key", "Paste a
  code instead of the browser hand-off") in 13 `textSecondary`; a 28pt circular close button
  (`xmark`, `lineStrong` line) trailing, which cancels. Body 18×22, footer as the import
  sheet's.
- **Steps** (`NWSignInStepRow`, in a `bgSunken` card at radius 10, 14×16, 14 apart): a done step
  (`checkmark` on `doneTint`), the live one (a `running` ring and dot, its title shimmering, its
  note under it in 12 `textTertiary`), pending ones (a `lineStrong` ring, `textTertiary`), a
  failed one (`xmark` on `failedTint`, its note the provider's reason).
- **Browser** (Anthropic, OpenAI Codex, Radius): the browser opens at once. "Opened claude.ai in
  your browser" (done) · "Waiting for you in the browser" (live), "Approve Shepherd on claude.ai.
  This closes by itself when you’re done." · "Save the sign-in to Shepherd’s pi" (pending). Under
  the card, "Browser on another computer? Paste a code instead" (a `running` link). Footer: Copy
  link (ghost, `doc.on.doc`) leading; Cancel (ghost, ⎋) and Open browser again (secondary,
  `arrow.up.forward.square`).
  - **Done**: the second step reads "Signed in" ("Signed in as …" only when the provider names
    the account), the third "Saved to Shepherd’s pi" with, when agents were waiting on it, "2
    waiting agents picked up where they left off." Footer: Done (primary, ⏎). A sign-in that
    lands closes a sheet opened from `/login` or an agent's card by itself after a beat.
  - **Failed**: the live step turns failed with the provider's reason, cleaned up (the first
    line, no stack): "claude.ai didn’t allow access", "access_denied · you chose Cancel on
    claude.ai"; the third step reads "Nothing was saved." Footer: Copy details (ghost) leading;
    Close (ghost, ⎋) and Try again (primary, ⏎).
  - **Callback port in use** (the provider's fixed port is taken, checked before the browser
    opens): the card becomes a `failed` box, "Another sign-in is using localhost:1455",
    "Probably Codex CLI or your terminal pi’s /login, mid-way. Finish or cancel it there, then
    try again.", above the two steps, pending; then "Or skip the browser hand-off: sign in on
    chatgpt.com and paste the code it shows." with Paste a code instead. Footer: Cancel and Try
    again (primary).
- **Paste a code** (from the link above, or a port in use): "Paste a code instead of the browser
  hand-off", "After you approve Shepherd, claude.ai shows a code. Paste it here to finish." A
  labelled field ("Code from claude.ai", 11.5/500 `textSecondary`, 6 above a 34pt mono 12.5
  field at radius 8, "Paste the code" as its prompt), focused. A rejected code says so under the
  field in 12 `failed`, in the provider's words ("That code was already used. Open claude.ai
  again for a new one."). Footer: Open claude.ai again (ghost) leading; Cancel and Continue
  (primary, ⏎, enabled with a code).
- **Device code** (GitHub Copilot, xAI, Kimi): "Enter this code at `github.com/login/device`.
  It’s already on your clipboard." Then the code, large (`NWDeviceCode`: mono 26/600 tracked
  12%, centered in a `bgSunken` box at radius 10, 16 high padding), with Copy (ghost, small) and
  Open GitHub (secondary, small) under it; then the live step "Waiting for you to enter the
  code", "The code works until 10:02 AM." Footer: Cancel. Done: the code dims, "Signed in",
  "Copilot · saved to Shepherd’s pi", and Done. GitHub Enterprise isn't offered (departures).
- **API key**: "With an API key". A segmented control (Paste a key · Environment variable), then
  one labelled field: "API key" (a secure mono field; once checked it shows masked) or
  "Variable name" (mono, `$` prefixed, with "Read from your login shell each time an agent
  starts." under it). Typing waits 600 ms, then "Checking the key with DeepSeek" (live, a
  spinner-free shimmer) checks it against the provider with the smallest request pi can make;
  then "Works." with "deepseek-chat and deepseek-reasoner are ready." (`done`), or "DeepSeek
  rejected this key (401 · invalid api key)." in `failed`. Save stays off until a key works; one
  the provider can't be reached to check says "Couldn’t reach DeepSeek to check it." and Save
  turns on (departures). "No key yet? Get one on platform.deepseek.com" (a link, where the
  provider has a page). Footer: Cancel and Save (primary, ⏎). Environment variable saves the
  name (`$DEEPSEEK_API_KEY` in auth.json), never the value.
- **Signing in** shows on the provider's row in Sign-in while the sheet is up (the row's Cancel
  cancels the sheet), and on a Missing row in the first launch's sheet.
- **When a sign-in lands**, every agent of this Mac waiting on "not signed in" for that provider
  (or for none named) starts again at once, and the sheet counts them.
