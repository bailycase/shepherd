# Project execution and owner placement

The owner chooses an explicitly linked host and Space; the executor never chooses a fallback,
moves Project ownership, or interprets model prose as success. `ProjectCoordinatorController`
installs both owner placement and the existing executor adapter. Transfer/Space-selection UI is
a separate lane; these APIs do not infer consent from a name or equal filesystem path. No Linux,
billing machinery, new dependency, engine change, or repository mutation path is introduced.

## Contract and adapter

`RemoteProtocol.projectExecutionCapability` is `logicalProjects.execution.v1`, independent of
`logicalProjects.v1`. The host offers it only while started with `onProjectExecutionLaunch`
installed. Both the authenticated connection and host must advertise it. Ordinary remote
creation remains unchanged and is **not** used as an idempotent execution endpoint.

`SessionServer.projectExecution` and `RemoteHostClient.projectExecution` accept:

- `.execute(ProjectExecutionAssignment)`
- `.snapshot(key: ProjectExecutionKey, watch: Bool)`
- `.cancel(key: ProjectExecutionKey)`

`ProjectExecutionKey` contains the owner's stable UUID, ProjectID and operation UUID. Persist
and reuse the same key across reconnects. Assignment carries task ID, reserved ordinary worker
AgentID, executor-relative SpaceID, title, prompt, goal, instructions, memory and existing model
choice. It contains **no filesystem path**. IDs must be canonical lowercase UUIDs; prompt must
be nonblank and at most 16 KiB UTF-8. Title is at most 800 bytes; goal 4000, instructions 16000,
memory 8000, model identifier 512. The combined native prompt/context must also fit the existing
16 KiB native input bound; invalid inputs fail before reservation or agent creation, never as an
unknown active slot. Context and memory are bounded reference data, not another transcript.
The owner is responsible for obtaining transfer consent and selecting/redacting context before
calling this explicit host endpoint. The receiver does not read or export arbitrary folders,
credentials or another thread's context, or choose a different provider.

`ProjectExecutionResult` contains the durable receipt plus an optional existing
`NativeThreadSnapshot`. The snapshot is omitted when the original session/generation is no
longer live or the combination would exceed the existing 1 MiB frame. Use ordinary native
snapshot/history retrieval for the full conversation. Snapshot/watch registration is atomic on
the server queue. `RemoteReply.projectExecutionChanged(key:revision:)` is a hint to pull, delivered
through `RemoteHostClient.onProjectExecutionChanged` on the main queue. Each connection has at
most 128 subscriptions; disconnect removes them without cancelling work. `watch: false` removes
one. All fleet state responses and broadcasts omit the executor ledger, including for legacy
viewers; legacy clients cannot call this endpoint. macOS and iOS use the same codecs/client.

The app installs `ProjectExecutionController` through `installProjectExecution()`. It validates
the exact visible executor Space and model catalog, then uses `NewAgentConfig.reservedAgentID`
and `startAgent(selectAfter: false, focusWindow: false, initialPrompt: nil)`. This is an ordinary
worker, never a coordinator or a private Project-folder launch. The common server addAgent
boundary rechecks reservation/cancellation even if the asynchronous app launch was held.
Project-created workers are not implicit empty-window fallback selections; explicitly selecting
them still uses ordinary thread navigation. A new operation can explicitly continue the same
task's existing worker under the proof/fences below. It does not create worktrees or implement
a separate follow-up launcher.

## Durability and evidence

`ShepherdState.projectExecutions` decodes empty for older state files. Each receipt keeps the
immutable bounded assignment (or nil for a cancel-before-execute tombstone), phase/revision,
original native session/generation, matched user entry ID, bounded originating question metadata,
last assistant result excerpt/entry ID, and a factual outcome. Question metadata includes native
ID, kind, title, message and up to 16 clipped options. Result/question text is an excerpt, not a
replacement transcript. Evidence fields are bounded to 4096 bytes, identity fields to 512 bytes.

