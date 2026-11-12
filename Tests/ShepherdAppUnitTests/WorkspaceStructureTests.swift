import ShepherdCore
import Testing
@testable import ShepherdApp

/// The workspace with each agent's live fields cleared, which the shell reads instead of the state: equal for states
/// that differ only in what a turn changes, so a status report, a send or a question reruns none of it.
@Suite("Workspace structure")
struct WorkspaceStructureTests {
    private let space = Fixture.space("acme-web", path: "/tmp/acme-web")

    private func state(_ count: Int = 3) -> ShepherdState {
        let made = (0..<count).map { Fixture.agent("agent-\($0)", in: space, order: $0) }
        return ShepherdState(spaces: [space], tabs: made.map(\.tab), agents: made.map(\.agent))
    }

    private func masked(_ state: ShepherdState) -> ShepherdState { state.withoutLiveAgentFields }

    @Test func statesDifferingOnlyInLiveFieldsMaskEqual() {
        let base = state()
        let changes: [(inout Agent) -> Void] = [
            { $0.status = .working },
            { $0.status = .blocked },
            { $0.lastActiveAt = 1_800_000_000_000 },
            { $0.waitingOn = "Which database?" },
            { $0.waitingReason = "database?" },
            { $0.completedAt = 1_800_000_000_001 },
            { $0.seenCompletedAt = 1_800_000_000_001 },
        ]
        for change in changes {
            var other = base
            change(&other.agents[1])
            #expect(other != base)
            #expect(masked(other) == masked(base))
        }
    }

    @Test func aTurnsEveryLiveFieldAtOnceMasksEqual() {
        let base = state()
        var turn = base
        for index in turn.agents.indices {
            turn.agents[index].status = .done
            turn.agents[index].lastActiveAt = 1_800_000_000_000
            turn.agents[index].waitingOn = "Ship it?"
            turn.agents[index].waitingReason = "ship?"
            turn.agents[index].completedAt = 1_800_000_000_000
        }
        #expect(masked(turn) == masked(base))
    }

    @Test func statesDifferingInStructureMaskUnequal() {
        let base = state()
        let other = Fixture.agent("other", in: space, order: 9)
        let changes: [(inout ShepherdState) -> Void] = [
            { $0.agents[1].name = "Renamed" },
            { $0.agents[1].tabID = $0.agents[2].tabID },
            { $0.agents[1].spaceID = SpaceID() },
            { $0.agents[1].piSessionID = "another-session" },
            { $0.agents[1].checkout = AgentCheckout(branch: "main", changedFiles: 2) },
            { $0.agents[1].goalState = "active" },
            { $0.agents[1].lastFailure = "pi stopped" },
            { $0.agents[1].designID = DesignID() },
            { $0.tabs.removeLast() },
            { $0.tabs[0].order = 7 },
            { $0.spaces[0].name = "acme-api" },
            { $0.spaces.append(Fixture.space("acme-api")) },
            { $0.agents.append(other.agent) },
            { $0.agents.removeLast() },
        ]
        for change in changes {
            var changed = base
            change(&changed)
            #expect(masked(changed) != masked(base))
        }
    }

    @Test func everyOtherFieldIsKept() {
        var base = state()
        base.agents[1].name = "Fix login"
        base.agents[1].piSessionID = "session-1"
        base.agents[1].checkout = AgentCheckout(branch: "agent/calm-stone", changedFiles: 3)
        base.agents[1].lastFailure = "pi stopped"
        base.agents[1].goalState = "active"
        base.agents[1].status = .blocked
        base.agents[1].lastActiveAt = 1_800_000_000_000
        base.agents[1].waitingOn = "Which database?"
        base.agents[1].waitingReason = "database?"
        base.agents[1].completedAt = 1_800_000_000_000
        base.agents[1].seenCompletedAt = 1_800_000_000_000

        let agent = masked(base).agents[1]
        #expect(agent.status == .idle)
        #expect([agent.lastActiveAt, agent.completedAt, agent.seenCompletedAt] == [nil, nil, nil])
        #expect([agent.waitingOn, agent.waitingReason] == [nil, nil])
        #expect(agent.name == "Fix login" && agent.piSessionID == "session-1" && agent.goalState == "active")
        #expect(agent.checkout == AgentCheckout(branch: "agent/calm-stone", changedFiles: 3) && agent.lastFailure == "pi stopped")

        var rest = base.agents[1]
        rest.status = .idle
        (rest.lastActiveAt, rest.waitingOn, rest.waitingReason, rest.completedAt, rest.seenCompletedAt) = (nil, nil, nil, nil, nil)
        #expect(agent == rest)
        #expect(masked(base).spaces == base.spaces && masked(base).tabs == base.tabs)
        #expect(masked(base).agents.map(\.id) == base.agents.map(\.id))
    }

    @Test func maskingIsIdempotent() {
        var base = state()
        base.agents[0].status = .working
        base.agents[0].waitingOn = "Which database?"
        #expect(masked(masked(base)) == masked(base))
    }
}
