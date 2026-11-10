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
            self.readAfterCommand()
            self.queue.asyncAfter(deadline: .now() + self.commandNoticeGrace) { [weak self] in
                self?.commandWindows.remove(token)
            }
        }
    }

    /// Serialize input preflights while control commands and abort bypass this lane.
    /// A timeout fences the lane until its matching response or restart, without retrying the send.
    func requestInput(prompt: String, images: [NativeImage], delivery: RPCStreamingBehavior,
                      timeout: TimeInterval = RPCThreadState.promptTimeout, expiresAt: Double? = nil,
                      canSend: @escaping () -> Bool = { true }, admitted: @escaping () -> Void = {},
                      completion: @escaping (NativeThreadResult?) -> Void) {
        guard canSend() else {
            completion(.failure(code: "send_cancelled", message: "The send was cancelled before pi started it."))
            // A deadline can invalidate a queued continuation without cancelling later inputs.
            if !inputActive, !waitingInputs.isEmpty { waitingInputs.removeFirst()(true) }
            return
        }
        var textBytes = 0
        for text in [prompt] + images.flatMap({ [$0.mimeType, $0.name ?? ""] }) {
            let count = text.utf8.count
            guard count <= RPCSession.outputQueueLimit - textBytes else {
                completion(Self.dispatchFailure(.failure(.inputRejected))); return
            }
            textBytes += count
        }
        guard !inputOutcomeUnknown else {
            completion(.failure(code: "input_pending", message: "An earlier send's outcome is unknown. Wait for the agent to answer or restart it before sending again; this message was not sent."))
            return
        }
        if inputActive {
            guard waitingInputs.count < 64 else {
                completion(.failure(code: "dispatch_failed", message: "Too many pending sends. Try again."))
                return
            }
            waitingInputs.append { [weak self] send in
                guard send, let self else {
                    completion(.failure(code: "send_cancelled", message: "The send was cancelled before pi started it."))
                    return
                }
                self.requestInput(prompt: prompt, images: images, delivery: delivery, timeout: timeout, expiresAt: expiresAt,
                                  canSend: canSend, admitted: admitted, completion: completion)
            }
            return
        }
        inputActive = true
        let laneID = UUID()
        inputLaneID = laneID
        let generation = generation, preparationVersion = inputPreparationVersion
        let late: (RPCResponse) -> Void = { [weak self] _ in
            guard let self, self.generation == generation else { return }
            self.inputOutcomeUnknown = false
            for dispatch in self.dispatches where dispatch.responded { self.confirmDispatch(dispatch.id) }
            self.resumeAfterSteering()
        }
        let receive: (Result<RPCResponse, RPCError>) -> Void = { [weak self] result in
            guard let self else {
                completion(.failure(code: "send_cancelled", message: "The session was retired before the send completed.")); return
            }
            if self.generation == generation, case .failure(.timeout) = result { self.inputOutcomeUnknown = true }
            let failure: NativeThreadResult?
            if case .failure(.inputRejected) = result, preparationVersion != self.inputPreparationVersion {
                failure = .failure(code: "send_cancelled", message: "The send was cancelled before pi started it.")
            } else {
                failure = Self.dispatchFailure(result)
            }
            completion(self.generation == generation ? failure : .failure(code: "stale_session", message: "The session changed while the send was pending."))
            guard self.inputLaneID == laneID else { return }
            self.inputLaneID = nil
            self.inputActive = false
            if self.inputOutcomeUnknown || !self.session.isAlive { self.cancelWaitingInputs() }
            else if !self.waitingInputs.isEmpty { self.waitingInputs.removeFirst()(true) }
            self.refreshSkillsIfIdle()
        }
        if expiresAt != nil || !images.isEmpty || prompt.utf8.count >= RPCSession.offQueueDecodeBytes {
            // Account for raw images, base64 strings and the encoded frame, plus worst-case
            // JSON text escaping. Input queues themselves retain their existing separate bounds.
            let preparationBytes = textBytes * 12
                + images.reduce(0) { $0 + $1.data.count } * 6 + 64 * 1024
            session.requestPrepared(type: "prompt", timeout: timeout, expiresAt: expiresAt, preparationBytes: preparationBytes, prepare: {
                .prompt(message: prompt, images: images.map { RPCImage(data: $0.data.base64EncodedString(), mimeType: $0.mimeType) }, streamingBehavior: delivery)
            }, isCurrent: { [weak self] in
                guard let self else { return false }
                return self.generation == generation && self.inputPreparationVersion == preparationVersion && self.workAdmission() && canSend()
            }, onAdmitted: admitted, onLateResponse: late, completion: receive)
        } else {
            session.request(.prompt(message: prompt, streamingBehavior: delivery), timeout: timeout,
                            onAdmitted: admitted, onLateResponse: late, completion: receive)
        }
    }

    func cancelWaitingInputs() {
        inputPreparationVersion &+= 1
        let waiting = waitingInputs
        waitingInputs.removeAll()
        for cancel in waiting { cancel(false) }
        session.cancelPreparedRequests()
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
