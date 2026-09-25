import Testing
import ShepherdCore

@Suite("Agent status transition table")
struct AgentStatusTests {
    /// Every allowed edge besides self-loops and "anything → idle". `done → working` is the
    /// deliberate addition to the handoff table: a finished agent starting a new turn.
    private static let allowedEdges: Set<[AgentStatus]> = [
        [.idle, .working],
        [.working, .blocked],
        [.blocked, .working],
        [.working, .done],
        [.done, .working],
    ]

    private static var allPairs: [(AgentStatus, AgentStatus)] {
        AgentStatus.allCases.flatMap { from in AgentStatus.allCases.map { (from, $0) } }
    }

    @Test(arguments: allPairs)
    func transitionMatchesTheTable(from: AgentStatus, to: AgentStatus) {
        let expected = from == to || to == .idle || Self.allowedEdges.contains([from, to])
        #expect(from.canTransition(to: to) == expected, "\(from) → \(to)")
    }

    @Test func aCompletedAgentMayStartANewTurn() {
        #expect(AgentStatus.done.canTransition(to: .working))
    }

    @Test(arguments: [(AgentStatus.idle, AgentStatus.done), (.idle, .blocked), (.blocked, .done), (.done, .blocked)])
    func skippingTheWorkingStateIsForbidden(from: AgentStatus, to: AgentStatus) {
        #expect(!from.canTransition(to: to))
    }

    @Test func rawValuesAreTheWireSpelling() {
        #expect(AgentStatus.allCases.map(\.rawValue) == ["working", "blocked", "idle", "done"])
        #expect(ThinkingLevel.allCases.map(\.rawValue) == ["off", "minimal", "low", "medium", "high", "xhigh", "max"])
        #expect(ThinkingLevel.allCases.map(\.title) == ["Off", "Minimal", "Low", "Medium", "High", "Extra high", "Max"])
    }

    /// pi-ai's `getSupportedThinkingLevels`: Off alone without reasoning; xhigh and max only
    /// when the model's map names them; a level mapped to null dropped.
    @Test(arguments: [
        (false, nil as [String: String?]?, ["off"]),
        (true, nil, ["off", "minimal", "low", "medium", "high"]),
        (true, ["xhigh": "xhigh"], ["off", "minimal", "low", "medium", "high", "xhigh"]),
        (true, ["xhigh": "high", "max": "max"], ["off", "minimal", "low", "medium", "high", "xhigh", "max"]),
        (true, ["off": "off", "minimal": nil, "low": nil, "medium": "medium", "high": nil, "xhigh": nil], ["off", "medium"]),
    ])
    func aModelTakesTheLevelsPiSupportsForIt(reasoning: Bool, map: [String: String?]?, expected: [String]) {
        #expect(ThinkingLevel.supported(reasoning: reasoning, levelMap: map).map(\.rawValue) == expected)
    }

    /// A level a model lacks becomes the one pi would use: the nearest higher, else lower.
    @Test(arguments: [
        (ThinkingLevel.xhigh, [ThinkingLevel.off, .minimal, .low, .medium, .high], ThinkingLevel.high),
        (.minimal, [.off, .low, .medium, .high], .low),
        (.low, [.off, .medium], .medium),
        (.medium, [.off, .minimal, .low, .medium, .high], .medium),
        (.max, [], .max),
    ])
    func aLevelClampsAsPiClampsIt(_ level: ThinkingLevel, _ levels: [ThinkingLevel], _ expected: ThinkingLevel) {
        #expect(level.clamped(to: levels) == expected)
    }
}
