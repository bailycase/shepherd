> Lane report from the 2026-10-27 audit. Static reading only (no build, no run) by a Claude (fable-5-1) agent; line numbers are from commit d28f3511c. Live confirmation of overlapping items is in [live-usage-mac-ios.md](live-usage-mac-ios.md); the cross-lane ranking is in [README.md](README.md).

# Shepherd performance audit — lane: session server and engine (SS)

Scope read: `Sources/ShepherdSessions` (SessionServer*, RPCSession, RPCThreadState*, StateStore, Changes/, PTYSession, SessionScreen, PiLaunch, AgentRecoveryStore, ProjectHistoryStore, extension socket), `Sources/ShepherdPTYSpawn`, `Sources/ShepherdCore`, plus `Extensions/shepherd-status.ts` and the app-side callers needed to confirm a path is hot. Static reading and grep only; no build, no run. Line numbers are from the checkout at audit time.

Severity = user impact × likelihood. "Server queue" means the single serial queue every session queue targets (docs/rules.md › Server concurrency): anything that holds it stalls every agent's stream, every terminal, every remote client.

---

## Findings (ranked by user impact)

### SS-01 — Every prompt waits on a full working-tree git snapshot (`git add -A` + `write-tree`) before pi sees it
**Severity: high** (large repos, dirty trees)
- `Sources/ShepherdSessions/RPCThreadState+Queue.swift:588` — `if expectsMessage, let beforePrompt { beforePrompt(send) } else { send() }`
- `Sources/ShepherdSessions/SessionServer.swift:7055-7058` — `thread.beforePrompt = { … server.changes.prepareTurn(agentID:) { completion } }`
- `Sources/ShepherdSessions/Changes/ChangesService+Turns.swift:169-178` — `prepareTurn` runs `snapshot(repository(context.cwd))` and only then calls `completion`
- `Sources/ShepherdSessions/Changes/ChangesService.swift:134-153` — `snapshot`: `snapshotIndex` (reads + SHA-256 of the user's whole `.git/index`), `git ls-files --others`, a `stat` per untracked file, `git add -A --pathspec-from-file`, `git write-tree`; `ChangesGit.run` has a 10 s timeout per command

**User sees:** press Send, the pending row appears, and pi does not start for hundreds of ms to several seconds in a monorepo or a tree with many untracked/changed files (node_modules not ignored, build output, big index). Worse on the first prompt after a branch switch (stat cache cold) and whenever another process holds `index.lock`. Timeouts (`gitFailed` after 10 s) are swallowed but the wait was still paid.

**Why:** the Undo baseline is captured synchronously in front of the send, instead of in parallel with it. `turnStarted` already tolerates a missing prepared baseline (`prepared … ?? snapshot(repository).tree`, line 190), so the gate is not needed for correctness of the record, only to make the baseline "before pi can write". pi cannot write before its first tool call, which is always ≥ one model round-trip later.

**Fix:** call `send()` immediately and let `prepareTurn` run concurrently on the capture queue; keep the ordering guarantee by having `turnStarted` wait on the capture queue (it already does — `captureQueue(agentID).async` is FIFO behind `prepareTurn`). Optional: skip `snapshotIndex`'s SHA-256 of the index when `(mtime, size)` of `.git/index` is unchanged.

---

### SS-02 — Whole-history `get_messages` on every turn end, projected on the server queue
**Severity: high** (long sessions, many agents)
- `Sources/ShepherdSessions/RPCThreadState.swift:706-723` — `.agentEnd` → `refreshMessages()` + `refreshState()` + `refreshStats()`
- `Sources/ShepherdSessions/RPCThreadState.swift:805` — any displayed custom `message_end` while idle also triggers a full refresh
- `Sources/ShepherdSessions/RPCSession.swift:66-70` — `maxRecordBytes = 256 MiB` ("pi answers get_messages with the whole context in one record … runs to many megabytes")
- `Sources/ShepherdSessions/RPCThreadState.swift:1593-1660` — `finishRefresh` runs `markingStopped`, `projectHistory` (projects *every* message), `keepingSummarized`, `interleave`, `kept != self.history` (deep compare of the whole array), `estimate(messages)` — all on the thread's queue, which targets the server queue

**User sees:** after each reply in a long thread, every other agent's stream and every terminal hiccups for the time it takes to decode (off queue, fine) and then re-project N thousand messages (on queue). With 20 active agents each ending turns, the server queue is saturated with O(total history) work several times a minute. Also a burst of transient memory: raw record + decoded `[RPCMessage]` (base64 images included) + projected array ≈ 3× the session size per refresh.

**Why:** history is rebuilt from scratch instead of appended. The live rows that just ended are already projected (`live`), and pi's `agent_end` carries the turn's messages; the full fetch exists to reconcile ids/timestamps and compaction.

**Fix (smallest):** move `projectHistory` + `estimate` onto `RPCSession.decodeQueue` (they are `static`/pure; the `adjust` closure reads only small dictionaries — snapshot `toolStarts`, `thinkingByTimestamp`, `timingByTimestamp`, `stoppedCalls`, `origins`, `compactionNotes`, `operationsByEntry` before hopping off, same pattern as `ThreadImages.table`). Then the on-queue part is the array swap and the diff. Larger fix: incremental refresh (`get_messages` after a cursor, or trust `agentEnd.messages` and only full-refresh after compaction/`switch`).

---

### SS-03 — `commit()` runs a recovery-checkpoint eligibility scan on every streamed token
**Severity: medium** (grows with agents × projects)
- `Sources/ShepherdSessions/RPCThreadState.swift:887` — `commit()` after every `handle(event)`, including each `text_delta`/`thinking_delta`
- `Sources/ShepherdSessions/RPCThreadState.swift:2412` — first line of `commit()`: `_ = onRecoveryChanged?()`
- `Sources/ShepherdSessions/SessionServer.swift:6972-6980` — `onRecoveryChanged` → `checkpointAgentRecovery`
- `Sources/ShepherdSessions/SessionServer.swift:7609-7616` — `allowsAgentRecovery`: `agents.first`, `isProjectWorker` (scans `projects × tasks` + `projectExecutions` + `agents`), `projectExecutions.contains`, and `automationRunAgentIDs(in:)` which builds two `Set`s from `spaces`/`agents`/`automations` — every call
- `Sources/ShepherdSessions/SessionServer.swift:7637` — then `thread.recoveryCheckpoint(sessionID:)` allocates a `Checkpoint` (maps `dispatches` → `QueueItem`s), and `AgentRecoveryStore.save` (`:51-53`) compares it with the cached previous one

**User sees:** nothing at 3 agents; at 30 agents streaming (~50 deltas/s each) this is ~1,500 state scans per second on the serial queue, each O(agents + projects·tasks + automations) with several heap allocations — tens of ms/s of queue time stolen from everyone, growing quadratically with agent count.

**Fix:** in `commit()` compute a cheap signature of the inputs `recoveryCheckpoint` actually depends on (`running`, `runFailed`, `retry != nil`, `recoveryResumePending`, `stopRequested`, `items`/`dispatches` identity or count, `paused`, `openingPrompt?.id`, `recoveryDispatchID`, `goal == nil`) and call `onRecoveryChanged` only when it moved. Alternatively cache `allowsAgentRecovery` per `(agentID, store.version)` like `sessionAgents` does.

---

### SS-04 — `threadRevised` resolves the thread through `rpcThread(forAgent:)` on every revision
**Severity: medium**
- `Sources/ShepherdSessions/SessionServer.swift:7715-7717` — `threadRevised`: `agentID(forSession:)` (cached, fine) then `if let thread = rpcThread(forAgent: agentID) { pushIfSettled(…) }`
- `Sources/ShepherdSessions/SessionServer.swift:7799-7810` — `rpcThread(forAgent:)` does `agents.first`, `tabs.first`, `layout.leaf(withID:)` (which builds the `leaves` array), then `projects.lazy.flatMap(\.tasks).first`, then `projectExecutions.first` — and writes `thread.projectResultDeliveryID` as a side effect
- `Sources/ShepherdSessions/SessionServer.swift:7697-7700` — `pushIfSettled` immediately returns unless `thread.pushRunArmed`

**User sees:** same as SS-03 — per-token O(state) scans on the serial queue; with many agents and tabs this is the second-largest per-delta cost after hashing.

**Fix:** `threadRevised` already has `sessionID`; use `sessions[sessionID]?.thread` and check `thread.pushRunArmed` before any lookup. Only call `rpcThread(forAgent:)` when a push is actually possible (settled, armed).

---

### SS-05 — `pushMessage(toAgent:)` is `queue.sync` from the main actor
**Severity: medium** (rule violation; latency spikes under load)
- `Sources/ShepherdSessions/SessionServer.swift:4217-4225` — `public func pushMessage(…) -> Bool { queue.sync { … } }`
- `Sources/ShepherdApp/AgentPeers.swift:8, 55` — `@MainActor` handler calls `server.pushMessage(toAgent:…)` synchronously inside `onAgentPeerRequest`
- docs/rules.md › Server concurrency: "The main thread never waits on the server queue."

**User sees:** when one agent messages another, the whole UI freezes for as long as the server queue is busy — which, per SS-02, can be hundreds of ms when another thread is re-projecting a long history, or seconds while a terminal is feeding a large burst (SS-10). Also `peerDeliveries.values.reduce` + `filter` are O(pending) inside the sync block.

**Fix:** make it `async` (`enqueueValue`) and have `AgentPeers` `await` it inside its existing `Task { @MainActor … }` before responding. Same pattern as `setAgentCheckout`.

---

### SS-06 — Every `mutateState` encodes, validates (two extra JSON encodes) and fsyncs state.json on the server queue
**Severity: medium**
- `Sources/ShepherdSessions/StateStore.swift:44-58` — `update`: `candidate.projects != state.projects` (deep compare), `ProjectHistoryStore(beside:).prepare` when projects exist, `candidate.validate()`, `persist(candidate)`, `commit`
- `Sources/ShepherdCore/StateValidation.swift:68, 74` — `validate()` does `JSONEncoder().encode(projects)` and `JSONEncoder().encode(projectExecutions)` purely to measure size, every update
- `Sources/ShepherdSessions/StateStore.swift:165-175` — `persist`: `prettyPrinted + sortedKeys` encode of the whole state, `createDirectory`, `Data.write(.atomic)` (temp file + rename + fsync)
- `Sources/ShepherdSessions/SessionServer.swift:4871-4886` — `mutateState` (46 call sites) runs all of it inline on the queue, then `stateDidCommit` re-derives `ProjectSettingsStore.directories(in:)` twice (`:4932-4933`), `syncServiceTiers`, `broadcastRemoteState` (another full encode per remote view)

**User sees:** each layout change, rename, tab open/close, session-id report, automation tick, design edit, `putState` from the app, etc. costs several ms of serial-queue time (more with large workspaces: sorted-key pretty JSON of hundreds of agents/tabs). On their own they're invisible; during a drag that triggers `putState` repeatedly, or when a Project coordinator mutates state in a loop, streaming judders. Logical-project mutations already stage off queue (`stageLogicalProjects`) — ordinary mutations do not.

**Fix (smallest):** drop the two measuring encodes in `validate()` for the non-project path (only encode when `projects`/`projectExecutions` changed vs `before`, which `StateStore.update` already knows via `logicalChange`). Next: write state.json on a serial I/O queue with a coalescing "latest wins" write, keeping `commit` on the server queue (crash-safety only needs the latest write to land; the app relaunch path already tolerates a stale file).

---

### SS-07 — `ProjectHistoryStore` opens a fresh SQLite connection (DDL + 5 indexes + `synchronous=FULL`) per state update
**Severity: medium** (only when Projects exist)
- `Sources/ShepherdSessions/StateStore.swift:52-54` — `ProjectHistoryStore(beside: url).prepare(before:candidate:)` on every `update` where projects/executions exist and changed (or first time)
- `Sources/ShepherdSessions/ProjectHistoryStore.swift:23-64` — `init`: `realpath`, `open/fstat/close`, `sqlite3_open_v2`, `PRAGMA synchronous=FULL; journal_mode=DELETE`, `CREATE TABLE IF NOT EXISTS` ×2, `CREATE INDEX IF NOT EXISTS` ×5 (two with `json_extract` expressions); `deinit` closes
- `Sources/ShepherdSessions/ProjectHistoryStore.swift:214-222` — `prepare` then `BEGIN IMMEDIATE` and `capture(project)` for *every* `before.projects` entry, each turn
- Seven `ProjectHistoryStore(beside:` call sites in total (`SessionServer.swift:1741`, `+ProjectHistory.swift:100`, `+ProjectExecution.swift:54,96,678`, `StateStore.swift:53,76`)

**User sees:** with an active Project, each coordinator/worker phase change costs an SQLite open + schema check + a fully synchronous transaction (two fsyncs with `journal_mode=DELETE`) on the server queue — ~5–30 ms each on APFS, more on external drives. Projects pump many such changes per turn.

**Fix:** keep one `ProjectHistoryStore` instance per `StateStore` (open once, `sqlite3_busy_timeout` already set), and move the index DDL to a one-time migration. `synchronous=NORMAL` with WAL is adequate for a history log that is re-derived from state.

---

### SS-08 — Remote attach replays up to 2,000 styled scrollback lines through a 2 MiB reply cap that disconnects on overflow
**Severity: medium** (iPhone/iPad terminal view)
- `Sources/ShepherdSessions/SessionServer.swift:3111-3116` — `remoteAttach`: `session.screen.snapshot()` (full scrollback, no `scrollbackLimit`), chunked into 256 KiB `RemoteReply.output` frames and `send` to the client
- `Sources/ShepherdSessions/SessionServer.swift:93, 4588-4595` — `maxQueuedReplyBytes = 2 MiB`; `enqueuePayload` logs "reply queue overflow" and `disconnect(client)` when exceeded
- `Sources/ShepherdSessions/SessionScreen.swift:17, 104-123` — 2,000 lines, every line emitted with SGR runs, no cap on width beyond `TerminalGrid`
- `Sources/ShepherdSessions/SessionServer.swift:3123-3136` — live output is also fanned out per client with no coalescing

**User sees:** attaching the phone to a terminal with a long, colourful scrollback (a test runner, `htop` history, wide 250-column output) can exceed 2 MiB after base64 (+33 %) and NDJSON framing → the remote client is dropped with no message, and reconnects loop if the pane is still open. Even when it fits, 2 MiB over cellular is a multi-second black screen. Separately, every live chunk is JSON-encoded once per attached client (fine) but a slow link with a fast terminal reaches the same 2 MiB cap and disconnects instead of dropping replay-safe bytes.

**Fix:** pass a `scrollbackLimit` for remote attach (e.g. 200 lines, or derive from `maxQueuedReplyBytes / cols`), and for live output let `enqueuePayload` for `.output` frames drop the oldest *output* payloads (they're replaced by the next attach snapshot anyway) rather than disconnecting. Build the snapshot off queue if it stays large (it's a pure read of the emulator under the session lock — would need a copy of the buffer).

---

### SS-09 — Whole-state broadcast on every live field change (status, question, checkout counts, lastActiveAt)
**Severity: medium** (remote clients, large workspaces)
- `Sources/ShepherdSessions/SessionServer.swift:4765-4770` — `applyAgentStatus`: `broadcastRemoteState(committedState)` + `hopToMain { onStateChanged(committedState) }`
- `Sources/ShepherdSessions/SessionServer.swift:4796-4798` — `applyAgentQuestion` same
- `Sources/ShepherdSessions/SessionServer.swift:4810-4814` — `noteAgentSend` same (every send)
- `Sources/ShepherdSessions/SessionServer.swift:5467-5474` — `setAgentCheckout` same, and the app calls it after each file-touching tool (`ShepherdViewModel.swift:795-798`, debounced 1 s per agent)
- `Sources/ShepherdSessions/SessionServer.swift:3171-3187` — `broadcastRemoteState` builds `withoutDesigns.withoutProjectCoordinators.withoutProjectExecutions` copies and runs a sorted-key `NDJSON.encode` of the whole state per distinct view, then queues the full payload per client; `stateChangedPayload` (`:3206`) refuses anything over 1 MiB

**User sees:** on the Mac, `onStateChanged` with a whole `ShepherdState` lands on main several times per second with many agents working (2 status flips/turn + question + checkout + send per agent) — how expensive that is depends on the app's diffing (app lane), but the server makes no attempt to say *what* changed. On the phone, each is a full state frame (tens–hundreds of KB) per event; with 20+ busy agents that's a steady ~0.5–2 MB/s to each remote client, competing with terminal output for the same 2 MiB reply queue (SS-08), and all of it is encoded on the server queue. There is no coalescing: a burst of 10 status changes queues 10 full-state frames, even though only the last matters.

**Fix (smallest):** in `broadcastRemoteState`, before enqueueing, remove any still-unsent `stateChanged` payload from `client.pendingReplies` (tag `PendingReply` with a kind; only drop when `pendingReplyOffset == 0` for index 0). Next: a `RemoteReply.agentLive(agentID, status, waitingOn, waitingReason, checkout, lastActiveAt)` delta for live fields (protocol addition: enum case, `Kind`, `CodingKeys`, codec arms, round-trip row per docs/rules.md › Contracts), keeping full `stateChanged` for structural mutations.

---

### SS-10 — Terminal emulation and the extension socket read loop share the server queue with no per-turn budget
**Severity: medium**
- `Sources/ShepherdSessions/PTYSession.swift:454-480` — `drainMaster` reads up to 256 KiB per turn and feeds each 64 KiB chunk into SwiftTerm (`screen.feed`, `SessionScreen.swift:54`) on the session queue → server queue. Backpressure (`outputHighWaterMark`) only throttles *renderer* delivery; parsing always happens on the queue
- `Sources/ShepherdSessions/SessionServer.swift:3244-3277` — `handleReadable` for extension *and remote* connections loops `read` until `EAGAIN` with no byte budget, decoding each ≤1 MiB NDJSON line (`JSONDecoder`) inline; a remote image upload or a chatty extension holds the queue for the whole burst
- `Sources/ShepherdProtocol/Framing.swift:46-53` — `LineBuffer.append` rescans the buffer from its start on every chunk (`firstIndex(of:)`) and `removeSubrange` from the front per line — O(n²) over a partial 1 MiB frame; `RPCSession.feedStdout` (`RPCSession.swift:460-490`) already has the fixed version with `searchFrom`
- `Sources/ShepherdSessions/SessionServer.swift:7292-7297` + `PTYSession.swift:306-322` — `resize` is applied per call (SwiftTerm reflow of 2,000 lines + `ioctl` + `SIGWINCH`), nothing coalesces a drag's stream of resizes on the server side

**User sees:** run `cat big.log` or a noisy build in a terminal tab and every agent's streaming text and every remote client stutters at the emulator's parse rate; resizing the window with several terminals open does N reflows per frame on the same serial queue.

**Fix:** give `handleReadable` the same `readBudgetPerTurn` pattern as `RPCSession.drainStdout` (return after ~1 MiB and let the source fire again); port `searchFrom` into `LineBuffer`; coalesce `resize` on the server (keep latest `cols/rows` per session, apply once per queue drain). Moving SwiftTerm parsing off the server queue is a larger change (a per-terminal queue with an attach-time fence) and is the real fix if runtime shows terminals dominating the queue.

---

### SS-11 — Unbounded concurrency for off-queue history decodes (memory spike on launch/resume)
**Severity: medium** (many agents, long sessions)
- `Sources/ShepherdSessions/RPCSession.swift:83` — `decodeQueue` is `.concurrent` with no width limit ("so the histories of agents resuming together decode side by side")
- `Sources/ShepherdSessions/RPCSession.swift:66-70, 77-80` — a record is allowed to be 256 MiB; the decode holds `line` (raw) + the decoded `[RPCMessage]` with base64 image payloads as `String`s, plus `deferredRecords` up to 8 MiB per session
- `Sources/ShepherdSessions/RPCThreadState.swift:1565-1576` — a history with images additionally re-decodes and SHA-256s *every* image on `DispatchQueue.global` on every refresh ("Nothing is cached between calls", `ThreadImages.swift:26`)

**User sees:** restoring a workspace with 20–40 long threads starts 20–40 simultaneous multi-MB JSON decodes; peak footprint = Σ(raw + decoded + projected) across all of them at once, enough to trigger memory pressure on 16 GB machines and swap on 8 GB. On image-heavy threads, every turn end re-hashes all past screenshots.

**Fix:** bound `decodeQueue` with a `DispatchSemaphore(value: ProcessInfo.activeProcessorCount / 2)` (or an `OperationQueue` with `maxConcurrentOperationCount`) — backpressure already exists upstream (`decodeHighWaterBytes`), so waiting is safe. Cache `ThreadImages.Meta` by `(entryID, index, base64.count)` across refreshes on the thread.

---

### SS-12 — Agent recovery checkpoints are written synchronously on the server queue, image bytes included
**Severity: low–medium**
- `Sources/ShepherdSessions/AgentRecoveryStore.swift:47-58` — comment admits it: "synchronous write-ahead keeps admission crash-safe; stage large image blobs off queue if … checkpoints measurably stall other sessions"; `save` does `JSONEncoder().encode(checkpoint).write(.atomic)` + `setAttributes`
- `Sources/ShepherdSessions/RPCThreadState+Recovery.swift:7-16` — the checkpoint carries every queued/pending item's `images: [NativeImage]` (`NativeImage.maxBytesPerSend = 5 MiB`, `NativeThread.swift:101`)
- Triggered from `commit()` (SS-03) whenever the checkpoint changes: send, queue edit, turn start/settle

**User sees:** sending a message with screenshots attached freezes every other agent's stream for the time to JSON-encode (base64 → ~7 MB) and atomically write + fsync that file. Repeats on each queue change while the images are still pending.

**Fix:** keep the compare on queue, hand the encoded `Data` to a serial I/O queue for the write (recovery only needs the *latest* checkpoint to be durable before the next send is admitted; gate admission on that queue's completion rather than on the server queue).

---

### SS-13 — Changes overview spawns a login shell for `gh pr view` and runs a working-tree snapshot per request
**Severity: low–medium**
- `Sources/ShepherdSessions/Changes/ChangesService+API.swift:74-131` — `overviewNow`: `pullRequest(...)` kicked off on `global()`, then `snapshot(repository)` (same cost as SS-01), `indexTree`, `files()` for five scopes (five `git diff --raw --numstat` processes), `commits(...)`, `mergeBase`, then `pullDone.wait(timeout: 12)`
- `Sources/ShepherdSessions/Changes/ChangesService.swift:453-477` — `runLoginShell`: `/bin/zsh -l -c "gh pr view …"` — a login shell sources the user's rc files (oh-my-zsh, nvm, conda… commonly 200–800 ms) before `gh` even talks to the network; cached per `(root, branch)` for 60 s (`:60, 419-427`)

**User sees:** opening the Changes tab (or whatever refreshes the overview) takes up to a second with a heavy shell profile, and up to 12 s when offline/VPN-flaky while `gh` times out; the working-tree snapshot repeats the SS-01 cost. All off the server queue (good), on the concurrent `work` queue, but each call is 8+ child processes.

**Fix:** resolve `gh` once (login shell → `command -v gh`, cached for the app lifetime) and exec it directly with `Process` + the captured `PATH`; lower the wait to ~3 s and let the PR row fill in on a later poll. Reuse the last turn's `endTree` as the working snapshot when `turnSettled` just ran (mtime of `.git/index` + untracked listing unchanged).

---

### SS-14 — `forkpty` from a large multithreaded app process on the server queue
**Severity: low–medium**
- `Sources/ShepherdPTYSpawn/shepherd_pty_spawn.c:15-28` — `forkpty` then `signal()` ×NSIG and `close()` for every fd up to `getdtablesize()` in the child
- `Sources/ShepherdSessions/PTYSession.swift:239-240` — called from `PTYSession.init`, which `makeSessionOnQueue` runs on the server queue (`SessionServer.swift:7111`)
- `RPCSession` (`RPCSession.swift:178-200`) uses `posix_spawn` and is cheap

**User sees:** opening a terminal tab stalls all agent streams for the fork of a process with WebKit, Ghostty surfaces and hundreds of MB resident (page-table copy, typically 20–80 ms, more with many threads/mappings), plus a loop over the fd table (10k+ iterations when many sockets/pipes are open).

**Fix:** `openpty` in the parent, then `posix_spawn` with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`, `addopen` of the slave path on 0/1/2 (first tty opened by a new session leader becomes the controlling tty on macOS) and `addchdir`. Same shape as `RPCSession`; drops the C shim entirely.

---

### SS-15 — Assistant text is rebuilt by `text + delta` and re-projected on every delta
**Severity: low** (bounded by `textLimit`)
- `Sources/ShepherdSessions/RPCThreadState.swift:2230-2242` — `apply`: `message.content[index] = .text(text + (delta.delta ?? ""))` allocates a new string of the whole block per delta
- `Sources/ShepherdSessions/RPCThreadState.swift:797-800, 1969-1971` — `var raw = current` (copies the message) then `upsertAssistant` → `project(entryID:message:)` re-clips every block; `commit()` re-hashes the row (`:2419-2421`, `hash = nil` on each change)
- Per-row work is bounded by `textLimit = 16 KiB` per block and 128 blocks (`:14, 2869`), so this is O(16 KiB) per token, not O(n)

**User sees:** nothing measurable on one agent; ~20–50 µs per token per agent of serial-queue time, pure overhead that adds to SS-03/SS-04.

**Fix:** mutate in place (`if case .text(var t) = …; t.append(delta); content[index] = .text(t)` with the enum payload taken out first to keep the buffer unique), and only re-project the block that changed. Low priority; listed so nobody "optimises" the clipping away.

---

### SS-16 — `toolStarts`, `thinkingSpans`, `stoppedCalls`, `retiredRPCSessions` grow for the lifetime of a session/app
**Severity: low** (memory; small entries)
- `Sources/ShepherdSessions/RPCThreadState.swift:2019` — `toolStarts[id] = …` on every tool row; removed only for dropped streaming calls (`:2226`) or `resetForNewSession` (`:1829`)
- `Sources/ShepherdSessions/RPCThreadState.swift:1983` — `thinkingSpans[key]` per assistant message, same lifetime
- `Sources/ShepherdSessions/RPCThreadState.swift:857` — `stoppedCalls.insert(id)`, never pruned
- `Sources/ShepherdSessions/SessionServer.swift:658, 7340` — `retiredRPCSessions` gains an entry per RPC exit, never removed
- Contrast: `timingByTimestamp`/`responseMarks` are capped at `timingLimit = 512` (`:268, 2090, 2039`)

**User sees:** a day-long agent with thousands of tool calls keeps a few hundred KB of stale ids; `retiredRPCSessions` keeps one tiny entry per stop/retry. Not user-visible; a leak-shaped pattern worth capping the same way as `timingByTimestamp`.

**Fix:** apply the `timingLimit` eviction (drop oldest when `count >= 512`) to `toolStarts`/`thinkingSpans`/`stoppedCalls`; prune `retiredRPCSessions` in `stateDidCommit` to sessions still referenced by a pane.

---

### SS-17 — `RPCSession.shutdown` / `PTYSession.shutdown` spin with `usleep` on the server queue at quit
**Severity: low** (quit path only)
- `Sources/ShepherdSessions/RPCSession.swift:362-377` — after SIGKILL, `while true { waitpid(WNOHANG) … usleep(10_000) }` up to 2 s, per session, sequentially on the queue
- `Sources/ShepherdSessions/PTYSession.swift:412-421` — same shape
- `Sources/ShepherdSessions/SessionServer.swift:1337-1340, 1473` — `stop` also `runLog.flush()`, `changes.flush()` (`io.sync {}`)

**User sees:** quitting with many sessions whose children are slow to die (a stuck `git` in a PTY, pi mid-fs-sync) can take several seconds; the app looks hung because the stop runs `queue.sync` from main. SIGKILL'd processes usually reap in <10 ms so this is rare.

**Fix:** issue all SIGKILLs first, then wait with one deadline across all sessions (one `kqueue`/`DispatchSourceProcess` per pid or a single polling loop), not 2 s × N worst case.

---

### SS-18 — Per-prompt `confirmDispatch` and per-turn `refreshState`/`refreshStats`/`refreshCommands` round-trips
**Severity: low**
- `Sources/ShepherdSessions/RPCThreadState+Queue.swift:594-598` — `confirmDispatch` sends `get_state` after every prompt
- `Sources/ShepherdSessions/RPCThreadState.swift:721-723, 741, 1686` — `agent_end` → `refreshState` + `refreshStats`; `agentSettled` → `refreshState` again; `refreshStats` on every reply (`:836-838`, "the ring moves once per reply")
- `Sources/ShepherdSessions/RPCThreadState.swift:620-648` — `refresh_skills` when idle after `skills_changed`, up to three retries

**User sees:** nothing directly; it is 3–5 extra JSONL round-trips through pi per turn, each a record parsed on the server queue, and `get_state` on pi's side is synchronous with its own event loop. Fine at current scale; listed because it compounds with SS-02 in the same queue turn.

**Fix:** only `refreshState` once per settle (drop the one in `agent_end`), and skip `refreshStats` when `agent_end` already carried `usage` for the last assistant message.

---

## Already good (do not re-fix)

- **Off-queue decode with ordering and backpressure** — `RPCSession.receiveRecord`/`decodeOffQueue`/`finishOffQueueDecode` (`RPCSession.swift:505-550`): records ≥ 256 KiB decode on a concurrent queue, later records are deferred in arrival order, stdout reading suspends at 8 MiB and resumes at 4 MiB, request deadlines wait for in-flight records. `feedStdout` uses `memchr` from `searchFrom` (no quadratic rescans).
- **Stdout read budget** — `drainStdout(budget: 1 MiB)` yields the queue between reads (`RPCSession.swift:433-454`).
- **Revision pacing** — `RevisionPacer` (`SessionServer.swift:765-803`) coalesces thread/design revisions to one main hop per display frame and only for watched agents; `onThreadRevision` carries no state. Snapshot requests short-circuit with `afterRevision` (`RPCThreadState.swift:964-966`).
- **Snapshot hashing/sizing caches** — `commit()` hashes a live row once per change (`LiveItem.hash`), `historyBytes` sizes each history row once, `dialogBytes`, `queueHash()`/`queueBytes()` memoised, `encodesSinceSnapshot` counters exist in DEBUG to catch regressions (`RPCThreadState.swift:2411-2470, 2665-2704`).
- **Bounded snapshot budget** — `snapshotLimit` 240 KiB, `activeLimit`, `pageSize` 50, `textLimit` 16 KiB per block, 128 blocks per row, dialog/widget/subagent caps (`RPCThreadState.swift:14-35`); `trimLive` keeps the live list to a page per kind.
- **`live` and queue bounds** — `queueItemLimit = 32`, `queueTextLimit`, `queueEncodedLimit`, `deletedLimit = 64`, `operationTableSize = 256`, `timingLimit = 512`.
- **PTY output backpressure** — `outputHighWaterMark` 4 MiB / `outputLowWaterMark` 1 MiB / `maxOutputDeliveryBytes` 256 KiB with exactly one in-flight main-queue delivery per session (`SessionServer.swift:7357-7435`); reads suspend instead of growing memory; terminal replay is an ANSI snapshot, scrollback capped at 2,000 lines.
- **`sessionAgents` lookup cache keyed by `store.version`** (`SessionServer.swift:7567-7580`) — the per-revision session→agent lookup is O(1).
- **Live fields never hit disk** — `updateLive` for status/question/checkout/lastActiveAt (`StateStore.swift:110-114`) avoids validate + write; `persisted` strips them.
- **Logical-project mutations stage off queue** — `stageLogicalProjects` encodes/validates/writes on `logicalProjectFiles`, the queue does only the rename (`StateStore.swift:66-107`, `SessionServer+ProjectRuntimePersistence.swift`).
- **Changes engine runs on its own queues** — `work` (concurrent), per-agent `captureQueue`, `TurnStore.io`; `TurnStore.update` coalesces saves with `writeScheduled`. Repository metadata cached per cwd; private index reseeded only when the user's index fingerprint changes.
- **Async writes elsewhere** — `AutomationRunLog`, `ThreadOrigins`, `DesignReferencePayloads`, `ProjectSettingsStore.remember` all write on their own serial queues.
- **Diagnostics sampling** — process census every 60 s under a budget, off both queues (`ShepherdDiagnostics.swift:163-170`, `SessionResources.swift`).
- **Remote reply queue is bounded** and revocation-aware; peer deliveries capped (4096 total / 64 per agent / 2 MiB text).
- **No `ObservableObject`/`@Published`, no timers that tick while idle** in this lane: the only repeating timers are the 50 ms reap fallback (cancelled on reap) and `BrowserTunnelHost`'s idle scanner (started only while tunnels exist).
- **Regexes are static** (`RPCThreadState.ansi`, `PushNotifications.secretPatterns`); the two inline `NSRegularExpression`/`replacingOccurrences(options: .regularExpression)` are on cold paths (MCP URL canonicalisation, goal-check label).

## Needs runtime confirmation

1. **Server-queue occupancy under load** — instrument `queue` with a signpost around each block (or sample with `spindump` while 20 agents stream + one terminal runs `yes | head -c 50M`) to rank SS-02/SS-03/SS-04/SS-10 by actual share. The DEBUG counters `bytesHashedByLastCommit` / `encodesByLastSnapshot` give the per-commit cost for SS-03/SS-15.
2. **`prepareTurn` latency** (SS-01) — time from `send` to pi's `agent_start` in a repo like a 50k-file monorepo with a dirty tree; compare with `beforePrompt = nil`.
3. **`get_messages` size and `finishRefresh` duration** (SS-02) — `onDiagnosticDuration("history.refresh")` already measures the round trip; add the on-queue projection time. Check peak RSS when restoring 20+ long threads (SS-11).
4. **Remote disconnects on attach** (SS-08) — attach the iPhone to a terminal after `seq 1 5000 | lolcat`-style output at 200 columns and watch for "reply queue overflow" in the log.
5. **`putState` frequency from the app** (SS-06) — count `mutateState` calls per second during a pane-divider drag or sidebar reorder; if >10/s the write should move off queue.
6. **Resize storms** (SS-10) — count `resize(sessionID:)` per second during a window drag with 6 terminals; confirm whether the app already debounces.
7. **Fork cost** (SS-14) — time `PTYSession.init` with the app at steady state (several boards/webviews open); if <10 ms, drop SS-14 to low/no-fix.
8. **Login-shell cost** (SS-13) — time `zsh -l -c true` on the user's machine; with a 50 ms profile the finding is moot.
9. **Main-thread blocking by `pushMessage`** (SS-05) — hang detector / `os_signpost` on `AgentPeers` while another thread's history refreshes.
