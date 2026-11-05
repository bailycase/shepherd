# Conversation goals

Settings > Experiments > Goals is off by default. Turn it on to use `/goal <condition>`, which keeps one conversation working until the agent says the goal is done or it needs the user. It is not a mission or a background scheduler.

`/goal`, `/goal status`, `/goal pause`, `/goal resume`, and `/goal clear` inspect or control the goal. Edit changes the condition only. Goals have no time, token or check limits. Elapsed time and reported tokens are information only. Legacy saved caps and checker fields are ignored on restore.

The experiment switch applies to running agents without restarting them. Off pauses active goals, stops goal accounting/continuation, and hides goal chrome and `/goal` from the menu. Typed and native goal controls reject while off. It does not kill an in-flight tool, discard the queue, clear the saved goal or remove historical transcript records. On makes the preserved goal available again but never resumes it automatically. A full pi input pipe retains disable before the latest On policy and retries once the queued bytes drain; it never drops that disable barrier or clears ordinary input. Reset settings turns the experiment off. iPhone/iPad Settings > Experiments has a switch for each connected host that supports `experiments.goals.v1`.

## How a goal runs

`Extensions/shepherd-goal.ts` loads after the native child controller. While a goal is Working, each request carries the condition as request-local data with one instruction: keep working, verify with tools, and call `goal_finish` when done or blocked. The objective is untrusted data and never changes permissions, project trust, approvals or tool access.

At `agent_before_settle`, after children and queued reports finish, the controller appends a hidden `shepherd.goal.continue` message and continues the run. The goal ends only when:

- the worker calls `goal_finish` with `met` (state Met, with its short summary) or `blocked` (state Needs you, with its reason);
- the worker asks the user a question (Needs you until answered; answering never resumes the goal);
- the user pauses, stops, steers or clears it;
- a run fails or aborts (Needs you, "work stopped or failed");
- three runs in a row end without any tool call (Needs you, "no progress in 3 turns"). This catches a worker that keeps talking instead of working or finishing.

There is no separate checker model. The worker's own `goal_finish` call decides Met, so the card's summary is the worker's claim, not independent verification. `goal_finish` is registered inactive and joins the active tool set only while a goal is Working, so threads without a goal pay no context for it.

Pause stops continuation and accounting, but does not kill a tool already running. Stop and Steer now pause the controller before interrupting work. Later ordinary turns are independent of a paused goal.

## Queue and accounting

Set, Edit or Resume while pi works keeps a cancellable kickoff in the controller until the run and ordinary queue settle. Pause, Stop or experiment disablement cancels it; it never leaves a hidden kickoff in pi's ordinary follow-up queue.

A queued message asks the goal to yield at its next settle. The host then delivers Up next in its existing order, and the goal continues after those turns. Deleting, steering or draining the last held row releases that yield so an idle Working goal is not stranded.

Elapsed time counts active work, including active children. Tokens include reported worker, child and cache usage. Neither total stops a goal.

Controls carry session generation and the displayed goal ID/revision/state. Pause and Resume require all those fences; both host and controller reject a stale state. Controller transitions increment revision, accounting updates do not. Met is clear-only.

## Persistence and projection

Canonical state lives in `shepherd.goal` session entries, not fleet persistence. Text is persisted on set/edit only; later transitions reference it. Accounting and interval snapshots do not append entries. Restore reads legacy full records and compact checkpoints; a previously active goal (including a legacy Checking one) restores Paused and needs explicit Resume.

The dedicated machine widget projects to `NativeGoal`, not ordinary widget text. Null announces controller availability. Snapshots carry optional `goal`; remote controls require `native.goal.v1`. `runningSince` is epoch milliseconds; clients advance the pill clock locally. The protocol still decodes the legacy `checking` state, `checkedBy`, confirmation fields and `goalCrossProviderEvaluation` so older peers interoperate; current hosts never emit them.

Only live `goalState` is mirrored on `Agent` for the sidebar. Working keeps the agent Working even while pi is idle between turns. An open question still takes priority. Needs you blocks an otherwise idle agent. Met/Needs you transitions notify using short metadata, never the condition. Ordinary turn-finished banners are suppressed only while Working.

## Card

`SHGoalCard` renders the Goal card, MobileGoal and iPadGoal states above the composer, including while a question replaces the field. Goal, Subagents and Up next share one framed dock in that order. See [the card spec](design/thread.md#goal-card). Meta is short runtime copy: Working shows tokens; Met adds the worker's summary; Paused says "paused by you · the clock stops"; Needs you gives a word-bounded lowercase reason. Legacy check records in old transcripts stay readable.
