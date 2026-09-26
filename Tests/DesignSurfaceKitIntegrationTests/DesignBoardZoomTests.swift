import CoreGraphics
import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import WebKit
#if canImport(AppKit)
import AppKit
#endif
@testable import DesignSurfaceKit

/// A board lays out at its own size at every zoom the canvas reaches: zoom only scales what it
/// draws. WebKit's page zoom alone did not: below about 0.56 its minimum font size swelled 16px
/// text until short labels wrapped, and at fractional zooms the layout viewport lost a pixel.
@MainActor
@Suite(.mainActorExclusive)
struct DesignBoardZoomTests {
    static let size = CGSize(width: 1280, height: 800)
    nonisolated static let zooms: [CGFloat] = [0.1, 0.17, 0.5, 1, 1.37, 2, 4]

    /// Short labels that barely fit, as the boards the user saw wrap had: a list title, a small
    /// caps date, and a paragraph that runs to a few lines.
    static let board = """
        <!doctype html>
        <html><head><meta charset="utf-8"><script src="./support.js"></script>
        <style>body { margin: 0; font-family: -apple-system, sans-serif; }</style></head>
        <body><x-dc>
        <div id="frame" style="position: fixed; left: 0; top: 0; right: 0; bottom: 0;"></div>
        <div id="list" style="position: absolute; left: 40px; top: 40px; width: 96px; font-size: 16px; line-height: 20px;">Little list</div>
        <div id="day" style="position: absolute; left: 40px; top: 100px; width: 150px; font-size: 12px; line-height: 16px; font-weight: 600; letter-spacing: 0.06em;">MONDAY, MAY 18</div>
        <p id="para" style="position: absolute; left: 40px; top: 160px; width: 320px; margin: 0; font-size: 16px; line-height: 22px;">A board lays out at its own size whatever the zoom, so its text wraps where the design says it does and nowhere else.</p>
        </x-dc></body></html>
        """

    struct Layout: Equatable, CustomStringConvertible {
        var viewport: [Double]
        /// Each element's rect in CSS pixels, rounded to a quarter pixel.
        var rects: [String: [Double]]
        var fontSizes: [String]

        var description: String { "viewport \(viewport) rects \(rects.sorted { $0.key < $1.key }) fonts \(fontSizes)" }
    }

