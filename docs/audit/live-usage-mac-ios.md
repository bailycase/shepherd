# Live usage audit: Mac, iPhone, iPad (2026-10-27)

> What happened when the app was used like a first-time user for an hour: a fresh support directory, a real import of the user's pi, real models (`openai-codex/gpt-6-astra`; Anthropic turned out to be stale, which is itself finding L13), every major surface, 12 agents, a relaunch, then the iOS client on an iPhone 17 Pro Max and an iPad Pro 13" simulator paired to the same Mac. Labels L1–L23 are referenced from [README.md](README.md).

## Setup

- Commit `d28f3511c`, Dev build (`Shepherd (Dev)` scheme, Debug, unoptimized) copied to `/tmp/shepherd-audit/Shepherd Audit.app` with bundle id `com.bailycase.shepherd.audit`, re-signed ad hoc, launched with `SHEPHERD_SUPPORT_DIR=/tmp/shepherd-audit/support`, `SHEPHERD_MCP_CONFIG` pointed at an empty file and every inherited `SHEPHERD_*`/`PI_*` variable unset. The user's Shepherd, Shepherd Nightly, Shepherd-dev support directories and `~/.pi` were only read by the app's own first-launch import.
- Driven through the accessibility API (a small Swift `axtool`: dump, press, set value, focus, menu, click) plus System Events keystrokes when a SwiftUI field ignored `AXValue` (see L6). Screenshots by `screencapture -l <window>`; iOS screenshots by `simctl io screenshot`; the simulators were driven through Xcode 27's DeviceHub, which exposes the iOS accessibility tree.
- Space: a scratch git repo `/tmp/shepherd-audit/spaces/demo` (3 Python files).
- Machine: the audit shared the Mac with the user's own Shepherd, Shepherd Nightly, seven audit subagents and an iOS build, so CPU numbers are indicative, not isolated.
- Debug build: absolute CPU/RSS are higher than a Release build; the ratios and the behavioral findings stand.

## What was exercised

First-launch import sheet · New thread page (space picker, custom folder chooser, model picker with All models…, thinking) · a coding turn with tools, edits, test run and summary card · Review (Changes pane, viewed state, Commit…) · Files tab · Browser tab (manual URL, agent-driven `browser_open`/`browser_read`) · Terminal panel (new, hide/show, + menu) · follow-ups typed from the keyboard · a commit through the agent · ⌘K palette · thread header menu, sidebar row context menu, menu bar · all 17 Settings pages · Automations (create, Run now, run detail) · New Agent with Options sheet · New worktree thread, branch chip menu, Finalize Worktree… checks · subagent start (`shepherd_child_start`), Subagents side pane and run inspector, reply field · 8 threads back to back · Quit and relaunch with 12 agents · Experiments: Design tool (one board drawn), Goals, Projects (project created, conversation sent) · Remote listener · iPhone: add host, Home, thread, send from phone, subagent page, thread "…" menu, Terminal (attach, + tab) · iPad: add host, sidebar, thread view.

Not exercised: goals (`/goal`), MCP servers, skills install, slash commands, instructions editing, design Tweak/Comments/Export, project workers across spaces, Live Activities/push, iPhone Duo, a second Mac as remote host, images in the composer.

## Findings

Severity is the user's experience. Each item says where it was seen and, when known, the code.

### L1. First launch: the imported default model cannot start (HIGH)
The import sheet says "Your pi is in Shepherd" with a green check and lists "default model gpt-6-astra". That default is `cpa/gpt-6-astra`; `cpa` is a provider one of the user's 15 extensions registers, and the extensions came over switched off. The first thread fails with raw pi stderr: `pi exited while starting (code 1). Error: Model "cpa/gpt-6-astra" not found. Use --list-models` and the sidebar says "can't start". Retry fails identically. The import log also recorded 10 problems (9 skill name clashes, one skill with >5,000 files) the sheet never mentioned. The new-thread composer labels the model "Default · Medium" rather than naming it, so nothing warns before Send. (shot `06-first-send.png`)

Fix: resolve the default model against Shepherd's own catalog during the "Something missing" check, and fall back to a working provider with a visible note; show import problems on the sheet.

### L2. A thread that cannot start has a dead model picker (HIGH)
`Thread/Composer.swift:1310` disables the model button when the session has no `setModel`, which is exactly the state after a model-not-found start failure. The only offered action is Retry. The thread is stuck; the user has to abandon it.

