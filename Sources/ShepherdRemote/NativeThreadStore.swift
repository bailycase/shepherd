import Foundation
import Observation
import ShepherdProtocol

/// One turn as the thread lists it: the turn, and for a reply its presentation and the
/// prompt that opened it. Equatable, so a row that did not change is not redrawn.
public struct NativeThreadRow: Equatable, Identifiable, Sendable {
    public var turn: NativeTurn
    /// Replies only.
    public var presentation: NativeTurnPresentation?
    /// True while this reply is the one streaming.
    public var live: Bool
    /// The opening prompt's text (a reply's Retry) and time (its footer).
    public var promptText: String?
    public var startedAt: Double?

    public var id: String { turn.id }
    public var isUser: Bool { turn.isUser }
}

/// A native thread for one agent: polls the host's snapshots, keeps the optimistic echoes of
/// sends, and derives what the thread draws (rows, subagent placements) once per change, so
/// views read stored values and typing in the composer invalidates only the composer.
@MainActor
@Observable
public final class NativeThreadStore {
    public typealias Request = @MainActor (NativeThreadRequest) async throws -> NativeThreadResult

    public private(set) var snapshot: NativeThreadSnapshot?
    public private(set) var messages: [NativeThreadMessage] = []
    public private(set) var olderCursor: String?
    public private(set) var loadingOlder = false
    public private(set) var ready = false
    /// The agent's pi is starting (`native_starting`): not ready, and not an error. The thread
    /// shows "Starting pi…", polls quickly, and a send waits for it (see `acceptsSend`). A pi
    /// that has not started within `startingLimit` becomes a `loadError`.
    public private(set) var starting = false
    public private(set) var busy = false
    public private(set) var loadError: String?
    public private(set) var notice: String?
    public private(set) var sentCount = 0
    /// Optimistic echoes of accepted sends (entryID "pending:<operationID>", status "pending",
    /// or "queued" when sent as a follow-up while a turn ran). Each one leaves once pi persists
    /// a user message with the same text, or when the session changes.
    public private(set) var pending: [NativeThreadMessage] = []
    /// `snapshot.running` held true for 400 ms after it drops, so tool boundaries never flicker
    /// the pill, the tail indicator, or the Stop button.
    public private(set) var settledRunning = false
    public var draft = ""
    public var delivery: NativeThreadDelivery = .followUp

    /// History, then the optimistic user echo, then the live (provisional) reply to it. The echo
    /// must precede provisional rows: the reply to a sent message streams below it, and the
    /// order must not flip once pi persists the message (that flip re-laid the whole tail). A
    /// queued follow-up waits below the reply still streaming, which is not its answer.
    public private(set) var displayedMessages: [NativeThreadMessage] = []
    public private(set) var turns: [NativeTurn] = []
    public private(set) var rows: [NativeThreadRow] = []
    /// Each reply's subagents, where their spawn calls were (keyed by turn id).
    public private(set) var placements: [String: NativeSubagentPlacement] = [:]
    public private(set) var subagents: [NativeSubagent] = []
    /// When the prompt that opened the current turn was sent (ms): the running pill's start. A
    /// queued follow-up has not opened a turn yet; nil while the newest prompt is an echo.
    public private(set) var lastPromptAt: Double?

    /// How long `starting` may last before it is reported as an error. Polling continues, so
    /// a pi that answers later still clears it.
    public let startingLimit: Duration

    public init(startingLimit: Duration = .seconds(60)) {
        self.startingLimit = startingLimit
    }

    @ObservationIgnored private var request: Request?
    /// When the current stretch of `native_starting` answers began.
    @ObservationIgnored private var startingSince: ContinuousClock.Instant?
    /// Sends waiting for pi to start: resumed with true once the thread is ready, false when it
    /// stops or fails first. Nothing has been dispatched for them yet.
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var recentRequest = UUID()
    @ObservationIgnored private var historyEpoch = UUID()
    /// Saved user entries → the echo they replaced, so the turn keeps its identity.
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var presentationCache: [String: (key: PresentationKey, value: NativeTurnPresentation)] = [:]
    /// Calls parse their JSON and output once; a finished call never changes.
    @ObservationIgnored private var callCache: [CallKey: NativeActivityCall] = [:]

    private struct PresentationKey: Equatable {
        var messages: [NativeThreadMessage]
        var live: Bool
        var cards: NativeCardLayout
    }

    private struct CallKey: Hashable {
        var entryID: String
        var status: String?
        var isError: Bool?
        var outputSize: Int
        /// A running call's output can change at the same length (the host clips a long tail,
        /// a progress line rewrites itself), so its key carries the end of the output too.
        var liveTail: String?
    }

