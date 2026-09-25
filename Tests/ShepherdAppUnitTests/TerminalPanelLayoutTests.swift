import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestKit
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The Mac's thread-and-panel layout: the thread on top, the panel's strip and the selected tab
/// under it, every pane placed whether it shows or not.
@Suite("Terminal panel geometry")
struct TerminalPanelGeometryTests {
    private let thread = LeafPane(cwd: "/tmp/repo", agentID: AgentID())
    private let shell = LeafPane(cwd: "/tmp/repo")
    private let logs = LeafPane(cwd: "/tmp/repo")
    private let psql = LeafPane(cwd: "/tmp/repo")
    private let size = CGSize(width: 1000, height: 900)

    /// + twice from the thread (shell, then psql), then Split right in the shell's tab (logs).
    private var layout: PaneNode {
        .split(axis: .horizontal, ratio: 0.5,
               first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(thread), second: .leaf(psql)),
               second: .split(axis: .vertical, ratio: 0.5, first: .leaf(shell), second: .leaf(logs)))
    }

    private func geometry(selected: PaneID? = nil, shown: Bool = true, maximized: Bool = false,
                          height: CGFloat = 330) -> TerminalPanelGeometry {
        let tabs = TerminalPanel.tabs(in: layout, thread: thread.id)
        let tab = TerminalPanel.selected(tabs, chosen: selected ?? shell.id)
        return terminalPanelGeometry(for: layout, thread: thread.id, selected: tab, shown: shown, maximized: maximized,
                                     height: height, in: size)
    }

    private func leaf(_ pane: LeafPane, _ geometry: TerminalPanelGeometry) throws -> TerminalPanelGeometry.Leaf {
        try #require(geometry.leaves.first { $0.pane.id == pane.id })
    }

    @Test func theThreadSitsOverThePanelWhoseSelectedTabShowsItsSplits() throws {
        let g = geometry()
        #expect(g.thread == CGRect(x: 0, y: 0, width: 1000, height: 570))
        #expect(g.tabBar == CGRect(x: 0, y: 570, width: 1000, height: NWTerminalMetrics.tabBarHeight))
        let top = 570 + NWTerminalMetrics.tabBarHeight
        #expect(g.content == CGRect(x: 0, y: top, width: 1000, height: 900 - top))
        #expect(g.tabs.map(\.id) == [shell.id, psql.id])
        let shellLeaf = try leaf(shell, g), logsLeaf = try leaf(logs, g)
        #expect(shellLeaf.shown && logsLeaf.shown)
        #expect(shellLeaf.rect.minY == top && logsLeaf.rect.minX > shellLeaf.rect.maxX)
        #expect(g.separators.count == 1 && g.separators[0].rect.minY == top)
        #expect(try leaf(psql, g).shown == false)
        #expect(try leaf(thread, g).shown)
    }

    @Test func anotherTabsPanesKeepTheirPlaceOffScreen() throws {
        let g = geometry(selected: psql.id)
        #expect(try leaf(psql, g).shown)
        #expect(try !leaf(shell, g).shown && !leaf(logs, g).shown)
        // A hidden tab keeps the panel's content size, so its grid never changes on a switch.
        #expect(try leaf(psql, g).rect.height == leaf(shell, g).rect.height)
        #expect(g.separators.isEmpty)
    }

    @Test func aHiddenPanelGivesTheThreadTheLayoutAndKeepsTheTerminalsSized() throws {
        let hidden = geometry(shown: false), shown = geometry()
        #expect(hidden.thread == CGRect(x: 0, y: 0, width: 1000, height: 900))
        #expect(hidden.tabBar == nil && hidden.content == nil)
        #expect(try !leaf(shell, hidden).shown)
        #expect(try leaf(shell, hidden).rect == leaf(shell, shown).rect)
    }

    @Test func maximizedThePanelTakesTheLayoutAndTheThreadFoldsAwayAtItsSize() throws {
        let g = geometry(maximized: true)
        #expect(g.tabBar?.minY == 0)
        #expect(g.content?.height == 900 - NWTerminalMetrics.tabBarHeight)
        let threadLeaf = try leaf(thread, g)
        #expect(!threadLeaf.shown && threadLeaf.rect.height == 570)
    }

    @Test(arguments: [(40.0, 120.0), (880.0, 740.0), (330.0, 330.0)] as [(CGFloat, CGFloat)])
    func thePanelsHeightIsClampedToTheLayout(preferred: CGFloat, height: CGFloat) {
        let g = geometry(height: preferred)
        #expect(900 - g.thread.height == height)
    }
}

@Suite("Terminal panels")
@MainActor
struct TerminalPanelsTests {
    private let key = TerminalPanelKey(host: nil, tab: TabID())
    private let thread = LeafPane(cwd: "/tmp/repo", agentID: AgentID())
    private let shell = LeafPane(sessionID: SessionID(), cwd: "/tmp/repo")

    @Test func aLayoutFirstSeenWithTerminalsShowsItsPanelAndOneWithoutDoesNot() {
        let panels = TerminalPanels(defaults: ScratchDefaults())
        panels.reconcile(key, layout: .leaf(thread), thread: thread.id)
        #expect(!panels.panel(key).shown)
        let other = TerminalPanelKey(host: nil, tab: TabID())
        panels.reconcile(other, layout: .split(axis: .vertical, ratio: 0.5, first: .leaf(thread), second: .leaf(shell)), thread: thread.id)
        #expect(panels.panel(other).shown)
    }

