import Combine
import Foundation
import ShepherdProtocol

@MainActor
public final class NativeThreadStore: ObservableObject {
    public typealias Request = @MainActor (NativeThreadRequest) async throws -> NativeThreadResult

    @Published public private(set) var snapshot: NativeThreadSnapshot?
    @Published public private(set) var messages: [NativeThreadMessage] = []
    @Published public private(set) var olderCursor: String?
    @Published public private(set) var loadingOlder = false
    @Published public private(set) var ready = false
    @Published public private(set) var busy = false
    @Published public private(set) var loadError: String?
    @Published public private(set) var notice: String?
    @Published public private(set) var sentCount = 0
    /// Optimistic echoes of accepted sends (entryID "pending:<operationID>", status "pending").
    /// Each one leaves once pi persists a user message with the same text, or when the session changes.
    @Published public private(set) var pending: [NativeThreadMessage] = []
    /// `snapshot.running` held true for 400 ms after it drops, so tool boundaries never flicker
    /// the pill, the tail indicator, or the Stop button.
    @Published public private(set) var settledRunning = false
    @Published public var draft = ""
    @Published public var delivery: NativeThreadDelivery = .followUp

    public init() {}

    private var request: Request?
    private var settleTask: Task<Void, Never>?
    private var epoch = UUID()
    private var recentRequest = UUID()
    private var historyEpoch = UUID()

    /// History, then the optimistic user echo, then the live (provisional) reply to it. The echo
    /// must precede provisional rows: the reply to a sent message streams below it, and the
    /// order must not flip once pi persists the message (that flip re-laid the whole tail).
    public var displayedMessages: [NativeThreadMessage] {
        let ids = Set(messages.map(\.entryID))
        let toolIDs = Set(messages.compactMap(\.toolCallID))
        return messages + pending + (snapshot?.provisional ?? []).filter {
            !ids.contains($0.entryID) && ($0.toolCallID == nil || !toolIDs.contains($0.toolCallID!))
        }
    }

    /// Reconcile echoes against a snapshot: gone when the real message landed or the session moved on.
    private func settlePending(_ value: NativeThreadSnapshot, sameSession: Bool) {
        guard !pending.isEmpty else { return }
        guard sameSession else { pending = []; return }
        let persisted = Set((value.messages + value.provisional).filter { $0.role == "user" }.map(Self.userText))
        pending.removeAll { persisted.contains(Self.userText($0)) }
    }

    private static func userText(_ message: NativeThreadMessage) -> String {
        message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var pollInterval: Duration {
        snapshot?.running == true || snapshot?.dialogs.isEmpty == false ? .milliseconds(500) : .seconds(2)
    }

    public func supports(_ action: String) -> Bool {
        ready && !busy && snapshot?.supportedActions.contains(action) == true
    }

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
        if busy { notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically." }
        epoch = UUID()
        recentRequest = UUID()
        historyEpoch = UUID()
        request = nil
        ready = false
        busy = false
        loadingOlder = false
        settleTask?.cancel()
        settleTask = nil
        settledRunning = false
    }

    private func settleRunning(_ running: Bool) {
        settleTask?.cancel()
        settleTask = nil
        if running {
            settledRunning = true
        } else if settledRunning {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, self.snapshot?.running != true else { return }
                self.settledRunning = false
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
                    messages = Array(messages[..<overlap]) + value.messages
                } else {
                    messages = value.messages
                    olderCursor = value.olderCursor
                    historyEpoch = UUID()
                    loadingOlder = false
                }
                snapshot = value
                ready = true
                loadError = nil
            case .unchanged(let session, let generation, _):
                if previous?.piSessionID != session || previous?.generation != generation || fresh {
                    ready = false
                    await refresh(fresh: true)
                } else {
                    ready = true
                    loadError = nil
                }
            case .failure(let code, let message):
                ready = false
                loadError = message
                if code == "stale_session", !fresh { await refresh(fresh: true) }
            default:
                ready = false
                loadError = "Unexpected thread response. Refresh to try again."
            }
        } catch {
            guard !Task.isCancelled, epoch == run, recentRequest == ticket else { return }
            ready = false
            loadError = String(describing: error)
        }
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
            case .failure(let code, let message):
                loadError = message
                if code == "stale_cursor" || code == "stale_session" { await refresh(fresh: true, resetHistory: true) }
            default: break
            }
        } catch {
            guard !Task.isCancelled, epoch == run, historyEpoch == history else { return }
            loadError = String(describing: error)
        }
    }

    /// `images` requires `sendImages` support (v2, RPC agents); they are dropped otherwise.
    public func send(images: [NativeImage] = []) async {
        guard supports("send"), !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let current = snapshot else { return }
        let text = draft
        let operation = UUID()
        let attached: [NativeImage]? = images.isEmpty || !supports("sendImages") ? nil : images
        await perform(.send(expectedSessionID: current.piSessionID, generation: current.generation,
                            operationID: operation, text: text, delivery: delivery, images: attached),
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

    public func abort() async {
        guard supports("abort"), let current = snapshot else { return }
        let operation = UUID()
        await perform(.abort(expectedSessionID: current.piSessionID, generation: current.generation,
                             operationID: operation), operation: operation, current: current)
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
                                                       blocks: [NativeThreadBlock(kind: .text, text: sentText)], status: "pending"))
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
