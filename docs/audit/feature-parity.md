> Lane report from the 2026-10-27 audit. Static reading only (no build, no run) by a GPT-6 Astra agent; line numbers are from commit d28f3511c. Live confirmation of overlapping items is in [live-usage-mac-ios.md](live-usage-mac-ios.md); the cross-lane ranking is in [README.md](README.md).

# Shepherd device-parity audit

## Scope and method

Read-only static audit of the current checkout. Read `AGENTS.md` first. No builds, tests, app launches, repository writes, user-support-directory access, or git mutations. This report is the only output file.

This is a **feature-parity lane**, not a measured performance benchmark. Findings below describe missing workflows, surprising semantics, and discoverability costs; no timing claim is inferred from absence of UI. Negative findings mean no native control/route was found in the inspected iOS surface—not that a sufficiently instructed agent or a terminal could never perform the operation.

Matrix notation: **Y** = implemented native surface; **N** = no equivalent native surface found; **P** = partial, with details. iPhone means ordinary compact iPhone; iPhone Duo can use iPad-like side panes/windows. Mac means the Mac app including its local-host capabilities; differences that also affect a *remote Mac* are called out. Capability-dependent features assume a current, connected, opted-in host. A host experiment being off is not a missing client feature.

Disposition: **D** = explicitly documented difference; **U** = unexplained mismatch (not listed as deferred in the reviewed docs); **A** = architectural/platform distinction, not necessarily a defect; **=** = substantive parity. **D does not mean “Not in the first release.”** That heading in `docs/ios/README.md:383–386` only lists background Live Activity updates, QR pairing, TLS, Missions and daemon hosts. Browser and phone-design omissions have separate explicit “not built/not yet” lists.

## Evidence index

Short codes in the matrix resolve to these repository file:line references. Findings below also give direct references.

- **CMD:** `Sources/ShepherdApp/AppCommands.swift:94–286` — app settings/updates; File, View, Terminal, Space, Agent, Appearance commands.
- **PAL:** `Sources/ShepherdApp/ShepherdViewModel+Palette.swift:13–180`; `App/iOS/Search/MobileSearchStore.swift:10–21,385–413`; `App/iOS/Search/SearchPalette.swift:72–98`.
- **SET:** `Sources/ShepherdApp/SettingsView.swift:173–190,262–314`; `App/iOS/Settings/SettingsRoute.swift:8–37,69–85`.
- **HOSTSET:** `App/iOS/Settings/HostSettingsScreens.swift:13–61,78–166`; `Sources/ShepherdApp/SettingsAgents.swift:33–100`.
- **IOS:** `docs/ios/README.md:155–386` — feature contracts, including device-specific shells and intentional limits.
- **ROW:** `App/iOS/Home/ThreadRowMenu.swift:16–75,115–129`; `docs/ios/README.md:182–199`.
- **COMP:** `App/iOS/Composer/ThreadComposer.swift:231–280,309–327`; `App/iOS/Composer/QueueSection.swift:88,186–200`; `Sources/ShepherdApp/Thread/ComposerReturnKey.swift:6–17`; `Sources/ShepherdApp/Thread/Composer.swift:265–267,527–546,1145`.
- **NEW:** `App/iOS/NewThread/NewThreadWhereItRuns.swift:103–136,182–215`; `App/iOS/NewThread/NewThreadModel.swift:260–298`; `docs/ios/README.md:256–266`.
- **CHANGE:** `docs/changes.md:3–38`; `docs/ios/README.md:277–302`; `Sources/ShepherdApp/DiffReviewView.swift:570–707`; `App/iOS/Commit/PadCommitPopover.swift:40–43,60–67`.
- **FILE:** `App/iOS/Files/ThreadFilesPane.swift:7–25,80–125,183–190`; `Sources/ShepherdApp/FilesTab.swift:10–27,123–171`; `docs/remote-protocol.md:57–69`.
- **TERM:** `Sources/ShepherdApp/TerminalPanelViews.swift:117–164`; `App/iOS/Terminal/TerminalScreen.swift:37–39,104–109`; `docs/ios/README.md:322–343`; `docs/remote-protocol.md:86–90`.
- **BROW:** `Sources/ShepherdApp/BrowserPane.swift:137,180–197,428–436`; `App/iOS/Browser/ThreadBrowserPane.swift:7–10,76–88,124–149`; `docs/browser.md:611–657`.
- **DES:** `docs/designs.md:933–1067,1130–1226,1712–1749,1875–1948`; `App/iOS/Designs/DesignBoardScreen.swift:185–237,300–306`; `App/iOS/DesignPad/PadDesignCanvas.swift:549–561,662–679,728–765`.
- **SPACE:** `docs/projects.md:3–69,85–93`; `App/iOS/NewThread/NewThreadWhereItRuns.swift:103–136`; `App/iOS/Settings/SettingsRoute.swift:8–37`.
- **PROJECT:** `docs/ios/README.md:176–181`; `App/iOS/Projects/ProjectSettingsScreen.swift:42–81,139–150,205–227`. These are logical Projects, not the legacy folder Spaces described in `docs/projects.md`.
- **AUTO:** `docs/ios/README.md:303–313`; `App/iOS/Home/ThreadRowMenu.swift:115–129`.
- **CHILD:** `docs/native-subagents.md:419–482`; `docs/ios/README.md:267–276`; `Sources/ShepherdApp/SettingsSubagents.swift:66–83`; `App/iOS/Composer/QueueSection.swift:186–200`.
- **SKILL:** `docs/skills.md:195–219`; `Sources/ShepherdApp/SettingsSkills.swift:773`; `App/iOS/Settings/SkillsScreens.swift:7,36`.
- **MCP:** `docs/mcp.md:224–303`; `Sources/ShepherdApp/SettingsView.swift:185,309–310`; `App/iOS/Settings/SettingsRoute.swift:8–37`.
- **GOAL:** `docs/goals.md:3–9,15–17,41–61`; `App/iOS/Settings/HostSettingsScreens.swift:50–59`; `docs/remote-protocol.md:34–47`.
- **KEY:** `Sources/ShepherdApp/Keybindings.swift:10–39,114–149,184–219`; `App/iOS/Windows/MobileWindowRoot.swift:46–52`; `App/iOS/Search/SearchRoute.swift:56–64`.

## Feature matrix

Grouped leaves are named explicitly; a row's Y/N applies to all listed leaves unless its notes say otherwise. This inventories the requested product surfaces, not every standard OS-provided text-editing menu item.

### App navigation, commands, search, thread row menus

