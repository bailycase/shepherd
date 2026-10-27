# Shepherd audit, 2026-10-27

> Read when you want the ranked list of what is broken, slow or inconsistent across the Mac, iPhone and iPad apps, and where the evidence for each item is.

For the fix branch's results, decisions, validation and remaining work, see
[implementation status](implementation.md). The findings below describe the baseline, not
all-current defects. L15's original tool diagnosis has been corrected.

Whole-product audit at commit `d28f3511c`: an hour of using the apps like a new user (Mac, then iPhone and iPad paired to that Mac, real models), plus seven static read-through lanes of the code. Two models did the work so the findings are not one model's taste: Claude lanes on the Mac views, session server, surfaces/extensions and Mac UX; GPT-6 Astra lanes on the remote protocol/iOS, iOS UX and the device parity matrix; the live run drove `openai-codex/gpt-6-astra` as the agent model. Nothing in the repo was changed by the audit except this folder.

| File | What it holds | Labels |
| --- | --- | --- |
| [live-usage-mac-ios.md](live-usage-mac-ios.md) | What actually happened: first launch, every surface, 12 agents, relaunch, iPhone, iPad, with RSS/CPU numbers | L1–L23 |
| [perf-sessions.md](perf-sessions.md) | Session server, RPC, persistence, Changes engine, PTY | SS-01–18 |
| [perf-mac-views.md](perf-mac-views.md) | Mac SwiftUI views and view model | MV-01–20 |
| [perf-remote-ios.md](perf-remote-ios.md) | Remote protocol, `ShepherdRemote`, iOS app performance | RI-01–18 |
| [perf-surfaces-extensions.md](perf-surfaces-extensions.md) | Terminal/design/browser surfaces, bundled pi extensions, token budget | SE-01–22 |
| [ux-mac.md](ux-mac.md) | Mac UX pain points, dead or inconsistent controls | UM-01–26 |
| [ux-ios.md](ux-ios.md) | iPhone/iPad UX pain points | UI-01–19 |
| [feature-parity.md](feature-parity.md) | Full Mac vs iPhone vs iPad feature matrix, top 20 mismatches | FP-01–20 |

Every lane report ends with an "already good" section (do not re-fix) and a "needs runtime confirmation" list. Severity in all files is the user's experience, not code aesthetics.

## The short version

Shepherd's core loop is solid: a thread with tools, edits, tests, review and commit worked first try; 8 threads sent back to back all finished within a minute; quit was clean; relaunch restores lazily; the phone paired first try and round-tripped a message in 10 s. The bugs cluster in five places:

1. **Onboarding and model resolution.** The first launch can import a default model that cannot start, a login that no longer works, and instructions the Settings page then shows as empty, and says "Done" with a green check for all of it (L1, L13, L9). "Default model" is resolved three different ways by threads, automations and projects (L12).
2. **Things that look alive but are dead.** A restored terminal tab with no session (L22), a model picker disabled exactly when it is needed (L2), a subagent "waiting on parent" whose process died at relaunch (L20), a leaked editor glyph painted over other settings pages (L8), subagent profiles whose search tools are stripped by parent-tool filtering (L15).
3. **Server-queue and main-thread stalls under load.** Every Send waits on a whole-tree git snapshot (SS-01); every turn end re-projects the whole history on the server queue (SS-02); `pushMessage` waits on that queue from the main thread (SS-05); whole-state broadcasts fan out to every view on every status tick (MV-01, SS-09); screenshots and design exports encode on the main actor (SE-01, SE-02).
4. **Memory.** ~150 MB per idle pi (L18), a paired phone waking every idle agent (L23, RI-05), the phone keeping every visited history forever (RI-02), the Mac growing 135 MB just from visiting Settings (L10).
5. **Inconsistency across surfaces and devices.** The same action lives in one of four Mac menus with no overlap (L7, UM-06), ⌘-Return means "steer now" on the Mac and "queue" on an iPad keyboard (FP-01), names and statuses differ between Mac, iPhone and iPad for the same thread or design (live iOS notes), and the iOS app has no MCP, Spaces, subagent-profile or provider-recovery surface (FP-02, FP-05, FP-07, FP-16).

## Ranked list

Ordered by how many users hit it times how bad it is. "Where" names the file in this folder; the label there has the evidence and the smallest fix.

### Fix first (blocks or misleads users)

