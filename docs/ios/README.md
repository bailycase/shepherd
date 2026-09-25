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
   never starts pi itself; it attaches only to the terminal panes of the agent's layout, and
   only while one is on screen.

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
  automatically. Once it has processed, the Release workflow's `retire-testflight` job expires
  every older build, so only the newest stays installable (otherwise each lasts 90 days). The
  first nightly push after that job landed also clears the builds already there. It has no
  manual run: a dry run (`release.py retire-testflight --dry-run`) works only locally, with the
  App Store Connect key.
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
  `ShepherdCore`, `ShepherdProtocol`, `ShepherdRemote` and `ShepherdUI`, never `ShepherdApp`,
  and SwiftTerm (the package the Mac's host screens already use) for terminal panes.
- **Folders:** `App/` (entry point, `MobileApp`, `MobileRoot`, the phone and iPad shells, routes
  and the navigator), `Hosts/`, `Home/`, `Thread/`, `Composer/`, `NewThread/`, `Subagents/`,
  `Review/`, `Commit/`, `Search/`, `Settings/`, `Automations/`, `Windows/` (the scene and its
  windows), `Terminal/`, and `Support/` (`AgentRef`, `MobileLayout`, `MobileAppearance`, the
  `AgentState` mapping). Ownership and hooks: [CONTRACTS.md](CONTRACTS.md).
- **Shared with the Mac:** `RemoteHostClient`, `NativeThreadStore`, the turn and activity
  derivations (`NativeTurnPresentation`, `NativeActivity`), host records
  (`RemoteHostRecord`, `RemoteHostEntry`, `RemoteReconnectBackoff`), and ShepherdUI's
  components (bubbles, prose, thinking, activity lines, the changes card, the composer). On iOS,
  ShepherdUI uses the phone boards' type ramp, grows controls' hit areas to 44pt, and shows at
  rest what the Mac shows on hover.

## What it does

- **Hosts (`MobileHosts`):** several hosts at once, each with its own `RemoteHostClient`,
  connection state and backoff (1, 2, 4… up to 30 s). A host that refuses the token or speaks
  another protocol says so on its card and waits for Edit or Retry; an unreachable one says
  Shepherd isn't running there or can't be reached, with the client's own reason in its form. Records (name, address, port) are saved in
  UserDefaults (`shepherd.ios.hosts`); each token is a Keychain generic password per host
  (device-only, available when unlocked, never synced). The first client's single saved host
  (`shepherd.ios.host` and its one Keychain item) migrates on first launch; if the Keychain is
  locked then, the token moves on the next foreground. Backgrounding
  disconnects every host; the agents keep running on the Macs.
- **iPhone:** two tabs, Home and Settings, each a navigation stack. Home merges every host:
  Automations and More (host cards), offline hosts with Retry, Needs you (questions
  and blocked threads, answered in place when short), and Recents with host tags. `HomeFeed`
  derives it once per change from each host's state and, while Home is on screen, the threads'
  snapshots.
- **iPad:** a split view. Landscape shows the sidebar (New thread, Needs you, Recents, and a
  footer with the hosts and Settings) beside the selected thread; in portrait the thread takes
  the width and the sidebar slides over it. Portrait is the window's shape, never what the
  keyboard leaves of it (CONTRACTS.md › Navigation). With no thread selected the detail is the
  overview: Needs you, Running now and Finished.
- **Thread (`ThreadScreen`):** the title with its status line ("Idle · ⧉ pi/swiftui-previews", or
  "Needs you · ⌂ your checkout" when pi works in the space's own checkout; on iPad the branch chip
  with its changed files, and the host when there are several, then a status pill with the running
  turn's clock), Stop while the agent
  runs, user bubbles with their times, thinking, prose, work groups folded into one line with
  their calls, the running call's live output, notes, errors with Retry, the changes card
  (Review opens all of the turn's changes), and the turn footer (time, duration, tool calls,
  Copy, Retry). It polls its host only while on screen and the app is active (500 ms while the
  agent runs). It follows its tail as the Mac's thread does (`NativeScrollFollower`): only a
  finger dragging it up detaches, while replies, the composer or keyboard resizing, and rows
  re-wrapping beside a docked review keep the last turn above the composer. Detached while the
  agent runs or new output arrived, "↓ Jump to latest" (`NWJumpToLatest`) sits above the
  composer.
- **Composer (`ThreadComposer`, `Composer/`):** on iPhone a paperclip beside a capsule field,
  with the commands, model and thinking chips above it while it is in use; on iPad the Mac's
  card with that row under the field. The thinking chip, like the Mac's, hides for a model the
  host's `listModels` says takes no thinking level. Send queues while pi works (hold it to Steer now). Up
  next draws the host's queue: steering messages first with Back to the queue, queued ones
  with swipe (Edit, Delete) and long-press (Steer now, Edit, Move to top, Delete) actions, an
  Undo row for a delete, and a ••• menu (Steer or Send all now, the delivery mode, Clear). A
  paused queue (after Stop, or a failed turn) shows Send now in its header, with its reason as
  the VoiceOver hint, where the Mac shows it on a row's hover and in a tooltip. The
  model picker lists the host's catalog; images come from Photos, resized to the protocol's
  limits; "/…" lists the snapshot's commands. A question from the agent takes the composer's
  place: numbered answers to choose, Yes and No for a confirm, a field for input and editor.
- **Settings:** Appearance (System, Light, Dark), the hosts as cards with Retry, and a host form
  (add, edit, forget; a blank token keeps the saved one).
- **New thread (`NewThread/`):** the prompt, then chips for repo, host, model and thinking (only
  for a model that takes a level: Off, Minimal, Low, Medium and High, with Extra high and Max where
  the host's catalog says the model has them, and Off to High on a host without
  `thinking.levels.v1`). The composer's thinking chip offers the levels pi reports for the
  thread's model. Model names truncate in the middle, the full id read aloud. Repo
  lists the host's spaces first and other hosts' after (choosing one moves the thread there), and
  Add repo browses the host's folders (`listDir`, `addSpace`). Host shows each one's status and
  running threads. The New worktree switch (on by default) takes a generated branch and a base
  resolved through `creationOptions`. Start sends `createAgent` as the Mac's New Agent sheet
  does, then opens the thread; images ride on the first send. An older host says what it lacks
  instead of failing. On iPad it is a small form over the thread, with a popover per chip.
- **Subagents (`Subagents/`):** cards in the thread where the spawn was (one run as a card, a
  group as one card that becomes a ledger once every run finishes), the runs list (this turn and
  earlier), and one run: its goal, its live transcript, and a steer field that reaches only that
  child. A child's question is answered in place, from the card, the list or the run. Pause,
  Continue, Stop and Re-run appear where the host takes them. On iPad the run opens in an
  inspector column beside the thread.
- **Review (`Review/`):** the changes (working tree vs HEAD, or the PR), with viewed progress,
  the file list, comments, Request changes, and Commit… (below; on an older host, Commit sends the
  agent a turn, as on the Mac); the diff reader (wrapped, syntax-colored lines, folded removed runs, line comments, Next
  file); and Finalize for worktree agents (checks, the form, each step, the PR link). On iPad
  review docks beside the thread or goes full screen with a unified or split view. There is no
  per-file revert: the remote protocol has none.
- **Commit from review (`Commit/`):** on a host with `review.commit.v1`, Commit… opens the
  commit: a sheet on iPhone, a popover beside Commit… on iPad. The host drafts the message from
  the diff (a plain one from the file list shows first), every changed file starts ticked, a
  message nobody edited follows the ticks (drafted again for the ticked files), and
  Push after commit (to the upstream, setting one when there is none) or Open a pull request
  instead picks where it goes. The host runs it (`ReviewCommitStore` in ShepherdRemote drives
  the sheet) and refuses a detached HEAD, a merge or rebase in progress, a file that changed since
  the sheet opened, and an agent still working unless confirmed; the sheet shows each step, and a
  finished commit reloads the changes. Ask agent to commit keeps the old turn.
- **Automations (`Automations/`):** every host's automations, the running ones first, each
  with its switch (On starts a run when Shepherd launches on the host) and how its last run went.
  One automation shows its folder, prompt, the latest fourteen runs as a chart, and every run the
  host kept, each opening its thread while that thread exists; Run now (replacing a finished
  run), Stop (confirmed, while a run is live), Edit and Delete act on the host. `+` saves a new
  one: a name, a prompt, and one of the host's spaces. The Mac has no schedules or triggers, so
  neither does the form. On iPad the list sits beside
  the chosen automation. A host without `automations.v1` shows its automations read-only and
  says so.
- **Windows (`Windows/`, iPad):** several Shepherd windows side by side in Split View or Stage
  Manager, each with its own place (restored on relaunch) over the same hosts, connections and
  threads. Open in new window from a thread's options, a sidebar row or the ⌘K palette (it
  brings forward a window already showing the thread). A turn's long-press menu has Send to…,
  which puts its text in another window's composer, and a turn drags into a composer as text.
  iPhone keeps one window.
- **Search and actions (`Search/`):** search across every connected host: title matches at once,
  conversations fanned out to each host (`agentQuery(.search)`), snippets with host tags. A
  thread's options menu renames, moves and deletes its agent; a worktree agent's delete follows
  the Mac's Delete Worktree Agent (the host's warning, acknowledged, then progress). On iPad
  ⌘K opens a palette over search and actions, with a live preview of the selected thread.

