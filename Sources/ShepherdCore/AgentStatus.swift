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

public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case off, low, medium, high
}

