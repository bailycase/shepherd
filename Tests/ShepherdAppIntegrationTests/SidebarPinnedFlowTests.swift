import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Pinned threads against a real view model (Sidebar › Pinned): pinning moves a row, the pins
/// outlive the view model, and what is gone is forgotten.
@Suite("Sidebar pinned flow", .mainActorExclusive)
@MainActor
struct SidebarPinnedFlowTests {
    private func fleet(_ app: AppHarness, count: Int = 4) -> (ShepherdState, [AgentFixture]) {
        let space = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        var fixtures = (0..<count).map { Fixture.agent("agent-\($0)", in: space, order: $0) }
        for index in fixtures.indices { fixtures[index].agent.lastActiveAt = Double(100 - index) }
        return (Fixture.state(spaces: [space], agents: fixtures), fixtures)
    }

    @Test func pinningAThreadMovesItsRowToPinnedAndUnpinningReturnsIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app)
        let vm = try await app.start(with: state)
        #expect(vm.sidebarLists.pinned.isEmpty)

        vm.pinThread(.local(agents[2].agent.id))
        #expect(vm.isPinned(.local(agents[2].agent.id)))
        #expect(vm.sidebarLists.pinned.map(\.title) == ["agent-2"])
        #expect(vm.sidebarLists.recents.map(\.title) == ["agent-0", "agent-1", "agent-3"])

        vm.pinThread(.local(agents[0].agent.id))
        #expect(vm.sidebarLists.pinned.map(\.title) == ["agent-2", "agent-0"], "oldest pin first")

        vm.unpinThread(.local(agents[2].agent.id))
        #expect(!vm.isPinned(.local(agents[2].agent.id)))
        #expect(vm.sidebarLists.pinned.map(\.title) == ["agent-0"])
        #expect(vm.sidebarLists.recents.map(\.title) == ["agent-1", "agent-2", "agent-3"], "back in its place by activity")
    }

    @Test func togglingPinsAndUnpinsAndAsksNothingOfAnUnknownThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app, count: 2)
        let vm = try await app.start(with: state)
        let row = SidebarRowID.local(agents[1].agent.id)
        vm.togglePin(row)
        #expect(vm.isPinned(row))
        vm.togglePin(row)
        #expect(!vm.isPinned(row))
        vm.pinThread(.local(AgentID()))
        #expect(vm.sidebarPins.isEmpty, "a thread this Mac doesn't list is never pinned")
    }

    /// ⌘1–9 and ⌘↑/↓ follow the rows as drawn: a pinned thread takes ⌘1 and the walk starts
    /// with it, and the Agent menu lists the same.
    @Test func digitsAndTheWalkFollowPinnedRowsFirst() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app)
        let vm = try await app.start(with: state)
        vm.pinThread(.local(agents[2].agent.id))

        vm.selectAgentDigit(1)
        #expect(vm.selectedAgentID == agents[2].agent.id)
        vm.selectAgentDigit(2)
        #expect(vm.selectedAgentID == agents[0].agent.id)
        #expect(MenuState.Snapshot(vm).agents.map(\.title) == ["agent-2", "agent-0", "agent-1", "agent-3"])
        vm.selectAgentDigit(1)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == agents[0].agent.id, "Pinned, then Recents")
        vm.selectAdjacentAgent(-1)
        vm.selectAdjacentAgent(-1)
        #expect(vm.selectedAgentID == agents[3].agent.id, "before Pinned, wrapping to the end of Recents")
    }

    @Test func pinsSurviveARelaunchOfTheViewModel() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app)
        let vm = try await app.start(with: state)
        vm.pinThread(.local(agents[3].agent.id))
        vm.pinThread(.local(agents[1].agent.id))

        let relaunched = ShepherdViewModel(
            server: app.server, settings: app.settings, keybindings: app.keybindings, themeManager: app.themeManager,
            remoteHosts: app.remoteHosts, sidebarDefaults: app.defaults, themeInstaller: { _ in },
            restoresAgentsAtLaunch: false, checkoutReader: nil)
        #expect(relaunched.sidebarPins == vm.sidebarPins)
        #expect(relaunched.sidebarPins.threads == [.local(agents[3].agent.id), .local(agents[1].agent.id)])
    }

    /// A deleted thread's pin goes with it, and nothing is forgotten before the workspace loads.
    @Test func aDeletedThreadsPinIsForgotten() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app)
        let vm = try await app.start(with: state)
        vm.pinThread(.local(agents[1].agent.id))
        vm.pinThread(.local(agents[2].agent.id))

        var next = vm.state
        next.agents.removeAll { $0.id == agents[1].agent.id }
        next.tabs.removeAll { $0.id == agents[1].tab.id }
        vm.adopt(next)
        #expect(vm.sidebarPins.threads == [.local(agents[2].agent.id)])
        #expect(app.defaults.stringArray(forKey: SidebarPins.defaultsKey) == [PinnedThread.local(agents[2].agent.id).key])
    }

    /// Pins load with the view model, before the workspace does: nothing is known to be gone yet.
    @Test func aPinIsNotForgottenBeforeTheWorkspaceIsAdopted() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app, count: 2)
        try await app.start(with: state).pinThread(.local(agents[0].agent.id))
        let relaunched = ShepherdViewModel(
            server: app.server, settings: app.settings, keybindings: app.keybindings, themeManager: app.themeManager,
            remoteHosts: app.remoteHosts, sidebarDefaults: app.defaults, themeInstaller: { _ in },
            restoresAgentsAtLaunch: false, checkoutReader: nil)
        try #require(!relaunched.didAdopt && relaunched.state.agents.isEmpty)
        relaunched.pruneSidebarPins()
        #expect(relaunched.sidebarPins.threads == [.local(agents[0].agent.id)])
        try await eventuallyOnMain("the view model to adopt the workspace") { relaunched.state == app.server.state }
        #expect(relaunched.sidebarPins.threads == [.local(agents[0].agent.id)])
    }

    /// A host's thread pins by the host's configured id, dims with its host, and goes when the
    /// host is removed.
    @Test func aHostsThreadIsPinnedAndForgottenWithItsHost() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, _) = fleet(app, count: 1)
        let vm = try await app.start(with: state)
        app.remoteHosts.addHost(name: "horizon", host: "127.0.0.1", port: 1, token: "x")
        let connection = try #require(app.remoteHosts.connections.first)
        let space = Fixture.space("remote", path: "/remote")
        let remote = Fixture.agent("remote thread", in: space).agent
        connection.state = ShepherdState(spaces: [space], agents: [remote])
        let ref = RemoteAgentRef(hostID: connection.id, agentID: remote.id)

        vm.pinThread(.remote(ref))
        #expect(vm.sidebarLists.pinned.map(\.id) == [.remote(ref)])
        #expect(vm.sidebarLists.pinned.first?.offline == true, "not connected: its last known state, dimmed")
        #expect(vm.sidebarLists.recents.map(\.title) == ["agent-0"])

        app.remoteHosts.removeHost(id: connection.id)
        #expect(vm.sidebarPins.isEmpty)
    }

    @Test func automationRunsAndDesignsCannotBePinned() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        var (state, agents) = fleet(app, count: 2)
        state.automations = [Automation(name: "Nightly", prompt: "p", cwd: "/tmp", agentID: agents[1].agent.id)]
        let vm = try await app.start(with: state)
        #expect(!vm.canPin(.local(agents[1].agent.id)))
        vm.pinThread(.local(agents[1].agent.id))
        #expect(vm.sidebarPins.isEmpty)
        #expect(vm.canPin(.local(agents[0].agent.id)))
        #expect(!vm.canPin(.design(DesignID())))
    }

    /// The project tree draws no Pinned section, so it offers no Pin: not on its rows, not in the
    /// header, not in the palette; the pins stay for the Activity sidebar.
    @Test func theProjectTreeOffersNoPin() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app, count: 2)
        let vm = try await app.start(with: state)
        let row = SidebarRowID.local(agents[0].agent.id)
        vm.pinThread(row)
        #expect(vm.offersPin(for: row))
        vm.settings.sidebarStyle = .projects
        vm.settings.sidebarKeepIdleDays = 0
        #expect(!vm.offersPin(for: row))
        #expect(vm.isPinned(row), "kept for when Activity comes back")
        let treeRows = vm.sidebarTree.projects.flatMap(\.rows)
        #expect(treeRows.count == 2 && treeRows.allSatisfy { !$0.pinnable && !$0.pinned })
    }
}
