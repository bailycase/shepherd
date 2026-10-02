# Missions

> Not built yet. Read only when asked to build Missions: the model, getting there, the map and its parts.

## Mission components (not built yet)

**Not built yet.** The NWAgents board's second half (dark and light): the components Missions
will use (Missions are not built; see "Where Shepherd departs from the boards"). Build them into
`Components/Agents` when Missions land.

- **`NWMissionNode`** on a dotted canvas (Mission graph): the canvas is `bgSunken` with 1pt
  `lineStrong` dots every 18pt, padding 20, radius 8, a `lineSubtle` line; stages run left to
  right with arrows between them. A node is 200pt wide, `bgRaised`, radius 8, padding 9×11, 6pt
  gaps: the name in `ui` semibold with its `NWStatusPill` trailing, the role as an `NWTag`, and a
  Geist Mono 10.5 `textSecondary` line that truncates ("DesignTokens.swift +214", "edit
  ThreadView.swift", "asks: keep alias?", "failed 3 of 3 tries", "+ ~250k · 15m", "after
  Verify"). States: done, running, needs you and failed with a 1px `lineSubtle` line; the
  selected node has a 1.5pt `running` line and a 3pt `runningTint` ring; proposed has a 1.5pt
  dashed `running` line and a "proposed" `NWTag` in place of the pill; draft or queued has a 1pt
  dashed `lineStrong` line and the outlined Queued pill.
- **`NWInboxItem`** (mission control inbox): padding 12×14, 6pt gaps, radius 8, a 1px
  `lineSubtle` line and a 2pt leading rule in the state's color. First line in `caption`
  `textSecondary`: the state dot (glowing while it needs you), the kind in semibold
  `textPrimary` ("Question"), " · ios · Ship native UI v2", and the age trailing in mono
  `textTertiary` ("2m"). Then the question in Geist 13 medium, then its answers as `s` buttons
  (the first primary, the rest secondary) and Open (ghost).
- **`NWClaimRow`** (evidence review): padding 10×12, 6pt gaps, radius 8, a `lineSubtle` line;
  the claim in `ui` medium (line height 1.4) with its verdict pill trailing, then its evidence
  as `NWTag`s ("3 tests", "before / after", "spec §5"). The verdicts are Verified, Contradicted
  and No evidence; the board draws only Verified (`done`), so choose the other two's states
  when building.

## Missions

**Not built yet.** Missions carries one goal across every repo it touches, from a sentence to merged
PRs, as a map you supervise. It is designed on the canvas's Missions page (MX* boards), the Night
Watch system pages "Missions map" (MXVocab, MXVocabLight) and "Mission screens" (NWMissions,
NWMissionsLight), the Mac's Missions destination (NavMissions), and the phone and iPad boards
(MobileMissions, MobileMission, MobilePatch, MobileMerge, iPadMissions, iPadMissionMap,
iPadMissionReview). It is planned for after the native app is stable: build it only when asked, and
then build it to this section.

What exists today is data, not UI:

- `Extensions/shepherd-missions.ts` keeps mission records for native subagents and workflows
  (`shepherd_mission`; [docs/native-subagents.md](../native-subagents.md) › Missions): a title,
  objective, status, runs and attachments per project. Nothing draws them, and none of the map's
  ideas (lanes, stations, the contract, the train) map onto them. They are off: the model is given
  no mission tool or parameter, and no record is written for a run, unless `SHEPHERD_MISSIONS=1`
  (docs/context-budget.md).
- pi's `/missions` command (native subagents) prints those records as text, and nothing else in
  the app says mission.
- Parts a mission reuses are built: a station's transcript and steer field are the subagent
  inspector's (Side pane), its worktree is `GitWorktree`'s, a merge builds on Finalize
  ([docs/worktrees.md](../worktrees.md)), and the review gate is drawn with the review pane's
  parts (`NWFileHeader`, `NWDiffView`, `NWHunkHeader`, `NWInlineComment`).

Strings in this section are the boards' own. The boards place every mission on a host "daemon"; Shepherd has no daemon today
(AGENTS.md), so where a mission runs is still to be decided.

### Missions: how a mission runs

A mission moves through four phases, Goal → Map → Run → Done (`NWPhaseBar`). MXFlow draws its steps
top to bottom in stages (Start, Describe, Draft, Review, Clear the fog, Launch, Run, Verify, Review,
Land, Done) and four actors, drawn as columns: **You** ("you decide, answer, approve"), **Shepherd**
("planner + validator, on the daemon"), **Workers** ("one agent session per station"), and **Repos &
CI** ("branches, checks, PRs"). Lantern marks the only steps where you act; everything else runs on
the host without you.

1. **Start a mission** (you): ⌘K → New mission, Missions ▸ New mission, `/mission` in any thread, or
   paste a ticket or pick a saved map. Every way in opens the same planner chat.
2. **Say where you want to end up** (you): one message, like to any agent; a ticket or spec is
   optional. Answer its scope questions in the same chat.
3. **Planner builds the brief**: reads the ticket and linked docs, searches your repos to pick the
   lanes, gathers context, sizes the limits; the validator drafts the contract alongside. It only
   asks what changes the scope; everything else becomes fog on the map.
4. **Planner drafts the map** ("Draft the map"): one lane per repo; stations, checks, forks, the
   merge order. Anything it can't decide becomes fog, with a question or research station on its
   edge.
5. **Research starts right away**: research stations are read-only sessions (code, docs, registries;
   no branches, no code).
6. **Review the map** (you): rewire stations, change a model or a budget, bypass a station, or ask
   the planner in words ("split orders into outbox + relay stations").
7. **Answer the questions** (you): only the decisions that need you, on the edge of the fog.
8. **Answers become patches**: real stations replace the fog. Apply one, edit it, or let fog patches
   apply on their own within budget.
9. **Launch** (you): leftover fog is fine; known ground runs while fog clears ahead of it. From
   here you can walk away.
10. **Lanes spin up**: per station, a worktree on a mission branch in its repo (`orders-svc @
    mission/anl-214`) and its own session that gets only its inputs.
11. **Stations do the work** until their own "done when" passes, then hand off outputs (a branch, a
    tag, a summary). One at a time, except where the map forks.
12. **Station checks**: a command after each station (`buf`, `go test`). Pass → next station; fail →
    back to the worker, up to 2 retries; still failing → pause.
13. **Validator runs the contract** after the join: builds the e2e stack from every branch, seeds
    it, runs the hidden checks.
14. **Route the findings**: all pass → your review; a finding with an owner → back to that station,
    automatically; no owner → off the map.
15. **Off the map** (you): the mission pauses and the planner proposes a patch; re-runs follow the
    data wires. Apply it and the mission resumes.
16. **Review the PR set** (you): one review across every repo, with the validator's evidence.
    Approve, or send changes; they go back as findings.
17. **Merge train**: PRs merge one by one in dependency order, each waiting for its CI; tags are cut
    on the way (`contracts #412` → `v1.8.0`).
18. **Done**: the route taken, the contract (now visible), merge order and spend per repo, and Save
    as map template.

Shepherd interrupts you for four things only: **a question** (a decision on the fog's edge only you
can make), **a patch** (fog cleared, or the run left the map), **a stuck station** (still failing
after its retries, or out of budget), and **the final review** (approve the PR set before anything
merges). During the run, all you do (MXInputs) is answer questions, apply patches (or let fog
patches auto-apply), steer a station if you want to ("use the existing outbox"), and approve the PR
set. What you no longer do (MXFlow): write code, babysit agent threads, copy context between
repos, open or merge PRs by hand, decide merge order.

**What you put in** (MXInputs): one message about where you want to end up, optionally a ticket or a
file. There are no forms: the planner builds the brief, and you change anything by saying so.

| In the brief | How the planner gets it | To change it, say |
| --- | --- | --- |
| Destination | Rewritten from your message and the ticket | "also track refunds" |
| Lanes | Searches your repos for owners, producers and consumers; asks if the scope is ambiguous | "add payments-svc" |
| Context | The ticket and linked docs, the relevant protos and schemas, each lane's README and AGENTS.md | drop a file in the chat |
| Validation contract | A validator agent drafts it from the goal and the code; hidden from workers | "also check p99 latency" |
| Test environment | Reuses what the repos already have and extends it to the other lanes | "use staging instead" |
| Size & limits | Estimated from the lanes and checks, with headroom ("~4.1M · ~3h → limits 6M · 4h · 3 forks") | "cap it at 3M" |
| Host | Your default host | "run it on this Mac" |
| Models | Planner and validator on your default; the planner picks per station | "use opus for orders" |
| Open questions | Asked in the chat only if they change the scope; the rest become fog | answer now or on the map |

Each station also carries, editable in the map's inspector: **Goal** (what it must achieve in its
own repo), **Model** (overrides the mission default), **Inputs** (data wires in: a branch, a module
version, a spec), **Outputs** (data wires out: branch, tag, summary), **Exits** (where pass, fail
and budget go), **Done when** (checks the worker can see and run), **Budget** (tokens and time), and
**Bypass** (skip it without deleting it).

