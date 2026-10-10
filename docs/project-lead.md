# Projects

Implementation in progress. This document records the agreed behavior of the new Projects
feature, not behavior available in a released build. Folder-based work locations remain
`Space` records. Their existing configuration service is described in [projects.md](projects.md).
Owner-relative read-only artifacts and typed conversation action references are documented in
[Project producers](project-producers.md), including the API used by local and remote UI.

## Current status

The owner service, local and cross-host task execution, question routing, human chat answers,
Pause/Resume and artifact publication are integrated. UI fidelity and complete control coverage
remain in progress. The numbered slice sections below record earlier implementation checkpoints,
not a claim that their old gap lists describe the current build.

Two workflows still need a user decision. Run on another host needs destination-Space selection
and explicit commit/push behavior. Project automation execution remains disabled until the user
chooses existing prompt-based watchers or structured schedule/event triggers. Neither omission
is an approved departure from the supplied boards.

## Design and scope

The user supplied the macOS Projects page of Shepherd chat UI, revision 1406. The fourteen
unchanged reference images are saved under `docs/design/boards/ProjectLead-*.png`:
Activity, AddsSpace, New, PausedV2, Question, Resolved, Started, ThreadRunning, EmptyV2,
RunElsewhere, SettingsAutomations, SettingsGeneral, SettingsMemory and SettingsSpacesV2.

The project's main view is one ongoing conversation. Its sidebar entry and Overview collect
ordinary task threads, which can be opened beside that conversation. A Project is not a Space,
a repository, a folder grouping, or an ephemeral subagent run.

The user approved additions to the persisted models and remote protocol. Existing folder
configuration protocol names, identifiers and stored preferences remain compatible. The old
folder-based UI becomes Spaces before the new Projects UI uses that name.

### Confirmed decisions

- **D1. Assigned work.** A project coordinates tasks the user asks for, including follow-up work
  needed to finish those tasks. The goal provides context, not permission to invent more work
  indefinitely. Quick questions can be answered in the project conversation. Related follow-ups
  can reuse an existing task thread.
- **D2. Questions.** Needs you primarily means questions. A question is associated with its
  originating task thread. The user can answer in the project conversation or in that thread.
  The answer must reach the same question without being delivered twice. Unrelated work need
  not wait for the answer; dependent work must not guess an irreversible decision.
- **D3. Host ownership.** A project has one owning Shepherd host. Its ordinary task threads may
  run on that host or another connected, eligible host. Viewing the project from another Mac
  does not transfer ownership. The owning host retains the conversation, settings, memory and
  coordination state.
- **D4. Files, provisional storage choice.** Use a Shepherd-owned project directory on the
  owning host for project inputs and published outputs. Source repositories and worktrees stay
  in their Spaces. Cross-host file transfer must be explicit about copies and locations; this
  feature does not imply automatic synchronization of arbitrary user folders.
- **D5. Disconnection and restart.** If the owning host becomes unavailable, already-running
  threads on other hosts may finish their assigned work and retain results and questions. The
  unavailable coordinator starts nothing. Restarting the owning app never silently resumes
  unattended work. Reconnecting a viewer is not restarting the owning app.
- **D6. macOS hosts.** No Linux runtime is required. Run elsewhere lists actual supported Mac
  hosts, not the board's example Linux daemon.

### Approved changes to the boards

- The RunElsewhere reference includes a Linux daemon. The user excluded Linux runtime support.
  Host names, capacities, connection states and platform labels come from actual host data,
  never from the board's examples.
- The user moved Designs to the top of Activity content, below fixed navigation. The order is
  Designs, Needs you, Working, Done, Projects, Recents.
- Project coordinators and workers delegate only through Project threads, not subagents. The
  subagent-count controls shown in the boards are omitted.
- Settings > Experiments > Projects gates the feature and defaults off. Disabling it preserves
  saved Projects and pauses coordination; enabling it does not resume work.

The user also rejected billing-budget machinery and its UI. Existing time, activation and
concurrency limits still bound coordination; this feature makes no strict dollar-ceiling claim.

## Behavior required by the boards

- Creation requires a name. The goal and linked Spaces are optional. A project with no Spaces
  can discuss and plan work without silently attaching a repository.
- Adding a Space proposed by the project requires the inline confirmation shown in AddsSpace.
  Existing Space configuration and filesystem ancestry rules remain unchanged.
- Settings separates the conversation model from the default task-thread model. New task
  threads receive project instructions in addition to the selected Space's instructions.
- Threads at once is a host-enforced project limit across all participating hosts, not a
  suggestion in the coordinator's prompt. Offline work must not be assumed finished merely
  because a connection disappeared.
- **User-directed tool policy:** neither Project coordinators nor workers may spawn or continue
  subagents or workflows, on local or remote hosts. Coordinators use existing typed
  `project_assign`, `project_inspect` and `project_follow_up` controls; workers do coding work
  directly and report extra work to the coordinator for visible Project threads. All such work
  counts toward Threads at once. Ordinary non-Project threads retain their child/workflow tools.
  Project launches omit child/workflow tools and commands entirely (including direct registered-tool
  access from codemode), and reject explicit delegation calls. The host independently refuses
  child admission and peer/automation bypasses from actual retained task/assignment membership,
  including settled tasks, offline executors and manual turns. There is no enable-children setting.
  After deletion/reuse outside a Project, an already launched Project process stays restricted
  until a fresh ordinary launch; retained remote execution assignments still establish membership,
  including on fresh launches. Inactive remote receipts supply identity/terminal context only, not
  old owner instructions, memory or prompts. This is a tool policy, not an OS sandbox: workers'
  normal coding tools, including bash, remain available.
