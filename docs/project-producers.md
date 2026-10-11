# Project artifact and conversation producers

Files and conversation are owner-host data APIs. Workers publish explicit artifact snapshots;
viewers request inert previews. Human image submissions store private input blobs and use the
existing explicitly requested coordinator turn. These APIs add no provider/classifier calls,
folder synchronization, Space copying, migration, or artifact deletion.

## Files: owner-relative, read-only previews

Local callers use `SessionServer.logicalProjects`; remote callers use
`RemoteHostClient.logicalProjects` with the **Project owner's existing host binding**:

- `.files(projectID: id, path: "")` lists the private Project root. A subdirectory uses its
  `relativePath` verbatim. Result: `.files(LogicalProjectFileListing)` with `projectID`, `path`
  (the requested parent-relative directory, never an absolute owner path), `entries`, `truncated`.
- Each `LogicalProjectFileEntry` has `name`, `relativePath`, `kind` (`file` / `folder`), `size`
  (bytes, `Int64`), `modifiedAt` (milliseconds since epoch), and optional `taskID`. `taskID` comes
  only from a ready publication receipt whose private commit manifest, file identity, size and
  SHA-256 still match. Unpublished or replaced files have nil provenance; filenames and times
  never identify a task.
- `.read(projectID: id, path: entry.relativePath)` returns `.file(LogicalProjectFile)` with
  `projectID`, `relativePath`, `mimeType`, and `data: Data` (base64 on the wire). Supported MIME
  types are `text/plain; charset=utf-8`, `image/png`, and `image/jpeg`. Text must be valid UTF-8
  without binary control characters; images are recognized by their signatures. Malformed image
  data may fail a viewer's decoder: show unavailable rather than execute or launch anything.
- Preview the bytes as data. Never use `NSWorkspace` to open an owner's path on the viewer, launch
  a `.command` / application, execute content, or render text as active HTML. Folder rows request
  another single directory. Text can be decoded with `String(data: file.data, encoding: .utf8)`.

`logicalProjects.files.v1` gates both requests independently of `logicalProjects.v1`.
`RemoteHostClient` refuses an old host with `update_required` before sending; the listener refuses
unadvertised file operations with `unsupported`. Older ordinary Project requests are unchanged.
These are host APIs, not iOS hosting capabilities; the mobile fixture does not advertise them.

The filesystem is `<owner state parent>/logical-projects/<ProjectID>/`, created at Project creation
by `LogicalProjectDirectory`, mode 0700, effective-user-owned. It is also the coordinator's cwd;
coordinator tools are typed Project operations, not arbitrary file commands. No linked Space is
searched or copied. Hidden components (including `.pi`), `logs`, `sessions`, `auth.json`,
`settings.json`, `.log` and `.jsonl` files are not artifacts; direct reads reject them too. This is
an artifact surface, not a session/configuration browser. Other files placed in this private
Project root are explicitly available to the owner's authenticated Project viewers.

Paths are at most 1024 UTF-8 bytes, components at most 255; absolute, empty interior, `.`, `..`,
NUL and unpublished components are rejected. The trusted state parent is canonicalized once;
all private-root and artifact traversal uses pinned descriptors, `openat` with `O_NOFOLLOW`,
`fstat` type/device checks, and `fstatat(..., AT_SYMLINK_NOFOLLOW)` for listing metadata. No
validate-URL-then-read gap exists. Symlinks, mount crossings, nonregular files and multiply linked
files cannot be read. Nonblocking opens prevent a substituted FIFO from hanging the file queue.

Each listing scans at most 4096 directory entries, returns at most 256 entries, and accounts for
worst-case JSON escaping within a 512 KiB entry budget. It is not recursive or a complete tree;
`truncated` means the viewer must not present it as complete. A read checks `fstat` first, then
reads at most 256 KiB + one overflow byte; oversized/growing files return `file_too_large`, not
partial or huge content. Unsupported binary content returns `unsupported_file`. Base64 encoding
keeps the bounded response comfortably below the 1 MiB TCP frame limit. Permission/path/type
failures produce explicit errors, not empty successful content.

