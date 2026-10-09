import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Terminal control requests from an agent's panes extension (its `terminal_*` tools), over the
/// real extension socket. An agent may only touch terminals in its own layout, never closes or
/// types into its own thread, never sees it listed, and every terminal it opens is a tab.
@Suite("Agent terminal control", .mainActorExclusive)
@MainActor
struct PaneControlTests {
    @Test func anAgentCannotCloseItsOwnThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        let reply = try await app.extensionRequest(.closePane(id: 1, agentID: agent.agent.id, paneID: agent.piPane.id))

        #expect(reply == .error(id: 1, code: "not_closable", message: "\(agent.piPane.id) is the agent's own thread, not a terminal"))
        #expect(app.server.state.tabs.first?.layout == agent.tab.layout)
    }

    @Test func anAgentCannotTypeIntoItsOwnThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        let reply = try await app.extensionRequest(.sendPaneInput(id: 2, agentID: agent.agent.id, paneID: agent.piPane.id, text: "rm -rf", submit: true))

        #expect(reply == .error(id: 2, code: "not_writable", message: "\(agent.piPane.id) is the agent's own thread, not a terminal"))
    }

    @Test(arguments: ["focus", "read"])
    func theThreadIsNotATerminalToFocusOrRead(action: String) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id

        let message: ExtensionMessage = action == "focus"
            ? .focusPane(id: 3, agentID: agent.agent.id, paneID: agent.piPane.id)
            : .readPane(id: 3, agentID: agent.agent.id, paneID: agent.piPane.id)
        let reply = try await app.extensionRequest(message)

        #expect(reply == .error(id: 3, code: "no_such_terminal", message: "\(agent.piPane.id) is the agent's own thread, not a terminal"))
        #expect(vm.focusedPaneID == agent.auxiliary[0].id, "the user's keyboard did not move")
    }

    @Test(arguments: ["close", "focus", "read", "input"])
    func anAgentCannotReachATerminalInAnotherAgentsLayout(action: String) async throws {
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

        #expect(reply == .error(id: 3, code: "no_such_terminal", message: "terminal \(target) is not in this agent's layout"))
        #expect(app.server.state.tabs.map(\.layout) == [agent.tab.layout, neighbour.tab.layout])
        #expect(vm.selectedAgentID == neighbour.agent.id && vm.focusedPaneID == neighbour.piPane.id)
    }

    /// The list is the agent's terminals, oldest first; its own thread is never among them.
    @Test func listingTheTerminalsNeverIncludesTheThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 2)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id

        let reply = try await app.extensionRequest(.listPanes(id: 4, agentID: agent.agent.id))

        guard case .panes(4, let terminals) = reply else { Issue.record("unexpected reply \(reply)"); return }
        #expect(!terminals.contains { $0.id == agent.piPane.id || $0.isAgentPane })
        #expect(Set(terminals.map(\.id)) == Set(agent.auxiliary.map(\.id)))
        #expect(terminals.map(\.id) == TerminalPanel.tabs(in: agent.tab.layout, thread: agent.piPane.id).map(\.id), "oldest first, as the tabs are")
        #expect(terminals.first { $0.id == agent.auxiliary[0].id }?.isFocused == true)
    }

    @Test func aLayoutsOnlyTerminalCannotBeClosed() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        // An agent from before its pi leaf was marked: its only leaf is an ordinary one.
        let only = LeafPane(cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(only))
        let agent = Agent(name: "legacy", spaceID: space.id, tabID: tab.id)
        try await app.start(with: ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))

        let reply = try await app.extensionRequest(.closePane(id: 4, agentID: agent.id, paneID: only.id))

        #expect(reply == .error(id: 4, code: "not_closable", message: "the layout's only terminal cannot be closed"))
    }

    @Test func closingATerminalStopsItsProcessAndCollapsesTheLayout() async throws {
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
        try await eventuallyOnMain("the layout to collapse to the thread") {
            server.state.tabs.first?.layout.leaves.map(\.id) == [agent.piPane.id]
        }
        try await eventuallyAsync("the terminal's process to stop") { await server.sessionInfo(sessionID: shell.id)?.isAlive != true }
    }

    /// The agent's terminal opens as a tab under its thread without moving the user, gets a live
    /// shell as soon as its view mounts, and runs the command the agent asked for.
    @Test func anAgentOpenedTerminalRunsItsCommandWithoutMovingTheUser() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let background = Fixture.agent("background", in: space, order: 0)
        let visible = Fixture.agent("visible", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [background, visible]))
        vm.selectAgent(visible.agent.id)

        let box = SendableReply()
        // The command echo cannot contain its output marker, even with prompt redraws.
        let command = "printf 'terminal-%s\\n' ready"
        let request = Task { box.reply = try await app.extensionRequest(.openPane(
            id: 6, agentID: background.agent.id, axis: .vertical, cwd: nil, relativeTo: nil, command: command))
        }
        var opened: LeafPane?
        try await eventuallyOnMain("the new terminal to join the agent's layout") {
            opened = vm.state.tabs.first { $0.id == background.tab.id }?.layout.leaves.first { $0.id != background.piPane.id }
            return opened != nil
        }
        let terminal = try #require(opened)
        let tab = try #require(vm.state.tabs.first { $0.id == background.tab.id })
        // What the terminal's view does when it renders.
        _ = vm.sessions.session(for: terminal, in: tab)
        try await request.value

        guard case .paneOpened(6, let info)? = box.reply else { Issue.record("unexpected reply \(String(describing: box.reply))"); return }
        #expect(info.id == terminal.id && info.isAlive && !info.isAgentPane)
        #expect(vm.selectedAgentID == visible.agent.id && vm.focusedPaneID == visible.piPane.id)
        #expect(TerminalPanel.tabs(in: tab.layout, thread: background.piPane.id).map(\.id) == [terminal.id])
        var lastRead = "no reply"
        do {
            try await eventuallyAsync("the command's output to show in the terminal", timeout: .seconds(20)) {
                let reply = try await app.extensionRequest(.readPane(id: 7, agentID: background.agent.id, paneID: terminal.id))
                guard case .paneContent(_, _, let lines) = reply else {
                    if case .error(_, let code, _) = reply { lastRead = "error code \(code)" }
                    else { lastRead = "unexpected reply kind" }
                    return false
                }
                let markerRows = lines.enumerated().compactMap { row, line in
                    line.range(of: "terminal-ready").map { "\(row):\(line.distance(from: line.startIndex, to: $0.lowerBound))" }
                }
                lastRead = "rows=\(lines.count), marker row:column=\(markerRows), command-not-found=\(lines.contains { $0.contains("command not found") }), compinit-warning=\(lines.contains { $0.contains("insecure directories") || $0.contains("compinit") })"
                // Screen readback need not put output at column zero.
                return lines.contains { $0.contains("terminal-ready") }
            }
        } catch let error as TimedOut {
            let pane = vm.sessions.session(for: terminal, in: tab)
            let phase: String
            switch pane.phase {
            case .connecting: phase = "connecting"
            case .live: phase = "live"
            case .failed: phase = "failed"
            case .exited: phase = "exited"
            case .stopped: phase = "stopped"
            }
            print("Agent-opened terminal: phase=\(phase), bound=\(pane.sessionID != nil), reported grid=\(pane.lastCols)x\(pane.lastRows), last read=\(lastRead)")
            throw error
        }
    }

    /// The panel of the thread on screen opens on the terminal the agent opened, and the keyboard
    /// stays where it was.
    @Test func aTerminalTheAgentOpensShowsThePanelOnItsTabAndLeavesTheKeyboard() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let key = TerminalPanelKey(host: nil, tab: agent.tab.id)
        #expect(vm.terminalTarget?.tabs.isEmpty == true && !vm.terminalPanels.panel(key).shown)

        let box = SendableReply()
        let request = Task { box.reply = try await app.extensionRequest(.openPane(
            id: 8, agentID: agent.agent.id, axis: .vertical, cwd: nil, relativeTo: nil, command: nil))
        }
        var opened: LeafPane?
        try await eventuallyOnMain("the terminal to join the layout") {
            opened = vm.state.tabs.first { $0.id == agent.tab.id }?.layout.leaves.first { $0.id != agent.piPane.id }
            return opened != nil
        }
        let terminal = try #require(opened)
        _ = vm.sessions.session(for: terminal, in: try #require(vm.state.tabs.first { $0.id == agent.tab.id }))
        try await request.value

        #expect(vm.terminalTarget?.tabs.map(\.id) == [terminal.id])
        #expect(vm.terminalPanels.panel(key).shown && vm.terminalPanels.panel(key).chosenTab == terminal.id)
        #expect(vm.focusedPaneID == agent.piPane.id)
    }

    /// An older client names where to split (a pane, an axis): the request is served as a new tab
    /// under the thread, the layout stays flat, and it answers as it always did.
    @Test(arguments: [SplitAxis.vertical, .horizontal])
    func aRequestToSplitBesideATerminalOpensANewTabInstead(axis: SplitAxis) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let key = TerminalPanelKey(host: nil, tab: agent.tab.id)
        vm.selectAgent(agent.agent.id)
        #expect(vm.terminalTarget?.tabs.count == 1, "the panel has seen the terminal that was already there")

        let box = SendableReply()
        let request = Task { box.reply = try await app.extensionRequest(.openPane(
            id: 9, agentID: agent.agent.id, axis: axis, cwd: nil, relativeTo: agent.auxiliary[0].id, command: nil))
        }
        var layout: PaneNode?
        try await eventuallyOnMain("the new terminal to join the layout") {
            layout = vm.state.tabs.first { $0.id == agent.tab.id }?.layout
            return layout?.leaves.count == 3
        }
        let grown = try #require(layout)
        let terminal = try #require(grown.leaves.first { $0.id != agent.piPane.id && $0.id != agent.auxiliary[0].id })
        _ = vm.sessions.session(for: terminal, in: try #require(vm.state.tabs.first { $0.id == agent.tab.id }))
        try await request.value

        guard case .paneOpened(9, let info)? = box.reply else { Issue.record("unexpected reply \(String(describing: box.reply))"); return }
        #expect(info.id == terminal.id)
        #expect(!grown.hasSplitTerminals(besideThread: agent.piPane.id), "no terminal shares a tab")
        #expect(TerminalPanel.tabs(in: grown, thread: agent.piPane.id).count == 2)
        #expect(vm.terminalTarget?.tabs.count == 2 && vm.terminalPanels.panel(key).chosenTab == terminal.id)
    }

    /// Opening in another folder keeps the folder; the default is the thread's.
    @Test func aTerminalOpensInTheThreadsFolderUnlessToldOtherwise() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let elsewhere = try makeScratchDirectory("elsewhere")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        for (id, folder) in [(10, String?.none), (11, elsewhere.path)] {
            let box = SendableReply()
            let before = vm.state.tabs.first { $0.id == agent.tab.id }?.layout.leaves.count ?? 0
            let request = Task { box.reply = try await app.extensionRequest(.openPane(
                id: id, agentID: agent.agent.id, axis: .vertical, cwd: folder, relativeTo: nil, command: nil))
            }
            try await eventuallyOnMain("terminal \(id) to join the layout") {
                (vm.state.tabs.first { $0.id == agent.tab.id }?.layout.leaves.count ?? 0) > before
            }
            let tab = try #require(vm.state.tabs.first { $0.id == agent.tab.id })
            for leaf in tab.layout.leaves where leaf.agentID == nil { _ = vm.sessions.session(for: leaf, in: tab) }
            try await request.value
            guard case .paneOpened(id, let info)? = box.reply else { Issue.record("unexpected reply \(String(describing: box.reply))"); return }
            #expect(info.cwd == (folder ?? space.path))
        }
    }
}