- Opening a thread shows its existing conversation, not a duplicate agent or transcript.
  Direct steering goes to that thread. Project-conversation follow-ups route to the appropriate
  thread as coordinated work.
- Questions and results retain their originating thread identity. Model prose is not proof
  that a thread finished or that a question was answered.
- Resolved threads remain inspectable and can be reopened. They are not deleted. A thread
  becoming idle is not automatically proof that its assigned task succeeded.
- Pause prevents new coordinated work and automation runs and requests safe interruption of
  active project work. Messages sent while paused wait for explicit Resume. The UI cannot
  claim an unreachable worker stopped before its host acknowledges that request.
- Project deletion removes project-owned conversation, memory and automation records while
  retaining ordinary task threads in their Spaces, their worktrees, branches and pull requests.
  Project-owned file retention or deletion must be explicit in the deletion confirmation.
- Memory is inspectable and forgettable, distinct from standing instructions. Forgetting a
  memory entry stops future memory injection; it is not a promise to erase historical chats.
- The Activity sidebar and Space-organized sidebar both include the new Projects destination.
  Preserve unrelated navigation, thread visibility and existing user settings.

## Delivery and validation

1. Rename the existing folder-oriented visible UI to Spaces. Keep legacy Swift/protocol names
   where a cosmetic rename would break compatibility or expand the change needlessly.
2. Add the new project record, ownership and worker associations, owner-side mutations and
   remote capability. Old persisted workspaces decode with an empty project collection.
3. Implement the real create, conversation, task, question, pause, resume and delete paths
   before wiring controls or previews to them.
4. Implement the supplied boards using the UI/UX helper, ShepherdUI components and tokens.
   Write the element, state, copy-producer and control checklist before UI code.
5. Verify model and codec round trips, local and remote mutations, two-client stale actions,
   concurrency admission, disconnection and restart behavior, and controls through scratch
   offscreen integration tests. Render actual producers in light and dark at normal and 1.3
   text scale, including empty, long, paused and unavailable-host states.
6. Review against the boards and [autonomous-work rules](rules.md). Document and test default
   iteration, elapsed-time and concurrency bounds before enabling unattended coordination.
   Billing-budget machinery is excluded by the explicit user decision above. Do not add an
   unbounded retry or model polling loop.

The new project-specific settings and task UI must use real data and functional actions. A
placeholder control or sample row is not completion. Full feature implementation and validation
remain outstanding until these paths are connected and tested.

## Slice 1: persisted owner service (implemented, no UI or dispatch)

`ShepherdCore.Project` is a new logical record, not a `Space`, `ProjectListing` or directory
configuration entry. `ShepherdState.projects` decodes `[]` in old workspaces. The owning host's
server queue is authoritative; every successful mutation persists through `StateStore` and
broadcasts the new state. Viewing or editing through another device never transfers ownership.
The configuration API alone creates no coordinator, thread, worktree, process, automation or
model call. The owner-local runtime below can now allocate `coordinatorAgentID` lazily. A runtime coordinator has an explicit ownership marker and reserved hidden Space; it is
stripped from legacy remote fleet snapshots rather than appearing as an ordinary thread.

### API for consumers

Core types live in `Sources/ShepherdCore/Project.swift`:

- `ProjectID`; `Project` with `id`, `name`, `goal`, `coordinatorAgentID?`, `revision`, `paused`,
  `settings`, `memory`, and `linkedSpaces`.
- `LogicalProjectSettings(maxConcurrentWorkers: 3, conversationModel: nil, threadModel: nil,
  instructions: "", canRequestSpaceLinks: true)`. Model preferences are the existing
  provider/model strings used by `Agent.model`. Save does not require a currently available
  model; a future launch must validate against the owning host's catalog. The Space setting
  allows **requesting user approval**, never automatically adding a Space.
- `ProjectMemory`: generated `ProjectMemoryID`, text, source label and host-assigned epoch
  milliseconds. Source/text are inspectable data, not instructions or authenticated model proof.
- `ProjectSpaceLink`: executor-relative `spaceID`, optional owner-relative `host` (old records
  default local), host-stamped provenance and `linkedAt`. A remote link requires the owner's
  exact authenticated binding and visible executor Space; no viewer-relative host IDs.

Both `SessionServer` and `RemoteHostClient` expose the same entry point:

```swift
func logicalProjects(_ request: LogicalProjectsRequest) async throws -> LogicalProjectsResult
```

`Sources/ShepherdProtocol/LogicalProjects.swift` defines:

- `.list`, `.get(projectID:)`
- `.create(projectID:name:goal:linkedSpaceIDs:)` (linked IDs default empty). Generate one ID
  before submitting and keep it for a retry. Existing identity returns the current record,
  without overwriting later edits or applying a retry's different name/goal/Space selection.
  Initial links are validated together before directory creation and again before commit.
- `.edit(projectID:expectedRevision:name:goal:)`
- `.settings(projectID:expectedRevision:settings:)`
- `.setPaused(projectID:expectedRevision:paused:)`
- `.addMemory(projectID:expectedRevision:memoryID:text:source:)`
- `.forgetMemory(projectID:expectedRevision:memoryID:)`
- `.linkSpace(projectID:expectedRevision:spaceID:)`, `.unlinkSpace(...)`
- `.delete(projectID:expectedRevision:)`

Results are `.projects([Project])`, `.project(Project)`, or `.deleted(projectID:)`. Use the
returned revision (and pushed `state.projects`) for the next action. Never overwrite a stale
view with a bulk state snapshot: `putState` refuses changes to logical projects. Settings is
one replacement of the displayed settings, not an unchecked patch. Every mutation except
initial create carries a revision, including Pause and Forget. A failed save leaves committed
metadata unchanged. Only an existing, non-hidden Space in the owner's authenticated destination
  directory can be newly linked (see `project-execution.md`). If an independently deleted Space leaves a