| # | Problem | Where |
| --- | --- | --- |
| 1 | First launch imports a default model that cannot start; thread shows raw pi stderr, Retry loops, model picker is disabled in that state | L1, L2, L3 |
| 2 | Imported Anthropic OAuth is stale (`invalid_grant`) but Settings says "Signed in"; the error card has no sign-in action | L13, FP-16 |
| 3 | "Default model" = nil for automations and projects, so pi silently picks another provider's model; thread path hard-fails on the same setting | L12 |
| 4 | Restored terminal tab on the Mac is a blank surface with no session; shell only spawns when a remote viewer attaches | L22 |
| 5 | ⇧⌘W (Close Window in every other app) deletes the selected agent with no confirmation or undo | UM-01 |
| 6 | Parent-tool filtering strips `grep/find/ls` from scout/planner/reviewer profiles; read-only children can only `read` | L15 |
| 7 | Parent thread fails with "no answer or tool call" after `shepherd_child_start`, auto-retries 8×, child's question is orphaned | L16 |
| 8 | Notifications are suppressed for the selected agent while Settings or any page covers it | UM-03 |
| 9 | iOS can send a message before a picked photo finished importing; the image lands on the next message | UI-01 |
| 10 | Leaked "⊖" editor glyph stays painted over later Settings pages | L8 |
| 11 | Every failure on the Mac is one blocking "Agent action failed" modal, often raw Swift error text | UM-02 |
| 12 | ⌘-Return steers on the Mac but queues on the iPad keyboard | FP-01 |

### Performance (measured or code-proven)

| # | Problem | Where |
| --- | --- | --- |
| 13 | Every Send waits for `git add -A` + `write-tree` of the whole working tree before pi gets the prompt | SS-01 |
| 14 | Every turn end re-fetches and re-projects the entire history on the serial server queue; all agents and terminals hiccup | SS-02 |
| 15 | Pairing a phone starts a pi process for every idle agent (2 → 13 processes, +1.2 GB) | L23, RI-05 |
| 16 | Whole `vm.state` replaced on every broadcast (~1/s per working agent), fanning out to sidebar, workspace, menus, palette | MV-01, MV-02, SS-09 |
| 17 | `pushMessage(toAgent:)` is `queue.sync` from the main actor: UI freezes while the queue is busy | SS-05 |
| 18 | ~150 MB RSS per idle pi; 11 idle threads = 1.7 GB | L18 |
| 19 | `browser_screenshot` encodes up to 24 JPEGs on the main thread; design PNG/PDF export rasterises 64 MP on the main actor | SE-01, SE-02 |
| 20 | iOS inbound push backlog is unbounded and delivered to main in one batch; visited thread histories are never evicted; disconnect blocks main behind decoding | RI-01, RI-02, RI-03 |
| 21 | Mac app grows 240 → 376 MB after one pass through Settings and does not come back | L10 |
| 22 | `commit()` runs a recovery-eligibility scan over all agents on every streamed token | SS-03, SS-04 |
| 23 | Thread view does O(rows) work per streamed chunk and re-renders every on-screen image per chunk | MV-04, MV-05, UM-14 |
| 24 | state.json: two measuring encodes + pretty print + fsync per mutation, plus a fresh SQLite connection per update when Projects is on | SS-06, SS-07 |
| 25 | Remote terminal attach replays 2,000 styled lines into a 2 MiB cap that disconnects on overflow | SS-08 |
| 26 | Workflow worker compiles a `vm.Script` every 10 ms for up to 30 min; `agent_wait` polls at 4 Hz; parked browser pages paint forever | SE-04, SE-10, SE-11 |
| 27 | Thread start costs 7,826 tokens of tools/prompt; `tools.children` (1,687) and codemode (~875) are the biggest kept groups | SE-14, SE-15 |

### UX and consistency

| # | Problem | Where |
| --- | --- | --- |
| 28 | Commands scattered over menu bar, ⌘K, header "…" and right-click with little overlap; Fork/Copy Transcript/Open in Finder/Move to Space are right-click only | L7, UM-06 |
| 29 | Settings ▸ Instructions shows "0 characters" right after the import said instructions came over | L9 |
| 30 | Import sheet hides its 10 problems (skipped skills) behind a green check | L1 |
| 31 | Relaunch resets every row to "idle" including failed and can't-start threads; Done/Needs you groups empty; dead subagents still "waiting" | L20 |
| 32 | Auto-names differ only in their last word, which the sidebar truncates; user's own distinctive words never reach the title | L19 |
| 33 | Destructive actions guarded inconsistently: designs confirm + undo, agents and automations neither | UM-04 |
| 34 | ⇧Tab in the composer cycles thinking level (keyboard trap); ⌘↑/⌘↓ collide with caret movement | UM-05, UM-10 |
| 35 | Unsent composer drafts are memory-only on the Mac; on iOS they survive navigation but not an OS kill | UM-09, UI-02 |
| 36 | Automation run shows "finished · 1s" on its page and "failed" in the sidebar; "1m ago" after relaunch for a 10-minute-old run | L12 |
| 37 | Subagent inspector header says "done · 3 turns" while the list says "Waiting on parent"; iPhone says "12s" where the Mac says "12m" | L16, live iOS notes |
| 38 | iOS live subagent transcript yanks the reader to the bottom on every turn | UI-03 |
| 39 | iOS push toggle reads "on" before the Mac acknowledged registration | UI-04 |
| 40 | Browser tool selector miss renders as a red "failed" row whose detail is the untrusted-content banner | L5 |
| 41 | Thread "…" menu on the Mac has 3 items; on iOS "Terminal" is a silent no-op for a thread without one | L7, live iOS notes |
| 42 | Accessibility: composer and ⌘K `AXValue` not bound; automation Name/Folder unlabeled; New project sheet absent from the AX tree; iOS nav-bar buttons not exposed | L6, L14, L21 |
| 43 | Menu bar: dead "Save Space File", top-level Appearance menu, View ▸ Component Gallery in a user build; palette "Review diff" row shows the wrong chord | L7, UM-18, UM-19 |
| 44 | No in-app notification preferences on the Mac; iOS notification denial offers prose but no route to Settings | UM-16, UI-18 |
| 45 | Terminal + menu says "New terminal in the worktree" for a checkout thread; tool row "Ran a command  paste ," | L22, L20 |

