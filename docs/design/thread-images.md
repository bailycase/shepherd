# Thread images

> Read when you change how images look in a thread: the composer's chips, the full-size viewer, the thumbnails in a sent message, or an image the agent made.

Boards: ThreadImagesComposer, ThreadImageOpen, ThreadImagesSent, ThreadImagesReceived
(`docs/design/boards/`, saved as given). Status per part below.

## Composer chips (built)

Chips above the card with a thumbnail, name, size and ✕, an over-limit image kept red and holding
Send. Specified under [composer](composer.md) › Images and files. `ComposerImageStrip` draws them
from `ComposerAttachments`; `SHAttachmentChip(detail:problem:open:remove:)` is the chip.

## Viewer (built; the user's floating modal, replacing ThreadImageOpen's full-window layout)

`SHImageViewer` floats over the thread (`ImageViewerOverlay`, state in `ImageViewerState`, one at a time). The user chose this
over ThreadImageOpen's full-window view and over a windowed card (2026-10-17): the thread stays in view, dimmed by `sheetScrim`
(black at 55%, as other modals), and the picture floats on it.

- **Picture**, centred, at its fitted size and never enlarged, in the window less 64pt all round
  (`SHImageViewerMetrics.margin`) after the arrows and the pill. Radius 8, a `lineSubtle` line and the popover shadow.
- **‹ ›**, with more than one image: 36pt `bgRaised` discs with a `lineSubtle` ring and a 14pt chevron, 16pt either side of the
  picture; the one with nowhere to go is drawn disabled.
- **Pill**, 12pt under the picture, a 44pt `.shPopover` capsule: "1 of 2" in mono `textTertiary` (only with more than one image),
  then **Copy** (`doc.on.doc`), **Add to message** (`plus`), **Show in Finder** (`folder`) as 28pt ghost icons with 14pt glyphs
  and their names as tooltips, and the 28pt round **Close** (`xmark` 12pt, `lineStrong` ring). The user's call: no name, type,
  resolution or byte size is drawn. VoiceOver still reads the name, its facts and "Sent by you · Esc to close".
- **Closing.** Esc, Close, or a click on the scrim. ← → step. Keys go to a hidden focus target, so no control inherits a keyboard
  ring. Copy puts the image on the pasteboard. Add to message puts the shown image in the composer and closes; it is drawn only
  where there is somewhere to add it. Show in Finder is drawn only for an image that came from a file.
- **States** use the existing components: loading is the `bgSunken` field with a spinner; failed is a raised card with the reason
  ("Couldn't reach the host.", "The connection was interrupted.", "This image can't be shown.") and **Try again**.
- **Diagrams** (Mermaid, [thread](thread.md)) open in the same viewer: the chart takes all the room, with Copy for its source.
- `ThreadImagesControlTests` measures the 28pt close and 36pt arrows, the pill's place, and presses every control and the scrim.

## Sent and received (built, for a host that serves images: `native.images.v1`)

Bytes come from pi's own saved history ([native-thread](../native-thread.md) › Images), so they are there after a
reload, on another Mac, and on a second client. A host without them leaves the "Image" chips.

- **Sent (ThreadImagesSent).** Thumbnails above the bubble, trailing, 6pt apart, each at its own shape inside 240 × 180
  (never past its own size), radius 8, a `lineSubtle` line; a `bgSunken` field holds each place while it loads. The
  bubble's own chips go when every image is named. "Sent by you" along the bottom of the viewer.
- **The summary line is a neutral count: "1 image", "2 images"** (the user approved this in place of boards 79 and 80's "Looked at 2
  images" and "Made 2 images"). It is the existing activity line with the `photo` glyph (`SHActivityLine.Kind.images`), its label
  `nativeCount(n, "image")` and no meta. It appears under a sent message's bubble (`UserTurn`, counting only images the host named)
  and above an agent's or a tool's pictures (the `images` item). No verb and no file names: pi's saved image block has only `type`,
  `data` and `mimeType`, so neither "Looked at" versus "Made" nor the names in the boards' lines exist in any data the host has. A message
  whose images the host did not name keeps its "Image" chips and shows no count.
- **Received (ThreadImagesReceived).** An agent's or a tool's images where they happened, inside 384 × 240, 12pt
  apart, wrapping, under the neutral count.
- **Source gaps, not approved by the user** (the data does not exist, so they are not drawn; they are not UI mismatches): the file
  names in the boards' summary lines, the agent's caption under each received picture (pi saves no alt text), and the board's web-image
  chip ("grafana.internal/d/refunds.png · web image · not loaded"). `SHThreadImageChip` can draw that chip, but nothing produces one: no
  producer parses an agent's prose or a tool result into a web-image reference, and Shepherd never fetches a web image.
- **Press** a thumbnail to open the viewer on that message's images at that one; ‹ › step through them and each
  is fetched as it is reached (the next one ahead of time).
- **States.** Loading: the field, no motion. Failed (the connection, a session that moved on): the box says
  "Couldn't load" and **Retry**, which is the box's one control. Gone (the host no longer has it, or does not offer
  it): the chip "<name> · not available", plain text. In the viewer: a spinner field, "This image can't be shown." or
  the host's reason, and **Try again**.
- **Bounds.** Types png, jpeg, gif, webp; at most 2 MiB and 4096 × 4096 (a header check before any bitmap); four fetches
  at once; 24 MiB held. Copy and Add to message use these bytes: Add to message puts the image in the composer
  under the same limits, with no file behind it (so no Show in Finder).
