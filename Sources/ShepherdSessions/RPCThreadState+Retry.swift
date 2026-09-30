import Foundation
import ShepherdProtocol

/// Retry (`NativeThreadRequest.retry`): the latest turn again, in place. The status extension's
/// `/shepherd-retry <ms>` moves pi's session back to before the user message pi stamped at that
/// millisecond (its tree keeps the failed turn off the active branch) and sends the message
/// again, text and images. RPC has no event for the move, so the host takes the turn out of the
/// thread when it sends the command and reads pi's history again once pi has run it: the thread
/// shows the active branch, and the retried turn streams in the old one's place.
extension RPCThreadState {
    static let retryCommand = "shepherd-retry"

    func retryTurn(entryID: String, operationID: UUID, completion: @escaping (NativeThreadResult) -> Void) {
        // pi has settled and the Changes engine is still recording the turn's end: the retry
        // goes once it has (a new turn's start is recorded after it).
        if settleCapture != nil, !running, dispatches.isEmpty {
            afterSettleCapture.append { [weak self] in
                guard let self else { return }
                self.retryTurn(entryID: entryID, operationID: operationID, completion: completion)
            }
            return
        }
        // Never queued or steered: a retry replaces the turn pi just finished.
        guard !piBusy, compactingRun == nil, dialogs.isEmpty else {
            completion(.failure(code: "busy", message: "Retry once the agent has stopped."))
            return
        }
        guard session.isAlive else {
            completion(.failure(code: "dispatch_failed", message: "pi is not running."))
            return
        }
        guard !live.contains(where: { $0.kind == .user }), let index = Self.retryIndex(of: entryID, in: history),
              let at = history[index].timestamp.flatMap(Self.millisecondKey) else {
            completion(.failure(code: "not_latest", message: "Only the latest turn can be retried. Refresh the thread."))
            return
        }
        let command = "/\(Self.retryCommand) \(at)"
        stopRequested = false
        dispatches.append(Dispatch(id: operationID, text: command, parts: nil, items: [], expectsMessage: false))
        retryDispatch = operationID
        dropHistory(from: index)
        commit()
        let generation = generation
        preparingPrompts[operationID] = completion
        let send = { [weak self] in
            guard let self, let completion = self.preparingPrompts.removeValue(forKey: operationID) else { return }
            guard self.generation == generation, self.session.isAlive, self.retryDispatch == operationID else {
                self.retryEnded(operationID)
                self.discardPreparedTurn?()
                self.refreshMessages()
                completion(.failure(code: "send_cancelled", message: "The retry was cancelled before pi started it."))
                return
            }
            self.session.request(.prompt(message: command), timeout: Self.promptTimeout) { [weak self] result in
                guard let self else { return }
                let failure = Self.dispatchFailure(result)
                if let failure, case .failure(let code, _) = failure, code != "outcome_unknown" {
                    self.retryEnded(operationID)
                    self.discardPreparedTurn?()
                } else {
                    self.confirmRetry(operationID)
                }
                // pi's branch now: without the retried turn once the command ran, as it was if
                // the command refused.
                self.refreshMessages()
                self.commit()
                completion(failure ?? .accepted(operationID: operationID))
            }
        }
        if let beforePrompt { beforePrompt(send) } else { send() }
    }

    /// The latest turn's user message: `entryID` in history, with no user message after it but
    /// ones steered into its turn.
    static func retryIndex(of entryID: String, in history: [NativeThreadMessage]) -> Int? {
        guard let index = history.lastIndex(where: { $0.entryID == entryID }), history[index].role == "user",
              history[index].origin != .steered, history[(index + 1)...].allSatisfy({ $0.role != "user" || $0.origin == .steered }) else { return nil }
        return index
    }

    func runAfterSettleCapture() {
        let waiting = afterSettleCapture
        afterSettleCapture = []
        waiting.forEach { $0() }
    }

    /// The run the retry started has begun: pi is busy on its own now.
    func retryStarted() {
        guard let id = retryDispatch else { return }
        retryEnded(id)
    }

    private func retryEnded(_ id: UUID) {
        dispatches.removeAll { $0.id == id }
        if retryDispatch == id { retryDispatch = nil }
    }

    /// pi answered the command: if no run started (the command refused), pi is idle again.
    private func confirmRetry(_ id: UUID) {
        guard retryDispatch == id else { return }
        session.request(.getState) { [weak self] result in
            guard let self, self.retryDispatch == id, case .success(let response) = result, response.success,
                  response.data?["isStreaming"]?.boolValue == false else { return }
            self.retryEnded(id)
            self.discardPreparedTurn?()
            self.commit()
            self.drainIfReady()
            self.idleAfterQueue()
        }
    }
}