### Device parity (see the matrix in feature-parity.md)

| # | Problem | Where |
| --- | --- | --- |
| 46 | iOS has no MCP administration or auth recovery, no Spaces settings, no subagent profile editing, no provider account recovery | FP-02, FP-05, FP-07, FP-16 |
| 47 | Mobile Browser is the user's own session, not the agent's page; no Take over | FP-03 |
| 48 | Cannot revert one file from mobile review (whole-turn undo only) | FP-04 |
| 49 | Mobile terminal tabs cannot be renamed or have their process killed although the protocol supports it | FP-06 |
| 50 | Mobile Defaults omits service tier, naming model, compaction and context-trim policies | FP-08 |
| 51 | iPhone design flow lacks comment conversations, Tweak, Duplicate, Play; iPad ⌘K is a search box, not the command palette | FP-09–11, FP-17 |
| 52 | Same design named by its prompt on iPhone Home, "Sign in" on iPad and Mac; designs sit inside Recents on iPad but in their own group on the Mac; Mac "idle" vs iOS "Failed" for the same thread after relaunch | live iOS notes |

## Quick wins (an hour each or less)

- Make `isWatching` false while Settings or a page covers the thread (UM-03).
- Route ⇧⌘W through the worktree-delete confirmation, or add the design-style undo toast (UM-01).
- Permit pi's `grep/find/ls` in read-only children when the parent allows `read`, and report genuinely unknown profile tools (L15; original diagnosis corrected).
- `Task.detached` around `BrowserImageClamp.encode` and the design export encoder (SE-01, SE-02).
- Make `pushMessage(toAgent:)` async (SS-05).
- Equality-gate and frame-pace `onStateChanged` in `adopt()` (MV-01).
- Show the provider in the compact model picker and the composer chip (L3).
- Add a "Sign in again" action to the provider-failed error card and flip the Sign-in row to "needs sign-in" on `invalid_grant` (L13).
- Resolve "Use the agent's default" to a concrete model once, in the app, for threads, automations and projects alike (L12).
- Bind iOS ⌘-Return to the same alternate-send action as the Mac (FP-01).

## Larger work

- Move `projectHistory` and `estimate` off the server queue and make turn-end refresh incremental (SS-02); send the prompt first and snapshot the tree in parallel (SS-01).
- Live-field delta messages instead of whole-state broadcasts on the socket and in `adopt()` (SS-09, MV-01, RI-04).
- Serve Home digests from live state without starting pi for idle agents (L23, RI-05), and bound the iOS push backlog and thread-store retention (RI-01, RI-02).
- Rebind restored terminal tabs to their respawned sessions, or respawn at relaunch as the docs say (L22).
- One command registry feeding the menu bar, ⌘K, the header menu and the row menu (L7, UM-06).
- A first-party ask-the-user tool so Needs you works without an imported extension (L4).
- A capability-gated host surface on iOS for MCP status, Spaces inventory and provider sign-in state (FP-02, FP-05, FP-16).

## Caveats

- Debug build on a shared machine: absolute CPU/RSS numbers are high; ratios and behaviors are the evidence.
- Static lanes cite line numbers from `d28f3511c`; they go stale with the next refactor but the function names will not.
- L16 (empty assistant reply after a child start) was reproduced twice with one model; it needs one more model before blaming Shepherd's retry policy alone.
- The audit did not exercise goals, MCP servers, skills install, slash commands, design Tweak/Comments/Export, cross-space project workers, Live Activities, iPhone Duo or a second Mac as a remote host; the static lanes cover those by reading only.