link, its provenance remains inspectable and unlinkable; do not present it as an available
execution target.

### Lifecycle, storage and errors

New projects are ready (`paused == false`) but launch nothing. Missing decoded `paused` is
conservatively true. Startup forces existing projects paused and increments revisions when it
changes pause state or clears a dangling coordinator reference. Reconnecting a viewer changes
neither. Pause/Resume only persist the admission setting in this slice; there is no dispatch or
active project process to interrupt. The intended full Pause behavior remains safe interruption
of active work, **not** a promise that accepted work always finishes.

The private directory is beside the injected state URL, at `logical-projects/<canonical UUID>/`.
The trusted state parent is canonicalized (macOS aliases `/var` and `/tmp`), then descriptor-relative
`O_NOFOLLOW` checks refuse symlink traversal; both new directory levels use mode 0700. An
existing unknown directory, file or symlink is never adopted, replaced or recursively removed.
Directory operations and state JSON encoding/writing run off the server queue. Completion
rechecks the project revision, full workspace version, lifecycle epoch and Space-operation
fence. The final atomic `rename` stays on the server queue so the check, file replacement and
published state cannot interleave with another service's commit; this is the only new on-queue
filesystem operation. A concurrent unrelated workspace change refuses the save, rather than
losing that change. Failed/stale stages unlink only their temporary state file.

**Deletion retains the project directory and every artifact in it.** Only the logical record
(settings, memory, links, coordinator reference) is removed. Ordinary agents, transcripts,
Spaces, worktrees, branches and PRs remain. A coordinator ID alone does not prove ownership of
an ordinary agent, so no agent metadata is deleted in this slice. Project-owned artifact
cleanup/retention choices and coordinator lifecycle remain future work. A create whose directory
was staged but whose metadata could not commit also retains that directory and reports failure;
a retry cannot silently adopt it. A deleted ID likewise cannot reuse its retained directory.
The deletion UI must disclose this policy rather than claiming files were removed. With the
owner-local runtime below, a reciprocally marked coordinator's metadata is removed and its
process stopped too; an unmarked optional reference still never authorizes deleting an agent.

Refusals have stable codes: `invalid_project`, `no_such_project`, `stale_project`,
`workspace_changed`, `project_busy`, `project_limit`, `conflict`, `no_such_space`,
`no_such_memory`, `project_directory`, `project_directory_exists`; persistence errors travel
as `project_failed` remotely (local persistence throws its underlying error). The remote client
refuses missing capability with `update_required`; the listener refuses with `unsupported`.
Surface the returned message, refresh after stale/workspace conflicts and let the user retry;
never blindly replay an edit with a new revision. No input is silently truncated.

### Decisions: storage resource limits, not execution policy

This slice bounds persisted configuration to 32 projects per owner, name 200 characters, goal
4000, instructions **16000 characters**, model identifiers 512, 64 memories per project with
4000 characters each and 200-character source labels, and 32 linked Spaces per project.
Duplicate project/memory/link IDs and invalid record invariants are rejected. The complete
logical-project collection is capped at 512 KiB encoded and a mutation cannot make a workspace
broadcast exceed the existing 1 MiB protocol frame. At most eight state saves and 32 creates
(including existing records) may be pending. These are storage/backpressure safeguards, not a
three-project product limit. **Three concurrent threads per project** remains the design default;
settings accept 1...6 but no worker admission exists yet. No billing ledger, budget setting,
provider reservation, scheduler or pi runtime change is part of this slice.

### Verification and remaining work

`LogicalProjectTests`, `LogicalProjectsWireTests` and `LogicalProjectsTests` cover old state
and record round trips, every request/result, defaults/limits, local and real TCP-client CRUD,
initial atomic Space links, host provenance, settings, memory forgetting, stale second-client
requests, off-queue staging races, startup pause, stop during staging, preservation on deletion,
filesystem/write failures and capability refusals. Existing state-validation/store and remote
request/reply/listener suites also pass (117 focused Swift test functions), as do the 14 agent-doc
checks. The iOS check script compiles the shared modules and passes MobileHosts' TCP checks,
then stops at `ThreadStoreCheck.swift:164` (late-send cancellation/draft retention); the complete
iOS check is not passing. All tests use scratch hosts; none launches an app or reaches user
support data. That baseline did not include the owner-local runtime described next; UI and
cross-host execution remain separate work.

## Runtime: bounded owner coordination (slice 2 foundation, phase 3 tools)

The coordinator now dispatches assigned work through typed tools and receives native worker
result/question events. It uses the existing RPC threads and ordinary launcher, not another
scheduler or a polling model. A remote viewer can use a Project on its owner Mac. Worker
placement on a different executor now uses the bounded adapter in `project-execution.md`; it never pretends an
owner-local Space ID names a Space on the viewer or another Mac. There is no Linux runtime,
billing ledger, budget UI or strict invoice guarantee. The user's Designs-first priority wins.

### Experiment admission

Projects is opt-in in Settings > Experiments, OFF by default on every host. The app queues
`SessionServer.setProjectsEnabled(_:)` from `AppSettings` before binding the remote listener or
installing runtime adapters. Project creation, feature RPCs, coordinator tools, assignments,
follow-ups, automation admission and question delivery require the owner's switch. Disabled
requests say “Enable Projects in Settings > Experiments.” Existing Spaces (including legacy
folder `project_*` tools), ordinary threads and saved Project data are not removed or disabled.

