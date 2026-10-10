import CryptoKit
import Dispatch
import Foundation
import ShepherdProtocol

/// What an extension command the user runs says back. pi's RPC mode has no toast: a command's
/// `ctx.ui.notify` reaches the host as an `extension_ui_request`, and most commands report that
/// way only. The thread drops a toast nobody asked for ("Ponytail loaded"), but one that answers
/// a command the user just sent is the command's output, so it becomes a row where the user is
/// looking: a plain note, or one marked "warning" or "error" by its role.
///
/// A command's window opens when the host hands pi its prompt and closes `commandNoticeGrace`
/// after pi answers it (pi answers once the handler returned, so a toast the handler sent
/// without waiting for it still lands). pi's session keeps none of it, so the host keeps the
/// rows and places them again on every history refresh, as it does for questions.
extension RPCThreadState {
    enum NoticeLevel: String {
        case info, warning, error
    }

    struct CommandNotice: Equatable {
        let id: UUID
        let level: NoticeLevel
        let text: String
        /// When it arrived (ms), which is where history places it.
        let at: Double
    }

    /// The most a thread keeps, and the most text each carries.
    static let noticeLimit = 16
    static let noticeBytes = 4 * 1024

    /// Opens a window for `prompt` when it runs an extension command; call the result with pi's
    /// answer (success, failure or no answer in time).
    func beginCommandWindow(for prompt: String) -> (() -> Void)? {
        guard isExtensionCommand(prompt) else { return nil }
        let token = UUID()
        commandWindows.insert(token)
        return { [weak self] in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + self.commandNoticeGrace) { [weak self] in
                self?.commandWindows.remove(token)
            }
        }
    }

    /// Preflights are serialized because pi's input hooks have no RPC request ID. Control
    /// commands and abort still bypass this lane. A timeout fences the lane until restart:
    /// a late marker must never reject a newer input or make an uncertain send retryable.
    func requestInput(id: UUID, prompt: String, images: [RPCImage], delivery: RPCStreamingBehavior,
                      completion: @escaping (NativeThreadResult?) -> Void) {
        guard !inputOutcomeUnknown else {
            completion(.failure(code: "input_pending", message: "An earlier send's outcome is unknown. Restart the agent before sending again; this message was not sent."))
            return
        }
        if inputActive {
            waitingInputs.append { [weak self] send in
                guard send, let self else {
                    completion(.failure(code: "send_cancelled", message: "The send was cancelled before pi started it."))
                    return
                }
                self.requestInput(id: id, prompt: prompt, images: images, delivery: delivery, completion: completion)
            }
            return
        }
        inputActive = true
        let generation = generation
        beginInput(id, prompt: prompt)
        session.request(.prompt(message: prompt, images: images, streamingBehavior: delivery), timeout: Self.promptTimeout) { [weak self] result in
            guard let self else { return }
            if case .failure(.timeout) = result { self.inputOutcomeUnknown = true }
            let failure = self.finishInput(id, result: result)
            completion(self.generation == generation ? failure : .failure(code: "stale_session", message: "The session changed while the send was pending."))
            self.inputActive = false
            if self.inputOutcomeUnknown { self.cancelWaitingInputs() }
            else if !self.waitingInputs.isEmpty { self.waitingInputs.removeFirst()(true) }
            self.refreshSkillsIfIdle()
        }
    }

    func cancelWaitingInputs() {
        let waiting = waitingInputs
        waitingInputs.removeAll()
        for cancel in waiting { cancel(false) }
    }

    /// A managed guard identifies the input it refused. Keep it only until the RPC response.
    func beginInput(_ id: UUID, prompt: String) {
        inputPrompts[id] = SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func recordBlockedInput(_ text: String) {
        struct Blocked: Decodable { let version: Int; let promptSHA256: String; let modelId: String }
        guard text.utf8.count <= Self.noticeBytes,
              let blocked = try? JSONDecoder().decode(Blocked.self, from: Data(text.utf8)),
              blocked.version == 1, !blocked.modelId.isEmpty, blocked.modelId.utf8.count <= 1024,
              !blocked.modelId.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return }
        // A prior input hook may have expanded a template or transformed the text. The
        // serialized lane still has exactly one RPC preflight, so that refusal belongs to it.
        for (id, digest) in inputPrompts where digest == blocked.promptSHA256 || inputActive && inputPrompts.count == 1 {
            inputFailures[id] = Self.modelUnavailableMessage(blocked.modelId)
        }
    }

    static func modelUnavailableMessage(_ modelID: String) -> String {
        "Couldn't restore this conversation's model: CLIProxyAPI / \(modelID). Your message wasn't sent. Try again or choose a model."
    }

    func finishInput(_ id: UUID, result: Result<RPCResponse, RPCError>) -> NativeThreadResult? {
        inputPrompts.removeValue(forKey: id)
        let message = inputFailures.removeValue(forKey: id)
        if let failure = Self.dispatchFailure(result) { return failure }
        // A notification never turns a started/queued message into a retryable failure.
        if case .success(let response) = result, response.data?["disposition"]?.stringValue == "handled", let message {
            return .failure(code: "model_unavailable", message: message)
        }
        return nil
    }

    /// pi's `notify`: kept only while a command the user sent is in flight.
    func recordNotify(_ request: RPCExtensionUIRequest) {
        guard !commandWindows.isEmpty, let message = request.message else { return }
        record(level: NoticeLevel(rawValue: request.notifyType ?? "") ?? .info, text: message)
    }

    /// pi's `extension_error` for a command whose handler threw: pi answers the prompt as accepted
    /// and says nothing else, so without this a failing command looks like one that did nothing.
    func recordCommandFailure(path: String?, event: String?, error: String) {
        guard event == "command" else { return }
        let prefix = "command:"
        let name = path.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        record(level: .error, text: name.map { "/\($0) failed: \(error)" } ?? error)
    }

    private func record(level: NoticeLevel, text: String) {
        let text = Self.stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let notice = CommandNotice(id: UUID(), level: level, text: Self.clippedText(text, limit: Self.noticeBytes),
                                   at: Date().timeIntervalSince1970 * 1000)
        commandNotices.append(notice)
        if commandNotices.count > Self.noticeLimit {
            let dropped = Set(commandNotices.prefix(commandNotices.count - Self.noticeLimit).map(\.id))
            commandNotices.removeFirst(dropped.count)
            live.removeAll { if case .notice(let id) = $0.kind { dropped.contains(id) } else { false } }
        }
        live.append(LiveItem(kind: .notice(notice.id), value: Self.message(notice), raw: nil, ended: true))
    }

    /// A notice's row: "n:<id>". An info one is a plain note (role "custom", as a displayed
    /// extension message is); the others say what they are, which older clients draw as "warning ·
    /// …". It carries no time, so it never stretches the turn it lands in.
    static func message(_ notice: CommandNotice) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "n:\(notice.id.uuidString)", role: notice.level == .info ? "custom" : notice.level.rawValue,
                            blocks: [NativeThreadBlock(kind: .text, text: notice.text)])
    }

    /// The rows the host keeps beside pi's history, each with where it goes.
    var placedRecords: [(at: Double, row: NativeThreadMessage)] {
        questions.map { (at: $0.endedAt, row: Self.message($0)) } + commandNotices.map { (at: $0.at, row: Self.message($0)) }
    }
}
