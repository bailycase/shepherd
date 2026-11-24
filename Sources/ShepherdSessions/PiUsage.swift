import Foundation

/// How much of a provider's limits are used: one entry per window its usage extension reports
/// ("5-hour", "Week"). Shepherd reads no provider itself: Anthropic's and OpenAI Codex's come from
/// its bundled `shepherd-usage.mjs`, like any other provider extension's.
public struct PiUsageWindow: Equatable, Sendable {
    public var name: String
    /// 0–100.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(name: String, usedPercent: Double, resetsAt: Date?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}
