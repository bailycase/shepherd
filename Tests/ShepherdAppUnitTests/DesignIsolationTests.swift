import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// A design's agent is no thread (docs/designs.md › Design agents and ordinary threads): it
/// launches without the peer tools, agent_list leaves it out, and a host's design agents make no
/// rows here, whether the Design tool is on or off.
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

    /// A host that sends its design agents (one from before `withoutDesigns`) still gives them
    /// no row, no ⌘-digit, and no Needs you.
    @Test(arguments: [false, true])
    func aHostsDesignAgentIsNoRowHere(designToolOn: Bool) {
        var (hostState, thread, drawer) = workspace()
        hostState.agents[1].status = .blocked
        hostState.agents[1].waitingOn = "Which hero?"
        let host = UUID()
        let lists = SidebarDerivation.lists(SidebarSource(
            local: ShepherdState(spaces: [Self.space]),
            hosts: [SidebarSource.Host(id: host, name: "horizon", state: hostState, children: [:])],
            designs: designToolOn))
        #expect(lists.all.map(\.id) == [.remote(RemoteAgentRef(hostID: host, agentID: thread.id))])
        #expect(lists.needsYou.isEmpty)
        #expect(!lists.shortcutRows.contains { $0.id == .remote(RemoteAgentRef(hostID: host, agentID: drawer.id)) })
    }
}
