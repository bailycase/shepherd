# Design specs

> Read when you build or change a surface. [DESIGN.md](../../DESIGN.md) holds the rules every UI change obeys; this folder holds each surface's spec.

**Precedence.** The design the user gives in the thread (an image, a board, a design
reference) comes first. Then the board or the canvas. Then these specs. Then the rules in
DESIGN.md. If a design disagrees with a spec here, build the design, update the spec in the
same change, and tell the user every place you could not match it. A departure from a design
is the user's call, never yours. The design image is saved in [boards/](boards/README.md) with the
change that builds it, and every difference you kept is listed under Departures in the PR body
([docs/design-workflow.md](../design-workflow.md)).

**Find a spec.** Do not read this index through: find the board with `--boards | grep -i <word>`
and print only its sections.

```sh
python3 scripts/design_section.py --boards | grep -i composer   # which boards touch the composer
python3 scripts/design_section.py ComposerSpeed          # a board: its status and the blocks it names
python3 scripts/design_section.py "Up next"              # a heading
python3 scripts/design_section.py "Composer, questions, and menus › The card"   # a block inside it
python3 scripts/design_section.py ComposerSpeed --full   # every line, not the narrowed block or outline
python3 scripts/design_section.py --list                 # the files and what each is for
```

A block over 250 lines prints as an outline of its parts; read one with a path as above.

**Reading a spec.**

- A rule names its board in parentheses, for example (NWFoundations).
- A spec marked **Not built yet.** is a design for later: build it to that spec when asked,
  and skip it when working on shipped UI.
- The places Shepherd deliberately departs from the boards are in
  [departures.md](departures.md); any other difference between the app and a spec is a gap to
  fix ([known-gaps.md](known-gaps.md)).
- Every value lives in code, and the specs name the code: tokens and shared components in
  `Packages/ShepherdUI` (module `ShepherdUI`), the Mac app's own surface dimensions in
  `AppLayout`, split by domain into `Sources/ShepherdApp/AppLayout+<Domain>.swift`.
- The design canvas, "Shepherd chat UI", has the pages macOS, iOS, iPadOS, Notifications,
  Missions, Design tool and Design system · Night Watch. The last is **Night Watch**,
  Shepherd's design system: Foundations, Controls, Status & feedback, Thread, Composer &
  menus, Navigation, Agents & orchestration, Review, Swift implementation, Missions map,
  Mission screens and Design tool, each drawn dark and light. A UI decision changes the specs
  here and the canvas together.

## Board index

Every board on the canvas, the section of this document that specifies it, and how much of it
the app has. Light variants share their dark board's row. **Built** means the app draws the
board as specified here, give or take what Known gaps and the departures table list;
**Partial** means some of it is built and the rest is marked **Not built yet** where it is
specified; **Not built yet** means none of its surface exists. A board is judged on its own
subject: the destinations sidebar that most macOS boards draw around it is NWNavigation's and
NavNewThread's, the Settings nav's Instructions, Skills and Experiments rows are those boards', and a
full-window board's larger sizes and second lines give way to the component boards (Composer,
questions, and menus), except SlashMenu's and ModelPicker's, which specify their menus.

**macOS**