Reservation is persisted **before launch**, and `sendReserved` with session/generation is
persisted **before native send**. A duplicate execute returns the existing receipt and never
launches or sends again, including after a lost response, disconnect or restart. A changed
payload for the same reserved key is refused. A cancel tombstone prevents every late execute.
One worker cannot have two outstanding reservations. No receipt identity is automatically
evicted: the ledger refuses new admissions at 128 records or a 512 KiB encoded budget. Active
receipts reserve 64 KiB of that budget for future evidence. Manual retention/export/forget policy
is pending; deleting receipts outside such a policy would destroy replay protection.

A receiver-specific FIFO stages full workspace JSON off the server queue using the existing
`StateStore.stageLogicalProjects`/`commitLogicalProjects` primitives. Each commit checks the
full workspace version, lifecycle epoch and Space-operation fence. An intervening ordinary
workspace edit causes a new stage derived from the latest workspace, with at most eight
re-stages. Only the final atomic rename/publication is on the server queue. A stopped/restarted
server cannot commit an old queued mutation. Failures refuse admission; evidence persistence
failures close the in-memory admission fence and are logged without prompt/context contents.

Native `.accepted` is not delivery. `RPCThreadState.onUserMessageConsumed` is called from
`userMessageStarted` with the bound operation and actual entry ID. Only that match marks `sent`.
Dialogs produce `waiting` and retained question metadata. `onActualTurnSettled` fires **after**
Changes capture clears busy; status `running == false`, assistant text, and agent status reports
are not settlement evidence. Settlement records `settled` (possibly with a native error), never
model-inferred success. Native auto-retry/compaction do not themselves complete an assignment.
The native thread remains the source of full subagent, tool, retry and transcript information.

## Opening a worker from another Mac

A viewer sends `ProjectRuntimeTransport.worker(projectID:taskID:request:)` to the
Project's owner. The owner resolves the task's recorded worker and executor binding, then
uses the existing native thread API. The viewer needs no executor connection or credentials.
No request accepts a viewer-chosen worker ID or falls back to a similarly named host.
An unlaunched worker reports native startup state. Opening a thread never launches a worker.

The capability `logicalProjects.worker.v1` gates this route on both owner and viewer.
Native session/generation fences, send idempotency, image bounds and request timeouts still
apply. Answers for an active managed assignment go through the owning Project so Pause retains
them until Resume. After that assignment ends, manual questions use ordinary native answer
checks instead of the old Project receipt. During takeover, the executing host must positively
prove native user consumption replaced that exact activation in the same session and generation.
Its snapshot returns optional `workerTakenOver` evidence. A proven takeover clears the old
Project question. Later callbacks cannot attribute manual questions to that activation, even
if persistence queued the callback before takeover. This proof read preserves the owner's
receipt watch on the shared executor connection, so later question settlement still reconciles.
Missing evidence, a restart, and
`.unknown` alone never bypass the Project answer path. This live proof also prevents an old
paused envelope from capturing the new manual answer. A paused Project does not hold answers
for unrelated manual work in its former worker. The server rejects remote design references at every Project
native transport boundary before capturing content or granting design access.
The native store's existing snapshot polling reads activity and subagents; the proxy adds no
background polling service or second transcript. A changed executor binding refuses access.

## Explicit same-task follow-ups

Use the same `execute` API with a **new operation UUID**, unchanged owner/project/task/worker/
Space identities, and refreshed bounded prompt/context. The receiver, not the caller, sets the
optional `ProjectExecutionReceipt.previousOperationID` from a retained settled or acknowledged
cancelled activation that actually consumed a user entry. Old receipts decode this field as nil.
No owner scheduling/admission policy moves to the executor; owner concurrency/activation limits
still apply independently. An arbitrary existing AgentID, a deleted worker, an unknown or
interrupt-pending activation, or a changed task/owner identity is refused, never adopted.

