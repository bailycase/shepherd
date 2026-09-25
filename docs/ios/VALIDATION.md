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
host refuses those and prints `FIXTURE MUTATION`. Each run also prints the requests every host
received (`FIXTURE REQUESTS`). A screen can also measure what it draws and print
`FIXTURE CHECK ok|FAILED: …`, which the script echoes and fails on: `thread-follow` checks that
the reply ends above the composer, and `thread-jump` (a drag up from the tail, stepped through
the scroll view's pan recognizer) that new output leaves the thread where the reader left it,
with "Jump to latest" showing. Attaching changes a host's PTY size, so the terminal screens
(`terminal`, `terminal-keys`, `terminal-split`, `terminal-maximized`, `terminal-empty`,
`terminal-phone`, `terminal-phone-keys`) never attach: their sessions draw canned screens
(`MobileTerminals.cannedScreens`), and the host answers only the read `terminals` query.

**Windows.** Without `-w` the fixture app is single-window, as the screens of the other tracks
expect. With it, a screen can open more windows (CONTRACTS.md › Fixture screens): `windows-split`
and `windows-sent` draw two windows side by side as Split View does, and `windows-new` opens a
real second window, which the simulator's full-screen mode shows over the first. Windows the
system restores from an earlier run are closed before a screen starts.

**Adding a screen:** see [CONTRACTS.md › Fixture screens](CONTRACTS.md#fixture-screens).

## Not yet validated

- A real pi session driven from a phone against the current RPC host.
- Physical-device signing, and the TestFlight upload itself. The nightly lane is in place
  ([README.md › Distribution](README.md#distribution)), but only its first real run proves the
  cloud-signed export and upload.
- VoiceOver navigation end to end (labels are set; no automated pass yet).