- **Terminal (`Terminal/`):** the terminal panes of an agent's layout on its host. On iPad a
  panel under the thread (Show Terminal in the thread's options menu; no header button) with the layout's
  tabs, + (a new pane beside the thread), Split right, Maximize, Hide, and a divider that snaps
  at a third, half and two-thirds; on iPhone the thread's options open them full screen. Each
  pane is SwiftTerm's view on Night Watch's terminal palette, attached (`attach`) while it is on
  screen, the app is active and the host connected, and detached a second after it leaves; the
  host replays its screen on every attach and sizes the PTY to its smallest viewer. A refused
  attach is retried with backoff (1 s doubling to 30 s) while the pane stays on screen, and a
  pane the host gives a new session (every pane respawns its shell when the host relaunches)
  gets a new view that attaches to it. Keys go to the host as `input`; a key row (esc, tab,
  ctrl, ⌥, `|`, `~`, `/`, `-`, arrows; two rows on a phone in portrait) sits under the terminal
  while it has the keyboard, and a hardware keyboard types directly. Tabs name what
  runs in them and show a spinner or a dot for new output where the host answers
  `RemoteAgentQuery.terminals` (`terminal.activity.v1`); the dot follows the row's `news`, which
  leaves out a redraw after a resize on hosts that send `newsSequence`. The iPad panel closes
  with its last terminal. Closing a tab asks (naming how many shells stop, and the tab's place
  when another tab has its title), then asks the host to close its panes; the host keeps the
  Mac's rules (never the agent's own pane, never the last pane). A host without pane control
  (`pane.control.v1`) shows its terminals but offers no +,
  split or close. A terminal's screen is in one iPad window at a time: another window showing the
  same thread says "open in another window" until the first lets it go.

## Not in the first release

Push notifications and Live Activities (they need a relay: the phone's socket drops in the
background), QR pairing and TLS, and everything waiting on the Mac (Missions, Designs,
daemon hosts).
