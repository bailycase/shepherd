import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

/// The design canvas's arithmetic: where a board lands on screen, which boards a view shows, the
/// board under a click, zooming about the pointer, and a canvas fitted to its boards.
@Suite("Design tool components")
struct DesignToolComponentTests {
    private static let boards = [
        NWCanvasBoard(id: "A.dc.html", frame: CGRect(x: 0, y: 0, width: 1280, height: 800), title: "A · Funnel first", size: "1280 × 800"),
        NWCanvasBoard(id: "B.dc.html", frame: CGRect(x: 1360, y: 0, width: 1280, height: 800), title: "B", size: "1280 × 800"),
        NWCanvasBoard(id: "A-phone.dc.html", frame: CGRect(x: 0, y: 920, width: 390, height: 844), title: "A · phone", size: "390 × 844"),
        // Over A: the front-most board wins a click.
        NWCanvasBoard(id: "Top.dc.html", frame: CGRect(x: 100, y: 100, width: 200, height: 200), title: "Top", size: "200 × 200"),
    ]

    @Test func canvasPointsAndScreenPointsRoundTrip() {
        let viewport = NWCanvasViewport(offset: CGPoint(x: 44, y: 52), zoom: 0.5)
        #expect(viewport.screen(CGPoint(x: 100, y: 200)) == CGPoint(x: 94, y: 152))
        #expect(viewport.canvas(CGPoint(x: 94, y: 152)) == CGPoint(x: 100, y: 200))
        #expect(viewport.screen(CGRect(x: 0, y: 0, width: 1280, height: 800)) == CGRect(x: 44, y: 52, width: 640, height: 400))
    }

    @Test(arguments: [(1.0, "100%"), (0.42, "42%"), (0.725, "73%"), (2, "200%")])
    func zoomReadsAsAPercentage(zoom: Double, text: String) {
        #expect(NWCanvasViewport(zoom: zoom).percent == text)
    }

    @Test func zoomingKeepsThePointUnderThePointerStill() {
        var viewport = NWCanvasViewport(offset: CGPoint(x: 10, y: 20), zoom: 0.5)
        let anchor = CGPoint(x: 300, y: 200)
        let before = viewport.canvas(anchor)
        viewport.zoom(by: 2, about: anchor)
        #expect(viewport.zoom == 1)
        #expect(viewport.canvas(anchor) == before)
    }

    @Test(arguments: [(CGFloat(100), CGFloat(4)), (0.0001, 0.05), (.infinity, 1)])
    func zoomStaysInItsRange(requested: CGFloat, expected: CGFloat) {
        #expect(NWCanvasViewport(zoom: requested).zoom == expected)
    }

    @Test func panningMovesTheOrigin() {
        var viewport = NWCanvasViewport(offset: .zero, zoom: 1)
        viewport.pan(by: CGSize(width: -30, height: 12))
        #expect(viewport.offset == CGPoint(x: -30, y: 12))
    }

    @Test func onlyBoardsOnScreenAreShown() {
        let size = CGSize(width: 800, height: 600)
        // At 100% from the origin only A (and the board over it) reach the view.
        #expect(Self.boards.visible(in: NWCanvasViewport(zoom: 1), size: size).map(\.id) == ["A.dc.html", "Top.dc.html"])
        // Zoomed out, all of them do.
        #expect(Self.boards.visible(in: NWCanvasViewport(zoom: 0.2), size: size).count == 4)
        // Panned right past A: B alone.
        let panned = NWCanvasViewport(offset: CGPoint(x: -1400, y: 0), zoom: 1)
        #expect(Self.boards.visible(in: panned, size: size).map(\.id) == ["B.dc.html"])
    }

    /// A board just below the view still shows while its label reaches in.
    @Test func aBoardWhoseLabelIsOnScreenIsShown() {
        let viewport = NWCanvasViewport(offset: CGPoint(x: 0, y: -780), zoom: 1)
        let size = CGSize(width: 400, height: 150)
        #expect(Self.boards.visible(in: viewport, size: size).map(\.id).contains("A-phone.dc.html"))
    }

    @Test func aClickPicksTheFrontMostBoardUnderIt() {
        let viewport = NWCanvasViewport(offset: .zero, zoom: 0.5)
        #expect(Self.boards.board(at: CGPoint(x: 100, y: 100), viewport: viewport)?.id == "Top.dc.html")
        #expect(Self.boards.board(at: CGPoint(x: 20, y: 20), viewport: viewport)?.id == "A.dc.html")
        #expect(Self.boards.board(at: CGPoint(x: 660, y: 10), viewport: viewport) == nil)
    }

    @Test func aFittedCanvasPutsTheBoardsTopLeadingCornerInItsInsetsAndNeverEnlarges() {
        let bounds = Self.boards.bounds
        #expect(bounds == CGRect(x: 0, y: 0, width: 2640, height: 1764))
        let fitted = NWCanvasViewport.fitting(bounds, in: CGSize(width: 1100, height: 800))
        #expect(fitted.screen(bounds.origin) == CGPoint(x: NWDesignMetrics.fitLeading, y: NWDesignMetrics.fitTop))
        #expect(fitted.zoom < 1)
        let screen = fitted.screen(bounds)
        #expect(screen.maxX <= 1100 - NWDesignMetrics.fitLeading + 0.001 && screen.maxY <= 800 - NWDesignMetrics.fitTop + 0.001)
        let small = NWCanvasViewport.fitting(CGRect(x: 10, y: 10, width: 200, height: 100), in: CGSize(width: 1100, height: 800))
        #expect(small.zoom == 1)
        // Nothing drawn yet: the origin at the insets, at 100%.
        #expect(NWCanvasViewport.fitting(.null, in: CGSize(width: 1100, height: 800)).zoom == 1)
    }

    @Test(arguments: [(CGSize(width: 1280, height: 800), NWDesignCardBoard.desktop),
                      (CGSize(width: 390, height: 844), .phone), (CGSize.zero, .none)])
    func aCardDrawsItsFirstBoardAsDesktopOrPhone(size: CGSize, board: NWDesignCardBoard) {
        #expect(NWDesignCardBoard(size: size) == board)
        #expect(NWDesignCardBoard(size: nil) == .none)
    }

    @Test func aBoardsSizeReadsInCSSPixels() {
        #expect(NWCanvasBoard.sizeLabel(CGSize(width: 1280, height: 800)) == "1280 × 800")
        #expect(NWCanvasBoard.sizeLabel(CGSize(width: 389.6, height: 844.2)) == "390 × 844")
    }
}