Listing and preview file I/O runs on `logicalProjectFiles`, never the server state queue. At most
eight artifact requests can be pending. Before delivering bytes, the server rechecks started state, lifecycle
epoch and the same Project record: restart, edit or deletion invalidates the result. Retained
files of a deleted Project are not reachable through this API and are never adopted on ID reuse.

## Conversation: human image submissions

The composer uses `LogicalProjectsModel.sendMessage(_ ref:text:images:)`, where `images` defaults
to an empty `[NativeImage]`. Its owner request is
`ProjectRuntimeRequest.message(operationID:text:images:)`; optional `images` defaults to nil in
both old JSON and source calls. Image-only first messages are accepted. The caller must retain
its draft and attachments on refusal and clear only the acknowledged submission. Operation
identity covers the entire submission, not just its text: a retry reuses it, replacing an image
must create a new identity.

The ordinary native image contract is unchanged: at most four images, 2 MiB each, 5 MiB total,
with `image/` MIME types. Project metadata additionally bounds MIME strings to 256 UTF-8 bytes
and clips optional display names to 256 characters (validated within 1024 UTF-8 bytes). The
existing app-entry downsampling owns source preparation; this producer never rewrites a source
file. The remote client requires `logicalProjectRuntime.images.v1` before sending images and
preflights the entire request against the ordinary 1 MiB frame limit. Too-large remote requests
fail **before transmission** with the existing images-too-large message. There is no chunked
upload, terminal upload reuse, or viewer-local path. Older hosts still accept text-only requests.

`ProjectMessage.images: [ProjectInputImage]?` stores only UUID `id`, `mimeType`, optional `name`,
and `byteCount`; missing fields decode as nil on old messages. Bytes do not enter workspace JSON,
Project settings snapshots, or the 512 KiB Project collection. The owner stores them under its
private root as `.inputs/<submission UUID>/<image UUID>`. Image IDs are SHA-256-derived from
submission UUID and image index. Files are 0600, directories 0700, descriptors owned by the
effective user. Files use no-follow descriptor-relative opens, same-device/type/link-count
checks and bounded reads; symlink/FIFO/hardlink substitutions are refused. Staged writes are
fsynced and linked into place without overwriting an existing identity. Existing bytes must
match on a pre-acceptance retry. No automatic orphan cleanup or background publisher exists.

All input filesystem work is off the server state queue, with at most eight pending storage
requests. Validate count/type/size/text before writing, durably store every image **before**
accepting the message, then revision/lifecycle-fence the receipt. A disk or receipt-write failure
refuses the submission and never sends its text alone. Already accepted duplicate operations
return their prior receipt without copying blobs or prompting again. A failed receipt write may
leave private blobs for a retry with the same immutable identities.

Paused submissions remain durable queued receipts. Explicit Resume reloads those exact blobs
and uses the existing `NativeThreadRequest.send(images:)` pipeline, checking Project admission,
message phase, lifecycle epoch, coordinator identity and native session/generation again after
I/O. Missing/unsafe blobs mark delivery failed and stop the run, never fall back to text-only.
A definite cancelled-before-send submission stays queued; unknown accepted consumption stays
unknown and is never replayed. Restart still pauses; neither queued nor unknown images resume
unattended. Native preparation, Pause and other revocation fences remain in force.

Input blobs are not artifacts: `.inputs` is inaccessible to Files listing/read. Model-facing
`project_read` excludes human message payloads; inspect only returns task-source receipts, which
cannot contain these images. The images go only to the explicitly selected coordinator provider
on the Project owner through its ordinary native prompt, never a different worker/provider.

## Worker publication

`project_publish(sourcePath, artifactName)` is an authenticated worker-only extension tool.
`sourcePath` is relative to the **actual native worker process cwd** (including its assigned
worktree), and `artifactName` is one safe filename. The tool derives a stable publication UUID
from the tool-call identity. Its `ProjectPublicationRequest.publish` carries no Project, task,
session, generation, owner or executor IDs. Ordinary threads and coordinators cannot publish.
The extension registers it only for a host-bound worker role, never a coordinator or unbound
ordinary thread. Pi freezes its first-turn tools before native user consumption, so registration
cannot wait for that evidence: a pinned-engine/local-provider regression proves this ordering.
Registration grants no authority. Every execution revalidates the consumed native scope; a later
manual turn in a worker process may still see the tool but receives `publication_scope` refusal.
`ProjectPublicationRequest.eligibility` reports the current native authorization without reading
a source.

