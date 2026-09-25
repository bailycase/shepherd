import Foundation
import ShepherdProtocol

/// A thread's latest exchange in a few lines, for a preview beside search results (the iPad
/// palette): the last prompts, replies and tool calls, newest last. Pure.
public struct ThreadPreview: Equatable, Sendable {
    public struct Line: Equatable, Identifiable, Sendable {
        public enum Kind: Equatable, Sendable { case user, assistant, activity }

        public var id: String
        public var kind: Kind
        public var text: String
        /// An activity line's call failed.
        public var failed: Bool

        public init(id: String, kind: Kind, text: String, failed: Bool = false) {
            self.id = id
            self.kind = kind
            self.text = text
            self.failed = failed
        }
    }

    /// Characters kept from one prompt or reply.
    public static let textLimit = 360

    public var lines: [Line]
    public var running: Bool
    public var model: String?

    public init(lines: [Line], running: Bool, model: String?) {
        self.lines = lines
        self.running = running
        self.model = model
    }

    /// The last `limit` lines of `snapshot`: prompts and replies as prose (thinking left out),
    /// tool calls as one activity line each ("bash swift test").
    public init(_ snapshot: NativeThreadSnapshot, limit: Int = 6) {
        var lines: [Line] = []
        for message in (snapshot.messages + snapshot.provisional).reversed() {
            guard lines.count < limit else { break }
            switch message.role {
            case "user", "assistant":
                let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
                let collapsed = Self.clipped(text)
                guard !collapsed.isEmpty else { continue }
                lines.append(Line(id: message.entryID, kind: message.role == "user" ? .user : .assistant, text: collapsed))
            case "toolResult":
                let call = NativeActivityCall(message)
                let text = [call.label, call.detail].filter { !$0.isEmpty }.joined(separator: " ")
                lines.append(Line(id: message.entryID, kind: .activity, text: Self.clipped(text), failed: call.state == .failed))
            default:
                continue
            }
        }
        self.init(lines: lines.reversed(), running: snapshot.running, model: snapshot.model)
    }

    /// One paragraph: whitespace runs collapsed, cut at `textLimit` with an ellipsis.
    static func clipped(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > textLimit else { return flat }
        return String(flat.prefix(textLimit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