| Feature / command | Mac | iPhone | iPad | Behavior / disposition / evidence |
|---|---|---|---|---|
| Run agents locally on this device | Y | N | N | A: iOS supervises Mac hosts; no daemon/local pi. IOS:155–170. |
| New Thread | Y | Y | Y | =; Mac page/menu/chord; phone form, pad form/popovers. CMD, NEW. |
| New Agent with Options as separate command | Y | P | P | Options exist in common New thread form, not separate command. CMD:115; NEW. |
| Add Space / Add repo | Y | Y | Y | = registration of host folder; iOS from repo picker. SPACE, NEW. |
| Sidebar show/hide and selection | Y | P | Y | A: phone tabs/push navigation; pad split/sidebar overlay. CMD:150; IOS:171–175,200–208. |
| Side pane show/hide, Changes/Files/Browser/Terminal | Y | P | Y | A: compact phone pushes individual screens; pad/Duo docks panes. FILE, BROW, TERM, CHANGE. |
| Hosts page / add, edit, retry, forget host | Y | Y | Y | =; phone under Settings, pad More/footer. SET, IOS:157–170. |
| Needs you / Working / Done / Pinned / Recents | Y | Y | Y | = shared fleet derivation; pins and completion-observation state device-local. ROW, IOS:182–199. |
| Mark all done seen | Y | Y | Y | = home/inbox semantics; IOS:171–175. |
| Organize sidebar by Spaces / hierarchical child Spaces | Y | N | N | U: mobile grouped activity feed, not Mac configurable hierarchy. SPACE; `SettingsAppearance.swift:29–48`; SET. |
| Rename thread | Y | Y | Y | = contextual menu, capability gated. ROW. |
| Pin / Unpin | Y | Y | Y | = device-local, not synchronized pins. ROW; PAL:142–147. |
| Move thread to another Space | Y | Y | Y | = same-host, idle ordinary agents; not worktrees or cross-host transfer. ROW:57–62; `remote-protocol.md:73–78`. |
| Reorder thread up/down | Y | P | Y | Mobile search action exists; phone search does not expose the full pad action palette. PAL. |
| Delete Agent / Delete Worktree Agent | Y | Y | Y | = confirmation and warning flow on host. ROW; IOS:317–321. |
| Finalize Worktree | Y | Y | Y | = host operation; remote/local gates differ as documented. ROW; `worktrees.md:189–205`. |
| Review Uncommitted / Review PR from row | Y | Y | Y | =; ROW:69–70. |
| Next/Previous Agent command | Y | N | N | U: select rows instead; no corresponding mobile Commands registration. CMD:254–257; KEY. |
| Focus Agent command | Y | N | N | A/U: desktop explicit focus action, mobile navigation focuses thread. CMD:232; KEY. |
| Previous/Next Turn command | Y | N | N | U: mobile scrolling instead. CMD:247–250; KEY. |
| Search thread titles and conversation contents across hosts | Y | Y | Y | =; phone search page, pad palette with preview. PAL; IOS:317–321. |
| Command palette | Y | P | P | Mac commands/destinations/subagents/Spaces; phone search, pad much smaller command set. FP-17. PAL. |
| Palette jump to subagent run / Space | Y | N | N | U: no mobile result kinds for either. PAL; `MobileSearchStore.swift:40`. |
| Open Hosts / Extensions / Design systems from palette | Y | N | N | U: mobile navigation still reaches pages. PAL:45–53 vs mobile action inventory. |
| Palette choose model / fast mode / review / terminal | Y | N | N | U: controls exist elsewhere, missing palette actions. PAL. |
| Check for Updates | Y | N | N | A: Mac updater vs iOS distribution; CMD:97. |
| Component Gallery | Y | N | N | A: Mac developer surface, not a parity priority. CMD:177. |
| Open thread in new window | P | N | Y | A: explicit mobile multiwindow action is iPad/Duo; no equivalent thread-targeted item in audited Mac command/palette/row inventory. ROW:16; IOS:314–316. Do not infer Mac cannot create any window. |
| Send turn text to another window / drag text between windows | P | N | Y | A: explicit iPad workflow; ordinary desktop text copy/drag is not the same command. IOS:314–316. |

### Thread, composer, queue, context, goals and subagents

| Feature / command | Mac | iPhone | iPad | Behavior / disposition / evidence |
|---|---|---|---|---|
| Transcript prose/thinking/tools/live output/errors | Y | Y | Y | = shared store/presentation; IOS:209–225. |
| Tail following / Jump to latest | Y | Y | Y | = shared scroll follower; IOS:221–225. |
| Copy / Retry completed turn | Y | Y | Y | = footer on both; IOS:220. |
| Edited-files card / review selected turn / Undo / Redo | Y | Y | Y | = current hosts; old-host edit-call fallback has no Undo. CHANGE. |
| Model selection / thinking levels | Y | Y | Y | = host catalog/capabilities, no thinking chip for unsupported models. COMP; IOS:226–246. |
| Per-thread Standard / Fast speed | Y | Y | Y | = explicitly present in mobile `ThreadComposer.swift:247`; not a missing feature. |
| Send queues while running / explicit Steer now | Y | Y | Y | = actions; hold Send on touch. COMP. |
| Command-Return semantics | Y | Y | Y | U: Mac alternate send steers; mobile shortcut invokes ordinary send/queue. FP-01. COMP. |
| Stop running turn | Y | Y | Y | = empty composer's send becomes Stop; question header has Stop. IOS:209–214. |
| Queued edit/delete/undo/reorder/move-to-top/clear | Y | Y | Y | = touch swipe/long press vs desktop hover/key actions. COMP; IOS:230–239. |
| Queue delivery one/all; resume paused queue | Y | Y | Y | = same model, touch explicit header action. HOSTSET; IOS:233–239. |
| Run queued message in subagent | Y | Y | Y | = capability-gated; `QueueSection.swift:88,186–200`. |
| Slash command picker | Y | Y | Y | = ordinary threads; deliberately hidden in iPad design chat. `ThreadComposer.swift:231`; IOS:347–365. |
| Agent questions: select/confirm/input/editor | Y | Y | Y | = composer replacement. IOS:241–245. |
| Context meter / split / largest items / Compact now | Y | Y | Y | = capability-gated; mobile sheet. IOS:243–249. |
| Compaction summary disclosure | Y | Y | Y | = IOS:248–249. |
| Attach images | Y | Y | Y | P: Mac file picker/drop; mobile Photos picker only. FP-15. COMP. |
| Attach design reference via @ / pasted reference chip | Y | N | N | U: mobile image handoff is not fenced editable design references. FP-14. COMP, DES. |
| Subagent tray / lifecycle records / live transcript | Y | Y | Y | = mobile pad inspector column, phone pushed screen. CHILD. |
| Steer/Reply / Stop / Pause / Continue / Re-run child | Y | Y | Y | = host supported controls; child question stays with parent. CHILD. |
| Create/edit/restore subagent profiles; default policies | Y | N | N | U: runtime child controls are not profile management. FP-07. SET, CHILD. |
| Enable Goals experiment per host | Y | Y | Y | = goal switch, live disabling pauses, enabling never resumes automatically. GOAL. |
| Set/edit/pause/resume/clear/confirm goal | Y | Y | Y | = host revision fences and model/evidence disclosure. GOAL. |
| Cross-provider goal-check consent | Y | Y | Y | = mobile Defaults explicitly includes it. HOSTSET:50–59. |
| Goal result alerts in background | P | P | P | D: mobile goal-specific local notifications require observing connection; not equivalent to general APNs turn notifications. `goals.md:47`. |

