> Lane report from the 2026-10-27 audit. Static reading only (no build, no run) by a Claude (fable-5-1) agent; line numbers are from commit d28f3511c. Live confirmation of overlapping items is in [live-usage-mac-ios.md](live-usage-mac-ios.md); the cross-lane ranking is in [README.md](README.md).

# Surfaces & extensions lane — performance/quality audit (SE)

Scope: `Sources/TerminalSurfaceKit`, `Sources/DesignSurfaceKit`, `Sources/ShepherdApp/Browser*.swift`,
`Extensions/*`, `Vendor/libghostty-spm`, `scripts/context-budget.json`, `docs/context-budget.md`.
Static reading only; nothing was built or run. Severity = user impact. Line numbers are from the
checkout at audit time.

---

## Findings (ranked)

### SE-01 · high · Browser screenshot encodes up to 24 JPEGs on the main thread
- `Sources/ShepherdApp/BrowserDriver.swift:337-340` → `BrowserImageClamp.encode(image)` then `base64EncodedString()`; `BrowserAgentRules.swift:476-490` loops `0...maxShrinks` × `qualities` (6 × 4), each a `CGContext` resize + `CGImageDestinationFinalize`.
- `BrowserSession` is `@MainActor`, and `screenshot()` is a method on it, so every encode, resize and the 300 KB base64 run on the main thread while the UI is blocked.
- User sees: a hitch (hundreds of ms on a 1280-px tall page that needs several shrink steps) every time an agent calls `browser_screenshot`; with several agents screenshotting, typing in the composer/terminal stutters.
- Fix: `let encoded = await Task.detached { BrowserImageClamp.encode(image) }.value` (CGImage is immutable); base64 inside the same detached task. One line change at `BrowserDriver.swift:337`.

### SE-02 · high · Design PNG/PDF export rasterises and encodes 64 MP bitmaps on the main actor
- `Sources/DesignSurfaceKit/DesignBoardExport.swift:48-69` (`image(scale:)`): after `takeSnapshot`, allocates a `CGContext` up to `maxImagePixels` (64 M px → 256 MB) and `context.draw` on the `@MainActor` class. `DesignBoardExport.swift:170-200` (`DesignPDF.compose`) draws every page through CoreGraphics on the same actor. `DesignHost.swift:1427-1428, 1496-1504` then call `DesignImageFile.png(image)` (`DesignBoardExport.swift:240`, full PNG encode) from `@MainActor enum DesignExporter`.
- User sees: the whole app freezes for the duration of an Export (seconds for a 2× export of a tall flow board), spinner stops, terminals stop painting.
- Fix: wrap the resample + PNG encode and `DesignPDF.compose` in `Task.detached` (inputs are `CGImage`/`Data`, outputs `Data`), awaiting from the main actor. No API change.

### SE-03 · medium · Page `console.*` is forwarded line-by-line with no batching; each line is an IPC + Observation mutation + O(500) shift
- JS: `Sources/ShepherdApp/BrowserScripts.swift:28-37` wraps `console.log/info/debug/warn/error` and posts one `postMessage` per call, synchronously, unthrottled. Native: `BrowserHost.swift:982-997` → `BrowserConsoleLog.append` (`BrowserModel.swift:158-167`) does `lines.append` + `removeFirst` when > 500 (array shift each line past cap) + `Calendar.dateComponents` per line, and each append is an `@Observable` mutation that re-diffs `BrowserConsoleLines` (500 rows).
- User sees: a dev page with a chatty HMR/analytics loop (hundreds of lines/s) makes the Browser pane and the rest of the window stutter; the parked (hidden) page does this too since the shim runs in every page.
- Fix: in `pageShim`, queue lines and flush with one `postMessage({lines:[…]})` per ~50 ms (cap the queue at 500); in `BrowserConsoleLog` add `append(contentsOf:)` and trim once per batch. Keep per-line semantics for `error`.

### SE-04 · medium · `shepherd-workflow.ts` worker compiles and runs a `vm.Script` 100×/s for up to 30 minutes
- `Extensions/shepherd-workflow.ts:45` `run = (code) => new vm.Script(code).runInContext(...)`; `:67` `setInterval(flush, 10)` → `run("drain()")` compiles a fresh `Script` every 10 ms until the workflow ends (deadline `timeoutMs = 30 * 60 * 1000`, `:71`).
- User sees: a background core pegged at a few % per running workflow (and several at once add up), fans, battery; it is in a `Worker` so it does not block pi, but it competes with the child pi processes the workflow is waiting on.
- Fix: compile `drain` once (`const drain = new vm.Script("drain()")`), and raise the interval to 50–100 ms, or better run `drain()` immediately after each `receive()` plus a 250 ms safety tick (the only time new outbox entries appear is after script execution).

