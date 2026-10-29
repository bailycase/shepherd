# Status language and components

> Read when you build a control or a status piece: the shared component inventory and how a status reads.

## Status language

One enum, `AgentState`, drives every status surface (SHStatus), and color always comes with a
word or a glyph's shape: a pill in headers and cards, a dot (with its word where the row has
room) in rows, a glyph in tool rows, steps, and checklists, a spinner for work in progress
outside the thread (in the thread, live text shimmers instead: LiveText), a bar for steps and
budget, and a step strip for a run's steps. The parts are under
Components › Status and feedback.

| Lifecycle | `AgentState` | Sidebar | Composer |
| --- | --- | --- | --- |
| Agent working | `running` | blue dot; elapsed trailing | Stop (the Send button while nothing is typed; Send with input); ↩ waits in Up next; ⌘↩ steers now |
| Agent blocked on a question | `attention` | lantern dot, glowing; "ASK" | the question panel in place of the field |
| A subagent asked its parent | `queued` (waiting, hollow) | none: its agent's row stays as it was | none: its tray row says "asked the parent" |
| Agent done | `done` | green dot | Send |
| Agent done, its turn failed | `failed` | red dot | Send |
| Agent idle | `idle` | hollow ring | Send |
| pi starting | `idle` | hollow ring | Send, which waits for pi; only when pi is slow (two seconds, half a second over a blank thread), "Starting…" beside it |
| Connection lost | `failed` | — | Send, plus a `failed` banner with Reconnect |
| pi can't start | `failed` | red dot; "can't start" in mono 10 `failed` | the Can't start banner with Retry; Send disabled |
| Restored, waiting for your pi to come over | `idle` | `clock` glyph; "waiting" in mono 10 `textTertiary` | Send, which waits; the thread ends in "Waiting to continue" |
| pi not signed in (this Mac) | `attention` | in Needs you: lantern dot, glowing; "sign in" | Send; the thread ends in the Not signed in card |

Subagent runs use the same states on their dots, glyphs, pills, and steps: running, done,
failed, and queued (queued, paused, or waiting on its parent, hollow). A subagent never draws
`attention`: that state is the user's. Tool calls use running, done, and failed.

**Not built yet: stuck.** `AgentState.stuck` marks an agent or run that has been running too
long without progress. Its dot and pill take `failed`'s color and tint and say for how long
("Stuck 14m", SHStatus); where a glyph stands alone it is `exclamationmark.triangle`. Nothing
detects it yet, and the board fixes no threshold.

A turn fails when pi's last reply is a provider error (not a Stop). The thread shows the error
(`SHTurnError`), and the agent's row (an automation's too) and its palette subtitle read failed
until its next turn starts. On iPhone and iPad the thread's header reads Failed from the thread
itself (`NativeThreadStore.lastTurnFailed`): a remote client hears no turn failure from the host.

Agent events that need a sentence are banners inside the pane they concern (Components › Status
and feedback), never a modal alert. Agent tool calls open no approval modals.

**Outside the app** the same language holds. A notification's group follows the state
(`attention` is Needs you, `failed` is Problems, `done` is Finished), and a Live Activity draws
the same dots, glyphs and words. What each notification says, when it is sent, and what the Mac
posts today are in Notifications and Live Activities.

## Components

`Packages/ShepherdUI/Sources/ShepherdUI/Components` is the shared library, by domain, with
`#Preview`s of every component in both appearances in `Previews/`. Use a component before
composing chrome by hand. Debug builds have a **Component Gallery** (View menu,
`ComponentGallery.swift`) that shows the base components in their states.