### Changes, Files, Terminal, Browser

| Feature / command | Mac | iPhone | iPad | Behavior / disposition / evidence |
|---|---|---|---|---|
| Last turn / Uncommitted / Unstaged / Staged / Commits / Branch / PR scopes | Y | Y | Y | = host engine; CHANGE. |
| Branch base picker, scope diffstats | Y | Y | Y | = CHANGE. |
| Syntax/word diffs / folded context / file navigation | Y | Y | Y | = phone wrapped reader; pad split or narrow unified. CHANGE. |
| Line comments / viewed progress / send review to agent | Y | Y | Y | = mobile send bar; no overall comment box by design. CHANGE. |
| Revert individual file | Y | N | N | D: Mac local working-tree only; no remote request, including remote Mac. FP-04. CHANGE. |
| Commit message drafting / Push / Open PR / progress | Y | Y | Y | = current `review.commit.v1`; old-host Ask agent fallback. CHANGE. |
| Select subset of files in mobile commit form | P | Y | N | D: iPad popover commits every changed file; phone sheet selects. Mac commit variants not equated to phone sheet here. `PadCommitPopover.swift:40–43`; IOS:290–302. |
| Finalize checks / gh login utility terminal / progress / PR link | Y | Y | Y | = host pipeline; `worktrees.md:189–205`; IOS:288–289. |
| Browse Files / expanded-folder filter / text preview | Y | Y | Y | = host-safe read-only API; FILE. |
| Several open file tabs, tree beside content | Y | N | N | U/layout gap: mobile one openPath replaces tree, even wide pane. FILE:80–83 vs Mac:123–171. |
| Edit arbitrary source directly in Files | N | N | N | Not a missing mobile editor: shared Files API is read-only. SPACE configuration editor is separate. FILE. |
| New terminal / close terminal with confirmation | Y | Y | Y | = current host; older host read-only terminal management. TERM. |
| Interactive terminal input / resize / replay / running titles / output dots | Y | Y | Y | = SwiftTerm mobile vs desktop Ghostty; mobile attach foreground-only. TERM; IOS:322–343. |
| Rename terminal tab / Kill process | Y | N | N | U: protocol already supports both, mobile lacks action dispatch/UI. FP-06. TERM. |
| Terminal maximize/restore and next/previous terminal commands | Y | P | P | Phone fullscreen substitutes for maximize; tap tabs, no mobile Commands entries. CMD:196–201; KEY. |
| Terminal splits | N | N | N | = deliberately tabs only; legacy remote layouts flatten on iOS. IOS:322–343. |
| Terminal font family/size/shell preferences | Y | N | N | A/U: no mobile terminal settings route; host shell still determines process. SET; `SettingsTerminal.swift:23–46`. |
| One terminal displayed in simultaneous windows | P | N | P | D: iPad one window owns terminal surface, another shows ownership message. IOS:342–343. |
| Browser user navigation / reload / dev servers / start script | Y | Y | Y | = forwarded host ports; iOS page is user's, not agent's. BROW. |
| Agent drives the browser shown to viewer / Take over | Y | N | N | D: explicit browser.drive omission. FP-03. BROW. |
| Browser tabs / console / element picker / viewport presets | Y | N | N | D: explicit browser extras omission. FP-12. BROW. |
| Browser persistent website data | Y | N | N | D: mobile non-persistent WK data store; pages bounded to three. `browser.md:619–624`; saved Mac data `browser.md:123`. |
| Browser downloads | P | N | N | D: mobile explicitly no downloads; do not infer full desktop download manager. `browser.md:635–638`. |

### Designs and design systems

| Feature / command | Mac | iPhone | iPad | Behavior / disposition / evidence |
|---|---|---|---|---|
| Designs list, recents, search, create from brief/system | Y | Y | Y | = host capability/experiment gated. DES; IOS:345–374. |
| Render boards locally / zoom / pan / select | Y | Y | Y | P: phone board-at-a-time; pad canvas. DES. |
| Pages/canvas board arrangement | Y | P | Y | Phone grid/board navigation instead of full canvas. DES. |
| Pin new comment / read existing agent answer | Y | Y | Y | = DES. |
| Reply to comment / Resolve / detached-pin note | Y | N | Y | D: explicit phone deferred set. FP-09. `designs.md:1912–1914,1938–1940`. |
| Tweak styles/props with undo / duplicate board | Y | N | Y | D: phone deferred. FP-10. DES; `PadDesignCanvas.swift:662–679`. |
| Present/interactive Play/board links | Y | N | Y | D: phone deferred, pad supports focused Present/Play. FP-11. DES; `PadDesignCanvas.swift:765`. |
| Ask design agent with viewed-board context | Y | Y | Y | = phone pushes thread; pad docked chat. DES. |
| Export PNG | Y | Y | Y | = mobile share sheet; pad page boards. DES. |
| Export PDF | Y | Y | N | D: documented pad PNG-only path. FP-19. DES. |
| Export HTML / attach structured boards to thread | Y | N | P | D/U: pad image+text handoff, not Mac structured export. FP-14/19. `DesignExportSheet.swift:19,72–78,104`; DES. |
| Import Claude Design ZIP/folder / import conflict dialogs | Y | N | N | U: Mac File menu/drop/import dialogs, no mobile import surface found. FP-13. CMD:121; `DesignLifecycleViews.swift:126–202,237–270`. |
| Delete design/system and Undo | Y | N | N | U: mobile list/detail inventory lacks lifecycle actions. FP-13. `DesignLifecycleViews.swift:45–103,211`; DES. |
| Sharing designs through Git | Y | N | N | D: documented Mac workflow, no mobile UI found. `designs.md:1291–1387`; DES. |
| Browse design systems / choose system for new design | Y | Y | Y | = DES; `DesignSystemsScreen.swift`, `NewDesignScreen.swift`; IOS:345–354. |
| Design system author/install/re-sync administrative workflows | Y | P | P | Mobile browsing/choosing is not full Mac administration. `designs.md:629–730`; SET/DES. |
| @ design/board/element reference picker; Copy Reference; Implement in Thread | Y | N | P | U: pad Send to thread carries rendered images + text, no equivalent reference picker. FP-14. COMP; DES:1941–1948. |
| Pencil markup / on-device handwriting recognition | N | N | Y | A: iPad-only hardware workflow; `PadDesignMarkup.swift:405`; `designs.md:1950`. |