A live worker must be servable and genuinely idle: no turn/capture, host or pi queue, preparation,
input ambiguity, dialog, compaction or pending interrupt. This is checked before reservation,
after off-queue staging and immediately before send, so a manual turn winning the race is not
silently queued behind or interrupted. The native session must still contain the predecessor's
matched user entry. Reuse invokes no launcher and preserves native conversation and generation.
Every activation has its own admission timestamp/deadline. Retrying/cancelling an older receipt
returns that receipt and cannot send or abort the newer activation or later manual work.

A clean terminal receipt permits an **explicit** idle restoration if the process is gone. The
app's ordinary `createAgentSession` path receives `requiredHistoryEntryID`: it checks the existing
private regular session file off-main and refuses missing/unreadable history rather than adopting,
seeding or starting a replacement conversation. The receiver independently verifies the resulting
native session ID, history and idle state before any send. On a changed generation the last user
entry must be the proven predecessor; later manual work without an executor settlement receipt
makes restoration conservative/refused. Long/compacted history whose predecessor cannot be
verified is likewise refused; this is not a universal Resume/recovery command. Live, proven-idle
workers can still continue after ordinary manual turns. Restarting an active attempt stays unknown
and cannot authorize a follow-up or replay.

Follow-ups preserve the native worker's model and thinking state. `model: nil` means preserve,
not reset to a host default. An explicit model must equal the live/restored native model; a
mismatch reports `execution_model` (or a retained failed pre-send attempt if detected after
restoration). Change the model through ordinary native controls first. Restoration never adds
fresh-session model/thinking flags or silently overrides manual model choices. No billing/model
calls are added by the receiver.

## Bounds, restart and Stop

Each executor independently requires Settings > Experiments > Projects (default OFF); an enabled
owner cannot enable another host implicitly. OFF refuses execute, resume and answer, fences
launch/restart and artifact publication, and pauses existing receipts through the same native
stop paths. Unstarted admissions are cancelled; original native waiting questions are parked.
Snapshot/proof reads, Pause and Cancel remain available while OFF, so a disconnected owner can
reconcile retained work without replaying it. Owner reconciliation can record evidence while
OFF but cannot dispatch work, deliver answers or commit pulled artifacts. Disconnect or failed
interruption is not completion and does not release a remote reservation. Re-enabling leaves
receipts and Projects paused until explicit Resume; no new polling or scheduler is introduced.

One assignment activates at most one native prompt, with no receiver retry/model/evaluator loop.
The default elapsed bound is ten minutes from durable admission, including launch and prompt
preparation. Deadline requests durable cancellation before interruption. This is an execution
bound, **not** a provider invoice guarantee or billing budget.

Cancellation normally persists `interruptPending` before a native abort, and does not claim
stopped until actual interruption/settlement acknowledgement. If that write fails, the receiver
retains its in-memory launch/send fence and attempts best-effort interruption only for the
identified consumed operation under its original session/generation. The caller receives the
write failure and a deadline logs it; no second timer or endless save retry is introduced. The
old durable proof remains unchanged while storage is unavailable; later retained evidence is
`unknown`, never a false `cancelled` acknowledgement. A later manual turn is not aborted. A not-yet-launched worker becomes
`cancelled`. A held preparation or host queue item is withdrawn by operation identity, not by
clearing all the worker's manual messages. Cancelling a queued preparation lets its failure
callback restore its batch, then removes only the target and preserves the pre-callback pause/
notice policy; ordinary Resume cannot resurrect the cancelled prompt. Managed sends set the
native producer's internal `isolateSend` flag, so they retain their operation identity even when
manual messages arrive on both sides in all-at-once mode. Fresh launch reservations encountering
manual work before readiness fail explicitly instead of remaining reserved until their deadline.
An accepted but unconsumed pi prompt can remain
`interruptPending`: it is not proof that a different turn is safe to abort. If its matched user
entry subsequently starts, interruption is requested then. Original session/generation and
consumed-operation fences prevent cancelling a replacement session or later manual turn.
A manual steer that takes over a project turn initially makes the attempt `unknown`; later Project
cancellation will not abort that manual turn. When native takeover evidence and the original
scope's helper-exit acknowledgement both exist, explicit cancellation can release that original
reservation as cancelled, without attaching the manual result (see Consumed-scope API below). A direct native Stop settles the admitted turn
normally with its real error evidence. Manual worker controls remain available afterwards.

