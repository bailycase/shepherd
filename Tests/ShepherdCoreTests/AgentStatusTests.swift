import Testing
@testable import ShepherdCore

@Suite("Agent status transitions")
struct AgentStatusTests {
    @Test func allowedTransitions() {
        #expect(AgentStatus.idle.canTransition(to: .working))
        #expect(AgentStatus.working.canTransition(to: .blocked))
        #expect(AgentStatus.blocked.canTransition(to: .working))
        #expect(AgentStatus.working.canTransition(to: .done))
        #expect(AgentStatus.done.canTransition(to: .working))
        for status in AgentStatus.allCases {
            #expect(status.canTransition(to: .idle), "any → idle must hold for \(status)")
            #expect(status.canTransition(to: status), "self-transition is a no-op for \(status)")
        }
    }

    @Test func forbiddenTransitions() {
        #expect(!AgentStatus.idle.canTransition(to: .blocked))
        #expect(!AgentStatus.idle.canTransition(to: .done))
        #expect(!AgentStatus.blocked.canTransition(to: .done))
        #expect(!AgentStatus.done.canTransition(to: .blocked))
    }
}
