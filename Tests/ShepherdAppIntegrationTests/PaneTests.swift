import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Pane control requests from an agent's panes extension, over the real extension socket.
/// An agent may only touch its own layout, never closes or types into its own pi pane, and
/// a layout always keeps its last pane.
@Suite("Agent pane control", .integrationTimeLimit)
@MainActor
struct PaneControlTests {
    @Test func anAgentCannotCloseItsOwnPiPane() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        let reply = try await app.extensionRequest(.closePane(id: 1, agentID: agent.agent.id, paneID: agent.piPane.id))

        #expect(reply == .error(id: 1, code: "not_closable", message: "an agent cannot close its own pi pane"))
        #expect(app.server.state.tabs.first?.layout == agent.tab.layout)
    }

    @Test func anAgentCannotTypeIntoItsOwnPiPane() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        let reply = try await app.extensionRequest(.sendPaneInput(id: 2, agentID: agent.agent.id, paneID: agent.piPane.id, text: "rm -rf", submit: true))

        #expect(reply == .error(id: 2, code: "not_writable", message: "an agent cannot type into its own pi pane"))
    }

    @Test(arguments: ["close", "focus", "read", "input"])
    func anAgentCannotReachAPaneInAnotherAgentsLayout(action: String) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("mine", in: space, order: 0)
        let neighbour = Fixture.agent("theirs", in: space, order: 1, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent, neighbour]))
        vm.selectAgent(neighbour.agent.id)
        let target = neighbour.auxiliary[0].id

        let message: ExtensionMessage = switch action {
        case "close": .closePane(id: 3, agentID: agent.agent.id, paneID: target)
        case "focus": .focusPane(id: 3, agentID: agent.agent.id, paneID: target)
        case "read": .readPane(id: 3, agentID: agent.agent.id, paneID: target)
        default: .sendPaneInput(id: 3, agentID: agent.agent.id, paneID: target, text: "ls", submit: true)
        }
        let reply = try await app.extensionRequest(message)

        #expect(reply == .error(id: 3, code: "no_such_pane", message: "pane \(target) is not in this agent's layout"))
        #expect(app.server.state.tabs.map(\.layout) == [agent.tab.layout, neighbour.tab.layout])
        #expect(vm.selectedAgentID == neighbour.agent.id && vm.focusedPaneID == neighbour.piPane.id)
    }

    @Test func aLayoutAlwaysKeepsItsLastPane() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        // An agent from before pi panes were marked: its only leaf is an ordinary pane.
        let only = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(only))
        let agent = Agent(name: "legacy", spaceID: space.id, tabID: tab.id)
        try await app.start(with: ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))

        let reply = try await app.extensionRequest(.closePane(id: 4, agentID: agent.id, paneID: only.id))

        #expect(reply == .error(id: 4, code: "last_pane", message: "a layout always keeps its last pane"))
    }

    @Test func closingAnAuxiliaryPaneStopsItsProcessAndCollapsesTheLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let shell = try await app.server.createSession(params: CreateSessionParams(cwd: app.dir.path, command: ["/bin/cat"]))
        var agent = Fixture.agent(in: space, auxiliary: 1)
        agent.auxiliary[0].sessionID = shell.id
        agent.tab.layout = .split(axis: .vertical, ratio: 0.5, first: .leaf(agent.piPane), second: .leaf(agent.auxiliary[0]))
        try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        let reply = try await app.extensionRequest(.closePane(id: 5, agentID: agent.agent.id, paneID: agent.auxiliary[0].id))

        #expect(reply == .ok(id: 5))
        let server = app.server
        try await eventuallyOnMain("the layout to collapse to the pi pane") {
            server.state.tabs.first?.layout.leaves.map(\.id) == [agent.piPane.id]
        }
        try await eventuallyAsync("the pane's process to stop") { await server.sessionInfo(sessionID: shell.id)?.isAlive != true }
    }

    /// The agent's pane opens beside its thread without moving the user, gets a live shell as
    /// soon as its view mounts, and runs the command the agent asked for.
    @Test func anAgentOpenedPaneRunsItsCommandWithoutMovingTheUser() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let background = Fixture.agent("background", in: space, order: 0)
        let visible = Fixture.agent("visible", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [background, visible]))
        vm.selectAgent(visible.agent.id)

        let box = SendableReply()
        let request = Task { box.reply = try await app.extensionRequest(.openPane(
            id: 6, agentID: background.agent.id, axis: .vertical, cwd: nil, relativeTo: nil, command: "echo pane-ready"))
        }
        var opened: LeafPane?
        try await eventuallyOnMain("the new pane to join the agent's layout") {
            opened = vm.state.tabs.first { $0.id == background.tab.id }?.layout.leaves.first { $0.id != background.piPane.id }
            return opened != nil
        }
        let pane = try #require(opened)
        let tab = try #require(vm.state.tabs.first { $0.id == background.tab.id })
        // What the pane's view does when it renders.
        _ = vm.sessions.session(for: pane, in: tab)
        try await request.value

        guard case .paneOpened(6, let info)? = box.reply else { Issue.record("unexpected reply \(String(describing: box.reply))"); return }
        #expect(info.id == pane.id && info.isAlive && !info.isAgentPane)
        #expect(vm.selectedAgentID == visible.agent.id && vm.focusedPaneID == visible.piPane.id)
        try await eventuallyAsync("the command's output to show in the pane", timeout: .seconds(20)) {
            let reply = try await app.extensionRequest(.readPane(id: 7, agentID: background.agent.id, paneID: pane.id))
            guard case .paneContent(_, _, let lines) = reply else { return false }
            return lines.contains { $0.hasPrefix("pane-ready") }
        }
    }
}