Viewer/owner disconnection does not stop accepted work. Questions and results remain on the
executor. Restart marks all active receipts `unknown` and starts/replays nothing; reconnect
returns only what the ledger and original native session prove. Process exit without proven
settlement is unknown (or acknowledged cancelled after an interruption), not success. A
definite launcher failure is failed. Project deletion/receipt retention never implicitly deletes
ordinary workers, their native conversations, branches or worktrees.

## Validation and remaining integration

`ProjectExecutionWireTests`, `ProjectExecutionTests` and `ProjectExecutionFlowTests` cover shared
codecs/defaults, actual TCP lost reply/reconnect, immutable payload refusal, cancel tombstone,
held launch and prompt preparation, accepted-but-unconsumed input, the capture/idle distinction,
questions/results after disconnect, deadline/ordinary manual use, manual-steer cancellation
fencing, restart/no replay, record/evidence capacity, auth/capability/legacy privacy, launch
failure and concurrent ordinary edits during off-queue staging. Follow-up regressions cover two
operations/one worker with preserved conversation, old execute/cancel after a newer turn, busy
manual input before and during staging, each activation's deadline, disconnected/unknown refusal,
explicit clean restoration and missing-history refusal. Additional regressions exercise queued
preparation cancellation/resume, managed identity between all-at-once manual messages, manual
work during held launch completion, and a real cancellation-write permission failure after
consumption that still aborts once and leaves subsequent manual work alone. AppHarness uses the real reserved
ID launcher and stub engine, checks model/ordinary identity, no opening prompt and no selection,
and restores the stub's actual retained history without model override or fresh-history seeding.
All hosts, processes and files are scratch-isolated; no live provider or user support data.
The receiver/queue regression run passes 222 test functions, including 27 executor-specific functions;
the 27 owner/runtime tests pass separately. One combined earlier run exposed the existing owner
Pause test's stale-revision race, so that intermittent failure is not claimed fixed here. The
14 agent-document checks pass. The shared iOS check compiles Core/Protocol/Remote and passes
MobileHosts TCP checks, then stops at the pre-existing `ThreadStoreCheck.swift:164` assertion;
the complete iOS validation is not passing. No UI preview or Dev app launch is required for this
nonvisual slice; the real creation adapter is exercised through the offscreen AppHarness.

## Owner placement adapter

`logicalProjects.placement.v1` adds host-relative links and pause-preserving execution controls.
`ProjectSpaceLink.host` and `ProjectTask.host` decode absent as owner-local. Link identity is the
pair of host reference and SpaceID, not SpaceID alone. `linkSpace`, `unlinkSpace`, and `assign`
accept an optional host with the same older-local default. Remote clients refuse a remote host
argument unless the owner advertises placement support; an old owner must never ignore it and
start locally. The owner's host directory includes optional visible executor `spaces`; absent
means no advertised executor. Viewer host configuration is never used to address another owner's
executors. Each remote binding must match the persisted config ID **and** binding ID. Editing
endpoint, port or token rotates the binding and cannot redirect an old pending assignment.
Unknown/offline/unsupported hosts and missing Spaces refuse rather than map their paths locally.

