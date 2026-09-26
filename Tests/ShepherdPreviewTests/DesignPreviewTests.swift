import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Design tool (Settings ▸ Experiments ▸ Design tool): the Designs page (NavDesigns), New
/// design (DZStart), and a design's canvas beside its chat (DZCanvas), with the sidebar's
/// Designs destination and design rows. Boards are real fixture boards rendered off screen by
/// the renderer and drawn from their snapshots: a capture can't draw a live web view.
@Suite("Design previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct DesignPreviewTests {
    /// The main column beside a docked sidebar in the boards' 1440×900 window.
    private static let pageSize = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)
    private static let windowSize = CGSize(width: 1440, height: 900)

    /// A workspace with the Design tool on, two projects, a plain thread, and two designs: the
    /// checkout funnel (three directions and a phone) drawn by a live stub agent, and a phone-first
    /// onboarding design.
    private func designWorkspace() async throws -> (workspace: PreviewWorkspace, checkout: Design, agent: Agent) {
        let workspace = try PreviewWorkspace()
        workspace.settings.designToolEnabled = true
        let vm = workspace.vm
        vm.designNetwork = .none
        vm.designLiveCap = 0
        let web = Space(name: "acme-web", path: workspace.dir.path)
        let app = Space(name: "shepherd", path: workspace.dir.path)
        let (thread, threadTab) = try await workspace.agent("Fix the login redirect", in: web, order: 0, status: .working)
        var (agent, tab) = try await workspace.agent("Checkout funnel dashboard", in: web, order: 1, live: true)
        let checkout = Design(name: "Checkout funnel dashboard", spaceID: web.id, agentID: agent.id, createdAt: 1_000)
        agent.designID = checkout.id
        try await workspace.seed(ShepherdState(spaces: [web, app], tabs: [threadTab, tab], agents: [thread, agent]))
        _ = try await workspace.server.createDesign(checkout)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: checkout.id, on: workspace.server, perRow: 3)
        let onboarding = Design(name: "Onboarding", spaceID: app.id, createdAt: 2_000)
        _ = try await workspace.server.createDesign(onboarding)
        let phone = [DesignFixtures.Board(path: "A-phone.dc.html", title: "A · phone", width: 390, height: 844, accent: "#be123c")]
        try await DesignFixtures.draw(phone, in: onboarding.id, on: workspace.server)
        let server = workspace.server
        try await eventuallyOnMain("the designs to load") { vm.state.designs.count == 2 && vm.state == server.state }
        return (workspace, checkout, agent)
    }

    @Test func designsPage() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        await vm.loadDesignThumbnails()
        try await Preview.render("page-designs", size: Self.pageSize, ready: {
            vm.state.designs.allSatisfy { vm.designRendering.thumbnails.image($0.id) != nil }
        }) {
            DesignsDestination(vm: vm)
        }
    }

    @Test func newDesign() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openNewDesign()
        #expect(vm.shownDestination == .newDesign)
        try await Preview.render("app-window-new-design", size: Self.windowSize) {
            RootView(vm: vm)
        }
    }

    /// The canvas at its fitted zoom beside the design agent's chat, the first board selected.
    @Test func designScreen() async throws {
        let (workspace, checkout, agent) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        #expect(vm.selectedAgentID == agent.id)
        #expect(vm.selectedSidebarRow == .design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        screen.select("A.dc.html")
        try await Preview.render("app-window-design", size: Self.windowSize, ready: { screen.isDrawn }) {
            RootView(vm: vm)
        }
    }

    /// Select (NWSelectionRing; NWDesignTool, DZTweak): a card on A selected with its tag, the
    /// bars under the pointer ringed, and B selected whole by its label. Rects are the fixture
    /// board's layout (a capture draws snapshots, so nothing live is asked).
    @Test func designScreenSelect() async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        let a = try #require(DesignPath("A.dc.html"))
        func element(_ tid: Int, _ path: [Int], _ rect: CGRect, kind: DesignElementKind, label: String?, tag: String) throws -> DesignElementPick {
            DesignElementPick(board: a, id: try #require(DesignElementID(board: a.viewName, tid: tid, path: path)), rect: rect,
                              kind: kind, label: label, tag: tag)
        }
        let card = try element(7, [1, 1, 0], CGRect(x: 32, y: 78, width: 396, height: 80), kind: .shape, label: "Step 1 90%",
                               tag: "card · Step 1 90%")
        let bars = try element(16, [1, 2], CGRect(x: 32, y: 176, width: 1216, height: 592), kind: .shape, label: nil, tag: "card")
        screen.setSelection([.init(board: try #require(DesignPath("B.dc.html"))), .init(board: a, element: card)], hover: bars)
        // Close enough on A to read the tag (the canvas opens fitted, at about 17%).
        let close = NWCanvasViewport(offset: CGPoint(x: NWDesignMetrics.fitLeading, y: NWDesignMetrics.fitFrameTop), zoom: 0.55)
        try await Preview.render("app-window-design-select", size: Self.windowSize, ready: {
            if screen.snapshot != nil, screen.viewport != close { screen.viewport = close }
            return screen.viewport == close && screen.isDrawn
        }) {
            RootView(vm: vm)
        }
        let record = try #require(screen.viewRecord)
        #expect(record.isValid && record.selected.map(\.description) == ["A.dc.html#7:1/1/0"])
        #expect(record.selectedBoards == ["A.dc.html", "B.dc.html"])
    }

    /// Comments on the checkout funnel's A, made once its agent answers: the step card's comment
    /// (answered under its pin) and one on the bars. Rects are the fixture board's layout.
    private func comment(on workspace: PreviewWorkspace, _ design: Design, agent: Agent) async throws -> [DesignComment] {
        let server = workspace.server
        let agentID = agent.id
        try await eventually("the design agent to start") { @Sendable [server] in
            guard case .snapshot(let s) = try await server.nativeThread(agentID: agentID, request: .snapshot()) else { return false }
            return !s.piSessionID.isEmpty
        }
        let a = try #require(DesignPath("A.dc.html"))
        let first = try await server.addDesignComment(design.id, draft: DesignCommentDraft(
            board: a, tid: 7, path: [1, 1, 0], target: "Step 1", rect: DesignCommentRect(x: 32, y: 78, w: 396, h: 80),
            text: "Show the absolute counts next to the percentages."))
        #expect(first.undelivered == nil)
        _ = try await server.replyToDesignComment(design.id, commentID: first.comment.id,
                                                  text: "Done on A and A · phone. Want the drop-off line in counts too?", author: .agent)
        let second = try await server.addDesignComment(design.id, draft: DesignCommentDraft(
            board: a, tid: 16, path: [1, 2], rect: DesignCommentRect(x: 32, y: 176, w: 1216, h: 592),
            text: "Use the accent for the biggest drop only."))
        return [first.comment, second.comment]
    }

    /// Close enough on A to read a pin's thread (the canvas opens fitted, at about 17%).
    private static let closeOnA = NWCanvasViewport(offset: CGPoint(x: NWDesignMetrics.fitLeading, y: NWDesignMetrics.fitFrameTop), zoom: 0.55)

    /// Comments (DZCanvas, DZTweak; NWCommentPin, NWCommentThread, NWCommentCard): two pins on A,
    /// the first's thread open with the design agent's answer, and in the chat the comment's card
    /// with the agent's turn inside it.
    @Test func designScreenComments() async throws {
        let (workspace, checkout, agent) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        let comments = try await comment(on: workspace, checkout, agent: agent)
        await screen.refreshComments()
        screen.openThread(comments[0].id.uuidString)
        let store = vm.threadStores.store(for: agent.id)
        try await Preview.render("app-window-design-comments", size: Self.windowSize, ready: {
            if screen.snapshot != nil, screen.viewport != Self.closeOnA { screen.viewport = Self.closeOnA }
            let answered = store.rows.contains { $0.designComment == comments[0].id && $0.commentAnswered }
            let second = store.rows.contains { $0.designComment == comments[1].id && $0.isUser }
            return screen.viewport == Self.closeOnA && screen.isDrawn && answered && second && !store.running
        }) {
            RootView(vm: vm)
        }
        #expect(screen.pins.map(\.number) == [1, 2])
        #expect(screen.openThread?.replies.map(\.author) == [.agent])
    }

    /// The Comments tab (DZCanvas): the open comments' cards, and a third comment being written
    /// on A's second step with the Comment tool.
    @Test func designScreenCommentsTab() async throws {
        let (workspace, checkout, agent) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        _ = try await comment(on: workspace, checkout, agent: agent)
        await screen.refreshComments()
        screen.paneTab = .comments
        screen.tool = .comment
        let a = try #require(DesignPath("A.dc.html"))
        var step = DesignElementPick(board: a, id: try #require(DesignElementID(board: a.viewName, tid: 10, path: [1, 1, 1])),
                                     rect: CGRect(x: 442, y: 78, width: 396, height: 80), kind: .shape, label: "Step 2 70%",
                                     tag: "card · Step 2 70%")
        step.words = "Step 2 70%"
        screen.beginComment(on: step)
        screen.draftText = "Make the bars thicker."
        try await Preview.render("app-window-design-comments-tab", size: Self.windowSize, ready: {
            if screen.snapshot != nil, screen.viewport != Self.closeOnA { screen.viewport = Self.closeOnA }
            return screen.viewport == Self.closeOnA && screen.isDrawn && screen.openCards.count == 2
        }) {
            RootView(vm: vm)
        }
        #expect(screen.pins.map(\.number) == [1, 2, 3])
    }

    /// The checkout's A and A · phone as a design system would draw them: tokens declared in the
    /// helmet, the step cards named "funnel card", and two data-props under Labels.
    private static func tokenized(_ board: DesignFixtures.Board) -> String {
        DesignFixtures.source(board)
            .replacingOccurrences(of: "<helmet><style>", with: "<helmet><style>:root{--accent:#4f46e5;--slate:#475569;--success:#059669;"
                                  + "--space-3:12px;--space-4:16px;--space-6:24px;--space-8:32px;--radius-s:8px;--radius-m:10px;--radius-l:12px}")
            .replacingOccurrences(of: "<div style=\"flex: 1; background: #ffffff; border: 1px solid #e4e4ea; border-radius: 10px",
                                  with: "<div data-el=\"funnel card\" style=\"flex: 1; background: #ffffff; border: 1px solid #e4e4ea; border-radius: 10px")
            .replacingOccurrences(of: "data-props='{", with: "data-props='{\"counts\":{\"editor\":\"boolean\",\"default\":true,\"section\":\"Labels\"},"
                                  + "\"density\":{\"editor\":\"enum\",\"options\":[\"compact\",\"cozy\"],\"default\":\"cozy\",\"section\":\"Labels\"},")
    }

    /// Tweak (DZTweak) in each of its states: a card selected with every funnel card in scope, a
    /// board picked whole (its data-props alone), and nothing selected.
    @Test(arguments: ["element", "board", "empty"])
    func designScreenTweak(_ state: String) async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let a = try #require(DesignPath("A.dc.html")), phone = try #require(DesignPath("A-phone.dc.html"))
        let boards = Dictionary(uniqueKeysWithValues: DesignFixtures.checkout.filter { ["A.dc.html", "A-phone.dc.html"].contains($0.path) }
            .map { (try! DesignPath.validate($0.path), Self.tokenized($0)) })
        _ = try await workspace.server.writeDesignBoards(checkout.id, sources: boards)
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        let tweak = try #require(screen.tweak)
        switch state {
        case "element":
            let card = DesignElementPick(board: a, id: try #require(DesignElementID(board: a.viewName, tid: 7, path: [1, 1, 0])),
                                         rect: CGRect(x: 32, y: 78, width: 396, height: 80), kind: .shape, label: "Step 1 90%",
                                         tag: "card · funnel card")
            screen.setSelection([.init(board: a, element: card)])
            tweak.scope = .every
        case "board":
            screen.setSelection([.init(board: a)])
        default:
            screen.clearSelection()
        }
        screen.paneTab = .tweak
        _ = phone
        let close = NWCanvasViewport(offset: CGPoint(x: NWDesignMetrics.fitLeading, y: NWDesignMetrics.fitFrameTop), zoom: 0.55)
        try await Preview.render("app-window-design-tweak-\(state)", size: Self.windowSize, ready: {
            if screen.snapshot != nil, screen.viewport != close { screen.viewport = close }
            let loaded = state == "empty" ? tweak.presentation.isEmpty
                : !tweak.presentation.groups.isEmpty && (state != "element" || tweak.presentation.scopeNote?.contains("A · phone") == true)
            return screen.viewport == close && screen.isDrawn && loaded
        }) {
            RootView(vm: vm)
        }
    }

    /// The board actions over A picked whole (DZCanvas), "Ask for another direction" after the
    /// last board, and a canvas with two pages: its title and sticky notes, and the pages menu in
    /// the toolbar.
    @Test func designScreenActionsPagesAndNotes() async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        _ = try await workspace.server.updateDesignIndex(checkout.id, patch: .object([
            "pages": .array([.object(["id": .string("flows"), "name": .string("Checkout flows")]),
                             .object(["id": .string("system"), "name": .string("System")])]),
            "notes": .object([
                "t1": .object(["kind": .string("title1"), "x": .number(0), "y": .number(-420), "maxW": .number(4000),
                               "text": .string("Checkout funnel — three directions and a phone")]),
                "s1": .object(["kind": .string("sticky"), "x": .number(0), "y": .number(1900), "w": .number(560),
                               "text": .string("Keep the phone's total above the fold.")]),
            ]),
        ]))
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        let a = try #require(DesignPath("A.dc.html"))
        let view = NWCanvasViewport(offset: CGPoint(x: NWDesignMetrics.fitLeading, y: 150), zoom: 0.24)
        try await Preview.render("app-window-design-actions", size: Self.windowSize, ready: {
            if screen.snapshot?.index.pages?.count == 2 {
                if screen.picks.isEmpty { screen.select(a.rawValue) }
                if screen.viewport != view { screen.viewport = view }
            }
            return screen.viewport == view && screen.isDrawn && screen.actionsBoard == a && screen.notes.count == 2
        }) {
            RootView(vm: vm)
        }
    }

    /// The board actions over A scrolled up to the canvas's top, where no board draws them: at 55%
    /// they flip under A; at 24% the next row's label is in the way too, so they sit just inside
    /// A's top edge.
    @Test(arguments: [("flipped", CGFloat(0.55)), ("inside", 0.24)])
    func designScreenActionsWithoutRoomAbove(_ name: String, zoom: CGFloat) async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        let a = try #require(DesignPath("A.dc.html"))
        let view = NWCanvasViewport(offset: CGPoint(x: NWDesignMetrics.fitLeading, y: 20), zoom: zoom)
        try await Preview.render("app-window-design-actions-\(name)", size: Self.windowSize, ready: {
            if screen.snapshot != nil {
                if screen.picks.isEmpty { screen.select(a.rawValue) }
                if screen.viewport != view { screen.viewport = view }
            }
            return screen.viewport == view && screen.isDrawn && screen.actionsBoard == a
        }) {
            RootView(vm: vm)
        }
    }

    /// Present (decision 11): the selected board focused over the canvas's scrim, its label above.
    @Test func designScreenPresent() async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        let a = try #require(DesignPath("A.dc.html"))
        try await Preview.render("app-window-design-present", size: Self.windowSize, ready: {
            if screen.snapshot != nil, screen.presented == nil {
                screen.select(a.rawValue)
                screen.togglePresent()
            }
            return screen.presented == a && screen.host?.image(a) != nil
        }) {
            RootView(vm: vm)
        }
        #expect(screen.viewRecord?.mode == .focused)
    }

    /// The Designs destination selected on its page, with design rows in Recents.
    @Test func appWindowDesigns() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openDestination(.designs)
        await vm.loadDesignThumbnails()
        try await Preview.render("app-window-designs", size: Self.windowSize, ready: {
            vm.state.designs.allSatisfy { vm.designRendering.thumbnails.image($0.id) != nil }
        }) {
            RootView(vm: vm)
        }
    }

    /// New thread with the Design tool on: "Start a design" is the last suggestion card.
    @Test func newThreadStartADesign() async throws {
        let (workspace, _, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openNewThread()
        try await Preview.render("page-new-thread-design", size: Self.pageSize) {
            NewThreadPage(vm: vm, chrome: PageHeaderChrome())
        }
    }
}
