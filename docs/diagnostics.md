# Crash diagnostics

Shepherd's macOS app can send opt-in crash diagnostics to Sentry. Settings > Advanced >
Diagnostics > Share crash diagnostics is off by default. A build without a valid hosted Sentry
DSN cannot enable reporting. iOS does not initialize the SDK.

## What is sent

The app sends native crash stacks, image UUIDs and addresses for symbolication, app release,
OS version, hardware class and memory fields supplied by the SDK. Fixed breadcrumbs record
app startup, selecting a local thread and process exits, with numeric exit codes. Agent-start
failures send a fixed error code. Random installation and run UUIDs permit correlation; they
are not account, device serial, agent or project identifiers.

`Sources/ShepherdApp/ShepherdDiagnostics.swift` is the only production file that imports
Sentry. Its single app-owned instance exposes active state to Settings and accepts scratch
storage and a URLSession configuration for isolated runtime tests. Callers use Shepherd-owned
enums and numbers. Do not pass arbitrary errors or logs to
it. The pre-send filter reconstructs the event and drops exception messages, unknown exception
names, user information, requests, extra fields, thread names, registers, source lines and
absolute binary paths. It retains symbols and image metadata needed for symbolication.

There is no prompt, reply, tool output, terminal content, file-content collection or session
replay. Automatic breadcrumbs, HTTP failure capture, tracing, metrics, logs, sessions,
MetricKit and hang tracking are disabled. This is a crash-reporting foundation, not a continuous
CPU/memory dashboard or a recorder of child-process stacks. Breadcrumbs appear with reports,
not as an independently uploaded event stream.

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

- At most 50 newly accepted reports per UTC day, persisted across restarts and consent changes.
- At most 10 cached SDK envelopes and 32 fixed breadcrumbs. Crash payloads cap exception, thread,
  frame and image counts before sending. The pinned SDK separately retains up to five native
  crash reports; those files can contain raw stack bytes before sanitization.
- Each request has a 15-second timeout and a 30-second resource timeout; one connection per host.
  The SDK may retry cached envelopes when later events or launches trigger delivery. Shepherd
  adds no retry loop or background polling task.
- Tracing, logs and metrics spend are off. Set Sentry's account quota/spending policy before
  rollout; the client cap is not an organization-wide billing cap.
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
bytes survive startup, and confirms retired consent caches are still removed.

Decisions: off by default; visible disabled row when unconfigured; reset revokes consent; hosted
Sentry only; crash/error reporting first; no confirmation sheet beyond the explicit labelled
switch; 50 reports/day; symbol upload is nonfatal like existing release symbol archives.
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
