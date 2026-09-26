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

    // MARK: Labels and picks

    /// The skill's grid: desktop boards 80 apart in a row, a phone row 120 below.
    private static let grid: [String: CGRect] = [
        "A.dc.html": CGRect(x: 0, y: 0, width: 1280, height: 800),
        "B.dc.html": CGRect(x: 1360, y: 0, width: 1280, height: 800),
        "A-phone.dc.html": CGRect(x: 0, y: 920, width: 390, height: 844),
        "B-phone.dc.html": CGRect(x: 470, y: 920, width: 390, height: 844),
    ]

    @Test func aLabelsRoomIsTheGapToTheRowAboveAndTheNextBoardAlong() {
        let rooms = NWLabelRoom.rooms(Self.grid)
        #expect(rooms["A.dc.html"] == NWLabelRoom(above: nil, along: 1360))
        #expect(rooms["B.dc.html"] == NWLabelRoom(above: nil, along: nil))
        #expect(rooms["A-phone.dc.html"] == NWLabelRoom(above: 120, along: 470))
        #expect(rooms["B-phone.dc.html"] == NWLabelRoom(above: 120, along: nil))
    }

    /// The canvas opens near 17% on the skill's grid, where rows are 20pt apart: the second row's
    /// labels move down toward their boards instead of over the first row, and past a zoom where
    /// even that doesn't fit they aren't drawn.
    @Test(arguments: [
        (CGFloat(1), true, NWDesignMetrics.labelGap),
        (0.17, true, 120 * 0.17 - NWDesignMetrics.labelHeight),
        (0.14, false, NWDesignMetrics.labelGap),
    ])
    func aLabelNeverLiesOverTheRowAbove(zoom: CGFloat, shown: Bool, gap: CGFloat) {
        let room = NWLabelRoom.rooms(Self.grid)["A-phone.dc.html"]!
        let label = room.layout(width: 390 * zoom, zoom: zoom)
        #expect(label.shown == shown)
        #expect(abs(label.gap - gap) < 0.001)
        if label.shown {
            // The label's top stays below the row above's bottom.
            let rowAbove = 800 * zoom
            let labelTop = 920 * zoom - label.gap - NWDesignMetrics.labelHeight
            #expect(labelTop >= rowAbove)
        }
        #expect(NWLabelRoom.rooms(Self.grid)["A.dc.html"]!.layout(width: 1280 * zoom, zoom: zoom).shown, "nothing above the first row")
    }

    /// A phone's label runs past its narrow board at a low zoom, but stops short of the next one.
    @Test func aLabelStopsBeforeTheNextBoardAlong() {
        let room = NWLabelRoom.rooms(Self.grid)["A-phone.dc.html"]!
        let label = room.layout(width: 390 * 0.2, zoom: 0.2)
        #expect(label.width == 470 * 0.2 - NWDesignMetrics.labelSpacing)
        #expect(room.layout(width: 390, zoom: 1).width == 390)
    }

    @Test func aPickNamesTheBoardThePointOnItOrItsLabel() {
        let rooms = NWLabelRoom.rooms(Self.grid)
        let boards = Self.grid.keys.sorted().map { id in
            NWCanvasBoard(id: id, frame: Self.grid[id]!, title: id, size: "", labelRoom: rooms[id]!)
        }
        let viewport = NWCanvasViewport(offset: CGPoint(x: 44, y: 52), zoom: 0.5)
        let onA = boards.pick(at: CGPoint(x: 44 + 100, y: 52 + 60), viewport: viewport, extending: true)
        #expect(onA == NWCanvasPick(board: "A.dc.html", point: CGPoint(x: 200, y: 120), extending: true))
        let label = boards.pick(at: CGPoint(x: 44 + 10, y: 52 - 12), viewport: viewport)
        #expect(label == NWCanvasPick(board: "A.dc.html"), "a label picks its board whole")
        #expect(boards.pick(at: CGPoint(x: 44 + 660, y: 52 + 10), viewport: viewport) == NWCanvasPick())
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
