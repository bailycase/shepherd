# Shepherd for iOS (deferred)

`App/iOS` is a remote-only iPhone and iPad client for a Mac running Shepherd. It works, but it is
**later work**. The current redesign is macOS-only, and iOS has not adopted the design system or
most of the Mac's thread features. This page describes the app as the code stands today.

The client connects to a Mac host over the same bearer-token TCP protocol another Mac uses (see
[SECURITY.md](../../SECURITY.md)). Use a trusted LAN or VPN. The connection has no TLS, and the
listener must never be exposed to the internet.

## Build and connect

1. On the Mac, run Shepherd (for development, the `Shepherd (Dev)` scheme). Turn on
   Settings ▸ Remote ▸ Serve this Mac ▸ Listener. The default port is 7433 (7434 in Shepherd
   Nightly). The token is the
   contents of `remote-token` in Shepherd's support directory; the Token row there reveals the
   file.
2. Build the `Shepherd iOS` scheme for an iOS 27 simulator or device. The target uses automatic
   signing with a development team set in the project. To run on your own device, select your
   team.
3. In the app, open the gear, then enter a name, the Mac's address, the port, and the token.
   The simulator can use `127.0.0.1` for a host on the same Mac. A phone needs the Mac's LAN or
   VPN address.
4. Open an agent from the list. The phone and the Mac control the same pi process. The phone
   never starts pi itself and never attaches a terminal.

Compile-only check, with no signing:

