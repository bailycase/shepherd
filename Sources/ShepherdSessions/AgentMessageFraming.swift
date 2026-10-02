import Foundation

/// What a thread reads when another agent messages or steers it (`agent_send`, `agent_steer`):
/// the text arrives as a user message, so the first words say it is an agent's and not the
/// user's, and that a reply is for when it asks for one. The panes extension's prompt rules say
/// the same once for the whole session (docs/agent-coordination.md › What the other thread reads).
public enum AgentMessageFraming {
    /// The longest sender name the header carries.
    static let nameLimit = 80

    /// `text` under the header naming `sender`.
    public static func framed(from sender: String, _ text: String) -> String {
        "[from: \(label(sender)), an agent, not the user. Reply with agent_send only if this asks for a reply.] \(text)"
    }

    /// A name as one short line that cannot close the header early: an agent's name comes from
    /// its first prompt, so it may hold line breaks and brackets.
    static func label(_ name: String) -> String {
        let flat = name.unicodeScalars.map { $0 == "[" || $0 == "]" ? " " : ($0.properties.isWhitespace ? " " : Character($0)) }
        let words = String(flat).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !words.isEmpty else { return "an agent" }
        return words.count <= nameLimit ? words : String(words.prefix(nameLimit - 1)) + "…"
    }
}
