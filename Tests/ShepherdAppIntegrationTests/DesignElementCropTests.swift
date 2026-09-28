import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The @ picker's element pictures (RefAtElements): each element cut from its own board as the
/// shared rasterizer drew it, only for the rows that ask, the board drawn once per revision and
/// never with more than the rasterizer's one web view.
@Suite("Design element pictures", .mainActorExclusive)
@MainActor
struct DesignElementCropTests {
    static func board(button: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Pay</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>body{margin:0}</style></helmet>
        <div style="width: 400px; height: 300px; box-sizing: border-box; padding: 20px; background: #ffffff">
        <h1 style="margin: 0; font-size: 20px; color: #111111">Checkout</h1>
        <button style="display: block; margin-top: 40px; width: 200px; height: 130px; border: 0; background: \(button); color: \(button)">Pay now</button>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    /// The pixel at the middle of `image`, as 0–255 RGB.
    static func middle(_ image: CGImage) -> (Int, Int, Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    @Test func anElementsPictureIsCutFromItsBoardOnlyWhenItsRowAsks() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        var drawer = Fixture.agent("Checkout", in: space)
        let design = Design(name: "Checkout", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [drawer]))
        vm.designNetwork = .none
        _ = try await app.server.createDesign(design)
        let path = try DesignPath.validate("Pay.dc.html")
        _ = try await app.server.writeDesignBoard(design.id, path: path, source: Self.board(button: "#4f46e5"))
        _ = try await app.server.updateDesignIndex(design.id, patch: .object(["boards": .object([
            "Pay.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(400), "h": .number(300), "title": .string("Pay")]),
        ])]))

        func rows() async throws -> (board: DesignMentionItem, elements: [DesignMentionItem]) {
            let catalog = await app.server.designMentionCatalog()
            let board = try #require(catalog.boards[design.id]?.first)
            return (board, catalog.elements[board.id] ?? [])
        }
        func target(_ board: DesignMentionItem, _ elements: [DesignMentionItem]) throws -> DesignElementCrops.Board {
            DesignElementCrops.Board(design: design.id, path: path, size: CGSize(width: 400, height: 300),
                                     revision: try #require(board.revision), tids: elements.compactMap { $0.reference.element?.tid })
        }
        let (board, elements) = try await rows()
        let button = try #require(elements.first { $0.title.contains("Pay now") }?.reference.element?.tid)
        let title = try #require(elements.first { $0.title.contains("Checkout") && $0.reference.element?.tid != button }?.reference.element?.tid)
        let crops = vm.designRendering.elementCrops
        let rasterizer = vm.designRendering.rasterizer
        rasterizer.resetPeak()

        crops.want(button, on: try target(board, elements))
        try await eventuallyOnMain("the button's picture to be cut") { crops.crop(design.id, path, revision: board.revision!, tid: button) != nil }
        let picture = try #require(crops.crop(design.id, path, revision: board.revision!, tid: button))
        #expect(CGSize(width: picture.width, height: picture.height) == AppLayout.referenceCropPixels)
        let (r, g, b) = Self.middle(picture)
        #expect(abs(r - 0x4f) < 12 && abs(g - 0x46) < 12 && abs(b - 0xe5) < 12, "the element's own picture, not its board's: \(r),\(g),\(b)")
        #expect(crops.drawn == 1 && crops.cut == 1)
        #expect(crops.crop(design.id, path, revision: board.revision!, tid: title) == nil, "a row that never asked has no picture cut")

        // Another row at the same revision is cut from the board already drawn.
        crops.want(title, on: try target(board, elements))
        try await eventuallyOnMain("the title's picture to be cut") { crops.crop(design.id, path, revision: board.revision!, tid: title) != nil }
        #expect(crops.drawn == 1 && crops.cut == 2)
        crops.want(button, on: try target(board, elements))
        #expect(crops.cut == 2, "a picture already cut is kept for its revision")
        #expect(rasterizer.peakWebViews <= 1, "the rasterizer's one view draws it")

        // A new revision draws the board again.
        _ = try await app.server.writeDesignBoard(design.id, path: path, source: Self.board(button: "#0f766e"))
        let (next, nextElements) = try await rows()
        #expect(next.revision != board.revision)
        crops.want(button, on: try target(next, nextElements))
        try await eventuallyOnMain("the new revision's picture to be cut") { crops.crop(design.id, path, revision: next.revision!, tid: button) != nil }
        #expect(crops.drawn == 2)
        #expect(crops.crop(design.id, path, revision: board.revision!, tid: button) == nil, "the old revision's pictures go")
        let (r2, g2, b2) = Self.middle(try #require(crops.crop(design.id, path, revision: next.revision!, tid: button)))
        #expect(abs(r2 - 0x0f) < 12 && abs(g2 - 0x76) < 12 && abs(b2 - 0x6e) < 12)
    }
}
