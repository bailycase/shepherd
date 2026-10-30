# Project-owned automation settings

This slice associates the existing saved `Automation` with a logical `Project`, not a Space.
Project-owned automations carry the same triggers as any other ([data-flow](data-flow.md#automation-triggers)):
a schedule or GitHub events fire a run, and that run is a **Project task** admitted through the
Project runtime's own `assign` (below). A manual Project automation still never runs on its own.

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

## Triggers and execution

The trigger question is decided: Project automations gain the structured schedule and GitHub
triggers every automation has, set through the draft's `settings` on `.create`/`.update` (a nil
`settings` keeps them). A Project run can't go to an existing thread (`invalid_automation`).

When a trigger fires, the app's trigger host calls `runProjectAutomation(projectID:expectedRevision:automationID:title:prompt:)`
with the server's current revision. The entry keeps every check it had (started, Projects on,
revision, not paused or interrupting, owned and enabled record), then calls the installed
`onProjectAutomationRun`, which performs `ProjectRuntimeRequest.assign` with a fresh operation id
in the Project's linked local Space that holds the automation's folder, and the automation's
model and thinking pins. That is the existing ProjectTask ledger: the reservation, the Project's
threads-at-once, time and activation limits, queueing, pause and revocation fences, and the
worker launch are the runtime's, unchanged, and a repeated operation id is the same task. After
the callback the entry rechecks lifecycle, association and that the task exists, as before.

The prompt is bounded to 15 KiB for the runtime's 16 KiB native input limit (event text is cut,
and says so). While the Project is paused or interrupting, Projects are off, the Project is gone
or no linked Space holds the automation's folder, the trigger keeps queueing events but starts
nothing, and its status says why (`AutomationTriggers.Host.holdReason`). Runs per day and runs at once
are the automation's own limits, and the Project's threads-at-once applies on top. Each run also
opens in the automation's run log under the task's reserved worker and follows the task's phase
(queued or working: running; waiting: asked you; settled or resolved: finished; failed: failed). Create, link, enable and Resume still launch
nothing by themselves, and app startup still starts no Project-owned watcher.

## Plain data for Project settings

Filter `state.automations` by `projectID`. `ProjectAutomationSnapshot.rows(projectID:host:runs:)`
provides the actual Automation (`name`, `enabled`, `prompt`, `cwd`), owner ID/name and newest real
`AutomationRun` (`result`, `startedAt`, `settledAt`, `endedAt`). No history supplied means nil,
not a fake success. The existing `AutomationPresentation` remains available for formatting;
generic scoped rows say "By explicit Project action" and direct changes to Project settings.

Each automation's `trigger` holds its schedule (an RRULE) or GitHub triggers; show those, the stored
prompt and actual run metadata rather than inventing secondary copy.

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

`ProjectAutomationTriggerTests` (AppHarness) cover a firing becoming a Project task in the linked
Space with the fenced event in its prompt, waiting while the Project is paused, the refusal of a
thread destination, and the prompt bound. The trigger engine's own bounds are covered in
`AutomationTriggersTests`.

Autonomous-work review: a triggered Project automation starts unattended model work, bounded by
its runs-per-day limit, the Project's threads-at-once and the trigger engine's bounds; it waits
while its Project is paused and never starts a manual watcher at launch. No dependency, Linux
runtime or billing/budget UI was added.