### SE-05 · medium · `shepherd-children.ts` writes `status.json` synchronously on every child tool start/end and republishes all cards
- `Extensions/shepherd-children.ts:843-848, 849-876` call `save(run)` on each `tool_execution_start` and `tool_execution_end`; `save` (`:670-688`) does `writeFileSync` + `renameSync` (`atomic`, `:115-119`), optionally reads+rewrites the mission JSON, then `publish()` (`:629-636`) which builds `card()` for up to 20 runs and emits an event that `shepherd-subagents.ts:67-70` re-`JSON.stringify`s to compare.
- User sees: with several busy children (each doing a tool call per second or faster) the parent pi's event loop blocks on disk I/O between child stdout reads; the parent's own streaming reply to the user hitches and child cards in the sidebar lag.
- Fix: debounce `save(run)` per run (trailing 250 ms) except for state transitions (`finish`, `stop`, needsReply) which flush immediately. Keep `publish` on the 1 s tick (`:642`) which already exists.

### SE-06 · medium · `jsonLines` child-stdout framer is O(lines × buffer) per chunk and re-measures bytes of the whole buffer
- `Extensions/shepherd-children.ts:96-113`: for each `\n`, `Buffer.byteLength(buffer.slice(0, end))` + `buffer.slice(end + 1)` (copies the remainder); after the loop `Buffer.byteLength(buffer)` on the whole partial frame. In RPC mode a child emits a `message_update` per streamed delta, so a 64 KB chunk can hold hundreds of lines.
- User sees: parent CPU scales with the square of child chattiness; a child streaming a long answer makes the parent stutter.
- Fix: track a `start` index and `indexOf("\n", start)`; slice once per chunk (`buffer = buffer.slice(start)`) at the end; measure `line.length` (UTF‑16) against the 8 MiB cap, converting to bytes only when `line.length > MAX_FRAME / 4`.

### SE-07 · medium · Design / Project system-prompt blocks change every turn, defeating the provider prompt cache
- `Extensions/shepherd-design.ts:388-403` fetches a full `designRead` snapshot over the socket before **every** turn (3 s timeout) and appends `designFacts` (board list, titles, systems; `:1444-1500`) to the system prompt. `Extensions/shepherd-project-context.ts:231-262` does a socket `read` per turn and embeds `revision: project.revision` plus up to 8 000 bytes of memory in the system prompt.
- User sees: every board write or project mutation changes the system prompt, so the next request re-sends and re-caches ~8 k+ tokens of prompt + tool definitions (money and first-token latency on cached-prompt providers); plus one socket RTT per turn even when nothing changed.
- Fix: move the volatile data out of the system prompt and into a `pi.sendMessage({customType, display:false})` / `context` injection at the *end* of the message list (the cache prefix stays stable), or drop `revision` from the brief and cache the facts until `designWritten`/`project` events say they changed.

### SE-08 · medium · Picked-element `scroll` follower posts to native on every scroll event
- `Sources/ShepherdApp/BrowserScripts.swift:204-211`: `window.addEventListener('scroll', follow, {capture:true})` with `follow` calling `show(picked)` (which rebuilds both `cssText` strings in `paint()` each time) and `post({kind:'rect'})` per event. Native `BrowserHost.swift:581-583` → `pickedRect` mutation → `BrowserPageArea` re-layouts the popover (`BrowserPane.swift:302-316`) each time.
- User sees: while an element is picked, scrolling the page is janky (60–120 IPC/s + SwiftUI layout per frame).
- Fix: coalesce `follow` with `requestAnimationFrame` (one post per frame max) and only `paint()` when colors change.

### SE-09 · medium · Ghostty surface ready-check polls the full viewport text every 10 ms and walks every window's view tree
- `Sources/TerminalSurfaceKit/TerminalSurfaceModel.swift:417, 426-439`: `confirmSurfaceReady` runs up to 50× at 10 ms, each calling `session.readViewportText()` (`Vendor/.../InMemoryTerminalSession.swift:103-138`: `ghostty_surface_read_text` + a `[UInt8]` copy + `String`) and `self.surfaceView` (`:442-447`) which does a recursive `search` of every `NSApp.windows` content view (`TerminalSurfaceView.swift:166-184`). `observeSelection` (`:453`), `copySelection` (`:470`) and `applyKeyboardFocus` (40 × 25 ms, `:306-336`) repeat the tree walk.
- User sees: on launch/space switch with many mounted agent layouts (14+ sibling hosts per the comment at `TerminalSurfaceView.swift:146`), every terminal appearance spends up to 0.5 s of 100 Hz main-thread polling; focus retries add another 1 s of tree walks.
- Fix: cache the found `AppTerminalView` weakly in the model once (set on first successful `search`, cleared in `surfaceViewDisappeared`), and check readiness with a cheap `session.currentSurface != nil` (vendored, `InMemoryTerminalSession.swift:80`; make it `public` in the vendor copy) instead of reading the viewport.

