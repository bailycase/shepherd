import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Jump to a board (JumpInContext): the card over the checkout design's canvas in the boards'
/// window, from the real recents and index. Opened is the board's state: E then A then C opened
/// lately, A picked on the canvas. Then a query, All designs, and a design with no boards opened.
extension DesignPreviewTests {
    @Test(arguments: ["open", "query", "all", "fresh", "long"])
    func designJump(_ state: String) async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        await screen.refresh()
        if state == "long" {
            _ = try await workspace.server.updateDesignIndex(checkout.id, patch: .object(["boards": .object([
                "B.dc.html": .object(["title": .string("B · Step table with every drop-off reason, broken down by platform and country")]),
            ])]))
            await screen.refresh()
        }
        let now = Date().timeIntervalSince1970
        if state != "fresh" {
            vm.designJumpRecents.opened(DesignPath("C.dc.html")!, in: checkout.id, at: now - 26 * 3600)
            vm.designJumpRecents.opened(DesignPath("A.dc.html")!, in: checkout.id, at: now - 600)
            vm.designJumpRecents.opened(DesignPath("A-phone.dc.html")!, in: checkout.id, at: now - 120)
        }
        screen.select("A.dc.html")
        vm.openDesignJump(checkout.id)
        let model = try #require(vm.designJump)
        switch state {
        case "query": model.query = "fun"
        case "all": model.scope = .allDesigns
        default: break
        }
        await vm.loadDesignThumbnails()
        try await Preview.renderMatrix(state == "open" ? "app-window-design-jump" : "app-window-design-jump-\(state)",
                                       size: Self.windowSizeForJump, scales: state == "open" ? [1, 1.3] : [1], ready: {
            // Every row's small picture drawn (the canvas's own drawing can stand in earlier, but
            // only for boards on screen): what a person sees a beat after the card opens.
            screen.isDrawn && model.rows.allSatisfy { item in
                switch item.kind {
                case .board(let path): vm.designRendering.boardPictures.image(checkout.id, path) != nil
                case .design(let id): vm.designRendering.thumbnails.image(id) != nil
                }
            }
        }) {
            RootView(vm: vm)
        }
    }

    /// The board's window: 1600 by 1000.
    static var windowSizeForJump: CGSize { CGSize(width: 1600, height: 1000) }
}