### Spaces, logical Projects, Automations, Worktrees

| Feature / command | Mac | iPhone | iPad | Behavior / disposition / evidence |
|---|---|---|---|---|
| List/select Spaces as New thread repos | Y | Y | Y | = NEW. |
| Space inventory by host/path, including hidden/history entries | Y | N | N | U: no Spaces settings page on iOS. FP-05. SPACE, SET. |
| Rename/remove Space; child-space hierarchy/add subspace | Y | N | N | U/A: local Mac operations; remote Macs also have limits on folder creation/removal. SPACE:13–45. |
| Space instruction/Pi-settings files edit/save with conflicts | Y | N | N | U: logical Project instructions are not folder configuration. FP-05. SPACE:47–69. |
| Space MCP config / project resource trust/approval | Y | N | N | U: agent can use trusted config but mobile cannot administer it natively. FP-02/05. SPACE. |
| Logical Projects list/create/rename/delete | Y | Y | Y | = shared `LogicalProjectsModel`, host revision checks. PROJECT. |
| Project conversations/questions/task transcripts | Y | Y | Y | = PROJECT; IOS:176–181. |
| Project linked Spaces / settings/instructions / forget memory | Y | Y | Y | = `ProjectSettingsScreen.swift:139–150,205–227`. |
| Project file previews | Y | Y | Y | = read-only mobile previews. PROJECT. |
| Project offline/old-host write restrictions | Y | Y | Y | = shared host authority; PROJECT. |
| Automations list/detail/running status/history chart | Y | Y | Y | = mobile shared host records, last 14 chart plus retained runs. AUTO. |
| Automation create/edit/delete / enable / run now / stop | Y | Y | Y | = host capability; enable means launch-run, not a scheduler. AUTO. |
| Time schedules/custom triggers | N | N | N | = docs explicitly say Mac has none; do not file mobile scheduler gap. AUTO. |
| New worktree toggle / branch / base / fetch override | Y | Y | Y | = all four controls present on mobile, not just toggle. NEW:182–215. |
| Worktree defaults (base/fetch/commit remaining/PR descriptions/delete branch/auto-merge/method) | Y | Y | Y | = HOSTSET:78–118. |
| Worktree delete warning/acknowledgement/progress | Y | Y | Y | = remote uses stricter confirmed fingerprint gate. `worktrees.md:189–205`. |

### Settings, integrations, extensions and keyboard

| Page / setting / control | Mac | iPhone | iPad | Behavior / disposition / evidence |
|---|---|---|---|---|
| Appearance System/Light/Dark | Y | Y | Y | = `SettingsAppearance.swift:22–25`; `SettingsScreen.swift:250–258`. |
| Sidebar organization/host grouping/idle retention/density/width | Y | N | N | U/A: mobile activity-only layout and fixed layout policies. FP-18. |
| Chrome text-size slider | Y | N | N | A: no same slider; iOS Dynamic Type is not “no accessibility text scaling.” SET. |
| Default model/thinking/queue | Y | Y | Y | = HOSTSET. |
| Default Fast speed / session naming model | Y | N | N | U: per-thread speed exists, defaults/naming settings do not. FP-08. `SettingsAgents.swift:47–59`; HOSTSET. |
| Automatic compaction threshold / trim old tool context / defer tools / Codemode default | Y | N | N | U: manual Compact now does not configure these policies. FP-08. `SettingsAgents.swift:71–95`. |
| Cross-provider goal checks | Y | Y | Y | = consent exists on mobile; HOSTSET:50–59. |
| Subagent profiles/settings | Y | N | N | U: FP-07. SET/CHILD. |
| Spaces configuration settings | Y | N | N | U: FP-05. SPACE. |
| Pi home/source/re-import/custom-provider migration | Y | N | N | A/U: host administration stays on Mac, no explicit mobile deferred statement. SET:300–304. |
| Provider sign-in/out/API keys/multiple accounts | Y | N | N | U: native auth recovery missing remotely. FP-16. `SettingsPiSignIn.swift:109–179`; SET. |
| Bundled extension toggles / installed extension listing / engine version | Y | Y | Y | = HOSTSET:123–166. |
| Slash-command enable/disable administration | Y | N | N | U: mobile invoking slash commands is not managing enabled commands. SET:181,305; COMP. |
| Root AGENTS.md / APPEND_SYSTEM.md editor | Y | Y | Y | = mobile same/per-host mode with shared client. `InstructionsScreens.swift:56–57,371–377`; IOS:250–255. |
| Installed skills/browse skills.sh/add repo/update/remove/Undo | Y | Y | Y | = shared ClientSkills. SKILL. |
| Scope skill changes to one host | Y | N | N | D: mobile lacks Same skills switch, defaults all hosts. FP-20. SKILL:218–219. |
| MCP list/add/edit/import/enable/tools/status/reconnect/OAuth | Y | N | N | U: global MCP switch is not server management. FP-02. MCP/SET. |
| MCP tool transcript display | Y | Y | Y | = shared `NativeMCPActivity`; MCP:293–303. |
| Hosts connection records / retry / edit / forget | Y | Y | Y | = iOS device-only Keychain tokens. IOS:157–170. |
| Serve this Mac / listener port/token | Y | N | N | A: iOS cannot host agents; mobile form explains Mac prerequisite. `HostEditorScreen.swift:68`. |
| Keyboard rebind/reset | Y | N | N | U: no mobile configuration; FP-17 covers discoverability, FP-01 semantics. KEY/SET. |
| Open files in external editor / workspace paths / update channel / reset all settings | Y | N | N | A/U: Mac Advanced page has no full mobile equivalent. SET:313. |
| Share diagnostics consent | Y | Y | Y | = mobile dedicated Diagnostics route. SET. |
| Goals/Projects/Design tool/suggested-instructions experiments | Y | Y | Y | Capability-gated mobile experiments; IOS:250–255,345–365; GOAL. |
| Suggested instruction review/edit/accept/dismiss | Y | Y | Y | = shared suggestions client. IOS:250–255. |
| APNs notification host preferences / previews | N | Y | Y | A: mobile-specific relay delivery, Mac has native notification behavior rather than APNs client preferences. IOS:375–381. |
| Follow thread on Lock Screen / Live Activity / Dynamic Island / widgets | N | Y | Y | A: hardware/OS surfaces differ; Dynamic Island only where available. ROW:47–49; IOS:379–386. |
| Live Activity server updates while backgrounded | N | N | N | D: explicitly “Not in the first release”; foreground updates go stale after five minutes. IOS:379–386. |
| QR pairing / TLS transport | N | N | N | D: explicitly deferred, not a mobile-only feature gap. `remote-protocol.md:9–13`; IOS:383–386. |
| Missions / daemon hosts | N | N | N | D: deferred on Mac as well; do not treat as missing mobile parity. IOS:383–386. |

