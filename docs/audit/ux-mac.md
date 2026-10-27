> Lane report from the 2026-10-27 audit. Static reading only (no build, no run) by a Claude (opus-5-5, ui-ux-engineer profile) agent; line numbers are from commit d28f3511c. Live confirmation of overlapping items is in [live-usage-mac-ios.md](live-usage-mac-ios.md); the cross-lane ranking is in [README.md](README.md).

# Shepherd Mac UX audit (lane: UM)

Scope: `Sources/ShepherdApp` views and view-model glue, `Packages/ShepherdUI`. I only read the code: no build, no run. Line numbers are from the checkout at audit time.

## Summary

The UI layer is in good shape. Icon-only buttons carry accessibility labels, the sidebar and thread are lazy, there are no `ObservableObject`s, motion goes through `shAnimation`, and preferences persist. The serious UX problems are about **safety and feedback**, not looks. Destructive actions are guarded the wrong way round: deleting an agent on ⇧⌘W has no confirmation and no undo, while deleting a design has both. Every error, whatever it is, shows in one modal titled "Agent action failed" with raw `String(describing:)` text. Notifications go quiet for the selected agent whenever any page, including Settings, covers it.

---

## High impact

### UM-01 · high · ⇧⌘W deletes the selected agent at once: no confirmation, no undo
- **Evidence:** `Keybindings.swift:123` (`deleteAgent` = ⇧⌘W), `AppCommands.swift:261-263`. `ShepherdViewModel+Workspace.swift:341-349`: `deleteSelectedAgent` calls `deleteAgent` directly unless the agent is a worktree agent. `SidebarView.swift:198` (context menu "Delete Agent", no ellipsis, no dialog). `SessionServer.swift:5605-5644` removes the agent and its tabs, kills every process in its layout, and drops `keptStarts` (the opening prompt).
- **What the user sees:** ⇧⌘W is "Close Window" in every Mac app and sits next to ⌘W (Close Terminal, `Keybindings.swift:122`). One reflexive press kills a running agent mid-turn and removes the thread from the sidebar. The pi session file may stay on disk, but nothing in the UI can bring it back.
- **Why it's bad:** it's the most destructive action in the app, it has the most-misfired chord, and it has zero friction. Designs get both a confirmation and an undo toast (UM-04), so the app already knows how to do this.
- **Smallest fix:** reuse the design pattern of delete followed by an undo toast. The server keeps the agent record for N seconds (as `DesignDeletion.undoUntil` does), or the toast re-creates the agent from its `piSessionID` (Fork already does this, `ShepherdViewModel+AgentMenu.swift:18-37`). Until then, at least route non-worktree deletes of a **working** agent through a `DialogSheet` like `WorktreeDeleteDialog`. Also consider dropping the default chord, or moving it to ⌘⌫ (Finder's "Move to Trash" idiom).

### UM-02 · high · Every failure shows as a blocking modal titled "Agent action failed", often as raw Swift error dumps
- **Evidence:** `DialogSheet.swift:226-231` hardcodes the title "Agent action failed". `AppDialogs.swift:127-128` presents it from the single `remoteActionError: String?`. There are 65 assignments; 16 are bare `String(describing: error)` (e.g. `ShepherdViewModel+Workspace.swift:391,405`, `+Terminal.swift:140`, `+ThreadMove.swift:74`, `+Creation.swift:89`, `+Review.swift:136,148,235`, `WorkspaceView.swift:988`, `+TerminalControl.swift:75,81`, `+Spaces.swift:153`). Other callers interpolate `\(error)` (`+DesignLifecycle.swift:122,165,178`, `+Automations.swift:274`).
- **What the user sees:** a modal sheet titled "Agent action failed" for things that are not agent actions ("Couldn't export <design>", "Couldn't add the space on …", "Could not revert …"). The body can read like `noSuchAgent(ShepherdCore.AgentID(rawValue: "…"))`. Informational messages are modal too, e.g. "“X” has no transcript yet. Nothing was copied." (`+AgentMenu.swift:52`). It's a single slot, so a second error overwrites the first before it's read.
- **Why it's bad:** a generic title plus an unreadable body leaves the user with no way to recover. A blocking modal for a non-blocking failure interrupts flow, and errors get lost.
- **Smallest fix:** give `remoteActionError` a title (a `struct ActionError { title, message }`) and have callers pass "Couldn't fork", "Couldn't revert", and so on. Add one `ActionError.describe(_ error:)` that prefers `LocalizedError.errorDescription`, then `ChangesError.message`, then a plain sentence. Show informational lines (nothing to copy) as a toast; `DesignToastLayer` already exists.

### UM-03 · high · Notifications are suppressed for the selected agent while a page or Settings covers it
- **Evidence:** `ShepherdViewModel+Notifications.swift:12-19`: `isWatching(.agent(id))` is `NSApp.isActive && selectedAgentID == id`. `openDestination` (`ShepherdViewModel+Navigation.swift:150-162`) and Settings (`RootView.swift:114`, an in-window overlay) never clear `selectedAgentID`. Only the *remote* selection is cleared. Every "turn finished", "turn failed" and question banner checks `isWatching` (`+Notifications.swift:37,43,71,86`).
- **What the user sees:** start a long task, open Settings, Automations, Designs or the New thread page to do something else. The agent finishes or asks a question, and no banner appears, because the app thinks you are looking at it. A question asked in that state never posts later either: `localAsks.update` has already consumed it.
- **Smallest fix:** in `isWatching`, add `destination == nil && !showSettings && !showComponentGallery` (and `!isSidePaneWide`, if the pane covers the thread) to the `.agent` and `.remote` arms.

### UM-04 · medium-high · Destructive actions are guarded inconsistently, often the wrong way round
- **Evidence:**
  - Design delete: a confirmation dialog (`AppDialogs.swift:106-109`, `DesignLifecycleViews.swift:45-70`) **and** an undo toast (`+DesignLifecycle.swift:290-325`).
  - Agent delete: neither (UM-01).
  - Automation delete: neither, and failure is silent: `try? await server.removeAutomation(id)` (`+Automations.swift:200-210`). Reached from `SidebarView.swift:180` and `Pages/AutomationsPage.swift:111`.
  - Space remove: confirmation (`AppDialogs.swift:290-317`), although it's mostly reversible (the folder and history are kept).
  - Terminal close (⌘W): kills the running process with no prompt; remote failure is just a beep (`+Terminal.swift:108-121`).
- **What the user sees:** friction where an undo would do, and none where data is lost. An automation's prompt, schedule and settings vanish on one misclick.
- **Smallest fix:** one rule: undoable means act then toast, irreversible means confirm. Drop the design confirmation (the undo is enough). Add undo or confirmation to automation delete and surface its error. Confirm ⌘W only when the PTY has a foreground child that isn't the shell (as Terminal.app does).

### UM-05 · medium · ⇧Tab in a focused composer cycles thinking level, which traps keyboard focus
- **Evidence:** `Keybindings.swift:140` (`cycleThinkingLevel` = ⇧Tab). `Composer.swift:1575-1601`: `CycleThinkingShortcut` installs a key monitor whenever the composer is focused and the model has more than one level. It is also used on the New thread and New design pages.
- **What the user sees:** keyboard and VoiceOver users can't Shift-Tab backwards out of the composer, the main text field of the app. Pressing it silently changes a setting that affects cost and latency, with only a chip label changing as feedback.
- **Smallest fix:** default the chord to ⌥⇧T or ⌃⇧. (anything that isn't focus traversal), keep it rebindable, and announce the new level (`AccessibilityNotification.Announcement`).

### UM-06 · medium · Many agent actions exist only in a right-click context menu
- **Evidence:** `SidebarView.swift:183-198` offers Fork from Here, Copy Transcript, Pin, Move to…, Review Changes, Open in Finder and Finalize Worktree…. The Agent menu (`AppCommands.swift:231-263`) has only Focus, Rename, Stop, Model, Inspect, Turns, Next/Prev, Delete. The palette (`ShepherdViewModel+Palette.swift:62-83`) adds Pin and Review but no Fork, Copy Transcript, Finder or Finalize. Sidebar rows are tap gestures (`SidebarView.swift:309-315`) and can't take keyboard focus, so you can't reach a row's context menu without a pointer (VoiceOver's actions menu does work).
- **What the user sees:** Fork and Copy Transcript are undiscoverable unless you right-click, and can't be reached from the keyboard at all.
- **Smallest fix:** add those items to the Agent menu (acting on the selection) and as `thisThread` palette rows. Both route to existing `vm.forkAgent`, `copyAgentTranscript`, `openAgentInFinder` and `beginFinalizeWorktree`.

### UM-07 · medium · Thread / agent / space / project are named inconsistently across surfaces
- **Evidence:**
  - Same action, different nouns: File menu "New Thread" and "New Agent with Options…" (`AppCommands.swift:113-115`); keybinding titles "New Thread", "New Agent with Options…", "Rename Agent…", "Delete Agent" (`Keybindings.swift:44-54`); palette "New thread", "New agent with options…" (`+Palette.swift:18-31`), and its placeholder says "Search commands, agents, subagents…" (`CommandPaletteView.swift:49`); empty thread "New agent in ~/…" (`ThreadView.swift:537`); Agent menu.
  - Settings section `.projects` is titled "Spaces" (`SettingsView.swift:272`), while "Projects" is a separate feature (`NewProjectSheet.swift`, "Open Project Settings" in `SidebarView.swift:167`).
  - The branch-picker error says "Couldn't read this project's branches." about a space (`WorktreeBasePicker.swift:65`).
  - Space rename is labelled "Rename…" (`NewThreadPage.swift:463`), "Rename Space…" (`SidebarProjectsView.swift:255`) and "Rename space…" (palette `:25`).
  - "Fork from Here" (`SidebarView.swift:187`) forks the whole conversation (`+AgentMenu.swift:15-17`), not from a point.
- **What the user sees:** it's unclear whether a thread and an agent are the same thing, and whether "project" means a folder or the Projects feature.
- **Smallest fix:** pick "thread" for the user-facing conversation (the boards already say "New thread"). Rename `ShortcutAction.title` and the menu, palette and empty-state strings to match. Fix the `WorktreeBasePicker` copy to "this space's". Rename "Fork from Here" to "Fork Thread".

### UM-08 · medium · Optimistic edits that fail to persist revert silently
- **Evidence:** `ShepherdViewModel+Workspace.swift:136-156`: `enqueuePersistence` catches, `NSLog`s, then `reconcileFromServer()`. Used for agent rename, rename space, move project, hide/show project and layout update (`grep enqueuePersistence("`).
- **What the user sees:** a rename or sidebar reorder snaps back with no explanation (disk full, state.json write refused).
- **Smallest fix:** keep the silent path for the exit-cleanup descriptions, and set a short toast or `remoteActionError` for user-initiated ones (pass a `userVisible: Bool`).

### UM-09 · medium · Unsent composer drafts are memory-only
- **Evidence:** `NativeThreadStore.draft` (`Sources/ShepherdRemote/NativeThreadStore.swift:137`) is a plain `var`. `NativeThreadStores.prune` (`NativeThreadStores.swift:55-58`) drops it with the store. Nothing writes it to defaults or disk. The quit dialog promises conversations "stay on disk and reopen" (`QuitConfirmation.swift:41-42`).
- **What the user sees:** a long prompt typed into a thread is lost on quit, crash or update relaunch. Switching agents keeps it (the deck keeps stores), so the loss on quit is unexpected.
- **Smallest fix:** persist non-empty drafts keyed by `AgentID` in `UserDefaults` (debounced on `draftChanged`), restore them in `NativeThreadStores.store(for:)`, and clear them on send.

### UM-10 · medium · ⌘↑ / ⌘↓ / ⌥⌘↑ / ⌥⌘↓ are app chords that also mean caret movement in the composer
- **Evidence:** `Keybindings.swift:119-120,132-133` (next/previous agent, next/previous turn) are app-scope menu key equivalents. The composer is a multi-line NSTextView, where ⌘↑ and ⌘↓ normally move to the start and end of the document.
- **What the user sees:** in a long draft, ⌘↑ switches to another agent instead of jumping to the top of the text. This needs a runtime check: if the menu wins, it's a real trap; if the text view wins, the chords are dead while typing.
- **Smallest fix:** when the composer has focus and the draft has more than one line, let the text view take ⌘↑/⌘↓ (the `ComposerKeyMonitor` pattern already exists), or default agent navigation to ⌃⌘↑/↓.

---

## Medium impact

### UM-11 · medium · Rename is a modal sheet everywhere
- **Evidence:** `AppDialogs.swift:70-125`: agent, remote agent, terminal tab, space, design and design-system rename all use `RenameDialog` in a `.sheet`.
- **What the user sees:** a window-modal sheet for a one-field edit of a row the user is already looking at. Mac sidebars rename inline (Finder, Mail, Xcode).
- **Smallest fix:** inline-edit the `SHSidebarRow` title on ⌘R or a double-click (a `TextField` swap in the row). Keep the sheet for the remote and palette paths if needed.

### UM-12 · medium · Command palette says "No matches" while transcript search is still running
- **Evidence:** `CommandPaletteView.swift:112-113` shows "No matches" when the rows are empty. Content search starts after a 250 ms debounce and then an async scan (`:168-176`), and its rows appear later with no progress indicator.
- **What the user sees:** "No matches" flashes, then results pop in, which makes the result list feel unreliable.
- **Smallest fix:** keep `contentSearchTask != nil` as `searching`, and show "Searching conversations…" (or the existing `shSpinner`) instead of "No matches" while it's true.

### UM-13 · medium · The palette rebuilds every item on each view-model change, with an O(n²) agent lookup
- **Evidence:** `CommandPaletteView.swift:20` reads `vm.paletteItems`, a computed property (`+Palette.swift:13-139`), in `body`. Inside, `for id in localRecentsOrder { state.agents.first { $0.id == id } }` (`:120-121`) is O(agents²). Remote children and the `remoteHosts.connections.first` lookups add more.
- **What the user sees:** with a busy fleet (state adopts on every status report), typing in ⌘K can stutter. This breaks the "don't filter in body" rule.
- **Smallest fix:** build an `[AgentID: Agent]` dictionary once at the top of `paletteItems`. Better, snapshot the items into `@State` when the palette opens and refresh on `state` revision, not on every observation tick.

### UM-14 · medium · ThreadView filters and maps the whole transcript on every stream chunk
- **Evidence:** `Thread/ThreadView.swift:110` (`store.rows.filter` for project threads), `:115` (`rows.last(where: \.live)`), `:124` (`rows.map(\.id)` into `arrivals.update`). The body re-runs per streamed chunk.
- **What the user sees:** long project or worker threads cost more CPU per token as they grow (perf lanes should measure). Ordinary threads skip the filter but still map every ID.
- **Smallest fix:** have `NativeThreadStore` publish `rowIDs` and `liveRowID` once per revision, and pass the arrival signature (count, first, last) instead of the full array, since `update` only uses those plus `lastIndex(of:)`.

### UM-15 · medium · Sheet dismissal relies on fixed 300 ms sleeps before the real action
- **Evidence:** `AppDialogs.swift:262-266` (`WorktreeDeleteDialog.confirm`), `:309-314` (Remove space), `FinalizeWorktreeSheet.swift:332,456`, `SkillsSheets.swift:281`. There are 82 literal `.milliseconds()` or `.seconds()` sleeps in `Sources/ShepherdApp`.
- **What the user sees:** a visible pause after confirming, and a race on slow machines or with Reduce Motion (the sheet's dismiss duration differs).
- **Smallest fix:** run the mutation from `.sheet(item:onDismiss:)`, which fires after dismissal, instead of a guessed delay. Name any sleep that has to stay in `AppLayout` (the rule already forbids literal durations).

### UM-16 · medium · There are no notification preferences in the app
- **Evidence:** the `SettingsSection` cases (`SettingsView.swift:262`) have no notification section. `AppSettings.swift` has no notification keys. Every unattended ordinary thread posts "Turn finished" (`AgentBanners.swift:124-138`).
- **What the user sees:** with 20 agents, a banner on every finished turn. The only control is all-or-nothing in macOS System Settings. You can't keep questions and failures but mute finished turns.
- **Smallest fix:** one `AppSettings.notifyOnTurnFinished: Bool` (default on) checked in `AgentBanners.status`'s success arm, plus a toggle in Settings ▸ Agents. Questions and failures stay on.

### UM-17 · medium · The automation delete error is swallowed, and Edit/Delete are disabled without a reason
- **Evidence:** `+Automations.swift:205-209` (`try?`, then `adoptCanonical`). `Pages/AutomationsPage.swift:109-111`: `.disabled(!row.canEdit)`, where `canEdit` is false both while busy and for project-owned automations (`AutomationsPageModel.swift:117,183`).
- **What the user sees:** a delete that does nothing, or greyed-out menu items with no idea why.
- **Smallest fix:** surface the error. Add a disabled reason line, as `DesignMenuItems` already does with `item.disabledReason` (`DesignLifecycleViews.swift:20-29`).

---

## Polish

### UM-18 · low · The Space menu's empty state is a dead item
- **Evidence:** `AppCommands.swift:212-215` shows a disabled `Button("No Spaces") {}`.
- **Smallest fix:** add `Button("New Space…") { vm.addSpaceFromPanel() }` beneath it, so the empty state offers the next step.

### UM-19 · low · The "Review diff" palette row advertises the wrong chord
- **Evidence:** `+Palette.swift:78-80` shows `keys.display(.toggleRightPane)` (⇧⌘B). The row runs `openUserReview()` → `selectSidePaneTab(.changes)` (`+Review.swift:63-66`), but ⇧⌘B *toggles* the pane on its last tab (`+RightPane.swift:122-125`) and can close it.
- **Smallest fix:** show the Changes tab's ⌃digit (`SidePaneTab.changes.digit`, `AppCommands.swift:169-173`).

### UM-20 · low · "Organize Sidebar By" fakes checkmarks with a `Label` icon
- **Evidence:** `AppCommands.swift:152-164` draws `Label(style.title, systemImage: "checkmark")` for the current style.
- **What the user sees:** the checkmark sits in the icon column, not the state column, and VoiceOver doesn't announce "checked".
- **Smallest fix:** `Picker("Organize Sidebar By", selection:) { … }.pickerStyle(.inline)`. Apply the same fix to `AppearanceCommands` if it uses the same pattern.

### UM-21 · low · Settings code still carries a stale doc comment and a debugging hook
- **Evidence:** `SettingsWindow.swift:5-12` says Settings is a `Window` scene, then that it's in-window. `:18-30` NSLogs every toggle "settings has been observed opening without a deliberate ⌘,".
- **What the user sees:** an unexplained Settings pop-open (a known open bug, judging by the hook).
- **Smallest fix:** delete the stale paragraph, then track the bug down or remove the log.

### UM-22 · low · Copy Transcript and Copy Path give no confirmation
- **Evidence:** `+AgentMenu.swift:43-56` reads the session file asynchronously, then writes the pasteboard silently. `+SidebarProjects.swift:156-158` does the same.
- **What the user sees:** no sign of whether the copy happened, which matters for a large transcript that takes time.
- **Smallest fix:** a short "Copied" toast, reusing the `DesignToast` pattern.

### UM-23 · low · Fork ignores the user's default thinking level
- **Evidence:** `+AgentMenu.swift:29` uses `thinking: source.agent.thinkingLevel ?? .medium`. `AppSettings.defaultThinking` exists (`AppSettings.swift:170`).
- **Smallest fix:** `?? settings.defaultThinking`.

### UM-24 · low · ⌘W beeps when there is no terminal
- **Evidence:** `+Workspace.swift:185-203` and `+Terminal.swift:108-121` beep when nothing can close. The menu item is always "Close Terminal".
- **What the user sees:** a Mac user expects ⌘W to close the window, and gets a beep.
- **Smallest fix:** disable "Close Terminal" when the visible thread has no terminal tab, so the window's own ⌘W can apply (or make it fall through).

### UM-25 · low · Font-size and dimension literals bypass the tokens
- **Evidence:** `DesignRulesAllowlist.swift` still lists **290 raw font sizes across 56 files**. The biggest are `ShepherdUI/Components/Thread/Activity.swift` (20), `Composer/ContextMeter.swift` (19), `Review/ChangesToolbar.swift` (18), `Browser/Browser.swift` (18), `Navigation/Sidebar.swift` (13). Examples include `TerminalPanel.swift:230` `.system(size: 8…)` and `PiSignIn/SheetParts.swift:48` `.shSans(12…)`. The design-rules scan doesn't cover `.frame(width: N)`, `.padding(N)`, `cornerRadius: N` or `.opacity(0.N)` literals (about 177 sites, e.g. `LineCommentBar.swift:63` `.opacity(hasText ? 1 : 0.35)`).
- **What the user sees:** inconsistent type sizes between surfaces, and no Dynamic Type or density scaling for these.
- **Smallest fix:** keep burning down the allowlist file by file. Optionally add a `rawOpacity` rule for UI-state opacities (disabled looks), which should be one token.

### UM-26 · low · TimelineViews refresh coarse ages while idle
- **Evidence:** `ArtifactsTab.swift:37` and `WorkspaceView.swift:1110` refresh every 60 s, `SettingsInstructions.swift:31` every 30 s, `SettingsExperiments.swift:24` every 60 s.
- **Impact:** small, but it's idle work on screens nobody is looking at. Gate them on `scenePhase == .active` if profiling shows them.

---

## Top 10 to fix first

1. **UM-01**: undo (or a confirmation for working agents) on Delete Agent, and move it off ⇧⌘W.
2. **UM-03**: make `isWatching` false while a page or Settings covers the thread. It's a one-line fix for silently missed questions.
3. **UM-02**: give errors a title, readable `describe(error)` text, and use a toast for informational messages.
4. **UM-04**: one guard policy (undo vs. confirm). Add undo and error handling to automation delete; drop the double guard on designs.
5. **UM-05**: take ⇧Tab back for focus traversal.
6. **UM-09**: persist composer drafts across relaunch.
7. **UM-06**: put Fork, Copy Transcript, Open in Finder and Finalize in the Agent menu and the palette.
8. **UM-07**: settle on "thread" vs "agent" and "space" vs "project" in the strings.
9. **UM-08**: surface failed renames and reorders instead of silently reverting.
10. **UM-12 / UM-13**: show a "Searching…" state in the palette, and stop rebuilding its items in an O(n²) way in `body`.

---

## Already good (don't re-fix)

- **No `ObservableObject`, `@Published` or `@StateObject`** anywhere in `ShepherdApp` or `ShepherdUI`.
- **Accessibility labels on icon-only buttons are nearly complete.** I scripted a check of every `Button` whose label is just an `Image`, and spot-checked about 40: all carry `.accessibilityLabel`, often with a toggle value and trait (`FilesTab.swift:238-252`). Sidebar rows add `.isButton`, an `accessibilityAction` and `.isSelected` (`SidebarView.swift:131-134,309-315`). Hidden deck layouts are removed from the accessibility tree (`AgentLayoutDeck.swift:105-107`, `WorkspaceView.swift:423-425`).
- **Sidebar is a LazyVStack of `Equatable` rows** with a single view per element (`SidebarView.swift:94-140`). Activity sparklines are stored and not computed in rows.
- **Motion goes through `shAnimation` / `withSHAnimation`.** I found no raw `withAnimation(.easeInOut…)` in views.
- **Preferences persist:** sidebar hidden, collapsed sections and projects, pins (`ShepherdViewModel.swift:236-258`), right-pane width (`RightPaneSplit.swift:10`), terminal height (`TerminalPanels.swift:42-61`), and Files word wrap / markdown preview (`AppSettings.swift:347-352`).
- **Dangerous git operations are guarded well:** the worktree delete probes for unreconciled work off-main and keeps the destructive button disabled until the probe answers (`AppDialogs.swift:195-268`). File revert in Changes is confirmed (`DiffReviewView.swift:17`). Stop All asks only when more than one subagent is running (`Composer.swift:909-910`).
- **Artifacts tab** has full loading, empty, unavailable and failed (with retry) states (`ArtifactsTab.swift:27-112`).
- **Notification hygiene:** one identifier per agent replaces banners rather than stacking them, and banners are grouped by target. Answered questions and deleted agents' banners are taken down (`+Notifications.swift:76-123`).
- **Dialog keyboard:** Cancel is `.cancelAction` and the prominent button is `.defaultAction` (`DialogSheet.swift:79-91`). The rename dialog focuses its field.
- **Menu state** is a snapshot (`MenuStateSync`, `AppCommands.swift:70`), so the menus don't re-evaluate the view model on every change.

## Needs runtime confirmation

1. **UM-10:** in a multi-line composer draft, does ⌘↑/⌘↓ switch agents or move the caret? The same question applies to ⌥⌘↑/↓.
2. **UM-03:** open Settings or Automations with an agent selected, let it finish or ask a question with the app active, and check that no banner appears.
3. **UM-05:** with VoiceOver or Full Keyboard Access, does ⇧Tab from the composer move focus or cycle the thinking level?
4. Does a sidebar row's context menu (Fork, Copy) open from the keyboard (VO-Shift-M, or Full Keyboard Access)? Rows aren't focusable (`sidebarTapRow`).
5. Under a destination page or the Settings overlay, does the thread beneath stay out of the Tab order and the VoiceOver rotor? `AgentLayoutDeck` hides *other* layouts, but the visible one under the overlay isn't `accessibilityHidden` (`RootView.swift:78-83,114-117`).
6. **UM-15:** with Reduce Motion on, or on a slow machine, does the 300 ms delay race the sheet dismissal (the "wedged modal session" the comments describe)?
7. **UM-01:** after a deletion, is the pi session file kept on disk? This decides whether an undo can be built purely client-side.
8. The "Settings opened without ⌘," bug that `SettingsCommandButton` logs (`SettingsWindow.swift:18-30`). Check whether it still reproduces.
9. **UM-13 / UM-14:** profile palette typing and thread streaming at 200+ agents and in 2k-row threads before changing the code.
10. **UM-26:** check whether ArtifactsTab and Settings timelines keep ticking while the app is in the background.
