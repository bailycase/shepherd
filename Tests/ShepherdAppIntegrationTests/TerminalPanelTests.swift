import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The terminal panel under a thread (TerminalSplit, TerminalStates boards) as the keyboard and
/// its strip drive it: new tabs split the thread, hiding hands the keyboard back, focus moves only
/// among panes on screen, and closing a tab never closes the thread.
@Suite("Terminal panel", .mainActorExclusive)
@MainActor
struct TerminalPanelTests {
    @Test func aNewTabSplitsTheThreadAndTakesTheKeyboard() async throws {
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
        #expect(tabs.contains { $0.panes.map(\.id) == [added] })
        #expect(vm.focusedPaneID == added)
    }

    @Test func splitRightStaysInTheTabOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id

        vm.splitTerminal()
        await app.settle()

        let layout = try #require(app.server.state.tabs.first?.layout)
        let tabs = TerminalPanel.tabs(in: layout, thread: agent.piPane.id)
        #expect(tabs.count == 1 && tabs[0].panes.count == 2)
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

    @Test func focusMovesOnlyAmongThePanesOnScreen() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 2)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let key = TerminalPanelKey(host: nil, tab: agent.tab.id)
        let tabs = TerminalPanel.tabs(in: agent.tab.layout, thread: agent.piPane.id)
        #expect(tabs.count == 2)
        vm.terminalPanels.update(key) { $0.shown = true; $0.chosenTab = tabs[0].id; $0.chosenPanes = [tabs[0].id] }
        vm.focusedPaneID = agent.piPane.id

        vm.focusAdjacentPane(1)
        #expect(vm.focusedPaneID == tabs[0].id)
        vm.focusAdjacentPane(1)
        #expect(vm.focusedPaneID == agent.piPane.id)

        // Hidden, only the thread is on screen: focus stays put.
        vm.terminalPanels.update(key) { $0.shown = false }
        vm.focusAdjacentPane(1)
        #expect(vm.focusedPaneID == agent.piPane.id)
    }

    @Test func closingATabClosesItsPanesButNeverTheThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id
        vm.splitTerminal()
        await app.settle()
        let layout = try #require(app.server.state.tabs.first?.layout)
        let tab = try #require(TerminalPanel.tabs(in: layout, thread: agent.piPane.id).first)
        let target = try #require(vm.terminalTarget)

        vm.closeTerminalTab(tab, target: target)
        await app.settle()

        #expect(app.server.state.tabs.first?.layout.leaves.map(\.id) == [agent.piPane.id])
        #expect(vm.focusedPaneID == agent.piPane.id)
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
        #expect(vm.visiblePanes(layout: agent.tab.layout, key: key, thread: agent.piPane.id, focused: nil)
            == [agent.piPane.id, agent.auxiliary[0].id])
    }
}