The user must explicitly link that host's Space and permit its host (selected or any-connected).
The immutable assignment transfers only bounded, `NativeRedaction.projectData`-redacted title,
prompt, goal, instructions and factual memory, never arbitrary files or credential/config stores.
A worker model override is explicit. Otherwise the owner reads its current configured default
off the server queue and pins it into the assignment; a missing default refuses remote dispatch,
never silently chooses the executor's provider. Immediately before native send, the receiver
also verifies that pi's actual model equals the selected model; a mismatch fails without sending
Project data, even if a launcher had advertised or requested the intended model. Follow-up model mismatches remain receiver refusals.
User-facing host/model selection must communicate this transfer boundary; routing alone supplies
no consent UI.

`Project.ownerID` is a persisted globally unique authority UUID, independent of display labels,
transport connections or viewers. Older Projects migrate deterministically from their existing
UUID ProjectID. The owner reserves its existing task slot and activation exactly once, persisting
the chosen `ProjectExecutionAssignment` (including reserved worker/key) before async transport.
Local direct workers and remote receipts share the same default three slots, ten-minute owner
run and twelve-activation bound. A fourth task queues. Receipt hints and reconnect scans pull the
same key; there is no receipt polling loop or replacement operation on timeout. Disconnection,
missing evidence or receiver `unknown` never frees a slot. A lost execute reply is reconciled
through snapshot/watch; an explicit Resume may retry an unsatisfied reservation using only its
original assignment/key. No connectivity event dispatches a new assignment after restart.

Actual executor settlement releases capacity and queues source-identified question/result events
on the owner. Restart always pauses the owner and reconciles known receipts read-only, including
an equal-revision receipt whose owner task was marked unknown at startup. Executor work may finish
while its owner is offline; receipts remain until the owner returns. Resume is explicit. A
follow-up reserves a new operation on the same task/worker/host with refreshed bounded context;
its returned receipt must prove the exact previous operation. The executor's existing native
history, session/generation and old-cancel fencing remain authoritative.

## Questions, Pause and deletion

Execution `.pause` differs narrowly from `.cancel`: it retains a waiting native dialog and marks
`ownerPaused`; other work enters normal durable cancellation. Paused answers from either the
Project page or the ordinary executor thread are durable native intentions. Both routes keep the
original session/generation/dialog/operation fences and permit only one retained answer. Explicit
`.resume` delivers it to the original dialog; expiration or a changed session never creates a
replacement question. The existing execution deadline does not abort a parked, paused question
(no unattended work is occurring); explicit resume installs a fresh bounded deadline. Owner-side
answer delivery still uses the existing activation count. No separate evaluator or model call
is added. Reconnect alone never resumes an answer after owner restart.

Deleting a Project with outstanding remote work first pauses and requests cancellation, returning
`project_interrupt_pending` rather than erasing its only durable identity. Retry Delete after
receipt acknowledgement; offline/unknown work remains inspectable and cannot falsely free a
slot. The native worker remains an ordinary thread after terminal receipt or deletion; late
cancellation of the prior key never interrupts subsequent manual work. An offline cancellation
that never reached the executor needs explicit Delete retry after reconnect.

An executor worker receives its immutable activation context through the canonical Project
extension, refreshed from its own authenticated receipt at each turn, not a lookup of an owning
Project on the wrong Mac. Neither coordinators nor workers may spawn/continue subagents or
workflows. Workers keep their coding tools and report extra work to the coordinator, which uses
existing typed Project assignments/follow-ups for visible threads under Threads at once.
Child/workflow tools and slash commands are absent from Project launches, so codemode cannot
call their registered executors either. Explicit tool calls are guarded; the server independently
rejects `childScope`, peer spawning/steering and automation admission using retained local tasks
or remote execution assignments, not caller flags or only active phases. Manual turns and offline
executors remain restricted. Ordinary unrelated threads keep their existing tools. After local
Project deletion, the server releases membership but an existing Project-launched process keeps
its restricted toolset until fresh launch. Retained remote assignments still establish membership;
receipt-retention management remains a separate limitation. Fresh launches also use this retained
membership, including settled, cancelled, failed and unknown receipts. Only active receipts expose
the assignment instructions/memory/prompt: inactive receipts return minimal identity and a paused,
terminal/unknown task context, never replaying private owner payload into later manual turns or
granting execution authority. The synthetic per-worker context is never added to the executor's
fleet Project collection.

