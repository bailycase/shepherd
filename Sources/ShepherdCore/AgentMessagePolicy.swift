import Foundation

/// Legacy server access policy. The app permits peer calls without a Settings preference,
/// but retains the raw values and server APIs for existing consumers.
public enum AgentMessagePolicy: String, Codable, CaseIterable, Sendable {
    /// Interactive threads may act immediately; unattended automation runs are refused.
    /// The stored name is retained for existing settings.
    case ask
    /// All threads, including automation runs, may act immediately.
    case always
    /// Every call is refused without a dialog, deleting included.
    case never

    /// Default for standalone server consumers. The app selects `always`.
    public static let `default`: AgentMessagePolicy = .ask
}