Turning OFF immediately revokes active run admissions and publication authority, then uses the
existing Pause/stop paths for owned Projects and executor receipts. Generation checks fence
staged writes and delayed callbacks across OFF/ON. A worker prompt waiting for Changes preparation
is withdrawn by its exact native delivery ID, even before consumption establishes its run scope.
Releasing the preparation cannot send it; explicit Resume uses a new native delivery ID. Manual
messages in that worker are not cancelled. Saved messages, files, memory, links and ordinary
worker threads remain. Turning ON never resumes work; use explicit Project Resume
or start. Restart likewise restores paused work. Worker no-subagents policy is membership-based
and remains enforced even with the experiment OFF.

### Runtime hooks

`vm.projectCoordinator` is a `@MainActor ProjectCoordinatorController`:

- `sendProjectMessage(projectID:expectedRevision:operationID:text:) async throws -> Project`
- `ensureProjectConversation(projectID:expectedRevision:) async throws -> AgentID`: finds/restores
  an existing active conversation idle, without a prompt. A paused Project requires explicit
  Resume first; an empty project requires its first message.
- `perform(projectID:expectedRevision:request:) async throws -> Project`
- `conversationStore(agentID:) -> NativeThreadStore?`: the normal shared agent store, not a
  copied transcript. Composer sends use the Project hook. Raw coordinator sends, queue actions,
  Retry, explicit compaction, goals and subagent commands are refused, not unbounded alternate
  admission paths. Native automatic compaction stays in the same timed run.
- `perform(_ transport: ProjectRuntimeTransport) async throws -> ProjectRuntimeResult`: owner
  adapter for host options and native worker/conversation access, not a viewer-local fallback.
  Remote `.action` and `.answer` requests enter the server's runtime service directly, retaining
  their admission generation rather than waiting on a GUI callback across an experiment toggle.

These call `SessionServer.projectRuntime(_:expectedRevision:request:)`. `ProjectRuntimeRequest`
contains `conversation`, `message(operationID:text:images:)`, `assign(operationID:spaceID:title:prompt:)`,
`followUp(taskID:operationID:text:)`, `resolve(taskID:)`, `reopen(taskID:)`, `pause`, and `resume`.
Additional actions are `read`, `inspect(taskID:)`, `proposeSpace(operationID:path:spaceID:originTaskID:)`,
`decideSpace(proposalID:expectedProposalRevision:accept:)` and `remember(operationID:text:taskID:)`.
Model resolution supplies an optional `operationID` on `resolve` for durable retry receipts.

`logicalProjectRuntime.v1` is advertised only with an owner launcher and runtime callback.
`RemoteHostClient.projectRuntime(_:)` accepts `ProjectRuntimeTransport.action`, `.conversation`
(native snapshots/controls), `.answer` (original worker native question fence), and `.hosts`.
Results are `.project`, `.native`, or `.hosts([ProjectHostOption])`. Authenticated requests route
through `SessionServer.onProjectRuntimeRequest` to the OWNER VM/controller. Legacy fleet snapshots
still omit coordinators. Project-capable viewers read the native conversation explicitly.
`SessionServer.answerProjectQuestion(_:expectedRevision:taskID:request:)` accepts only a bounded
native `.answer`. The coordinator-only `project_answer` relays a verified human chat reply through
this same owner path; it cannot originate an approval or approve a Space link.

First send reserves the coordinator identity before launching. `Agent.coordinatorFor` is set
before its first publication; `Space.holdsProjects` is hidden and not an automation Space.
`ShepherdState.isProjectCoordinator`/`isOrdinaryThread` are the presentation predicates. The
coordinator directory is excluded from legacy Space configuration/history, including session
header imports. Legacy remote snapshots omit coordinator agents/layouts. UI integrations must
use these predicates in ordinary sidebar, palette, pin and notification producers. VM fallback
selection cannot select a coordinator as an ordinary thread.

`Project.tasks` contains `ProjectTask` records: ID, current/prior operation IDs, worker agent,
owner-local Space, title, prompt, phase, revision, optional error, settled timestamp and question
title. Phases are `queued`, `reserved`, `running`, `waiting`, `settled`, `resolved`, `unknown`,
`failed`. **Settled means an admitted worker emitted an actual started/settled native turn, not
success or automatic resolution.** User resolution requires settled; Reopen returns resolved
to settled. Follow-up reuses a settled worker and its native conversation. Active work can still
be steered directly in that ordinary thread; a project follow-up to an active/unknown task is
refused, not silently reinterpreted. Questions retain worker identity and remain inspectable.

`Project.messages` retains bounded queued/delivering/delivered/unknown/failed receipts.
Human image-only and text-plus-image submissions use optional `NativeImage` inputs; durable
receipts retain bounded private blob descriptors, never image bytes in Project JSON. Paused
images wait for explicit Resume and restart remains paused. Remote image submissions require
`logicalProjectRuntime.images.v1` and must fit one frame; oversized sends fail before transmission
without clearing the draft. Storage, privacy and UI API: [Project producers](project-producers.md). A retry with the
same operation identity returns the current record without another prompt, even with a stale
revision; changed retry text is never applied. Reservations persist before asynchronous worker
creation and prompt dispatch. Runtime writes use the existing staged StateStore path: validation,
encoding and file writing are off the server queue; one version-fenced atomic rename publishes.
A bounded FIFO serializes runtime writers (32 waiting), with at most eight rebases for unrelated
workspace churn. Project revision and lifecycle-epoch checks never silently rebase a stale user
mutation or revive old callbacks after restart. Reserved/running/waiting/unknown tasks occupy slots. The default
three-worker limit is host-enforced; a fourth user assignment queues until actual settlement.
Lowering the configured limit blocks new admissions without killing already admitted workers.
Launch failures mark failed and free a slot without an automatic retry. A send with an unknown
outcome stays unknown rather than replaying on reconnect or restart. Native `.accepted` does
NOT mean delivered: a message advances only when its exact native prompt starts/gets consumed.
A definite pre-send cancellation retains the message/assignment and records a new native
`nativeDeliveryID`; its public operation identity stays unchanged. Definite refusal fails instead
of occupying an unknown slot. Text admission matches native trimmed-nonempty, 16 KiB UTF-8 limits;
the Instructions editor's independent character counter does not change.

