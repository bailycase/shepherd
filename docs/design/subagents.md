# Subagents

> Read when you change the subagent tray, its cards, or its record lines in a thread.

Subagents live in a **tray above the composer** while they run (SubagentTray, NWAgents;
Subagents, SubagentsDone, SubagentsQueue): one row each, steered, stopped or opened from there,
in the same card as Up next. The thread keeps two quiet lines for them, where they
started and where they finished, and both open the inspector, so finished runs stay browsable.
Raw wait or status dumps never appear. Subagents have no sidebar rows, and **a subagent never asks
you anything**: one that has a question asks its parent agent, which answers it or asks you
itself, in its own thread, as an ordinary question (Composer, questions), and passes your answer
down. So a subagent's question marks no row in Needs you, posts no notification, and takes
nothing over the composer: it shows quietly on the subagent's own row. Behavior is specified in
[native-subagents.md](../native-subagents.md).

The components are ShepherdUI's Agents set (`Components/Agents/SubagentTray.swift`).
`NativeSubagentTray` (ShepherdRemote, shared with iOS) derives the
tray's header and rows once per change on the thread store (`NativeThreadStore.tray`), and the
turn's record (`NativeSubagentRecord`) with its presentation; `SubagentPresentation` maps them onto
the components' values, and `Thread/Subagents.swift` lays out the tray. State always comes from
`AgentState` (a queued run, a run paused before its next model request and a run waiting on its
parent's answer all draw as `queued`; a subagent never draws `attention`, which is yours).

- **When the tray shows** (`nativeTrayRuns`): only runs started during the current turn, plus
  genuinely live or waiting work continuing from an earlier turn. Finished runs stay as that
  turn's summary until the next immediate message is accepted, then animate away. Refused sends,
  steering within a turn, and follow-ups still waiting in the queue do not dismiss it. A run
  finishing after the next turn begins does not become part of that new turn. The store keeps
  the opening-message timestamp across history paging; unknown historical runs never become
  current just because their spawn messages are unloaded. Older runs stay accessible through
  their original transcript records and inspector. It sits above the composer card
  in the composer's column, grows upward as Up next does, and the thread keeps its tail in view as
  the composer grows (`SubagentMotionTests`).
- **One card with Up next** (`NWDockStack`, SubagentsQueue, NWAgents › NWDockStack): when both
  show, one card holds the subagents, then Up next: one `bgRaised` fill, one 1px `lineStrong`
  line, radius `NW.Radius.m` (8), and a `lineStrong` rule between the two sections. Each section
  draws only its contents (`NWQueueStack(framed: false)`), and each collapses on its own. Up next
  keeps every behavior it has alone (steer, edit, move, delete with Undo, paused, Send now; see Up
  next); the card rounds only the tray's corners, so a lifted queue row still floats past its
  edges. Alone, either one is its own card.
- **Header** (32pt, 12pt leading, 6pt trailing, items 8pt apart): `NWBranchGlyph` at 12pt in
  `textTertiary`, "3 subagents" in `.nwSans(12, .semibold)` `textSecondary`, one 6pt cell per run
  (radius 2, 2pt apart, in the state's color; queued, paused and waiting-on-parent cells are
  `lineStrong`; at most twelve, in row order), then the tally in `.nwMono(11)`: "1 running" in
  `running`, "1 done" in `textTertiary`, "1 failed" in `failed`, in that order (with "queued" and
  "paused" after running, then "1 waiting on parent", all `textTertiary`), joined by " · "; "all
  done" once every run finished well. A spacer, then Collapse (`chevron.down`, a 24pt circular
  icon button; it turns to point right while collapsed). Collapsed, the tray is its header alone:
  the cells and counts still say what runs and what waits (SubagentTray · collapsed). The
  header's hairline is the first row's.
- **A row** (`NWSubagentTrayRow`; 36pt minimum, 12pt leading, 6pt trailing, items 9pt apart, a
  hairline above): the state in a 13pt slot (a 7pt `NWStatusDot`, glowing while it needs you; a
  `done` checkmark or a `failed` cross once finished), the name in `.nwMono(12, .semibold)` in a
  72pt column for legacy role-only rows, then what it is doing in `.nwSans(12.5)`, truncated at the tail, then its diff
  stat (`NWDiffStat`, Geist Mono 11) and its time (`NWElapsedText`, Geist Mono 11 `textTertiary`),
  then a 24pt trailing slot. Per state:
  - **Running:** its call in flight in the present tense in `textSecondary`, then what it acts on
    in `.nwMono(11.5)` `textPrimary` (a path shortened to its file name, a command's deciding
    part): "Editing NativeThreadPresentation.swift", "Running tests swift test", "Building",
    "Reading", "Searching", "Writing", "Listing"; the words shimmer (LiveText) while the call runs.
    Between calls the last call reads in the past ("Edited B.swift"), still; before any call,
    "Starting". Its diff so far and its time since it started ("37m").
  - **Queued / paused:** "Waiting to start", or "Paused before its next model request".
  - **Asked the parent:** a quiet waiting row: the hollow `queued` dot, "asked the parent: " and
    the question's asking sentence in `textSecondary` ("asked the parent" alone when it gave
    none), and its wait since the child asked (`shepherd_parent_message`; no figure without one).
    The question is its parent's to answer, or to ask you in its own thread, so the row has no
    tint, glow or Answer: nothing on it is yours to do. Hover keeps Stop and Open, and its Steer
    is called **Reply** (below).
  - **Done:** the first sentence of what it did, without its final period, in `textSecondary`;
    its diff and its duration ("41m").
  - **Failed:** why, in `failed`, without the exit code it leads with ("context limit reached
    after 41 turns").
  - **Hover** (a live run, on the Mac): `bgHover`, and Steer (`arrow.turn.down.right`; Reply on
    a run that asked its parent), Stop (`stop.fill`) and Open (`chevron.right`), 24pt circular
    icon buttons, take the trailing slot.
    At rest, and on a finished run, the slot holds a 10pt `chevron.right` in `textTertiary`.
  - **Selected** (its run open in the inspector): `bgSelected` with a 2pt rule on its leading
    edge, `running`.
- **Order and length** (SubagentTray · 8 subagents): up to four runs keep spawn order (the
  boards' worker · reviewer · tests); a longer tray sorts the live runs first (one waiting on its
  parent among them), then failed, then done, and shows four rows and "Show 4 more" (a 30pt row, Geist 12
  `textSecondary`, 34pt leading inset; "Show fewer" once open). Open, a tray of more than eight
  rows scrolls inside a lazy stack eight rows tall (`AppLayout.trayExpandedMaxRows`).
- **What a row does:** a click opens its run in the inspector (again closes it); Steer opens it
  with its Steer field focused; Stop stops the run, or closes the question of one waiting on its
  parent. Its context menu and accessibility actions carry Open (or Close the Inspector), Steer
  while the run is live, and the run's controls (Pause or Continue and Stop while live, Stop alone
  while it waits on its parent, Re-run once finished). Controls are disabled while the
  thread can't take commands (its agent is off screen, or its host has no subagent control).
