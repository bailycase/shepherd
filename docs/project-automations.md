# Project-owned automation settings

This slice associates the existing saved `Automation` with a logical `Project`, not a Space.
It adds host-owned settings, not a scheduler, cron format, event listener, billing UI or engine
change. **Project-owned execution is unavailable until the owner runtime admission adapter is
installed and validated.** No automation execution adapter is installed. Owner-to-executor task
placement is implemented separately (`project-execution.md`), but does not turn prompt metadata
into a schedule.

## Owner API and compatibility

`Automation.projectID: ProjectID?` defaults to nil and older JSON decodes unscoped. Existing
projectless automation startup, editing and run history remain unchanged. `RemoteAutomationDraft`
is unchanged, so an older viewer cannot silently replace the association with an omitted field.
Legacy create/update/delete/run/stop requests refuse scoped records with `project_scope` and
direct the caller to Project controls. History remains readable through the existing runs API.
Bulk `putState` cannot replace Project-owned automation metadata. The shared local Stop entry
also checks canonical owner state before cancelling or deleting a watcher: a stale sidebar row
cannot bypass Project revisions. It reports a normal action error and leaves the scoped run intact;
owner-service pause/delete cleanup remains independent of that unscoped convenience.

Local and remote settings use the same owner service:

```swift
LogicalProjectsRequest.automation(
    projectID: ProjectID,
    expectedRevision: UInt64,
    automationID: AutomationID,
    action: ProjectAutomationAction
)
```

Actions: `.create(draft:)`, `.update(draft:)`, `.setEnabled(Bool)`, `.link`, `.delete`.
A successful action returns `.project(Project)` with the next revision and broadcasts the
committed automation state. It uses the existing staged Project transaction, workspace-version
and lifecycle fences. A stale action returns `stale_project` without changing either record;
keep the user's draft, refresh, and require an explicit retry rather than substituting a revision.
A new create ID that already exists is a conflict, not an overwrite.

Remote clients require both `logicalProjects.v1` and **`logicalProjectAutomations.v1`**. The
client refuses before sending to an old host (`update_required`); the listener independently
refuses when the latter capability is absent (`unsupported`). No new remote run/stop operation
is advertised. The capability advertises settings, never execution support.

Create validates the existing Project, automation name/prompt and actual owner directory using
the existing automation validator. Link accepts only a stopped, unscoped existing automation.
An ordinary launch holds a server-side fence until its async creation finishes, so a link cannot
race that launch. Cross-Project updates, deletes and links refuse with `project_scope`. Linking
is not moving or detaching. User/owner settings are the only callers; no model-facing extension
tool was added. A future model-facing entry must authenticate its coordinator's own Project
before invoking this service; a model-supplied Project ID is not authority.

Settings are bounded to **64 automation records and 512 KiB per Project**, also subject to the
existing complete-workspace remote frame limit. These are storage limits, not a spending policy.
Ordinary records do not count against that per-Project bound.

## Pause, delete, restart

Create, link, enable and explicit Resume never implicitly launch watchers. App startup skips
all Project-owned automations, even enabled ones; the Project startup policy restores paused.
Removing a Project removes its associated automation records. Pausing, disabling, or deleting
an automation removes its current ephemeral watcher metadata and terminates its process using
the existing session shutdown path. Only agents in the reserved hidden Automations Space are
watchers for this cleanup: ordinary task threads, worktrees, branches and artifacts remain.
Run-history status follows the existing real run log; deleting an automation drops its history
as ordinary automation deletion already does.

Cleanup is applied before ordinary state commits, staged settings commits, and staged owner
runtime transactions (including `projectRuntime(.pause)` through the installed controller); it
requires no edits to `ProjectCoordinatorController` or `SessionServer+ProjectRuntime`. It does
not free ProjectTask reservations just because watcher metadata disappeared.

## Unresolved trigger policy — execution remains disabled

The existing record stores a prompt and enabled flag, not a Monday schedule or PR subscription.
The outstanding product choice is whether Project automations gain real structured schedule/event
triggers, or retain the existing prompt-driven watcher semantics. Neither choice authorizes
replacing enabled automations with one-shot tasks. Existing settings rows/toggles persist metadata
and guards; they do not prove a working scheduler. Enable, explicit Resume and app restart
therefore launch no scoped watcher until that choice and the bounded adapter are implemented.
No timer framework, fake trigger copy or unscoped launcher bypass was added to bridge this gap.

The common Project admission now counts local and remote task reservations together and can be
reused after this decision. A real adapter still needs linked Space/cwd validation, scoped
watcher/run identity, all asynchronous revocation fences, and full-slot/Pause/restart checks.

## Required execution adapter (not installed)