```sh
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd iOS' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

An unsigned build can fail Keychain access at runtime (`-34018`). Use a signed build to exercise
connecting. [VALIDATION.md](VALIDATION.md) covers the scripted checks.

## Distribution

The iOS client ships through TestFlight, following the Mac's channels:

| Trigger | iOS lane | Status |
| --- | --- | --- |
| push to `nightly` | TestFlight, internal testing | done |
| tag `vX.Y.Z-beta.N` | TestFlight, external testing | later |
| tag `vX.Y.Z` (the beta's commit re-tagged) | App Store | later |

**How the nightly lane works:**

- **Job:** every push to `nightly` runs the `testflight` job in `.github/workflows/release.yml`
  beside the Shepherd Nightly build. `scripts/release.py plan` decides it (`ios`), and
  `Tests/Release` tests the rule.
- **Build:** the job runs on the `xcode-27` runner, because the target needs the iOS 27 SDK.
  It archives `Shepherd iOS` unsigned, and `release.py verify-ios` checks the app.
- **Signing and upload:** `xcodebuild -exportArchive` with `App/iOS/ExportOptions.plist`,
  `-allowProvisioningUpdates`, and the App Store Connect key. It signs with the team's
  cloud-managed Apple Distribution certificate and uploads the build. No certificate is
  exported and no keychain is involved.
- **Versions:** the build number is the workflow's run number, the same one as the Shepherd
  Nightly build from that commit. The version is the project's `MARKETING_VERSION`. The Mac
  nightly's `0.0.0-nightly.<stamp>` is not a valid iOS version.
- **Missing secrets:** the job is skipped with a notice, and the Mac release is unaffected. It
  never runs for pull requests, tags, or other branches.
- **Expiry:** Apple processes each build (usually minutes). The Nightly group's testers get it
  automatically, and it stays installable for 90 days.
- **Re-runs:** re-running the whole workflow uploads nothing, because the run number would
  repeat. Use "Re-run failed jobs" to retry a failed upload, or push again.

**One-time setup, in order:**

1. The Account Holder accepts any pending agreements in App Store Connect (Business). A free app
   needs no paid-apps agreement.
2. Register the App ID `com.bailycase.shepherd.ios` under Certificates, Identifiers & Profiles:
   Identifiers ▸ + ▸ App IDs ▸ App, Explicit, with no capabilities. Skip this step if Xcode
   already registered it for a device run. Automatic signing at export does not register App
   IDs.
3. In App Store Connect, go to Apps ▸ + ▸ New App:
   - Platform iOS, a name, a language, bundle ID `com.bailycase.shepherd.ios`, and a SKU (for
     example `shepherd-ios`).
   - The API cannot create this record, and uploads fail without it.
4. Go to Users and Access ▸ Integrations ▸ App Store Connect API ▸ Team Keys ▸ Generate:
   - Access must be **Admin**. Developer and App Manager keys fail with a cloud-signing
     permission error.
   - Download the `.p8` (it downloads only once), and note the Key ID and Issuer ID.
5. Add these repository secrets under GitHub ▸ Settings ▸ Secrets and variables ▸ Actions:
   - `APP_STORE_CONNECT_KEY_ID`
   - `APP_STORE_CONNECT_ISSUER_ID`
   - `APP_STORE_CONNECT_KEY_P8`: the `.p8` file's text pasted as-is, not base64.
6. In the app's TestFlight ▸ Internal Testing ▸ +, create a group (for example "Nightly"), check
   **Enable automatic distribution**, and add testers. Testers are App Store Connect users,
   up to 100.
7. Testers install TestFlight with the same Apple Account and accept the invite. The next push
   to `nightly` uploads a build.

The first upload is also the first real test of the unsigned-archive, cloud-signed-export path.
The export step prints `DistributionSummary.plist` when there is one, which shows the signing
certificate and entitlements it used.

**Compatibility with Macs.** `hello` requires `RemoteProtocol.version` to match exactly, so a
TestFlight nightly and an older Mac stop talking the moment the version is bumped. A nightly
always pairs with the Shepherd Nightly from the same commit. Once builds reach people who
update the phone and the Mac at different times, grow the protocol through `capabilities` and
keep the version for real breaks.

**Later lanes:**

- **Beta, external testing:** the same job on a beta tag, with the tag's `X.Y.Z` as the version
  and `testFlightInternalTestingOnly` off. Then add the processed build to an external group and
  submit it for Beta App Review through the App Store Connect API. External testing needs its
  test information filled in, and the first build is reviewed.
- **Stable, App Store:** promotion re-tags the beta's commit, so attach the beta's build to a new
  App Store version instead of rebuilding. This needs store metadata, iPad and iPhone
  screenshots, privacy labels, and an age rating.
- **Version trains:** once `X.Y.Z` ships on the App Store it accepts no more builds, so the
  nightly version then has to move past it (derived in `release.py`).

## What it is made of

- **Target:** the `Shepherd iOS` Xcode target (iOS 27, iPhone and iPad) compiles the nine files
  in `App/iOS`. It links only `ShepherdCore`, `ShepherdProtocol`, and `ShepherdRemote`, not
  ShepherdUI or `ShepherdApp`.
- **Shared with the Mac:** `RemoteHostClient` and the `NativeThreadStore` thread client are the
  same code the Mac uses. The phone draws the `NativeThreadPresentation` derivations (turns, tool
  rows, pill state); the Mac has moved on to activity lines and the changes card
  (`NativeTurnPresentation`, `NativeActivity`).
- **Tokens:** it keeps its own `MobileTokens`: colors, the phone type ramp, and status words.
  These are not Night Watch and no longer match the Mac.

## What it does

- **Agents list (`FleetView`):**
  - The host with a Connected / Connecting / Unreachable pill.
  - Agent rows showing a status dot, the name, and "state · space"; "Show N more" past five
    rows.
  - An Automations section linking to running automations' agents.
  - When the host is unreachable: a Retry card, with cached rows dimmed.
- **Thread (`ThreadView`, `ThreadMessageView`):**
  - User bubbles and agent prose (a lightweight Markdown renderer).
  - Collapsible thinking.
  - Consecutive tool calls collapsed into one summary row, which expands to 40pt rows and opens
    a full-screen output view.
  - "Load older messages" paging.
  - Extension text widgets.
  - A header with the status line, Stop, and a menu for delivery (follow-up or steer) and
    Refresh.
- **Composer:** a pill field whose Send button becomes Stop while the agent runs with an empty
  draft. A "Waiting for you" slot reopens a pending question.
- **Questions (`ThreadDialogView`):** pi's `select`, `confirm`, `input`, and `editor` questions
  arrive over RPC like on the Mac. They appear in a bottom sheet and are answered in place. The
  first answer from any client wins. No pi patch or bridge extension is involved.
- **Host settings (`HostSettingsView`):**
  - The connection state with Reconnect, and the name, address, port, and token fields.
  - A no-TLS warning, and "Forget this host".
  - One host only. Its name, address, and port are saved in UserDefaults (`shepherd.ios.host`).
    The token is saved in the Keychain: a generic password, device-only, available when
    unlocked, never synced.
- **Lifecycle:**
  - Backgrounding disconnects; the agents keep running on the Mac.
  - Returning to the foreground reconnects, with backoff of 1, 2, 4… up to 30 s.
  - The open thread polls every 500 ms while the agent runs or waits, and every 2 s otherwise.
  - A request with no answer within 15 s is reported as an unknown outcome and never resent
    automatically.

## What it does not do (yet)

- **Sending:** no image attachments, no model or thinking controls, and no slash-command menu.
  Messages are sent as literal text.
- **Subagents:** no cards and no inspector. `snapshot.subagents` is ignored.
- **Thread detail:** no timestamps, thinking durations, context or stats, or tool durations. The
  host snapshot carries all of these; the phone does not render them yet. Images in the
  transcript show as a placeholder.
- **Workspace actions:** creating agents or spaces, worktrees, review, and terminals are all
  missing.
- **Multiple hosts:** only one is supported.
- **Notifications:** none. The app disconnects in the background.
- **Design system:** ShepherdUI (Night Watch, [DESIGN.md](../../DESIGN.md)) is not adopted,
  though the package already builds for iOS 27: its fonts follow Dynamic Type through
  `relativeTo:`, and icon buttons grow to the 44pt `NW.Height.touch`.
- **Approval wording:** confirm questions are labeled "Allow once / Deny" and blocked agents
  "needs approval". [DESIGN.md](../../DESIGN.md#principles) says there is no approval UI, only
  questions.

## Stale code to clean up when iOS resumes

- `ThreadView` shows "Questions need the pi dialog bridge on your Mac" when a snapshot reports
  `dialogsSupported == false`. Current hosts always report `true`, so only an older host can
  trigger it. Several comments still describe that bridge and claim the snapshot has no
  timestamps or durations; it does.
- `ThreadDialogView` has an `external-editor` unavailable branch that the RPC host never
  produces. The host only uses `payload-limit`.
- `MobileTokens` refers to `NativeTokens` in a comment. That type no longer exists.
