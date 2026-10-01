# Conversation goals

`/goal <condition>` keeps a conversation working until a separate model check accepts its evidence or it needs the user. It is one goal in one agent's session, not a mission or a background scheduler.

Start with `/goal --for 30m --tokens 100000 <condition>` to set optional limits. `/goal`, `/goal status`, `/goal pause`, `/goal resume`, and `/goal clear` inspect or control it. The card also has pause, resume, edit, and clear controls. Pausing stops automatic continuation and the clock. It does not interrupt a tool already running. The ordinary Stop control still interrupts work.

## Runtime

`Extensions/shepherd-goal.ts` is loaded after the native child controller. At `agent_before_settle`, once child work and queued child reports no longer need continuation, it publishes Checking and makes a separate authenticated model call. The evaluator cannot run tools or read the checkout. It gets the complete goal and bounded recorded conversation evidence, then returns a structured `goal_verdict` tool call with a short human summary separate from its detailed feedback and proof. Checking's meta names the commands attached to the tool results that call reads. It extracts safe unquoted shell command heads or short read/write/edit basenames. Quoted, substituted, control-syntax or unresolved calls use "checking · commands unavailable"; an empty tool history uses "checking · no tool results to read". Full records remain in the transcript.

A `met` verdict must cite exact quotes from successful, complete tool results. Worker prose alone cannot establish success. Missing citations, omitted or truncated evidence, evaluator errors, and evaluator timeouts cannot turn the card green. A valid `not_met` verdict supplies feedback for another turn. Missing permission, credentials, or a decision stops at Needs you. A child asks its parent first and does not block the goal on the user by itself. When the parent actually asks the user, the goal stops at Needs you. Answer the question, then resume explicitly. Repeated blockers and checks without new successful tool evidence also stop instead of looping indefinitely.

The default evaluator preference is Haiku, Codex Mini, then Gemini Flash, using already configured credentials. If none is available, it uses the working model in a separate call. No new authentication is introduced. `SHEPHERD_GOAL_MODELS` can supply a comma-separated provider/model preference list for a host-managed launch.

The worker receives the goal and feedback as data. Neither grants tool permissions or changes project trust, confirmation rules, or tool access. The evaluator's verdict is an assessment of recorded evidence, not independent proof that every test result is truthful or that deployment succeeded.

## Controls, queue, and accounting

Goal controls are typed native requests gated by the controller capability. They execute during both work and checking. Each carries the session generation and displayed goal ID/revision. The extension checks the fence again before applying it. Editing, pausing, clearing, replacing, or switching sessions invalidates an in-flight verdict. An edit preserves the state and stop reason; unchanged text sends no mutation and leaves the revision alone. Met is clear-only. If a check finishes while an editor is open, Save disables rather than applying old proof to a new condition. Resume stays disabled while the stopping question is open.

A user message queued during a goal asks the controller to yield after the next check. The existing host queue then delivers the message, rather than waiting for the entire objective to finish. This preserves Up next's ordering. A pause does not discard that queue.

Elapsed time counts working and checking, including active child work. The clock stops while paused, met, needs-you, or settled without work. Token usage includes worker, projected child, and evaluator usage when those runtimes report it. Cached input counts as tokens. The card's clock-only updates do not write session entries or increment the condition revision.

Limits are runtime guards, not instructions interpreted by the model. Token use becomes known after a model response and can exceed a cap by that response. A time limit never kills a tool halfway through a write. It prevents further automatic work at the next safe boundary. Defaults have no time or token cap; no-progress and blocker guards still apply.

## Persistence and projection

The canonical goal is stored in `shepherd.goal` custom session entries. Restore keeps the condition, accounting, limits, and stop reason. A previously active goal restores Paused and requires an explicit resume. Completed and stopped goals remain visible until cleared. It never resumes unattended because the app restarted.

The extension publishes `shepherd.goal` through a dedicated machine widget. `RPCThreadState` parses it into `NativeGoal`, not an opaque transcript note. A null publication announces the controller even before a goal exists. Native snapshots carry `goal` and advertise the `goal` action; remote controls require `native.goal.v1`. Older hosts retain ordinary chat but cannot offer these controls.

Only the live goal state is mirrored on `Agent` for the sidebar. It is removed from persisted fleet state. A Needs you goal makes the idle agent blocked; a Met goal produces a completion notification. macOS notifications use the existing host notification path. iPhone notifications, when allowed, require the client to be connected and observing the thread. They are not APNs background delivery.

## Card

`NWGoalCard` implements the five states of the Goal card board, with MobileGoal and iPadGoal. It appears above the composer and remains visible while a question replaces the input. When subagent or queue cards are also present, one framed stack has Goal, Subagents, then Up next, separated by hairlines. The thread header shows the elapsed goal pill only in Working and Checking. The iPhone header keeps its ordinary status dot and word alongside that pill. The sidebar adds the two-ring goal glyph without removing its ask/reason chip, elapsed time or host tag.

Desktop cards are 70 pt with 32 pt headers and 10 pt corners. Touch cards are 92 pt with 40 pt headers, 12 pt corners, and 44 pt action hit targets. Working pulses its dot and Checking animates its spinner; reduced motion disables both animations. Met exposes clear, Paused exposes resume/edit/clear, and Needs you keeps edit available and resume disabled while its question is open.

The runtime publishes meta text; previews decode tested fixtures of those publications. Working shows tokens; Checking names recorded commands; Met adds the verdict's short summary to the token count; Paused always says "paused by you · the clock stops"; Needs you gives a short lowercase reason at whole-word boundaries. Full feedback, diagnostic errors, proof IDs, quotes and tabs stay behind the transcript's Details disclosure; legacy Evidence disclosures remain readable. The "Goal met" closing line is centered and limited to two lines. `/goal <condition>` appears in the slash menu.

See [the card spec](design/thread.md#goal-card) for touch anatomy and transcript copy. Long-condition truncation and both edit surfaces remain unchanged pending the user's decisions in PR #189's Departures. That section also records the checking-label fallback and a second header row when larger text cannot fit beside the actions.
