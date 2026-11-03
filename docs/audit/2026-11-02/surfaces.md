# Terminal, browser, design and extension surfaces

Baseline `f80d01132`. These are static mechanisms; none of the queue/memory/encoding costs below
has a measured runtime magnitude in this lane.

## SF-01 · P1 · Output backpressure ends before the terminal parser consumes bytes

Path: PTY → `Sources/ShepherdSessions/SessionServer.swift:8037-8110` → main callback →
`Sources/ShepherdApp/TerminalSessions.swift:138` →
`Sources/TerminalSurfaceKit/TerminalSurfaceModel.swift:390` →
`Vendor/libghostty-spm/Sources/GhosttyTerminal/InMemory/InMemoryTerminalSurfaceAccess.swift:86`.
The last step enqueues `Data` on an asynchronous parser queue. Upstream delivery is acknowledged
when the main callback returns, not when the parser consumes it. Remote delivery has the same
boundary (`RemoteHostClient.swift:1405` → `RemoteHostStore.swift:873`).

- Impact: if parser throughput is lower than input throughput, retained bytes and display lag
  can grow behind otherwise bounded upstream queues. One flooding terminal is enough; many
  busy terminals amplify CPU contention. This is not yet a measured memory-growth experiment.
- Fix: carry parser-consumption completion into delivery accounting. An existing
  `InMemoryTerminalSession.receive(_:completion:)` is a candidate, not proof of a drop-in fix:
  its generation-bound completion may currently be skipped.
- Preserve: exactly-once acknowledgement even on detach/replacement, byte order, attach watermarks,
  final output before exit, and queue isolation. Do not block main waiting for the parser.
- Check: inject a slow writer, stream through 1/10/50 terminals, and observe all queues. Require
  a memory plateau, eventual correct final screen and no stranded acknowledgements on teardown.

The host's separate 2 MiB remote reply queue can still disconnect an overrun slow reader. A
complete solution must characterize both socket and parser bottlenecks, not only raise limits.

## SF-02 · P2 · Agent-facing design image encoding remains main-actor work

`Sources/ShepherdApp/ShepherdViewModel+DesignRender.swift:26` enters main-actor
`DesignRendering.draw` (`DesignHost.swift:1403`) and `DesignRenderImage.encode(:28)`.
Its bounded resize/PNG/JPEG loop plus base64 can attempt six PNG and 24 JPEG encodes. Browser
screenshots and exports were offloaded; this sibling tool-result path was not.

- Fix: retain WebKit capture on main, detach encoding/base64 as the browser path does.
- Preserve: byte/dimension caps, MIME, queue serialization, cancellation/deadlines and failures.
- Check: flat/noisy large boards with 1/10/50 queued requests; inspect main-actor stacks and a
  heartbeat, validate decoded output/caps. The maximum encode attempts are not an observed cost.

## SF-03 · P2 · Design thumbnails escape the shared image budget

`DesignHost.swift:763,813` holds `DesignThumbnails.images` and `DesignBoardPictures.images`;
pruning at `:798,850` removes deleted designs, not merely hidden/offscreen ones.
`Pages/DesignsPage.swift:39` → `ShepherdViewModel+Designs.swift:88` schedules catalog thumbnails,
and the reference picker retains up to 24 board pictures per requested design.

- Impact: cache size and startup rendering grow with catalog/picker traversal. Width-only
  downscaling also permits expensive tall aspect ratios. These dictionaries are outside the
  shared canvas `DesignImageCache`; that cache's new limit does not cover them.
- Fix: reuse byte-accounted caching and request visible thumbnails instead of eagerly rendering
  the catalog. Evicted visible entries must be able to reload.
- Preserve: revision/hash invalidation, ownership, remote host boundaries and stable presentation.
- Check: visit 1/10/50 designs with up to 24 boards, including tall boards; navigate away without
  deleting them, require bounded cost and correct revision recovery after eviction.

## SF-04 · P3 · Suffixed assets still enumerate their directory per request

`Sources/DesignSurfaceKit/DesignSchemeHandler.swift:129-143` probes a bare asset ID, then scans
all names to resolve `<id>.<extension>`. #398 removed sorting, not this per-image enumeration.
B subresources against A assets still entail O(A×B) name work. It runs off main, but may delay
readiness and compete for I/O across designs.

- Fix: one per-load filename index, retaining direct bare-ID lookup.
- Preserve: deterministic duplicate resolution, size limits, symlink containment and invalidation
  after imports/writes/deletes. Do not indiscriminately cache mutable files.
- Check: count enumerations for 100/1,000 assets and test rename/delete/duplicates/escaping symlinks.

## Existing improvements and unranked risks

Local output coalesces into 256 KiB chunks, permits one main callback/session and pauses PTY
reads at 4 MiB until 1 MiB. Remote socket writes are nonblocking and bounded. These are useful
protections, but do not include the asynchronous parser queue.

Canvas images now share a 160 MiB soft budget; visible protected entries/newest insertion can
exceed it. Do not repeat the old per-hidden-design budget claim. Hidden designs release live
views; parked browsers sleep after grace and wake for tools; terminal visibility updates retry.
Browser screenshots, PNG/PDF exports and ordinary console traffic are offloaded/batched. Workflow
scripts are precompiled, child persistence coalesces, NDJSON slices once, browser scroll followers
use animation frames, and design size reporting suppresses unchanged dimensions. Rare tools are
deferred and reply buffers bounded.

`Extensions/shepherd-context.ts:287,383` still traverses original messages on provider requests.
Measure 100/1,000/10,000 retained messages before adding another cache. Design/project revisions
were removed from prompt text; actual title/board/memory changes may still alter prefixes, but
provider cache loss is unmeasured and no numerical claim is carried forward from October.