### L3. Composer and picker hide the provider (MEDIUM)
The compact model picker lists bare names: `cpa/gpt-6-astra` and `openai-codex/gpt-6-astra` both show as "gpt-6-astra". The chip under the composer shows "gpt-6-astra · Medium" with no provider. After L1 the user cannot see which one they are picking.

### L4. No first-party "ask the user" tool (MEDIUM)
Asked to use a question tool, gpt-6-astra searched (`tool_search "question ask user options"`), found nothing and asked in prose. pi's engine ships no ask tool; Shepherd's Needs you / question dock only fires from extension `ui.*` dialogs (children, `project_question`) or user extensions that arrive disabled. A fresh install never sees "Needs you" from an ordinary thread.

### L5. Browser tool error row is misleading (LOW)
A selector miss (`browser_read h1` on a page without an `h1`) rendered as a red "Browser read failed" row whose detail text is the untrusted-content banner, not the reason.

### L6. Composer `AXValue` is not bound; AX `confirm` ignored (LOW, accessibility)
Setting `AXValue` on the thread composer ("Message the agent"), the ⌘K search field and the iOS composer shows the text but never reaches the model: Send stays a no-op and focusing the field wipes it. The New thread page field, the automation sheet and the directory chooser honor it. Dictation and assistive input tools that set values will fail on the main composer. After opening a terminal, activating the app focuses the terminal, not the composer.

### L7. Commands are scattered across four inconsistent surfaces (MEDIUM)
- Menu bar Agent: Focus, Rename, Stop, Choose Model, Inspect Subagent, Previous/Next Turn, Next/Previous Agent, Delete Agent.
- ⌘K palette (`ShepherdViewModel+Palette.swift`): New thread/agent/space, Hide sidebar, Settings, Open Hosts/Extensions/Design systems, Rename, Pin, Choose model, Toggle fast mode, Review diff, Review PR changes, terminal items, Rename/Remove space. Nothing for Automations, Projects, Designs, Delete, Stop, Move to space, Fork, Copy transcript, Appearance, side pane tabs.
- Thread header "…": Refresh Thread, Rename…, Pin.
- Sidebar row context menu: Rename, Pin, Move to Space, Fork from Here, Copy Transcript, Review Changes, Open in Finder, (Finalize Worktree…), Delete Agent.
Fork, Copy Transcript, Open in Finder and Move to Space exist only on right-click; Stop only in the menu bar and composer; Refresh only in the header menu. The menu bar also carries "Save Space File" with no action, a top-level Appearance menu and View ▸ Component Gallery in a user build. (ux-mac UM-06 reaches the same conclusion statically.)

### L8. Leaked overlay glyph after visiting Settings ▸ Instructions (HIGH, visual)
The Instructions editor draws a "⊖" glyph in a rounded box at its top-left. After leaving that page the glyph stays at the same window coordinates on Skills, Extensions, Slash commands, MCP servers, Remote, Keyboard, Advanced and Experiments, over toggles and rows. Pages visited before Instructions did not have it. The same glyph appears inside the automation sheet's Prompt editor and the New agent sheet's Prompt editor, so it belongs to the multi-line editor component; the bug is that it is not removed with its page. (shot `24-settings-Experiments.png`, glyph at ~300,407)

### L9. Settings ▸ Instructions says "0 characters" right after the import said instructions came over (MEDIUM)
The import copies AGENTS.md (4.5 KB) and APPEND_SYSTEM.md (10.6 KB) into `<support>/pi/` (by design, docs/pi-home.md). The page edits `<support>/instructions/`, which does not exist yet, so it shows two empty files. The only hint is a sidebar note. Users will paste their AGENTS.md again and send it twice.

### L10. Settings walk grows app RSS 240 → 376 MB (MEDIUM, needs profiling)
Visiting the 17 pages once with no edits added ~135 MB to the app process (Appearance and Terminal +66 MB, Pi +7, Skills +7) that did not come back in the next 20 minutes. Check for retained page views or caches that never evict.

### L11. Settings ▸ Remote copy ignores the iPhone/iPad app (LOW)
"Connect to agents on other Macs over your VPN, or let other Macs connect to this one." Nothing says the iOS app pairs the same way or where to find the token for it.

