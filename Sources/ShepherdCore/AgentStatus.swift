public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case working
    case blocked
    case idle
    case done

    /// Transition table from the handoff:
    /// idle → working on turn start; working → blocked on approval/question;
    /// blocked → working on answer; working → done on turn completion;
    /// any → idle when the session is attached with no active turn.
    /// done → working is additionally allowed: a completed agent starting a
    /// new turn (the handoff table omits it but the lifecycle requires it).
    public func canTransition(to next: AgentStatus) -> Bool {
        if next == self { return true }
        switch (self, next) {
        case (_, .idle),
             (.idle, .working),
             (.working, .blocked),
             (.blocked, .working),
             (.working, .done),
             (.done, .working):
            return true
        default:
            return false
        }
    }
}

/// pi's thinking levels, in pi's order (`THINKING_LEVEL_OPTIONS`). Which ones a model takes is
/// pi's to say: `get_available_thinking_levels` for a running session, or `supported(…)` from
/// the catalog before one starts.
public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case off, minimal, low, medium, high, xhigh, max

    /// The four every Shepherd before the full set knows: what an older host accepts.
    public static let legacy: [ThinkingLevel] = [.off, .low, .medium, .high]

    /// "Off", "Minimal", …, "Extra high", "Max".
    public var title: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }

    /// The levels pi offers a model (pi-ai's `getSupportedThinkingLevels`): only Off without
    /// reasoning; otherwise every level its `thinkingLevelMap` does not map to null, with xhigh
    /// and max only when the map names them.
    public static func supported(reasoning: Bool, levelMap: [String: String?]? = nil) -> [ThinkingLevel] {
        guard reasoning else { return [.off] }
        return allCases.filter { level in
            guard let mapped = levelMap?[level.rawValue] else { return level != .xhigh && level != .max }
            return mapped != nil
        }
    }

    /// The level pi would use for `self` among `levels` (pi-ai's `clampThinkingLevel`): itself
    /// when offered, else the nearest higher one, else the nearest lower one.
    public func clamped(to levels: [ThinkingLevel]) -> ThinkingLevel {
        guard !levels.isEmpty, !levels.contains(self), let index = Self.allCases.firstIndex(of: self) else { return self }
        let all = Self.allCases
        if let higher = all[index...].first(where: levels.contains) { return higher }
        return all[..<index].last(where: levels.contains) ?? levels[0]
    }
}

