import AppKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The command palette's motion, recorded from an off-screen window: the card grows from its
/// top edge over a fading scrim (a plain fade under Reduce Motion), and its results list
/// animates when its rows change, the card following their height.
@Suite("Palette motion", .mainActorExclusive, .timingSensitive)
@MainActor
struct PaletteMotionTests {
    @MainActor @Observable
    final class Model {
        var open = false
        var items: [PaletteItem] = PaletteMotionTests.commands(2)
    }

    static func commands(_ count: Int) -> [PaletteItem] {
        (0..<count).map { PaletteItem(id: "c\($0)", kind: .action("c\($0)"), section: .commands, title: "Command \($0)") }
    }

    private static let size = CGSize(width: 600, height: 500)
    /// A column down the middle of the window, through the card.
    private static let column = CGRect(x: size.width / 2, y: 0, width: 1, height: size.height)
    private static let cardHeight: CGFloat = 200

    /// A black stand-in card, so its edges are easy to find.
    private struct Block: View {
        @Bindable var model: Model

        var body: some View {
            Color.white.nwCommandPalette(isPresented: $model.open) {
                Color.black.frame(height: PaletteMotionTests.cardHeight)
            }
        }
    }

    /// The card's top and bottom rows in a frame of `column`: the rows dark enough to be it.
    private func cardRows(_ frame: MotionRecording.Frame) -> ClosedRange<Int>? {
        let dark = (0..<Int(Self.size.height)).filter { frame.lightness(x: 0, y: $0) < 0.3 }
        guard let first = dark.first, let last = dark.last else { return nil }
        return first...last
    }

    @Test func thePaletteGrowsFromItsTopEdgeOverAFadingScrim() async throws {
        let model = Model()
        let window = OffscreenWindow(size: Self.size, dark: false, Block(model: model))
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: Self.column) { model.open = true }

        let top = Int(NWPaletteMetrics.placement(in: Self.size, rowHeight: NWDensity.standard.rowHeight).top)
        let settled = try #require(cardRows(recording.settled))
        #expect(abs(settled.lowerBound - top) <= 1 && abs(settled.upperBound - (top + Int(Self.cardHeight) - 1)) <= 1, "\(settled)")
        let growing = recording.inBetween.compactMap(cardRows)
        #expect(growing.contains { $0.upperBound < settled.upperBound - 2 }, "caught growing: \(growing)")
        #expect(growing.allSatisfy { abs($0.lowerBound - settled.lowerBound) <= 1 }, "anchored at its top edge: \(growing)")
        let scrim = recording.settled.lightness(x: 0, y: 10)
        #expect(scrim < 0.98, "the scrim settles over the window")
        #expect(recording.inBetween.contains { $0.lightness(x: 0, y: 10) > scrim + 0.01 && $0.lightness(x: 0, y: 10) < 0.995 },
                "the scrim fades in")
    }

    @Test func underReduceMotionThePaletteOnlyFades() async throws {
        let model = Model()
        let window = OffscreenWindow(size: Self.size, dark: false,
                                     Block(model: model).environment(\._accessibilityReduceMotion, true))
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: Self.column) { model.open = true }

        let settled = try #require(cardRows(recording.settled))
        let middle = (settled.lowerBound + settled.upperBound) / 2
        #expect(recording.inBetween.contains { (0.1..<0.9).contains($0.lightness(x: 0, y: middle)) }, "caught mid-fade")
        #expect(recording.inBetween.compactMap(cardRows).allSatisfy { abs($0.upperBound - settled.upperBound) <= 1 },
                "the card never grows")
    }

    /// Rows arriving (a new command, the query or scope changing) animate, and the card
    /// follows their height instead of jumping.
    @Test func theResultsListAnimatesWhenItsRowsChange() async throws {
        let model = Model()
        model.open = true
        let view = Color.white.nwCommandPalette(isPresented: .constant(true)) {
            PaletteCard(items: model.items, run: { _ in }, close: {})
        }
        let window = OffscreenWindow(size: Self.size, dark: false, view)
        defer { window.close() }
        // Let the card's own arrival settle.
        _ = await MotionProbe.record(window, region: Self.column, timeout: 1) {}

        let recording = await MotionProbe.record(window, region: Self.column) { model.items = Self.commands(6) }

        let bottom = try #require(recording.settled.lastRow(differingFrom: recording.before))
        let edges = recording.inBetween.compactMap { $0.lastRow(differingFrom: recording.before) }
        #expect(edges.contains { $0 < bottom - 4 }, "caught the card growing: \(edges), settles at \(bottom)")
    }
}