### L12. "Default model" means three different things (HIGH)
- A thread sends `--model cpa/gpt-6-astra` and fails (L1).
- An automation's Run now launched pi with no `--model` (app.log) because Settings ▸ Agents says "Use the agent's default" and passes nil; pi, not knowing `cpa`, picked `claude-opus-4-8` on its own, and the run went to Anthropic, a provider the user never chose for it.
- A Project conversation's composer says "Default model · Medium" and did the same, failing with "The request to Anthropic failed".
The Automations page listed that run as "finished · 1s" (later "finished · 1m ago") while its sidebar row said "failed". The automation sheet has no model field.

### L13. Imported OAuth login is stale but Settings says "Signed in" (HIGH)
The Anthropic OAuth copied from `~/.pi/agent` returns `invalid_grant` on first use (the refresh token had rotated in the terminal pi, exactly what the row's own warning predicts). Settings ▸ Sign-in still reads "Anthropic · Signed in · Claude Pro or Max" (an attention dot appeared on the Sign-in row only after the second failure). The turn error card offers Retry (fails the same way) and Details; no "Sign in again", no link to Settings. The first-launch "Something missing" check only tests that a login exists. (shot `30-automation-thread.png`)

### L14. New automation sheet fields are unlabeled (LOW, accessibility)
Name and Folder are `AXTextField`s with no label; Prompt and the On toggle are labeled.

### L15. Default subagent profiles ask for tools pi does not have, so scouts can only read (HIGH)
`shepherd_child_agents` lists `tools: [read, grep, find, ls]` for scout, planner and reviewer. pi has no grep/find/ls tools; the child silently gets `read` only (the audit's own worker lanes show `tools: ["read","bash","edit","write"]` with grep/find/ls dropped). A scout spawned from a thread reported "I only have file-read tools (no directory listing or shell)", failed `read` on the repo root with EISDIR and blocked on a question to its parent. Settings ▸ Subagents does not warn that a listed tool does not exist. (shot `38-subagent-retry.png`)

### L16. Parent thread dies with "The provider returned no answer or tool call" after starting a child (HIGH, reproduced twice with openai-codex/gpt-6-astra)
After the `shepherd_child_start` result, the next assistant message was empty (`text:"" error` in the session file, rows 22–28). This is treated as a provider failure and retried 4 times in 20 s; the user's Retry did 4 more (8 tries, 1 m 20 s). The parent is now "failed", the child's question never reaches it, and the Subagents pane shows the child as "done · 3 turns" in the header and "Waiting on parent" in the list. Each retry appends a `shepherd.failed-checkpoint.v1` + `checkpoint-recovery.v1` pair to the session file. Needs a second model to decide whether it is model-specific; the retry policy spends 8 identical requests either way.

### L17. Clicking the subagent row under the thread does nothing visible (LOW)
The row is a button with help "Opens the run"; pressing it changed nothing until View ▸ Subagents opened the side pane.

### L18. Idle pi processes cost ~150 MB RSS each (MEDIUM)
3 idle agents + 1 shell: 466–482 MB; 11 idle agents: 1.70 GB. Ten idle threads sit near 1.5 GB before a model is called. Relaunch only starts the visible agents (good, L20), but L23 defeats that.

### L19. Auto-names collide and the sidebar cannot tell 8 similar threads apart (MEDIUM)
Eight prompts "Scale test N: … haiku about N" became "List files and celebrate eight/seven/six", "List files and haiku five/four", "List files and compose two haiku"…: the only distinguishing word is the last one, which the 232 pt sidebar truncates away ("List files and cele…" ×4). The user's own distinctive token ("Scale test 4") never made the title; rows have no tooltip with the full name.

### L20. Relaunch loses status and keeps ghosts (MEDIUM)
Quit with 12 agents: clean, ~1 s, no orphan pi. Relaunch: 2 pi processes start (lazy, visible-first), the rest start in ~100 ms when selected. But every row comes back "idle", including the thread that could not start and the one that failed 8 retries; Done/Needs you/Automations groups are empty (seen-state is per launch, as documented for iOS); the failed parent still says "1 subagent · 1 waiting on parent · 6m" with a Stop button although the child died with the app. A tool row reads "Ran a command  paste ,  · 3.9s" (summariser keeps the first token and a comma from `paste -sd, …`).

### L21. New project sheet (LOW)
Half the sheet is empty below the Spaces picker; it has both an ⓧ and a Cancel. The sheet is absent from the accessibility tree (no fields or buttons), so VoiceOver cannot create a project.

### L22. Restored terminal tab on the Mac is a dead surface (HIGH)
After relaunch the thread's terminal tab shows an empty pane with only a cursor; typing does nothing; the tab's + menu shows "Kill process" disabled, so the Mac tab has no session bound. app.log shows no shell respawn at relaunch (docs say every terminal respawns): the shell was spawned only when the iPhone attached (`created 80x24`), and that session never bound to the Mac tab. A new terminal from + works (148x16). The + menu says "New terminal in the worktree" for a checkout thread. (shot `57-mac-terminal-after-click.png`)

### L23. Pairing a phone wakes every idle agent (HIGH, performance)
Before the phone connected: 2 pi processes. Within a minute of the iOS Home screen loading: 13 (eight new at 14:42–14:43), +1.2 GB RSS, although the phone opened two threads. Home's per-thread snapshot requests start a pi session for each idle agent to serve history. On a 30-thread Mac that is 30 node processes the moment the phone unlocks. (perf-remote-ios RI-05 predicts this statically.)

### iOS observations (not numbered, see ux-ios.md and feature-parity.md for the static view)
- Pairing works first try with the Mac's token (shots `ios-03-home.png`, `ipad-22-home.png`); the Mac log shows `remote client 'Shepherd iOS' authenticated`. Phone → Mac send → reply ("pong") in 10 s.
- iPhone Home names the design by its prompt ("A simple login page: email field…") while the iPad sidebar and the Mac call it "Sign in". iPad lists the design inside Recents; the Mac gives designs their own group.
- iPhone Home shows "demo · 9m ago" for some rows and only "demo" for others; the thread that cannot start shows no status. The iOS thread header says "Failed" for the thread the Mac sidebar calls "idle" after relaunch.
- Thread "…" menu: Files, Terminal, Subagents, Browser, Stop agent, More… (Refresh, Rename…, Pin, Delete worktree agent…). "Terminal" is a silent no-op on a thread that has no terminal; on a thread with one it opens full screen with a + tab, and the starship prompt's Nerd Font glyphs render as "?" boxes (no Nerd Font on iOS).
- The subagent page shows "Waiting on parent · 12s" where the Mac shows "12m".
- iPhone composer hides model/thinking/speed; the iPad composer shows "/ commands · gpt-6-astra · Thinking Medium · Speed Standard" chips.
- The iOS nav-bar buttons (Save, Cancel, Back) are not in the accessibility tree exposed through DeviceHub; the form fields are.

## Measurements

| Moment | App RSS | App CPU (ps) | pi/zsh descendants | Descendants RSS |
| --- | ---: | ---: | ---: | ---: |
| First launch, import sheet | 168 MB | 0 | 0 | 0 |
| One thread done, idle | 231 MB | 0 | 1 | 180 MB |
| Review + Files + Browser + Terminal open | 277 MB | 0.9 | 2 | 188 MB |
| After the 17-page Settings walk | 376 MB | 2.0 | 2 | 137 MB |
| 3 agents + worktree + subagent | 418 MB | 0.2 | 4 | 466 MB |
| 8 more threads sent (11 agents) | 454 MB | 41 | 12 | 1.85 GB |
| 11 agents idle, 70 s later | 460 MB | 1.6–4.4 (top) | 12 | 1.70 GB |
| Relaunch, 12 agents restored | 178 MB | 0 | 2 | 247 MB |
| After iPhone + iPad paired | 234 MB | 1.3 | 15 | 803 MB |

- First-launch import of the user's pi: 6.9 s (bounded at 30 s). Quit with 12 agents: < 1 s, no orphans.
- A thread with tools from Send to named and done: ~25 s (gpt-6-astra). A design board: ~40 s.
- Idle app with 11 agents samples at 1.6–4.4 % CPU in a Debug build; the only non-wait frames are AttributeGraph updates from the relative-time labels ("33s ago").
- Scrolling and streaming felt smooth at this transcript size; no beachballs were observed in the hour. Longer transcripts were not tested here (see perf-mac-views MV-04/05 and perf-sessions SS-02 for the static risks).

## Reproducing

The driver lives outside the repo at `/tmp/shepherd-audit/` (`launch.sh`, `axtool.swift`, `shot.sh`, `metrics.sh`, `type.sh`, `simclick.sh`, `app.log`, `metrics.log`, `shots/`, `ios/`). Any of L1–L23 can be reproduced by: build the Dev scheme, copy the app with a new bundle id, launch with `SHEPHERD_SUPPORT_DIR` on a scratch path, and follow the step named in the finding. L1/L12/L13 need a `~/.pi/agent` whose default model comes from an extension and whose OAuth has rotated; L23 needs the iOS client paired and Home on screen.