### Pause, bounds, restart and deletion

Pause closes admissions, retains new messages and queued assignments, and issues native aborts
for active project work. `interruptPending` distinguishes the request from acknowledged idle
processes; pending launcher callbacks also reconcile the acknowledgement. A worker solely waiting
on an actual native human dialog is a safe pause point and is NOT aborted. Concurrent non-question
tool work still interrupts. Both native answer views enter the same owner gate while paused:
`ProjectTask.pendingAnswer: ProjectQuestionAnswer?` persists the original operation/session/
generation/dialog identity and a bounded opaque native answer envelope. Its phase is queued,
delivering, delivered, failed or unknown. UI shows queued as waiting for explicit Resume; it must
not display or log the envelope. Resume revalidates the original live dialog and consumes the
answer once; expired/replaced dialogs fail honestly, never become synthetic replacement dialogs.
Restart marks retained answers unknown and never sends them. An ordinary worker Stop can explicitly
cancel its dialog. Resume is refused until pending interruptions are acknowledged.
Native Stop on the coordinator also pauses its project. Ordinary
worker manual sends remain available after project Pause or a limit stop. Restart pauses, marks
in-flight assignments/deliveries unknown, clears ephemeral run admission, and sends no prompts.
Restoring an existing coordinator is idle. Unknown assignments conservatively retain slots;
there is no automatic recovery/replay policy yet.

One explicit active run admits at most **12 activations over 10 minutes**, including finite
result/question wakeups and resumed queued answers. Host counters/timer, not prompts, enforce this;
it is not a strict spend ceiling. No polling model, invented backlog or automatic task retry is
used. First-class child/workflow/peer/automation spawn/send bypasses are gated for active assigned
workers; ordinary coding tools stay available and settled workers retain ordinary manual use.
Record limits remain 64 task links, 32 activations and 32 resolution receipts per task, 64 message
receipts, 32 Space proposals and 128 memory-operation receipts within the encoded project budget.
A full event receipt queue pauses and records an inspectable error; the native result remains in
the worker conversation. These are bounded interim resource safeguards, not billing policy.

Delete removes the project and only a reciprocally marked coordinator's agent/layout metadata,
related coordinator automation records, and running coordinator process. Ordinary workers and
their native conversations/worktrees remain. Project directories and native session files are
retained; no recursive artifact cleanup is introduced. Late reservations cannot create new
coordinators after deletion, and no project prompt is dispatched after its owner record goes.

### Owner runtime revocation and exit fixes

An admission revoked by Pause (`project_paused`) is not a storage failure. The running/delivering
transaction invokes its failure cleanup, dropping only the matching unsent operation fence;
Pause can acknowledge and explicit Resume can reuse the durable reservation. Actual staging or
commit failures still close admissions through the separate persistence-failure barrier.

A coordinator process exit marks its still-delivering messages `unknown`, retaining their IDs
without replay. Explicit Resume plus a new message can restore a dead coordinator session and
deliver only the new input; a retained dead thread is not mistaken for a live session. Runtime
transactions also reconcile scoped automation metadata before staging, just like ordinary and
settings mutations: actual runtime Pause removes an already-published hidden watcher and stops
its process immediately while preserving ordinary workers and artifacts. This cleanup does not
install the automation admission adapter.

Regressions hold the writer with Pause queued ahead of the ready transition, exit an accepted
but unconsumed native coordinator prompt, and invoke the real app controller's runtime Pause on
a published watcher. The focused owner-runtime/coordination/automation-app run passes 26 tests,
including the existing genuine persistence-failure regression.

### Typed tools, live context, Space approval and hosts

The one canonical `shepherd-project-context.ts` plus its synced embedded literal registers only
`project_read`, `project_inspect`, `project_answer`, `project_assign`, `project_follow_up`, `project_resolve`,
`project_propose_space` and `project_remember` for coordinators. Ordinary workers get no coordinator
tools. Kernel extension-peer identity, reciprocal coordinator ownership, revision, operation,
linked Space and host permission checks run independently on the host. These primary tools are
not available in unrelated threads. Launch still disables generic tools/discovery/skills/context
files; the extension allows only this explicit project toolset. Peer listing excludes private
coordinators and their working directories.

Native settled assistant content and native question data create durable, source-identified,
quoted event receipts. Duplicate native callbacks cannot wake twice. A remembered claim must name
an inspectable settled task; it is not a host-certified assertion of success. Common credentials
and private keys are redacted in forwarded data, including human-written memory source labels.
Model-facing Project copies omit immutable execution assignments from tasks and receipts. These
transport payloads retain old context for retry equality, not future memory injection. Task and
receipt identities and status remain visible; the persisted assignments are unchanged. This
model-facing copy is display data, not a valid record to replay or persist. Forgotten memory's
operation receipt remains so a retry cannot resurrect it. Every new native turn reads current instructions/goal/memory from the
owner, replacing the extension's previous context block rather than appending stale facts. A
failed refresh supplies no cached memory. Explicit model preferences apply before the next
admitted native turn; a Project model picker must update that preference, not only native state.

#### Human chat replies to worker questions

`ProjectRuntimeRequest.answer(operationID:taskID:questionEventID:humanReplyID:answer:)` is available
only to the current active coordinator over its authenticated extension connection. `project_answer`
maps natural human wording to an exact native select option, confirm boolean, input or editor answer;
it must cite the owner's question event and human reply IDs. A pending question does not authorize
answering unrelated user work. Worker text, tool output and synthetic Space-decision messages remain
data, never human permission; the coordinator must ask rather than guess ambiguous answers.