### SE-10 · medium · `agent_wait` polls the Shepherd server every 250 ms per waiting agent
- `Extensions/shepherd-panes.ts:650-668`: loop sends a `coordinateAgent{status}` socket request, then sleeps `min(250, …)` ms, for up to 120 s.
- User sees: each waiting agent adds 4 server-queue round trips/s (the status reply walks the target's live context); several coordinators waiting on each other turn into a small CPU hum on the main app.
- Fix: back off (250 → 500 → 1000 ms, cap 1 s), or have the server hold the request until idle/timeout (one request instead of up to 480).

### SE-11 · medium · Parked browser pages keep painting and running rAF for every thread forever
- `Sources/ShepherdApp/BrowserHost.swift:716-731, 752-770`: a hidden page is moved into a borderless, on-screen (`orderBack`, alpha 0.01) `BrowserParkWindow` "so it lays out, runs timers and animation frames"; nothing ever orders it out while the agent is not driving it. `BrowserSessions` (`:150-230`) only closes a session when its agent is removed.
- User sees: N threads that ever opened a dev server = N WebContent processes rendering at full rate (HMR, animations, canvas) in the background; CPU/battery drain unrelated to what is on screen.
- Fix (bounded): `parkWindow.orderOut(nil)` when `hostRequestsInFlight == 0 && agentOverlay == nil` after a short grace, and `orderBack` on the next `performPage`/`snapshotImage`. WebKit then throttles timers/rAF itself. Needs runtime confirmation that `takeSnapshot` still works after re-ordering (it should; `afterScreenUpdates = true`).

### SE-12 · low · Pixel-only Ghostty resizes are forwarded (main hop + server hop) during divider drags
- `TerminalSurfaceModel.swift:176-183` constructs `InMemoryTerminalSession` without `suppressesPixelOnlyResizes`; the vendor comment (`InMemoryTerminalSession.swift:22-31`) measured ~78 % of drag updates as pixel-only. Each one → `deliverResize` → main queue → `handleResize` (`:519`) → `onResize` → `server.reportLocalViewport` (`TerminalSessions.swift:515-521`) → server queue. The server dedupes same-grid (`SessionServer.swift:3072-3078`), so no SIGWINCH, but the two hops per layout tick remain.
- User sees: slightly busier main thread while dragging a split that contains terminals.
- Fix: pass `suppressesPixelOnlyResizes: true` (Shepherd only consumes `columns`/`rows`).

### SE-13 · low · `TerminalSurfaceModel` is `ObservableObject` + `@ObservedObject` (rule: `@Observable`)
- `TerminalSurfaceModel.swift:115`, `TerminalSurfaceView.swift:7`. No `@Published` properties, so there is no invalidation storm, but the `@ObservedObject` wrapper still subscribes and `Combine` is imported only for `viewState.$isFocused` (`:197`).
- User sees: nothing measurable today; it is a rule violation that a future `@Published` would turn into a per-keystroke redraw of every mounted pane.
- Fix: drop `ObservableObject`/`@ObservedObject` (the view only needs the reference); keep the Combine sink on the vendored `TerminalViewState`.

### SE-14 · low · `tools.children` (1 687 tokens) is the largest kept tool group; `shepherd_workflow` alone is ~300 tokens in every thread
- `scripts/context-budget.json` → `tools.children: 1687` of a 7 826 total; `Tests/Extensions/context-tools.json` keeps `shepherd_child_agents/start/message/result/cancel/resume` and `shepherd_workflow` in `thread`. The `shepherd_workflow` description (`Extensions/shepherd-children.ts:1482-1483`) is ~1 100 chars plus a 9-field schema; `shepherd_child_agents`, `_cancel`, `_resume` are rare follow-ups.
- User sees: ~600–800 tokens on every request of every thread (≈8–10 % of the start budget) for tools most threads never call.
- Fix: register `shepherd_workflow`, `shepherd_child_agents`, `shepherd_child_cancel`, `shepherd_child_resume` as `deferred` under a `shepherd_children` namespace (same mechanism as the browser family, `shepherd-status.ts:186-200`), keep `shepherd_child_start` + `_result` + `_message`; update the verdict rows and `--update` the budget.

### SE-15 · low · `codemode` costs 269 tokens of definition + ~600 of prompt guidance in every thread
- `Tests/Extensions/context-tools.json` ("with its prompt guidance the first request grows by 875 tokens"); `Extensions/shepherd-status.ts:76-121` registers it on every `session_start` when enabled (default on).
- User sees: 875 tokens per request for a tool used in a minority of turns.
- Fix: register it `deferred` too, or trim the guideline line (`:96`) to one sentence. Measure with `context_budget.py --scenario thread --tools`.

### SE-16 · low · Design scheme handler lists and sorts the whole `assets/` folder for every `/_blob/<id>` request
- `Sources/DesignSurfaceKit/DesignSchemeHandler.swift:137-142`: `contentsOfDirectory` + `sorted()` + linear `first(where:)` per image request; `serve` (`:150-158`) then `resolvingSymlinksInPath` on both base and file. All responses carry `Cache-Control: no-store` (`:63`), so a board reload re-requests every image.
- User sees: a board with many uploads on a design with hundreds of assets takes noticeably longer to boot after each edit that forces `load()` (head changes), off-main but it delays the first paint.
- Fix: resolve `id` directly (`assets/<id>` then `assets/<id>.<ext>` for the handful of known extensions) and allow `Cache-Control: max-age` for `/_blob/` (content-addressed by id) and `support.js`.

### SE-17 · low · `BrowserSessions.prune(state:)` recomputes a SHA-1 store id for every agent on every state broadcast
- `Sources/ShepherdApp/BrowserHost.swift:206-221` called from `ShepherdViewModel.adopt` (`ShepherdViewModel.swift:1192`); `identifier(for:in:)` (`:50-60`) filters `state.spaces` and does `Insecure.SHA1` per agent each time.
- User sees: nothing today (µs per agent); scales linearly with agents × broadcast rate.
- Fix: early-return when `state.agents.map(\.id,\.spaceID)`, `spaces`, and automations are unchanged from the last prune (store a small hash), or run the prune only on agent add/remove.

### SE-18 · low · Child `publish()` → `shepherd-subagents` re-serialises all cards to detect change
- `Extensions/shepherd-subagents.ts:67-70` `JSON.stringify(next)` of ≤20 cards each time `shepherd-children.ts:629-636` emits (per `save` and per 1 s tick); then a new Unix socket per report (`:36-48`).
- User sees: minor; ~1 socket connect + ≤20-card JSON per second per busy parent.
- Fix: have `publish()` in children compute the key once and skip emitting when unchanged; reuse one socket.

### SE-19 · low · Extensions' NDJSON readers have no frame cap (panes, browser, review, design-refs)
- `Extensions/shepherd-panes.ts:93-99`, `shepherd-browser.ts:127-150`, `shepherd-review.ts` (same pattern): `buffer += chunk` without a size bound (children and design have 8 MiB / 1 MiB caps).
- User sees: nothing unless the server misbehaves; a reply without `\n` would grow pi's heap until exit.
- Fix: one shared guard (`if (buffer.length > 1 << 20) { socket.destroy(); buffer = "" }`) in each reader.

### SE-20 · low · `shepherd-service-tier.ts` reads and parses the tier file on every provider request
- `Extensions/shepherd-service-tier.ts:66-68` `readTier(file)` → `readFileSync` + `JSON.parse` per `before_provider_request`.
- User sees: nothing measurable (one tiny file read per model call).
- Fix: `fs.watch` the file once, or cache by `mtimeMs` via `statSync`.

### SE-21 · low · `inputWatch` reports the user's own clicks/keys in every page even when no agent is driving it
- `Sources/ShepherdApp/BrowserAgentScript.swift:671-689`: throttled to one post per 300 ms, in every frame, for every page including parked ones; native side drops it unless `agentOverlay != nil` (`BrowserHost.swift:595-596`).
- User sees: nothing measurable; a steady trickle of IPC while typing in a page.
- Fix: gate the listener with a flag toggled from `agentBegan`/`agentEnded` (`__shepherdAgentActive`), or leave as is.

### SE-22 · low · Goal extension publishes a widget on every `message_update` where usage grows
- `Extensions/shepherd-goal.ts:403` → `assistantUsage` → `charge` → `publish` → `ctx.ui.setWidget(KEY, [JSON.stringify(goal)])` (`:132-134`). In RPC mode a widget update is an `extension_ui_request` frame to the app.
- User sees: depends on how often providers send usage during a stream (Anthropic: start + end; OpenAI responses: end only) — probably a handful of frames per message; if a provider streams usage per delta this becomes a frame per token.
- Fix: debounce `publish` (100 ms trailing) or only publish from `message_end`.

---

## Already good (don't re-fix)

- **Terminal render loops stop when hidden**: `TerminalSurfaceModel.setRenderingActive` + `TerminalRenderingBridge` (`TerminalSurfaceView.swift:102-128`) mark hidden surfaces not visible so libghostty stops their display link; retry-with-deadline, not fire-and-forget.
- **Focus/render bridges are deduped** (`Coordinator.applied`), so SwiftUI's per-update `updateNSView` does no work on unchanged values.
- **Ghostty parsing is off-main**: `InMemoryTerminalSession.receive` enqueues onto a per-session serial queue; pre-attach bytes capped at 1 MiB; vendored `TerminalDebugLog.log` takes an `@autoclosure` so disabled logging costs one lock.
- **Server dedupes same-grid PTY resizes** (`SessionServer.swift:3072-3078`), so no SIGWINCH storms during drags.
- **Image drops are resized off the main actor**: `TerminalImageDrop.resolve` is a nonisolated async (Swift 5 mode → global executor); 2000-px cap and JPEG/PNG re-encode keep transcripts small; drop dir pruned daily.
- **Design boards**: `DesignContentRules` compiled once per process; `supportScript`/`bridgeScript` read once (`DesignRuntime.swift:12-29`); scheme handler reads files on a detached task; bridge coalesces `size` reports via rAF and only posts diffs; runtime diagnostics capped at 64 entries / 1 000 chars; render limits (`DesignRenderLimits`) bound bitmaps; `replaceSource` avoids a navigation; `DesignHost` keeps a live-board cap with snapshot rasterisation.
- **Browser**: console log capped at 500 lines / 2 000 chars; `BrowserConsoleLines` is a `LazyVStack` of `Equatable` rows observed separately from the page; network count is debounced 250 ms in JS; `inputWatch` throttled 300 ms; per-page operation queue with epochs and deadlines (`withDeadline`) so a hung page cannot wedge later tools; screenshot clamp (1280 px / 300 KB) keeps transcripts small; wait loops are bounded by explicit deadlines.
- **Extensions inert without env vars**: every extension returns early unless `SHEPHERD_AGENT_ID`+`SHEPHERD_SOCKET` (or its own `SHEPHERD_EXT_*`) is set; every hook body is wrapped in `try {} catch {}` so nothing throws into pi; timers are `unref()`'d; the children 1 s tick runs only while a run is live and switches to `fs.watch` when idle; subagents refresh runs only while rows exist; `shepherd-status` reconnects with exponential backoff capped at 10 s and removes its stream listener after the first event.
- **Context budget is guarded** (`context-budget.test.mjs`, 5 %/60-token row margin), deferred-tool registry is tested, and `shepherd-context` clears old tool results instead of re-sending them.
- **Bounded limits everywhere in children/workflow/design**: MAX_RUNS 64, MAX_TEXT 16 KiB, MAX_FRAME 8 MiB, relay 1 MiB / 8 calls, workflow 512 calls / 64 KiB, design 900 KB boards / 200-board batches / 64 edits, `checkBaselines` ≤ 20.

## Needs runtime confirmation

1. SE-01/SE-02 hang duration: profile `browser_screenshot` on a tall page and a 2× export of a 100-page flow board (Instruments → main-thread time in `CGImageDestinationFinalize`/`CGContextDrawImage`).
2. SE-11: CPU of WebContent processes for parked pages (Activity Monitor with 5 threads that each opened a Vite dev server, none on screen) and whether `orderOut` breaks `takeSnapshot`.
3. SE-09: time spent in `TerminalFirstResponder.search` on launch with 20+ mounted agents (Instruments → `-[NSView subviews]` under `confirmSurfaceReady`).
4. SE-07: provider cache-hit rate on turns after a board write / project mutation (Anthropic `cache_read_input_tokens` in the response usage).
5. SE-22: how many `setWidget` frames arrive per streamed message per provider (count `extension_ui_request` with `method: setWidget` in RPC stdout).
6. SE-04: CPU of a worker running an idle `shepherd_workflow` for a minute.
7. Ghostty scrollback: `scrollback-limit` is left at libghostty's default (10 MB/surface); confirm RSS with many long-lived terminals across mounted layouts.
8. SE-03: main-thread cost when a page logs ~500 lines/s (e.g. a dev page with `console.log` in rAF).
