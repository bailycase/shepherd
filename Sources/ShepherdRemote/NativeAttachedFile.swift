import Foundation

/// A file waiting in a composer beside the draft (a design's boards attached to a thread): its
/// chip's name and where it is on the host. pi reads it from there; the message it goes with
/// lists where each one is under the words.
public struct NativeAttachedFile: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// What its chip says ("A.html").
    public let name: String
    /// Its absolute path on the host that runs the agent.
    public let path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    /// The message that goes: the words, then the attached files' paths.
    public static func message(_ text: String, files: [NativeAttachedFile]) -> String {
        guard !files.isEmpty else { return text }
        let list = (["Attached files:"] + files.map { "- \($0.path)" }).joined(separator: "\n")
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? list : text + "\n\n" + list
    }
}
