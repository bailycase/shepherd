# Conversation goals

`/goal <condition>` keeps one conversation working until a separate model check accepts recorded evidence or it needs the user. It is not a mission or a background scheduler.

A new unattended run defaults to 25 checks, 30 minutes and 200,000 reported tokens. Legacy goals with absent limits receive these defaults on restore; explicit version-2 lifted caps stay lifted. The time/token defaults and legacy migration are provisional product choices recorded under Decisions in PR #189. `/goal --for 30m --tokens 100000 <condition>` overrides them. `/goal`, `/goal status`, `/goal pause`, `/goal resume`, and `/goal clear` inspect or control the goal. Edit can change a limit without changing the condition; a blank limit field lifts that cap. The 25-check stop remains. Resume renews the configured unattended time/token windows and check count while preserving cumulative usage.

Pause stops continuation, evaluation and accounting, but does not kill a tool already running. Stop and Steer now pause/cancel the controller before interrupting work. Their following ordinary turn cannot inherit an expired goal's abort. Answering a question never resumes the goal automatically.

## Evaluation and disclosure

`Extensions/shepherd-goal.ts` loads after the native child controller. At `agent_before_settle`, after children and queued reports finish, it publishes Checking and makes a separate authenticated model call. The evaluator cannot execute tools or read the checkout. By default it uses the thread's exact provider/model, not an automatic cheaper-provider fallback. Each actual check discloses `Checked by <model>` in its record and card.

Settings > Agents > Allow cross-provider goal checks is off by default. Turning it on allows already authenticated Haiku, Codex Mini or Gemini Flash models before the thread model. The setting applies when agents start or restart; running processes retain their launch policy. Shepherd explicitly clears `SHEPHERD_GOAL_MODELS` when consent is off, so an inherited shell value cannot opt in. No new authentication is introduced.

The evaluator receives the full condition, canonical requirements, and a bounded transcript tail starting at goal set/edit. This can include user/assistant text, tool arguments, tool output and written code. It sends that data to the selected provider even when the call uses the thread model. Obvious environment assignments, keys, bearer tokens, passwords and private-key blocks are redacted before sending. Redaction is best effort, not a guarantee that all secrets have been found. Cross-provider checks therefore need explicit consent.

Evidence comes from the raw session branch, including successful results recorded before compaction. Tail selection keeps newest records instead of the oldest prefix. Images and incidental words such as "truncated" or "[Showing lines" do not invalidate unrelated text evidence. Actual tool truncation metadata and missing requirement coverage do.

A `met` verdict must quote successful tool results for every canonical requirement. Quotes need at least 24 non-whitespace characters and each requirement needs a distinct quote. Argument-only excerpts and recognized `echo`/`printf` manufactured results cannot verify completion. Shell detection is conservative and lexical; it cannot certify arbitrary scripts or prevent deliberately forged results. Requirement splitting is a conservative syntax heuristic, not proof that the evaluator understood every semantic clause. The evaluator still assesses recorded data, not an independently inspected checkout, test run or deployment.

If genuine evidence supports part of a Met candidate but required evidence is missing or a cited result is incomplete, the card says "looks met, evidence incomplete, confirm". Details explains what is missing. Confirm is explicit user attestation, displays "Confirmed by you", and does not claim independent verification. A verdict with no genuine supporting citation, malformed fields, an evaluator error or a timeout cannot turn green. The checker has a 60-second request bound.

Full redacted feedback, proof and errors live in custom-message details and reach native transcript disclosures through projection. They are not model-visible continuation instructions. The worker receives at most one short plain note explicitly marked untrusted data; markup and instruction-like lines are removed. Neither the objective nor that note changes permissions, project trust, approvals or tool access.

## Stops, queue and accounting

Repeated tool calls with new entry IDs do not establish progress. The controller hashes distinct result content. Three checks without a new complete successful result, or three repeated normalized blocker reasons, stop earlier than the hard 25-check limit. Even continually novel `not_met` results stop at 25 checks. These bounds limit unattended continuation; they do not prove convergence.

