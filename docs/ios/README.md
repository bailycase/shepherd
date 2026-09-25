# Shepherd for iOS

`App/iOS` is a remote-only iPhone and iPad client for Macs running Shepherd. It is being built
for its first release: a foundation (this page) and six feature tracks, each with its own folder
([CONTRACTS.md](CONTRACTS.md) is the map). It is built on Night Watch (ShepherdUI) and
`@Observable` stores, like the Mac.

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
3. In the app, open Settings ▸ Hosts ▸ Add host, then enter a name, the Mac's address, the port,
   and the token. Add as many hosts as you like. The simulator can use `127.0.0.1` for a host on
   the same Mac. A phone needs the Mac's LAN or VPN address.
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
- **Re-runs:** a re-run keeps the run number, so it keeps the build number. Once the Mac
  nightly has published, re-running the whole workflow skips both builds. To retry only the
  upload, use "Re-run failed jobs". If only the Mac job failed, also use "Re-run failed jobs":
  re-running everything would upload the same build number again, which App Store Connect
  refuses. Or push again.

**One-time setup, in order:**

1. The Account Holder accepts any pending agreements in App Store Connect (Business). A free app
   needs no paid-apps agreement.
2. Register the App ID `com.bailycase.shepherd.ios` under Certificates, Identifiers & Profiles:
   Identifiers ▸ + ▸ App IDs ▸ App, Explicit, with no capabilities. Skip this step if Xcode
   already registered it for a device run. App Store Connect's New App form only lists bundle
   IDs that are already registered.
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

- **Target:** the `Shepherd iOS` Xcode target (iOS 27, iPhone and iPad). `App/iOS` is one
  synchronized folder, so every Swift file under it is compiled without a project edit
  (`ExportOptions.plist` is excepted; `PrivacyInfo.xcprivacy` ships as a resource). It links
  `ShepherdCore`, `ShepherdProtocol`, `ShepherdRemote` and `ShepherdUI`, never `ShepherdApp`.
- **Folders:** `App/` (entry point, `MobileApp`, `MobileRoot`, the phone and iPad shells, routes
  and the navigator), `Hosts/`, `Home/`, `Thread/`, `Composer/`, `NewThread/`, `Subagents/`,
  `Review/`, `Search/`, `Settings/`, and `Support/` (`AgentRef`, `MobileLayout`,
  `MobileAppearance`, the `AgentState` mapping). Ownership and hooks: [CONTRACTS.md](CONTRACTS.md).
- **Shared with the Mac:** `RemoteHostClient`, `NativeThreadStore`, the turn and activity
  derivations (`NativeTurnPresentation`, `NativeActivity`), host records
  (`RemoteHostRecord`, `RemoteHostEntry`, `RemoteReconnectBackoff`), and ShepherdUI's
  components (bubbles, prose, thinking, activity lines, the changes card, the composer). On iOS,
  ShepherdUI uses the phone boards' type ramp, grows controls' hit areas to 44pt, and shows at
  rest what the Mac shows on hover.

## What it does

- **Hosts (`MobileHosts`):** several hosts at once, each with its own `RemoteHostClient`,
  connection state and backoff (1, 2, 4… up to 30 s). Records (name, address, port) are saved in
  UserDefaults (`shepherd.ios.hosts`); each token is a Keychain generic password per host
  (device-only, available when unlocked, never synced). The first client's single saved host
  (`shepherd.ios.host` and its one Keychain item) migrates on first launch; if the Keychain is
  locked then, the token moves on the next foreground. Backgrounding
  disconnects every host; the agents keep running on the Macs.
- **iPhone:** two tabs, Home and Settings, each a navigation stack. Home merges every host:
  Automations (read-only) and More (host cards), offline hosts with Retry, Needs you (questions
  and blocked threads, answered in place when short), and Recents with host tags. `HomeFeed`
  derives it once per change from each host's state and, while Home is on screen, the threads'
  snapshots.
- **iPad:** a split view. Landscape shows the sidebar (New thread, Needs you, Recents, and a
  footer with the hosts and Settings) beside the selected thread; in portrait the thread takes
  the width and the sidebar slides over it. With no thread selected the detail is the overview:
  Needs you, Running now and Finished.
- **Thread (`ThreadScreen`):** the title with its status line ("Idle · 17 turns · 42k", or the
  running turn's clock; on iPad a status pill with the counters trailing), Stop while the agent
  runs, user bubbles with their times, thinking, prose, work groups folded into one line with
  their calls, the running call's live output, notes, errors with Retry, the changes card
  (Review opens all of the turn's changes), and the turn footer (time, duration, tool calls,
  Copy, Retry). It polls its host only while on screen and the app is active (500 ms while the
  agent runs).
- **Composer (`ThreadComposer`, `Composer/`):** on iPhone a paperclip beside a capsule field,
  with the commands, model and thinking chips above it while it is in use; on iPad the Mac's
  card with that row under the field. Send queues while pi works (hold it to Steer now). Up
  next draws the host's queue: steering messages first with Back to the queue, queued ones
  with swipe (Edit, Delete) and long-press (Steer now, Edit, Move to top, Delete) actions, an
  Undo row for a delete, and a ••• menu (Steer or Send all now, the delivery mode, Clear). The
  model picker lists the host's catalog; images come from Photos, resized to the protocol's
  limits; "/…" lists the snapshot's commands. A question from the agent takes the composer's
  place: numbered answers to choose, Yes and No for a confirm, a field for input and editor.
- **Settings:** Appearance (System, Light, Dark), the hosts as cards with Retry, and a host form
  (add, edit, forget; a blank token keeps the saved one).
- **Stubs:** New thread, Subagents, Review, Search, and agent actions are placeholders their
  tracks fill ([CONTRACTS.md](CONTRACTS.md)).

## Not in the first release

Push notifications and Live Activities (they need a relay: the phone's socket drops in the
background), automations over remote, QR pairing and TLS, terminal panes, multiple iPad
windows, and everything waiting on the Mac (Missions, Designs, daemon hosts).
