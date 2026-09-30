import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The terminal panel under a thread (TerminalSplit, TerminalStates boards) as the keyboard and
/// its strip drive it: a terminal is a tab, ⌘J with none opens one, hiding hands the keyboard
/// back, Next and Previous Terminal move among the tabs, and closing a tab never closes the thread.
@Suite("Terminal panel", .mainActorExclusive)
@MainActor
struct TerminalPanelTests {
    @Test func aNewTabIsATerminalBesideTheThreadAndTakesTheKeyboard() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)

        vm.newTerminalTab()
        await app.settle()

        let layout = try #require(app.server.state.tabs.first?.layout)
        let tabs = TerminalPanel.tabs(in: layout, thread: agent.piPane.id)
        #expect(tabs.count == 2)
        let added = try #require(layout.leaves.map(\.id).first { $0 != agent.piPane.id && $0 != agent.auxiliary[0].id })
        #expect(tabs.contains { $0.id == added })
        #expect(vm.focusedPaneID == added)
        #expect(!layout.hasSplitTerminals(besideThread: agent.piPane.id))
    }

    /// ⌘D in a terminal no longer splits it: it opens a new tab, from a terminal as from the thread.
    @Test func newTerminalFromATerminalOpensATabNotASplit() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id

        vm.newTerminalTab()
        await app.settle()

        let layout = try #require(app.server.state.tabs.first?.layout)
        #expect(TerminalPanel.tabs(in: layout, thread: agent.piPane.id).count == 2)
        #expect(!layout.hasSplitTerminals(besideThread: agent.piPane.id))
    }

    /// ⌘J in a thread with no terminal opens one in the thread's folder, shows the panel on it and
    /// gives it the keyboard: there is never an empty panel to show.
    @Test func showingTheTerminalWithNoneOpensOne() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let key = TerminalPanelKey(host: nil, tab: agent.tab.id)
        #expect(!vm.isTerminalPanelShowing)

        vm.toggleTerminalPanel()
        await app.settle()

        let layout = try #require(app.server.state.tabs.first?.layout)
        let terminal = try #require(layout.leaves.first { $0.id != agent.piPane.id })
        #expect(terminal.cwd == agent.piPane.cwd && terminal.agentID == nil)
        #expect(vm.isTerminalPanelShowing)
        #expect(vm.terminalPanels.panel(key).chosenTab == terminal.id)
        #expect(vm.focusedPaneID == terminal.id)
        #expect(vm.terminalTarget?.tabs.map(\.id) == [terminal.id])
    }

    /// With terminals already there, ⌘J shows them and opens nothing.
    @Test func showingTheTerminalWithSomeOpensNothing() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let key = TerminalPanelKey(host: nil, tab: agent.tab.id)
        vm.terminalPanels.update(key) { $0.shown = false }

        vm.toggleTerminalPanel()
        await app.settle()

        #expect(app.server.state.tabs.first?.layout == agent.tab.layout)
        #expect(vm.isTerminalPanelShowing && vm.focusedPaneID == agent.auxiliary[0].id)
    }

    @Test func hidingThePanelHandsTheKeyboardBackToTheThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.terminalPanels.update(TerminalPanelKey(host: nil, tab: agent.tab.id)) { $0.shown = true }
        vm.focusedPaneID = agent.auxiliary[0].id

        vm.toggleTerminalPanel()
        #expect(!vm.isTerminalPanelShowing)
        #expect(vm.focusedPaneID == agent.piPane.id)

        vm.toggleTerminalPanel()
        #expect(vm.isTerminalPanelShowing)
        #expect(vm.focusedPaneID == agent.auxiliary[0].id)
    }

    @Test func nextAndPreviousTerminalMoveAmongTheTabsAndWrap() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 3)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let key = TerminalPanelKey(host: nil, tab: agent.tab.id)
        let tabs = TerminalPanel.tabs(in: agent.tab.layout, thread: agent.piPane.id)
        #expect(tabs.count == 3)
        vm.terminalPanels.update(key) { $0.shown = true; $0.chosenTab = tabs[0].id }
        vm.focusedPaneID = agent.piPane.id

        vm.selectAdjacentTerminal(1)
        #expect(vm.terminalPanels.panel(key).chosenTab == tabs[1].id && vm.focusedPaneID == tabs[1].id)
        vm.selectAdjacentTerminal(1)
        vm.selectAdjacentTerminal(1)
        #expect(vm.terminalPanels.panel(key).chosenTab == tabs[0].id, "wraps past the last tab")
        vm.selectAdjacentTerminal(-1)
        #expect(vm.terminalPanels.panel(key).chosenTab == tabs[2].id && vm.focusedPaneID == tabs[2].id)

        // Hidden, there is no strip to move along: nothing changes.
        vm.terminalPanels.update(key) { $0.shown = false }
        vm.focusedPaneID = agent.piPane.id
        vm.selectAdjacentTerminal(1)
        #expect(vm.terminalPanels.panel(key).chosenTab == tabs[2].id && vm.focusedPaneID == agent.piPane.id)
    }

    @Test func withOneTerminalThereIsNowhereToGo() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let key = TerminalPanelKey(host: nil, tab: agent.tab.id)
        vm.terminalPanels.update(key) { $0.shown = true; $0.chosenTab = agent.auxiliary[0].id }
        vm.focusedPaneID = agent.piPane.id

        vm.selectAdjacentTerminal(1)

        #expect(vm.focusedPaneID == agent.piPane.id)
    }

    @Test func closingATabClosesItsTerminalButNeverTheThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id
        let target = try #require(vm.terminalTarget)
        let tab = try #require(target.tabs.first)

        vm.closeTerminalTab(tab, target: target)
        await app.settle()

        #expect(app.server.state.tabs.first?.layout.leaves.map(\.id) == [agent.piPane.id])
        #expect(vm.focusedPaneID == agent.piPane.id)
        let after = try #require(vm.terminalTarget)
        #expect(!vm.isTerminalPanelShowing, "the panel closes with its last terminal")

        let thread = TerminalPanelTab(leaf: agent.piPane)
        vm.closeTerminalTab(thread, target: after)
        await app.settle()
        #expect(app.server.state.tabs.first?.layout.leaves.map(\.id) == [agent.piPane.id], "the thread is not a tab to close")
    }

    @Test func maximizingShowsThePanelAndRestoringKeepsIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let key = TerminalPanelKey(host: nil, tab: agent.tab.id)
        vm.terminalPanels.update(key) { $0.shown = false }

        vm.toggleTerminalMaximized()
        #expect(vm.terminalPanels.panel(key).shown && vm.terminalPanels.panel(key).maximized)
        vm.toggleTerminalMaximized()
        #expect(vm.terminalPanels.panel(key).shown && !vm.terminalPanels.panel(key).maximized)
    }

    /// With no terminal there is nothing to maximize, and no empty panel is drawn for it.
    @Test func maximizingWithNoTerminalShowsNothing() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)

        vm.toggleTerminalMaximized()

        #expect(!vm.isTerminalPanelShowing)
        #expect(app.server.state.tabs.first?.layout == agent.tab.layout)
    }

    /// A host's agent, from the client: ⌘J with no terminal asks the host for one (a tab, in the
    /// thread's folder), and the panel shows on it once the host has made it.
    @Test func showingTheTerminalOfARemoteThreadWithNoneAsksItsHostForOne() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: local.dir.path)
        let agent = Fixture.agent(in: space)
        let vm = try await local.start(with: Fixture.state(spaces: [space], agents: []))
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts)
        vm.selectRemoteAgent(hostID: connection.id, agentID: agent.agent.id)
        let key = TerminalPanelKey(host: connection.id, tab: agent.tab.id)
        #expect(vm.terminalTarget?.tabs.isEmpty == true)

        vm.toggleTerminalPanel()

        try await eventuallyOnMain("the host to make a terminal") {
            (remote.host.server.state.tabs.first { $0.id == agent.tab.id }?.layout.leaves.count ?? 0) == 2
        }
        let layout = try #require(remote.host.server.state.tabs.first { $0.id == agent.tab.id }?.layout)
        let terminal = try #require(layout.leaves.first { $0.id != agent.piPane.id })
        #expect(terminal.cwd == space.path && !layout.hasSplitTerminals(besideThread: agent.piPane.id))
        try await eventuallyOnMain("the client to see it and show its panel") {
            vm.terminalTarget?.tabs.map(\.id) == [terminal.id] && vm.terminalPanels.panel(key).shown
        }
        try await eventuallyOnMain("the keyboard to follow the new terminal") { vm.remoteFocusedPaneID == terminal.id }
    }

    /// A client of an older host asks for its terminal the way it always did (a split of the
    /// thread): the host, current, makes a tab, and the client draws tabs only.
    @Test func anOlderStyleOpenRequestToACurrentHostMakesATab() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: local.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        try await local.start(with: Fixture.state(spaces: [space], agents: []))
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts)

        let opened = try await local.remoteHosts.openPane(hostID: connection.id, agentID: agent.agent.id,
                                                          relativeTo: agent.auxiliary[0].id, axis: .vertical)

        let layout = try #require(remote.host.server.state.tabs.first { $0.id == agent.tab.id }?.layout)
        #expect(layout.leaves.count == 3 && layout.contains(opened))
        #expect(!layout.hasSplitTerminals(besideThread: agent.piPane.id))
        #expect(TerminalPanel.tabs(in: layout, thread: agent.piPane.id).count == 2)
    }
}