Transient worker `message_end` provider errors are not final stop decisions while pi retries. Final settlement determines whether work failed. A 529 followed by a successful retry may continue to evaluation. Missing permissions, credentials or a decision stops at Needs you. Children ask their parent first; only a parent's actual user question stops on the user. Resume and Confirm remain unavailable until that question closes.

A queued message asks the goal to yield after its next check. The host then delivers Up next in its existing order. Deleting, steering or draining the last held row releases that yield so an idle Working goal is not stranded. Stop/session changes do not wake it; Steer now cancels Checking and leaves the goal Paused. Pause does not discard the queue.

Elapsed time counts active work/checking, including active children. Tokens include reported worker, child, evaluator and cache usage. A token cap is a usage/spend proxy, not a fixed currency guarantee, and can overshoot by an in-flight response. A time limit stops at a safe boundary, not halfway through a write. Only goal-owned work can be aborted by the limit transition. Later ordinary turns complete without charging or renewing a stopped goal.

Controls carry session generation and the displayed goal ID/revision/state. Pause, Resume and Confirm require all those fences; both host and controller reject a stale state. Controller transitions increment revision, accounting updates do not. Editing preserves the offered state and reason, cancels stale evaluation, and changes limits or text only when different. Met remains clear-only; an editor whose check becomes Met cannot apply its old proof to a new condition.

## Persistence and projection

Canonical state lives in `shepherd.goal` session entries, not fleet persistence. Text is persisted on set/edit only; later transitions reference it. Accounting and interval snapshots do not append entries. Restore reads legacy full records and compact checkpoints; a previously active goal restores Paused and needs explicit Resume. Restart never resumes unattended work or retains a running evaluator.

The dedicated machine widget projects to `NativeGoal`, not ordinary widget text. Null announces controller availability. Snapshots carry optional `goal`; remote controls require `native.goal.v1`. Additive fields disclose the model, confirmation, check count and current interval start. `runningSince` is epoch milliseconds; clients advance the pill clock locally from accrued elapsed time. Composer/queue depend on cached `hasGoal`/`goalID`, not every clock or token update. Older hosts keep ordinary chat without goal controls.

Only live `goalState` is mirrored on `Agent` for the sidebar. Needs you blocks an otherwise idle agent. Met/Needs you transitions notify using short human metadata, never the condition, tool quotes or raw checker feedback. Ordinary turn-finished banners are suppressed only in Working/Checking. Paused, Met and Needs you do not suppress later ordinary work. iPhone alerts require permission and a connected, observing client; they are local notifications, not APNs/background delivery.

## Card

`NWGoalCard` renders the Goal card, MobileGoal and iPadGoal states above the composer, including while a question replaces the field. Goal, Subagents and Up next share one framed dock in that order. The header pill exists only while active; the iPhone keeps its lifecycle dot and word beside it. The sidebar adds the two-ring glyph without replacing ask/reason/time accessories.

The base desktop/touch anatomy is 70/92pt with 32/40pt headers and 10/12pt corners. All iOS action targets remain 44pt. Requested model disclosure adds a line and may grow the card; larger text/crowded headers reflow rather than clip controls. Working pulses, Checking spins, and reduced motion disables both. An incomplete-evidence candidate offers Confirm instead of Resume; questions disable both.

Meta is short runtime copy. Working shows tokens; Checking names safe command heads or basenames of recorded results; Met adds a structured short summary; Paused says "paused by you · the clock stops"; Needs you gives a word-bounded lowercase reason. Unresolved/quoted/substituted calls use "checking · commands unavailable"; no results use "checking · no tool results to read". Raw IDs/quotes stay in Details; legacy Evidence records remain readable. `/goal <condition>` appears in the slash menu.

See [the card spec](design/thread.md#goal-card). Long-condition truncation and the existing desktop inline/iOS sheet edit surfaces remain pending user decisions under PR #189's Departures. That section also records retained geometry, tint and legacy-summary differences. All unrequested implementation choices are listed separately under Decisions.
