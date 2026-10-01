import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Shared pieces on the Mac's canvas (docs/designs.md › Shared pieces; docs/design/design-tool.md › Shared pieces),
/// with a real server, the real renderer and an off-screen window: a piece edited once redraws every
/// board that imports it (live view and snapshot) and no other, a piece says how many boards use it,
/// a pick on one of its uses offers Go to source and no Tweak on the instance.
@Suite("Design shared pieces on the canvas", .mainActorExclusive)
@MainActor
struct DesignSharedPiecesFlowTests {
    static func board(_ body: String, preview: (Int, Int)) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Board</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>body { margin: 0 }</style></helmet>
        \(body)
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"density":{"editor":"enum","options":["cozy","compact"],"default":"cozy"},"$preview":{"width":\(preview.0),"height":\(preview.1)}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    static func card(_ color: String) -> String {
        board(#"<div style="width: 200px; height: 60px; background: \#(color)" data-el="Card"></div>"#, preview: (200, 60))
    }

    static func page(_ import: String = #"<dc-import name="Card" hint-size="200px,60px"></dc-import>"#) -> String {
        board(#"<div style="width: 400px; height: 300px; background: #ffffff">\#(`import`)</div>"#, preview: (400, 300))
    }

    static let home = DesignPath("Home.dc.html")!
    static let menu = DesignPath("Menu.dc.html")!
    static let plain = DesignPath("Plain.dc.html")!
    static let cardPath = DesignPath("Card.dc.html")!

    private func openCanvas(_ app: AppHarness) async throws -> (vm: ShepherdViewModel, window: OffscreenWindow, design: Design, screen: DesignScreenModel, host: DesignHost) {
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        var drawer = try await app.liveAgent("Pieces", in: space)
        let design = Design(name: "Pieces", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [drawer]))
        vm.designNetwork = .none
        _ = try await app.server.createDesign(design)
        _ = try await app.server.writeDesignBoards(design.id, sources: [
            Self.home: Self.page(), Self.menu: Self.page(), Self.plain: Self.page(""), Self.cardPath: Self.card("#ff0000"),
        ])
        func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ title: String) -> JSONValue {
            .object(["x": .number(x), "y": .number(y), "w": .number(w), "h": .number(h), "title": .string(title)])
        }
        _ = try await app.server.updateDesignIndex(design.id, patch: .object(["boards": .object([
            "Home.dc.html": frame(0, 0, 400, 300, "Home"), "Menu.dc.html": frame(480, 0, 400, 300, "Menu"),
            "Plain.dc.html": frame(960, 0, 400, 300, "Plain"), "Card.dc.html": frame(0, 400, 200, 60, "Card"),
        ])]))
        vm.selectAgent(drawer.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1500, height: 900), dark: false, WorkspaceView(vm: vm))
        let screen = vm.designScreen(design.id)
        let host = try #require(screen.host)
        try await eventuallyOnMain("the canvas to draw every board", timeout: .seconds(60)) {
            window.layout()
            return screen.isDrawn && screen.snapshot?.index.boards.count == 4
        }
        return (vm, window, design, screen, host)
    }

    /// The pixel at (x, y) of an image.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func near(_ color: (Int, Int, Int), _ expected: (Int, Int, Int)) -> Bool {
        abs(color.0 - expected.0) <= 12 && abs(color.1 - expected.1) <= 12 && abs(color.2 - expected.2) <= 12
    }

    private func color(_ host: DesignHost, _ board: DesignPath, x: Int = 10, y: Int = 10) -> (Int, Int, Int)? {
        host.image(board).map { pixel($0, x, y) }
    }

    @Test func aPieceEditedOnceRedrawsEveryBoardThatImportsItAndNoOther() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (_, window, design, screen, host) = try await openCanvas(app)
        defer { window.close() }
        try await eventuallyOnMain("the importers' snapshots to show the piece's red") {
            window.layout()
            return [Self.home, Self.menu].allSatisfy { color(host, $0).map { near($0, (255, 0, 0)) } == true }
        }
        screen.select(Self.home.rawValue)
        try await eventuallyOnMain("Home to go live") { host.liveView(Self.home) != nil }
        let liveBefore = try #require(host.liveView(Self.home))
        let plainToken = host.tokens[Self.plain]
        let snapshots = host.snapshotsTaken

        // The one edit, to the piece: its own file is the only file that changes.
        let edited = try await app.server.editDesignBoard(design.id, path: Self.cardPath, edits: [DesignBoardEdit(find: "#ff0000", replace: "#00ff00")])
        #expect(edited.result.changed)

        try await eventuallyOnMain("both importers to redraw green", timeout: .seconds(30)) {
            window.layout()
            return [Self.home, Self.menu].allSatisfy { color(host, $0).map { near($0, (0, 255, 0)) } == true }
        }
        #expect(color(host, Self.cardPath).map { near($0, (0, 255, 0)) } == true, "the piece itself")
        #expect(host.tokens[Self.plain] == plainToken, "a board that imports nothing is not redrawn")
        #expect(host.snapshotsTaken > snapshots)

        // Home's live view was loaded again (a live reload keeps what it imported), and shows green.
        try await eventuallyOnMain("Home's live view to be the fresh one") { host.liveView(Self.home).map { $0 !== liveBefore } == true }
        let live = try #require(host.liveView(Self.home))
        let image = try await live.snapshot()
        #expect(near(pixel(image, 10, 10), (0, 255, 0)))
    }

    @Test func aPieceSaysHowManyBoardsUseItAndAUseOffersGoToSourceNotTweak() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (_, window, design, screen, host) = try await openCanvas(app)
        defer { window.close() }
        await screen.refresh()
        #expect(screen.usage.usedIn(Self.cardPath) == 2)
        let boards = screen.boards
        #expect(boards.first { $0.id == "Card.dc.html" }?.usage == "used in 2 boards")
        #expect(boards.filter { $0.usage != nil }.map(\.id) == ["Card.dc.html"], "only the piece says it")

        // A click on the import's drawing names the import: one use of Card.
        screen.select(Self.home.rawValue)
        try await eventuallyOnMain("Home to go live") { host.liveView(Self.home) != nil }
        let pick = try #require(await host.hitTest(Self.home, at: CGPoint(x: 10, y: 10)))
        #expect(pick.piece == "Card" && pick.tag == "component · Card")
        screen.setSelection([.init(board: Self.home, element: pick)])
        #expect(screen.pieceBoard(for: pick) == Self.cardPath)
        let note = try #require(screen.pieceNote)
        #expect(note.boards == "2 boards" && note.goToSource != nil)

        // The Tweak tab says so and offers no style on the instance; nothing is written.
        let tweak = try #require(screen.tweak)
        await tweak.select(screen.tweakTarget)
        #expect(tweak.presentation.instanceOf == "Card")
        #expect(!tweak.presentation.groups.contains { group in group.rows.contains { if case .style = $0.id { true } else { false } } },
                "no style control on a use: the piece draws it")
        #expect(tweak.presentation.problem == nil && !tweak.presentation.canReset)
        #expect(tweak.writes == 0)

        // Right-click offers Go to Source; it brings the piece's board into view, picked whole.
        let items = screen.menuItems(designName: "Pieces", keys: KeybindingsStore(store: ScratchDefaults()))
        let go = try #require(items.first { $0.id == "go-to-source" })
        go.action()
        #expect(screen.selectedWhole == [Self.cardPath] && screen.selectedElements.isEmpty)
        let center = screen.viewport.canvas(CGPoint(x: screen.canvasSize.width / 2, y: screen.canvasSize.height / 2))
        #expect(abs(center.x - 100) < 1 && abs(center.y - 430) < 1, "the piece's frame is in the middle of the view")
        _ = design
    }

    @Test func anElementThatIsNoUseOfAPieceKeepsItsTweakControlsAndOffersNoGoToSource() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (_, window, _, screen, host) = try await openCanvas(app)
        defer { window.close() }
        screen.select(Self.plain.rawValue)
        try await eventuallyOnMain("Plain to go live") { host.liveView(Self.plain) != nil }
        let pick = try #require(await host.hitTest(Self.plain, at: CGPoint(x: 50, y: 50)))
        #expect(pick.piece == nil)
        screen.setSelection([.init(board: Self.plain, element: pick)])
        #expect(screen.pieceNote == nil)
        let tweak = try #require(screen.tweak)
        await tweak.select(screen.tweakTarget)
        #expect(tweak.presentation.instanceOf == nil && !tweak.presentation.groups.isEmpty)
        let items = screen.menuItems(designName: "Pieces", keys: KeybindingsStore(store: ScratchDefaults()))
        #expect(!items.contains { $0.id == "go-to-source" })
    }
}