## Top 20 mismatches, ranked by switching-device impact

Severity reflects workflow disruption, not a security exploit. Explicitly documented limitations are still ranked because users experience them. Several fixes need protocol work; none should be implemented by bypassing host authorization or turning UI operations into unreviewed shell commands.

### FP-01 — high — The same Send chord changes delivery semantics
- **Evidence:** `Sources/ShepherdApp/Thread/ComposerReturnKey.swift:6–17` describes Command-Return as alternate send; `Sources/ShepherdApp/Keybindings.swift:139` binds it to `alternateSend`. `App/iOS/Composer/ThreadComposer.swift:278–280` binds Command-Return to ordinary send. `docs/ios/README.md:230–234` explicitly says hardware Command-Return queues.
- **Experience:** a Mac user on an iPad keyboard tries to interrupt/steer a running agent and instead silently leaves work queued until the current turn ends.
- **Why bad:** identical chord, different consequential action; delayed feedback is especially costly during an unwanted long-running task. This is not a network latency issue.
- **Smallest fix:** bind mobile Command-Return to the same explicit alternate-send action; preserve ordinary Send as queue. If touch design requires the existing mapping, disclose the difference next to the chord and provide a separate steer shortcut.
- **Disposition:** behavior is documented, but no rationale for cross-device inversion or first-release exclusion.

### FP-02 — high — No mobile MCP administration or authentication recovery
- **Evidence:** `Sources/ShepherdApp/SettingsView.swift:185,309–310` exposes MCP server administration; `docs/mcp.md:266–272` describes sign-in/out, status and tools. `App/iOS/Settings/SettingsRoute.swift:8–37,69–85` has no MCP page; `App/iOS/Settings/HostSettingsScreens.swift:135–140` offers only bundled extension switches.
- **Experience:** a mobile user can see an MCP call fail but cannot add/edit the server, inspect status, reconnect or sign in through Shepherd.
- **Why bad:** toggling the global MCP extension cannot repair one server; a laptop return is required for a core tool integration. Existing native tool display is not administration parity.
- **Smallest fix:** begin with a capability-gated host MCP status/error page and explicit “configure/sign in on host” guidance; then add host-mediated reconnect/auth/config actions with the existing trust/secret rules, not raw config downloads containing credentials.
- **Disposition:** U; not in iOS deferred list.

### FP-03 — high — Mobile Browser is not the agent's browser
- **Evidence:** `docs/browser.md:635–638` says iOS does not implement `browser.drive.v1`, never claims the agent browser and ignores `opened` pushes; `:646–647` explicitly defers driving/ring/Take over. `App/iOS/Browser/ThreadBrowserPane.swift:7–10` describes the user page; Mac toolbar/key integration is in `Sources/ShepherdApp/BrowserPane.swift:180–197`.
- **Experience:** opening Browser on a phone/tablet does not show/control the page the agent is operating, unlike the remote Mac viewer. Take over/hand back is unavailable.
- **Why bad:** the same tab name implies continuity but mobile owns a separate browsing session. User and agent can reason about different page state.
- **Smallest fix:** label the mobile pane as user preview and disclose “agent browser control unavailable on this device.” For full parity reuse the shared claimant/policy described at `docs/browser.md:649–657`, preserving navigation and ownership checks.
- **Disposition:** D, explicitly not built on iOS (not the top-level first-release list).

### FP-04 — high — Cannot revert one file from mobile review
- **Evidence:** `Sources/ShepherdApp/DiffReviewView.swift:570,706–707` provides Revert File for eligible reviews; `Sources/ShepherdApp/ShepherdViewModel+Review.swift:194` deliberately supplies no revert for remote reviews. `docs/ios/README.md:288–289` says the protocol has no per-file revert.
- **Experience:** a user reviewing on mobile can comment, undo a whole turn or ask an agent, but cannot perform the same precise confirmed one-file rollback available locally on Mac.
- **Why bad:** whole-turn undo is not equivalent and may undo wanted work; agent-mediated rollback adds latency and interpretation risk.
- **Smallest fix:** add a capability-gated host revert operation fenced to the displayed working-tree/file version, then reuse the existing confirmed action in clients. Until then state the limitation beside review actions.
- **Disposition:** D; applies to remote Mac too, not only iOS.

### FP-05 — high — Logical Projects conceal a missing Spaces administration surface
- **Evidence:** `docs/projects.md:47–69` specifies Space file editors, Pi settings, MCP files and explicit project-resource trust. Mac routes are `Sources/ShepherdApp/SettingsView.swift:177,299`. `App/iOS/Settings/SettingsRoute.swift:8–37` lacks Spaces; `App/iOS/NewThread/NewThreadWhereItRuns.swift:103–136` only lists/adds repos. `App/iOS/Projects/ProjectSettingsScreen.swift:205–227` edits logical Project instructions/memory, not these files.
- **Experience:** mobile's Projects page does not let users repair the `.shepherd`/`.pi` configuration or trust approval of the repo they selected for a thread.
- **Why bad:** two similarly named concepts appear interchangeable but operate on different state; executable resources can remain blocked with no native mobile recovery path.
- **Smallest fix:** expose a distinct host Spaces settings entry using the existing versioned project-file API and conflict/approval checks; start with inventory plus read-only status if full editing cannot ship immediately.
- **Disposition:** U. Do not report logical Projects themselves as missing.

### FP-06 — medium — Terminal management stops at add/close on mobile
- **Evidence:** `Sources/ShepherdApp/TerminalPanelViews.swift:158–164` has Rename tab and Kill process; `Sources/ShepherdApp/ShepherdViewModel+TerminalControl.swift:74,88` already sends remote actions. `docs/remote-protocol.md:86–90` advertises these operations. `App/iOS/Terminal/TerminalScreen.swift:37–39,104–109` wires selection/close and confirms closing; no rename/kill action is wired in `App/iOS/Terminal`.
- **Experience:** an iPad user cannot name several shells or stop the foreground job with the same menu action as Mac without typing terminal control keys or closing the shell.
- **Why bad:** shell close is stronger than kill-current-process; lost tab names make multiple identical commands hard to distinguish.
- **Smallest fix:** add a long-press/menu for the selected tab calling the existing capability-gated `renameTerminal`/`killTerminalProcess` requests.
- **Disposition:** U; protocol already exists.

### FP-07 — medium — Can operate subagents but cannot configure their profiles
- **Evidence:** `Sources/ShepherdApp/SettingsSubagents.swift:66–83` exposes Restore defaults, New subagent and profile folder; `Sources/ShepherdApp/SettingsView.swift:176,297–298` routes profile settings. `App/iOS/Settings/SettingsRoute.swift:8–37` has no subagent settings; `docs/ios/README.md:267–276` describes only runs and control.
- **Experience:** mobile can stop/re-run a child but cannot edit the profile that caused the problem or create a reusable helper profile.
- **Why bad:** execution UI is present while its configuration/recovery UI is missing, requiring a device switch.
- **Smallest fix:** add host profile listing/read first, clearly distinguishing profile configuration from live runs; expose bounded, conflict-checked host edits only through a supported API.
- **Disposition:** U.

