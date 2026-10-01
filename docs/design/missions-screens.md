# Missions: screens

> Not built yet. Read only when asked to build Missions: the run, review, failure states, templates, iOS and motion.

## Missions: map, patches and the run

**Not built yet.** From the Map phase on, the sidebar is hidden and the screen is the map canvas
beside the inspector.

**Map** (MXMap): the pill reads "Draft", the header shows the estimate and **Launch**.

- The canvas shows the frontier chip, and at its bottom-right an ask field: 440pt, 40pt tall, radius
  8, `bgRaised`, a `lineStrong` border and the popover shadow, a 13pt symbol, "Ask the planner to
  change the map…" in 13 `textTertiary`, and a 28pt Send.
- **The station inspector**: Goal (13/1.55); Runs as (Session "own agent session"; Model and Host as
  `NWPopupMenu`s in mono 12, "claude-fable-5-1", "build-01"; Worktree in mono 11.5 `textSecondary`,
  "orders-svc @ mission/anl-214"); Inputs ("data wires in") and Outputs ("data wires out") as pin
  rows; Exits ("flow wires out"): rows 28pt, an 18×8 arrow in `textTertiary`, an outcome chip
  ("done", "failed", "budget"), the target in mono 600 ("go test ./...", "retry ×2", "pause") and a
  note in 11 `textTertiary` ("then pause for a patch", "at 900k"); Station done when ("the worker
  sees these"): 14pt checkboxes, 12.5; Budget: Tokens and Time as `NWStepper`s ("900k", "40m"). Its
  footer: **Bypass** and **Remove station** (ghost, 24pt), a spacer, **Duplicate to lane…**
  (secondary, 24pt).
- Research stations start as soon as the map is drafted.

**Fog clears** (MXPatch): your answer becomes a patch on the map. The pill reads "Patch ready"
(glowing); Launch stays, the estimate updates.

- The map previews the patch: new stations in `.patchAdded`, the answered decision resolved with its
  outcome chip ("13 mo"), a bypassed route in `.notTaken`. The status chip reads "Previewing patch ·
  +2 stations · fog cleared" (26pt, radius 6, a `done` border on `doneTint`, a 12pt symbol in
  `done`, the detail in mono 10.5 `done`); the legend shows flow, patch, not taken.
- **The patch inspector**: "Patch" with the tag "clears fog"; Decision it resolves (the decision in
  mono 600 with its question in `textSecondary`, then your answer as a bubble, 10pt/12pt padding,
  radius 8, `bgBubble`, `lineStrong` border, 13/1.5, headed "You · 10:41" in 11 `textTertiary`);
  What changes (change rows); Why this shape (12.5/1.55 `textSecondary`); Cost; Decisions so far.
  Above the footer, a row (12pt/18pt padding) with "Apply fog patches automatically when they fit
  the budget" in 12 `textSecondary` and a switch. Footer: **Reject** (ghost), **Edit on map**
  (secondary), **Apply patch** (primary, ⌘⏎).

**Run** (MXRun): a mini-map beside the live station. The pill reads "Running", the meters fill in
`running`, and the action is Pause.

- **The left column** (640pt): the mini-map, 554pt tall with a hairline beneath: stations at 112×28
  (radius 6, 16pt symbol boxes at radius 5, 12pt diamonds, names in mono 10.5/600), checks at 112×22
  (mono 10), lanes 124pt apart with heads in mono 9.5/500, and an "Open full map" icon (24pt) in a
  bottom corner. Under it:
  - **Frontier** ("3 moving"): rows 30pt, radius 6, 12.5: a 12pt spinner, the station in mono 600,
    its lane and elapsed time in mono 11 `textTertiary`; the selected row on `bgSelected`. Then
    "then `join` → `validator` (e2e) once all three pass" in 11.5 `textTertiary`.
  - **Waiting on you**: "Nothing. Next check-in is `review`, approving the 4 PRs."
  - **Decisions so far**, log rows ("10:58 · buf → failed once, retried · auto").
- **The live station** fills the rest: the inspector header with its pill ("Running · 14m"), then a
  tab strip (18pt padding, a hairline beneath): tabs 36pt tall in 12.5, the chosen one at 600
  `textPrimary` over a 2pt `textPrimary` underline, the rest `textSecondary`: **Transcript**,
  **Evidence**, **Inputs · 2**, **Diff** "+84 −6"; on the right, mono 11 `textTertiary` "fable-5-1 ·
  612k of 900k". The transcript (22pt/28pt padding, at most 720pt) opens with "Started from `fork`
  at 10:58 with `events v1.8.0-rc.1` and `spec ANL-214`" (11.5 `textTertiary`, the data in mono
  `wireData`), then the thread's own components: prose, activity lines with their file rows, a
  running row (a 13pt spinner, "Running tests", the command in mono 11 `textTertiary`, the elapsed
  time in mono 11 `running`) and its streamed output in mono 11/1.6 `textTertiary` with the newest
  line `textSecondary`. At the bottom (12pt/28pt/16pt padding), the steer field: 44pt, radius 8,
  `bgRaised`, `lineStrong` border, "Steer orders — delivered before its next turn", and a 28pt Send.
  This is the subagent inspector's transcript and steer, in a station.