/// Terminal focus and layout rules the user drives from the keyboard (⌘D, ⌘W).
@Suite("Terminal layout", .mainActorExclusive)
@MainActor
struct PaneLayoutTests {
    @Test func aNewTerminalIsATabUnderTheThreadInItsFolderAndTakesTheKeyboard() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)

        vm.newTerminalTab()
        await app.settle()

        let layout = try #require(app.server.state.tabs.first?.layout)
        let leaves = layout.leaves
        #expect(leaves.count == 2 && leaves[0].id == agent.piPane.id)
        #expect(vm.focusedPaneID == leaves[1].id)
        #expect(leaves[1].cwd == agent.piPane.cwd && leaves[1].agentID == nil)
        #expect(TerminalPanel.tabs(in: layout, thread: agent.piPane.id).map(\.id) == [leaves[1].id])
    }

    @Test func closingTheFocusedTerminalReturnsFocusToTheThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id

        vm.closeFocusedTerminal()
        await app.settle()

        #expect(app.server.state.tabs.first?.layout.leaves.map(\.id) == [agent.piPane.id])
        #expect(vm.focusedPaneID == agent.piPane.id)
    }

    @Test func theThreadNeverClosesAsATerminal() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)

        #expect(!vm.closeLocalPane(agent.piPane.id))
        vm.focusedPaneID = agent.piPane.id
        vm.closeFocusedTerminal()
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

    @Test func restructuringALayoutKeepsItsTerminalsSessionBindings() async throws {
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