    func layout(_ harness: BoardHarness, _ view: DesignBoardView) async throws -> Layout {
        let value = try #require(try await harness.page(view, """
            const q = (v) => Math.round(v * 4) / 4;
            const rect = (id) => { const r = document.getElementById(id).getBoundingClientRect(); return [q(r.x), q(r.y), q(r.width), q(r.height)]; };
            const d = document.documentElement;
            return {
              viewport: [innerWidth, innerHeight, d.clientWidth, d.clientHeight],
              rects: { frame: rect('frame'), list: rect('list'), day: rect('day'), para: rect('para') },
              fontSizes: ['list', 'day', 'para'].map(id => getComputedStyle(document.getElementById(id)).fontSize),
            };
            """) as? [String: Any])
        let viewport = try #require(value["viewport"] as? [NSNumber]).map(\.doubleValue)
        let rects = try #require(value["rects"] as? [String: [NSNumber]]).mapValues { $0.map(\.doubleValue) }
        return Layout(viewport: viewport, rects: rects, fontSizes: try #require(value["fontSizes"] as? [String]))
    }

    /// The layout once it matches `expected`, or what it still is after a few seconds: a new
    /// page zoom reaches the web content process a moment after the view takes it.
    func settledLayout(_ harness: BoardHarness, _ view: DesignBoardView, expected: Layout) async throws -> Layout {
        // `eventually`, polling the page from the main actor.
        let deadline = ContinuousClock.now + .seconds(5)
        var last = try await layout(harness, view)
        while last != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            last = try await layout(harness, view)
        }
        return last
    }

    @Test(arguments: zooms)
    func aBoardLoadedAtAZoomLaysOutAtItsOwnSize(_ zoom: CGFloat) async throws {
        let harness = try BoardHarness(files: ["Zoom.dc.html": Self.board])
        let atOne = try harness.view("Zoom.dc.html", size: Self.size)
        try await atOne.load()
        let expected = try await layout(harness, atOne)
        #expect(expected.viewport == [1280, 800, 1280, 800])
        #expect(expected.rects["frame"] == [0, 0, 1280, 800])
        #expect(expected.rects["list"]?[3] == 20, "Little list fits on one line: \(expected)")
        #expect(expected.rects["day"]?[3] == 16, "the date fits on one line: \(expected)")
        #expect(expected.fontSizes == ["16px", "12px", "16px"])

        let view = try harness.view("Zoom.dc.html", size: Self.size)
        view.zoom = zoom
        #expect(view.frame.size == CGSize(width: 1280 * zoom, height: 800 * zoom))
        #expect(view.renderScale == DesignBoardView.renderScale(for: zoom))
        let drawn = try await view.load()
        #expect(drawn == Self.size)
        #expect(try await layout(harness, view) == expected)
    }

    /// The canvas's path: one view, loaded once, zoomed out and in. Every step lays the page out
    /// exactly as at 100%, the page is never loaded again, the page zoom changes only as it
    /// crosses a render scale, and the bridge reports elements in the board's own pixels.
    @Test func zoomingALiveBoardNeverChangesItsLayout() async throws {
        let harness = try BoardHarness(files: ["Zoom.dc.html": Self.board])
        let view = try harness.view("Zoom.dc.html", size: Self.size)
        #if canImport(AppKit)
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        parent.addSubview(view)
        #endif
        try await view.load()
        let expected = try await layout(harness, view)
        let list = try #require(expected.rects["list"])
        let point = CGPoint(x: list[0] + 10, y: list[1] + 10)
        let hit = try #require(await view.hitTest(at: point))

        var scale = view.renderScale
        var crossings = 0
        for zoom in Self.zooms + Self.zooms.reversed() {
            view.zoom = zoom
            if DesignBoardView.renderScale(for: zoom) != scale {
                scale = DesignBoardView.renderScale(for: zoom)
                crossings += 1
            }
            #expect(view.frame.size == CGSize(width: 1280 * zoom, height: 800 * zoom))
            #expect(view.webView.pageZoom == scale)
            #expect(view.webView.frame.size == CGSize(width: 1280 * scale, height: 800 * scale))
            let now = try await settledLayout(harness, view, expected: expected)
            #expect(now == expected, "at \(zoom)")
            #expect(await view.hitTest(at: point) == hit, "at \(zoom)")
            #if canImport(AppKit)
            // Clicks reach the page through the same scale: the view's frame is the whole page.
            let page = view.webView.convert(view.frame, from: parent)
            #expect(abs(page.minX) < 0.01 && abs(page.minY) < 0.01, "at \(zoom): \(page)")
            #expect(abs(page.width - 1280 * scale) < 0.01 && abs(page.height - 800 * scale) < 0.01, "at \(zoom): \(page)")
            #endif
        }
        #expect(view.navigationsStarted == 1, "zooming never reloads the page")
        #expect(view.renderScaleChanges == crossings)
        #expect(harness.problems.isEmpty)
    }

    /// A snapshot is the whole board at its own size at every zoom.
    @Test(arguments: [0.17, 1, 2] as [CGFloat])
    func aSnapshotCoversTheBoardAtAnyZoom(_ zoom: CGFloat) async throws {
        let harness = try BoardHarness(files: ["Zoom.dc.html": Self.board])
        let view = try harness.view("Zoom.dc.html", size: Self.size)
        view.zoom = zoom
        try await view.load()
        let image = try await view.snapshot()
        let scale = image.width / 1280
        #expect(scale >= 1)
        #expect(image.width == 1280 * scale && image.height == 800 * scale)
    }
}