**Off the map** (MXOffMap): an upstream contract change; re-runs follow the data wires. The pill
reads "Paused · off the map", the meters fill `lantern`, and Resume is disabled.

- The map shows the failed validator (chip "1 of 11 failed"), the finding's "no owner" edge, and the
  proposed patch below it in `.patchAdded` ("schema-2", "buf breaking · rc.2", then "analytics ↻"
  and "orders ↻" with "re-run" chips, and "validator ↻"), its fork and join bars in `done`; an
  untouched lane says why in mono 10.5 `textTertiary` ("unchanged / doesn't read OrderPlaced"). The
  status chip reads "Paused at `validator` · previewing patch · +2 stations · 3 re-runs" (a `failed`
  border on `failedTint`).
- **The inspector**: "Off the map" with the tag "paused 11:46" in `failed`, "1 of 11 contract checks
  failed · nothing is running"; What happened (12.5/1.55 `textSecondary`); Finding (10pt/12pt
  padding, a 2pt `failed` rule on the leading edge, radius 0/6/6/0, `failedTint`, 12.5/1.55, footed
  by "from check 3 of 11 · the check itself stays hidden" in 11 `textTertiary` with a lock);
  Proposed patch ("re-runs follow the data wires", change rows, a skipped lane as `=` with
  "skipped"); Considered and rejected (each option in `textPrimary` over its reason in
  `textTertiary`, 12.5/1.45; "Validators can't weaken the contract."); Cost. Footer: **Stop
  mission** (`.danger`), **Edit on map** (secondary), **Apply patch** (primary, ⌘⏎).

**Done** (MXDone): route history, the contract revealed, merge order. The pill reads "Done", Goal,
Map and Run are checked and Done is current, the meters fill `done`, and there is no header action.

- The map shows the route it took: every station done, patch stations now plain with a "patched"
  chip, a station that came from fog marked "from fog", the destination selected with its time. The
  status chip (26pt, radius 6, a `lineSubtle` border) lists "21 stations", "2 patches", "1 retry",
  "2 decisions" 12pt apart in mono 10.5 `textSecondary`, then "1 route not taken" in
  `textTertiary`.
- **The inspector**: "Merged in order" with "Done · 2h58"; "4 PRs · 4.8M of 6M tokens · $44"; a
  summary in 13/1.6; **Contract · now visible** ("11 / 11" in mono 11 `done`), rows at least 24pt,
  12, a 12pt check and a mono 10.5 `textTertiary` note ("2,000 orders", "212 → 219ms"); **Merged, in
  order**, rows at least 28pt: the order in mono 10.5, a 13pt merge glyph in `done`, the repo in
  mono 600, the PR in mono `running`, its diff stat, and the time or tag ("13:02 · v1.8.0"); **Spend
  by lane**, rows at least 24pt: the lane in mono (120pt), a 6pt bar (radius 3, `lineSubtle`, filled
  `textTertiary` relative to the largest lane), the value in mono 11; **Planner's note for next
  time** (12.5/1.55 `textSecondary`). Footer: **Run again** (ghost, with a symbol) and **Save as map
  template** (primary, with a symbol).

## Missions: review, evidence and the merge train

**Not built yet.** **The review gate** (MXReview) is one pass over every PR, with the contract's
evidence beside the diff. The pill reads "Review · needs you".

- **Three columns** over a 56pt footer: the PR set (320pt), the diff, and the contract (420pt).
- **PR set**: a head (16pt/16pt/12pt padding) with "PR set" and "merges in this order", then "4 PRs
  · 21 files" in 12.5/600 with its stat and "CI green ×4" in mono 10.5 `textTertiary`, and a 4pt
  `.nwBar` in `done` beside "viewed 7 of 21" (11.5 `textTertiary`). PR rows are 32pt, radius 6,
  12.5: a 10pt disclosure chevron, the order in mono 10.5, the repo in mono 600, the PR in mono 11
  `running`, a spacer, files viewed ("3 / 3") in mono 10.5 `textTertiary`, and a 12pt CI check. An
  open PR lists its files, 28pt, inset 30pt: a 14pt Viewed checkbox, the path in mono 12 (the
  directory `textTertiary`, the name at 600 when selected), its stat; the selected file on
  `bgSelected`. At the bottom, **Planner's summary** (12/1.5 `textSecondary`).