### FP-08 — medium — Mobile Defaults omits important cost/context and launch policies
- **Evidence:** `Sources/ShepherdApp/SettingsAgents.swift:47–59` includes default service tier and naming model; `:71–95` includes compaction threshold, context trimming, deferred tools and Codemode. `App/iOS/Settings/HostSettingsScreens.swift:13–61` includes only model, thinking, queue and cross-provider goal-check consent.
- **Experience:** users can change the current thread's speed or compact now, but cannot change these defaults and context-cost policies for subsequent host sessions.
- **Why bad:** the “Agents”/“Defaults” page name suggests broader parity than its controls provide. Mobile users cannot tune expensive context behavior from their current device.
- **Smallest fix:** extend the host settings projection/change enum for the missing supported policies and reuse mobile settings rows. Do not conflate per-thread `setServiceTier` with a default.
- **Disposition:** U.

### FP-09 — medium — iPhone cannot finish a design-comment conversation
- **Evidence:** `docs/designs.md:1912–1914` explicitly excludes replies, Resolve and detached-pin note on phone; `:1938–1940` gives iPad replies/Resolve. Phone `App/iOS/Designs/DesignBoardScreen.swift:201–223` sends a new draft; pad `App/iOS/DesignPad/PadDesignCanvas.swift:549–561` has revision-aware comment writes.
- **Experience:** a phone user can create a pin and read an answer but cannot reply to or resolve the existing discussion as on Mac/iPad.
- **Why bad:** review threads become write-only initial feedback; users create duplicate pins or switch devices to close the loop.
- **Smallest fix:** reuse the pad/shared comment request path in the phone pin card, keeping revision checks and detached-element explanation.
- **Disposition:** D, explicit phone “Not yet.”

### FP-10 — medium — iPhone design selection has no Tweak or Duplicate
- **Evidence:** `docs/designs.md:1912–1914` defers Tweak/moves/Duplicate; `:1938–1940` says pad uses shared `DesignTweakModel` and Duplicate. `App/iOS/DesignPad/PadDesignCanvas.swift:662–679` implements duplicate with a stale-revision refresh.
- **Experience:** a quick visual correction possible on Mac/iPad must be described to an agent on phone instead of directly adjusted.
- **Why bad:** narrower screen changes capability rather than merely presentation; feedback round-trips replace deterministic controls.
- **Smallest fix:** offer a compact sheet for the existing tweak model and a confirmed board Duplicate action; retain revision handling.
- **Disposition:** D, explicit phone “Not yet.”

### FP-11 — medium — iPhone cannot Play an interactive design
- **Evidence:** `docs/designs.md:1912–1914` excludes interactive Play and links on phone; `Sources/ShepherdApp` behavior is specified at `docs/designs.md:1044–1058`; pad focused modes are implemented in `App/iOS/DesignPad/PadDesignCanvas.swift:765` onward.
- **Experience:** the device most useful for checking a phone prototype only offers the static/comment board experience, not its interactions.
- **Why bad:** visually correct screens can hide broken interactions; viewing a design is not testing it.
- **Smallest fix:** add explicit Play mode backed by the existing renderer's isolated interactive mode and a reliable exit affordance; do not make comment hit-testing accidentally execute links.
- **Disposition:** D, explicit phone “Not yet.”

### FP-12 — medium — Mobile Browser lacks inspection tools, tabs and viewport controls
- **Evidence:** `docs/browser.md:646–647` explicitly lists tabs, console, element picker and viewport menu as not built on iOS. `Sources/ShepherdApp/BrowserPane.swift:137,180–197,428–436` wires desktop tab/select/address actions; `App/iOS/Browser/ThreadBrowserPane.swift:124–149` is navigation/address control.
- **Experience:** users can inspect the visible dev server but cannot gather console errors or an element selection in the same way they do on Mac.
- **Why bad:** debugging feedback becomes screenshots/prose rather than exact browser context; loading another URL replaces the only page.
- **Smallest fix:** prioritize a read-only console/error sheet and explicit single-page notice; add picker/viewport controls using shared toolbar semantics when supported. Full tabs need page-budget decisions, not an unbounded webview array.
- **Disposition:** D, explicit browser deferred list.

### FP-13 — medium — Mobile design libraries have no import/delete lifecycle UI
- **Evidence:** `Sources/ShepherdApp/AppCommands.swift:121` imports Claude Design; `Sources/ShepherdApp/DesignLifecycleViews.swift:45–103,126–202,237–270` implements delete/system-delete/import handling. Mobile `App/iOS/Designs/MobileDesigns.swift:235–253` supplies add comment/create and list/sync; the inspected phone/pad design list and detail surfaces have no corresponding import/delete action.
- **Experience:** mobile can create or browse designs but cannot clean up unwanted designs or import the project a colleague supplied.
- **Why bad:** library management is stranded on Mac despite design authoring/review being a headline mobile feature.
- **Smallest fix:** expose supported host lifecycle operations with existing confirmation/Undo semantics; first add explicit “Manage/import on Mac” guidance. Import needs bounded upload and validation, not a device-side path sent to the host.
- **Disposition:** U for native mobile lifecycle; absence of Finder/drop on iOS alone would not be a defect.

### FP-14 — medium — Mobile design handoff loses Mac reference semantics
- **Evidence:** `Sources/ShepherdApp/Thread/Composer.swift:265–267,527` handles capability-gated @ and pasted reference chips. `Sources/ShepherdApp/DesignScreenModel+References.swift:130–137` exposes Implement in a Thread and Copy Reference. `docs/designs.md:1941–1948` describes pad handoff as up to four rendered boards plus fixed text. `App/iOS/Composer/ThreadComposer.swift:309–327` sends image attachments, not a mobile @ reference picker.
- **Experience:** Mac users can refer to a precise design/board/element; iPad users hand over images, and phone users have no equivalent reference selection flow.
- **Why bad:** images are not structured reference grants and do not carry the same editable source/element targeting semantics. Treating these as equivalent masks meaningful information loss.
- **Smallest fix:** reuse reference selection/serialization and host grant validation in mobile composer; keep image handoff as a distinct option labelled accordingly.
- **Disposition:** U, with pad image behavior documented.

