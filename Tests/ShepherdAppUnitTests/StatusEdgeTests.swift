import ShepherdCore
import ShepherdSessions
import Testing
@testable import ShepherdApp

/// A status change between two snapshots of the workspace, as the view model's effects and the banners read it.
@Suite("Status edge")
struct StatusEdgeTests {
    private let space = Fixture.space("acme-web", path: "/tmp/acme-web")

    private func agents(_ count: Int) -> [Agent] {
        (0..<count).map { Fixture.agent("agent-\($0)", in: space, order: $0).agent }
    }

    private func state(_ agents: [Agent]) -> ShepherdState {
        ShepherdState(spaces: [space], agents: agents)
    }

    private func with(_ agents: [Agent], _ index: Int, _ status: AgentStatus) -> [Agent] {
        var next = agents
        next[index].status = status
        return next
    }

    @Test func anEdgeCarriesTheNewStatusAndTheOldOne() throws {
        let before = with(agents(3), 1, .working)
        let after = with(before, 1, .done)
        let edge = try #require(StatusEdge.between(state(before), and: state(after)).first)
        #expect(edge.agent.id == before[1].id)
        #expect(edge.agent.status == .done)
        #expect(edge.old == .working)
        // The banners read the agent's new status: a "Turn finished" one for working to done.
        let banner = try #require(AgentBanners.status(of: edge.agent, from: edge.old, failure: nil, watching: false))
        #expect(banner.subtitle == "Turn finished")
    }

    @Test func aBlockedEdgeKeepsItsOldStatus() throws {
        let before = with(agents(2), 0, .working)
        let after = with(before, 0, .blocked)
        let edge = try #require(StatusEdge.between(state(before), and: state(after)).first)
        #expect(edge.agent.status == .blocked)
        #expect(edge.old == .working)
    }

    @Test func anAgentTheOlderSnapshotLacksHasNoEdge() {
        let before = agents(2)
        var after = before
        after.append(with(agents(1), 0, .working)[0])
        #expect(StatusEdge.between(state(before), and: state(after)).isEmpty)
    }

    @Test func anUnchangedStatusHasNoEdge() {
        let same = with(agents(4), 2, .working)
        #expect(StatusEdge.between(state(same), and: state(same)).isEmpty)
        var renamed = same
        renamed[0].name = "renamed"
        #expect(StatusEdge.between(state(same), and: state(renamed)).isEmpty)
    }

    @Test func edgesFollowTheNewerSnapshotsOrderEvenWhenTheAgentsMoved() {
        let before = agents(4)
        var after = with(before, 3, .working)
        after = with(after, 1, .done)
        after.swapAt(0, 3)
        let edges = StatusEdge.between(state(before), and: state(after))
        #expect(edges.map(\.agent.id) == [before[3].id, before[1].id])
        #expect(edges.map(\.old) == [.idle, .idle])
        #expect(edges.map(\.agent.status) == [.working, .done])
    }

    @Test func aRemovedAgentLeavesTheOthersMatchedById() throws {
        let before = agents(3)
        var after = Array(before.dropFirst())
        after[1].status = .working
        let edge = try #require(StatusEdge.between(state(before), and: state(after)).first)
        #expect(edge.agent.id == before[2].id)
        #expect(edge.old == .idle)
    }
}