    /// Reconcile echoes against a snapshot: gone when the real message landed or the session moved on.
    private func settlePending(_ value: NativeThreadSnapshot, sameSession: Bool) {
        guard !pending.isEmpty else { return }
        guard sameSession else { pending = []; aliases = [:]; return }
        let persisted = (value.messages + value.provisional).filter { $0.role == "user" }
        let texts = Set(persisted.map(Self.userText))
        let landed = pending.filter { texts.contains(Self.userText($0)) }
        guard !landed.isEmpty else { return }
        for echo in landed {
            let text = Self.userText(echo)
            // The newest saved message with the echo's text is the one it became.
            if let saved = persisted.last(where: { Self.userText($0) == text && aliases[$0.entryID] == nil }) {
                aliases[saved.entryID] = echo.entryID
            }
        }
        pending.removeAll { texts.contains(Self.userText($0)) }
    }

    private static func userText(_ message: NativeThreadMessage) -> String {
        message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live subagents keep the fast cadence too: their cards tick counters and activity. A
    /// starting pi is polled faster still, so the thread comes up as soon as pi answers.
    public var pollInterval: Duration {
        if starting { return .milliseconds(200) }
        return snapshot?.running == true || snapshot?.dialogs.isEmpty == false || hasLiveSubagents ? .milliseconds(500) : .seconds(2)
    }

    public var hasLiveSubagents: Bool { subagents.contains { !$0.isTerminal } }

    public func supports(_ action: String) -> Bool {
        ready && !busy && snapshot?.supportedActions.contains(action) == true
    }

    /// Send is offered: the thread supports it now, or pi is still starting and the send will
    /// wait for it (every pi thread takes sends).
    public var acceptsSend: Bool {
        supports("send") || (starting && !busy && loadError == nil)
    }

    // MARK: Derived state

    /// Recomputes what the thread draws. Values are assigned only when they changed, so an
    /// unchanged poll invalidates nothing.
    private func derive() {
        let ids = Set(messages.map(\.entryID))
        let toolIDs = Set(messages.compactMap(\.toolCallID))
        let provisional = (snapshot?.provisional ?? []).filter {
            !ids.contains($0.entryID) && ($0.toolCallID == nil || !toolIDs.contains($0.toolCallID!))
        }
        let displayed = messages + pending.filter { $0.status != "queued" } + provisional + pending.filter { $0.status == "queued" }
        if displayed != displayedMessages { displayedMessages = displayed }
        let promptAt = displayed.last { $0.role == "user" && $0.status != "queued" }?.timestamp
        if promptAt != lastPromptAt { lastPromptAt = promptAt }
        let turns = nativeTurns(displayed, aliases: aliases)
        if turns != self.turns { self.turns = turns }
        let runs = snapshot?.subagents ?? []
        if runs != subagents { subagents = runs }
        let placements = nativeSubagentPlacements(runs, turns: turns)
        if placements != self.placements { self.placements = placements }

        // The streaming reply is the last one, with only queued follow-ups below it.
        let running = loadError == nil && settledRunning
        let lastReply = turns.lastIndex { !$0.isUser }
        let liveReply = running ? lastReply.flatMap { index in
            turns[(index + 1)...].allSatisfy { $0.messages.allSatisfy { $0.status == "queued" } } ? index : nil
        } : nil
        var rows: [NativeThreadRow] = []
        rows.reserveCapacity(turns.count)
        var kept: Set<String> = []
        for (index, turn) in turns.enumerated() {
            if turn.isUser {
                rows.append(NativeThreadRow(turn: turn, presentation: nil, live: false, promptText: nil, startedAt: nil))
                continue
            }
            let isLive = index == liveReply
            let opener = index > 0 && turns[index - 1].isUser ? turns[index - 1] : nil
            let key = PresentationKey(messages: turn.messages, live: isLive, cards: NativeCardLayout(placements[turn.id]))
            let presentation: NativeTurnPresentation
            if let cached = presentationCache[turn.id], cached.key == key {
                presentation = cached.value
            } else {
                presentation = nativeTurnPresentation(turn.messages, live: isLive, cards: key.cards, call: call)
                presentationCache[turn.id] = (key, presentation)
            }
            kept.insert(turn.id)
            let prompt = opener.map { $0.messages.flatMap(\.blocks).filter { $0.kind == .text }.map(\.text).joined(separator: "\n") }
            rows.append(NativeThreadRow(turn: turn, presentation: presentation, live: isLive, promptText: prompt,
                                        startedAt: opener?.messages.first?.timestamp))
        }
        if presentationCache.count > kept.count { presentationCache = presentationCache.filter { kept.contains($0.key) } }
        if rows != self.rows { self.rows = rows }
    }

    private func call(_ message: NativeThreadMessage) -> NativeActivityCall {
        let running = message.status == "running" || message.status == "streaming"
        let key = CallKey(entryID: message.entryID, status: message.status, isError: message.isError,
                          outputSize: message.blocks.reduce(0) { $0 + $1.text.utf8.count },
                          liveTail: running ? message.blocks.last.map { String(decoding: $0.text.utf8.suffix(1024), as: UTF8.self) } : nil)
        if let cached = callCache[key] { return cached }
        let value = NativeActivityCall(message)
        if callCache.count > 4096 { callCache.removeAll(keepingCapacity: true) }
        callCache[key] = value
        return value
    }

    // MARK: Polling

    // The view's foreground task owns this loop. Reconnection always starts without a revision.
    public func run(request: @escaping Request) async {
        guard !Task.isCancelled else { return }
        stop()
        let run = epoch
        self.request = request
        await withTaskCancellationHandler {
            await refresh(fresh: true, resetHistory: true)
            while !Task.isCancelled && epoch == run {
                do { try await Task.sleep(for: pollInterval) } catch { break }
                guard epoch == run else { break }
                await refresh()
            }
            if epoch == run { stop() }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == run else { return }
                self.stop()
            }
        }
    }

