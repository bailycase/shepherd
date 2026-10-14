# Thread images: checklist and review

> Read when you change images in the thread, the composer's image chips or the image viewer, or review them against the
> boards [ThreadImageOpen](../../boards/ThreadImageOpen.png), [ThreadImagesComposer](../../boards/ThreadImagesComposer.png),
> [ThreadImagesReceived](../../boards/ThreadImagesReceived.png), [ThreadImagesSent](../../boards/ThreadImagesSent.png).

The checklist `docs/design-workflow.md` asks for, then the review of the build against it. Renders come from
`SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter ThreadImagesPreviewTests` (light, dark, text scale 1.3).

## Checklist

| Element | Glyph / token | Strings, from the producer | Controls |
| --- | --- | --- | --- |
| Composer chip | thumbnail 20pt radius 4, `xmark`, `lineStrong` radius 6 (`failed` when over) | name; size `NWByteText` "1.4 MB"; "3.1 MB · over 2 MB"; "Remove <name>" | × removes (24pt hit area) |
| Composer line | `AgentState.failed.textColor`, caption | `ComposerAttachments.error` ("At most 4 images per message.", "<name> is not an image Shepherd can attach.", "This agent does not support image attachments.") else `problem` ("<name> is over 2 MB after resizing. Remove it or send a smaller one.", "The images come to over 5 MB together. Remove one to send.") | Send disabled while `problem` |
| Sent group | `NWThreadMetrics.sent*`, radius 8 `lineSubtle`/`lineStrong` | "Open <name>, <w> by <h>"; "N images you sent"; "Image" chips when no bytes | thumbnail opens the viewer |
| Received group | `proseImageMax*` 384×240, caption `.nw(.caption)` `textTertiary` | alt text; chip "host/path" + "web image · not loaded" | thumbnail opens the viewer; web chip opens the browser |
| Looked-at line | `photo` | "Looked at N image(s)", file names, duration; "Read failed", "Read stopped" | expands as any activity line |
| Viewer header | 44pt `bgWindow`, ghost buttons, `nwIcon` close | name; "w × h · TYPE · size"; "n of N"; "Copy"/"Copied"; "Add to message"; "Show in Finder"; "Close" | Copy, Add to message, Show in Finder, Close, ← → Esc |
| Viewer body | `bgBase` 94%, blur 4pt, a centred row: 36pt round `chevron.left`/`chevron.right` | "Previous image", "Next image"; "Sent by you · Esc to close" / "From the agent · Esc to close" | previous, next |

States drawn: sent (two images with words; four without words, one with a 100-character name), received (two local
images, a web image, a missing file, a remote agent's local-looking path), composer (one fine, one over the limit), looked at,
viewer open (first of two), each in light, dark and at 1.3. States not drawn: an image still decoding (the viewer shows a
`bgSunken` placeholder), an agent without image support (Add to message disabled with its reason).

## Review

Verified by tests: `ThreadImagesTests`, `ThreadImageControlTests` (ControlPress: ×, Send over the limit, thumbnail, Previous, Next,
Copy, Add to message, Show in Finder, Close, with hit areas of 24pt), `ComposerAttachmentsTests`, `ActivityTests`, the store's
`NativeThreadStoreQueueTests` and `NativeThreadStoreTests`.

Measured at 1440×900 against the board: received images at x310–693 and x722–1105 (28pt apart, the board's), viewer image
335 wide and previous/next at about x500 and x906, the board's.

Actual Dev runtime (the checkout's Dev build, scratch support, home and defaults, stub pi): the viewer's toolbar clears the real
window controls with the sidebar shown and hidden, in light and dark, portrait and landscape; thumbnails, Next, Close and the
sidebar toggle were pressed with AXPress, not synthesised events (`dev-*.png` beside this file).

Departures from the boards: the viewer's toolbar is a bounded, centred column that clears the window controls (the user's
correction after seeing the full-width one in the app; renders `thread-image-viewer-window-{wide,board,narrow}` through
`RootView`: 2000×844, 1440×900 and 760×700 with the sidebar hidden, light, dark and 1.3); beyond that, none that the build chooses; each is a fact the code cannot supply without a protocol change.
The measure exception (an image-bearing reply is set at 820pt, as the board sets it, not 640pt) is the board's and is
documented in thread.md.

- "Made N images": only for an image-generation tool by identity (`image_gen`, `imagegen`). Any other non-`read`, non-Browser
  tool whose result carried pictures says "Returned N images". Counts are the image blocks, never a file name.
- Sent thumbnails: this client's own sends use its bytes; another client's, or after a restart, use the host's preview
  (`NativeThreadRequest.images`, `native.images.v1`, at most 160 KiB each), a documented departure in quality, not in layout;
  Copy, Add to message and Show in Finder wait for the original (`imageChunk`, 255 KiB slices) and never use the preview.
- Sizes count in binary megabytes beside the 2 MiB limit (decimal would change the host's limit).
- Glyphs the boards do not settle: `doc.on.doc`, `plus`, `folder`, `chevron.left`, `chevron.right`, `xmark`, `photo`, all outline.
