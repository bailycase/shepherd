# MVP validation

Validated on 2026-09-10 with Xcode beta, iOS 27 Simulator, iPhone 17 Pro. The branch is `feat/ios-native-mvp`. No physical-device provisioning or global pi replacement was performed.

## Results

- All 402 Swift tests passed in the final full run. Log: `/tmp/shepherd-ios-final-repeat.log`.
- Native extension Node/socket checks passed, including rewritten-final-message reconciliation and embedded Swift source identity.
- `Tests/ShepherdIOSChecks/run.sh` passed connection, thread-state, dialog, pagination, and cancelled-handshake checks.
- macOS Dev and iOS 27 Simulator builds passed.
- The prototype pi patch passed root checks and 113 focused tests in its isolated v0.85.1 checkout.
- Fourteen real runtime integration checks passed through Swift RemoteHostClient, SessionServer, the canonical native extension, and a real pi AgentSession with a deterministic faux provider. The dialogs used the real InteractiveMode components and virtual terminal keyboard input.
- The shipping iOS app passed an actual XCUITest touch/typing flow against that real scratch host. The final result bundle reports one passed test and zero failures, about 105 seconds. Bundle: `/tmp/shepherd-ui-acceptance/clean-pass.xcresult`; log: `/tmp/shepherd-ui-acceptance/clean-pass.log`.

The iOS flow saved a synthetic host credential through the real Keychain path, cold-launched and reconnected, opened the host agent, sent text, displayed the reply and expanded tool output, answered select/confirm/input/multiline editor questions, verified each original desktop dialog closed and returned its expected value, cancelled an active faux-provider response, backgrounded/foregrounded, and sent again to the same pi session. The editor check inserted multiline text before an existing prefill and verified both were preserved; it did not test select-all replacement.

## Screenshots

These screenshots contain only synthetic test data:

- [Connected fleet](screenshots/fleet.png)
- [Native transcript and expanded tool output](screenshots/native-thread.png)
- [Standard confirmation](screenshots/confirm.png)

## Issues found during validation

- Fixed cancelled/superseded socket opens authenticating after disconnect.
- Fixed provisional assistant messages surviving after a later pi handler rewrote the persisted final response.
- Fixed a tool disclosure accessibility label masking its expanded output.
- Fixed the embedded extension literal's missing final newline after regeneration.
- An unsigned simulator build failed Keychain access with `-34018`. Xcode signing of the full simulator build with local-only application/keychain entitlements resolved it. Signing only the outer unsigned app caused launch failure.
- A pre-existing worktree-import test failed once in a full run and passed in isolation and the final full run. No assertion was weakened.
- Early scratch UI tests had incorrect text replacement and scroll selection assumptions. Final acceptance ran against a fresh scratch session. An earlier passing test's result bundle was overwritten by a duplicate command, so the reported result is the later independently exported `clean-pass.xcresult`.

## Remaining limits

The host needs the documented prototype pi source patch for standard mobile dialog answers. It is not an upstream release or an automatic install. Native sends are literal text, not the desktop slash-command parser. Custom UI, authentication/project-trust prompts, images, worktree management, and creation are outside the agreed first MVP. External editors temporarily disable mobile answers.

The runtime proof used a real SessionServer and real pi session with virtual terminal rendering, not a full physical desktop CLI walkthrough. Physical iPhone signing, TestFlight, iPad interaction, VoiceOver navigation, and large Dynamic Type remain unvalidated. The UI automation was a temporary local XCTest project; the repository's reproducible fast checks are under `Tests/ShepherdIOSChecks` and `Tests/Extensions`.