- **The diff** is the review pane's: a 44pt file header on `bgSunken` ("orders-svc /
  internal/orders/" `textTertiary` and "place.go" at 600, the stat, Viewed, and Unified | Split),
  26pt hunk headers on `runningTint`, 22pt lines with 44pt number gutters and an 18pt sign column.
  Between lines sit **`NWDiffAnnotation`** cards (10pt/12pt padding, radius 8, `bgRaised`,
  `lineStrong` border): `.check(5)` pins a validator judgment to the lines it judged ("Check 5 ·
  Outbox only, never inline", "judge · passed" in `wireData`, a 13pt check); `.patch(id)` says why a
  line exists ("Added by a patch", "schema-2 → orders ↻" in `textTertiary`, a lantern symbol, traced
  to the finding that caused it). A draft comment ("You · draft", an 18pt avatar) offers **Send to
  the orders lane** (secondary, 24pt) or **Just a note** (ghost), with "Sending adds a patch: orders
  re-runs, then the validator." in 11 `textTertiary`.
- **Contract**: a header with a `done` symbol, "Contract" and "10 passed · 1 is you", over "visible
  to you now · workers never saw it". **`NWContractRow(check)`** rows: at least 28pt, radius 6, 12:
  the number in mono 10 (16pt), a 14pt state column, the check, and its evidence kind in mono 10 on
  the right: ci, sql, trace, k6 in `textTertiary`, judge in `wireData`, you in `lanternText` (with a
  glowing 7pt dot until you approve). The selected row expands: what it proves (11.5/1.45
  `textSecondary`), its query (mono 11/1.6 on `bgSunken`, radius 6, syntax colored), its result as a
  small table (header cells on `bgSunken` in mono 10.5 `textTertiary`, good values in `done`), and
  **Open evidence** (secondary, 24pt) and **Re-run** (ghost). Its footer: "Validator ran at 12:52 on
  `build-01` in its own worktree, against `compose.e2e.yml` with all four services." (11.5/1.5
  `textTertiary`).
- **The footer** (56pt, a hairline above): "Changes you send go to the lane that owns the file. The
  map adds a patch, and the validator runs again before you're asked back." (12 `textTertiary`),
  then **`NWMergeActions`**: **Request changes · 1** (secondary) and **Approve 4 PRs · start the
  train** (primary, ⌘⏎). Changes go to the lane that owns the file, as a patch.

**Evidence** (MXEvidence): what the validator ran for one check, traced across services.

