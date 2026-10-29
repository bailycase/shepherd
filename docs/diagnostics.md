# Crash and performance diagnostics

Shepherd's macOS app can send opt-in crash and performance diagnostics to Sentry. Settings > Advanced >
Diagnostics > Share diagnostics is off by default. The existing `shareDiagnostics` preference covers both;
there is no second switch, and existing opt-ins remain opted in. A build without a valid hosted Sentry
DSN cannot enable reporting. The iOS client reports differently: see [iOS](#ios).

## What is sent

The app sends native crash stacks, image UUIDs and addresses for symbolication, app release,
OS version, hardware class and memory fields supplied by the SDK. Fixed breadcrumbs record
app startup, selecting a local thread and process exits, with numeric exit codes. Agent-start
failures send a fixed error code, the existing allowlisted startup problem kind and its inferred stage
(preflight, launch, initialization, resume, or unknown). Local pane starts also record their trigger
(restore, recovery, demand, retry, or unknown) and whether the launch cwd matches the space, recorded
worktree, or neither; no paths are sent. Unknown or absent context is not inferred from a session ID.
Random installation and run UUIDs permit correlation; they
are not account, device serial, agent or project identifiers.

`Sources/ShepherdApp/ShepherdDiagnostics.swift` is the only production file that imports
Sentry. Its single app-owned instance exposes active state to Settings and accepts scratch
storage and a URLSession configuration for isolated runtime tests. Callers use Shepherd-owned
enums and numbers. Do not pass arbitrary errors or logs to
it. The pre-send filter reconstructs the event and drops exception messages, unknown exception
names, user information, requests, extra fields, thread names, registers, source lines and
absolute binary paths. It retains symbols and image metadata needed for symbolication. Swift async
stack traces are enabled so native crash evidence can include async callers. Before dropping exception
reasons, the filter recognizes only fixed assertion categories (continuation misuse, duplicate key,
index out of range, unexpected nil, missing embedded extension resource, precondition); unknown reasons
produce no category. Crash reports also label the captured stack as missing, single-frame,
multi-frame or truncated, and the exception reason as unavailable, unclassified or classified.
These describe available evidence, not proof that a stack contains every caller, and do not diagnose
or fix the underlying crash.

Performance reporting adds explicit, fixed-name transactions for agent start/stop/turns, model responses,
history refresh, compaction and tool categories (`read`, `bash`, `write`, `edit`, `mcp`, `other`). These
record completed durations with reconstructed start timestamps, not prompts, tool names or arguments.
Resource transactions carry numeric measurements, and the latest ten numeric samples accompany errors
and crashes through the sanitized scope. Dedicated Sentry metrics also record resource gauges,
operation-duration distributions and lifecycle/outcome counters. Duration metrics have their own budget
and do not depend on a trace being sampled. Fixed structured logs identify app startup, process exits,
agent-start failures, model failures/retries, tool failures, extension failures and compaction failures.
They contain no error messages, tool names or raw application/agent logs. Failure logs and breadcrumbs add
bounded provider-error categories and tool kinds; startup reports and logs add startup kind/stage. Categories
reuse the thread's provider-error classifier; unrecognized errors and tool failures use `other`. A generic
startup exit has `unknown` stage rather than guessing. Logs and metrics otherwise retain only app-owned
release, environment, random installation/run IDs and numeric exit codes. One-use emission
receipts reject arbitrary SDK calls, even if they reuse our public event names.
Memory-pressure notifications and observed orphan processes
produce fixed, rate-limited anomaly reports. App hangs lasting at least five seconds use the same sanitized
stack filter and error budget; macOS hang detection cannot distinguish fully blocked from partially blocked
UI and can produce false positives. MetricKit supplies system CPU, disk-write and hang diagnostics
through the same stack scrubber; raw MetricKit attachments stay disabled. Release health tracks native
app sessions and their crash/error outcomes using the SDK's random installation/session IDs, release
and environment. These sessions are not agent conversations. Native stacks and profiles do not inspect
Pi's JavaScript heap or subprocess stacks.

The census records app RSS and physical footprint separately; Pi, terminal, generic descendant and observed
orphan counts/RSS; cumulative CPU seconds; active/idle/total sessions; RPC buffer bytes; transcript row counts;
physical memory, memory pressure and scan-quality counters. Summed RSS may double-count shared pages and
is not physical footprint. CPU seconds are cumulative, not CPU percent. Descendants are not presumed MCP
servers. An orphan means an owned descendant observed before its owner disappeared; a 60-second census can
miss short-lived owners/launchers and does not establish that a process is safe to kill. Native process scanning
reads no names, paths, argv or environment and caps the census at 8192 OS processes and 4096 tracked identities.
Failed, truncated and unreadable scans are reported numerically rather than passed off as complete.

There is no prompt, reply, tool output, terminal content, file-content collection, command-line collection or
session replay. Native macOS does not support the SDK's UIKit replay integration. Automatic breadcrumbs,
HTTP failure capture and automatic/network/file/Core Data tracing remain disabled because those paths can
expose request URLs or project paths. Unregistered transactions are dropped. Registered transaction roots
and scope data are scrubbed; automatic child spans are discarded. Breadcrumbs appear with reports;
allowlisted structured logs are a separate, bounded stream.

Native profiling is implemented but disabled in the production constructor until account billing is approved.
When enabled, the first memory-pressure or orphan-process anomaly may start one profile per UTC day.
It immediately requests stop after the current SDK chunk, nominally 60 seconds; the SDK's main-run-loop
flush can be delayed by a hang. App launch does not start or resume a profile. The persisted budget survives
restarts. Opt-out immediately revokes the forwarding transport and discards pending uploads; the SDK's
local sampler may finish its current chunk after revocation.

SDK scope attachments bypass event callbacks too. The transport discards all attachment payloads and
filename headers, preserves permitted sibling events, and consumes attachment-only envelopes locally
without upload or retry. A real-SDK test attaches private sentinels to scope and checks the wire.

Profile chunks bypass Sentry's event callbacks, so `DiagnosticsEnvelopeTransport.swift` filters their actual
byte-framed envelopes before forwarding. It retains sampled addresses, numeric stacks, image UUIDs,
numeric thread IDs/priorities and the fixed `main` thread label, but removes other thread/queue names,
function/source strings, ambient metadata and absolute image paths. Release/environment come from trusted
app configuration, not the incoming payload. Input is capped at 8 MiB compressed/16 MiB expanded, with
bounded nesting and sample/stack counts. Unknown profile schemas fail closed. Disabled profiling also
rejects cached profile chunks. This implementation profiles the native app, not Pi or MCP subprocesses.

Sentry receives the connection's IP address. Enable **Prevent Storing of IP Addresses** in the
Sentry project's Security & Privacy settings. `sendDefaultPii = false` is not a substitute for
that server setting. Sentry's configured retention applies to reports already uploaded.

## Consent and bounds

The SDK starts only after explicit consent and only in a configured build. Consent persists
across app launches so the SDK can upload a previous crash when the app reopens. It starts after
Shepherd acquires workspace ownership; failures before that point are not captured.

Turning reporting on takes effect after quitting and reopening Shepherd. The SDK can replay
crashes through its current global client, so it must not restart in-process after revocation.
Turning the switch off or resetting settings disables capture, blocks new upload requests,
cancels pending tasks, closes the SDK and removes its cache. One revoked URLSession remains
allocated until process exit: invalidating it would crash late SDK callbacks that create tasks.
A URLProtocol installed only on this session rejects those late requests without a socket. A later opt-in uses a new cache directory, so a late write
from the retired SDK is never uploaded under renewed consent. Data already received by Sentry
cannot be recalled. The random installation UUID remains stable across opt-out/in.

- Separate persisted UTC-day budgets: 50 error/crash/hang reports, 24 resource anomaly reports,
  144 resource transactions, 256 duration transactions, 1440 local resource samples, 256 structured logs
  and 5000 metric observations. Duration distributions and activity counters each have a 256-observation
  sub-budget, reserving capacity for the resource time series. These are sampled observations, not complete
  event totals. Native release-health sessions follow
  the SDK's app foreground/background lifecycle. Duration trace traffic
  also has a persisted cap of ten transactions per UTC hour and two per operation per hour, so startup
  and frequent refreshes cannot exhaust the day immediately. Resource traffic cannot exhaust the
  crash/error budget. Each anomaly category has a ten-minute local cooldown.
- At most 10 cached SDK envelopes and 32 fixed breadcrumbs. Crash payloads cap exception, thread,
  frame and image counts before sending. The pinned SDK separately retains up to five native
  crash reports; those files can contain raw stack bytes before sanitization.
- Each request has a 15-second timeout and a 30-second resource timeout; one connection per host.
  The SDK may retry cached envelopes when later events or launches trigger delivery. Shepherd
  adds no upload retry loop. The consent-owned sampler runs immediately and then every 60 seconds,
  with at most one sample in flight, for at most 1440 iterations and less than 24 hours per launch.
  It uploads the first sample and then every tenth sample. No persisted sampling job resumes; each
  launch checks consent again. Opt-out cancels the sampler and pressure observer before closing the SDK,
  and a late sample cannot capture a report. At most 32 pending owned span handles are retained;
  handles older than 30 seconds cannot send and are cleared at the next registration or opt-out.
- Set Sentry's account quota/spending policy before rollout; client caps are not an organization-wide
  billing cap. Traces carry all explicitly budgeted operations, not automatic app/network instrumentation.
- Stop, steering, compaction and queues do not change consent or generate model calls. Crashing
  child agents remain distinct from the app's own crash; their numeric exits become breadcrumbs.

The SDK cache lives under `<support>/diagnostics/<consent UUID>`. Startup retires other consent
UUIDs by directory name, not full URL equality: Foundation can enumerate `/tmp` as `/private/tmp`
or resolve a symlinked support directory. The active cache must survive those aliases so the
next launch can upload its pending crashes. Its native crash recorder can
write raw stack bytes and exception details locally before the upload filter runs, even with
memory introspection disabled. These are not uploaded. Disabling reporting removes that
directory tree; a late SDK write is retired and cleaned up on the next launch. Tests use scratch
defaults and never send to a live project.

## Configure a release

1. Create a Sentry Apple/macOS project. Configure retention, IP storage and account spending.
2. Add GitHub repository variables `SHEPHERD_SENTRY_DSN`, `SENTRY_ORG` and `SENTRY_PROJECT`.
   The DSN is public application configuration and must be an HTTPS hosted `*.sentry.io` DSN.
3. Add `SENTRY_AUTH_TOKEN` as a GitHub Actions secret with the permissions Sentry requires for
   debug-symbol upload. Never place the upload token in the plist, source or a chat message.
4. Release builds embed only the public DSN. The optional symbol step downloads Sentry CLI
   3.8.0, verifies its pinned SHA-256 and uploads existing dSYMs before stripping the app.
   Missing configuration skips the upload. Upload failures warn and retain the release's dSYM
   archive for a retry; they do not alter signing, notarization or feed publication.
5. Install a disposable configured build, opt in, trigger a controlled crash without a debugger,
   reopen it and confirm the issue has symbolicated Shepherd frames. Also confirm opt-out blocks
   further uploads. This live-project check is required before treating reporting as operational.

For a Dev build, supply `SHEPHERD_SENTRY_DSN=<public DSN>` to the existing `xcodebuild` command.
Use scratch support, defaults and agent homes for testing; never crash a running working copy.
The SDK's default release name distinguishes bundle identifier, version and build. The main and
Nightly apps can share a Sentry project and be filtered by release/environment.

## iOS

The iPhone and iPad client reports to the separate `shepherd-ios` project, and unlike the Mac it is
opt-out: on unless Settings > Diagnostics turns it off. `App/iOS/App/MobileDiagnostics.swift` is the
only iOS file that imports Sentry. It starts the SDK at launch with its automatic instrumentation:
crashes, app hangs, watchdog terminations, MetricKit, every trace (app start, screens, taps, network,
file I/O, frames, time to full display), profiles on app start and a quarter of sessions, the view
hierarchy (types, frames, identifiers; no text), and a replay of the moments around an error with all
text and images masked. No screenshot is attached, and `sendDefaultPii` stays off, so no IP, user or
request headers (the push relay's bearer token) are sent. Automatic breadcrumbs keep request URLs.
The SDK's existing bounded breadcrumb ring also records app-owned navigation requests (open, present, dismiss,
pop to root) with only the coarse screen kind, never route-associated paths, queries or identifiers.
These describe requested navigation, not confirmation that a screen rendered; SDK lifecycle breadcrumbs
already record foreground/background transitions. Opt-out disables these breadcrumbs with the SDK.

`DiagnosticsBudget` (ShepherdRemote) caps each UTC day at 100 errors and 1000 transactions, persisted
across launches; profiles and replays are bounded by their sample rates and the error cap. Turning the
switch off closes the SDK and deletes unsent reports; turning it on waits for the next launch.

Only a build given a DSN reports: the TestFlight job passes repository variable `SHEPHERD_IOS_SENTRY_DSN`
and uploads the archive's dSYMs to `shepherd-ios` with the existing `SENTRY_AUTH_TOKEN`. Local and
simulator builds have no DSN and send nothing.

## Removing or replacing Sentry

Keep the small `record` and `capture` API and replace its body with local logging, another SDK,
or no-ops. Remove the Sentry package/product and its pin from both resolution files, the plist
and build setting, the optional upload script/workflow step, repository variables and secret.
Remove the Diagnostics setting if no reporting remains. No Core/Protocol contracts or persisted
workspace fields depend on Sentry. Historical Sentry reports require separate export/deletion.

## Validation and decisions

Focused checks cover opt-in/reset, daily limits across restarts, DSN rejection, SDK options,
private-field removal while retaining symbolication inputs, the settings switch and its disclosure
through real accessibility actions, light/dark/large-text renders, and optional symbol upload with
mocked network/process boundaries. Runtime tests start the real SDK with a URLProtocol transport
that intercepts every request, inspect the compressed upload, cancel an in-flight request on
revocation, and verify off/on cannot restart the SDK within the same launch. The runtime scenario
also reuses a persisted consent UUID through a symlinked support path, verifies its pending report
bytes survive startup, and confirms retired consent caches are still removed. Performance tests cover
separate persistent budgets, finite sampling lifetime, finite nonnegative numeric allowlists, ten-sample
retention, trace duration timestamps and rejection of unknown transaction names. Wire tests inject a
private sentinel into scope and resource input, verify it never uploads, and ensure resource/duration
capture remains inert after revocation. Log/metric tests inspect real compressed envelope item types,
reject forged ownership receipts, verify fixed metadata, exhaust persisted budgets, and cancel pending
uploads on opt-out. Release-health tests verify anonymous session IDs and the release/environment schema.
System-performance diagnostics retain their fixed kind but drop raw diagnostic strings. A separate
isolated test captures an actual SDK profile chunk against the fake transport, verifies symbolication
addresses and trusted release metadata, and hits the persisted one-profile limit. No test sends to Sentry.

Decisions: off by default; visible disabled row when unconfigured; reset revokes consent; hosted
Sentry only; the one existing consent controls crash and bounded performance reporting; no confirmation
sheet beyond the explicit labelled switch; separate daily report budgets; symbol upload is nonfatal like
existing release symbol archives.
Design checklist: [Diagnostics](design/boards/Diagnostics.md). Departures: none.

The preview suite skips when `SHEPHERD_PREVIEW_DIR` is unset, like the other visual suites;
set it explicitly to exercise all four consent states in both appearances and text sizes.

Local validation used `swift test --build-system native --filter 'Diagnostics|SettingsReset'`
because this Xcode beta's default SwiftPM test runner could not load Sparkle. Fifteen tests
passed; the preview test skipped because `SHEPHERD_PREVIEW_DIR` was unset. Restoring the old URL
comparison makes the pending-cache assertion fail.
The Release `xcodebuild` passed. A configured disposable copy, with a unique preferences domain,
scratch support and pi homes, and no agents, completed two native crash/relaunch cycles through
an aliased `/tmp` support path without a debugger or injected library. Its executable and dSYM
UUIDs matched, symbol upload succeeded, and Sentry received both events with the expected release
and symbolicated `ShepherdLauncher.swift:11` frames. Relaunching opted out removed the SDK cache
and consent cache ID. Both stored test events had no `user.ip` field, but Sentry added geographic
metadata. That event-level check does not verify the project's IP-storage setting.
