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
        #expect(ThinkingLevel.allCases.map(\.rawValue) == ["off", "low", "medium", "high"])
    }
}