### Missions: getting there

**Not built yet.** Missions live in the same window and sidebar as threads, and every station is a
thread you can open (MXNav):

- **The sidebar's Missions destination** opens every mission (running, drafts, done) with New
  mission at the top right, and opens where the thread was. It sits in the boards' destination list
  (New thread, Missions, Designs, Automations, More), which the Mac's sidebar does not have (see
  Sidebar).
- **Needs you**, under the destinations, pins a mission (or a thread) waiting on you with its
  question ("retention?" in `lanternText`, mono 10) until you answer.
- **⌘K** from anywhere (the sidebar has no field; the palette is keyboard-first): "New mission…",
  or part of a mission's name to jump to it.
- **`/mission`** in any thread ("Turn this thread into a mission") hands the conversation to the
  planner: you land in its chat with the brief already started. `/missions` is "Open Missions". pi's
  native subagents runtime already registers a `/missions` that prints records; the two must not
  collide.
- **The thread's ••• menu** gains "Turn into mission…" (a 13pt symbol), the same as `/mission`.
- **A notification** for a mission opens the station that asked, even if the app was closed (the
  Mac banner: the crook, "Checkout funnel events needs you", "retention: raw events for 30 days or
  13 months?", "now"). Everything that doesn't need you stays in Recents.

Three places, one hop apart (MXNav › Moving between the three places): a **thread**, headed by its
space and title ("Shepherd / Investigate SwiftUI…"); the **mission** (click it in the sidebar; ⌘[
goes back), headed "Missions / Checkout funnel events", where the sidebar tucks away to give the map
room and ⌘0 brings it back; and a **station thread** (Open as thread, at the foot of a selected
station's inspector), the station's own session shown like any thread, whose breadcrumb ("Checkout
funnel events › orders", the mission in `lanternText`) returns to the map and whose composer is the
station's steer field ("Steer orders…"). ⌘0 is the boards' chord; the app's show-sidebar chord is
⇧⌘S (Keyboard), and a new chord goes through `KeybindingsStore` like every other.

**The Missions page** (NavMissions: header, state tabs, and the Mission · Lanes · Route · Spend ·
Host table) is specified under Destination pages › Missions page; build it from there. Its
Templates tab is below (Missions: templates). A mission's glyph is a folded map (14pt on the Mac,
`lanternText` while it needs you, else `textSecondary`; 15pt on iPhone and iPad).

**Mission states** and the words their pill says (`NWStatusPill`; lantern pills glow):

| State | Pill | Color |
| --- | --- | --- |
| New, before the first message | New | outlined, `textTertiary` dot |
| Waiting on you, in a list (Missions page, iPhone, iPad) | Needs you | attention |
| The planner is working | Planning | running |
| The planner is asking | Planning · 1 question | attention |
| Map drafted, not launched | Draft | outlined |
| A patch waits for you | Patch ready | attention |
| Running | Running | running |
| A lane is stuck, or held by a lock | Running · 1 lane stuck, Running · 1 lane held | attention |
| Paused | Paused · off the map, Paused · out of budget | attention |
| The PR set waits for you | Review · needs you | attention |
| The train is merging | Merging · 2 of 4 | running |
| Finished | Done (Merged in lists) | done |

### Missions: chrome and phases

**Not built yet.** Every Mac mission screen shares one header, `NWMissionHeader(mission)`
(NWMissions › Mission chrome): where you are, which phase, what it has spent, where it runs, and the
one action that fits the state.

- **52pt** on `bgWindow` with a hairline beneath, 10pt leading and 12pt trailing padding, 12pt gaps.
  Leading: a 28pt sidebar button (every mission board draws it, docked sidebar or not), then the
  breadcrumb: a 14pt folded-map glyph and "Missions" in 13 `textTertiary`, "/", the mission's name
  in 13/600 ("New mission" before it has one), and its state pill.
- **Centered: `NWPhaseBar`** (`.goal`, `.map`, `.run`, `.done`), items 24pt tall, 9pt padding,
  radius 6, 2pt apart with a 9pt chevron in `textTertiary` between: a finished phase has an 11pt
  check in `done` and its word in 12/500 `textSecondary`; the current one sits on `bgSelected`,
  12/600 `textPrimary`, its number in mono 10 `lanternText`; a later one is `textTertiary` with its
  number in mono 10. Review and the merge train are part of Run.
- **Trailing** (14pt gaps): the meters once the mission runs (the Map phase shows an estimate
  instead, mono 11 `textTertiary`: "est. 4.1M of 6M · 3h10 of 4h"), the host chip, and the one
  action:

| State | Action |
| --- | --- |
| New, Planning, Review, Done | none |
| Draft, Patch ready | **Launch** (primary, a 13pt symbol, ⌘⏎) |
| Running, stuck, held | **Pause** (secondary, a 13pt symbol) |
| Paused | **Resume** (secondary, disabled at 40% until the pause is resolved) |
| Merging | **Pause train** (secondary) |
| While the Stop dialog is up | **Stop** (`.danger`, drawn pressed on `bgSelected`) |

**`NWBudgetMeter(.tokens | .time, used:, cap:)`**, 92pt wide: a mono 10 line ("tokens" in
`textTertiary`, then "2.3M" in `textSecondary` and "/ 6M" in `textTertiary`), 3pt under it a 3pt
bar, radius 2, on `lineSubtle`. The board's rule is "neutral, then lantern past 80%, red at the
cap"; the screens fill it `running` while the mission runs, `lantern` while it is paused for you,
`failed` at the cap, and `done` once finished. On the phone the bar is 4pt with the value in
`textPrimary`.

**`NWHostChip(host)`**: 24pt, 8pt padding, radius 6, a `lineSubtle` border, a 12pt host symbol, the
name in mono 11.5 `textSecondary`, and a 5pt `done` dot (no board draws another state). ShepherdUI's
`NWHostBadge` (a smaller mono chip with no symbol or dot) is the row-sized relative.

Mission screens hide the sidebar to give the map room; New mission, intake, starting from a template
(MXTemplateStart) and the Templates tab keep it docked.

### Missions: the map

**Not built yet.** The map (MXVocab, MXVocabLight) is drawn with stations, wires, lanes and fog,
laid out automatically top to bottom. You change the logic, never the positions.

**Stations.** Every station has a kind, a lane (its repo) and a state. Decisions are diamonds,
because they end in labelled outcomes rather than work.

- **Work stations** are 190×44 cards, radius 8, `bgRaised` with a 1px `lineStrong` border, 8pt gaps,
  9pt leading and 10pt trailing padding: a 22pt symbol box (radius 6, `bgSunken`, `lineSubtle`
  border, a 12pt symbol) and two lines, the name in mono 12/600 over a 10.5 `textTertiary` subtitle,
  with an optional trailing mark.
- **Decisions** draw a dashed border and, in place of the box, an 18pt diamond (a square turned 45°,
  radius 3, `bgSunken`, `lineStrong` border) holding a 10pt symbol.

| Kind | Call site | Drawn as | Example |
| --- | --- | --- | --- |
| Agent | `NWStation(.agent(role: .worker), name: "orders")` | work station; a trailing estimate in draft | "orders", "worker · fable-5-1", "~900k"; its own session and worktree in its lane's repo |
| Check | `NWStation(.check("go test ./..."))` | 172×32, radius 6, `bgSunken`, `lineStrong` border, a 12pt terminal symbol, the command in mono 11 `textSecondary` | a command; its exit code picks the edge |
| Contract | `NWStation(.contract(mission.contract))` | work station | "validator", "e2e · 11 hidden checks"; workers only get findings |
| Merge | `NWStation(.merge(pr: 318))` | work station | "merge #318", "orders-svc"; one per repo, chained in dependency order |
| Research | `NWStation(.decision(.research))` | decision | "event-audit", "research · find sources"; runs without you and clears fog with evidence |
| Question | `NWStation(.decision(.question))` | decision with a dashed `lantern` border, a 3pt `lanternTint` halo and a glowing 7pt lantern dot | "retention", "you · 30d or 13 mo?"; glows until you reply |
| Prototype | `NWStation(.decision(.prototype))` | decision | "rollups", "prototype · 2 options"; builds throwaway options to pick from |
| Gate | `NWStation(.gate)` | work station, its symbol in `lanternText` | "review", "you · approve 4 PRs"; you approve or send changes back |
| Sub-map | `NWStation(.submap(template))` | work station with a second card (`bgSunken`, `lineStrong`) peeking out 4pt up and to the right | "registry", "map · Buf registry"; a saved map used as one station |
| Start | `NWTerminus(.start(mission.goal))` | 176×44, a 22pt circle with a 1.5pt `textSecondary` ring | "goal", "ANL-214 · 4 repos"; top of the map, holds the goal and inputs |
| Destination | `NWTerminus(.destination)` | 200×44, a 22pt circle with a 1.5pt `textPrimary` ring | "merged in order", "funnel live in analytics"; reached only when the contract passes |
| Fork / Join | `NWForkBar(lanes: 1...4)`, `NWJoinBar(.all)` | a 4pt bar, radius 2, across the lanes it spans, labelled at its right end in mono 10 `textTertiary` ("fork", "join · all") | parallel work only happens where a fork is drawn; a join waits for all (or any) |

**Station states** (`.stationState(_:)`). Color only ever means state: blue moving, green done, red
failed, lantern needs you.

| State | Border and halo | Name | Trailing mark |
| --- | --- | --- | --- |
| `.draft` | `lineStrong` | `textPrimary` | the estimate, mono 10 `textTertiary` ("~900k") |
| `.queued` | `lineStrong` | `textSecondary`, symbol `textSecondary` | a 7pt hollow ring, 1.2pt `textTertiary` |
| `.running` | `running`, 3pt `runningTint` halo | `textPrimary` | a 12pt spinner in `running` |
| `.done` | `lineStrong` | `textSecondary`, symbol `textSecondary` | a 13pt check in `done` |
| `.failed` | `failed`, 3pt `failedTint` halo | `textPrimary` | an 11pt xmark in `failed` |
| `.needsYou` | `lantern`, 3pt `lanternTint` halo | `textPrimary` | a glowing 7pt `lantern` dot |
| `.notTaken` | dashed `lineStrong`, the card at 42% | as it was, symbol `textSecondary` | as it was (the estimate stays); the route stays drawn |
| `.patchAdded` | dashed `done` on `bgWindow`, 3pt `doneTint` halo | `textPrimary` | "NEW" in mono 10/600 `done`; dashed green until applied |

- **Selected** (`.stationSelected(true)`): a neutral ring outside the state's border, 2pt of
  `bgWindow` then 1.5pt of `textPrimary`. Color stays reserved for state; lanes, kinds and selection
  are neutral.
- **Paused at a checkpoint** (MXBudget): a 1px `lantern` border, no halo.
- **A resolved decision** keeps its dashed border, turns its name `textSecondary`, shows the done
  check, and carries its outcome as a small chip on its top-right corner: 15pt, 5pt padding, radius
  4, `bgWindow`, a `lineStrong` border, mono 9.5 ("registry ✓", "13 mo" in `lanternText`). The same
  chip marks other facts on a station: "retry ×1", "1 of 11 failed" in `failed`, "patched" in
  `done`, "from fog", "re-run", "learned" in `lanternText`, the time on the destination ("2h58").

**Flow wires** (`NWFlowWire`). Flow is geometry: orthogonal lines with 10pt corners, round caps.

| Wire | Stroke |
| --- | --- |
| `.upcoming` | 2pt `lineStrong` |
| `.travelled` (with its outcome) | 2pt `textSecondary` at 75% |
| `.moving` (into a running station) | 2pt `running`, dashed 6/3, the dash advancing 18pt every 0.9s |
| `.notTaken` | 1.5pt `lineStrong` at 80%, dashed 3/4; kept on the map after the run |
| `.patch` | 2pt `done`, dashed 5/4 |
| `.retry(max: 2)` | 2pt `textSecondary` at 75% (drawn as travelled), from a check's side back up into its station's side with 9pt corners, and a chevron head (1.8pt); the only wire that goes up |

A fork or join bar takes its wire's color: `lineStrong` ahead, `textSecondary` once travelled,
`done` in a patch.

**Outcome chips** (`NWOutcomeChip(.fail(retry: 2))`) label every edge out of a check, decision or
gate: 18pt, 5pt padding, radius 4, `bgWindow`, a `lineSubtle` border, mono 10.5. `done` for "pass"
and "all pass"; `failed` for "fail", "fail · retry ≤2", "findings", "findings → owner", "no owner";
`textSecondary` for neutral results ("registry ✓", "none", "no"); `lanternText` for your answers and
gates ("13 mo", "approve", "changes", "key"); `wireData` with an 8pt pin for data ("events
v1.8.0-rc.1").

**Data wires and pins.** Data is string: a dashed bezier in **`wireData`**, 1.5pt, dashed 4/3 at
90%, leaving an output pin and entering an input pin (3.2pt circles filled `bgWindow` with a 1.5pt
`wireData` stroke). They are drawn for the selected station, or all of them in the Data view.
Re-runs follow data wires, so a contract change re-runs exactly the stations that read it. Call
site: `NWDataWire(from: buf.out(.events), to: orders.in(.events))`.

- **`wireData` is a new role**: `#d7a6ff` dark, `#8a3fb5` light (the syntax keyword colors). Add it
  the way "Adding a theme or a role" says.
- **`NWPinRow(pin)`** in the inspector: 28pt, radius 6, 6pt padding, a 10pt pin glyph, the name in
  mono 12/600, its type in mono 10.5 `wireData`, a spacer, the source or target in mono 11
  `textTertiary` ("← buf", "→ validator, #318"), and the value in mono 11 `textSecondary`,
  truncating at 150pt ("v1.8.0-rc.1", "none yet"). Inputs on the way in, outputs on the way out.
- **Pin types** (`enum PinType { case gitRef, goModule, … }`), each a 22pt chip (8pt padding, radius
  4, `lineSubtle` border, mono 11, an 8pt glyph): git ref, go module, proto package, doc, summary,
  findings, test output, migration, PR.

**Lanes, fog and frontier.** One lane per repo, the mission's own lane first. Fog covers what isn't
decided yet; the decision on its edge is the frontier.

- **`NWLane(repo:)`**: columns 218pt apart on the full map, divided by dashed 1px `lineSubtle`
  verticals. Each head is the repo in mono 11/500 `textSecondary` after a 12pt repo symbol in
  `textTertiary`, over its stack in mono 10 `textTertiary` ("buf · protos", "go · kafka → pg", "go ·
  grpc · outbox"). The mission lane reads "mission" and "orchestration", both tertiary. Cross-lane
  wires are the hand-offs between services.
- **`NWFog(reason:)`**: a dashed `lineStrong` region, radius 12, on `bgSunken` hatched at 135° with
  1px `lineSubtle` lines every 7pt, 8pt padding: an 18pt cloud in `textTertiary`, "Undecided" in
  12/600 `textSecondary`, and the reason in 11 `textTertiary` ("storage layout, partitions and
  rollups follow from retention"). A patch replaces it once the decision above it is resolved.
- **`NWFrontierChip(mission.frontier)`**: 26pt, 10pt padding, radius 6, `bgWindow`, a `lineSubtle`
  border, 11.5 `textSecondary`: "FRONTIER" in mono 10 tracked `textTertiary`, then "1 researching"
  (a 10pt spinner), "1 needs you" (a glowing 6pt lantern dot), "1 undecided" (a 12pt cloud). What is
  moving, what needs you, what is still fog.

**Rules** (the board's own):

- **The map grows downward.** Patches append new stations below; they never rewrite what already
  ran.
- **Flow is geometry, data is string.** Rigid orthogonal wires for control, soft beziers for
  hand-offs.
- **Color means state, nothing else.** Lanes, kinds and selection are all neutral.
- **Only retries go up.** Every other route reads top to bottom, in time order.
- **Off the map means pause.** When no route covers a finding, the mission stops and proposes a
  patch.
- **Workers never see the contract.** Only the validator reads the checks; stations get findings.

**The map canvas** (MXMap and every full-map screen): `bgWindow`, with an overlay bar 14pt from the
top and 16pt from the sides (8pt gaps): `NWSegmentedPicker` (small) **Flow | Data | Both**; a 1×18
`lineSubtle` divider; a zoom group (26pt, radius 6, `lineSubtle` border: zoom out, "100%" in mono
10.5 `textSecondary` 34pt wide, zoom in, as 22pt icons); **Fit map** (a 26pt circle with a
`lineStrong` border); a spacer; and the frontier chip, or the screen's own status chip in its place.
A legend sits 16pt from the bottom-left in mono 10.5 `textTertiary`, 14pt apart, showing only the
marks on screen: flow (a 2pt `textTertiary` stroke), data (a `wireData` bezier), undecided (a 16×10
hatched swatch), patch, not taken.

### Missions: shared parts

**Not built yet.** Mission screens are built from these parts (NWMissions), besides the map.

**The inspector** (a right column, 440pt; 520pt for the brief and Save as template) on `bgWindow`
with a hairline on its leading edge:

- **Header**, 14pt top and bottom, 18pt leading and 12pt trailing padding, a hairline beneath: a
  28pt symbol box (radius 7, `bgSunken`, `lineSubtle` border, a 14pt symbol in the state's color:
  `done` for a patch or Done, `failed` off the map, `lanternText` when it waits on you), the title
  (a station's name in mono 15/600, anything else in Geist 15/600) with a kind tag (18pt, 6pt
  padding, radius 4, `lineStrong` border, mono 10.5 `textSecondary`: "agent", "clears fog", "2 of 4
  merged"; `failed` or `lanternText` for "paused 11:46") and a live station's pill ("Running · 14m",
  "Stuck · 3 tries"). Its second line is 11.5 `textTertiary`: "lane" and a lane chip (20pt, 7pt
  padding, radius 4, `bgSunken`, `lineSubtle` border, an 11pt repo symbol, mono 11 `textSecondary`),
  or a sentence ("proposed by planner · claude-opus · 10:42", "1 of 11 contract checks failed ·
  nothing is running"). Trailing: ••• and close, 28pt icons.
- **Sections**, 16pt/18pt padding with a hairline between: a label in mono 10.5/500 caps tracked 5%
  `textTertiary`, then an optional note in 11 `textTertiary` on the right ("data wires in", "re-runs
  follow the data wires").
- **Fact rows**, at least 28pt, 12.5: the label 104pt wide in `textSecondary`, the value in mono 12
  with an optional mono 10.5 `textTertiary` note. A cost reads "4.1M → 4.8M of 6M": the old value
  and the arrow in `textTertiary`, the new one in `textPrimary`, the cap in `textTertiary`.
- **Change rows**, at least 28pt: a mono 600 mark in a 14pt column (`+` in `done`, `−` in `failed`,
  `↻` in `running`, `=` in `textTertiary`), the name in mono 600 (`textTertiary` for `=`), a
  description in `textSecondary`, and a meta in 11 `textTertiary`.
- **Log rows** ("Decisions so far", "Log"), at least 26pt, 12: the time in mono 10.5 `textTertiary`
  38pt wide, the subject in mono 600, "→" in `textTertiary`, the result in `textPrimary`, and who
  did it in 11 `textTertiary` ("research · 4m", "you", "auto · rule", "someone else").
- **Footer**, 12pt/14pt padding with a hairline above, 6pt gaps (10pt/14pt with 24pt buttons in the
  station inspector): ghost actions first, a spacer, then secondary actions and the one primary,
  which shows "⌘⏎" in mono 10.5 at 60% after its label. A destructive action (Stop mission) is
  `.buttonStyle(.nw(.danger))` (bordered, `failed` text), on the leading side.

**Asking you.** A mission only stops for you with a question or a short list of choices, and one of
them is always the planner's pick. None of this is a permission prompt.

- **`NWChoiceCard(option, isPicked:)`**: 11pt/12pt padding, radius 8, 10pt gaps, a `lineSubtle`
  border: a 14pt radio (1.5pt `lineStrong` ring on `bgRaised`; when chosen, a `lantern` disc with a
  6pt `textOnLantern` center), then the title in 13/600, tags, and a meta in mono 10.5
  `textTertiary` ("~150k · 10m", "+1 station · ~350k · 25m", "7M cap"), over a description in
  12/1.45 `textSecondary`. The chosen card has a `lanternText` border on `lanternTint`. The
  planner's pick carries "planner's pick" (16pt, 5pt padding, radius 4, a `lanternText` border, mono
  9.5 `lanternText`); the chosen retry holds its hint as an editable field (8pt/10pt padding, radius
  6, `bgRaised`, `lineStrong` border, 12.5/1.5).
- `NWChoiceCard(option, risk: .high)` turns the meta `failed` ("likely conflict").
- `NWChoiceCard(option).disabled(true)` stays visible at 45% with "not possible" as its meta and the
  reason as its description ("The contract needs this lane.").
- **The mission's question card** (`NWQuestionCard(question)` on the board; ShepherdUI already has
  an `NWQuestionCard` for the phone's agent questions, so this one needs its own name): 14pt/16pt
  padding, radius 10, `bgRaised`, a `lanternText` border while unanswered (`lineSubtle` once
  answered), a 15pt question symbol in `lanternText`, the question in 13.5/600, why it matters in 12
  `textTertiary` ("Changes the contract."), and the offered answers as secondary buttons with a
  ghost "Something else…". Answered, the chosen answer becomes a `lanternTint` pill with a
  `lanternText` border and a check, and the others fade to 40%.
- **`NWPlannerNote(note)`**, the planner's diagnosis above the choices: 12pt/14pt padding, radius 8,
  `bgSunken`, `lineSubtle` border; a header in 11.5 `textTertiary` with a 12pt symbol ("Planner's
  read · claude-opus · 11:52") over 13/1.55 text (13.5 in a station's tab).

**When a lane struggles**: enough evidence to decide without opening a transcript.

- **`NWAttemptRow(attempt)`**: 12pt vertical padding, a hairline above, 12pt gaps: a 22pt circle
  with the number in mono 11, border and number `failed`; then "Attempt 1" in 12.5/600 with mono 11
  `textTertiary` meta ("11:14 · fable-5-1 · 612k"), what it tried in 12.5 `textSecondary` with its
  diff stat, and its failure in a mono 11.5/1.55 block (11 on NWMissions; 7pt/10pt padding, radius
  6, `failedTint`, "--- FAIL" in `failed`). A repeat of the same failure collapses to its summary
  line with a "same failure" tag (18pt, `lineStrong` border, mono 10.5 `failed`).
- **`NWCheckpointRow(station)`**, a station paused at a turn boundary, committed and resumable: at
  least 32pt, 12.5: an 11pt pause symbol in `lanternText`, the station in mono 600 (96pt), its lane
  in mono 11 `textTertiary` (116pt), "turn 14 · clean at `a1f3c9e`" in `textSecondary`, and its
  spend in mono 11 `textTertiary`.
- **`NWSpendBar(lane, used:, planned:)`**: at least 26pt, 12: the lane in mono `textSecondary`
  (120–128pt), an 8pt track (radius 4, `lineSubtle`) filled `textTertiary` up to the plan and
  `lantern` beyond it, the plan marked by a 2×16 tick in `textPrimary` at 70%, and the value in mono
  11 (`lanternText` when over, "/ 1.3M" in `textTertiary`). A legend under the bars: "planned" (the
  tick) and "over plan" (a 12×6 lantern swatch).

### Missions: intake

**Not built yet.** **New mission** (MXStart) asks one question. The sidebar stays docked with
Missions selected; the header reads "Missions / New mission" with an outlined "New" pill, the phase
bar on 1 Goal, and the host chip alone.

- The column (40pt side and 60pt bottom padding, 28pt gaps): "Where do you want to end up?" in
  26/600 tracked −2%, over 13.5/1.55 `textSecondary` at most 560pt wide: "Describe the end state,
  like you would to any agent. The planner finds the repos, the context and the checks, and only
  asks what it can't work out."
- **The goal field**: 720pt wide, radius 10, `bgRaised`, focused (a `textTertiary` border and the
  composer's 3pt `bgSelected` ring); the field in 14.5/1.5 with 16pt padding, at least 76pt tall
  ("Add checkout funnel analytics so product can see drop-off at every step…"); under it an attach
  button (28pt, labelled "Attach a ticket, spec or screenshot") and Send (a 30pt lantern circle, at
  35% until there is text).
- **"OR START FROM"** (mono 10.5 tracked `textTertiary`), then a row of cards, 10pt apart, each
  12pt/14pt padded, radius 8, a `lineSubtle` border, `bgHover` on hover: a 13pt symbol and the name
  in mono 12/600, a line in 12.5 `textPrimary`, and a meta in 11 `textTertiary`. A ticket
  ("ANL-214", "Checkout funnel analytics", "assigned to you · Linear"), a thread ("continue from
  this thread", "thread · 42m ago"), a saved map ("Contract change", "protos → producers →
  consumers", "saved map · used 3×").

**Planner intake** (MXGoal): you chat, the brief builds itself. The pill reads "Planning".

- **The chat** (26pt top and 36pt side padding, at most 720pt, 14pt gaps) is a thread: your message
  as `NWUserBubble`; the planner's work as activity lines ("Read ANL-214 · 2 linked docs", "Explored
  7 repos · search 14 · read 22 · 48s"); prose at 13.5/1.6, at most 680pt, with inline code; and a
  scope question as the mission's question card. The composer card sits below (12pt/36pt/18pt
  padding): 720pt, radius 10, `bgRaised`, `lineStrong` border, "Reply to the planner, or tell it
  what to change…", attach and Send.
- **The brief** (a 540pt column): a header (14pt/18pt padding) with "Mission brief" in 15/600 over
  "built by the planner as you talk · click anything to change it" in 11.5 `textTertiary` after a
  10pt spinner while it builds. Then its sections (14pt/18pt padding, a hairline between; the label
  in mono 10.5/500 caps tracked 5% `textTertiary`, its source on the right in mono 10.5
  `textTertiary`):
  - **Destination** ("from your message + ANL-214"): 13.5/1.55 with inline code.
  - **Lanes · 4 repos** ("found by searching producers and consumers"): rows at least 30pt, radius
    6, 6pt padding, 12.5, hover `bgHover`: a 12pt repo symbol, the repo in mono 600 (132pt), its
    role in `textSecondary` ("emits OrderPlaced via outbox"), and its branch in mono 10.5
    `textTertiary` ("main"). A lane left out stays listed at 55%, its name struck through, with why
    ("out: you said checkout and orders only").
  - **Context** ("5 found"): chips 24pt, 8pt padding, radius 6, `lineSubtle` border, 11.5: an 11pt
    symbol, the name in mono, the kind in 10.5 `textTertiary` ("ticket", "linked", "× 4").
  - **Validation contract** ("validator · hidden from workers"): rows at least 26pt, 12, an 11pt
    symbol in `textTertiary` and the check, with its kind in mono 10.5 `textTertiary` ("cmd"); then
    "8 more · still reading analytics-ingest" in `textSecondary` after an 11pt spinner, and where it
    runs in 11.5 `textTertiary` ("Runs in `compose.e2e.yml` from analytics-ingest, extended with
    checkout + orders").
  - **Size**: fact rows for Estimate ("~4.1M tok · ~3h"), Limits ("6M · 4h · 3 forks", "sized from 4
    lanes") and Runs on ("build-01", "your default").
  - **Still open**: a 13pt cloud in `textTertiary`, the decision in mono 600, the question in
    `textSecondary`, and "becomes fog on the map" in mono 10.5 `textTertiary`.
  - **Footer**: "Nothing writes code until you launch." in 11.5 `textTertiary`, and **Draft the
    map** (primary, ⌘⏎).
- The planner asks only what changes the scope; an answered question stays in the chat as the chosen
  pill. Clicking anything in the brief changes it by telling the planner.