| Domain | Components | Owned in the app by |
| --- | --- | --- |
| Controls | `.buttonStyle(.sh(_:size:tint:))` (primary, secondary, ghost, danger, dangerFill; s 24 · m 28 · l 32), `.shIcon` and `.shIcon(bordered:isOn:size:tint:)` (a circle, 28pt, 44 on iOS; "on" is lantern tint), `.shLink`, `.shRow(selected:)`, `.shRowBackground(selected:hovering:)`; `.toggleStyle(.shSwitch)` (30×18) and `.shCheckbox` (14pt); `SHSegmentedPicker` (m 24, s 20), `SHPopupMenu` and `SHPopupLabel`, `SHValueSlider`, `SHStepper`; `.textFieldStyle(.sh)` and `.sh(mono:error:)` (28pt, radius 6), `.shField(focused:error:mono:)`, `.shFieldMessage(_:alignment:)`, `.textFieldStyle(.shSearch)`, `SHSearchField`; `SHButtonTitle` (a title and its chord), `SHRadioGroup`; `SHKeycap`, `SHCountBadge`, `SHTag`, `.shHelp(_:shortcut:)` | across the app; `SHRadioGroup` has no app use |
| Status | `SHStatusPill` (20pt, radius 4; a glyph in place of its dot), `SHStatusDot` (6pt), `SHStateGlyph` (14pt), `.progressViewStyle(.shSpinner)` and `.shBar` (4pt), `SHStepStrip`, `SHSparkline`, `SHBanner`, `.shToast(item:)` with `SHToast`, `SHEmptyState`, `.shShimmer()` and `SHLoadingRows`, `SHWordmark`, `SHCrook` | across the app; `SHSparkline` and `.shToast(item:)` have no app use (see departures); `SHLoadingRows` in the directory picker |
| Containers | `SHSectionHeader`, `SHGroupCard`, `SHCardRow`, `SHHairline`, `SHChoiceRow` (`SHChoiceRowMetrics`), `SHFlowLayout`, `SHMarkupText` | `SettingsComponents.swift`; hairlines everywhere; `SHMarkupText` for Settings' descriptions (Mac and iOS); `SHChoiceRow` in the iOS client's New thread pickers; `SHFlowLayout` for wrapping chips and answers (iOS) |
| Navigation | `SHSidebar`, `SHSidebarTopBar`, `SHSidebarDestination`, `SHSidebarSection`, `SHSidebarRow`, `SHSidebarFooter`, `SHDropIndicator`, `SHDensity`; `SHThreadToolbar`, `SHPaneToggle`, `SHOptionsMenu`, `SHPaneHeader`; `.shCommandPalette(isPresented:)`, `SHPaletteCard`, `SHPaletteSearchRow`, `SHPaletteSectionHeader`, `SHPaletteRow` | `SidebarView.swift`, `ThreadHeader.swift`, `RootView.swift`, `CommandPaletteView.swift`; the review's header (`DiffReviewView.swift`) and the inspector's ⋯ menu (`Thread/SubagentInspector.swift`) |
| Thread | `SHUserBubble` (its time shown while `revealed`; `origin: .steered`), `SHQueueDivider`, `SHAgentProse`, `SHCodeBlock`, `SHThinking`, `SHActivityLine`, `SHActivityCalls`, `SHChangesCard`, `SHDiffStat`, `SHInlineCode`, `SHAttachmentChip`, `SHTurnFooter` (shown while `revealed`), `SHTurnError` (card, Details, folded), `SHRetryLine`, `SHJumpToLatest`, `.shShimmer(active:)` (live text) | `Thread/ThreadView.swift`, `ThreadTurns.swift` (with each turn's `MessageHover`), `ThreadTools.swift`, `ThreadMarkdown.swift` |
| Composer | `SHComposer`, `.shComposerChip(active:)`, `SHChipChevron`, `SHComposerActionButton` (Send, Stop, Send's ring), `SHMenuHeader`, `SHSlashMenu`, `SHModelPicker`, `SHModelSettings` (`SHModelSettingsLabel`, `SHComposerBranchLabel`, `SHFastBolt`), `SHSendMenu`, `SHPlaceMenu` and `SHPlaceChipLabel` (the New thread page's workplace); the question dock: `SHQuestionDock` (`SHQuestionDockContent`, `SHQuestionDockMetrics`, `.shQuestionCard()`), `SHQuestionHead`, `SHQuestionDockHidden` (over `SHQuestionHiddenLine`); the queue: `SHQueueStack`, `SHQueueRow`, `SHQueueEditor`, `SHQueueDeletedRow`, `SHQueueMoreRow`, `SHQueueNumber`, `SHQueueGlyph`, `SHGripGlyph`, `SHQueueMetrics` | `Thread/Composer.swift`, `Thread/QuestionDock.swift`, `Thread/QueueStack.swift` |
| Agents | `SHSubagentTray` (`SHSubagentTrayRun`, `SHSubagentTraySummary`, `SHSubagentTrayRow`, `SHSubagentTrayMoreRow`), `SHDockStack`, `SHSubagentRecordLine`, `SHInspectorHeader`, `SHRunBrief`, `SHRunActions`, `SHBranchGlyph`, `SHElapsedText`, `SHDuration`, `SHInlineMarkup`, `.shRunArrival`; touch forms for iOS (the tray's `.pad` and `.phone` sizes, `SHRunCard`, `SHRunHeader`, `SHRunTabs`, `SHSteerField`, …) | `Thread/Subagents.swift`, `Thread/SubagentInspector.swift`, `Thread/SubagentPresentation.swift`; the iOS client |
| Review | The Changes pane: `SHScopeButton`, `SHViewedPill`, `SHCompareRow`, `SHFileStrip`, `SHFileHeader`, `SHViewedCheckbox`, `SHDiffView` over `SHChangesRow`s (`SHDiffLine`, `SHSplitDiffLine`, `SHDiffHatch`, `SHDiffFoldRow`), `SHInlineComment`, `SHCommentEditor`, `SHReviewSendBar`, `SHChangesFileList`, the menus (`SHChangesMenu`, `SHChangesMenuRow`, `SHChangesMenuToggle`, `SHChangesMenuSearch`), `SHDiffMetrics`, `SHChangesMetrics`; the commit form (`SHCommitMessageEditor`, `SHCommitFileRow`, `SHCommitOptionRow`); touch forms for iOS (`SHTouchDiffLine`, `SHSplitDiffRow`, `SHTouchFileStrip`, `SHLineCommentBar`, `SHReviewFileRow`, `SHReviewComposer`, …) | `DiffReviewView.swift`, `ChangesMenus.swift`, `ChangesRows.swift`, `ReviewCommitSheet.swift`; the iOS client |
| Dialogs | `SHDialog` (`SHDialogMetrics`), `SHDialogStatus`, `SHSheetRow`, `SHChecklistRow`, `SHSettingsNavRow` | `DialogSheet.swift`, `AppDialogs.swift`, the sheets, `QuitConfirmation.swift`, `SettingsView.swift` |
| Pi sign-in (`Components/PiSignIn/`) | `SHProviderBadge`, `SHProviderRow` (`SHProviderStatus`, `SHProviderStatusLine`, `SHProviderDot`), `SHProviderMenuButton`, `SHKeySourceLabel` (`SHKeySource`), `SHSharedLoginNote`, `SHReimportRow` (`SHFreshness`), `SHCardLabel`, `SHExtensionRow`, `SHSheetHeader`, `SHSheetSubtitle`, `SHSheetFooter`, `SHSheetCard`, `SHStepMark`, `SHImportStepRow`, `SHImportSummary`, `SHImportSignInRow`, `SHSignInChoiceTile`, `SHSignInStepRow` and `SHSignInSteps`, `SHDeviceCode`, `SHFailureBox`, `SHNoteCard`, `SHFieldLabel`, `SHAgentWaitingLine`, `SHAgentNotSignedInCard`, `SHPiSignInMetrics`; `SHSidebarRow.Leading.waiting` | `SettingsPiSignIn.swift`, `SettingsPiFromYourPi.swift`, `PiImportSheet.swift`, `PiSignInSheet.swift`, `Thread/ThreadView.swift` |
| Automations | `SHAutomationRow` (a row with its switch), `SHAutomationSwitch`, `SHFactRow` and `SHFactText`, `SHAutomationPrompt`, `SHRunBars`, `SHRunRow`, `SHAutomationMetrics`; the Mac's table: `SHAutomationTableRow`, `SHRunOutcome` and `SHRunOutcomeLabel`, `SHAutomationRunLine` | `Pages/AutomationsPage.swift`; the iOS client's `Automations/` |
| Pages | `SHPageHeader`, `SHPageFilterField`, `SHTableColumns` and `SHTableHead`, `.shPageCard()`, `SHPageFact`, `SHPageSectionLabel`, `SHPageQuote`, `SHPageMetrics`; `SHHostPageCard` and `SHHostFact` (`SHHostPageMetrics`, in `Fleet/`) | `Pages/` (the sidebar destinations' pages) |
| Design tool (partly built; `Components/DesignTool/`) | `SHDesignCanvas`, `SHBoardFrame`, `SHSelectionRing`, `SHCommentPin`, `SHBoardActions`, `SHCanvasToolbar`, `SHCommentCard`, `SHCommentThread`, `SHTweakRow`, `SHTokenChip`, `SHTweakScope`, `SHTweakPieceNote`, `SHDesignSystemChip`, `SHTokenSwatch`, `SHExportFormatCard`, `SHLiveLinkField` (see Design tool). Built: the canvas, frames, selection ring, toolbar, system chip, the comment pin, thread and card, the export format card (with `SHExportSheet`), and `SHActivityLine`'s `.drew` and `.checked` kinds | `Thread/ThreadTools.swift` (the activity lines), `DesignScreen.swift`, `DesignExportSheet.swift`, `Thread/ThreadView.swift` (a comment's card in the chat) |
| Missions map (Mac subset in `Pages/MissionMapView.swift`) | `SHMissionMap`, `SHStation`, `SHTerminus`, `SHFlowWire`, `SHDataWire`, `SHForkBar`, `SHJoinBar`, `SHOutcomeChip`, `SHPinRow`, `SHLane`, `SHFog`, `SHFrontierChip` (see Missions: the map) | `MissionMapView.swift` (`MissionGraph`, `MissionNodeView`) implements the Mac map; the listed shared NW parts remain unbuilt |
| Mission screens (Mac subset in `Pages/Mission*View.swift` and `MissionsPage.swift`) | `SHMissionHeader`, `SHPhaseBar`, `SHBudgetMeter`, `SHHostChip`, `SHChoiceCard`, the mission question card, `SHPlannerNote`, `SHAttemptRow`, `SHCheckpointRow`, `SHSpendBar`, `SHTrainCard`, `SHTrainGateRow`, `SHTrainRuleRow`, `SHRepoTimeline`, `SHPathLockRow`, `SHContractRow`, `SHDiffAnnotation`, `SHTraceSpan`, `SHMergeActions`, `SHRollbackRow`, `SHTemplateInput`; iPhone: `SHMissionLiveActivity`, `SHMissionNotification`, `SHLaneStrip`; in `Components/Agents`: `SHMissionNode`, `SHInboxItem`, `SHClaimRow` (see Missions: motion, keyboard and parts to build; Mission components) | Mac Goal, Map, Run, evidence review and Done use native views and existing NW controls; the train, templates, mobile and remaining shared parts are not built |

Rules for every component:

- **Styles on native controls first.** Buttons, toggles, text fields, and progress views are
  styles on the native control, so keyboard and VoiceOver behavior come with it. Where SwiftUI
  has no public style (a segmented or popup picker, a stepper, a slider), the component draws
  its own control and represents itself to accessibility as the native one (see departures).
- **States come from the style**, never from the view that uses it. Hover and pressed fills
  fade on the `hover` motion. The focus ring (`.shFocusRing()`: `focusRing`, 2pt wide, 2pt
  outside the control, following its shape) shows for keyboard focus only, never on a click.
  Disabled is 40% opacity (`shEnabledOpacity`), fading on `hover`, while the label changes at
  once.
- **Icon-only buttons** always carry an accessibility label.
- **Banners** sit inside the pane they concern. Agent events and tool calls never open approval
  modals.

### Controls (SHControls, SHControlsLight)

The light board changes only colors: every measure below holds in both appearances, and every
color is a role.

**Buttons** (`.buttonStyle(.sh(kind, size:))` on a native `Button`):

| Kind | Rest | Hover | Pressed | Use |
| --- | --- | --- | --- | --- |
| `primary` | `lantern` fill, `textOnLantern` semibold | the fill lifted (the board's `#f7b84f` dark, `#eca63a` light) | the fill sunk (`#d9922a`, `#cf8a1c`) | the view's one main action ("Launch") |
| `secondary` | `bgRaised`, 1px `lineStrong`, `textPrimary` medium | `bgSelected` | `bgSelected` | everything else ("Review") |
| `ghost` | no fill or line, `textSecondary` medium | `bgHover`, `textPrimary` | `bgSelected`, `textSecondary` | low emphasis, and Cancel (the board's sample; MXTemplateSave, DZExport, QueueEdit, and PaneArtifactEdit draw Cancel ghost too) |
| `danger` | `bgRaised`, 1px `lineStrong`, `failed` medium | `failedTint` | `bgSelected` | destructive, not yet confirmed (Stop, Revert) |
| `dangerFill` | `failed` fill, white (`textOnFailed`) semibold | unchanged | the fill sunk (`#d24f4b`, `#bf3a35`) | the confirmed destructive action (Delete) |

- **Sizes:** s 24 (8pt side padding, a 12pt label), m 28 (10pt, 12.5), l 32 (14pt, 13), from
  `SH.Height.controlS/M/L`, which never scale with Density. Radius 6 (`SH.Radius.s`). Pressed
  also nudges the button down 0.5pt. On iOS a button keeps its drawn height and grows its hit
  area to 44 (`shTouchTarget`). `tint:` recolors a secondary or ghost label (the review's
  Commit in `done`).
- **Primary appears at most once per view**, and a destructive action is never the ⏎ default.
- **With an icon:** a `Label` ("Fork" with `arrow.branch`, "Re-run" with `arrow.clockwise`),
  the symbol one step smaller than the title and 6pt before it.
- **With a shortcut:** only on the view's main action. The chord is bound (⌘⏎:
  `.keyboardShortcut(.return, modifiers: .command)`) and drawn after the title in Geist Mono
  10.5 regular at 60% opacity, 6pt after it ("Land ⌘⏎", "New agent ⌘N"): the label is
  `SHButtonTitle("Land", chord: "⌘↩")`, and VoiceOver hears the title alone. The Changes pane's
  Send to agent draws ⌘↩ on the Mac (the touch bar has no chord to teach). In a sheet the primary
  is the ⏎ default instead (Dialogs and sheets).

**Icon buttons** (`.buttonStyle(.shIcon)`, `.shIcon(bordered:isOn:size:tint:)`): always a
circle, 28pt (`controlM`; 44 on iOS), the SF Symbol at 14pt medium, monochrome.

- rest: no fill, `textSecondary`; hover: `bgHover`, `textPrimary`; pressed: `bgSelected`
- on: `lanternTint` with the symbol in `lanternText` (the side-pane button while the pane shows,
  however it opened)
- bordered: a 1px `lineStrong` ring (the board's `ellipsis`); focus: the ring as a circle
  (`.shFocusRingCircle()`); disabled: 40%
- The board's set: `sidebar.left`, `square.and.pencil` (hover), a pane toggle (on),
  `ellipsis` (bordered), `xmark` (focus), `paperclip` (disabled).

**Links and rows** (app additions): `.shLink` is inline text that acts ("Show all", "Reset"),
in `caption` and `running` unless given a color, 70% while pressed. `.shRow(selected:)` and
`.shRowBackground(selected:hovering:)` give a row `bgSelected` when selected and `bgHover` while
hovered (while pressed on iOS), radius 6.

**Selection:**

- **Segmented** (`SHSegmentedPicker`): scopes and view modes, 2–4 options ("Local | PR #24",
  "All | Commands | Agents"). A `bgSunken` track, radius 6, with a 1px `lineSubtle` line, 2pt
  padding, and 2pt between segments. Segments are 24pt (m; s is 20) with 10pt side padding (8
  at s) and 12pt labels: medium `textSecondary`, the selected one semibold `textPrimary` on a
  `bgSelected` pill with a 1px `lineStrong` line, radius 4. The pill slides to a new segment on
  the `content` motion (a cross-fade in place under Reduce Motion); disabled dims the segments
  and the pill.
- **Switch** (`.toggleStyle(.shSwitch)`): settings that apply immediately ("Check for
  updates"). A 30×18 capsule, `lantern` on and `lineStrong` off, with a 14pt knob 2pt inside
  (`knobOn` white when on, `knobOff` when off, a small `knobShadow`) that slides on `content`.
  The label, when shown, sits 8pt before it. Settings rows use it through `SettingsSwitch`.
- **Checkbox** (`.toggleStyle(.shCheckbox)`): lists and "done when" checks. 14pt, radius 4:
  off is `bgRaised` with a 1.5pt `lineStrong` border; on is `lantern` with a `textOnLantern`
  checkmark; mixed is `lantern` with a 7×2 `textOnLantern` dash. The label sits 8pt after the
  box, and only the box animates.
- **Radio group** (`SHRadioGroup(_:selection:options:)`; the board's
  `Picker(…).pickerStyle(.radioGroup).tint(.sh.lantern)`): rare; prefer segmented or a popup.
  14pt circles: off `bgRaised` with a 1.5pt `lineStrong` ring, on `lantern` with a 6pt
  `textOnLantern` center; each label (`ui`, `textPrimary`) 8pt after its circle, options 8pt
  apart, and only the circle animates. It draws its own circles, because the system's radio
  ignores the tint, and represents itself to accessibility as a native radio-group `Picker`.
  Nothing in the app needs one yet (the Component Gallery shows it).

**Inputs** (native `TextField`, `Picker`, `Stepper`, and `Slider` in Shepherd Design styles; every
one 28pt, radius 6, on `bgRaised` with a 1px `lineStrong` line):

- **Text field** (`.textFieldStyle(.sh)`, or `.shField(focused:error:mono:)` where the caller
  binds focus): 8pt side padding, 12.5pt text in `textPrimary`, the placeholder in
  `textTertiary`, a `lantern` caret. `mono` (Geist Mono 12) for paths, file names, and ids
  ("shepherd.sock", "~/dev/shepherd"). States: default; focus (the ring 2pt outside); error (the
  line turns `failed`, and the message sits 6pt under the field in `caption` `failed`: "Socket
  path already in use"); disabled (40%). The line and the ring fade on their own layer, so
  focusing never animates the text. Settings fields are 220pt (`AppLayout.settingsFieldWidth`).
  The message is `.shFieldMessage(_:)` (trailing-aligned under a field that ends a Settings row).
  A field whose own value is refused shows it this way: Settings ▸ Remote's port refuses anything
  outside 1–65535 ("Ports run from 1 to 65535."); a problem with a whole setting stays its row's
  problem line (Settings).
- **Search field** (`SHSearchField`; `.textFieldStyle(.shSearch)` for the glass alone): a 13pt
  `magnifyingglass` in `textTertiary` 6pt before the text; the placeholder names what it
  searches ("Search agents", "Search settings"). While empty, the shortcut's keycaps trail
  (⌘F); with text, a clear `xmark` in `textTertiary` takes their place ("Clear search" to
  VoiceOver). `large` is the command palette's 56pt search row, without the chrome.
- **Popup** (`SHPopupMenu`, a native `Menu` whose label is `SHPopupLabel`): longer option lists
  ("claude-opus", "Nightly"). 10pt leading and 8pt trailing padding, the value in 12pt (Geist
  Mono for a model id), and a `chevron.down` in `textTertiary` 8pt after it; 200pt wide (the
  board's; `SHPopupMenu`'s default minimum, and `AppLayout.settingsPopupWidth` in Settings). Its
  items are real menu items.
- **Stepper** (`SHStepper`): small integer settings ("− 3M tok +"). 24pt − and + buttons in
  `textSecondary` either side of the value in Geist Mono 12, at least 52pt wide between 1px
  `lineSubtle` rules. A bound disables its button, and the digits roll (down after −).
- **Slider** (`SHValueSlider`): 200×16, a 3pt `lineStrong` track filled with `lantern` up to a
  14pt `knobOn` knob with a hairline `lineStrong` ring and `knobShadow`. The app adds the value
  in `mono` `textSecondary` 12pt after the track ("105%"); double-clicking it restores the
  neutral value, and ← → step it while it has keyboard focus.

**Small parts:**

- **Keycap** (`SHKeycap("⇧⌘B")`, one cap per key, 3pt apart): at least 18×18 with 4pt side
  padding, Geist Mono 10.5 in `textSecondary` on `bgRaised`, radius 4, a 1px `lineStrong` line
  with a heavier bottom edge (1.5px). Only for a real, wired chord read from
  `KeybindingsStore`; in menus, the palette, Settings, search fields, and empty states (see
  departures), never under the composer.
- **Count badge** (`SHCountBadge(3, tone: .attention)`): a capsule at least 18×16 with 5pt side
  padding, Geist Mono 10 semibold: `neutral` is `textSecondary` on `bgSelected` ("19"),
  `attention` `textOnLantern` on `lantern` (needs you, "3"), `failed` white on `failed` ("1").
  Its digits roll when the count changes.
- **Tag** (`SHTag("worker")`, `SHTag("claude-sonnet", mono: true)`): roles, models, kinds. 18pt,
  6pt side padding, radius 4, `textSecondary` on `bgSelected`, Geist 11 (Geist Mono 10.5 when
  `mono`).
- **Tooltip** (`.shHelp("Review changes", shortcut: "⇧⌘B")`): the label and its shortcut. The
  board draws a 24pt tip after 600ms of hover (8pt side padding, the label at 12, the chord as
  keycaps 8pt after it, `.shPopover` chrome at radius 6); the app renders the system tooltip
  with the chord as text (see departures).

### Status and feedback (SHStatus, SHStatusLight)

Everything that tells you what an agent is doing comes from `AgentState` (Theme model › One
status enum); a view never picks a status color itself. Only `attention` animates: its dot
glows from full to 35% opacity and back over 1.6s, static under Reduce Motion. The light board
changes only colors.

- **Pill** (`SHStatusPill(state)`), in headers and cards: 20pt, radius 4, a 6pt dot and the
  state's word 6pt apart, 6pt leading and 7pt trailing padding, the word in Geist 11.5 medium
  in the state's text color on its tint. Queued and idle have no tint: a 1px `lineStrong` line
  and `textSecondary` words. `label:` replaces the word where the state says more ("Stuck
  14m", "Running · 0:31"), and `symbol:` puts an 11pt SF Symbol in the dot's place (the
  queue's Steering). A new state cross-fades its word and tint; a label that ticks changes at
  once.
- **Dot** (`SHStatusDot(state)`), in rows: 6pt, filled in the state's color. Queued is a hollow 1px
  ring in `textTertiary`; idle is a filled `textTertiary` dot. A row that names the state puts its
  word 8pt after the dot in `textSecondary`. The sidebar's agent rows draw their own dot
  (`SHSidebarRow`), hollow while idle as well as queued, as the Navigation boards do (Sidebar; the
  Status language table's "hollow ring").
- **Glyph** (`SHStateGlyph`, 14pt), in tool rows, steps, and checklists: a spinner while
  running, otherwise the state's symbol in its color; queued and idle are a 1.5pt ring.
- **Spinner** (`ProgressView().progressViewStyle(.shSpinner)`): a tool or turn in progress. A
  13pt three-quarter arc in `running`, about 1.9pt wide, one turn a second, linear; drawn by
  Core Animation (Motion) and static under Reduce Motion.
- **Bar** (`ProgressView(value:).progressViewStyle(.shBar)`, `.shBar(tint:)`): steps and budget.
  4pt, radius 2, on a `lineSubtle` track; the fill is `running` unless tinted with a state's
  color (the board shows running, lantern, and done fills). VoiceOver reads a percentage. The iOS
  run cards and the iOS review's progress (tinted `done`) use it.
- **Step strip** (`SHStepStrip`): one 3pt segment per step, 3pt apart, radius 2, each at least
  14pt and sharing the row. Done, running, and needs-you steps take their colors; pending,
  queued, and idle steps are `lineStrong`. The board draws a mission's steps; the app draws
  subagent runs with it (iOS run cards). VoiceOver reads "n of m
  steps done".
- **Sparkline** (`SHSparkline`): tool calls per minute over the last 10 minutes, 36×12, a
  1.2pt `running` line. The board puts it on running sidebar rows; the app shows elapsed time
  there instead (see departures).

**Banners** (`SHBanner(state, title:message:systemImage:)`) sit inline, inside the pane they
concern: 12pt vertical and 14pt side padding, radius 8, the state's tint (`bgRaised` for queued
and idle) with a 1px `lineSubtle` line. A 15pt icon in the state's color, 2pt down; 12pt after
it the title in Geist 13 semibold (`lanternText` for attention, else `textPrimary`), and 4pt
under that the message in 12.5 `textSecondary` at a 1.5 line height, both selectable. Actions
trail, top-aligned, 6pt apart, as small (24pt) buttons. Accessibility groups the title and
message as one text element and keeps each action a separately labelled button. Default icons:
`exclamationmark.triangle` for attention, failed, and stuck; `checkmark` for done;
`arrow.clockwise` for running; `info.circle` otherwise. The board's four:

- **A question** (attention): "<asker> asks: <question>" ("ios asks: keep MobileTokens as an
  alias?"), the asker's context as the message ("Migrating touches 31 call sites; an alias is
  4 lines but leaves two token systems."), then the answers the asker offered (the first
  primary, the rest secondary) and a ghost **Reply…**. In the app a thread's own question is
  the composer's question panel (Composer); a subagent's goes to its parent, so no surface asks
  you for it, and no surface draws the banner form yet.
- **A repeated failure** (failed): "<what> failed <n> times" ("tests failed 3 times"), a
  diagnosis that says whether retrying helps ("3 snapshot tests fail at Dynamic Type XL.
  Retrying won't help."), and **Open replay** (secondary). **Not built yet:** nothing counts
  repeated failures or diagnoses them, and the board fixes no threshold. Today a failed turn
  shows `SHTurnError` with its tries ("Tried 3 times over 2m") and Retry, and a failed subagent
  card offers Open replay and Re-run.
- **A host reconnecting** (running, `point.topleft.down.to.point.bottomright.curvepath`):
  "<host> reconnecting", "Last seen 3h ago. Remote agents resume when it's back.", and **Retry
  now** (secondary), in the thread of a remote agent whose host went away (`HostAwayBanner`, at the
  top of its layout, as wide as the thread). It shows while Shepherd retries a host that was
  connected earlier this launch (`lastSeen`, never persisted), through every try and wait, and
  its age moves on by itself; Retry now reconnects at once, skipping the backoff. A host that
  never connected this launch keeps "connecting to <host>…", and a failure that won't retry (a
  refused token, another protocol) keeps its own sentence. The sidebar's notice row says the
  same for the host (Sidebar).
- **A mission done** (done, `checkmark`): "Mission done", "Every “done when” check is verified.
  Draft PR #34 is ready.", and **Open review** (secondary). This shared banner is not built;
  the Mac mission workspace has its own PR-publication result banner.

The app's banners today: the composer's "Lost connection to the agent process." (failed, with
Reconnect) and its Can't start banners (failed, with Retry) and a failed attachment, a remote agent's thread while its host reconnects, dialogs' `DialogBanner`s, the commit sheet's, the review's load
error, and the Nightly notice (idle); on iOS, a screen's own failure (commit, review, terminal, New
thread, Automations).

**Transient and empty:**

- **Toast** (`.shToast(item:)` with an `SHToast`): background agent events only ("**worker**
  finished · 5 files", Open). Bottom-trailing, 16pt in, one at a time (a new one replaces the
  current one), gone after 4s, rising from the bottom on the `sheet` motion. 36pt, 12pt leading
  and 8pt trailing padding, a 7pt state dot, then the subject in semibold and the message in
  12.5 `textPrimary` (two lines at most), 10pt apart, and an optional small ghost action that
  also dismisses it; `.shPopover(radius: SH.Radius.m)` chrome. The app posts system
  notifications instead (see departures), so nothing shows one.
- **Empty state** (`SHEmptyState(Text(title), message:)`): one sentence, one or two actions.
  Centered, 28pt vertical padding, 10pt between parts: the 28pt lantern crook (`showsMark`),
  the title in Geist 17 semibold tracked −0.02em in `textPrimary`, the sentence in 12.5
  `textSecondary` at a 1.5 line height and at most 280pt wide, then the actions 6pt apart, 4pt
  further down. The board's: "No agents on watch", "Start one here, or pick a repo and let a
  mission plan the work.", **New agent** (primary, ⌘N) and **New mission** (secondary; not
  built, Missions). `framed` draws a dashed `lineStrong` border at radius 8 (the empty
  thread, which also hides the crook with `showsMark: false`). The app's copy is under Empty
  workspace and Thread.
- **Loading placeholder** (`SHLoadingRows`, pulsing with `.shShimmer()`; the board's
  `.redacted(reason: .placeholder).shShimmer()`): a remote host's list while it loads. Four rows
  of `SH.Height.row` (28pt), each a 6pt dot and an 8pt-tall bar (radius 4) in `bgSelected`, 10pt
  apart, the bars at 70%, 52%, 64%, and 40% of the width. The block pulses between 55% and full
  opacity over 1.4s (`shimmer`), static under Reduce Motion and while hidden (`shMotionPaused`),
  and reads "Loading" to VoiceOver. The directory picker shows it while a host's first listing is
  on its way (the footer says "Loading…"); a remote agent's thread keeps its own placeholder and
  banner (A host reconnecting, above).