    public func stop() {
        // A send still waiting for pi to start was never dispatched: its draft stays as it is.
        if busy, startWaiters.isEmpty {
            notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically."
        }
        resumeStartWaiters(false)
        epoch = UUID()
        recentRequest = UUID()
        historyEpoch = UUID()
        request = nil
        if ready { ready = false }
        // Unknown until the thread polls again.
        endStarting()
        if busy { busy = false }
        if loadingOlder { loadingOlder = false }
        settleTask?.cancel()
        settleTask = nil
        if settledRunning {
            settledRunning = false
            derive()
        }
    }

    private func settleRunning(_ running: Bool) {
        settleTask?.cancel()
        settleTask = nil
        if running {
            if !settledRunning { settledRunning = true }
        } else if settledRunning {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, self.snapshot?.running != true else { return }
                self.settledRunning = false
                self.derive()
            }
        }
    }

    public func refresh(fresh: Bool = false, resetHistory: Bool = false) async {
        guard !Task.isCancelled, let request else { return }
        let run = epoch
        let ticket = UUID()
        recentRequest = ticket
        let previous = snapshot
        let fresh = fresh || !ready
        do {
            let result = try await request(.snapshot(
                expectedSessionID: fresh ? nil : previous?.piSessionID,
                afterRevision: fresh ? nil : previous?.revision
            ))
            guard !Task.isCancelled, epoch == run, recentRequest == ticket else { return }
            switch result {
            case .snapshot(let value):
                let sameSession = previous?.piSessionID == value.piSessionID && previous?.generation == value.generation
                if sameSession, let previous, value.revision < previous.revision { return }
                settlePending(value, sameSession: sameSession)
                settleRunning(value.running)
                if !resetHistory, sameSession, value.olderCursor != nil,
                   let first = value.messages.first,
                   let overlap = messages.firstIndex(where: { $0.entryID == first.entryID }) {
                    let merged = Array(messages[..<overlap]) + value.messages
                    if merged != messages { messages = merged }
                } else {
                    if value.messages != messages { messages = value.messages }
                    if olderCursor != value.olderCursor { olderCursor = value.olderCursor }
                    historyEpoch = UUID()
                    if loadingOlder { loadingOlder = false }
                }
                if value != snapshot { snapshot = value }
                if !ready { ready = true }
                endStarting()
                if loadError != nil { loadError = nil }
                derive()
                resumeStartWaiters(true)
            case .unchanged(let session, let generation, _):
                if previous?.piSessionID != session || previous?.generation != generation || fresh {
                    ready = false
                    await refresh(fresh: true)
                } else {
                    if !ready { ready = true }
                    endStarting()
                    if loadError != nil {
                        loadError = nil
                        derive()
                    }
                    resumeStartWaiters(true)
                }
            case .failure(let code, _) where code == NativeThreadCode.starting:
                noteStarting()
            case .failure(let code, let message):
                ready = false
                setLoadError(message)
                if code == "stale_session", !fresh { await refresh(fresh: true) }
            default:
                ready = false
                setLoadError("Unexpected thread response. Refresh to try again.")
            }
        } catch RemoteHostClientError.rejected(let code, _) where code == NativeThreadCode.starting {
            guard !Task.isCancelled, epoch == run, recentRequest == ticket else { return }
            noteStarting()
        } catch {
            guard !Task.isCancelled, epoch == run, recentRequest == ticket else { return }
            ready = false
            setLoadError(String(describing: error))
        }
    }

    /// Any failure but `native_starting`: the thread is not starting, it is in trouble.
    private func setLoadError(_ message: String) {
        endStarting()
        resumeStartWaiters(false)
        guard loadError != message else { return }
        loadError = message
        derive()
    }

    /// pi has not answered yet (the host is still binding or booting it): quiet, with no
    /// error, until it has taken longer than `startingLimit`.
    private func noteStarting() {
        if ready { ready = false }
        let now = ContinuousClock.now
        let since = startingSince ?? now
        startingSince = since
        // A thread cached from before (a host that relaunched) is not running while pi restarts.
        if settledRunning {
            settleTask?.cancel()
            settleTask = nil
            settledRunning = false
            derive()
        }
        guard now - since < startingLimit else {
            if starting { starting = false }
            resumeStartWaiters(false)
            let limit = startingLimit.formatted(.units(allowed: [.minutes, .seconds], width: .wide))
            let message = "The agent's pi has not started after \(limit)."
            if loadError != message {
                loadError = message
                derive()
            }
            return
        }
        if !starting { starting = true }
        if loadError != nil {
            loadError = nil
            derive()
        }
    }

    private func endStarting() {
        if starting { starting = false }
        startingSince = nil
    }

    private func resumeStartWaiters(_ started: Bool) {
        guard !startWaiters.isEmpty else { return }
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume(returning: started) }
    }

    /// At once when the thread can act. While pi is starting, holds the caller (the composer
    /// shows its "Waiting for pi" spinner) until the thread is ready: false instead when the
    /// thread stops or fails first, or pi never starts. Nothing is dispatched while it waits.
    private func readyToAct() async -> Bool {
        if ready { return true }
        guard starting, loadError == nil, !busy, request != nil else { return false }
        let run = epoch
        busy = true
        let started = await withCheckedContinuation { startWaiters.append($0) }
        // stop() already reset everything for a thread that went away meanwhile.
        guard epoch == run else { return false }
        busy = false
        return started && ready
    }

    public func loadOlder() async {
        guard ready, !loadingOlder, let request, let current = snapshot, let cursor = olderCursor else { return }
        let run = epoch
        let history = historyEpoch
        loadingOlder = true
        defer { if epoch == run && historyEpoch == history { loadingOlder = false } }
        do {
            let result = try await request(.snapshot(expectedSessionID: current.piSessionID, beforeEntryID: cursor))
            guard !Task.isCancelled, epoch == run, historyEpoch == history, olderCursor == cursor,
                  snapshot?.piSessionID == current.piSessionID, snapshot?.generation == current.generation else { return }
            switch result {
            case .snapshot(let page) where page.piSessionID == current.piSessionID && page.generation == current.generation:
                let ids = Set(messages.map(\.entryID))
                messages = page.messages.filter { !ids.contains($0.entryID) } + messages
                olderCursor = page.olderCursor
                derive()
            case .failure(let code, let message):
                loadError = message
                derive()
                if code == "stale_cursor" || code == "stale_session" { await refresh(fresh: true, resetHistory: true) }
            default: break
            }
        } catch {
            guard !Task.isCancelled, epoch == run, historyEpoch == history else { return }
            setLoadError(String(describing: error))
        }
    }

    // MARK: Actions

    /// `images` requires `sendImages` support (v2, RPC agents); they are dropped otherwise.
    /// Sent while pi is starting, the draft waits for it (see `acceptsSend`), still in the field,
    /// then goes as the field has it by then: edited, or not at all once cleared.
    public func send(images: [NativeImage] = []) async {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, await readyToAct() else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              supports("send"), let current = snapshot else { return }
        let operation = UUID()
        let attached: [NativeImage]? = images.isEmpty || !supports("sendImages") ? nil : images
        await perform(.send(expectedSessionID: current.piSessionID, generation: current.generation,
                            operationID: operation, text: text, delivery: delivery, images: attached),
                      operation: operation, current: current, sentText: text)
    }

    /// Send `text` as a new user message without touching the draft (a turn's Retry).
    public func send(text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, await readyToAct(),
              supports("send"), let current = snapshot else { return }
        let operation = UUID()
        await perform(.send(expectedSessionID: current.piSessionID, generation: current.generation,
                            operationID: operation, text: text, delivery: delivery),
                      operation: operation, current: current, sentText: text)
    }

    /// "provider/id"; gated by `setModel` in `supportedActions`.
    public func setModel(_ model: String) async {
        guard supports("setModel"), let current = snapshot, current.model != model else { return }
        let operation = UUID()
        await perform(.setModel(expectedSessionID: current.piSessionID, generation: current.generation,
                                operationID: operation, model: model), operation: operation, current: current)
    }

    /// off/low/medium/high; gated by `setThinking` in `supportedActions`.
    public func setThinking(_ level: String) async {
        guard supports("setThinking"), let current = snapshot, current.thinking != level else { return }
        let operation = UUID()
        await perform(.setThinking(expectedSessionID: current.piSessionID, generation: current.generation,
                                   operationID: operation, level: level), operation: operation, current: current)
    }

    /// Card and inspector actions on one subagent run. Gated by `subagents` in `supportedActions`.
    public func subagentCommand(runID: String, action: NativeSubagentAction, text: String? = nil, mode: NativeThreadDelivery? = nil) async {
        guard supports("subagents"), let current = snapshot else { return }
        let operation = UUID()
        await perform(.subagentCommand(expectedSessionID: current.piSessionID, generation: current.generation, operationID: operation,
                                       runID: runID, action: action, text: text, mode: mode), operation: operation, current: current)
    }

    /// One transcript page for the inspector; nil when the thread is not ready or the host refused.
    public func subagentTranscript(runID: String, beforeEntryID: String? = nil) async -> NativeSubagentTranscript? {
        guard let request, let current = snapshot else { return nil }
        guard case .transcript(let page)? = try? await request(.subagentTranscript(expectedSessionID: current.piSessionID, runID: runID, beforeEntryID: beforeEntryID)) else { return nil }
        return page
    }

    public func abort() async {
        guard supports("abort"), let current = snapshot else { return }
        let operation = UUID()
        await perform(.abort(expectedSessionID: current.piSessionID, generation: current.generation,
                             operationID: operation), operation: operation, current: current)
    }

    /// Stop the parent's turn and every live subagent (the composer's "⌘. stop all").
    public func abortAll() async {
        let live = subagents.filter { !$0.isTerminal }.map(\.runID)
        for runID in live { await subagentCommand(runID: runID, action: .cancel) }
        await abort()
    }

    public func answer(dialogID: String, sessionID: String, generation: String, answer: NativeDialogAnswer) async {
        guard supports("answer"), let current = snapshot,
              current.piSessionID == sessionID, current.generation == generation,
              current.dialogs.contains(where: { $0.id == dialogID && $0.unavailable == nil }) else { return }
        let operation = UUID()
        await perform(.answer(expectedSessionID: sessionID, generation: generation, operationID: operation,
                              dialogID: dialogID, answer: answer), operation: operation, current: current)
    }

    private func perform(_ action: NativeThreadRequest, operation: UUID, current: NativeThreadSnapshot, sentText: String? = nil) async {
        guard let request else { return }
        let run = epoch
        // A follow-up sent while a turn runs waits in pi's queue until the turn ends.
        let queued = current.running && delivery == .followUp
        busy = true
        notice = nil
        do {
            let result = try await request(action)
            guard epoch == run else { return }
            guard snapshot?.piSessionID == current.piSessionID, snapshot?.generation == current.generation else {
                busy = false
                notice = "The session changed while the action was pending. Check the thread before trying again."
                return
            }
            switch result {
            case .accepted(let accepted) where accepted == operation:
                if let sentText {
                    if draft == sentText { draft = "" }
                    sentCount += 1
                    pending.append(NativeThreadMessage(entryID: "pending:\(operation.uuidString)", role: "user",
                                                       blocks: [NativeThreadBlock(kind: .text, text: sentText)],
                                                       status: queued ? "queued" : "pending"))
                    derive()
                }
                // Success is visible in the thread itself; only failures earn a notice.
                notice = nil
            case .failure(_, let message): notice = message
            default:
                notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically."
            }
        } catch {
            guard epoch == run else { return }
            if case RemoteHostClientError.outcomeUnknown = error {
                notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically."
            } else { notice = String(describing: error) }
        }
        guard epoch == run else { return }
        busy = false
        ready = false
        await refresh(fresh: true)
    }
}
