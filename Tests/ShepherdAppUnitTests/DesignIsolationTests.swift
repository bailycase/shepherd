import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// A design's agent is no thread (docs/designs.md › Design agents and ordinary threads): it
/// launches without the peer tools, and agent_list leaves it out.
@Suite("Design isolation")
@MainActor
struct DesignIsolationTests {
    private static let space = Fixture.space("web")

    /// A thread, and a design drawn by its own agent.
    private func workspace() -> (state: ShepherdState, thread: Agent, drawer: Agent) {
        let thread = Fixture.agent("Fix login bug", in: Self.space)
        var drawer = Fixture.agent("Landing hero", in: Self.space, order: 1)
        let design = Design(name: "Landing hero", spaceID: Self.space.id, agentID: drawer.agent.id, createdAt: 1)
        drawer.agent.designID = design.id
        let state = ShepherdState(spaces: [Self.space], tabs: [thread.tab, drawer.tab], agents: [thread.agent, drawer.agent],
                                  designs: [design])
        return (state, thread.agent, drawer.agent)
    }

    @Test(arguments: [(false, true, true), (true, true, false), (false, false, false), (true, false, false)])
    func onlyAThreadLaunchesWithThePanesExtension(drawsDesign: Bool, enabled: Bool, wants: Bool) {
        let agent = Agent(name: "a", spaceID: SpaceID(), tabID: TabID(), designID: drawsDesign ? DesignID() : nil)
        #expect(TerminalSessionStore.wantsPanes(for: agent, enabled: enabled) == wants)
    }

    @Test func agentListShowsThreadsAndNoDesignsAgent() {
        let (state, thread, drawer) = workspace()
        let infos = ShepherdViewModel.peerInfos(in: state, sender: thread.id)
        #expect(infos.map(\.id) == [thread.id])
        #expect(infos.first?.isSelf == true)
        #expect(!infos.contains { $0.id == drawer.id })
    }
}