- **Reply** (decided by the user, 2026-10-01): on a run that asked its parent (`needsReply`, the
  `asked` phase) the Steer action is called **Reply**, everywhere it is offered: the hover button
  (VoiceOver "Reply to <name>", tooltip "Answer this subagent yourself. It was waiting on its
  parent."), the context menu item and accessibility action, the inspector's field (its
  label "Reply to <role>", its placeholder "Reply to <role> — it was waiting on its parent", its
  button) and the touch screens' field (its prompt, accessibility label and Reply button, and the
  caption "to: <name> · not the parent · it was waiting on its parent"). It is the same Steer
  command, which also ends the child's question, so only the words change (`NativeRunSteerWords`);
  every run that did not ask keeps "Steer". A child waiting on its parent never times out, and
  Stop closes it: there is no timeout and no capability gate for it.
- **No Answer, and no question dock for a subagent.** A subagent that has a question puts it to its
  parent: the parent's extension is told (docs/native-subagents.md › Questions and results), and
  answers it from what it knows, or asks you in its own thread, as pi's own question in the
  composer's place, then passes your answer down. What a subagent's row offers is Reply (the Steer
  action under its asked-run name: you speaking to the child yourself, over its parent, which
  resumes the child with your words and ends its question) and Stop (which closes the question
  and marks the run stopped). The dock that once drew a subagent's question, with a note and
  Something else…, is gone from the components (Composer, questions, and menus › Questions).
- **In the thread** (`NWSubagentRecordLine`, SubagentTray › SubagentRecord): an activity line in
  look (26pt, 12.5 `textSecondary`, the meta in `.nwMono(11)` `textTertiary`, a 13pt branch glyph
  and a 10pt chevron; a real button with the row hover; with no run to open, no chevron, its
  place kept, and not a button). "Started 3 subagents · worker · reviewer
  · tests" (at most six names, then "+2 more") takes the first spawn call's place; later spawns
  and the parent's `shepherd_child_wait` and `shepherd_child_result` calls leave no line, and the
  activity lines around them run on as one (a burst of one kind still merges across them). Once every run has finished, "3 subagents finished · 45m ·
  7 files · +318 −64" (the span from the first start to the last end, "1 failed" when any did,
  the files touched, the combined diff) sits where they finished: before the first part of the
  turn that landed after the last run ended, else at the turn's end; with nothing between them the
  two lines sit 2pt apart, as activity lines do (SubagentsDone). Runs whose spawn call is in
  no loaded turn stay accessible in the tray and inspector, but add no transcript records or
  footer counts to an unrelated reply. Loading their spawn turn restores their records there.
  Both lines open the first run in the
  inspector, whose ‹ › browse the rest; the footer's "3 subagents" does the same.
- **Task names distinguish children.** Native `role: task` runs lead with a normalized first
  sentence capped at 72 characters, with the full task in GOAL. Task-bearing tray rows give
  the name a full-width line above role and activity. Explicit workflow lane names and legacy
  labels stay intact. Results, questions and controls use run identity, never the label.
- **Background coordination stays out of chat.** Routine child progress updates its record,
  not a new parent turn. Questions and unread completion can wake an idle parent; results that
  arrive while it works are batched into one continuation at its settlement boundary. A question
  is the child's to its parent: its notice tells the parent to answer it, or to ask you in its own
  thread and pass your answer down, and says so once however many children asked. Reading
  a result or receiving it through Wait consumes its pending notification. A question does not
  also generate a completion wake. Stop prevents late results from restarting the parent.
  The native tray remains the progress display; no receipt-only assistant response is requested.
  Report-only child/workflow results add context without starting a parent turn; continue mode
  resumes dependent work. Live children alone do not make the parent busy. An accepted user
  message interrupts child/workflow waits, ending that tool wait without cancelling children,
  so the host can deliver the user's next turn. User input takes priority over result-only
  continuation at the settlement boundary. Questions expose attempt-specific IDs for stale-answer
  refusal; delivery remains best-effort, not a durable exactly-once mailbox.
- **Not built yet: a queued message addressed to a subagent** (SubagentsQueue, SubagentTray ›
  DockStack: a queued row's "worker" tag). The queue carries no recipient, and no board draws how
  one is chosen.
