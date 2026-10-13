# Proposal: thread image bytes on demand (pending user approval)

Status: **approved by the user and built** (see [native-thread](../native-thread.md) › Images). Where this differs: the host stores nothing, because pi saves the bytes (verified); the request is `.image(expectedSessionID, imageID, offset)` and the reply `.imageChunk`; the id is `entry|index|hash`; the capability is `native.images.v1` with `images` in `supportedActions`. This is for boards ThreadImagesSent, ThreadImagesReceived and ThreadImageOpen.

## Problem

`RPCThreadState.swift:2322` turns every pi image block into `NativeThreadBlock(kind: .unsupportedImage, text: "[Image unavailable in native thread]")`. The bytes are dropped. The thread shows a bare "Image" chip (`NativeTurnPresentation.swift:156`, `ThreadTurns.swift:103`). Only the sending client's memory (`NativeThreadStore.sentImages`) has the bytes, so thumbnails vanish after a restart, on a remote host, and on a second client.

## Additive change

1. `NativeThreadBlock` gains optional `imageID`, `mimeType`, `width`, `height`, `byteCount`. All default nil and decode with defaults. `kind` stays `.unsupportedImage`, so old clients keep the chip. No bytes in snapshots.
2. New `NativeThreadRequest.image(expectedSessionID, imageID, offset)` and `NativeThreadReply.imageChunk(mimeType, totalBytes, offset, data)`. Chunks are 256 KiB, the size of the design file chunks (`RemoteProtocol.designChunkBytes`). Base64 of one chunk stays far under `NDJSON.maxPayloadBytes` (1 MiB).
3. The host reads the block from pi's session file for that thread's own agent, never from a client path. It validates `imageID` against the session id (stale or unknown gives a typed error). It serves only png, jpeg, gif and webp, and nothing over `NativeImage.maxBytes` (2 MiB).
4. The client reassembles, checks `totalBytes`, caps decoded pixels before making a bitmap, and keeps a bounded cache. One fetch in flight per thread. Thumbnails are decoded from the same bytes with ImageIO.
5. Capability `thread.images.v1` in `supportedActions` and the remote capability set. Without it the client keeps the chip.

## Affected

`Sources/ShepherdProtocol/NativeThread.swift` (fields, request, reply, CodingKeys, both codec arms, `speaksFor`, `replyID`), `Tests/Extensions/native-thread-wire.json`, `NativeThreadWireTests`, `RPCThreadState` projection, a new `SessionServer` handler, `NativeThreadStore` fetch and cache, Mac `ThreadTurns`. iOS is unchanged and keeps the chip. Docs: `docs/native-thread.md`, `docs/remote-protocol.md`.

## Tests

Wire round trip and decode of an old payload. Host integration: restored history, stale id, oversize, non-raster, a chunk under 1 MiB, another agent's id refused. Remote client test. Store cache and cancel test.

## Fallback if declined

Mac-local only: read the session file through `PiSessionFile`. No remote or second-client support. Listed as a departure.

## Meanwhile (no contract)

Saved boards, composer chip states (size label, over-2-MB state, send held until removed), the full-size viewer component and its actions.
