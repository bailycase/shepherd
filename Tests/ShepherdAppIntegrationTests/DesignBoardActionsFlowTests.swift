import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import DesignSurfaceKit
@testable import ShepherdApp
@testable import ShepherdUI

/// The board actions against a real server, a live stub agent and real board views:
/// a board dragged is written once where it lands, Duplicate
/// adds one board, Variations reaches the design agent with the board fenced as data, and a
/// presented board's links move Play between the design's boards and nowhere else.
@Suite("Design board actions flow", .mainActorExclusive)
@MainActor
struct DesignBoardActionsFlowTests {
    /// A board with links: to B, to the canvas root's flows/Cart, to a board the design lacks,
    /// and out of the design.
    static func linked(_ title: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>\(title)</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <div style="width: 400px; height: 300px; display: flex; flex-direction: column; gap: 12px; padding: 24px">
        <h1 id="title" style="margin: 0; font-size: 20px">\(title)</h1>
        <a id="next" href="B.dc.html" style="display: block; padding: 8px">Next</a>
        <a id="rooted" href="/flows/Cart.dc.html" style="display: block; padding: 8px">Cart</a>
        <a id="missing" href="Missing.dc.html" style="display: block; padding: 8px">Missing</a>
        <a id="out" href="https://example.com/" style="display: block; padding: 8px">Out</a>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    private struct Opened {
        let app: AppHarness
        let vm: ShepherdViewModel
        let window: OffscreenWindow
        let design: Design
        let log: URL
        let agent: AgentFixture
    }

    /// A design drawn by a live stub agent that logs what it receives, on screen in a window.
    private func open(boards: [DesignPath: String]? = nil) async throws -> Opened {
        let app = try AppHarness()
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        let log = app.dir.appendingPathComponent("pi.log")
        var drawer = try await app.liveAgent("Checkout", in: space, order: 0, log: log)
        let design = Design(name: "Checkout", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [drawer]))
        vm.designNetwork = .none
        _ = try await app.server.createDesign(design)
        if let boards {
            _ = try await app.server.writeDesignBoards(design.id, sources: boards)
            var entries: [String: JSONValue] = [:]
            for (index, path) in boards.keys.sorted().enumerated() {
                entries[path.rawValue] = .object(["x": .number(Double(index) * 480), "y": .number(0), "w": .number(400), "h": .number(300),
                                                  "is_interactive": .bool(true)])
            }
            _ = try await app.server.updateDesignIndex(design.id, patch: .object(["boards": .object(entries)]))
        } else {
            try await DesignFixtures.draw(DesignFixtures.checkout, in: design.id, on: app.server, perRow: 3)
        }
        vm.selectAgent(drawer.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1400, height: 900), dark: true, WorkspaceView(vm: vm))
        let screen = vm.designScreen(design.id)
        try await eventuallyOnMain("the canvas to draw every board on screen", timeout: .seconds(60)) {
            window.layout()
            return screen.isDrawn && !screen.visibleBoards.isEmpty
        }
        return Opened(app: app, vm: vm, window: window, design: design, log: log, agent: drawer)
    }

    /// A drag writes nothing until it ends, then writes the board's new place once: one revision,
    /// one pushed revision, the rest of canvas.json as it was.
    @Test func aDragWritesOnceWhereTheBoardLands() async throws {
        let opened = try await open()
        defer { opened.app.stop(); opened.window.close() }
        let screen = opened.vm.designScreen(opened.design.id)
        let a = try DesignPath.validate("A.dc.html")
        let before = try await opened.app.server.designSnapshot(opened.design.id)
        let pulls = screen.pulls
        for step in 1...20 {
            screen.move(SHBoardMove(board: a.rawValue, offset: CGSize(width: Double(step) * 7, height: Double(step) * 3), ended: false))
        }
        #expect(try await opened.app.server.designSnapshot(opened.design.id).revision == before.revision, "nothing written while dragging")
        await screen.move(SHBoardMove(board: a.rawValue, offset: CGSize(width: 140.4, height: 60.2), ended: true))?.value
        let after = try await opened.app.server.designSnapshot(opened.design.id)
        #expect(after.revision == before.revision + 1, "one write")
        #expect(screen.moveWrites == 1)
        let board = try #require(after.index.boards[a])
        #expect(board.x == 140 && board.y == 60)
        var expected = before.index
        expected.boards[a]?.x = 140
        expected.boards[a]?.y = 60
        #expect(after.index == expected, "only its x and y changed")
        try await eventuallyOnMain("the canvas to show the move") {
            screen.snapshot?.revision == after.revision && screen.boards.first { $0.id == a.rawValue }?.frame.origin == CGPoint(x: 140, y: 60)
        }
        #expect(screen.pulls - pulls <= 2, "the write's own pull, and at most one push")
    }

    /// Duplicate from the board's actions: one more board beside it, its file a copy, picked.
    @Test func duplicateAddsOneBoard() async throws {
        let opened = try await open()
        defer { opened.app.stop(); opened.window.close() }
        let screen = opened.vm.designScreen(opened.design.id)
        let a = try DesignPath.validate("A.dc.html")
        let before = try await opened.app.server.designSnapshot(opened.design.id)
        screen.select(a.rawValue)
        #expect(screen.actionsBoard == a)
        await screen.duplicate(a)?.value
        let after = try await opened.app.server.designSnapshot(opened.design.id)
        let copy = try DesignPath.validate("A-copy.dc.html")
        #expect(after.index.boards.count == before.index.boards.count + 1)
        #expect(Set(after.boards.keys).subtracting(before.boards.keys) == [copy])
        #expect(after.boards[copy] == before.boards[a])
        #expect(after.revision == before.revision + 1)
        #expect(screen.picks == [.init(board: copy)])
        try await eventuallyOnMain("the copy to draw", timeout: .seconds(60)) {
            opened.window.layout()
            return screen.boards.contains { $0.id == copy.rawValue } && screen.isDrawn
        }
    }

    /// Variations goes to the design agent as a message of fixed words, the board it is about in
    /// the fenced view record ahead of it.
    @Test func variationsReachTheDesignAgentWithTheBoardFencedAsData() async throws {
        let opened = try await open()
        defer { opened.app.stop(); opened.window.close() }
        _ = try await opened.app.readyThread(opened.agent.agent.id)
        let screen = opened.vm.designScreen(opened.design.id)
        await screen.askForVariations(of: try DesignPath.validate("B.dc.html"))?.value
        let log = opened.log
        try await eventuallyOnMain("pi to receive the variations message") {
            AppHarness.prompts(in: log).contains { $0.hasSuffix(DesignScreenModel.variationsMessage) }
        }
        let prompt = try #require(AppHarness.prompts(in: log).last { $0.hasSuffix(DesignScreenModel.variationsMessage) })
        #expect(prompt.hasPrefix("The text between the design-data markers"))
        #expect(prompt.contains(#""selectedBoards":["B.dc.html"]"#))
        #expect(DesignViewRecord.strippingFence(from: prompt) == DesignScreenModel.variationsMessage, "the thread shows the words alone")
    }

    /// "Ask for another direction" (the dashed tile after the last board), pressed, puts the words in
    /// the design chat's composer and focuses it; nothing reaches the agent until the person sends.
    @Test func theAnotherDirectionTilePutsItsWordsInTheComposerAndSendsNothing() async throws {
        AccessibilityNode.enable()
        let opened = try await open()
        defer { opened.app.stop(); opened.window.close() }
        let vm = opened.vm
        _ = try await opened.app.readyThread(opened.agent.agent.id)
        let screen = vm.designScreen(opened.design.id)
        let store = vm.threadStores.store(for: opened.agent.agent.id)
        let input = vm.threadStores.input(for: opened.agent.agent.id)
        screen.paneTab = .comments
        try await eventuallyOnMain("the tile after the last board") {
            opened.window.layout()
            return opened.window.controls().contains { $0.label == "Ask for another direction" }
        }
        let focusAsks = input.focusRequest
        let tile = try opened.window.press("Ask for another direction")
        #expect(ControlPress.undersized([tile], minimum: .desktop).isEmpty, "the tile's hit area is \(String(describing: tile.frame))")
        #expect(store.draft == DesignScreenModel.anotherDirectionDraft && store.draft == "Draw another direction")
        #expect(screen.paneTab == .chat, "the chat's tab shows its composer")
        #expect(vm.focusedPaneID == opened.agent.agent.paneID && input.focusRequest == focusAsks + 1, "the composer takes the keyboard")
        #expect(AppHarness.prompts(in: opened.log).isEmpty, "nothing is sent until the person sends it")
    }

    /// Words already drafted stay; the tile's words follow them.
    @Test func theAnotherDirectionTileKeepsWhatIsAlreadyDrafted() async throws {
        let opened = try await open()
        defer { opened.app.stop(); opened.window.close() }
        let vm = opened.vm
        let screen = vm.designScreen(opened.design.id)
        let store = vm.threadStores.store(for: opened.agent.agent.id)
        store.draft = "Keep the header"
        screen.draftAnotherDirection(store: store, input: vm.threadStores.input(for: opened.agent.agent.id)) {}
        #expect(store.draft == "Keep the header\n\nDraw another direction")
    }

    /// Present shows A focused in its own live view, which takes clicks: its link to B moves Play
    /// to B; on B, a link out of the design, and one to a board the design lacks, move nothing and
    /// navigate nowhere.
    @Test func aPlayLinkMovesBetweenTheDesignsBoardsOnly() async throws {
        let a = try DesignPath.validate("A.dc.html"), b = try DesignPath.validate("B.dc.html")
        let opened = try await open(boards: [a: Self.linked("A"), b: Self.linked("B")])
        defer { opened.app.stop(); opened.window.close() }
        let screen = opened.vm.designScreen(opened.design.id)
        let host = try #require(screen.host)
        screen.select(a.rawValue)
        screen.togglePresent()
        #expect(screen.presented == a)
        #expect(screen.viewRecord?.mode == .focused && screen.viewRecord?.visibleBoards == ["A.dc.html"])
        func presented(_ title: String) async throws -> DesignBoardView {
            var found: DesignBoardView?
            try await eventuallyOnMain("\(title) to be presented live", timeout: .seconds(60)) {
                opened.window.layout()
                guard let view = host.presentedView(), view.board.rawValue == "\(title).dc.html" else { return false }
                found = view
                return host.liveCount == 1 && host.liveView(view.board) == nil
            }
            return try #require(found)
        }
        let viewA = try await presented("A")
        #expect(viewA.superview?.hitTest(NSPoint(x: 10, y: 10)) != nil, "the presented board takes its own clicks")
        _ = try await viewA.webView.evaluateJavaScript("document.getElementById('next').click()")
        try await eventuallyOnMain("Play to move to B") { screen.presented == b }

        let viewB = try await presented("B")
        let refused = viewB.navigationsRefused
        _ = try await viewB.webView.evaluateJavaScript("document.getElementById('out').click()")
        _ = try await viewB.webView.evaluateJavaScript("document.getElementById('missing').click()")
        _ = try await viewB.webView.evaluateJavaScript("document.getElementById('rooted').click()")
        try await eventuallyOnMain("the three links to be refused") { viewB.navigationsRefused >= refused + 3 }
        #expect(screen.presented == b, "no link out of the design's boards moves Play")
        #expect(viewB.navigationsStarted == 1 && viewB.webView.url == viewB.surface.url(for: b), "the board never navigated")

        screen.togglePresent()
        #expect(screen.presented == nil)
        try await eventuallyOnMain("the canvas to draw again", timeout: .seconds(60)) {
            opened.window.layout()
            return screen.isDrawn
        }
    }
}
