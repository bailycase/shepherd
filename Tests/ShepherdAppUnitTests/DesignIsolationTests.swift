import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A design's agent is no thread (docs/designs.md › Design agents and ordinary threads): it
/// launches without the peer tools, agent_list leaves it out, the palette never searches its
/// chat, it posts no thread's banners, the Hosts page counts no thread for it, and a host's
/// design agents make no rows here, whether the Design tool is on or off.
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

    @Test func thePalettesTranscriptSearchNeverReadsADesignsChat() {
        let (state, thread, _) = workspace()
        #expect(ShepherdViewModel.paletteSearchTargets(in: state).map(\.id) == [thread.id])
    }

    @Test func onlyAThreadsTurnsAndQuestionsPostAsAThreads() {
        let (state, thread, drawer) = workspace()
        #expect(ShepherdViewModel.notifiesAsThread(thread.id, in: state))
        #expect(!ShepherdViewModel.notifiesAsThread(drawer.id, in: state))
    }

    /// The Hosts page counts threads: a design's agent at work is none of them, here or on a
    /// host's last pushed state.
    @Test func theHostsPageNeverCountsADesignsAgentAsAThread() {
        var (state, _, _) = workspace()
        state.agents[1].status = .working
        #expect(HostsPageModel.connectedFacts(state, address: nil).first { $0.label == "Running" }?.value == "none")
        let offline = HostsPageModel.offlineFacts(state, lastSeen: nil, address: "horizon:7433",
                                                  timeZone: .gmt, locale: Locale(identifier: "en_US"))
        #expect(offline.first { $0.label == "Waiting" }?.value == "1 thread")
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