The explicit owner API is:

```swift
func runProjectAutomation(projectID: ProjectID, expectedRevision: UInt64,
                          automationID: AutomationID) async throws -> ProjectTaskID

var onProjectAutomationRun:
    (@Sendable (ProjectID, UInt64, AutomationID,
                @escaping @Sendable (Result<ProjectTaskID, Error>) -> Void) -> Void)?
```

The callback runs on the SessionServer owner queue. The entry verifies started state, Project
revision, enabled/owned record, and active Project with no interruption pending. Missing adapter
returns `unsupported`, with no run created. After callback completion it rechecks lifecycle,
active/enabled association and that the returned task exists in the Project. Callback success
means admission, not proof of task success. Legacy VM `startAutomation` never routes scoped
records to the ordinary prompt-at-launch path.

Before installing the adapter, the runtime owner must:

1. Reserve an activation and slot in the **existing ProjectTask ledger**, not another counter,
   before any asynchronous launch stage. Apply the same Project threads-at-once/time/activation
   limits as ordinary coordinated work; queueing is the existing runtime's responsibility.
2. Resolve the approved watcher representation (the existing hidden Automations Space pattern
   versus linked-Space task workers) without guessing trigger semantics. Launch idle with the
   reserved worker identity and validate the explicitly linked execution Space/cwd.
   Recheck ownership, record identity/configuration, enabled state, Project lifecycle/pause and
   reservation after every asynchronous stage and immediately before native prompt delivery.
   Atomically publish the automation's `agentID` through the owner queue, not legacy
   `updateAutomation`, which intentionally refuses scoped records.
3. Cancel pending starts on pause/delete/disable, and handle failed launch, acknowledged
   settlement and unknown outcomes in that ledger. Never free a slot merely on disconnect,
   metadata removal, a viewer retry or model prose. Never replay an unknown send automatically.
4. Retain the reserved agent/session identity for interruption/exit acknowledgements. The
   existing `sessionDidExit` lookup cannot recover an agent from a tab removed by watcher cleanup;
   missing acknowledgement must retain unknown occupancy rather than allowing a side channel.
5. Test real delayed StubPi boot/publication/native-send races, owner shutdown, full slots,
   stale configuration, Stop/queue/retry/compaction and acknowledged interruption before enabling
   runs. The tests in this slice exercise fail-closed entry and late callback rejection, not a
   complete working launch adapter.

## Plain data for Project settings

Filter `state.automations` by `projectID`. `ProjectAutomationSnapshot.rows(projectID:host:runs:)`
provides the actual Automation (`name`, `enabled`, `prompt`, `cwd`), owner ID/name and newest real
`AutomationRun` (`result`, `startedAt`, `settledAt`, `endedAt`). No history supplied means nil,
not a fake success. The existing `AutomationPresentation` remains available for formatting;
generic scoped rows say "By explicit Project action" and direct changes to Project settings.

**Data limitation:** these records store no weekday, time-of-day, cron expression, pull-request
trigger or event subscription. The board's example Monday schedule and PR-trigger semantics
cannot be derived from this runtime. Show the stored prompt and actual run metadata instead of
inventing secondary copy. No UI view or control is implemented in this slice.

## Validation and risk review

Scratch-server TCP tests cover scoped CRUD, stale toggles, cross-Project refusal, legacy update
association preservation, link/start fencing, persistence, restart, missing admission adapter,
late admission completion after pause/delete, capability refusal and storage-bound rejection.
Real StubPi process tests cover pause/delete/disable cleanup and preservation of ordinary worker
metadata/artifacts. AppHarness verifies startup skips scoped records and legacy launch cannot
bypass admission. A live StubPi AppHarness regression also invokes sidebar Stop with a deliberately
stale unscoped view-model copy and verifies the process, agent, association and Project revision
are preserved with a clear refusal. Its 14-test focused rerun, including ordinary Stop and
owner-service cleanup, passes. Protocol checks cover old decoding and every scoped action; presentation
checks derive owner/prompt/latest-run data from the actual producer. The focused run passed
142 Swift test functions across the new suites and affected automation, Project runtime,
state-store/validation and protocol suites, plus 14 documentation checks. Tests used isolated
scratch hosts/StubPi only. The checkout's local SwiftPM Sparkle framework link was required for
bundle discovery; no installed application or user support directory was changed.

Autonomous-work review: no new model call, provider transfer, evaluator, retry loop or scheduler
is enabled; execution is fail-closed. Settings fences and startup pause are enforced. Full
execution-bound and interaction validation remains the adapter owner's integration requirement,
not a completed scheduling feature. No dependency, Linux runtime or billing/budget UI was added.