### FP-15 — medium — Mobile attachments only browse Photos
- **Evidence:** `Sources/ShepherdApp/Thread/Composer.swift:546` accepts image files through file importer; `ComposerAttachments.swift:170` accepts image/file URL drops. `App/iOS/Composer/ComposerControls.swift:15–18` offers a PhotosPicker; mobile composer/new-thread attachment searches reveal no Files image importer.
- **Experience:** a screenshot/mockup saved in Files instead of Photos cannot be selected from the ordinary mobile attachment control without moving it to the photo library.
- **Why bad:** same supported data type, narrower acquisition path; unnecessary library pollution and extra steps rather than a renderer limitation.
- **Smallest fix:** put Photos and Choose image file under the paperclip; route security-scoped file data through the existing bounded `ComposerState.attach` image preparation path.
- **Disposition:** U; not a request for arbitrary source-file upload.

### FP-16 — medium — Provider account recovery remains Mac-only
- **Evidence:** `Sources/ShepherdApp/SettingsPiSignIn.swift:109–119,141–179` implements account use/rename/remove, sign out/in, keys and another account; `Sources/ShepherdApp/SettingsView.swift:179` routes it. `App/iOS/Settings/SettingsRoute.swift:8–37` has no provider sign-in page; mobile Pi page is extensions/version (`HostSettingsScreens.swift:123–166`).
- **Experience:** when host model credentials expire or the active account hits limits, changing the model is available on mobile but changing/repairing its account is not.
- **Why bad:** an otherwise full remote workflow stops at an administrative action; a terminal workaround is less discoverable and not the native account selector.
- **Smallest fix:** show host authentication status with an explicit host recovery instruction; add host-mediated sign-in/account selection later with careful credential and callback boundaries. Do not copy raw provider keys into state broadcasts.
- **Disposition:** U/A: host-side credentials are intentional; lack of a remote recovery surface is unexplained.

### FP-17 — medium — iPad Command-K is a search palette, not the Mac command palette
- **Evidence:** `Sources/ShepherdApp/ShepherdViewModel+Palette.swift:45–90,142–180` adds host/settings/integration/model/fast/review/terminal actions. `App/iOS/Search/MobileSearchStore.swift:385–398` only adds rename, move up/down, delete, New thread and Settings (design actions are separate). `App/iOS/Windows/MobileWindowRoot.swift:46–52` only installs SearchCommands.
- **Experience:** typing “terminal”, “review”, “model”, “pin” or a helper's name in Command-K works differently or finds nothing on iPad even when the feature exists elsewhere.
- **Why bad:** keyboard users have to abandon their learned route and hunt through touch menus. Missing bindings/settings compound discoverability, not feature execution speed.
- **Smallest fix:** add mobile action entries for already-supported native actions, capability-gated from the same availability predicates as their menus; no new host protocol needed for most.
- **Disposition:** U; iOS docs promise search/actions but not the complete Mac inventory.

### FP-18 — medium — Sidebar organization preferences do not exist on iOS
- **Evidence:** `Sources/ShepherdApp/SettingsAppearance.swift:29–48` provides organization, host grouping and idle retention; `:51–68` adds density/width. `App/iOS/Settings/SettingsScreen.swift:250–258` exposes appearance mode; `App/iOS/Settings/SettingsRoute.swift:69–85` has no separate organization page. `docs/ios/README.md:182–208` describes fixed activity groups.
- **Experience:** a user organizing many Mac threads by nested Spaces/hosts must use a different activity-based information architecture on iPad/phone.
- **Why bad:** the larger a fleet, the more muscle memory and project context are lost. This is not a request to force 22-point Mac rows onto touch.
- **Smallest fix:** expose organization/group-by-host choices on iPad using existing shared hierarchy derivations; keep touch row sizing independent. Explicitly document the phone's fixed grouping if it remains intentional.
- **Disposition:** U/A: touch density can intentionally differ; absent organization controls are not explained as a deferral.

### FP-19 — low — Export options regress from phone to iPad
- **Evidence:** `App/iOS/Designs/DesignBoardScreen.swift:300–306` offers format choices; `docs/designs.md:1907–1908` names phone PNG/PDF. `App/iOS/DesignPad/PadDesignCanvas.swift:728` is `exportPNGs`; `docs/designs.md:1948` says pad export shares PNGs. `Sources/ShepherdApp/DesignExportSheet.swift:19,72–78,104` offers the format enum and structured HTML attachment.
- **Experience:** users move a design from phone to the bigger iPad canvas and lose PDF export; moving from Mac also loses structured HTML export.
- **Why bad:** device-specific export format selection is surprising and forces redundant conversions or a device switch for delivery.
- **Smallest fix:** reuse the existing phone PDF exporter for selected pad boards, explicitly keeping multi-board layout/selection semantics; add other formats only where host/renderer contracts already support them.
- **Disposition:** D for the current export description, no stated first-release rationale.

### FP-20 — medium — Mobile skills management cannot target one host
- **Evidence:** `Sources/ShepherdApp/SettingsSkills.swift:773` offers Same skills on every host; `docs/skills.md:203–208` describes scope and owed offline operations; `:218–219` says phone/pad have no switch. `App/iOS/Settings/SkillsScreens.swift:36` says every host gets the same skills.
- **Experience:** a user who keeps distinct development/work hosts cannot scope an update/removal/install from the mobile UI; the default applies across hosts, including later-connected hosts.
- **Why bad:** administrative scope differs by device, and the effect can be delayed by offline reconciliation. The mobile disclosure is good, but there is no native alternative for a one-host operation.
- **Smallest fix:** expose the existing `ClientSkills` scope setting and target-host selection on mobile; retain pending-operation and Undo semantics.
- **Disposition:** D, explicit client limitation. Ranked below the broader workflow blockers because mobile does disclose global scope.

## Mac keyboard-only / menu discoverability audit

Do **not** label all context-scoped chords “keyboard-only.” Many have toolbar/context-menu equivalents:

| Action | Menu/palette reachability | Evidence / assessment |
|---|---|---|
| New thread/options/Space, rename/delete, model, stop, previous/next agent/turn, inspect child, sidebar/side pane, terminal commands | Main menus; several also palette | `AppCommands.swift:112–261`. Not keyboard-only. |
| Send and Steer Now (Command-Return by default) | Composer send menu, not main menu/palette | `Thread/Composer.swift:1145`; `Keybindings.swift:139`. Not chord-only. |
| Cycle Thinking Level (Shift-Tab) | **No exact cycle command in main menus or palette found** | `Keybindings.swift:140`; `Thread/Composer.swift:1581`. Thinking chip can choose levels directly. This is the clearest exact-action chord-only affordance, not a hidden capability. |
| Focus address bar (Command-L) | **No main menu/palette entry found**; click field | `BrowserPane.swift:190,428–430`; `Keybindings.swift:145`. Focus operation has pointer equivalent. |
| Select an Element / New Browser Tab | Browser toolbar/tab affordances, not global palette/menu | `BrowserPane.swift:137,180,432–436`; `Keybindings.swift:146–148`. Not chord-only. |
| Implement in Thread / Copy Reference | Canvas context menu, not global palette/menu | `DesignScreenModel+References.swift:130–137`. Not chord-only. |
| Edit last queued / move focused queue item / delete focused item / Escape stop | Local keyboard accelerators; queue touch/context controls expose underlying operations | `Keybindings.swift:184–219`; `Thread/QueueStack.swift:528–541`. Exact focus-navigation gesture need not get a menu item. |
| Save Space/Subagent file | File menu changes label with active settings section | `AppCommands.swift:125–129`. Not chord-only. |