`SessionServer.publicationAuthority` uses the child-control lane's consumed-operation
`currentProjectChildScope` and `projectChildClosed`, the bound native process, session and
generation, and the current active task/execution. A started-agent set or model context is not
proof. Pause, stop, deletion, manual takeover and replaced native sessions revoke publication.
Child continuations use that same native scope, not a second publication scope protocol.

The public producer is `Project.artifacts: [ProjectArtifactReceipt]` (old records decode as `[]`).
Receipts contain `id`, `key` (owner/Project/operation), `taskID`, `workerAgentID`, `sessionID`,
`generation`, `artifactName`, owner-relative `relativePath`, byte `size`, `sha256`, hashed
`sourceIdentity`, and `state` (`staged`, `ready`, or `refused`). A definite commit refusal
retains a bounded public `refusal` code; reconnect does not retry name collisions. An owner's remote receipt also retains the
exact `executor` host/binding reference. These receipts survive task follow-ups independently
of immutable execution-assignment snapshots. Public receipts contain no bytes, absolute source
or staging paths, credentials, or assignment prompt/context.

Source traversal is descriptor-relative and nonblocking; hidden/configuration/authentication
paths, traversal, symlinks, hardlinks, mount crossings and special files refuse. Trusted runtime,
application and home-configuration roots refuse too. Source size, modification and change times
are rechecked after a finite read. Existing `NativeRedaction.projectData` patterns detect known
secret-bearing text: detection **refuses** publication rather than modifying the artifact.
This is not a claim to detect arbitrary image-encoded, renamed or obfuscated secrets.

Snapshots use private descriptor-open `<state parent>/project-publications/<UUID>/` staging.
Retained lookup never allocates directories: only an absent identity returns no snapshot; an
existing empty, incomplete or malformed store refuses. Source validation and secret-text checks
precede allocation, so rejected sources do not consume the host's 128-identity ledger.
Bytes and immutable manifests are fsynced. Same-ID retries must match original source identity,
name and provenance; an incomplete snapshot with no receipt has an unknown outcome and is not
silently repeated. Local publication and remote owner pulls share one commit path: prepare and
hash pinned descriptors off the state queue, then recheck exact authority and perform
`renameatx_np(RENAME_EXCL)` in one state-queue turn, with no async gap. Pinned parent/name inode
checks and native vnode dirty-event checks refuse changed preparation; the exclusive rename
never overwrites a collision. Descriptor ownership spans both queues without cross-queue sync.
Post-rename digest verification, fsync and private ready-receipt writes remain off the state
queue. If Pause or another revocation wins, no public file is created; hidden staging may remain.
If rename wins, subsequent revocation can prevent acknowledgement, not undo the committed file.
Recovery
checks the recorded inode/device and digest, not merely same-name/same-content coincidence.
On restart, a retained staged Project receipt is promoted only when an already committed file
matches its fsynced provenance manifest and original inode and staging no longer holds the bytes.
This also proves a crash between rename and ready-metadata write; merely staged bytes are not committed and no worker
source is reopened. The tool says `published` only after ready Project metadata persists; executors say
`staged; waiting for owner`. Neither status implies task success or resolution.

### Existing owner/executor connection

