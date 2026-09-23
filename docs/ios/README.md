# Shepherd for iOS (deferred)

`App/iOS` is a remote-only iPhone and iPad client for a Mac running Shepherd. It works, but it is
**later work**. The current redesign is macOS-only, and iOS has not adopted the design system or
most of the Mac's thread features. This page describes the app as the code stands today.

The client connects to a Mac host over the same bearer-token TCP protocol another Mac uses (see
[SECURITY.md](../../SECURITY.md)). Use a trusted LAN or VPN. The connection has no TLS, and the
listener must never be exposed to the internet.

## Build and connect

1. On the Mac, run Shepherd (for development, the `Shepherd (Dev)` scheme). Turn on
   Settings ▸ Remote ▸ Serve this Mac ▸ Listener. The default port is 7433. The token is the
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

## What it is made of

- **Target:** the `Shepherd iOS` Xcode target (iOS 27, iPhone and iPad) compiles the nine files
  in `App/iOS`. It links only `ShepherdCore`, `ShepherdProtocol`, and `ShepherdRemote`, not
  ShepherdUI or `ShepherdApp`.
- **Shared with the Mac:** `RemoteHostClient`, the `NativeThreadStore` thread client, and the
  `NativeThreadPresentation` derivations (turns, tool rows, pill state) are the same code the
  Mac uses.
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
- **Design system:** ShepherdUI (Night Watch) and the handoff's iOS rules
  ([handoff §8](../design-spec/handoff.md), boards in `docs/design-spec/boards/ios/`) are not
  adopted. The boards show attach, timestamps, "Thought for Ns", a context count, and
  Shells/Settings tabs. The app has none of these.
- **Approval wording:** confirm questions are labeled "Allow once / Deny" and blocked agents
  "needs approval". The handoff says there is no approval UI, only questions.

## Stale code to clean up when iOS resumes

- `ThreadView` shows "Questions need the pi dialog bridge on your Mac" when a snapshot reports
  `dialogsSupported == false`. Current hosts always report `true`, so only an older host can
  trigger it. Several comments still describe that bridge and claim the snapshot has no
  timestamps or durations; it does.
- `ThreadDialogView` has an `external-editor` unavailable branch that the RPC host never
  produces. The host only uses `payload-limit`.
- `MobileTokens` refers to `NativeTokens` in a comment. That type no longer exists.
