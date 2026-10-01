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

/// Shared pieces on the canvas (DESIGN.md › Shared pieces): a piece's "used in 2 boards" label, and
/// the Tweak tab on one use of it (the Shared piece note and Go to source). A real server and the
/// real renderer; the boards are drawn from their snapshots.
extension DesignPreviewTests {
    private static func pieceBoard(_ body: String, width: Int, height: Int) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Board</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>body{margin:0;font-family:-apple-system,system-ui,sans-serif}</style></helmet>
        \(body)
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":\(width),"height":\(height)}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    /// The checkout design with a Card piece and two boards that import it, in a row under the
    /// phone version, and the canvas looking at that row.
    @Test(arguments: ["use", "piece"])
    func designScreenSharedPiece(_ state: String) async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let card = try #require(DesignPath("Card.dc.html")), home = try #require(DesignPath("Home.dc.html")), menu = try #require(DesignPath("Menu.dc.html"))
        let page = { (title: String) in
            Self.pieceBoard("""
                <div style="width: 640px; height: 400px; box-sizing: border-box; padding: 32px; background: #f6f6f9; color: #1c1c28; display: flex; flex-direction: column; gap: 18px">
                <h1 style="margin: 0; font-size: 22px">\(title)</h1>
                <dc-import name="Card" hint-size="360px,96px"></dc-import>
                </div>
                """, width: 640, height: 400)
        }
        let pieceSource = Self.pieceBoard("""
            <div data-el="Card" style="width: 360px; height: 96px; box-sizing: border-box; padding: 16px; background: #ffffff; border: 1px solid #e4e4ea; border-radius: 12px; color: #1c1c28">\
            <div style="font-size: 12px; color: #6b6b7b">Conversion</div>\
            <div style="font-size: 26px; font-weight: 600; margin-top: 6px">68%</div></div>
            """, width: 360, height: 96)
        _ = try await workspace.server.writeDesignBoards(checkout.id, sources: [card: pieceSource, home: page("Home"), menu: page("Menu")])
        func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ title: String) -> JSONValue {
            .object(["x": .number(x), "y": .number(y), "w": .number(w), "h": .number(h), "title": .string(title)])
        }
        _ = try await workspace.server.updateDesignIndex(checkout.id, patch: .object(["boards": .object([
            "Card.dc.html": frame(0, 1884, 360, 96, "Card"), "Home.dc.html": frame(440, 1884, 640, 400, "Home"),
            "Menu.dc.html": frame(1160, 1884, 640, 400, "Menu"),
        ])]))
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        let tweak = try #require(screen.tweak)
        await screen.refresh()
        #expect(screen.boards.first { $0.id == "Card.dc.html" }?.usage == "used in 2 boards")
        if state == "use" {
            let use = DesignElementPick(board: home, id: try #require(DesignElementID(board: home.viewName, tid: 4, path: [1, 1])),
                                        rect: CGRect(x: 32, y: 72, width: 360, height: 96), kind: .shape, label: nil,
                                        tag: "component · Card", piece: "Card")
            screen.setSelection([.init(board: home, element: use)])
            screen.paneTab = .tweak
            await tweak.select(screen.tweakTarget)
            #expect(tweak.presentation.instanceOf == "Card")
        } else {
            screen.setSelection([.init(board: card)])
            screen.paneTab = .chat
        }
        let view = NWCanvasViewport(offset: CGPoint(x: NWDesignMetrics.fitLeading, y: -1085), zoom: 0.65)
        try await Preview.render("app-window-design-piece-\(state)", size: CGSize(width: 1440, height: 900), ready: {
            if screen.snapshot != nil, screen.viewport != view { screen.viewport = view }
            let drawn = [card, home, menu].allSatisfy { screen.host?.image($0) != nil }
            return screen.viewport == view && screen.isDrawn && drawn
        }) {
            RootView(vm: vm)
        }
    }

    /// What `board_render` hands the agent, saved as the PNG it would see: a board that imports a piece
    /// (the piece drawn in it, through the export path) and a checkout direction, with the design off screen.
    @Test func designAgentRender() async throws {
        let (workspace, checkout, _) = try await designWorkspace()
        defer { workspace.stop() }
        let card = try #require(DesignPath("Card.dc.html")), home = try #require(DesignPath("Home.dc.html"))
        let pieceSource = Self.pieceBoard("""
            <div data-el="Card" style="width: 360px; height: 96px; box-sizing: border-box; padding: 16px; background: #ffffff; border: 1px solid #e4e4ea; border-radius: 12px; color: #1c1c28">\
            <div style="font-size: 12px; color: #6b6b7b">Conversion</div>\
            <div style="font-size: 26px; font-weight: 600; margin-top: 6px">68%</div></div>
            """, width: 360, height: 96)
        let page = Self.pieceBoard("""
            <div style="width: 640px; height: 400px; box-sizing: border-box; padding: 32px; background: #f6f6f9; color: #1c1c28; display: flex; flex-direction: column; gap: 18px">
            <h1 style="margin: 0; font-size: 22px">Home</h1>
            <dc-import name="Card" hint-size="360px,96px"></dc-import>
            </div>
            """, width: 640, height: 400)
        _ = try await workspace.server.writeDesignBoards(checkout.id, sources: [card: pieceSource, home: page])
        let directory = try #require(Preview.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for path in ["Home.dc.html", "A.dc.html"] {
            let rendered = try await workspace.server.renderDesignBoard(checkout.id, request: DesignRenderRequest(path: path))
            let data = try #require(Data(base64Encoded: rendered.image.data))
            let name = path.replacingOccurrences(of: ".dc.html", with: "")
            try data.write(to: directory.appendingPathComponent("design-agent-render-\(name).\(rendered.image.mimeType == "image/png" ? "png" : "jpg")"))
            #expect(rendered.text.hasPrefix("\(path) at "))
        }
    }
}