| Board | Files | Specified in | Status |
| --- | --- | --- | --- |
| Main | [thread](thread.md), [composer](composer.md), [window-and-toolbar](window-and-toolbar.md) | Thread; Composer, questions, and menus; Toolbar (breadcrumb, branch chip, side-pane button) | Built |
| Running | [thread](thread.md), [composer](composer.md) | Thread (A turn while pi works); Composer, questions, and menus | Built |
| Goal card | [thread](thread.md) | Goal card | Partial (long-condition truncation and edit surfaces await user decisions in PR #189) |
| MobileGoal | [thread](thread.md) | Goal card | Partial (same pending decisions) |
| iPadGoal | [thread](thread.md) | Goal card | Partial (same pending decisions) |
| SlashMenu | [composer](composer.md) | Composer, questions, and menus › Slash menu | Built |
| ModelPicker | [composer](composer.md) | Composer, questions, and menus › Model picker | Built |
| ComposerSpeed | [composer](composer.md), [dialogs-and-palette](dialogs-and-palette.md), [settings](settings.md) | Composer, questions, and menus › The control row, Model settings (its Speed control); Command palette; Settings › Agents | Built (its separate Speed chip and menu are replaced by the Composer & menus board's one popover) |
| CommandPalette | [dialogs-and-palette](dialogs-and-palette.md) | Command palette | Built |
| ToolRows | [thread](thread.md) | Thread › Activity lines | Built |
| ChangesSplit | [design-tool](design-tool.md) | Side pane › Changes (toolbar, compare row, strip, file headers, split, comments, send bar) | Built |
| ChangesScope | [ios-ipad-pages](ios-ipad-pages.md) | Side pane › Changes (scope menu, Commits menu) | Built |
| ChangesBase | [ios-ipad-pages](ios-ipad-pages.md) | Side pane › Changes (base picker) | Built |
| ChangesUnified | [ios-ipad-pages](ios-ipad-pages.md) | Side pane › Changes (unified, word diffs, Diff options) | Partial |
| ChangesLastTurn | [ios-ipad-pages](ios-ipad-pages.md) | Side pane › Changes (a turn's compare row, the comment editor) | Built |
| ChangesWide | [ios-ipad-pages](ios-ipad-pages.md) | Side pane › Changes (maximized, file list, rail) | Built |
| Subagents | [subagents](subagents.md), [ios-ipad-pages](ios-ipad-pages.md) | Subagents; Side pane › Subagent inspector | Built |
| SubagentsDone | [subagents](subagents.md), [ios-ipad-pages](ios-ipad-pages.md) | Subagents; Side pane › Subagent inspector | Built |
| SubagentsQueue | [subagents](subagents.md), [queue](queue.md) | Subagents (One card with Up next); Up next (the queue) | Partial |
| SettingsAppearance | [settings](settings.md), [foundations](foundations.md) | Settings › Appearance; Density and row settings | Built |
| SettingsAgents | [settings](settings.md), [codemode-settings](codemode-settings.md) | Settings › Agents | Built |
| SettingsWorktrees | [settings](settings.md) | Settings › Worktrees | Built |
| SettingsProjects | [settings-projects](settings-projects.md), [project-mcp](project-mcp.md) | Settings > Projects | Built |
| ProjectInstructions | [project-instructions](project-instructions.md) | Settings > Projects > Instructions | Built |
| ProjectBrowser | [project-browser](project-browser.md) | Settings > Projects > Browser | Built |
| SubagentsSettings | [settings-subagents](settings-subagents.md) | Settings › Subagents | Built |
| SubagentEdit | [settings-subagents](settings-subagents.md) | Settings › Subagents › Edit form | Built |
| SettingsPi | [settings-pi](settings-pi.md) | Settings › Pi | Built (departures) |
| SettingsPiSignIn | [settings-pi](settings-pi.md) | Settings › Sign-in | Built (departures) |
| SettingsPiSignInKeys | [settings-pi](settings-pi.md) | Settings › Sign-in (API keys, custom providers, the provider menu) | Built |
| SettingsPiFromPi | [settings-pi](settings-pi.md) | Settings › Pi ▸ From pi | Built (departures) |
| SettingsExtensions | [settings-pi](settings-pi.md) | Settings › Extensions | Built |
| SettingsPiDesignReferences | [settings-pi](settings-pi.md) | Settings › Extensions (Design references) | Built |
| SettingsPiSlashCommands | [settings-pi](settings-pi.md) | Settings › Slash commands | Built |
| SettingsTerminal | [settings](settings.md) | Settings › Terminal | Built |
| SettingsAgentsDeferred | [settings](settings.md) | Settings › Agents (Defer rarely used tools) | Built |
| SettingsPiExtensions | [settings-pi](settings-pi.md) | Settings › Pi ▸ From pi (Imported extensions) | Built |
| SignInBrowser | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Sign in to <provider> (Browser) | Built |
| SignInDevice | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Sign in to <provider> (Device code) | Built (departures) |
| SignInPaste | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Sign in to <provider> (Paste a code) | Built |
| SignInKey | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Sign in to <provider> (API key) | Built (departures) |
| SignInPortBusy | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Sign in to <provider> (Callback port in use) | Built |
| PiImportProgress | [dialogs-and-palette](dialogs-and-palette.md), [sidebar](sidebar.md), [thread](thread.md) | Dialogs and sheets › Bringing over your pi (In progress); Sidebar (waiting); Thread › Waiting to continue | Built |
| PiImportDone | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Bringing over your pi (Done) | Built |
| PiImportMissing | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Bringing over your pi (Something missing) | Built (departures) |
| PiImportNew | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Bringing over your pi (New user) | Built (departures) |
| PiImportFailed | [dialogs-and-palette](dialogs-and-palette.md) | Dialogs and sheets › Bringing over your pi (Failed) | Built |
| AgentNotSignedIn | [thread](thread.md), [sidebar](sidebar.md) | Thread › Not signed in; Sidebar (Not signed in) | Built |
| SlashLogin | [composer](composer.md) | Composer, questions, and menus › /login and /logout | Built |
| SlashLoginArgs | [composer](composer.md) | Composer, questions, and menus › /login and /logout | Built |
| PiAuthStates | [settings-pi](settings-pi.md) | The states of all of the above | Built (departures) |
| SettingsRemote | [settings](settings.md) | Settings › Remote | Built |
| SettingsKeyboard | [settings](settings.md) | Settings › Keyboard; Keyboard | Built |
| SettingsAdvanced | [settings](settings.md) | Settings › Advanced | Built |
| SettingsInstructions | [settings](settings.md) | Settings › Wide pages, Instructions | Built |
| SettingsInstructionsHosts | [settings-instructions](settings-instructions.md) | Settings › Instructions per host | Built |
| SettingsSkills | [settings](settings.md), [settings-skills](settings-skills.md) | Settings › Wide pages, Skills | Built |
| SettingsSkillsBrowse | [settings-skills](settings-skills.md) | Settings › Browse skills.sh and Add from repo | Built |
| SettingsSkillsSearch | [settings-skills](settings-skills.md) | Settings › Browse skills.sh and Add from repo | Built |
| SettingsSkillsRepo | [settings-skills](settings-skills.md) | Settings › Browse skills.sh and Add from repo | Built |
| SkillsStates | [settings-skills](settings-skills.md) | Settings › Skills; Browse skills.sh and Add from repo | Built |
| SettingsExperiments | [settings-mcp-experiments](settings-mcp-experiments.md) | Settings › Experiments | Built |
| NavNewThread | [sidebar](sidebar.md), [pages](pages.md) | Sidebar; New thread page | Built |
| NavMissions | [pages](pages.md), [missions](missions.md) | Missions page; Missions | Not built yet |
| NavDesigns | [pages](pages.md), [design-tool](design-tool.md) | Designs page; Design tool › Designs | Built (Mac, behind the Design tool experiment; systems as names only) |
| NavAutomations | [pages](pages.md), [sidebar](sidebar.md) | Automations page; Sidebar (no When, Next or tabs: departures) | Built |
| NavHosts | [pages](pages.md), [sidebar](sidebar.md), [settings](settings.md) | Hosts page; Sidebar; Settings › Remote (no daemon, Load or disk use: departures) | Built |
| PaneBrowser | [side-pane-browser](side-pane-browser.md) | Side pane: Browser | Partial (local threads: the page, toolbar, viewport, Select an element, composer chip, console, the agent using it and its thread lines; remote threads: the same page through the tunnel, its host chip and Start on the host, and the agent on the host driving it, with the card, Take over, the dot and its tip; not Throttle to 3G) |
| PaneArtifacts | [ios-ipad-pages](ios-ipad-pages.md) | Side pane (Artifacts) | Not built yet |
| PaneArtifactEdit | [side-pane-artifacts](side-pane-artifacts.md) | Side pane (Artifacts › Editing in place) | Not built yet |
| PaneFiles | [ios-ipad-pages](ios-ipad-pages.md) | Side pane (Files) | Not built yet |
| PaneStates | [ios-ipad-pages](ios-ipad-pages.md), [side-pane-browser](side-pane-browser.md), [side-pane-artifacts](side-pane-artifacts.md) | Side pane (tabs, dot, narrow, ⋯, button); Side pane: Browser; Side pane: Artifacts, Files | Partial (Browser: nothing open, viewport, the agent using it and the tab's tip built, on a remote thread too) |
| ContextDetails | [composer](composer.md) | Composer, questions, and menus › Context meter | Built |
| ContextFull | [composer](composer.md) | Composer, questions, and menus › Context meter | Built |
| ContextCompacted | [composer](composer.md), [thread](thread.md) | Composer, questions, and menus › Context meter; Thread › Compactions | Built |
| QueueStack | [queue](queue.md) | Up next (the queue) | Built |
| QueueSteer | [queue](queue.md), [thread](thread.md) | Up next (the queue); Thread › User turn (Steered) | Built |
| QueueEdit | [queue](queue.md), [composer](composer.md) | Up next (the queue); Composer › Send menu | Built |
| QueueStates | [queue](queue.md), [settings](settings.md) | Up next (the queue); Settings › Agents, Keyboard | Partial |
| QuestionAsk | [ios-ipad](ios-ipad.md) | Composer, questions, and menus › Questions | Built |
| QuestionPick | [ios-ipad](ios-ipad.md) | Composer, questions, and menus › Questions | Built |
| QuestionAnswered | [ios-ipad](ios-ipad.md) | Composer, questions, and menus › Questions (The record) | Built |
| QuestionStates | [ios-ipad](ios-ipad.md), [settings](settings.md) | Composer, questions, and menus › Questions; Keyboard | Partial |
| TerminalSplit | [terminal](terminal.md) | Terminal; Terminal panel (tabs only, no Split right or header button: departures) | Built |
| TerminalPane | [terminal](terminal.md) | Terminal; Terminal panel (Send output to the agent, on a tab's one terminal; no split drawing, pane headers or header button: departures) | Partial |
| TerminalStates | [terminal](terminal.md) | Terminal panel (tab states, maximized, divider, new terminal menu without Split right; no header toggle, Run in terminal or empty state, ⌘J opens a terminal: departures) | Partial |
| ThreadError | [thread](thread.md), [components](components.md) | Thread › Errors (the card, folded); Status language | Built |
| ThreadErrorDetails | [thread](thread.md) | Thread › Errors (Details) | Built |

**iOS**

| Board | Files | Specified in | Status |
| --- | --- | --- | --- |
| MobileAgents | [ios-iphone](ios-iphone.md) | iPhone: shell and shared anatomy; iPhone: Home | Partial |
| MobileThread | [ios-iphone](ios-iphone.md) | iPhone: Thread | Built |
| MobileApproval | [ios-iphone](ios-iphone.md) | iPhone: Thread | Built |
| MobileThreadError | [ios-iphone](ios-iphone.md), [thread](thread.md) | iPhone: Thread (Header); Thread › Errors (touch sizes) | Built |
| MobileLock | [notifications](notifications.md) | Notifications and Live Activities › Live Activities | Not built yet |
| MobileAnswer | [notifications](notifications.md) | Notifications and Live Activities › Actions and answering | Not built yet |
| MobileMission | [missions-screens](missions-screens.md) | Missions › Missions: iPhone and iPad | Not built yet |
| MobilePatch | [missions-screens](missions-screens.md) | Missions › Missions: iPhone and iPad | Not built yet |
| MobileMerge | [missions-screens](missions-screens.md) | Missions › Missions: iPhone and iPad | Not built yet |
| MobileLiveLock | [notifications](notifications.md) | Notifications and Live Activities › Live Activities | Not built yet |
| MobileIsland | [notifications](notifications.md) | Notifications and Live Activities › Dynamic Island | Not built yet |
| MobileNewThread | [ios-iphone](ios-iphone.md) | iPhone: New thread and Where it runs | Partial |
| MobileWorkspace | [ios-iphone](ios-iphone.md) | iPhone: New thread and Where it runs | Partial |
| MobileSteer | [ios-iphone](ios-iphone.md) | iPhone: Up next and questions; iPhone: Subagents | Partial |
| MobileSubagents | [ios-iphone](ios-iphone.md) | iPhone: Subagents | Built |
| MobileSubagent | [ios-iphone](ios-iphone.md) | iPhone: Subagents | Built |
| MobileQueue | [ios-iphone](ios-iphone.md) | iPhone: Up next and questions | Partial |
| MobileQueueMenu | [ios-iphone](ios-iphone.md) | iPhone: Up next and questions | Built |
| MobileQuestion | [ios-iphone](ios-iphone.md) | iPhone: Up next and questions | Partial |
| MobileChanges | [ios-iphone](ios-iphone.md) | iPhone: Review | Partial |
| MobileDiff | [ios-iphone](ios-iphone.md) | iPhone: Review | Partial |
| MobileCommit | [ios-iphone](ios-iphone.md) | iPhone: Review; iOS (Commit from review) | Built |
| MobileInbox | [ios-iphone-pages](ios-iphone-pages.md) | iPhone: Needs you | Partial |
| MobileSearch | [ios-iphone-pages](ios-iphone-pages.md) | iPhone: Search | Partial |
| MobileMissions | [missions-screens](missions-screens.md) | Missions › Missions: iPhone and iPad | Not built yet |
| MobileDesigns | [design-tool](design-tool.md) | Design tool › Designs | Built |
| MobileDesignBoard | [design-tool-references](design-tool-references.md) | Design tool › On iPhone | Partial |
| MobileAutomations | [ios-ipad-pages](ios-ipad-pages.md) | iOS: Automations | Partial |
| MobileMore | [ios-iphone-pages](ios-iphone-pages.md) | iPhone: More | Partial |
| MobileSettings | [ios-iphone-pages](ios-iphone-pages.md) | iPhone: Settings | Partial |
| MobileInstructions | [ios-iphone-pages](ios-iphone-pages.md) | iPhone: Instructions | Built |
| MobileInstructionsEdit | [ios-iphone-pages](ios-iphone-pages.md) | iPhone: Instructions | Built |
| MobileSkills | [ios-iphone-pages](ios-iphone-pages.md) | iPhone: Skills | Built |
| MobileExperiments | [ios-iphone-pages](ios-iphone-pages.md) | iPhone: Experiments | Built |

**iPadOS**

| Board | Files | Specified in | Status |
| --- | --- | --- | --- |
| iPadThread | [ios-ipad](ios-ipad.md) | iOS: iPad › Shell and sidebar, Thread, Composer and commands | Partial |
| iPadThreadError | [ios-ipad](ios-ipad.md), [thread](thread.md) | iOS: iPad › Thread (Header), Shell and sidebar (Rows: the failed row); Thread › Errors (touch sizes) | Built |
| iPadReview | [ios-ipad](ios-ipad.md) | iOS: iPad › Review | Built |
| iPadSubagents | [ios-ipad](ios-ipad.md) | iOS: iPad › Subagents | Partial |
| iPadPortrait | [ios-ipad](ios-ipad.md) | iOS: iPad › Shell and sidebar, Composer and commands | Built |
| iPadSidebar | [ios-ipad](ios-ipad.md) | iOS: iPad › Shell and sidebar | Partial |
| iPadPortraitLaunch, iPadPortraitLaunchLight | [ios-ipad](ios-ipad.md) | iOS: iPad › Shell and sidebar (Portrait) | Built |
| iPadLock | [notifications](notifications.md) | Notifications and Live Activities › Live Activities, Lock-screen widget (iPad) | Not built yet |
| iPadOverview | [ios-ipad-pages](ios-ipad-pages.md) | iOS: iPad › Overview | Partial |
| iPadNewThread | [ios-ipad](ios-ipad.md) | iOS: iPad › New thread | Partial |
| iPadSteer | [ios-ipad](ios-ipad.md) | iOS: iPad › Up next and steering, Subagents | Partial |
| iPadReviewSplit | [ios-ipad](ios-ipad.md) | iOS: iPad › Review | Built |
| iPadCommit | [ios-ipad](ios-ipad.md), [ios-ipad-pages](ios-ipad-pages.md) | iOS: iPad › Commit; Side pane › Changes (Commit… sheet) | Built |
| iPadQueue | [ios-ipad](ios-ipad.md) | iOS: iPad › Up next and steering | Built |
| iPadQuestion | [ios-ipad](ios-ipad.md) | iOS: iPad › Questions | Built |
| iPadMissions | [missions-screens](missions-screens.md) | Missions › Missions: iPhone and iPad | Not built yet |
| iPadMissionMap | [missions-screens](missions-screens.md) | Missions › Missions: iPhone and iPad | Not built yet |
| iPadMissionReview | [missions-screens](missions-screens.md) | Missions › Missions: iPhone and iPad | Not built yet |
| iPadInbox | [ios-ipad-pages](ios-ipad-pages.md) | iOS: iPad › Needs you | Partial |
| iPadAutomations | [ios-ipad-pages](ios-ipad-pages.md) | iOS: Automations | Partial |
| iPadHosts | [ios-ipad-pages](ios-ipad-pages.md) | iOS: iPad › Hosts and More | Partial |
| iPadPalette | [dialogs-and-palette](dialogs-and-palette.md), [ios-iphone](ios-iphone.md) | iOS: iPad › Command palette; iOS (Windows) | Partial |
| iPadDesign | [design-tool-references](design-tool-references.md) | Design tool › On iPad | Partial |
| iPadSplitView | [ios-iphone](ios-iphone.md), [ios-ipad-pages](ios-ipad-pages.md), [design-tool-references](design-tool-references.md) | iOS (Windows); iOS: iPad › Split View; Design tool › On iPad | Partial |
| iPadSettingsInstructions | [settings](settings.md) | iOS: iPad › Settings | Partial |
| iPadPaneBrowser | [ios-ipad-pages](ios-ipad-pages.md) | iOS: iPad › Side pane | Not built yet |
| iPadPaneArtifacts | [ios-ipad-pages](ios-ipad-pages.md) | iOS: iPad › Side pane | Not built yet |
| iPadPaneFiles | [ios-ipad-pages](ios-ipad-pages.md) | iOS: iPad › Side pane | Not built yet |
| iPadTerminal | [ios-iphone](ios-iphone.md), [terminal](terminal.md) | iOS (Terminal); Terminal (tabs only, no Split right; the options menu shows it and opens a terminal when there is none: departures) | Partial |

**Notifications**

| Board | Files | Specified in | Status |
| --- | --- | --- | --- |
| NotifCatalog | [notifications](notifications.md) | Notifications and Live Activities › The catalog, Rules for sending, Anatomy, Actions and answering | Partial |
| NotifPhoneBanner | [notifications](notifications.md) | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneStacks | [notifications](notifications.md) | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneRich | [notifications](notifications.md) | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneReply | [notifications](notifications.md) | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneReview | [notifications](notifications.md) | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneSummary | [notifications](notifications.md) | Notifications and Live Activities › iPhone | Not built yet |
| NotifSettings | [notifications](notifications.md) | Notifications and Live Activities › Settings ▸ Notifications | Not built yet |
| NotifiPadBanner | [notifications](notifications.md) | Notifications and Live Activities › iPad | Not built yet |
| NotifiPadCenter | [notifications](notifications.md) | Notifications and Live Activities › iPad | Not built yet |
| NotifMac | [notifications](notifications.md) | Notifications and Live Activities › On the Mac today, Mac | Partial |

**Missions**

| Board | Files | Specified in | Status |
| --- | --- | --- | --- |
| MXNav | [missions](missions.md) | Missions › Missions: getting there | Not built yet |
| MXFlow | [missions](missions.md) | Missions › Missions: how a mission runs | Not built yet |
| MXStart | [missions](missions.md) | Missions › Missions: intake | Not built yet |
| MXGoal | [missions](missions.md) | Missions › Missions: intake | Not built yet |
| MXMap | [missions](missions.md) | Missions › Missions: the map; map, patches and the run | Not built yet |
| MXPatch | [missions-screens](missions-screens.md) | Missions › Missions: map, patches and the run | Not built yet |
| MXRun | [missions-screens](missions-screens.md) | Missions › Missions: map, patches and the run | Not built yet |
| MXOffMap | [missions-screens](missions-screens.md) | Missions › Missions: map, patches and the run | Not built yet |
| MXDone | [missions-screens](missions-screens.md) | Missions › Missions: map, patches and the run | Not built yet |
| MXInputs | [missions](missions.md) | Missions › Missions: how a mission runs | Not built yet |
| MXReview | [missions-screens](missions-screens.md) | Missions › Missions: review, evidence and the merge train | Not built yet |
| MXEvidence | [missions-screens](missions-screens.md) | Missions › Missions: review, evidence and the merge train | Not built yet |
| MXTrain | [missions-screens](missions-screens.md) | Missions › Missions: review, evidence and the merge train | Not built yet |
| MXStuck | [missions-screens](missions-screens.md) | Missions › Missions: when things go wrong | Not built yet |
| MXBudget | [missions-screens](missions-screens.md) | Missions › Missions: when things go wrong | Not built yet |
| MXLocks | [missions-screens](missions-screens.md) | Missions › Missions: when things go wrong | Not built yet |
| MXCancel | [missions-screens](missions-screens.md) | Missions › Missions: when things go wrong | Not built yet |
| MXTemplateSave | [missions-screens](missions-screens.md) | Missions › Missions: templates | Not built yet |
| MXTemplates | [missions-screens](missions-screens.md) | Missions › Missions: templates | Not built yet |
| MXTemplateStart | [missions-screens](missions-screens.md) | Missions › Missions: templates | Not built yet |

**Design tool**

| Board | Files | Specified in | Status |
| --- | --- | --- | --- |
| DZStart | [design-tool](design-tool.md) | Design tool › New design | Built, without Capture a page, From a screenshot and "/ commands" |
| DZCanvas | [design-tool](design-tool.md) | Design tool › A design: canvas and chat, Comments | Partly built: header, canvas, board frames, Chat, comments; not actions, Tweak |
| DZTweak | [design-tool-references](design-tool-references.md) | Design tool › Tweak | Not built yet |
| DZSystem | [design-tool-references](design-tool-references.md) | Design tool › Design systems | Not built yet |
| DZExport | [design-tool-references](design-tool-references.md) | Design tool › Export and share | Partly built: the sheet, its formats and Attach to a thread; not the live link or Attach to a mission |
| DesignLifecycleStates | [design-tool-references](design-tool-references.md) | Design tool › Delete and import | Built, but for the Recents row's outline while its menu is open |
| DesignCardMenu, DesignRecentsMenu, DesignToolbarMenu | [design-tool-references](design-tool-references.md) | Design tool › Delete and import (a design's menu) | Built, as native menus |
| DesignDeleteConfirm, DesignDeleteWorking, DesignDeleted, DesignDeleteFailed | [design-tool-references](design-tool-references.md) | Design tool › Delete and import (DeleteDesignDialog, the toast) | Built |
| SystemCardMenu, SystemBuiltIn, SystemDeleteConfirm, SystemDeleteBuilding, SystemDeleteFailed | [design-tool-references](design-tool-references.md) | Design tool › Delete and import (a system's menu, DeleteSystemDialog) | Built |
| ImportFileMenu, ImportNewDesign, ImportDrop, ImportProgress, ImportDone, ImportFailed, ImportAgain | [design-tool-references](design-tool-references.md) | Design tool › Delete and import (Import) | Built, without New Design, New Mission and Export… in the File menu |

**Design system · Night Watch**

| Board | Files | Specified in | Status |
| --- | --- | --- | --- |
| NWFoundations, NWFoundationsLight | [theme](theme.md), [foundations](foundations.md), [motion](motion.md) | Theme model; Typography; Space, radius, height, elevation; Motion | Built |
| NWControls, NWControlsLight | [components](components.md) | Components › Controls | Built |
| NWStatus, NWStatusLight | [components](components.md) | Components › Status and feedback; Status language | Partial |
| NWThread, NWThreadLight | [thread](thread.md) | Thread | Partial |
| TurnErrors | [thread](thread.md) | Thread › Errors (every kind, the retry line, touch sizes) | Partial |
| LiveText | [thread](thread.md), [motion](motion.md), [queue](queue.md), [subagents](subagents.md) | Thread › Live text, Activity lines (Live), Thinking (Live); Motion (`shimmer`); Up next (a steering row waits still); Subagents (a running tray row's words) | Built |
| NWComposer, NWComposerLight | [composer](composer.md), [dialogs-and-palette](dialogs-and-palette.md) | Composer, questions, and menus; Command palette | Built |
| ContextIdeas | [composer](composer.md), [thread](thread.md) | Composer, questions, and menus › Context meter; Thread › Compactions | Built |
| NWNavigation, NWNavigationLight | [window-and-toolbar](window-and-toolbar.md), [sidebar](sidebar.md) | Window and adaptive layout; Sidebar; Toolbar | Partial |
| NWAgents, NWAgentsLight | [subagents](subagents.md), [ios-ipad-pages](ios-ipad-pages.md), [missions](missions.md) | Subagents; Side pane › Subagent inspector; Mission components | Built |
| ChangesStates | [ios-ipad-pages](ios-ipad-pages.md), [thread](thread.md), [settings](settings.md) | Side pane › Changes; Thread › Changes card; Keyboard | Partial |
| SubagentTray | [subagents](subagents.md), [ios-iphone](ios-iphone.md), [ios-ipad](ios-ipad.md) | Subagents; iPhone: Subagents; iOS: iPad › Subagents | Partial |
| NWSwift, NWSwiftLight | [theme](theme.md) | Theme model › Building on ShepherdUI | Partial |
| MXVocab, MXVocabLight | [missions](missions.md) | Missions › Missions: the map | Not built yet |
| NWMissions, NWMissionsLight | [missions](missions.md) | Missions (Missions: shared parts and the screens that use them) | Not built yet |
| NWDesignTool, NWDesignToolLight | [design-tool-references](design-tool-references.md) | Design tool › Design components | Partly built: the canvas, board frame, toolbar, system chip and chat composer |

## Files

| File | Read when |
| --- | --- |
| [components](components.md) | Read when you build a control or a status piece: the shared component inventory and how a status reads. |
| [composer](composer.md) | Read when you change the composer, its model-settings popover, slash menu, context meter, a question, or the send path. |
| [departures](departures.md) | Read when a board and the app disagree. Each row is a decision the user made; a new departure is the user's call, never an agent's. |
| [goal safety review](goal-safety-review.md) | Read when changing goals after PR #189's user review: model disclosure, confirmation, experiment enablement and narrow clock observation. |
| [design-tool-references](design-tool-references.md) | Read when you work on design references, Tweak, design systems, export, deletion and import, or the Design tool on iOS. |
| [design-tool](design-tool.md) | Read when you work on the Design tool (Settings ▸ Experiments ▸ Design tool): designs, canvas, comments. |
| [dialogs-and-palette](dialogs-and-palette.md) | Read when you change the command palette, a dialog or a sheet. |
| [foundations](foundations.md) | Read when you set type, spacing, radius, row height, elevation, an icon, or the density settings. |
| [ios-ipad-pages](ios-ipad-pages.md) | Read when you change the iPad's overview, Needs you, hosts, palette, Split View, settings or side pane, or Automations on iOS. |
| [ios-ipad](ios-ipad.md) | Read when you change the iPad client's shell, thread, composer, queue, questions, subagents, review or commit. |
| [ios-iphone-pages](ios-iphone-pages.md) | Read when you change the iPhone's Needs you, Search, More, Settings, Instructions, Skills or Experiments. |
| [ios-iphone](ios-iphone.md) | Read when you change the iPhone client's shell, home, thread, new thread, queue, subagents or review. |
| [keyboard-and-accessibility](keyboard-and-accessibility.md) | Read when you add a shortcut, a focus behavior, a VoiceOver label, or a Reduce Motion path. |
| [known-gaps](known-gaps.md) | Read when you finish a change that leaves the app short of its design: list the place here until it is fixed. |
| [missions-screens](missions-screens.md) | Not built yet. Read only when asked to build Missions: the run, review, failure states, templates, iOS and motion. |
| [missions](missions.md) | Not built yet. Read only when asked to build Missions: the model, getting there, the map and its parts. |
| [motion](motion.md) | Read when something animates, appears, or must not move. |
| [notifications](notifications.md) | Read when you send a notification or build a Live Activity, on the Mac or iOS. |
| [pages](pages.md) | Read when you change New thread, Automations, Hosts, Designs or the Missions page. |
| [performance](performance.md) | Read when you build or change a list, a row, a scroll view, or anything that redraws often. |
| [principles](principles.md) | Read when you weigh a UI decision: what the app is for, and the principles in priority order. |
| [queue](queue.md) | Read when you change the queue above the composer, steering, or Send now. |
| [settings-instructions](settings-instructions.md) | Read when you change Settings ▸ Instructions or its per-host view. |
| [settings-mcp-experiments](settings-mcp-experiments.md) | Read when you change Settings ▸ MCP servers or Experiments. |
| [settings-subagents](settings-subagents.md) | Read when you change the owned Markdown profile list and editor. |
| [settings-pi](settings-pi.md) | Read when you change Settings ▸ Pi: Slash commands, Sign-in, the CLIProxyAPI connection, or From your pi. |
| [settings-skills](settings-skills.md) | Read when you change Settings ▸ Skills, Browse skills.sh or Add from repo. |
| [settings](settings.md) | Read when you change a Settings page other than Pi, Instructions, Skills, MCP servers and Experiments. |
| [side-pane-artifacts](side-pane-artifacts.md) | Read only when asked to build the Artifacts or Files tabs. |
| [side-pane-browser](side-pane-browser.md) | Read when you change the Browser tab or how an agent drives it. |
| [side-pane-changes](side-pane-changes.md) | Read when you change the Changes pane, a diff, a review comment, or the subagent inspector. |
| [sidebar](sidebar.md) | Read when you change the sidebar: its rows, Needs you, Pinned, Recents or Projects. |
| [child-projects](child-projects.md) | Read when you change the create-or-add child-project dialog or its entry points. |
| [subagents](subagents.md) | Read when you change the subagent tray, its cards, or its record lines in a thread. |
| [terminal](terminal.md) | Read when you change a terminal tab, the panel under a thread, or ⌘J and ⌘D. |
| [theme](theme.md) | Read when you add or change a color, a theme, an AgentState look, or build on ShepherdUI's tokens. |
| [thread](thread.md) | Read when you change how a thread draws: turns, activity lines, prose, errors, starting, following. |
| [verifying](verifying.md) | Read when you check a UI change: previews, windows, motion probes, the Component Gallery. |
| [window-and-toolbar](window-and-toolbar.md) | Read when you change the window, how it adapts to a narrow size, or the toolbar. |
