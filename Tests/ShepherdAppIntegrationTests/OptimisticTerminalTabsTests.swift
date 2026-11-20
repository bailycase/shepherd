import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// + and Close ahead of the host (⌘D, ⌘W, the strip's + and ×), on this Mac and on a paired host:
/// the tab opens selected and Starting, or leaves, before the host answers; the host's reply, its
/// push and its refusal land in any order without moving the keyboard from where the person put it.
/// The panel's requests are held and released one by one (`HeldRequests`).
@Suite("Optimistic terminal tabs", .mainActorExclusive)
@MainActor
struct OptimisticTerminalTabsTests {
    private struct Refused: Error, CustomStringConvertible { var description: String { "the host said no" } }

    /// Requests the panel makes of its host, parked until the test lets them go.
    @MainActor
    private final class HeldRequests {
        enum Verdict { case run, refuse }
        /// Whether a held open waits again after the host made the terminal, for its push to land first.
        var holdsReply = false
        private(set) var opens: [CheckedContinuation<Verdict, Never>] = []
        private(set) var closes: [CheckedContinuation<Verdict, Never>] = []
        private(set) var replies: [CheckedContinuation<Void, Never>] = []
        private(set) var closed: [PaneID] = []

        func install(on vm: ShepherdViewModel) {
            vm.terminalRequests = .init(open: { [unowned self, unowned vm] ref, anchor, axis in
                if await withCheckedContinuation({ self.opens.append($0) }) == .refuse { throw Refused() }
                let real = try await vm.remoteHosts.openPane(hostID: ref.hostID, agentID: ref.agentID, relativeTo: anchor, axis: axis)
                if self.holdsReply { await withCheckedContinuation { self.replies.append($0) } }
                return real
            }, close: { [unowned self, unowned vm] ref, pane in
                if await withCheckedContinuation({ self.closes.append($0) }) == .refuse { throw Refused() }
                try await vm.remoteHosts.closePane(hostID: ref.hostID, agentID: ref.agentID, paneID: pane)
                self.closed.append(pane)
            })
        }

        /// Lets the oldest held request go, once the panel has made it.
        func releaseOpen(_ verdict: Verdict = .run) async throws {
            try await eventuallyOnMain("the panel to ask the host to open") { !self.opens.isEmpty }
            opens.removeFirst().resume(returning: verdict)
        }
        func releaseClose(_ verdict: Verdict = .run) async throws {
            try await eventuallyOnMain("the panel to ask the host to close") { !self.closes.isEmpty }
            closes.removeFirst().resume(returning: verdict)
        }
        func releaseReply() async throws {
            try await eventuallyOnMain("the host's reply to be held") { !self.replies.isEmpty }
            replies.removeFirst().resume()
        }
    }

    @MainActor
    private struct Local {
        let app: AppHarness
        let vm: ShepherdViewModel
        let agent: AgentFixture
        let held = HeldRequests()
        var key: TerminalPanelKey { TerminalPanelKey(host: nil, tab: agent.tab.id) }
        var thread: PaneID { agent.piPane.id }
        var hostLayout: PaneNode? { app.server.state.tabs.first { $0.id == agent.tab.id }?.layout }
        var focus: PaneID? { vm.focusedPaneID }
        func setFocus(_ pane: PaneID?) { vm.focusedPaneID = pane }
        /// The tabs the panel draws, brought up to date as a drawn panel does.
        func tabs() -> [PaneID] { vm.terminalTarget.map { vm.panelTabs($0).map(\.id) } ?? [] }
        func tabItems() -> [SHTerminalTab] {
            guard let target = vm.terminalTarget else { return [] }
            let tabs = vm.panelTabs(target)
            return vm.terminalPanels.items(key, tabs: tabs, selected: vm.selectedTerminalTab(target), onScreen: true, host: nil)
        }
        var chosen: PaneID? { vm.terminalPanels.panel(key).chosenTab }
        var selected: PaneID? { vm.terminalTarget.flatMap { vm.selectedTerminalTab($0)?.id } }
        func select(_ pane: PaneID) {
            guard let target = vm.terminalTarget, let tab = vm.panelTabs(target).first(where: { $0.id == pane }) else { return }
            vm.selectTerminalTab(tab, target: target)
        }
        func closeTab(_ pane: PaneID) {
            guard let target = vm.terminalTarget, let tab = vm.panelTabs(target).first(where: { $0.id == pane }) else { return }
            vm.closeTerminalTab(tab, target: target)
        }
        var hostPanes: [PaneID] { hostLayout?.leaves.map(\.id) ?? [] }
        var pending: Bool { !vm.terminalPanels.overlay(key).pending.isEmpty }
    }

