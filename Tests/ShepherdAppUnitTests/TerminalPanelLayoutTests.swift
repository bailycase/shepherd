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
/// under it, every terminal placed whether it shows or not.
@Suite("Terminal panel geometry")
struct TerminalPanelGeometryTests {
    private let thread = LeafPane(cwd: "/tmp/repo", agentID: AgentID())
    private let shell = LeafPane(cwd: "/tmp/repo")
    private let psql = LeafPane(cwd: "/tmp/repo")
    private let size = CGSize(width: 1000, height: 900)

    /// + twice from the thread: a tab each, the shell first and the newer psql nearer the thread.
    private var layout: PaneNode {
        .split(axis: .horizontal, ratio: 0.5,
               first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(thread), second: .leaf(psql)),
               second: .leaf(shell))
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

    @Test func theThreadSitsOverThePanelWhoseSelectedTabShowsItsTerminal() throws {
        let g = geometry()
        #expect(g.thread == CGRect(x: 0, y: 0, width: 1000, height: 570))
        #expect(g.tabBar == CGRect(x: 0, y: 570, width: 1000, height: NWTerminalMetrics.tabBarHeight))
        let top = 570 + NWTerminalMetrics.tabBarHeight
        #expect(g.content == CGRect(x: 0, y: top, width: 1000, height: 900 - top))
        #expect(g.tabs.map(\.id) == [shell.id, psql.id])
        // One terminal a tab: it fills the panel's content, with no header and no divider.
        let shellLeaf = try leaf(shell, g)
        #expect(shellLeaf.shown && shellLeaf.rect == g.content)
        #expect(try leaf(psql, g).shown == false)
        #expect(try leaf(thread, g).shown)
        #expect(g.leaves.count == 3)
    }

    @Test func anotherTabsTerminalKeepsItsPlaceOffScreen() throws {
        let g = geometry(selected: psql.id)
        #expect(try leaf(psql, g).shown)
        #expect(try !leaf(shell, g).shown)
        // A hidden tab keeps its place, so its grid never changes on a switch.
        #expect(try leaf(shell, g).rect == leaf(psql, g).rect)
        #expect(try leaf(shell, g).rect == leaf(shell, geometry()).rect)
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
        // The thread keeps one line above the strip (TerminalStates).
        #expect(g.fold == CGRect(x: 0, y: 0, width: 1000, height: NWTerminalMetrics.foldedThreadHeight))
        #expect(g.tabBar?.minY == NWTerminalMetrics.foldedThreadHeight)
        #expect(g.content?.height == 900 - NWTerminalMetrics.foldedThreadHeight - NWTerminalMetrics.tabBarHeight)
        #expect(geometry().fold == nil && geometry(shown: false, maximized: true).fold == nil)
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

    /// However the last terminal goes (its tab closed, the agent closed its terminal, its shell
    /// exited), the panel goes with it, and a panel is never left showing with no terminal.
    @Test func thePanelClosesWithItsLastTerminal() {
        let panels = TerminalPanels(defaults: ScratchDefaults())
        let layout = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(thread), second: .leaf(shell))
        panels.reconcile(key, layout: layout, thread: thread.id)
        panels.update(key) { $0.maximized = true }
        panels.reconcile(key, layout: .leaf(thread), thread: thread.id)
        #expect(!panels.panel(key).shown && !panels.panel(key).maximized)
        panels.update(key) { $0.shown = true; $0.maximized = true }
        panels.reconcile(key, layout: .leaf(thread), thread: thread.id)
        #expect(!panels.panel(key).shown && !panels.panel(key).maximized, "no empty panel, however it came to show")
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
        let tab = TerminalPanelTab(leaf: shell)
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

    /// Rename tab names it whatever it runs; a blank name goes back to what it runs.
    @Test(arguments: [("logs", "logs"), ("  ", "make dev")])
    func aRenamedTabKeepsItsName(name: String, title: String) {
        let pane = LeafPane(cwd: "/tmp/repo", title: name)
        let row = RemoteTerminalActivity(paneID: pane.id, sessionID: SessionID(), process: "make", command: "make dev", outputSequence: 0)
        #expect(TerminalPanels.title(row: row, pane: pane) == title)
    }
}

/// Add to message (TerminalPane): where the bar hangs, and what the composer gets.
@Suite("Terminal selection")
@MainActor
struct TerminalSelectionTests {
    /// Under the selection's last line with room below, else over its first, inside the pane.
    @Test(arguments: [
        (CGFloat(40), "a\nb", CGFloat(400), CGFloat(40 + 2 * 18 + 4)),
        (CGFloat(360), "a\nb", CGFloat(400), CGFloat(360 - 32 - 4)),
        (CGFloat(10), "a", CGFloat(40), CGFloat(0)),
    ] as [(CGFloat, String, CGFloat, CGFloat)])
    func theBarHangsBesideTheSelection(originY: CGFloat, text: String, height: CGFloat, top: CGFloat) {
        let selection = AppTerminalModel.Selection(text: text, origin: CGPoint(x: 20, y: originY), lineHeight: 18)
        #expect(TerminalSelectionOverlay.top(selection, barHeight: 32, in: height) == top)
    }

    @Test(arguments: [
        ("", "FAIL x\n", "```\nFAIL x\n```\n"),
        ("Why does this fail?", "FAIL x", "Why does this fail?\n\n```\nFAIL x\n```\n"),
        ("look:\n", "FAIL x", "look:\n\n```\nFAIL x\n```\n"),
        ("keep", "\n", "keep"),
    ])
    func aSelectionJoinsTheDraftAsACodeBlock(draft: String, selection: String, result: String) {
        #expect(ShepherdViewModel.draft(draft, adding: selection) == result)
    }
}