### Helpers and scoped cancellation

**Compatibility machinery, not current helper admission.** Project `childScope` requests are
always refused, including stale/forged requests and settled/manual Project turns. No new helper
can be admitted. The internal `ProjectChildScope` identity remains necessary for native task
activation, publication validation/cleanup, question Resume epochs and manual takeover.
The following Stop/drain behavior is retained for previously admitted controllers and tested by
explicit legacy-state fixtures, never by reopening production admission.

Project Pause/Stop and native Stop during a Project turn close that activation's admission, then
send `projectChildren(stop)` over the existing child control channel. The controller fences starts
synchronously, aborts matching workflow controllers first, awaits their pending launches/cleanup,
and stops only matching child attempts through the normal descendant cleanup/process-exit path.
Only then does `childCommandResult` acknowledge cancellation (15-second Stop acknowledgement limit;
a timeout is unknown, not proof of exit). An old scope cannot stop a resumed
manual attempt or a new operation. A paused native question stays open, but its background helpers
are stopped separately; `helpersStopped` on the execution receipt proves that acknowledgement.
Explicit Resume of the exact retained question persists a new `childScopeEpoch` on the local task
or executor receipt, then installs that scope only after rechecking native consumption, session,
generation and acknowledged old-scope Stop/drain. The old scope remains permanently closed.
Fresh publications use the new epoch even though the assignment and native user turn
are unchanged; Resume does not enable helpers. Missing epochs decode as zero. Duplicate Resume/reconnect never rotates or replays;
failed persistence, failed helper Stop, manual takeover and restart cannot restore authority.
The executor retains `childScopeResumedAt` for the renewed existing deadline; old epoch timers
cannot cancel the resumed epoch. A pending pre-Pause controller admission cannot borrow a new epoch
from a delayed authorization response.

Root `agent_settled` alone does not release a slot: `projectChildren(drain)` waits on the existing
controller's owned process/workflow promises, including report-only background children and
children omitted by the twenty-row display cap. Its acknowledgement re-enters native settlement;
there is no polling scheduler. The drain request has a 615-second acknowledgement ceiling, covering
the default ten-minute activation and cleanup. Reconnecting can recheck an idle task's drain but
never restarts it or automatically retries Stop. A drain reply cannot substitute for a pending Stop acknowledgement.
Disconnect, timeout or an older connected controller lacking scoped control keeps cancellation
unconfirmed and capacity reserved, rather than claiming its helpers exited. Even when helper Stop
fails, a deadline or active-turn Pause still attempts the root's normal queue-clear/abort path,
rechecking the original consumed scope/session/generation before abort; it never acknowledges a
combined stop or aborts a later manual turn. A parked question keeps its native dialog. Repeated
owner Pause skips only a waiting receipt with both `ownerPaused` and `helpersStopped` acknowledged,
so a reconnected executor can retry an unconfirmed helper Stop. A parent exit without
helper completion evidence remains unknown. No restart replays helpers.

Bounds reuse the worker's Project activation deadline (ten minutes), the owner's twelve-activation
run bound, existing child concurrency/retention limits, and workflow thirty-minute maximum deadline.
There is no new budget UI, billing estimate, provider route, permission setting or helper-limit knob.
The Project activation deadline does not depend on owner connectivity: the executor enforces its own bound.

Validation checks absent child/workflow registrations and commands for both Project roles,
explicit tool-call refusals and ordinary-thread preservation. Scratch-server tests reject local
and remote worker admission while active, settled and manually driven, including offline owners,
stale scopes and peer/automation bypasses. Legacy-controller fixtures retain Stop/drain,
manual takeover, question Resume, publication epoch and deadline regressions without granting
new helper admission. Ordinary-thread Node tests retain real child/workflow lifecycle coverage
against a loopback fixture provider. No real-provider or running-app validation is claimed.

