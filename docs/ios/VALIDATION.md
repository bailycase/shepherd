# Checking the iOS client

The iOS app ([README.md](README.md)) is deferred, but it still shares `ShepherdCore`,
`ShepherdProtocol`, and `ShepherdRemote` with the Mac. Run these checks when you change those
modules, or when iOS work resumes. Neither script is part of `swift test`.

## Compile

```sh
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd iOS' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Connection and thread-store checks

```sh
bash Tests/ShepherdIOSChecks/run.sh
```

This takes no arguments. It compiles the three shared modules as macOS libraries into a
temporary directory, then builds and runs three programs:

- **`HostConnectionCheck`:** `App/iOS/HostConnection.swift` with an in-memory token store. It
  covers port validation, exactly what is saved, live state pushes over real TCP, superseded
  handshakes, reconnect after backgrounding, failure, retry and cancel, and forgetting the host.
- **`ThreadStoreCheck`:** `NativeThreadStore`. It covers revisions, merging history with live
  entries, stale sessions, acceptance, drafts, unknown outcomes with no automatic resend,
  questions, abort, and stop and reconnect.
- **`RemoteConnectCheck`:** checks that cancelling or disconnecting while a socket is still
  opening never sends `hello`.

The token store is a stand-in, so real Keychain behavior is not tested here.

## Simulator render

```sh
bash Tests/ShepherdIOSChecks/run-simulator.sh [productsDir] [deviceUDID]
```

Build the `Shepherd iOS` scheme for the simulator first, with
`-derivedDataPath /tmp/shepherd-ios-thread-build`. The script expects the products there by
default. The default simulator UDID is hard-coded in the script, so pass your own.

The script builds a separate fixture app from the production views and an in-memory token
store. It serves a fixed snapshot from a local Python responder that rejects any state-changing
request. Then it launches the app, waits, and takes a screenshot. It asserts that the app made no
terminal `attach`, `input`, or `resize` requests, and that it polled or fetched state.

| Variable | Values |
| --- | --- |
| `FIXTURE_SCREEN` | `fleet`, or the thread (default) |
| `FIXTURE_DIALOG` | `none` (idle thread, composer visible), `select`, `input`, or a confirm question (default) |
| `FIXTURE_UNAVAILABLE` | marks the input question unavailable |
| `FIXTURE_SCHEME` | `light`, or dark (default) |
| `FIXTURE_SHOT` | screenshot path (default `/tmp/shepherd-ios-thread-fixture.png`) |

`screenshots/` holds renders from the September 2026 MVP work: `agents-{dark,light}.png`,
`polished-thread-{dark,light}.png`, `fleet.png`, `native-thread.png`, and `confirm.png`. They
predate the RPC-only host and the macOS redesign. Treat them as history, not as a reference.

## Not yet validated

- A real pi session driven from a phone against the current RPC host.
- Physical-device signing and TestFlight.
- iPad layouts, VoiceOver navigation, and large Dynamic Type.

The September 2026 acceptance run (an XCUITest flow on the simulator) exercised a host that
bridged dialogs through a patched pi. That host no longer exists. Re-run an end-to-end pass
before calling the client validated again.