`ProjectExecutionReceipt.publications` retains immutable executor-produced receipts. The existing
`projectExecutionChanged` hint wakes owner reconciliation. The owner uses its exact existing
placement binding to request
`ProjectExecutionRequest.publicationRead(key:publicationID:offset:)`; the reply's optional
`ProjectExecutionResult.publication: ProjectPublicationChunk` carries that ID, offset and bytes.
A network publication-read request cannot select a source path. The owner checks the original
receipt, offsets, size and digest, then stages and commits through the same no-overwrite path.
A worker can settle with the owner offline. Same-lifetime reconnect pulls retained results only
while the owner run remains authorized and unpaused; it never resumes worker execution.
Restart clears that run authorization: reconnect can reconcile receipts and verify already
committed inodes, but cannot pull or commit merely staged bytes. Explicit owner Resume authorizes
retained outputs, including those of settled workers. Transfers capture the exact run token,
lifecycle epoch and executor binding, so Pause followed by Resume cannot revive an old in-flight
commit. Deleted Projects and replaced/offline bindings refuse; a different binding is not a fallback.

`logicalProjects.publications.v1` gates publication reads and publication-enabled assignments
on both listener and client. New owner assignments set `publicationsEnabled`; an old executor
refuses with `update_required` rather than ignoring output requirements. Legacy assignments
without this optional flag still execute, but their workers cannot publish to an incapable owner.

Default bounds: 32 MiB/file, 256 KiB/chunk (base64 safely below the 1 MiB frame), 32 receipts and
256 MiB per Project/execution collection, 64 KiB encoded receipt metadata, 128 private snapshot
identities and 256 MiB retained staging bytes per host, four pending publications and four owner
transfers (128 bounded waiting transfer identities), and a 120-second transfer deadline. Full ledgers refuse; there is no eviction or
cleanup service. Hashing, manifest encoding, fsync and deadline-bounded disk loops run off the
state queue. Only bounded descriptor checks and the exclusive rename share the final exact
scope/run/owner/binding check on the state queue; metadata persistence rechecks those fences. Deleted Projects retain their files; this does
not add a deletion policy, export approval, or UI.

## Conversation: typed action references

`NativeThreadMessage.projectAction: NativeProjectAction?` is optional display metadata:

```
projectID: ProjectID
revision: UInt64
operationID: UUID
taskID: ProjectTaskID?
proposalID: UUID?
```

Exactly one of `taskID` / `proposalID` is populated. Existing native `operationID` still means a
user-send UUID and is not repurposed. Old native payloads without `projectAction` decode as nil;
malformed optional references also become nil without breaking the transcript.

The canonical `shepherd-project-context.ts` returns its usual full Project JSON text unchanged.
Its bounded details add explicit operation identity only when the actual returned Project has a
unique matching receipt:

- `project_assign` / `project_follow_up`: match `task.operationID` or `previousOperations`.
- `project_resolve`: match the explicit task ID and its `resolutionOperations` receipt.
- `project_propose_space`: match `spaceProposal.operationID`.
- `project_read`, inspect, remember, errors, missing/ambiguous receipts: no action identity.

The existing stable SHA-derived operation UUID and idempotency behavior are unchanged. No title,
prose, filename, timing or tool argument is interpreted as a task identity. The embedded Swift
literal is synchronized from the canonical extension.

RPC decoding allowlists the action tool names and retains only bounded validated identifiers and
revision. It verifies those details against the returned Project JSON receipt (at most 1 MiB),
at the RPC decode boundary so large replies are parsed off the state queue. Both live
`tool_execution_end` and settled `get_messages`/replay use this path. Native text/arguments stay
unchanged for ordinary tools and editing/retry; opaque details and arbitrary private keys never
enter the native projection.

The reference is **not authorization**. Before drawing a card, the UI must resolve its Project
and task/proposal in the current owner-host context and check that they still exist. Mutation
requests retain all existing owner, identity and expected-revision checks. A stale card must not
resurrect a task or route through another host because its UUID happens to match.

## Worker turn plans

`project_plan` is registered statically beside `project_publish` only for a bound worker,
so Pi's frozen first-turn tool list includes it. Coordinators retain their typed whitelist.
The pure tool accepts a full ordered `steps` array: 1–20 entries, each with nonblank `text`
(up to 500 UTF-16 code units) and explicit `state`: `pending`, `current`, `done`, or `failed`.
Invalid/oversized input returns a tool error. Success returns one persisted text block:
`{"version":1,"steps":[{"text":"Build the storefront","state":"current"}]}`.
It performs no IO, owner request, model call or mutation; a later manual turn in an old worker
can report an ordinary native plan without acquiring Project authority.

