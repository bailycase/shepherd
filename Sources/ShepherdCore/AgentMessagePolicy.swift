import Foundation

/// Settings ▸ Pi ▸ Agent-to-agent messages: whether an agent may act on another agent's thread
/// (message, steer, interrupt or read it, or start a new one). The host enforces it, never the
/// agent's extension.
public enum AgentMessagePolicy: String, Codable, CaseIterable, Sendable {
    /// Each call waits for the user's answer in a dialog.
    case ask
    /// Calls go through. Deleting another agent still opens its own dialog.
    case always
    /// Every call is refused without a dialog, deleting included.
    case never

    /// New installs, and what Reset settings returns to.
    public static let `default`: AgentMessagePolicy = .ask
}
