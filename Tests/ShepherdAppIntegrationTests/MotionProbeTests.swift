import AppKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing

/// The motion probe on a stand-in pane: a 100pt dark pane opening at the trailing edge of a
/// light 300pt container, wired the way a right pane should be (`nwAnimation` on the container,
/// `nwTransition` on the pane). Pixels are read from an off-screen window.
@Suite("Motion probe", .mainActorExclusive)
@MainActor
struct MotionProbeTests {
    @MainActor @Observable
    final class PaneModel {
        var open = false
    }

    private struct SamplePane: View {
        let model: PaneModel
        var instant = false

        var body: some View {
            ZStack(alignment: .trailing) {
                Color.white
                if model.open {
                    Color.black
                        .frame(width: SamplePane.paneWidth)
                        .nwTransition(.pane)
                }
            }
            .frame(width: SamplePane.width, height: SamplePane.height)
            .modifier(Instant(on: instant))
            .nwAnimation(.pane, value: model.open)
        }

        static let width: CGFloat = 300
        static let height: CGFloat = 40
        static let paneWidth: CGFloat = 100
        /// Where the open pane's leading edge rests.
        static let restingEdge = Int(width - paneWidth)
    }

    private struct Instant: ViewModifier {
        let on: Bool

        func body(content: Content) -> some View {
            if on { content.nwInstant() } else { content }
        }
    }

    /// A strip across the middle of the container: the pane's leading edge shows in it.
    private let strip = CGRect(x: 0, y: SamplePane.height / 2, width: SamplePane.width, height: 1)

    private func window(_ model: PaneModel, reduceMotion: Bool = false, instant: Bool = false) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: SamplePane.width, height: SamplePane.height), dark: false,
                        SamplePane(model: model, instant: instant).environment(\._accessibilityReduceMotion, reduceMotion))
    }

    @Test func aPaneSlidesInFromItsEdge() async {
        let model = PaneModel()
        let window = window(model)
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: strip) { model.open = true }

        #expect(recording.settled.firstColumn(differingFrom: recording.before) == SamplePane.restingEdge)
        let edges = recording.inBetween.compactMap { $0.firstColumn(differingFrom: recording.before) }
        #expect(edges.contains { $0 > SamplePane.restingEdge + 4 }, "caught mid-slide: \(edges) in \(recording.frames.count) frames")
        #expect(edges.allSatisfy { $0 >= SamplePane.restingEdge }, "never past its resting place: \(edges)")
        #expect(edges == edges.sorted(by: >), "the edge only moves toward rest: \(edges)")
        // A slide, not a fade: the part of the pane in view is already opaque.
        for frame in recording.inBetween {
            if let edge = frame.firstColumn(differingFrom: recording.before), edge + 2 < Int(SamplePane.width) {
                #expect(frame.lightness(x: edge + 2) < 0.05)
            }
        }
    }

    @Test func underReduceMotionAPaneOnlyFades() async {
        let model = PaneModel()
        let window = window(model, reduceMotion: true)
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: strip) { model.open = true }

        #expect(recording.settled.firstColumn(differingFrom: recording.before) == SamplePane.restingEdge)
        let edges = recording.inBetween.compactMap { $0.firstColumn(differingFrom: recording.before) }
        #expect(!edges.isEmpty, "caught mid-fade in \(recording.frames.count) frames")
        #expect(edges.allSatisfy { $0 == SamplePane.restingEdge }, "the pane never moves: \(edges)")
        #expect(recording.inBetween.contains { (0.05..<0.95).contains($0.lightness(x: SamplePane.restingEdge + 10)) },
                "the pane fades in")
    }

    /// `nwInstant()` is how terminal surfaces and streaming text opt out of any motion.
    @Test func anInstantSubtreeNeverAnimates() async {
        let model = PaneModel()
        let window = window(model, instant: true)
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: strip) { model.open = true }

        #expect(recording.settled.firstColumn(differingFrom: recording.before) == SamplePane.restingEdge)
        #expect(recording.inBetween.isEmpty)
    }

    /// `nwInstant()` drops the animation a change arrives with, not motion attached inside it:
    /// a pane with its own `nwAnimation` still slides under an instant ancestor.
    @Test func anInstantAncestorKeepsTheMotionAttachedInsideIt() async {
        let model = PaneModel()
        let window = OffscreenWindow(size: CGSize(width: SamplePane.width, height: SamplePane.height), dark: false,
                                     SamplePane(model: model).nwInstant())
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: strip) { model.open = true }

        let edges = recording.inBetween.compactMap { $0.firstColumn(differingFrom: recording.before) }
        #expect(edges.contains { $0 > SamplePane.restingEdge + 4 }, "caught mid-slide: \(edges)")
    }

    /// SwiftUI resizes a hosted NSView on every frame of an animated layout change; for a
    /// Ghostty surface each is a PTY resize. Under `nwInstant()` the view takes its final size
    /// once while the pane beside it still slides.
    @Test func anInstantHostedViewResizesOnceWhileItsNeighborSlides() async {
        for instant in [false, true] {
            let model = PaneModel()
            let surface = SizeLoggingView()
            let window = OffscreenWindow(size: CGSize(width: SamplePane.width, height: SamplePane.height), dark: false,
                                         PaneBesideHostedView(model: model, surface: surface, instant: instant))
            defer { window.close() }
            let recording = await MotionProbe.record(window, region: strip) {
                surface.widths.removeAll()
                model.open = true
            }

            #expect(!recording.inBetween.isEmpty, "the pane slides (instant: \(instant))")
            let resting = SamplePane.width - SamplePane.paneWidth
            if instant {
                #expect(!surface.widths.isEmpty && surface.widths.allSatisfy { $0 == resting }, "\(surface.widths)")
            } else {
                // Without it, the same view is resized frame by frame: the check above is not vacuous.
                #expect(Set(surface.widths).count > 3, "\(surface.widths)")
            }
        }
    }

    /// A pane sliding in from the leading edge beside a hosted view, which the pane narrows.
    private struct PaneBesideHostedView: View {
        let model: PaneModel
        let surface: SizeLoggingView
        let instant: Bool

        var body: some View {
            HStack(spacing: 0) {
                if model.open {
                    Color.black.frame(width: SamplePane.paneWidth).nwTransition(.pane, edge: .leading)
                }
                HostedView(view: surface).modifier(Instant(on: instant))
            }
            .frame(width: SamplePane.width, height: SamplePane.height)
            .nwAnimation(.pane, value: model.open)
        }
    }

    private struct HostedView: NSViewRepresentable {
        let view: SizeLoggingView

        func makeNSView(context: Context) -> SizeLoggingView { view }
        func updateNSView(_ nsView: SizeLoggingView, context: Context) {}
    }
}

/// A hosted view that records every width it is given, standing in for a terminal surface.
private final class SizeLoggingView: NSView {
    var widths: [CGFloat] = []

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        widths.append(newSize.width)
    }
}
