# Prototype pi dialog API

These patches target https://github.com/earendil-works/pi.git at tag `v0.85.1`, commit `d981de1229ef899957bbe968bc8dcda02a21f477`. They are source changes for an isolated development checkout, not a patch to the global npm installation. They have not been submitted or released upstream.

- `dialogs-v0.85.1.patch` adds the dialog API, documentation, and behavioral tests.
- `vitest-uuid-alias.patch` supplies a missing source alias needed to run tests from this tag without compiled workspace output. It is separate from the dialog behavior.

## Apply and validate

In a new source checkout at the exact tag:

```sh
git apply /path/to/Shepherd/docs/ios/pi-dialog-bridge/dialogs-v0.85.1.patch
git apply /path/to/Shepherd/docs/ios/pi-dialog-bridge/vitest-uuid-alias.patch
npm ci --ignore-scripts
npm run hydrate:model-data
npm run check
cd packages/coding-agent
node ../../node_modules/vitest/dist/cli.js --run \
  test/extension-dialogs.test.ts \
  test/suite/regressions/5943-session-start-notify.test.ts \
  test/extensions-runner.test.ts test/external-editor.test.ts \
  test/interactive-tui.test.ts test/interactive-mode-status.test.ts
```

The model-data hydration task retrieves public metadata into ignored files. Initial validation instead used the matching installed pi-ai 0.85.1 metadata as a read-only source. No account data or credentials are needed for these tests. Root checks and 113 focused tests passed in the isolated development checkout.

For development, source CLI execution works through the checkout's tsx and source aliases:

```sh
./node_modules/.bin/tsx --tsconfig tsconfig.json packages/coding-agent/src/cli.ts --version
```

A local wrapper named `pi` on an isolated Dev app's PATH can invoke that command with absolute checkout paths and forward its arguments. Do not replace the everyday global executable. A packaged distribution and upstream integration remain separate work.

## API

`ctx.ui` gains:

```ts
getPendingDialogs(): readonly PendingDialog[];
onDialog(listener: (event: DialogEvent) => void): () => void;
resolveDialog(id: string, answer: DialogAnswer): "accepted" | "stale" | "invalid";
```

Pending dialogs carry an ID, kind, title, and the appropriate choices, message, placeholder, or prefill. Events are opened, updated, and closed. Answers are typed select/confirm/input/editor values or cancel. Empty text is a valid answer. Subscribe before taking a snapshot, reconcile by ID, and tolerate already queued notifications after unsubscribe.

The interactive mode owns the registry and mounts the existing desktop components. Desktop submission, cancellation, caller abort, timeout, and remote answers share synchronous settlement. The first valid answer wins. Invalid answers leave the question open. Reset/stop invalidate pending IDs and remove listeners.

Only standard extension dialogs are exposed. Internal direct dialogs, project trust, authentication, and custom components are excluded. Other run modes return empty/no-op/stale and keep their existing behavior.

## Limits

Overlapping standard dialogs reject with `Extension dialog busy` rather than replacing an active component. When Ctrl+G launches an external editor, the pending editor has `unavailable: "external-editor"`; remote answers and cancellation return invalid until it exits. Reset invalidates its ID but does not kill the external editor process. New standard dialogs remain busy until the child exits; late child results cannot overwrite a closed dialog or restart a stopped TUI.

The patch is validated with real interactive dialog components, virtual terminal input, and faux-provider sessions. It does not establish physical-terminal or Windows external-editor compatibility. Keep this dependency explicit when distributing the mobile MVP.