### Consumed-scope API for native consumers

Server-queue-only API (not model authority):

- `SessionServer.currentProjectChildScope: [AgentID: ProjectChildScope]`
- `SessionServer.projectChildClosed: Set<ProjectChildScope>`
- `ProjectChildScope`: `key: ProjectExecutionKey` (`ownerID`, `projectID`, `operationID`),
  `workerAgentID`, `sessionID`, `generation`, `epoch: UInt64` (legacy/default zero);
  `Codable`, `Hashable`, `Sendable`. Initializer adds trailing `epoch: UInt64 = 0`.
  Local `ProjectTask.childScopeEpoch` and executor `ProjectExecutionReceipt.childScopeEpoch`
  are optional persisted fields (nil means zero). Existing `projectChildScope` overloads include
  that persisted epoch. Publishers must capture the current scope, not reconstruct epoch zero.
- `projectChildUserStarted(agentID:thread:operation:)` is called only from the consumed native
  **user** message hook, not from `agent_start`. Nil/unmatched operations are manual/peer input
  and invalidate the old scope. The pinned Pi emits owned child notices as native `role: custom`
  (`customType: shepherd-child`), including idle result continuations: they do not run this hook,
  and keep the original scope. Neither notice text nor a custom-type string restores authority
  after a manual takeover. The controller's drain waits for its queued/running dependent parent
  continuation to settle before allowing terminal task settlement.

A consumer captures the exact scope, then checks equality with `currentProjectChildScope[agentID]`,
absence from `projectChildClosed`, and its existing active task/receipt fence on the server queue
before work and again before committing off-queue results. Pause/cancel closes the scope;
terminal native settlement closes it and clears the current scope. This is an in-memory execution
fence, not persisted permission, and restart cannot restore unattended authority.

A manual takeover initially leaves the original activation unknown, without borrowing the human
result. Native consumed-user metadata records that takeover. Explicit Project Pause/cancel then
closes/stops only the original helper scope. Once the matching controller acknowledges its exits,
that proof plus native takeover permits a local stopped/settled task or remote cancelled receipt;
Resolve can release the task. The human turn/question continues untouched. This is not an
automatic resume or inferred success. Missing takeover/exit evidence still remains unknown.

## Routing validation checkpoint

Seven new real-app adapter tests use two authenticated scratch macOS servers and StubPi: mixed
local/remote three-slot admission and fourth queue, identical SpaceIDs on distinct hosts,
settlement release and same-worker follow-up, both native/Project question answers with Pause,
owner restart and retained offline results, independent remote viewer plus lost execute reply,
binding replacement refusal, link/host opt-in and redacted owner-model transfer, and deletion
cancellation followed by unaffected ordinary manual work. Existing receiver/runtime/automation
regressions, state validation and codec/default checks total 148 passing Swift test functions in
the expanded focused run;
two canonical extension tests and 16 documentation/embedded-literal checks pass. A deadline
regression proves Pause preserves the actual dialog and explicit Resume receives a new bound.
Core/Protocol/Remote compile in the iOS shared-module check,
and real-TCP MobileHosts migration/reconnect checks pass. No provider, running app, user's pi or
support data was used. No UI previews or control tests are claimed by this non-view lane.

Remaining: transfer/link and remote-question UI integration; explicit receipt-retention management;
expanded remote Stop/Steer/retry/compaction interaction matrix. The user's subsequent explicit
no-subagents requirement supersedes the earlier plan for bounded Project helpers; this is not a
temporary restriction or an enable-children setting. Scoped cancellation remains compatibility
and native-authority machinery only. Automation admission deliberately remains disabled pending
the trigger-policy decision in `project-automations.md`; this adapter
is not a scheduler or a universal job framework.
