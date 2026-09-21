# Mobile UI polish

Fable 5.1 implemented the visual pass. Both delegated runs timed out before a final handoff; the parent reviewed the resulting source and completed validation directly.

## Changes

- System-face chat prose and headings, with monospace code and metadata.
- Quiet user-message panels and unboxed assistant replies.
- Inline Markdown, headings, lists, and horizontally scrollable fenced code.
- Compact expandable tool and thinking rows.
- Pinned composer with separate send/stop controls and a delivery menu.
- Standard questions in outlined panels with explicit answer buttons.
- Clearer fleet rows and labeled host settings.

The mobile design exception is recorded in `DESIGN.md`. Desktop styling and the native protocol/store behavior are unchanged by the visual pass. The Markdown renderer is intentionally lightweight, not a complete CommonMark implementation.

Parent review corrected masked user-message accessibility, disclosure accessibility values, Reduce Motion handling for the working indicator, simultaneous working/question presentation, misleading delivery timing labels, and prominent-button foreground contrast.

## Second pass

A later Fable 5.1 pass, reviewed and adjusted by the parent, tightened the iOS thread: tool and thinking rows share an icon column and inline chevron, code blocks and text widgets share one panel treatment, status widgets render on one line, dialog buttons match the prose scale, the composer field shows a focus border with a hairline above the bar, and fleet/settings metadata use the secondary ramp. Review fixes restored 44pt touch targets on disclosure rows and dialog cancel, and made the composer-focus scroll respect Reduce Motion. The same pass restyled the desktop native view; see `docs/desktop-native.md`.

## Validation

- `bash Tests/ShepherdIOSChecks/run.sh` passed connection, thread-state, dialog, and cancelled-handshake checks.
- Signed iOS 27 simulator build passed.
- Production-view fixture compiled and rendered over TCP in dark and light appearances without terminal attach/input/resize frames.
- Screenshots inspected: [dark](screenshots/polished-thread-dark.png), [light](screenshots/polished-thread-light.png).

These fixture checks validate rendering and polling, not a fresh end-to-end touch run against patched pi. The earlier MVP touch acceptance is recorded separately in `VALIDATION.md`. Full VoiceOver navigation, larger Dynamic Type, and iPad interaction still need manual review. Changes remain uncommitted.
