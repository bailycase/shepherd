# Checking the iOS client

The iOS app ([README.md](README.md)) shares `ShepherdCore`, `ShepherdProtocol`,
`ShepherdRemote` and `ShepherdUI` with the Mac. Run these checks when you change the app or those
modules. Neither script is part of `swift test`. A change to a shared module also runs the Mac
build, the touched targets' unit tests, and the Mac preview suites it affects.

## Compile

```sh
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd iOS' \
  -destination 'generic/platform=iOS Simulator' -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
```

Build for a simulator you made, iPhone and iPad alike, with `-destination 'id=<udid>'`.

A device archive, as the TestFlight job builds it (unsigned; the job signs at export):

```sh
xcodebuild archive -project Shepherd.xcodeproj -scheme 'Shepherd iOS' -configuration Release \
  -destination 'generic/platform=iOS' -archivePath /tmp/Shepherd-iOS.xcarchive \
  -skipPackagePluginValidation -skipMacroValidation -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION=1
python3 scripts/release.py verify-ios '/tmp/Shepherd-iOS.xcarchive/Products/Applications/Shepherd iOS.app' 1
```

`verify-ios` checks what App Store Connect or testers would trip on: the bundle id, the build
number, a version of one to three integers, the export-compliance answer, and the privacy
manifest. `Tests/Release` pins the target's signing and Info.plist settings and the export
options.

## Connection and thread-store checks

```sh
bash Tests/ShepherdIOSChecks/run.sh
```

This takes no arguments. It compiles the three shared modules as macOS libraries into a
temporary directory, then builds and runs three programs:

- **`MobileHostsCheck`:** `App/iOS/Hosts/MobileHosts.swift` with tokens in memory and a scratch
  preferences domain, against real TCP listeners. It covers migrating the first client's single
  host and its token (and a token that waits for a locked Keychain), records saved without tokens, a new host needing a token, several hosts
  at once (one live, one refusing), pushed state, backgrounding and foregrounding with a new
  session, retry and stop, renaming without reconnecting, forgetting, and a host that refuses the
  token waiting for Retry instead of retrying on its own.
- **`ThreadStoreCheck`:** `NativeThreadStore`. It covers revisions, merging history with live
  entries, stale sessions, acceptance, drafts, unknown outcomes with no automatic resend,
  questions, abort, and stop and reconnect.
- **`RemoteConnectCheck`:** checks that cancelling or disconnecting while a socket is still
  opening never sends `hello`.

Real Keychain behavior is not tested here. Pure logic (host records and entries, backoff) has
unit tests in `ShepherdRemoteUnitTests`.

## Screens from fixtures

`run-simulator.sh` renders any screen of the app from fixture data on a simulator, headless, and
saves a screenshot of each. It never opens Simulator.app and never touches the mouse or
keyboard.

```sh
# Your own simulators, never one someone is using:
iphone=$(xcrun simctl create "Shepherd shots iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
ipad=$(xcrun simctl create "Shepherd shots iPad" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB com.apple.CoreSimulator.SimRuntime.iOS-27-0)

bash Tests/ShepherdIOSChecks/run-simulator.sh -d "$iphone" -o /tmp/shots home thread question
bash Tests/ShepherdIOSChecks/run-simulator.sh -d "$ipad" -o /tmp/shots -r landscape -s dark thread
bash Tests/ShepherdIOSChecks/run-simulator.sh -d "$ipad" -o /tmp/shots --sidebar thread
bash Tests/ShepherdIOSChecks/run-simulator.sh -w -d "$ipad" -o /tmp/shots -r landscape windows-split windows-palette
bash Tests/ShepherdIOSChecks/run-simulator.sh -d "$iphone" -o /tmp/shots -t accessibility-extra-large all
bash Tests/ShepherdIOSChecks/run-simulator.sh --list

xcrun simctl shutdown "$iphone" "$ipad" && xcrun simctl delete "$iphone" "$ipad"
```

| Option | Meaning |
| --- | --- |
| `-d <udid>` | the simulator; booted if it is not |
| `-o <dir>` | where the PNGs go: `<screen>-<device>-<scheme>[-landscape][-sidebar][-<text size>].png` |
| `-p <products>` | the `Shepherd iOS` scheme's `Debug-iphonesimulator` products; without it the script builds them (into `$SHEPHERD_IOS_DERIVED_DATA`, or a temporary folder) |
| `-s light\|dark\|both` | the appearance (default both); set on the simulator and in the app |
| `-r portrait\|landscape` | the orientation (iPad; the shot is turned the way it is seen) |
| `-t <category>` | a Dynamic Type size (`simctl ui content_size`), reset to large afterwards |
| `-n <label>` | the device part of file names (default: the simulator's name) |
| `--sidebar` | opens the iPad sidebar over a portrait thread |
| `-w` | an app that supports multiple windows, as the shipped app does (the `windows-*` screens) |
| `--list` | prints every screen name |
| screens | names from `Tests/ShepherdIOSChecks/Fixtures`, or `all` |

**How it works.** The script compiles a fixture app from every file in `App/iOS` except
`App/ShepherdIOSApp.swift`, with `ThreadSimulatorFixture.swift` as its entry point, linking the
scheme's package objects (SwiftTerm's included) and copying ShepherdUI's font bundle. The fixture app starts one
in-process `FixtureHost` per fixture host: a real TCP listener on 127.0.0.1 speaking the remote
protocol, so the app connects through `MobileHosts` and `RemoteHostClient` exactly as it would to
a Mac. Tokens live in memory and preferences in a scratch domain. Once the online hosts connect,
the app opens the screen's routes, waits for a thread's first snapshot, settles, and prints
`FIXTURE READY <screen>`; the script then takes the screenshot.

