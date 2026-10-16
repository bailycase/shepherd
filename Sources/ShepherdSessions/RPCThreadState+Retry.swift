import Foundation
import ShepherdProtocol

/// Retry (`NativeThreadRequest.retry`): restart or continue the latest turn. The status extension's
/// `/shepherd-retry <ms>` moves pi's session back to before the user message pi stamped at that
/// millisecond (its tree keeps the failed turn off the active branch) and sends the message
/// again, text and images. A failed turn with tool results or extension messages continues
/// without rewinding, keeping completed work and child references. The host reads pi's
/// history again once the command runs: either the replacement branch or the retained history.
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
        // Never queued or steered: retry only once pi has finished the turn.
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
        // A Git merge turn runs only through its own bounded, checked attempt (Try again with agent).
        if Self.isGitMergeTurn(history[index]) {
            completion(.failure(code: "git_merge", message: "Use Try again with agent to retry the merge."))
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
                // pi's branch now: a replacement, a continuation retaining completed work,
                // or the unchanged history if the command refused.
                self.refreshMessages()
                self.commit()
                completion(failure ?? .accepted(operationID: operationID))
            }
        }
        if let beforePrompt { beforePrompt(send) } else { send() }
    }

    /// The user message Shepherd sent for a design's Git merge (`DesignGitMergeBrief.request`).
    static func isGitMergeTurn(_ message: NativeThreadMessage) -> Bool {
        message.blocks.contains { $0.kind == .text && $0.text == DesignGitMergeBrief.request }
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