No evidence supports a sweeping claim that Mac's main features are keyboard-only. The actual gap is the narrower mobile command inventory and one conflicting Send chord.

## iOS capabilities with no direct Mac equivalent

- APNs per-host notification configuration and Cloudflare relay push delivery (`docs/ios/README.md:375–381`); Mac native notifications are a different mechanism.
- Lock Screen Follow/Live Activities, Dynamic Island and mobile widgets (`App/iOS/Home/ThreadRowMenu.swift:47–49`; `docs/ios/README.md:379–386`). Background Live Activity updating is **not** implemented.
- Apple Pencil markup and local Vision handwriting extraction for design feedback (`App/iOS/DesignPad/PadDesignMarkup.swift:405`; `docs/designs.md:1950`).
- Explicit iPad thread-targeted multiwindow “Open in new window” and “Send to…” turn handoff (`docs/ios/README.md:314–316`; `App/iOS/Home/ThreadRowMenu.swift:16`). This does not assert the Mac lacks all multiwindow support.
- Phone Photos selection, terminal software-key rows, touch long-press/swipe controls; these are platform adaptations rather than missing Mac functionality (`ComposerControls.swift:18`; `docs/ios/README.md:230–239,332–335`).
- Duo folding layout and window availability, Stage Manager/Split View restoration (`docs/ios/README.md:314–316`). These are device-specific surfaces, not portable feature requirements.

## Already good — preserve instead of rebuilding

1. **Far more than a read-only companion:** mobile supports creation with branch/base/fetch, worktree finalization/deletion, commit/push/PR, logical Project mutations and automation CRUD/run/stop. Do not file these as absent.
2. **Shared semantics where it matters:** `NativeThreadStore`, Changes engine, ClientSkills/Instructions/Suggestions, LogicalProjectsModel and the fleet derivation reduce divergence (`docs/ios/README.md:147–153,176–181,250–255`; `docs/changes.md:3–8`).
3. **Important newer features already present:** per-thread Fast mode (`ThreadComposer.swift:247`), queued-message subagents (`QueueSection.swift:186–200`), goal controls and cross-provider consent (`HostSettingsScreens.swift:50–59`). Avoid stale audit claims.
4. **Safety isn't dropped for touch:** host capabilities gate writes; remote worktree deletion keeps warning acknowledgement; project and goal writes use revision/session fences; Files remains bounded/read-only (`remote-protocol.md:34–69`; `worktrees.md:189–205`).
5. **Conscious resource bounds:** mobile browser keeps at most three pages/eight ports per page; phone/pad designs cap live webviews to two, and the pad uses snapshots for the rest (`browser.md:619–632`; `designs.md:1884–1888,1927–1936`). Do not implement parity by removing these bounds.
6. **Useful explicit offline/old-host states:** mobile host cards retain records and report authentication/protocol errors; unsupported Files says newer host needed; older-host reviews/commits have a deliberate fallback (`ThreadFilesPane.swift:17–18`; IOS:157–170,277–302).
7. **Files rows are lazy and stable:** `ThreadFilesPane.swift:115–125` uses LazyVStack over identified model rows, rather than rebuilding a visible nested tree in each row.
8. **Subagent questions remain with parents across clients:** no false Needs you/Answer takeover for child questions; direct human Reply/Steer remains possible (`native-subagents.md:449–472`).

## Needs runtime confirmation

Static evidence establishes routes/actions, not that they work end-to-end. No app or test was run.

- Validate hardware Return/Command-Return behavior while idle, running, paused and with a queue, including responder focus and iPad design chat. FP-01 is statically supported; actual event routing needs a device check.
- Verify iPad/Duo compact transitions preserve selected side-pane state, terminal ownership and design chat without losing draft/attachments; matrix counts implemented surfaces, not restoration reliability.
- Exercise host capability downgrade/offline/reconnect during each write; confirm buttons disable and errors remain actionable instead of stale controls silently failing.
- Compare Mac local vs remote Mac vs iOS worktree finalize/delete warnings on the same dirty/diverged repo. Remote differences are documented and should not be flattened into nominal parity.
- Verify model catalog/thinking/Speed availability across host versions and provider models, including hidden controls when unsupported.
- Exercise mobile Projects executor approvals, blocked tasks, revision conflicts and linked-space reassignment against real host state; the shared model is encouraging, not proof of identical UI states.
- Test phone photo import and iPad drag/paste from Files. The native picker path is Photos-only; OS paste/drop behavior may provide additional acquisition paths not evident in these controls.
- Test phone comments with detached elements, stale revisions and resolved threads; inspect whether omitted controls produce useful disabled-state explanation.
- Verify iPad export's actual available share representations, not merely the PNG entry point; confirm whether OS print/share adds a user-level PDF workaround.
- Compare browser page/session/auth continuity when switching Mac→phone→pad and after backgrounding; distinguish intentionally separate user page from agent-owned page.
- Validate terminal kill-vs-close behavior, sizing with multiple viewers, software-key accessibility, and reacquisition between iPad windows.
- Check device-local pins/Done/seen behavior with hosts finishing work while iOS is backgrounded. Observed completion is deliberately not a global synchronized inbox.
- Verify APNs delivery versus goal-specific local alerts and Live Activity staleness with the app suspended. Documentation describes different delivery guarantees.
- Inspect VoiceOver/Dynamic Type and narrow iPad forms for controls that exist in source but become unreachable. No screenshot or accessibility-tree validation was performed.
- Matrix negatives derived from missing routes/control dispatch should be rechecked if app-specific extension menus inject controls at runtime. A protocol operation or slash-command workaround alone does not establish native-page parity.

## Audit limits / documentation disagreements

- `docs/ios/README.md:383–386` is a very small deferral list; do not reinterpret all missing mobile settings as intentional first-release scope.
- `docs/remote-protocol.md:78` says the iOS layout is unchanged for Move to Space, but current `App/iOS/Home/ThreadRowMenu.swift:57–62` clearly exposes it. Current code wins: marked present.
- The README summary omits some newer implemented controls (e.g. mobile Speed, queued subagents and richer worktree fields). Current code wins.
- `docs/projects.md` is titled Spaces; logical Projects live in another feature family. Conflating these would falsely mark mobile repo configuration as implemented.
- The matrix groups related menu leaves rather than reproducing every localized label, SF Symbol, host capability variant or standard Edit menu item. Rows with P/qualified N deliberately avoid inferring a nonexistent Mac/mobile implementation from docs alone.
