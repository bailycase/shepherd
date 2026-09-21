# iOS MVP

Shepherd iOS requires iOS 27. It connects to a running Mac host over the existing bearer-token TCP connection. Use a trusted LAN or VPN. The transport does not use TLS and must not be exposed to the internet.

## Build and connect

1. Build and run the current `Shepherd (Dev)` scheme on the Mac. Enable its listener in Settings > Remote. Existing agents need to restart to load the new native bridge extension.
2. Build the `Shepherd iOS` scheme for an iOS 27 simulator or device. A physical device requires your own Xcode development team and provisioning. No team is configured in the repository.
3. In the mobile app, enter the Mac's reachable hostname or IP address, listener port, and bearer token. The simulator can use `127.0.0.1` for a host on the same Mac; a physical phone must use the Mac's LAN or VPN address.
4. Open an agent from the fleet list. Both clients control the same pi process. The mobile app does not create another pi process or attach a terminal viewport.

Simulator compile check without signing:

```sh
xcodebuild -project Shepherd.xcodeproj -scheme 'Shepherd iOS' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

That command checks compilation only. An unsigned simulator build can fail Keychain access with error `-34018`. To exercise connection setup, run a normally signed development build from Xcode. For local simulator automation, let Xcode sign the complete build using `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGN_ENTITLEMENTS=/path/to/simulator.entitlements`. The entitlement file needs an `application-identifier` and matching `keychain-access-groups`. Signing only the outer `.app` after an unsigned build was insufficient for the debug-dylib launch path. The validation build used the simulator-only identifier `LOCALONLY.com.bailycase.shepherd.ios`; this is not a real Apple development team and cannot provision a phone.

Mobile saves one host's name/address/port in UserDefaults. Its token is stored separately in device-only, when-unlocked Keychain storage. Backgrounding disconnects the mobile client; the host agent continues. Returning to the foreground reconnects and fetches current history and questions.

## Included

- Native text, thinking, tool output, and compaction/branch summaries.
- Paged older history and live updates while the thread is open.
- Follow-up or steering messages and agent cancellation.
- Native select, confirm, input, and multiline editor answers when the host pi provides the dialog API below.
- Explicit, keyed text/status widgets from [Shepherd-aware extensions](../native-ui-widgets.md).
- Connection errors and stale-action handling. Unknown-outcome actions are not automatically retried; check the thread before submitting again.

An accepted action means pi accepted synchronous API dispatch, not that the response finished or the message was persisted. Messages are literal text; built-in desktop slash commands are not interpreted by the mobile composer. Cancel uses pi's normal abort behavior, which may restore queued prompts into the desktop editor.

Worktree management, creation, diff review, arbitrary custom TUI controls, and image rendering are outside this MVP. Images appear as explicit placeholders. Output is clipped at 16 KiB per entry, with pages of up to 50 visible entries and an encoded snapshot limit below 256 KiB. The full session remains on the host. The open thread polls every 500 ms while active or waiting, otherwise every two seconds. Hidden/background threads do not poll.

## Presentation

The phone follows the design spec in `../design-spec/` (page 9 §8 and the page 4–6 artboards). `App/iOS/MobileTokens.swift` holds the same light/dark hex values as the desktop's `NativeTokens`, kept local so the iOS target never imports the Mac app module, plus the phone type ramp (body 16 ×1.5, bubble 15, tool rows 12 mono, title 16/600, micro 11 mono). Turn grouping, tool rows, DiffStat, durations, the status pill, the collapsed group summary and head truncation come from `ShepherdRemote/NativeThreadPresentation.swift`, shared with the desktop.

- Agents list: host section header with a Connected / Connecting / Unreachable pill, 56pt rows (title + one-line status in micro mono, chevron), "Show N more" past five rows, an Automations section, and a dimmed card with Retry when the host is unreachable (cached rows stay visible but cannot open). The status line shows the state word and the space name only; the current tool and elapsed time are thread-snapshot data the fleet state does not carry, so they are omitted rather than faked.
- Thread header: back · title (label/600) with a status line beneath (dot + pill text, no fill, "· N turns" once the full history is loaded) · Stop (danger) while running or waiting · options menu (delivery, refresh).
- Body: user turns are trailing bubbles (15pt, radius 14 with a 4pt bottom-trailing corner), agent prose is 16pt at ×1.5, thinking is a collapsed disclosure, and consecutive tool calls collapse into one 44pt summary row ("6 tool calls · read 1 · edit 3 · bash 2"). Expanded rows are 40pt with head-truncated paths; bash rows and any row with saved output push a full-screen output view. The footer shows only the tool count.
- Composer: pill field (44pt minimum, radius 22, grows to five lines) with the Send circle inside; Send becomes Stop while running or waiting when the draft is empty. A "Waiting for you" slot appears while a question is pending and re-opens the sheet if it was swiped away. The gutter is 16pt.
- Approval: a bottom sheet (`.sheet` with medium/large detents, grabber, radius 20, system scrim) with stacked 50pt actions: confirm → Allow once / Deny, select → stacked options, input/editor → field + Submit, plus a plain Cancel. "Always for this agent" appears only when a select option literally offers it.
- Touch targets are at least 44pt. Reduce Motion replaces the spinner with a pulsing dot and disables expand animations.

### Substitutions and spec items not honoured

- Fonts: IBM Plex Sans / JetBrains Mono are not bundled; system sans and system monospace at the spec sizes.
- No attach icon: the bridge has no attachment support, so the affordance is omitted rather than disabled.
- No timestamps under bubbles, no turn durations, no "Thought for Ns", no "Nk" context count: the bridge does not carry them.
- No per-row durations or live elapsed on the phone: the fleet state and snapshot carry no start times.
- The scrim is the system sheet dimming, not exactly 32% text.primary.
- No local notification when approval is needed while backgrounded (the app disconnects on background).
- Shells and Settings tabs from the artboard are not present; Settings remains a sheet behind the gear button.

The screenshots in `screenshots/` were re-captured after this restyle from the simulator fixture: `polished-thread-{dark,light}.png` (thread with the confirm sheet open) and `agents-{dark,light}.png` (the Agents list, via `FIXTURE_SCREEN=fleet FIXTURE_DIALOG=none`). `FIXTURE_DIALOG=none` renders an idle thread with the composer visible.

## Standard dialog dependency

Unmodified pi 0.85.1 supports native history, message dispatch, and cancellation through its extension API, but not remote answers to its desktop dialogs. It emits only a waiting notification, not a complete question and resolver.

The prototype patch in [pi-dialog-bridge](pi-dialog-bridge/README.md) adds a public dialog snapshot/listener/resolver API. Shepherd feature-detects it. Without it, mobile explicitly reports that dialog answers are unavailable; it does not monkey-patch pi's UI or silently send an answer as a new prompt.

Desktop and mobile answers share first-wins settlement. An answered, cancelled, or expired question cannot be answered again. Custom UI and authentication/project-trust prompts are not exposed by this API. If the desktop multiline dialog launches an external editor, mobile answers are disabled until that editor exits.

The pi patch is not an upstream release and is not installed automatically. Your global pi installation is never rewritten by building Shepherd.

## Checks

```sh
env -u SHEPHERD_SUPPORT_DIR swift test
node --test Tests/Extensions/shepherd-native.test.mjs
bash Tests/ShepherdIOSChecks/run.sh
```

`Tests/ShepherdIOSChecks` compiles the production connection/thread owners against a local responder and tests observable state, answers, reconnect, and zero-byte cancelled handshakes. Its token substitute does not validate real Keychain operations. `run-simulator.sh` renders production thread views with a controlled fixture; it is not a replacement for exercising the shipping app against a real pi session.