/// Pane focus and layout rules the user drives from the keyboard (⌘D, ⌘W, ⌥⌘←/→).
@Suite("Pane layout", .integrationTimeLimit)
@MainActor
struct PaneLayoutTests {
    @Test func splittingTheFocusedPaneFocusesTheNewPaneAndPersists() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)

        vm.splitFocusedPane(axis: .horizontal)
        await app.settle()

        let leaves = try #require(app.server.state.tabs.first?.layout.leaves)
        #expect(leaves.count == 2 && leaves[0].id == agent.piPane.id)
        #expect(vm.focusedPaneID == leaves[1].id)
        #expect(leaves[1].cwd == agent.piPane.cwd && leaves[1].agentID == nil)
    }

    @Test func closingTheFocusedAuxiliaryPaneReturnsFocusToTheLayout() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id

        vm.closeFocusedPane()
        await app.settle()

        #expect(app.server.state.tabs.first?.layout.leaves.map(\.id) == [agent.piPane.id])
        #expect(vm.focusedPaneID == agent.piPane.id)
    }

    @Test func thePiPaneNeverClosesAsAnOrdinaryPane() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        #expect(!vm.closeLocalPane(agent.piPane.id))
        await app.settle()

        #expect(app.server.state.tabs.first?.layout == agent.tab.layout)
    }

    @Test func layoutWritesPersistInOrderAndARejectedWriteRollsBack() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let first = LeafPane(cwd: space.path), second = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(first))
        let vm = try await app.start(with: ShepherdState(spaces: [space], tabs: [tab]))
        let committed = PaneNode.split(axis: .vertical, ratio: 0.6, first: .leaf(first), second: .leaf(second))
        let invalid = PaneNode.split(axis: .vertical, ratio: 1.0, first: .leaf(first), second: .leaf(second))

        vm.setLayout(committed, forTab: tab.id)
        vm.setLayout(invalid, forTab: tab.id)
        await app.settle()

        #expect(app.server.state.tabs.first?.layout == committed)
        #expect(vm.state.tabs.first?.layout == committed)
    }

    @Test func restructuringALayoutKeepsItsPanesSessionBindings() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let sessionID = SessionID()
        let pane = LeafPane(sessionID: sessionID, cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let vm = try await app.start(with: ShepherdState(spaces: [space], tabs: [tab]))

        // The view rebuilds leaves without their bindings; the server must keep them.
        vm.setLayout(.split(axis: .vertical, ratio: 0.5, first: .leaf(LeafPane(id: pane.id, cwd: space.path)),
                            second: .leaf(LeafPane(cwd: space.path))), forTab: tab.id)
        await app.settle()

        let layout = try #require(app.server.state.tabs.first?.layout)
        #expect(layout.leaves.count == 2)
        #expect(layout.leaf(withID: pane.id)?.sessionID == sessionID)
    }
}

final class SendableReply: @unchecked Sendable {
    var reply: ExtensionReply?
}
