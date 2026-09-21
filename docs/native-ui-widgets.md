# Native text and status widgets

Shepherd-aware pi extensions can explicitly publish keyed, display-only items to native Mac and iOS threads. These are live session state, not transcript messages. Terminal remains the default on Mac. The app controls placement, fonts, and colors. Text is literal, including Markdown and HTML-looking strings. No buttons, callbacks, layout trees, images, styling, or arbitrary UI execution are accepted.

This uses pi's in-process `pi.events` API, not a new socket or a global pi patch. Shepherd installs its request subscription at `session_start` and removes it at shutdown. Without `pi.events.on` and `pi.events.emit`, the existing bridge still provides history/send/abort. The widget producer should keep its terminal fallback.

Standard select/confirm/input/editor questions still use `ctx.ui` and the [existing isolated dialog patch](ios/pi-dialog-bridge/README.md). Their settlement and external-editor rules are unchanged. Widgets cannot ask questions or answer dialogs. Shepherd does not patch `ctx.ui.setStatus`, `ctx.ui.setWidget`, or custom widget factories.

## Event contract, version 1

Emit data on `shepherd:native-ui:request`. Subscribe first to `shepherd:native-ui:response` and correlate by a unique `requestID`. The action discriminator is `type`; `kind` describes the displayed item.

```ts
{ version: 1, requestID: "unique-id", type: "capabilities" }
{ version: 1, requestID: "unique-id", type: "set",
  namespace: "my-extension", key: "build", kind: "status",
  title: "Build", text: "Focused checks passed" }
{ version: 1, requestID: "unique-id", type: "set",
  namespace: "my-extension", key: "notes", kind: "text", text: "Plain text\nNext line" }
{ version: 1, requestID: "unique-id", type: "clear",
  namespace: "my-extension", key: "build" }
```

A successful set/clear response is `{version:1, requestID, ok:true}`. Capabilities additionally returns `kinds:["status","text"]` and this `limits` object:

```json
{"namespaceBytes":128,"keyBytes":128,"requestIDBytes":128,"titleBytes":256,"textBytes":4096,"items":16,"aggregateBytes":32768}
```

Namespace, key, and requestID must be nonempty strings within their UTF-8 byte limits. `text` must be a string, including the empty string if needed. `title` is optional and must be a string when present. The aggregate limit counts the UTF-8 bytes of the JSON-encoded widgets array, including metadata and escapes. It is not a sum of visible character counts. All 16 items and the aggregate budget are shared by the agent's extensions, not granted per namespace.

Invalid requests return `{version:1, requestID, ok:false, error:{code:"invalid", message}}`. Oversized text/title, a seventeenth item, or an aggregate overflow returns code `limit`. A missing, non-string, or oversized requestID is returned as `null`. Validation never throws into pi. Rejected replacements leave the previous item unchanged. No accepted item is silently evicted or truncated.

Set replaces only the same `(namespace,key)` pair, retaining its order. Different namespaces can use the same key. Clear removes only that pair; clearing an absent pair succeeds. Namespaces prevent accidental collisions, not malicious writes by another in-process extension. Items survive Shepherd socket reconnects, but reset at session start, shutdown, session-ID change, or a session-tree generation change. They are never persisted. Republish from current extension state after those resets, not from an automatic transport retry loop.

Replies acknowledge in-process storage, not that a device displayed the item. There may be no native viewer. A producer should bound how long it waits and unsubscribe its response listener. Older bridges simply never respond. Use a unique requestID per attempt. On error or timeout, keep the already-published terminal fallback; do not append a second fallback or automatically retry an unknown outcome. Existing thread polling carries widget changes through the snapshot revision and the same bounded payload. Old clients ignore the additional field. New clients treat missing `widgets` as empty and skip unknown future kinds.

## Producer example

[The standalone example](examples/native-ui-widgets.ts) registers `/native-widget-demo`. Load it explicitly in a scratch pi session with `-e`; it is not installed by Shepherd. It publishes the terminal status/widget once, then sends the corresponding native items. It reports explicit native rejection without publishing the fallback twice. It uses only `node:crypto` and pi's extension API.

To remove a published item, send `clear` for its namespace/key and clear the matching terminal fallback through the normal pi API. To query bounds before producing content, send `capabilities`. Do not split rejected content into more items to bypass the shared budget.

## Checked fixtures

`Tests/Extensions/shepherd-native.test.mjs` exercises the real scratch socket with a mocked pi event bus, including namespace isolation, rejected replacement, count/byte budgets, reconnects, reset, and absent-bus behavior. It retains the standard-dialog checks.

`NativePresentationTests.nativeWindowStopsPollingWhenHiddenAndRendersStandardQuestions` includes one status caption and one text panel in its controlled Mac snapshot. `Tests/ShepherdIOSChecks/run-simulator.sh` uses the same two items with production iOS views and a scratch TCP responder. Neither fixture requires a model call, real credentials, or an installed pi modification.