`NativeProjectPlan` in ShepherdRemote parses only complete successful `project_plan` v1
results, with bounded text and step counts. `NativeActivityCall.projectPlan` exposes ordered
steps redacted with `NativeRedaction.projectData`. Each actual valid call stays a standalone
activity burst for the UI's steps card; updates never erase historical calls.
`NativeTurnPresentation.latestProjectPlan` is the latest valid explicit report in that turn's
transcript order. No previous turn's plan carries forward. Stop, error, settlement, assistant
prose, shell output and filenames never manufacture steps or change reported states. `done`
is the worker's claim, not admission, settlement or publication evidence.

Pi's existing tool-result history and native codecs retain the report across reload; no new
wire field or database is involved. Plan rows alone have a 128 KiB combined arguments/result
projection allowance (JSON escaping can exceed ordinary rows' 16 KiB); single results are
parsed only up to 65,536 bytes. Invalid, clipped, errored, unknown-version or unrelated output
keeps the generic tool fallback and unchanged raw history. Existing snapshot budgets still apply.

`project-context.test.mjs` loads the canonical extension with the pinned SDK and checks its
real output against `project-plan-results.json`; the Swift projection tests consume that same
fixture through RPC history and native presentation. `NativeProjectPlanTests` covers update
order, turn boundaries, bounds, false prose, errors and redaction. `project-plan-engine.test.mjs`
checks first-turn registration, actual persisted Pi output and session restoration using a
scratch home and loopback fake provider only; restoring history makes no model call.

## Focused verification

`ProjectPublicationTests` uses ScratchServer/StubPi and authenticated two-host TCP: real local
publish/list/read and exact task provenance; immutable duplicate/collision behavior; ordinary
and coordinator refusal; traversal/link/FIFO/secret/oversize and post-fstat growth attacks;
failed state persistence with same-ID snapshot recovery; held-I/O pause, manual takeover,
delete, restart and session replacement; ready-receipt crash-window recovery without work
resume; offline worker settlement followed by owner pull only after explicit post-restart Resume;
transfer deadline, remote collision, changed binding and old capability refusal.
`ProjectPublicationCommitTests` holds a deterministic barrier after preparation hashing and before
the final rename: local Pause/takeover/delete/restart/session replacement and owner
Pause/delete/restart/binding replacement/new-run fences leave no public file. It also checks
dirty bytes, swapped directories, inode/link/collision attacks, more than 128 rejected sources
followed by a valid publication, incomplete/corrupt-store refusal and real retained-ledger capacity. `ProjectPublicationWireTests` checks old records,
all new envelope shapes, SHA/identity/count/aggregate bounds and full-size chunk frame budgets.
The canonical Node test checks retry identity and honest staged/native-refusal output.
`project-publication-engine.test.mjs` runs the pinned engine against a scratch local provider
and extension socket: before-agent/turn-start authorization is too early, and even user-end
registration misses the frozen first-turn tools. Worker-role registration makes the first
assigned turn able to publish; the server integration tests independently prove execute-time
native authorization. No real provider or user support paths are involved.

`LogicalProjectFilesTests` exercises actual ScratchServer files, metadata and nil provenance,
traversal/symlink/hardlink/FIFO refusal, hidden internal data, size/binary/entry limits, TCP owner
bytes versus a separate viewer root, old-host refusal, and pending-read restart/edit/delete gaps.
`NativeProjectActionTests` feeds a real server assignment receipt through StubPi's live result,
settled history, TCP reconnect and fresh-process history replay. Projection/wire tests cover
malformed, unknown and old payloads; Node extension tests check returned server identities rather
than arguments. `ProjectMessageImagesTests` covers actual StubPi bytes/MIME for image-only and
mixed first messages, durable paused/restarted submissions, Pause during native preparation,
unknown-consumption non-replay, failed receipt writes, missing/unsafe blobs, five-MiB local input,
remote frame/capability/auth/owner refusal and old JSON defaults. No real provider, user pi home or application support directory is involved.