**What it checks.** A screen that never becomes ready fails, and so does one that asks a host to
change anything (a send, an abort, an agent action, a terminal attach or input): the fixture
host refuses those and prints `FIXTURE MUTATION` (Undo and Redo of a turn included). Each run also prints the requests every host
received (`FIXTURE REQUESTS`). A screen can also measure what it draws and print
`FIXTURE CHECK ok|FAILED: …`, which the script echoes and fails on: `thread-follow` checks that
the reply ends above the composer, and `thread-jump` (a drag up from the tail, stepped through
the scroll view's pan recognizer) that new output leaves the thread where the reader left it,
with "Jump to latest" showing. The `context-*` screens (Fixtures/ContextFixtures.swift) draw the context ring
beside Send and its sheet: `context-ring` (68%, amber), `context-details` (the split and Largest),
`context-full` (almost full, the field for what to keep), `context-compacting`, and
`context-compacted` and `context-compacted-details` (what the agent kept open in the thread, the
dashed ring, the estimate). `ThreadStoreCheck` also covers the ring's store side: no ring from a
host without context, the ring changing only with the usage, and Compact now's instructions. `composer-focus` focuses the composer as a tap does and checks
that the field keeps the focus above the keyboard and, on an iPad in portrait, that the sidebar
stays a hidden overlay; `composer-focus-rotate` focuses in landscape, turns the iPad to portrait,
and checks the same with no second tap (the field keeps the focus through the turn) (run both in portrait; `-r landscape` shots draw the keyboard
sideways). Attaching changes a host's PTY size, so the terminal screens
(`terminal`, `terminal-keys`, `terminal-split`, `terminal-maximized`, `terminal-empty`,
`terminal-phone`, `terminal-phone-keys`, and the ones below) never attach: their sessions draw
canned screens (`MobileTerminals.cannedScreens`), and the host answers only the read `terminals`
query. `terminal-close` and `terminal-phone-close` open the split tab's close confirmation
(`MobileTerminals.cannedClose`). `terminal-relaunched` and `terminal-phone-relaunched` have the
host push the layout it has after a relaunch (the shell pane under a new session) and check that
the pane draws the new session's own screen.

**Windows.** Without `-w` the fixture app is single-window, as the screens of the other tracks
expect. With it, a screen can open more windows (CONTRACTS.md › Fixture screens): `windows-split`
and `windows-sent` draw two windows side by side as Split View does, and `windows-new` opens a
real second window, which the simulator's full-screen mode shows over the first. Windows the
system restores from an earlier run are closed before a screen starts.

**The Changes pane's screens.** `review`, `diff`, `review-comment`, `review-base`, `review-pr`,
`review-empty`, `review-error` (MobileChanges, MobileDiff) and `changes-pad`, `changes-pad-full`,
`changes-pad-commit`, `changes-pad-base`, `changes-pad-turn`, `changes-pad-collapsed` (iPadReview,
iPadReviewSplit, iPadCommit, on an iPad in landscape) run against a host with `changes.v1`;
`review-legacy` against one without it (today's working-tree review). The thread's card:
`thread` (Undo), `thread-undone` (Redo), `thread-card-legacy` (an older host: no Undo), and
`changes-card` (the iPad's "Edited 5 files").

**Designs on iPad.** A fixture host with designs (`FixtureHostData.designs`) offers `designs.v1`
and answers every read of it (the listing, an index, changed files, pieces, comments, a system,
watch) from `FixtureDesigns`; every write (a comment, a tweak, a move, a duplicate) is refused as
a mutation. Hosts without designs don't list the capability, so other screens are unchanged. The
boards (`Fixtures/DesignPadBoards.swift`, acme's checkout funnel) are Design-format files the
simulator renders with Shepherd's own runtime. Run them on an iPad (the screenshots use an iPad
Air 11-inch, iPadDesign's 1180 × 820): `design-pad`, `design-pad-tweak` (an element tapped: its
ring and the Tweak tab) and `design-pad-comments` (the Comments tab and a pin's thread) with
`-r landscape` or in portrait; `design-pad-split` (iPadSplitView) with `-w`; `design-pad-sidebar`
(iPadSidebar) with `--sidebar`; and `designs-pad` (the Designs list). Each design screen prints
`FIXTURE CHECK ok design` once the boards on screen drew. `design-pad-pan` pans a 64-board canvas
row by row and prints `FIXTURE CHECK FAILED` if more than the plan's two web views were ever
alive, in the renderer or in the window.

**Adding a screen:** see [CONTRACTS.md › Fixture screens](CONTRACTS.md#fixture-screens).

## Not yet validated

- A real pi session driven from a phone against the current RPC host.
- Physical-device signing, and the TestFlight upload itself. The TestFlight lane is in place
  ([README.md › Distribution](README.md#distribution)), but only its first real run proves the
  cloud-signed export and upload.
- VoiceOver navigation end to end (labels are set; no automated pass yet).
