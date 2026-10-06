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

@Suite("Design comment controls", .integrationTimeLimit)
struct DesignCommentControlsTests {
    @Test func aHoveredCommentCardOpensItsBoardAndResolvesThroughTheHost() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressing(hovering: true) }
        }
    }

    @Test func aCommentAtRestResolvesThroughItsAccessibilityAction() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressing(hovering: false) }
        }
    }

    @MainActor
    private static func pressing(hovering: Bool) async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let vm = try await app.start()
        vm.designNetwork = .none
        vm.designLiveCap = 0
        let design = Design(name: "Comment actions", createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        try await DesignFixtures.draw(Array(DesignFixtures.checkout.prefix(2)), in: design.id, on: app.server)
        _ = try await app.server.updateDesignIndex(design.id, patch: .object([
            "pages": .array([.object(["id": .string("flows"), "name": .string("Flows")]),
                             .object(["id": .string("system"), "name": .string("System")])]),
            "boards": .object(["B.dc.html": .object(["page": .string("system"), "x": .number(12_000), "y": .number(6_000)])])
        ]))
        let b = try DesignPath.validate("B.dc.html")
        let a = try DesignPath.validate("A.dc.html")
        for board in [b, a] {
            _ = try await app.server.addDesignComment(design.id, draft: DesignCommentDraft(
                board: board, tid: 7, path: [1, 1, 0], target: "Step 1",
                rect: DesignCommentRect(x: 32, y: 78, w: 396, h: 80), text: "Show the absolute counts."))
        }
        let screen = vm.designScreen(design.id)
        await screen.refresh()
        screen.resized(CGSize(width: 900, height: 800))
        screen.paneTab = .comments
        screen.viewport = NWCanvasViewport(offset: CGPoint(x: -10_000, y: -10_000), zoom: 1)
        let first = try #require(screen.openCards.first)
        let second = try #require(screen.openCards.last)
        #expect(screen.page == "flows" && !screen.visibleBoards.contains(b))

        let window = OffscreenWindow(size: CGSize(width: AppLayout.designChatWidth, height: 500), dark: true,
                                     Comments(screen: screen, hovering: hovering))
        defer { window.close() }
        try await eventuallyOnMain("the comment's open button") {
            window.layout()
            return window.controls().contains { $0.label == "Open comment 1" }
        }
        #expect(window.controls().contains { $0.label == "Resolve comment 1" } == hovering)
        #expect(ControlPress.actions(onLabelContaining: "Open comment 1", under: window.host).contains("Resolve"))
        #expect(ControlPress.undersized(window.controls(), minimum: .desktop).isEmpty)

        try window.press("Open comment 1")
        #expect(screen.page == "system" && screen.selectedWhole == [b])
        #expect(screen.visibleBoards.contains(b) && screen.openThread?.id == first.id)
        #expect(screen.popoverAnchor?.board == b.rawValue && screen.paneTab == .comments)
        let center = screen.viewport.screen(CGPoint(x: 12_640, y: 6_400))
        #expect(abs(center.x - 450) < 1 && abs(center.y - 400) < 1)

        if hovering {
            try window.press("Resolve comment 1")
        } else {
            try ControlPress.perform("Resolve", onLabelContaining: "Open comment 1", under: window.host)
        }
        try await eventuallyOnMain("the resolved comment to leave the list and canvas") {
            window.layout()
            return screen.openCards.map(\.id) == [second.id] && screen.openThread == nil
        }
        let saved = try await app.server.designComments(design.id)
        #expect(saved.comments.first { $0.id == first.id }?.isOpen == false)
        #expect(saved.comments.first { $0.id == second.id }?.isOpen == true)
        #expect(screen.commentsTabCount == 1 && !screen.pins.contains { $0.id == first.id.uuidString })
        #expect(screen.commentCards.cards[first.id] == first, "the chat keeps its historical card")
        #expect(screen.focusBoard == b, "Resolve does not open the next card")
        #expect(!window.controls().contains { $0.label == "Open comment 1" || $0.label == "Resolve comment 1" })

        try window.press("Open comment 2")
        #expect(screen.page == "flows" && screen.openThread?.id == second.id)
        if hovering {
            try window.press("Resolve comment 2")
        } else {
            try ControlPress.perform("Resolve", onLabelContaining: "Open comment 2", under: window.host)
        }
        try await eventuallyOnMain("the last resolved comment to leave an empty list") {
            window.layout()
            return screen.openCards.isEmpty && window.controls().isEmpty
        }
        #expect(screen.commentsTabCount == 0 && screen.pins.isEmpty)
        #expect(DesignChatPane.tabs(open: screen.commentsTabCount, tweak: false).allSatisfy { $0.count == nil })
        #expect(try await app.server.designComments(design.id).comments.allSatisfy { !$0.isOpen })
        #expect(vm.remoteActionError == nil)
    }

    private struct Comments: View {
        let screen: DesignScreenModel
        let hovering: Bool

        var body: some View {
            DesignCommentsList(cards: screen.openCards, resolve: { screen.resolve($0) },
                               hovering: hovering ? screen.openCards.first?.id : nil, open: { screen.revealComment($0) })
                .background(Color.nw.bgWindow)
        }
    }
}