Only human `.message` admission sets optional `ProjectMessage.humanSubmitted = true`. Legacy messages
and source-nil synthetic messages do not qualify. The server requires actual native consumption in
the coordinator's currently in-flight turn, with the human message ordered after the question event.
The owner derives worker, task activation, session, generation and dialog from the typed question
source, then rechecks that exact live native question and answer type/options at dispatch. A button
answer, expired dialog, changed activation/generation, manual takeover, stale revision or wrong
Project cannot redirect the chat answer to another question. Ordinary native controls need no
coordinator proof and keep their existing behavior.

`project_read`/`project_inspect` expose at most the current eligible human message, redacted, alongside
inspect's existing three worker events. They never expose chat history, image descriptors, chat-answer
payload receipts or immutable execution retry context. Native question sources carry optional
generation; old events without it cannot authorize a relay.

The owner retains up to 64 chat-answer receipts per Project under their human messages, each binding
operation, task, question event and the exact bounded native answer envelope (32 KiB). Identical
accepted retries do not dispatch again; changing the answer or source under an operation refuses.
In-flight/unknown delivery is reported as uncertain, never retried as a fresh answer. A definite
pre-dispatch refusal marks its chat reservation failed and retains the user text, question and exact
operation/payload receipt. That failed identity cannot be recycled or changed; a fresh tool call with
the latest revision may try the same answer under the current human proof, or a later consumed human
reply may authorize a new call. Only failed reservations stop blocking a new operation: delivering,
unknown and accepted receipts never reopen. Local and
remote delivery reuse `answerProjectQuestion`/`answerProjectPlacement`, including their existing
native answer identity and transport receipts. Paused chat replies stay queued: only explicit Resume
can consume the reply and admit a relay. Restart never resumes this work automatically. No new model
call, scheduler, classifier, spend/iteration policy, or answer transport is added.

`ProjectChatAnswerTests`, `ProjectRuntimeWireTests`, `ProjectPlacementFlowTests` and the canonical
extension tests cover causal human proof, spoofed/synthetic/old sources, identity/generation/type
refusals, privacy, receipt limits and retries (including an intervening revision at the explicit
post-admission dispatch boundary, then fresh calls in the same or a later human turn), expired/replaced questions, and actual script-stub
local/two-host native select closure exactly once, both running and after Pause/Resume.

`Project.spaceProposals` retains UUID id/operation, path OR existing Space ID, displayPath,
phase pending/accepted/denied, optional originTaskID and revision. Only a human `decideSpace`
acceptance validates through the existing directory/Space service and links with provenance
`.project`. Denial is consumed, not Not now. Disabling `canRequestSpaceLinks` consumes pending
proposals as denied; a later model request stores no actionable approval. Acceptance/denial can
notify the coordinator within the same run bounds.

`settings.hostPolicy` is selected/anyConnected; `allowedHosts` contains owner-relative `.local`
or `.remote(hostID:bindingID:)` references. New bindings must be currently connected and known to
the OWNER. Existing references may survive disconnect but never silently follow a changed binding.
`.hosts` returns owner-known option names and optional visible executor Spaces, not viewer
configuration. The integrated placement adapter counts local and remote tasks in one admission
ledger; transfer/link UI must use these exact references, not labels or path equivalence.

**Decisions:** new Projects default to selected/[local] (the owner Mac). The board depicts a
configured selection, not a creation default, so this is not a design departure. Remote hosts
require explicit user permission and linked Spaces. No budgets or Linux support were added.

### Verification and integration boundaries

Real StubPi extension-socket tests prove coordinator dispatch (three reserved, fourth queued),
reused follow-ups, actual result wakeups once, native question cards/answers, pause-preserved
questions with durable delayed answers, restart without resumption, stale answers, Space approval
and provenance, launch/write/backpressure failures and activation/time bounds. Node tests execute
the canonical extension against a real local socket to check tool request identities, context
refresh/Forget and worker tool fencing. AppHarness verifies actual launch isolation, native model
changes, remote viewer-to-owner controller/conversation/answer routing, and private peer filtering.
Ordinary native queue/thread suites, codec round trips and the bare-agent launch contract also run.

Cross-host owner placement is integrated with the native isolated-send/actual-consumption hooks
and tested through the real app adapters (see `project-execution.md`). Automation admission stays
disabled pending the trigger-policy decision in `project-automations.md`. Coordinator raw Retry
and explicit compaction are intentionally refused; ordinary workers keep their native controls.
Unknown assignment/answer recovery remains explicit inspection, never automatic replay. Backend
checks do not claim the separately owned transfer/link/question UI controls or renders are complete.

## Slice 3: Projects UI over the owner service (implemented here; no coordinator, tasks or dispatch)

The Mac UI for the persisted record only (`LogicalProjectsModel`, `ShepherdViewModel+LogicalProjects.swift`). It
creates no thread, session or process and fakes no conversation, task or send.

- **Sidebar, both modes**, **New project** (Name required, Goal and Spaces optional; the chosen Spaces go in the
  same `create` request, so the project and its links commit together), a **Project page** (the Empty overview:
  name, goal, a Spaces row, an Instructions row, Suggestions drawn from real context), and the four
  **Project settings** tabs. They are not the global Settings > Spaces table.