    private func local(auxiliary: Int) async throws -> Local {
        let app = try AppHarness()
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: auxiliary)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.selectAgent(agent.agent.id)
        let scene = Local(app: app, vm: vm, agent: agent)
        scene.held.install(on: vm)
        _ = vm.terminalTarget
        return scene
    }

    // MARK: Opening, on this Mac

    @Test func aNewTabOpensAtOnceSelectedAndStartingWithTheKeyboardOnNoShell() async throws {
        let s = try await local(auxiliary: 1)
        defer { s.app.stop() }
        let shell = s.agent.auxiliary[0].id
        s.setFocus(shell)

        s.vm.newTerminalTab()

        // Nothing has been asked of the host yet; the tab is already there.
        #expect(s.hostPanes.count == 2)
        let tabs = s.tabs()
        let placeholder = try #require(tabs.last)
        #expect(tabs.count == 2 && tabs.first == shell)
        #expect(s.vm.isTerminalPanelShowing)
        #expect(s.chosen == placeholder && s.selected == placeholder)
        #expect(s.focus == placeholder, "the keyboard is on no shell: the previous terminal is hidden and the new one has none")
        #expect(s.tabItems().last?.activity == .starting)
        #expect(s.vm.terminalPanels.isStarting(placeholder, in: s.key))

        try await s.held.releaseOpen()
        try await eventuallyOnMain("the host to make the terminal and the tab to become it") {
            let tabs = s.tabs()
            return !s.pending && tabs.count == 2 && tabs.last != placeholder
        }
        let real = try #require(s.tabs().last)
        #expect(s.hostPanes.contains(real))
        #expect(s.chosen == real && s.focus == real, "the keyboard follows the tab onto its terminal")
        #expect(s.tabItems().allSatisfy { $0.activity != .starting })
    }

    @Test func aTabAskedForWhileTheThreadHasNoTerminalOpensThePanelOnIt() async throws {
        let s = try await local(auxiliary: 0)
        defer { s.app.stop() }
        #expect(!s.vm.isTerminalPanelShowing)

        s.vm.toggleTerminalPanel()

        #expect(s.vm.isTerminalPanelShowing && s.tabs().count == 1, "⌘J with none shows a Starting tab at once")
        try await eventuallyOnMain("the first request to be made") { s.held.opens.count == 1 }
        s.vm.toggleTerminalPanel()
        s.vm.toggleTerminalPanel()
        #expect(s.vm.isTerminalPanelShowing && s.tabs().count == 1)
        await s.app.settle()
        #expect(s.held.opens.count == 1, "showing it again asks for nothing more")
        try await s.held.releaseOpen()
        try await eventuallyOnMain("the terminal to arrive") { s.tabs().count == 1 && !s.pending && s.hostPanes.count == 2 }
        #expect(s.focus == s.tabs().first)
    }

    @Test func aPushThatBeatsTheReplyNeverShowsTheTabTwice() async throws {
        let s = try await local(auxiliary: 1)
        defer { s.app.stop() }
        s.held.holdsReply = true
        s.vm.newTerminalTab()
        let placeholder = try #require(s.tabs().last)

        try await s.held.releaseOpen()
        try await eventuallyOnMain("the host's push to carry the new terminal") { s.vm.state.tabs.first?.layout.leaves.count == 3 }
        let real = try #require(s.vm.state.tabs.first?.layout.leaves.map(\.id).first { ![s.thread, s.agent.auxiliary[0].id].contains($0) })

        #expect(s.tabs().count == 2 && s.tabs().last == placeholder, "the terminal is the Starting tab, not another")
        #expect(s.chosen == placeholder && s.focus == placeholder, "its arrival selects nothing")
        try await eventuallyOnMain("the reply to be waiting") { s.held.replies.count == 1 }
        try await s.held.releaseReply()
        try await eventuallyOnMain("the reply to settle the tab") { s.tabs().last == real && !s.pending }
        #expect(s.tabs().count == 2 && s.chosen == real && s.focus == real)
    }

    @Test func aTabAnotherDeviceOpensWhileOursStartsDoesNotTakeTheSelection() async throws {
        let s = try await local(auxiliary: 1)
        defer { s.app.stop() }
        s.vm.newTerminalTab()
        let placeholder = try #require(s.tabs().last)

        // Opened by the thread's own tool, say: a pane that is not ours.
        let ref = try #require(s.vm.localRef(s.agent.agent.id))
        let theirs = try await s.vm.remoteHosts.openPane(hostID: ref.hostID, agentID: ref.agentID, relativeTo: s.thread, axis: .horizontal)
        try await eventuallyOnMain("the push with the other terminal") { s.vm.state.tabs.first?.layout.contains(theirs) == true }
        _ = s.tabs()
        #expect(s.chosen == placeholder, "the Starting tab keeps the selection")

        try await s.held.releaseOpen()
        try await eventuallyOnMain("ours to arrive") { !s.pending && s.hostPanes.count == 4 }
        let tabs = s.tabs()
        #expect(tabs.count == 3 && tabs.contains(theirs))
        let real = try #require(tabs.first { ![s.agent.auxiliary[0].id, theirs].contains($0) })
        #expect(s.chosen == real && s.focus == real, "the keyboard is on ours, not the other tab")
    }

    @Test func selectingAnotherTabWhileOneStartsKeepsTheKeyboardThere() async throws {
        let s = try await local(auxiliary: 1)
        defer { s.app.stop() }
        let shell = s.agent.auxiliary[0].id
        s.vm.newTerminalTab()

        s.select(shell)
        #expect(s.focus == shell && s.chosen == shell)
        try await s.held.releaseOpen()
        try await eventuallyOnMain("the new terminal to arrive") { !s.pending && s.tabs().count == 2 && s.hostPanes.count == 3 }

        #expect(s.chosen == shell && s.focus == shell, "a terminal that finished starting never takes the keyboard back")
        #expect(s.selected == shell)
    }

    @Test func aRefusedOpenTakesTheTabBackAndGivesTheKeyboardBack() async throws {
        let s = try await local(auxiliary: 1)
        defer { s.app.stop() }
        let shell = s.agent.auxiliary[0].id
        s.select(shell)
        s.vm.newTerminalTab()
        let placeholder = try #require(s.tabs().last)
        #expect(s.focus == placeholder)

        try await s.held.releaseOpen(.refuse)
        try await eventuallyOnMain("the refusal to take the tab back") { !s.pending }

        #expect(s.tabs() == [shell])
        #expect(s.chosen == shell && s.focus == shell)
        #expect(s.hostPanes.count == 2)
        #expect(s.vm.actionError?.title == "Couldn’t open a terminal")
    }

    @Test func aRefusedOpenLeavesTheKeyboardWhereThePersonWentMeanwhile() async throws {
        let s = try await local(auxiliary: 2)
        defer { s.app.stop() }
        let first = s.agent.auxiliary[0].id, second = s.agent.auxiliary[1].id
        s.select(first)
        s.vm.newTerminalTab()
        s.select(second)

        try await s.held.releaseOpen(.refuse)
        try await eventuallyOnMain("the refusal") { !s.pending }

        #expect(Set(s.tabs()) == [first, second])
        #expect(s.chosen == second && s.focus == second, "the failure does not steal back to the tab before")
    }

    @Test func aRefusedFirstTabHidesThePanelAgain() async throws {
        let s = try await local(auxiliary: 0)
        defer { s.app.stop() }
        s.vm.newTerminalTab()
        #expect(s.vm.isTerminalPanelShowing)

        try await s.held.releaseOpen(.refuse)
        try await eventuallyOnMain("the refusal") { !s.pending }

        #expect(s.tabs().isEmpty)
        #expect(!s.vm.isTerminalPanelShowing, "a panel never shows with no tab in it")
    }

    @Test func closingAStartingTabWithTheKeyboardClosesTheTerminalTheHostMakes() async throws {
        let s = try await local(auxiliary: 0)
        defer { s.app.stop() }
        s.vm.newTerminalTab()
        let placeholder = try #require(s.tabs().last)
        #expect(s.focus == placeholder)

        s.vm.closeFocusedTerminal()
        #expect(s.tabs().isEmpty && !s.vm.isTerminalPanelShowing, "⌘W takes the Starting tab at once")
        #expect(s.focus == s.thread)

        try await s.held.releaseOpen()
        try await eventuallyOnMain("the host's reply to ask for the new terminal to close") { s.held.closes.count == 1 }
        #expect(s.tabs().isEmpty, "the terminal is never a tab, even once the host has pushed it")
        try await s.held.releaseClose()
        try await eventuallyOnMain("the host to drop it") { s.hostPanes == [s.thread] && s.held.closed.count == 1 }
        _ = s.tabs()
        #expect(s.vm.terminalPanels.overlay(s.key).isEmpty)
        #expect(s.focus == s.thread)
    }

    @Test func theStripsCloseOnAStartingTabGoesToo() async throws {
        let s = try await local(auxiliary: 1)
        defer { s.app.stop() }
        let shell = s.agent.auxiliary[0].id
        s.vm.newTerminalTab()
        let placeholder = try #require(s.tabs().last)

        s.closeTab(placeholder)
        #expect(s.tabs() == [shell])
        try await s.held.releaseOpen()
        try await eventuallyOnMain("its terminal to be asked to close") { s.held.closes.count == 1 }
        try await s.held.releaseClose()
        try await eventuallyOnMain("the host to drop it") { s.hostPanes.count == 2 }
        #expect(s.tabs() == [shell])
    }

    // MARK: Closing, on this Mac

    @Test func closingTheFocusedTerminalLeavesAtOnceAndTheKeyboardGoesToTheThread() async throws {
        let s = try await local(auxiliary: 2)
        defer { s.app.stop() }
        let first = s.agent.auxiliary[0].id, second = s.agent.auxiliary[1].id
        s.setFocus(first)
        s.select(first)

        s.vm.closeFocusedTerminal()

        #expect(s.hostPanes.contains(first), "the host has not been asked yet")
        #expect(s.tabs() == [second])
        #expect(s.focus == s.thread)
        try await eventuallyOnMain("the first request to be made") { s.held.closes.count == 1 }
        s.vm.closeFocusedTerminal()
        await s.app.settle()
        #expect(s.held.closes.count == 1, "a second ⌘W is not a second request")
        try await s.held.releaseClose()
        try await eventuallyOnMain("the host to close it") { !s.hostPanes.contains(first) }
        _ = s.tabs()
        #expect(s.vm.terminalPanels.overlay(s.key).isEmpty && s.tabs() == [second] && s.focus == s.thread)
    }

    @Test func theStripsCloseLeavesAtOnceToo() async throws {
        let s = try await local(auxiliary: 2)
        defer { s.app.stop() }
        let first = s.agent.auxiliary[0].id, second = s.agent.auxiliary[1].id
        s.select(second)

        s.closeTab(first)
        #expect(s.tabs() == [second])
        #expect(s.focus == second && s.chosen == second, "closing a tab in the background moves nothing")
        try await s.held.releaseClose()
        try await eventuallyOnMain("the host to close it") { !s.hostPanes.contains(first) }
    }

    @Test func aRefusedCloseBringsTheTabBackWithoutTakingTheKeyboard() async throws {
        let s = try await local(auxiliary: 2)
        defer { s.app.stop() }
        let first = s.agent.auxiliary[0].id, second = s.agent.auxiliary[1].id
        s.setFocus(first)
        s.select(first)
        s.vm.closeFocusedTerminal()
        #expect(s.focus == s.thread)

        // The person goes to the other terminal while the host decides.
        s.select(second)
        try await s.held.releaseClose(.refuse)
        try await eventuallyOnMain("the refusal to bring the tab back") { Set(s.tabs()) == [first, second] }

        #expect(s.focus == second && s.chosen == second && s.selected == second)
        #expect(s.hostPanes.contains(first))
        #expect(s.vm.actionError?.title == "Couldn’t close the terminal")
    }

    @Test func closingTheLastTerminalHidesThePanelAtOnceAndARefusalShowsItAgain() async throws {
        let s = try await local(auxiliary: 1)
        defer { s.app.stop() }
        let shell = s.agent.auxiliary[0].id
        s.setFocus(shell)
        #expect(s.vm.isTerminalPanelShowing)

        s.vm.closeFocusedTerminal()
        #expect(s.tabs().isEmpty && !s.vm.isTerminalPanelShowing && s.focus == s.thread)

        try await s.held.releaseClose(.refuse)
        try await eventuallyOnMain("the tab and the panel to come back") { s.tabs() == [shell] && s.vm.isTerminalPanelShowing }
        #expect(s.focus == s.thread, "the keyboard stays where closing put it")
    }

    @Test func aTerminalClosedWhileItWasNotFocusedLeavesTheKeyboardAlone() async throws {
        let s = try await local(auxiliary: 2)
        defer { s.app.stop() }
        let first = s.agent.auxiliary[0].id, second = s.agent.auxiliary[1].id
        s.select(first)
        s.setFocus(s.thread)
        s.vm.terminalPanels.update(s.key) { $0.chosenTab = second }

        s.closeTab(first)

        #expect(s.focus == s.thread && s.chosen == second)
        try await s.held.releaseClose()
        try await eventuallyOnMain("the host to close it") { !s.hostPanes.contains(first) }
    }

    // MARK: A paired host

    @MainActor
    private struct Paired {
        let local: AppHarness
        let remote: RemoteHostHarness
        let vm: ShepherdViewModel
        let agent: AgentFixture
        let connection: RemoteHostStore.Connection
        let held = HeldRequests()
        var ref: RemoteAgentRef { RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id) }
        var key: TerminalPanelKey { TerminalPanelKey(host: connection.id, tab: agent.tab.id) }
        var thread: PaneID { agent.piPane.id }
        var hostPanes: [PaneID] { remote.host.server.state.tabs.first { $0.id == agent.tab.id }?.layout.leaves.map(\.id) ?? [] }
        var focus: PaneID? { vm.remoteFocusedPaneID }
        func tabs() -> [PaneID] { vm.terminalTarget.map { vm.panelTabs($0).map(\.id) } ?? [] }
        var chosen: PaneID? { vm.terminalPanels.panel(key).chosenTab }
        var pending: Bool { !vm.terminalPanels.overlay(key).pending.isEmpty }
        func select(_ pane: PaneID) {
            guard let target = vm.terminalTarget, let tab = vm.panelTabs(target).first(where: { $0.id == pane }) else { return }
            vm.selectTerminalTab(tab, target: target)
        }
        func stop() { local.stop(); remote.stop() }
    }

    private func paired(auxiliary: Int) async throws -> Paired {
        let local = try AppHarness(), remote = try await RemoteHostHarness()
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: auxiliary)
        let vm = try await local.start()
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts)
        vm.selectRemoteAgent(hostID: connection.id, agentID: agent.agent.id)
        let scene = Paired(local: local, remote: remote, vm: vm, agent: agent, connection: connection)
        scene.held.install(on: vm)
        _ = vm.terminalTarget
        return scene
    }

    @Test func aPairedHostsNewTabOpensAtOnceThenBecomesTheHostsTerminal() async throws {
        let s = try await paired(auxiliary: 1)
        defer { s.stop() }
        let shell = s.agent.auxiliary[0].id
        s.vm.remoteFocusedPaneID = shell

        s.vm.newTerminalTab()

        let placeholder = try #require(s.tabs().last)
        #expect(s.tabs().count == 2 && s.hostPanes.count == 2)
        #expect(s.vm.isTerminalPanelShowing && s.chosen == placeholder && s.focus == placeholder)
        try await s.held.releaseOpen()
        try await eventuallyOnMain("the host's terminal to replace the Starting tab") {
            !s.pending && s.tabs().count == 2 && s.tabs().last != placeholder
        }
        let real = try #require(s.tabs().last)
        #expect(s.hostPanes.contains(real) && s.chosen == real && s.focus == real)
    }

    @Test func aPairedHostsPushBeforeTheReplyNeverShowsTheTabTwice() async throws {
        let s = try await paired(auxiliary: 1)
        defer { s.stop() }
        s.held.holdsReply = true
        s.vm.newTerminalTab()
        let placeholder = try #require(s.tabs().last)

        try await s.held.releaseOpen()
        try await eventuallyOnMain("the push with the new terminal") {
            s.connection.state.tabs.first { $0.id == s.agent.tab.id }?.layout.leaves.count == 3
        }
        #expect(s.tabs().count == 2 && s.tabs().last == placeholder && s.focus == placeholder)
        try await eventuallyOnMain("the reply to wait") { s.held.replies.count == 1 }
        try await s.held.releaseReply()
        try await eventuallyOnMain("the tab to settle") { !s.pending && s.tabs().last != placeholder }
        #expect(s.tabs().count == 2 && s.focus == s.tabs().last)
    }

    @Test func aPairedHostsRefusedOpenRestoresTheTabAndTheKeyboard() async throws {
        let s = try await paired(auxiliary: 1)
        defer { s.stop() }
        let shell = s.agent.auxiliary[0].id
        s.select(shell)
        s.vm.newTerminalTab()

        try await s.held.releaseOpen(.refuse)
        try await eventuallyOnMain("the refusal") { !s.pending }

        #expect(s.tabs() == [shell] && s.chosen == shell && s.focus == shell)
        #expect(s.hostPanes.count == 2)
    }

    @Test func aPairedHostsRefusedOpenKeepsWhereThePersonWentMeanwhile() async throws {
        let s = try await paired(auxiliary: 2)
        defer { s.stop() }
        let first = s.agent.auxiliary[0].id, second = s.agent.auxiliary[1].id
        s.select(first)
        s.vm.newTerminalTab()
        s.select(second)

        try await s.held.releaseOpen(.refuse)
        try await eventuallyOnMain("the refusal") { !s.pending }

        #expect(Set(s.tabs()) == [first, second] && s.focus == second && s.chosen == second)
    }

    @Test func aPairedHostsCloseLeavesAtOnceByKeyboardAndReturnsTheKeyboardToTheThread() async throws {
        let s = try await paired(auxiliary: 2)
        defer { s.stop() }
        let first = s.agent.auxiliary[0].id, second = s.agent.auxiliary[1].id
        s.select(first)
        #expect(s.focus == first)

        s.vm.closeFocusedTerminal()

        #expect(s.hostPanes.contains(first))
        #expect(s.tabs() == [second] && s.focus == s.thread)
        try await s.held.releaseClose()
        try await eventuallyOnMain("the host to close it") { !s.hostPanes.contains(first) }
        try await eventuallyOnMain("the overlay to settle") { _ = s.tabs(); return s.vm.terminalPanels.overlay(s.key).isEmpty }
        #expect(s.tabs() == [second] && s.focus == s.thread)
    }

    @Test func aPairedHostsRefusedCloseBringsTheTabBackWithoutTakingTheKeyboard() async throws {
        let s = try await paired(auxiliary: 2)
        defer { s.stop() }
        let first = s.agent.auxiliary[0].id, second = s.agent.auxiliary[1].id
        s.select(first)
        s.vm.closeFocusedTerminal()
        s.select(second)

        try await s.held.releaseClose(.refuse)
        try await eventuallyOnMain("the tab to come back") { Set(s.tabs()) == [first, second] }

        #expect(s.focus == second && s.chosen == second)
    }

    @Test func aPairedHostsStartingTabClosesWithTheKeyboardToo() async throws {
        let s = try await paired(auxiliary: 1)
        defer { s.stop() }
        let shell = s.agent.auxiliary[0].id
        s.vm.newTerminalTab()

        s.vm.closeFocusedTerminal()
        #expect(s.tabs() == [shell] && s.focus == s.thread)
        try await s.held.releaseOpen()
        try await eventuallyOnMain("the new terminal to be asked to close") { s.held.closes.count == 1 }
        #expect(s.tabs() == [shell])
        try await s.held.releaseClose()
        try await eventuallyOnMain("the host to drop it") { s.hostPanes.count == 2 }
        #expect(s.tabs() == [shell])
    }
}