    @Test func aTerminalThatAppearsOpensThePanelOnItsTab() {
        let panels = TerminalPanels(defaults: ScratchDefaults())
        let layout = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(thread), second: .leaf(shell))
        panels.reconcile(key, layout: layout, thread: thread.id)
        panels.update(key) { $0.shown = false }
        let added = LeafPane(cwd: "/tmp/repo")
        let grown = layout.splitting(pane: thread.id, axis: .horizontal, newPane: added)!
        #expect(panels.reconcile(key, layout: grown, thread: thread.id) == added.id)
        #expect(panels.panel(key).shown && panels.panel(key).chosenTab == added.id)
        #expect(panels.reconcile(key, layout: grown, thread: thread.id) == nil)
    }

    /// However the last terminal goes (its tab closed, the agent closed its pane, its shell
    /// exited), the panel goes with it; ⌘J on no terminals still shows the empty state.
    @Test func thePanelClosesWithItsLastTerminal() {
        let panels = TerminalPanels(defaults: ScratchDefaults())
        let layout = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(thread), second: .leaf(shell))
        panels.reconcile(key, layout: layout, thread: thread.id)
        panels.update(key) { $0.maximized = true }
        panels.reconcile(key, layout: .leaf(thread), thread: thread.id)
        #expect(!panels.panel(key).shown && !panels.panel(key).maximized)
        panels.update(key) { $0.shown = true }
        panels.reconcile(key, layout: .leaf(thread), thread: thread.id)
        #expect(panels.panel(key).shown)
    }

    /// A tab's dot follows the host's news, not every read of output: a resize's redraw moves
    /// only the output sequence.
    @Test func aRedrawThatIsNotNewsLeavesNoDot() throws {
        let panels = TerminalPanels(defaults: ScratchDefaults())
        let session = try #require(shell.sessionID)
        func row(output: UInt64, news: UInt64?) -> RemoteTerminalActivity {
            RemoteTerminalActivity(paneID: shell.id, sessionID: session, process: "zsh", command: nil,
                                   outputSequence: output, newsSequence: news)
        }
        panels.setActivity([row(output: 2, news: 2)], for: key)
        panels.setActivity([row(output: 5, news: 2)], for: key)
        #expect(!panels.hasUnseen(key, session: session))
        panels.setActivity([row(output: 6, news: 3)], for: key)
        #expect(panels.hasUnseen(key, session: session))
        panels.markSeen(key, sessions: [session])
        #expect(!panels.hasUnseen(key, session: session))
    }

    @Test func theHeightPersistsAndABadValueFallsBackToTheDefault() {
        let defaults = ScratchDefaults()
        TerminalPanels(defaults: defaults).height = 420
        #expect(TerminalPanels(defaults: defaults).height == 420)
        defaults.set(10.0, forKey: TerminalPanels.heightKey)
        #expect(TerminalPanels(defaults: defaults).height == AppLayout.terminalPanelHeight)
    }

    @Test func outputOffScreenIsNewsUntilItsTabShows() throws {
        let panels = TerminalPanels(defaults: ScratchDefaults())
        let session = try #require(shell.sessionID)
        let tab = TerminalPanelTab(node: .leaf(shell))
        func row(_ sequence: UInt64, command: String? = nil) -> RemoteTerminalActivity {
            RemoteTerminalActivity(paneID: shell.id, sessionID: session, process: "zsh", command: command, outputSequence: sequence)
        }
        panels.setActivity([row(5)], for: key)
        // What was there before the first look is not news.
        #expect(!panels.hasUnseen(key, session: session))
        panels.setActivity([row(9)], for: key)
        #expect(panels.hasUnseen(key, session: session))
        #expect(panels.items(key, tabs: [tab], selected: nil, onScreen: true, host: nil).map(\.activity) == [.unseen])
        #expect(panels.items(key, tabs: [tab], selected: tab, onScreen: true, host: nil).map(\.activity) == [.idle])
        panels.markSeen(key, sessions: [session])
        #expect(!panels.hasUnseen(key, session: session))
        panels.setActivity([row(12, command: "make dev")], for: key)
        let items = panels.items(key, tabs: [tab], selected: nil, onScreen: false, host: "build-01")
        #expect(items.map(\.activity) == [.running] && items.map(\.title) == ["make dev"] && items.map(\.host) == ["build-01"])
    }

    @Test(arguments: [
        (String?("make dev"), String?("make"), "/tmp/repo", "make dev"),
        (nil, "zsh", "/tmp/repo", "zsh"),
        (nil, nil, "/Users/dev/payments", "payments"),
        (nil, nil, "", "Terminal"),
    ] as [(String?, String?, String, String)])
    func aTabIsNamedForWhatRunsInIt(command: String?, process: String?, cwd: String, title: String) {
        let pane = LeafPane(cwd: cwd)
        let row = RemoteTerminalActivity(paneID: pane.id, sessionID: SessionID(), process: process, command: command, outputSequence: 0)
        #expect(TerminalPanels.title(row: command == nil && process == nil ? nil : row, pane: pane) == title)
    }
}
