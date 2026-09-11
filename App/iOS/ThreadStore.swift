import Combine
import Foundation
import ShepherdProtocol
import ShepherdRemote

@MainActor
final class ThreadStore: ObservableObject {
    typealias Request = @MainActor (NativeThreadRequest) async throws -> NativeThreadResult

    @Published private(set) var snapshot: NativeThreadSnapshot?
    @Published private(set) var messages: [NativeThreadMessage] = []
    @Published private(set) var olderCursor: String?
    @Published private(set) var loadingOlder = false
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var loadError: String?
    @Published private(set) var notice: String?
    @Published private(set) var sentCount = 0
    @Published var draft = ""
    @Published var delivery: NativeThreadDelivery = .followUp

    private var request: Request?
    private var epoch = UUID()
    private var recentRequest = UUID()
    private var historyEpoch = UUID()

    var displayedMessages: [NativeThreadMessage] {
        let ids = Set(messages.map(\.entryID))
        let toolIDs = Set(messages.compactMap(\.toolCallID))
        return messages + (snapshot?.provisional ?? []).filter {
            !ids.contains($0.entryID) && ($0.toolCallID == nil || !toolIDs.contains($0.toolCallID!))
        }
    }

    var pollInterval: Duration {
        snapshot?.running == true || snapshot?.dialogs.isEmpty == false ? .milliseconds(500) : .seconds(2)
    }

    func supports(_ action: String) -> Bool {
        ready && !busy && snapshot?.supportedActions.contains(action) == true
    }

    // The view's foreground task owns this loop. Reconnection always starts without a revision.
    func run(request: @escaping Request) async {
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

    func stop() {
        if busy { notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically." }
        epoch = UUID()
        recentRequest = UUID()
        historyEpoch = UUID()
        request = nil
        ready = false
        busy = false
        loadingOlder = false
    }

    func refresh(fresh: Bool = false, resetHistory: Bool = false) async {
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

    func loadOlder() async {
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

    func send() async {
        guard supports("send"), !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let current = snapshot else { return }
        let text = draft
        let operation = UUID()
        await perform(.send(expectedSessionID: current.piSessionID, generation: current.generation,
                            operationID: operation, text: text, delivery: delivery), operation: operation, current: current, sentText: text)
    }

    func abort() async {
        guard supports("abort"), let current = snapshot else { return }
        let operation = UUID()
        await perform(.abort(expectedSessionID: current.piSessionID, generation: current.generation,
                             operationID: operation), operation: operation, current: current)
    }

    func answer(dialogID: String, sessionID: String, generation: String, answer: NativeDialogAnswer) async {
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
                }
                notice = "Accepted by pi. This does not confirm completion or saved history."
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