- **General:** Goal, Conversation and Thread model (the owner's real catalog; "Default" clears the choice), Threads
  at once 1...6 (default 3), Pause or Resume, Delete. **Spaces:** the linked Spaces (owner-relative), Add a space,
  Remove, and "The project can add spaces" (`canRequestSpaceLinks`). **Memory:** the instructions with a counter read
  from the text and `Project.maximumInstructionsLength` (16,000), and Forget. **Automations:** an honest empty
  state, because an `Automation` has no project link yet.
- **Revisions:** every action carries the revision it was shown. A `stale_project`, `workspace_changed` or
  `no_such_project` refusal re-reads the owner, shows its message and never replays the edit. An older answer
  never replaces a newer record; the owner's pushed state wins at the same revision.
- **Delete says what stays:** the confirmation states that the project's files stay on the host, which is what the
  host does (see the Slice 1 retention policy). It never claims removal.
- **Paused:** a project restored paused shows "Paused. Nothing new starts until you resume." with a working Resume.
  A new project is ready.

Verified with `LogicalProjectsModelTests` and `LogicalProjectSidebarTests` (unit), `LogicalProjectControlTests`
(a real scratch server, offscreen ControlPress) and `LogicalProjectPreviewTests` (real producers, light and dark at
1 and 1.3). See [ProjectLead-checklist](design/boards/ProjectLead-checklist.md) for each board's status.

## Slice 4: the Project conversation, tasks and thread pane (UI over the runtime)

The page is the shared thread over the coordinator's own native store (`ThreadView` + `projectCoordinator.conversationStore`), never a
copied transcript. Only the composer's **send** and **placeholder** differ (`ProjectComposerSend`, an environment value around the thread):
a send uses one operation identity per text-and-images submission, so a retry never delivers twice. While paused a message
is accepted and held by the runtime (queued, not delivered), and Resume is a real control until the owner acknowledges the interruption.

- **Right pane:** Waiting on you, Working and Resolved groups from `Project.tasks`; a row's detail is the worker's own question (waiting) or
  its latest native activity (running); ages come from the task's own clock. Opening a row shows the worker's **ordinary** thread with its
  own composer (steering stays native); Resolve, Reopen and Open as a thread are real runtime calls with the displayed revision.
- **Questions:** a waiting task's native dialog is drawn as lettered options and answered through `answerProjectQuestion`, so the same dialog
  is not answered twice.
- **Coordinators are not threads:** every ordinary-thread producer (sidebar in both modes, completions, palette, pins, notifications, remote
  inspection, peer lists) now asks `isOrdinaryThread`, covered by `ProjectCoordinatorHiddenTests`.
- **Settled is not done:** the strip counts only what the person resolved ("1 of 3 done"); a settled turn is finished work awaiting a decision.
- **Remote Projects:** an owner-remote Project's runtime actions are refused in words; they are never sent to this Mac's runtime.

Verified with `ProjectPagePresentationTests`, `ProjectCoordinatorHiddenTests` (unit), `LogicalProjectConversationTests` (real scratch
server, stub engine, ControlPress) and `LogicalProjectPreviewTests` (2x renders). Not built: the AddsSpace offer card, Run elsewhere, task
cards inside the conversation, and the pane's Files, New thread, Search, Filter and Expand. See [ProjectLead-checklist](design/boards/ProjectLead-checklist.md).

## Slice 5: the Threads pane header, and what the UI still needs from the owner

The pane header draws every control the Started board draws, and each acts.

- **Threads / Files / Automations** switch the pane's tab. Automations shows the same owner rows as Project settings.
- **New thread** opens a sheet (title, prompt, one of the Project's linked Spaces) and sends the revisioned `assign` request with one
  operation id per sheet, so a retry never starts a second thread. It is disabled with a reason when the Project has no linked Space.
- **Search threads** and **Filter** narrow the task list locally over the real `ProjectTask` rows (title, subtitle, group).
- **Expand** gives the pane the whole page; the same button (named Collapse) restores the conversation.
- A task row's subtitle is its worker's own native activity line, and its age is the worker's last user message (else its last status
  change). Nothing is typed in. The branch pill reads the worker Agent's own worktree branch and is absent without one.
- The conversation and a worker's thread draw a day separator from the first turn's real timestamp.

**Files: producer required.** The tab is drawn and says so in words ("This host does not list a project's files yet"); it lists nothing
it cannot read. The UI needs a read-only owner request, `LogicalProjectsRequest.files(projectID:, path:)`, answering
`[ProjectFileEntry]` with `name`, `relativePath`, `kind` (file or folder), `size`, `modifiedAt` and the producing `taskID?`, rooted at the
Project's private directory (`logical-projects/<id>/`) and refused for any path that escapes it. A remote Project lists through the same
request; opening a file on a remote host needs a `read(projectID:, path:)` (bounded, text or image only), while a local Project opens with
`NSWorkspace`. Until then neither draws a row.

**Conversation task cards: typed results required.** A card draws only from a decoded `ProjectTask`. The coordinator tools
(`project_assign`, `project_propose_space`, follow-up) must return, in the tool result's retained `details`, `{ projectID, revision,
taskID?, operationID, proposalID? }`, and `NativeThreadMessage` must project `details` for a tool result so the card finds its task by
`taskID` instead of parsing the title or prose. A card whose task is gone is not drawn.

## Slice 6: Phase 3 wiring, and the gap list at this checkpoint

Wired over the owner's Phase 3 contracts (nothing here is typed in or invented):

- **Hosts row** (Spaces tab): options come from the OWNER's `.hosts` result (`ProjectHostChoices`): "This Mac and <host>" for each other
  host the owner knows, "This Mac only", "Any connected host". "This Mac" is the owner's machine, so a remote owner's own name replaces
  it. A binding the owner no longer knows reads "an unknown host". Choosing saves `hostPolicy`/`allowedHosts` against the revision shown.
  It does not claim cross-host placement; that is the execution adapter's.
- **Space offer card** (`NWLeadSpaceOffer`): drawn only for a proposal still `pending`. "Add to project" is `decideSpace(accept: true)`,
  "Not now" is `accept: false` (consumed as denied), both against the proposal's own revision.
- **pendingAnswer**: a held answer is said in words ("Answer queued · Sends when the project resumes.", "Answering", "Answer failed",
  "Answer unconfirmed"), its task is not asked again, and the envelope is never read, shown or logged.
- **Remote owner**: Project actions, answers, the coordinator conversation and each worker's thread go to the OWNER
  (`ProjectRuntimeTransport.action/.answer/.conversation`, and the owner's agent route for workers). Nothing runs on the viewing Mac.
- **Sidebar**: New thread, Designs (while the Design tool is on), Automations, exactly as the boards draw it. There is no More; the
  palette opens Hosts, Design systems and Extensions. **Decision for the user**; alternatives are in the checklist.
- **Subagent pill**: the pill on a task row (`po-sub`, "Subagents") is the worker's live subagent count, not a branch.

**Gaps that remain at this checkpoint (each is named, none is "later"):**

1. **Attachments in a Project message.** The paperclip is drawn and opens the real picker, but the Project send carries only text. A
   message with images is refused in words on the composer's own failed line, and the draft and every image stay (`carriesImages` is
   false until the runtime accepts them). Needs the owner's attachment transport (reuse of native image upload); the UI then passes the
   images and clears only the ones the owner acknowledged. Not verified: the system picker itself cannot be driven offscreen, so the
   test presses the paperclip and puts a real fixture image through the composer's own attach path, which a picked file also uses.
2. **Offer card position.** The board draws it inline under the assistant's prose; it is docked above the composer today. It moves
   into the transcript with the typed `projectAction` result (same for the three task cards).
3. **Files tab** and **typed task cards**: waiting on the merged `.files/.read` (`files.v1`) and `NativeThreadMessage.projectAction`.
4. **Hosts link**: `link(ref, space, host:)` is not used yet; the Spaces tab links on the owner.
5. **Not rendered or compared yet**: the Settings tabs, the New project sheet's Goal and Spaces positions, Resolved with its Reopen
   footer, and the Paused-with-question board (the paused-waiting fix has landed; it has not been rendered).
6. **Automation triggers** are not claimed: the UI shows owner rows and the enable switch only.

## Slice 7: producers wired, and the gap list at this checkpoint

Wired over the merged producers (nothing typed in, nothing from a title or prose):

- **Files tab** (`files.v1`): one owner directory at a time, a folder opens the next, "Back" returns, a file previews as data (text, PNG or
  JPEG) under the list. The owner's own refusals are said in words (too large, unsupported, old host, disconnected), a truncated list says
  it is not the whole folder, and nothing is opened, launched or revealed on this Mac. No provenance is drawn (`taskID` is nil).
- **Typed task and Space cards**: `NativeActivityCall.projectAction` carries the owner's identifiers. In a Project conversation the card is
  drawn inline where the tool result sits, resolved against the CURRENT Project (`ProjectActionResolver`): another Project's reference, a
  gone task and a consumed proposal draw nothing. A pending proposal with no inline card is offered above the composer, never twice.
- **Worker threads through the owner**: the pane, the question card and the worker thread all read `ProjectRuntimeTransport.worker`, keyed by
  Project and task, never by agent. Tested end to end against a real owner with no other host connected.
- **Images**: the paperclip, paste and drop ask the Project's owner (`projectCarriesImages`), not the coordinator's thread, so they exist
  before the first message; an image alone is a first message; `sendMessage` carries images and clears only what it submitted.
- **Held messages**: a message the owner accepted but the transcript has not taken in (queued while paused, sending, unconfirmed, failed) is
  drawn as the thread's own pending bubble with one note in the thread's own style. It leaves when the transcript holds its operation id or
  the owner's native delivery id. Unknown and failed are never retried for the person; sending the same words again is the explicit retry.
- **New thread** offers a host when the Project allows more than its owner, from the owner's own host list; the host rides the `assign`.
- **Nav**: New thread, Designs, Automations; More removed (palette opens Hosts, Design systems, Extensions).

**Still open (named, not "later"):**

1. **Run elsewhere (board 10) is not built.** The board's two moves ("Push the branch and continue there", "Start over there") need an owner
   request that does not exist: the protocol has `assign(host:)` only for a NEW task, nothing that relocates a running one or pushes its
   branch. The host list under it is real (`ProjectHostChoices`), macOS only.
2. **Task plan card in the worker pane** ("Building the storefront and checkout mockup / Publish it to the project's files") comes from the
   worker's own native plan producer; the stub engine emits none, so it is not rendered.
3. **Fixture history**: the full-window renders still show the stub's stock "Dec 3 / Hello!" history and "Running · ls". A Project-specific
   StubPi fixture with current timestamps and real tool outputs is not added, so structural comparison to the board's conversation (three
   task cards, "Starting threads") is not yet shown in the Started render; the card path is covered by the control test instead.
4. **Not re-rendered or compared against the original HTML this pass**: Resolved with its Reopen footer, EmptyV2, Paused with a waiting
   question, and the Settings pages (owned by the Settings engineer).
5. **Failures not proven mine**: `ControlMotionTests.settingsCrossFadesInAndOutHoweverItOpens` and
   `NewThreadDesignTests.aDesignAttachedOnTheNewThreadPageStartsTheThreadWithItsFence` fail when run alone on this tree. I changed neither
   area (my `ThreadTurns` edit is the cards field only) but did not run them on the baseline.
6. **Known**: the 22pt compact-row hit area, and `aMultilineSendIntoAThreadOfTallRowsEndsOnItsTail`, both existing.
