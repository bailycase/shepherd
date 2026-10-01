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