- The column (20pt/28pt padding): a breadcrumb in 12 `textTertiary` ("Review / Contract / Check 2 of
  11", the last in `textSecondary`), the check as a 20/600 title, then its pill ("Passed · 2,000 of
  2,000 orders"), the sample in mono 11 `textTertiary` ("trace 4f2a…c81 · 1 of 50 sampled · 1.08s"),
  and **Trace | Rows | Commands** (`NWSegmentedPicker`, small).
- **The trace** (a card, radius 10, `lineSubtle` border): "ONE ORDER, END TO END" with a legend
  (request `running`, outbox write `done`, event on a topic as a 1.5pt dashed `wireData` outline,
  database `textSecondary`), time ticks every 200ms in mono 10 `textTertiary`, and one 32pt row per
  span (alternate rows on `bgHover`): the service in mono 11.5 `textTertiary` (132pt) and the span
  in `textPrimary`, its **`NWTraceSpan(kind:)`** bar (12pt, radius 3) at its offset with the
  duration after it in mono 10 `textTertiary`; hand-offs between spans are dashed `wireData` curves,
  as on the map.
- Under it, two columns: **Row it produced** (a table in mono 11) and the **payload** (proto as JSON
  on `bgSunken`, syntax colored).
- **The inspector**: "How it was checked", "hidden from workers · 12:52 on build-01 · 3m10"; Would
  fail if; **Steps** ("5 commands"), each 10pt padded with a hairline above: its number in mono 11,
  the command in mono 11.5 over its result in 12 `textSecondary` with an 11pt check; **Keep it**,
  with **Save as an e2e test** (secondary, 24pt). Footer: **Re-run check** (ghost) and **Back to
  review** (secondary).

**Merge train** (MXTrain): the order comes from the data wires, with staging and a soak between
services. The pill reads "Merging · 2 of 4"; the action is Pause train.

- A bar (14pt/24pt padding): **Map | Train** (`NWSegmentedPicker`, small), a spacer, and "Drag a
  card to change the order. The planner checks it against the data wires." (11.5 `textTertiary`).
- **`NWTrainCard(pr, state:)`**, one per PR, left to right, joined by 38pt arrows (2pt `lineStrong`
  with a chevron): 234pt wide, radius 10, `bgRaised`, `lineSubtle` border. Its head (12pt/14pt
  padding, a hairline beneath): a 20pt circle with the order in mono 10.5, the repo in mono 13/600;
  the PR in mono `running`, its stat, and its role in `textTertiary` ("shared protos", "consumer",
  "producer"); and its pill: **Merged** (`done`), **In the train** (`running`; the card gets a
  `running` border and a 3pt `runningTint` ring), **Waiting** (outlined, hollow dot; the card at
  70%). Its gates follow (8pt/14pt/10pt padding).
- **`NWTrainGateRow(gate)`**: at least 28pt, 12.5, a 14pt glyph column: done (13pt check), running
  (12pt spinner), failed (11pt xmark), fixed by a rule (a 13pt symbol and "auto" in `lanternText`),
  queued (7pt hollow ring, the name in `textTertiary`); the meta in mono 10.5 `textTertiary` ("CI
  green 12:58", "Soak 10m · 6m left", "Bumped in 3 repos · go.mod"). A note can sit under a gate,
  indented 24pt, in 11 `textTertiary` ("main moved at 13:12"). A soaking card shows its health on
  `bgSunken` (radius 6, mono 10.5): errors "0.00%" in `done`, "consumer lag p95", "events ingested".
- The gates run top to bottom inside each card, in this order (MXTrain, NWMissions): **Rebase on
  main**, **CI**, **Merge**, then what the lane ships. A shared contract is tagged and bumped where
  it is imported ("Tagged v1.8.0", "Bumped in 3 repos · go.mod"); a service is deployed and soaked
  ("Deploy to staging", "Soak 10m", per the Between services rule). The first card has no rebase. A
  finished gate reads in the past tense with its time or count ("CI green 12:58", "Merged 13:02",
  "Deployed to staging 3/3"), a pending one in the imperative ("Rebase on main", "CI", "Merge"), and
  a running one with its elapsed or remaining time ("CI 2m", "Soak 10m · 6m left").
- When a rule acted, a note on `lanternTint` (10pt/12pt padding, radius 8, 12/1.5, a lantern symbol)
  says so: "…The train fixed it without asking, because lockfile conflicts are on your **fix
  automatically** list. A code conflict would have paused here."
- **Why this order** ("worked out from the data wires, not guessed"), a card (16pt/18pt padding,
  radius 10, `lineSubtle` border): rows at least 30pt, 12.5/1.5: the order in mono `textTertiary`
  (44pt), the reason in 600 (250pt), the explanation in `textSecondary` ("contracts first",
  "analytics-ingest before producers", "checkout, then orders").
- **The inspector**: "Merge train" with "2 of 4 merged", "one PR at a time · started 12:58 · ~30m
  left"; **Rules** ("host default · change for this mission"): **`NWTrainRuleRow(rule)`** rows at
  least 34pt, the rule in 12.5 `textSecondary` and an `NWPopupMenu` (190pt): Between services
  "staging + 10m soak", Lockfile conflicts "fix automatically", Code conflicts "pause and ask", Red
  CI after merge "revert, then pause", Merge window "weekdays 9–4 CT"; **Log**. Footer: **Skip
  soak** (ghost) and **Pause train** (secondary).

## Missions: when things go wrong

**Not built yet.** Only the part that's stuck pauses.

**Stuck lane** (MXStuck): three failed tries pause that lane; the rest keep going. The pill reads
"Running · 1 lane stuck"; the action stays Pause.

- **The left column**: the mini-map (the stuck station and its check in `.failed`, selected);
  **Lanes** ("1 paused · 3 moving or done"): rows 32pt, radius 6, 12.5: a 14pt state glyph, the repo
  in mono 600 (128pt), the state in `textSecondary` ("done, waiting at join"; "stuck after 3 tries"
  in `failed`), its time in mono 11 `textTertiary`; then "Only orders-svc paused. The other lanes
  keep going. `join` waits for orders, so nothing else is blocked yet." (12/1.5 `textTertiary`);
  **Why it paused** ("from the go test exits"): exit rows ("fail → retry, tries 2 and 3"; "fail ×3 →
  pause this lane, and ask you").
- **The station**: its pill reads "Stuck · 3 tries" in `failed` on `failedTint` (`AgentState
  .stuck`), and its tabs lead with **Attempts · 3** ("fable-5-1 · 870k of 900k"). The tab (22pt/28pt
  padding, 18pt gaps, at most 780pt): the planner's read; **Attempts** ("orders · 870k of its 900k")
  as attempt rows; **What next** as choice cards: Retry with a hint (the planner's pick, "~150k ·
  10m", its hint editable), Replan the lane ("+1 station · ~350k · 25m", "Adds `outbox-tx` before
  orders…"), Take over in a thread ("mission waits at join"; "Opens a thread in this worktree. When
  you're done, hand it back and the lane re-runs its check."), and Drop the lane, disabled ("not
  possible"). Footer: what the choice costs ("The hint raises orders to 1.05M. The mission stays
  under 6M.", 11.5 `textTertiary`), **Take over** (secondary), **Retry with hint** (primary, ⌘⏎).

**Out of budget** (MXBudget): every station stops at a checkpoint. The pill reads "Paused · out of
budget"; the tokens meter is full in `failed`, time in `lantern`; Resume is disabled.

- **The left column**: the mini-map (checkpointed stations with a `lantern` border); **Stopped at a
  checkpoint** ("2 stations") as checkpoint rows, then "Stations stop at their next turn and commit
  to their worktree. Nothing is cut off mid-edit, and resuming picks up the same agent session."
  (12/1.5 `textTertiary`).
- **The inspector**: "Out of budget", "paused 12:31" in `lanternText`, "6.0M of 6M tokens · 2h31 of
  4h · nothing is running"; What happened; **Spend vs plan** ("6.0M total") as spend bars with their
  legend; **Left to do** ("estimated from this run"): rows at least 26pt (`↻` or `·`, the station in
  mono 600 at 104pt, what's left, the estimate in mono 11 `textTertiary`), and a total row over a
  dashed `lineSubtle` rule ("To finish", "~0.9M · ~40m" in mono 12); **What next**: Add 1M and
  resume (the planner's pick, "7M cap", "The cap goes to 7M, about $9 more. Both stations pick up
  from their checkpoints."), Land what's ready ("2 of 4 lanes"), Stop and keep the branches
  ("Nothing merges. The 4 draft PRs stay open and the worktrees are kept for 7 days."); and a card
  (10pt/12pt padding, radius 8, `lineSubtle` border) with "Pause when a lane goes 50% over its
  plan", "Would have paused at 12:05, when analytics hit 1.95M." (11 `textTertiary`) and a switch.
  Footer: **Stop mission** (`.danger`), **Land what's ready** (secondary), **Add 1M and resume**
  (primary, ⌘⏎).

**Two missions, one repo** (MXLocks): locks are on paths, with a queue. The pill reads "Running · 1
lane held".

- The column (26pt/32pt padding, 26pt gaps):
  - **Repos over time**, with a legend of 18×10 swatches (radius 3): this mission (`runningTint`
    with a `running` border), another mission by name (`lineStrong`), held (lantern-tint stripes at
    135° with a dashed `lantern` border), planned (a dashed `running` border); the other mission's
    planned work is dashed `lineStrong` ("merges ~13:21"). **`NWRepoTimeline(repos, missions:)`**: a
    56pt row per repo with a hairline above and its name in mono 11.5/600 with an 11pt symbol, hour
    ticks in mono 10 `textTertiary`, bars 16pt tall (radius 4) labelled in mono 10 at 8pt in
    ("funnel · order.proto", "held · place.go" in `lanternText`, "merges ~13:21"), and now as a
    1.5pt `running` line with "now 12:12" in mono 10 `running`.
  - **Paths each mission holds**: **`NWPathLockRow(lock)`**, one row per repo both missions touch:
    columns REPO (150pt), the other mission, THIS MISSION, RESULT (230pt); rows at least 36pt, 12, a
    hairline above: the repo in mono 600, the paths in mono `textSecondary`, and the result with a
    12pt symbol ("no overlap · both run" and "free" in `done`, "place.go overlaps · waits" in
    `lanternText`). Under it a note on `bgSunken` (radius 8, `lineSubtle`, 12/1.5): "Missions lock
    **paths, not repos**. A mission holds the paths its stations plan to write, taken from the map.
    A station that writes outside its paths pauses and asks."
  - **Queue on orders-svc · place.go**: rows 34pt, 12.5 (30/260/flex/160): the position in mono 11
    `textTertiary`, the mission at 600, its state after a 6pt dot ("holding · merge train, 2 of 4";
    a glowing lantern dot for "this mission · waiting"; a hollow one for "draft · plans to write
    place.go"), and when in mono 11 `textTertiary` ("releases ~13:21", "starts ~13:21", "not
    launched"); this mission's row on `bgSelected`.
- **The inspector**: "orders-svc is held" with "queue #1", "by Checkout funnel events · merges
  ~13:21"; **The overlap** ("1 file"), a card on `bgSunken` with the path in mono 12/600 and what
  each mission changes; **What next**: Wait for it to merge (the planner's pick, "starts ~13:21"),
  Stack on its branch ("starts now"), Run anyway ("likely conflict" in `failed`); **Meanwhile**, the
  mission's other lanes as 32pt rows. Footer: "You'll get a notification when orders starts." and
  **Wait in queue** (primary, ⌘⏎).

**Stop** (MXCancel): what happens to each lane, with safe defaults. Stop (the header's, or Stop
mission in a paused inspector) opens a dialog over the mission:

- A scrim of black at 55%, and the dialog 96pt from the top, 940pt wide, radius 12, `bgRaised`, with
  the popover's border and shadow.
- **Head** (20pt/24pt/12pt padding): "Stop Checkout funnel events?" in 17/600; "2 of 4 PRs are
  already merged. This is what stopping does to each lane. The planner picked safe defaults; change
  anything before you stop." (13/1.5 `textSecondary`); an `NWStepStrip` of the train, 280pt wide.
- **Lanes** (24pt side padding): columns LANE (170pt), NOW (210pt), ON STOP (170pt), WHAT HAPPENS;
  heads in mono 10 caps tracked `textTertiary`; rows 12pt padded with a hairline above.
  **`NWRollbackRow(lane)`**: the lane in mono 12.5/600 over its PR in mono 11 `running` ("#97 ·
  merged", "#231 · open"); now in 12/1.45 `textSecondary`, after a 6pt state dot for merged work
  ("On staging, migration `0042` applied"); an `NWSegmentedPicker` (small): **Keep | Revert** for
  merged work, **Close | Leave open** for open PRs, none for the mission's own sessions; and what
  happens in 11.5/1.45 `textTertiary`, with a revert's plan in mono 10.5 `lanternText` ("revert #97
  → down 0042 → staging"). Defaults: additive merged work is kept, merged work with a migration is
  reverted, open PRs close (the branch stays), and the mission's sessions stop (the compose stack is
  torn down).
- "Keep worktrees for" with an `NWPopupMenu` ("7 days"), and "You can re-open the mission from
  Missions › Stopped until then." (11.5 `textTertiary`).
- **Footer** (12pt/16pt/12pt/24pt padding, a hairline above): the tally in mono 11 `textTertiary`
  ("1 revert · 2 PRs closed · 2 sessions stopped · 1 kept"), a spacer, **Pause instead**
  (secondary), and **Stop mission** (`.buttonStyle(.nw(.dangerFill))`: `failed` with
  `textOnFailed`), which is never the ⏎ default.

## Missions: templates

**Not built yet.** A finished mission becomes a map you can reuse. Inputs are data, so they render
in `wireData`: `Text(template: "Every {events.last} joins on {join key}")` draws each `{input}` in
`wireData`.

**Save as template** (MXTemplateSave), from Done's Save as map template:

- The map shows the template: lane heads and subtitles with their inputs in braces ("{consumer}", "1
  repo"; "{producers}", "1 or more · a lane each"; "add {events}"; "{events} → {table}"), a repeated
  station as "producer ×n" with a "one per producer" chip, and what the run taught it as a
  `.patchAdded` station ("join key", "you · asked up front") with a "learned" chip in `lanternText`.
  The status chip reads "Template preview · 17 stations · 6 inputs · 1 learned"; bottom-left,
  "`{input}` filled in when you start a mission from it". Template stations are 210pt wide and lanes
  262pt apart.
- **The inspector** (520pt): "Save as template", "from Checkout funnel events · 2h58 · 4.8M";
  **Name** (a 28pt text field, then a description field, 8pt/10pt padding, radius 6, `bgRaised`,
  `lineStrong`, 12.5/1.5); **Inputs** ("found by comparing the goal with the map"):
  **`NWTemplateInput(input)`** rows at least 30pt, 12, columns INPUT (104pt, mono `wireData`), KIND
  (92pt, 11.5 `textTertiary`: "proto messages", "repos, 1+", "pg table", "field", "duration"), THIS
  RUN (mono 11 `textSecondary`), FILLED BY (76pt, 11 `textTertiary`: "your goal", "planner"; "asks
  you" in `lanternText`), heads in mono 9.5 caps tracked; **Changed from this run** (change rows: `+
  join key` "learned", `= retry ≤2`, `↻ contract` "11 checks become 9 with inputs", `− registry`
  "sub-map route was never taken"); **Contract, with inputs** (rows with inputs in `wireData`, then
  "6 more · still hidden from workers when the template runs"); **Share**: **Just me | Team**
  (`NWSegmentedPicker`, small) and "Saved as `.shepherd/maps/add-event.yml` in contracts. Changes go
  through a PR." Footer: **Cancel** (ghost), **Save template** (primary, ⌘⏎).

**Missions ▸ Templates** (MXTemplates): the Missions page with the Templates tab chosen, shared
through a repo and reviewed like code.

- **Table**: TEMPLATE 1.7fr, LANES 1fr, RUNS 50, AVG 60, SHARED 80, 18pt gaps; rows 12pt/24pt: a
  13pt symbol and the name in 13.5/600 over its inputs in mono 11 `textTertiary` ("events,
  producers, consumer, table, join key, retention"); lanes in mono 11.5 `textSecondary` ("contracts
  · consumer · producers ×n"); runs in mono 12; average in mono 12 `textSecondary`; shared in 12
  `textSecondary` ("team", "just me"). Under it: "Save any finished mission as a template from its
  Done screen. Team templates live in a repo, so they're reviewed like code." (12 `textTertiary`).
- **Detail** (420pt): the name in 15/600 over its file in mono 11 `textTertiary`
  (".shepherd/maps/add-event.yml · contracts"); its map at 84×26 (checks 84×20, lanes 96pt apart);
  **Runs** ("3 · all merged": Average "2h40 · 4.6M tokens", Patches per run "1.3 → 0 last run");
  **Learned from runs** (rows at least 24pt: the date in mono 10.5 `textTertiary`, 48pt, and the
  lesson in `textSecondary`). Footer: **Edit map** (ghost), **Start a mission** (primary).

**Start from a template** (MXTemplateStart): five of six inputs filled, one question first. The pill
reads "Planning · 1 question" (glowing).

- The chat as in intake: activity lines "Read PAY-311 · 1 linked doc" and "Matched a template · Add
  an event across services · used 3×"; the filled inputs as a list (the input in mono `wireData`,
  "→", its value as inline code); "The template asks one thing before it draws anything:" and an
  unanswered question card ("Which key joins a refund to the funnel?", "Asked up front since the
  funnel mission, where a missing join key cost a re-run of two services.", order_id, payment_id,
  Something else…).
- **The brief** (520pt), "started from a template · click anything to change it": Destination
  ("PAY-311 + your message"); **Template** ("3 runs · avg 2h40"): its chip (24pt, radius 6,
  `lineSubtle`) and change rows against the last run (`= consumer`, `± producers` in `running`, `+
  check` "new"); Lanes · 3 repos ("template + planner"); Validation contract ("7 more from the
  template"); Size ("~3.1M tok · ~2h10", "from 3 runs"; "5M · 3h · 2 forks"); **Still open** with a
  glowing lantern dot ("join key", "order_id or payment_id?", "needed to draft"). Footer: "Answer
  the join key to draw the map." and **Draft the map**, disabled at 40% until it is answered.

## Missions: iPhone and iPad

**Not built yet.** The phone is for missions that run while you're away: a Live Activity for
progress, notifications with answers built in, and the few decisions a mission stops for. Map
editing stays on the Mac ("Take over on your Mac", "Open on your Mac"). The iOS rules hold (Dynamic
Type, 44pt targets, no hover).

- **`NWLaneStrip(stations)`**, a lane as a tiny subway line: 14pt tall, stops 4.5pt in radius joined
  by 2pt lines; a finished stop is a `done` disc (its line `done`), a running one a `bgRaised` disc
  with a 2pt `running` ring, a failed one a `failed` disc, and a pending one a 3.6pt `bgRaised` disc
  with a 1.5pt `lineStrong` ring (its line `lineStrong`).
- **`NWMissionLiveActivity(mission)`** (ActivityKit), one strip per lane and the one thing that
  needs you: a card (radius 18, `bgRaised`, 12pt/14pt padding, 8pt gaps) with a 14pt lantern crook,
  the mission in 13/600 and "1h38 / 4h" in mono 11 `textTertiary`; a row per lane (18pt: the lane in
  mono 10.5 `textSecondary`, 80pt; its strip; its step in mono 10 in its state's color, "go test",
  "stuck"); and a glowing 7pt lantern dot with "orders needs you" in 12 `lanternText`.
- **`NWMissionNotification(question)`**: a `UNNotificationCategory` with the choices as actions, so
  answering never opens the app ("Refund events · question", "Which key joins a refund to the
  funnel?"). A mission notification opens the station that asked.

**iPhone Missions** (MobileMissions): from Home, with "‹ Home" (16 `running`) and two 36pt circle
buttons, Search (a `lineStrong` border) and New mission (`lantern`, a plus); the title "Missions" in
30/600. Filters are capsules 32pt tall (12pt padding, 13.5): the chosen one `textPrimary` with
`bgWindow` text at 600, the rest on `bgSelected`, counts in mono 11 at 70%. Missions sit in one card
(radius 12, `bgRaised`, `lineSubtle` border), a hairline between rows (12pt/14pt padding, 8pt gaps):
a 15pt symbol, the name in 15.5/600 and its pill; the state in 13 (`lanternText` when it needs you:
"orders is stuck after 3 tries"); repo chips (mono 10.5, 1pt/6pt padding, radius 4); and the route
strip (4pt segments, 2pt apart) with the spend in mono 11 `textTertiary` ("3.1M / 6M").

**A mission** (MobileMission): a header (58pt top, hairline beneath) with "‹ Missions" and a 34pt
More, the name in 22/600 and its pill. The body on `bgBase` (14pt padding, 12pt gaps):

- the meters (4pt bars, values in `textPrimary`) and the host in mono 11.5;
- **Needs you** (13/600 `textSecondary`, the count in mono 12 `lanternText`), then its card: 14pt
  padding, radius 14, `bgRaised`, a `lanternText` border; a glowing 8pt dot, "orders is stuck" in
  16/600 and "3 tries" in mono 11.5 `textTertiary`; the planner's read in 14/1.45 `textSecondary`;
  and stacked 48pt buttons (radius 12, 16pt): **Retry with the planner's hint** (primary), **Replan
  the lane** (secondary), **Take over on your Mac** (text, `running`);
- **Lanes** ("3 moving or done"), a card (radius 14): rows at least 30pt with the lane in mono
  12.5/600 (126pt), its strip (80pt), and its state in mono 11.5 ("done", "go test · 2m" in
  `running`, "at join", "stuck" in `failed`), then "then join → validator → review → merge train"
  (12.5 `textTertiary`);
- at the bottom (10pt/14pt/34pt padding, a hairline above), a capsule field (42pt, radius 21,
  `bgRaised`, `lineStrong`): "Tell the planner…".

**Patch sheet** (MobilePatch): apply from the phone. A sheet over the mission (a 50% black scrim),
640pt tall, radius 16 on top, `bgWindow`, a 36×5 grabber in `lineStrong`: "Patch for orders-svc" in
20/600 over "proposed by the planner · 11:55" (13 `textTertiary`); its changes (14/1.35: the mark in
mono 600, the station in mono 600 over what it does in 13 `textSecondary`); the cost in a card
(radius 12, `bgRaised`, rows at least 26pt, 13.5: "Tokens 3.1M → 3.5M of 6M"); a note ("Only
orders-svc changes. join still waits for it, so nothing else re-runs."); and 48pt buttons, **Apply
patch** (primary) and **Open on your Mac** (secondary).

**Review** (MobileMerge): approve the PR set, start the train. The pill reads "Review · needs you".
The planner's summary (14/1.5 `textSecondary`); a **Contract** card (a 17pt check, "Contract"
16/600, "10 passed" as a `done` pill; rows at least 28pt in 14 with a 14pt check; "Show all 10, with
evidence" in 13 `running`); **PR set** ("merges in this order"), a card of rows at least 42pt: the
order in mono 11.5 `textTertiary`, the repo in mono 14/600 over the PR in `running`, its stat and "3
files", a 14pt check and an 8×14 chevron. Footer: **Approve 4 PRs · start the train** (primary) and
**Request changes** (secondary), both 48pt.

**iPad** (iPadMissions, iPadMissionMap, iPadMissionReview), missions on a big screen:

- **List and detail** beside the sidebar (the boards' 300pt iPad sidebar with Missions chosen): a
  340pt list column with a 76pt header ("Missions" 17/600, a 40pt New mission icon), capsule filters
  (30pt, 13), and rows (12pt padding, radius 10, the selected one on `bgSelected`): a 15pt symbol,
  the name in 15/600 and its pill, the state in 12.5, and a 160pt lane strip of the mission's route.
  The detail: a 76pt header (the name, its pill, a 40pt •••), a bar (10pt/16pt) with the meters, the
  host chip and **Open map** (36pt, secondary), the mini-map (stations 96×28, lanes 108pt apart),
  and the needs-you card floating 14pt from the sides and 26pt from the bottom (14pt/16pt padding,
  radius 14, a `lanternText` border, the popover's shadow) with 36pt buttons: **Retry with the
  planner's hint**, **Replan the lane**, **Take over** (ghost).
- **Mission map** (iPadMissionMap): a 76pt header with "‹ Missions" (16 `running`), the name and
  pill, the meters, the host chip and **Pause** (36pt). The whole map in a 700pt column (stations
  124×33, lanes 140pt apart) with "pinch to zoom · tap a station · two-finger drag to pan" in mono
  10.5 `textTertiary` at its bottom-left; beside it the station: its name in mono 16/600 with its
  pill and "orders-svc · fable-5-1 · 870k of 900k" in mono 12; the planner's read (radius 10,
  14/1.55); attempts as 36pt rows (a 20pt number, what it tried, "same failure", the time); the
  choice cards; and a footer (12pt/16pt/26pt) with **Take over** and **Retry with hint** at 36pt.
- **Mission review** (iPadMissionReview): PR set, diff and contract in three columns under a 76pt
  header ("‹ Map", "Review · Checkout funnel events", Needs you, and **Request changes · 1** and
  **Approve 4 PRs · start the train** at 36pt). The PR list is 270pt ("4 PRs · merge order" in mono
  11 caps, PR rows at least 44pt in 13.5, file rows at least 40pt inset 30pt); the diff keeps the
  Mac's parts with 30pt number gutters; the contract column is 380pt ("Contract · 10 passed" and "+
  your approval"; rows at least 36pt in 13, the selected one expanded with its result, **Open
  trace** and **Re-run**).

## Missions: motion, keyboard and parts to build

**Not built yet.**

- **Motion:** needs-you stations, dots and pills glow (the 1.6s attention glow); running stations,
  frontier rows and gates spin (1s); a moving flow wire's dash advances 18pt every 0.9s, linear and
  repeating. The dash is a new continuous motion: add it to `NW.Motion` as a clock-driven,
  render-server animation like the spinner, static under Reduce Motion and stopped under
  `nwMotionPaused`. Nothing else on the map moves by itself; a patch appends below (the map grows
  downward) and the canvas never re-lays out what already ran.
- **Keyboard:** ⌘⏎ (⌘↩) performs a mission screen's primary action (Draft the map, Launch, Apply
  patch, Retry with hint, Add 1M and resume, Wait in queue, Approve N PRs · start the train, Save
  template); ⌘[ goes back from a mission to the thread; ⌘K offers "New mission…" and the missions by
  name. New chords go through `KeybindingsStore`, and the boards' ⌘0 for the sidebar yields to the
  existing ⇧⌘S. ⌘↩ already means "send the other way" in a composer while pi works (Keyboard), so
  decide which wins in the planner chat and a station's steer field before building.
- **Performance:** the map, the Missions table, the log and the attempts are long lists: lazy, one
  view per row, rows as `Equatable` values, with an `ListPerformanceTests` budget each (see
  Performance).

**Parts the boards name** (NWSwift, NWMissions, MXVocab), to build in ShepherdUI with a `#Preview`
in both appearances. NWSwift files them in two folders: the map in `Components/MissionMap/`
(`NWMissionMap` and its parts; a `Canvas` draws the wires and the stations are views on top, laid
out automatically: rows from time order, columns from lanes) and the screens in
`Components/Missions/`. See Theme model › Building on ShepherdUI.

| Group | Parts |
| --- | --- |
| Map (`MissionMap/`) | `NWMissionMap`, `NWStation` (kinds `.agent(role:)`, `.check`, `.contract`, `.merge(pr:)`, `.decision(.research \| .question \| .prototype)`, `.gate`, `.submap`), `.stationState(_:)`, `.stationSelected(_:)`, `NWTerminus(.start \| .destination)`, `NWForkBar`, `NWJoinBar`, `NWFlowWire`, `NWOutcomeChip`, `NWDataWire`, `NWPinRow`, `PinType`, `NWLane`, `NWFog`, `NWFrontierChip` |
| Chrome | `NWMissionHeader`, `NWPhaseBar`, `NWBudgetMeter`, `NWHostChip` |
| Asking you | `NWChoiceCard` (`isPicked:`, `risk:`, `.disabled`), the mission question card, `NWPlannerNote` |
| Struggling | `NWAttemptRow`, `NWCheckpointRow`, `NWSpendBar` |
| Train and locks | `NWTrainCard`, `NWTrainGateRow`, `NWTrainRuleRow`, `NWRepoTimeline`, `NWPathLockRow` |
| Review and evidence | `NWContractRow`, `NWDiffAnnotation(.check \| .patch)`, `NWTraceSpan`, `NWMergeActions` |
| Stopping and templates | `NWRollbackRow`, `NWTemplateInput`, `Text(template:)` |
| iPhone | `NWMissionLiveActivity`, `NWMissionNotification`, `NWLaneStrip` |

Reuse before adding: `NWStatusPill`, `NWStepStrip`, `NWSegmentedPicker`, `NWPopupMenu`, `NWStepper`,
`.toggleStyle(.nwSwitch)`, `.nwCheckbox`, `NWTag`, `NWSearchField`, the thread's components, and the
review pane's.
