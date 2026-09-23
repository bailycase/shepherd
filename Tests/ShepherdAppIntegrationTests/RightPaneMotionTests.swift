import AppKit
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The right pane (review, subagent inspector) opening and closing, recorded from an off-screen
/// window: it slides from the trailing edge, docked or overlaid; the thread beside a docked
/// pane takes its new width once; under Reduce Motion it only fades; its content cross-fades
/// when the review and the inspector swap. The last test drives the real workspace through the
/// view model, the path ⇧⌘B, the toolbar, and an agent's `review_diff` share.
@Suite("Right pane motion", .mainActorExclusive)
@MainActor
struct RightPaneMotionTests {
    @MainActor @Observable
    final class Model {
        var open = false
        var showing: RightPaneShowing? = .inspector(runID: "a")
    }

    /// White thread, black pane; the thread's width is logged by a hosted view.
    private struct Split: View {
        let model: Model
        let thread: WidthLog
        let panes = RightPaneState()

        var body: some View {
            RightPaneSplit(state: panes, showPane: model.open) {
                Color.white.background(Hosted(view: thread))
            } pane: {
                RightPaneSlot(showing: model.showing) {
                    if case .inspector = model.showing {
                        Color.black.nwTransition(.content)
                    } else {
                        Color.nw.running.nwTransition(.content)
                    }
                }
            }
            // The leaf's background, which shows beside a thread that has already narrowed.
            .background(Color.white)
        }
    }

    private static let height: CGFloat = 60

    private func window(_ model: Model, width: CGFloat, thread: WidthLog = WidthLog(), reduceMotion: Bool = false) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: width, height: Self.height), dark: false,
                        Split(model: model, thread: thread).environment(\._accessibilityReduceMotion, reduceMotion))
    }

    private func strip(_ width: CGFloat) -> CGRect { CGRect(x: 0, y: Self.height / 2, width: width, height: 1) }

    /// Where the open pane's leading edge (its 1pt handle) rests in a column `width` wide.
    private func restingEdge(_ width: CGFloat) -> Int {
        let layout = ShellLayout.rightPane(containerWidth: width, preferredWidth: nil)
        return Int(width - layout.width - AppLayout.dividerWidth)
    }

    @Test(arguments: [CGFloat(1200), CGFloat(820)])
    func thePaneSlidesInFromTheTrailingEdgeDockedOrOverlaid(width: CGFloat) async throws {
        let model = Model()
        let window = window(model, width: width)
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: strip(width)) { model.open = true }

        // Its 1pt handle rests at `restingEdge`; an overlaid pane's shadow reaches a little further.
        let resting = try #require(recording.settled.firstColumn(differingFrom: recording.before))
        #expect((restingEdge(width) - 40...restingEdge(width)).contains(resting), "\(resting)")
        let edges = recording.inBetween.compactMap { $0.firstColumn(differingFrom: recording.before) }
        #expect(edges.contains { $0 > resting + 20 }, "caught mid-slide: \(edges)")
        #expect(edges.allSatisfy { $0 >= resting }, "never past its resting place: \(edges)")
        #expect(edges == edges.sorted(by: >), "the edge only moves toward rest: \(edges)")
    }

    /// Beside a docked pane the thread narrows once, as the slide starts, instead of being
    /// relaid out on every frame; an overlaid pane never resizes it.
    @Test(arguments: [CGFloat(1200), CGFloat(820)])
    func theThreadTakesItsNewWidthOnceWhileThePaneSlides(width: CGFloat) async {
        let model = Model()
        let thread = WidthLog()
        let window = window(model, width: width, thread: thread)
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: strip(width)) {
            thread.widths.removeAll()
            model.open = true
        }

        #expect(!recording.inBetween.isEmpty, "the pane slides")
        let layout = ShellLayout.rightPane(containerWidth: width, preferredWidth: nil)
        if layout.mode == .docked {
            #expect(thread.widths == [layout.contentWidth], "\(thread.widths)")
        } else {
            #expect(thread.widths.isEmpty, "\(thread.widths)")
        }
    }

    /// Closing gives the thread its width back at once, under the pane as it leaves. (The slide
    /// out itself is the same transition, reversed; an off-screen window completes removal
    /// transitions at once, so the probe cannot watch it.)
    @Test func closingGivesTheThreadItsWidthBackAtOnce() async {
        let model = Model()
        model.open = true
        let thread = WidthLog()
        let width: CGFloat = 1200
        let window = window(model, width: width, thread: thread)
        defer { window.close() }
        _ = await MotionProbe.record(window, region: strip(width)) {
            thread.widths.removeAll()
            model.open = false
        }

        #expect(thread.widths == [width], "\(thread.widths)")
    }

    @Test func underReduceMotionThePaneFadesInPlace() async {
        let model = Model()
        let width: CGFloat = 1200
        let window = window(model, width: width, reduceMotion: true)
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: strip(width)) { model.open = true }

        let resting = restingEdge(width)
        let edges = recording.inBetween.compactMap { $0.firstColumn(differingFrom: recording.before) }
        #expect(!edges.isEmpty, "caught mid-fade in \(recording.frames.count) frames")
        // The faint 1pt handle can round away in the first frames; the pane itself never moves.
        #expect(edges.allSatisfy { abs($0 - resting) <= 1 }, "the pane never moves: \(edges)")
        #expect(recording.inBetween.contains { (0.05..<0.95).contains($0.lightness(x: resting + 40)) }, "it fades in")
    }

    /// The review replacing the inspector (or another run, or a new review) cross-fades in the
    /// open pane; the pane stays where it is.
    @Test func swappingThePanesContentCrossFadesWithoutMovingThePane() async {
        let model = Model()
        model.open = true
        let width: CGFloat = 1200
        let window = window(model, width: width)
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: strip(width)) { model.showing = .review(UUID()) }

        let resting = restingEdge(width)
        let inside = resting + 40
        #expect(!recording.inBetween.isEmpty, "the content cross-fades")
        let before = recording.before.lightness(x: inside), after = recording.settled.lightness(x: inside)
        #expect(recording.inBetween.contains { frame in
            let value = frame.lightness(x: inside)
            return value > min(before, after) + 0.02 && value < max(before, after) - 0.02
        }, "caught between the two contents")
        for frame in recording.frames {
            #expect(frame.lightness(x: resting - 2) > 0.95, "the thread beside it never changes")
        }
    }

    /// Through the view model, as ⇧⌘B does: the review slides in beside the live thread, and
    /// switching to another agent and back is a visibility flip, never a motion.
    @Test func theReviewSlidesInThroughTheViewModelAndSwitchingAgentsStaysInstant() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let first = try await app.liveAgent("first", in: space, order: 0)
        let second = try await app.liveAgent("second", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [first, second]))
        vm.reviewDiffLoader = { _, reference in ([], reference) }
        let size = CGSize(width: 1200, height: 600)
        let window = OffscreenWindow(size: size, dark: false, WorkspaceView(vm: vm).environment(\.threadCommands, vm.threadCommands))
        defer { window.close() }
        for agent in [second, first] {
            vm.selectAgent(agent.agent.id)
            let store = vm.threadStores.store(for: agent.agent.id)
            try await eventuallyOnMain("\(agent.agent.name)'s thread to load", timeout: .seconds(20)) { store.ready }
        }
        // A row through the pane's header, above the thread's content (which rewraps at once
        // when the thread narrows). Let the first thread's own arrival motion settle first.
        let row = CGRect(x: 0, y: 20, width: size.width, height: 1)
        _ = await MotionProbe.record(window, region: row, timeout: 1) {}

        let opening = await MotionProbe.record(window, region: row) { vm.toggleReviewPane() }
        let resting = restingEdge(size.width)
        let edges = opening.inBetween.compactMap { $0.firstColumn(differingFrom: opening.before) }
        #expect(vm.isReviewPaneShowing)
        #expect(edges.contains { $0 > resting + 20 }, "caught mid-slide: \(edges)")

        let switching = await MotionProbe.record(window, region: row) { vm.selectAgent(second.agent.id) }
        #expect(switching.inBetween.isEmpty, "switching agents is a visibility flip")
        let back = await MotionProbe.record(window, region: row) { vm.selectAgent(first.agent.id) }
        #expect(back.inBetween.isEmpty, "the open review comes back with its agent, without sliding")
    }
}

private struct Hosted: NSViewRepresentable {
    let view: WidthLog

    func makeNSView(context: Context) -> WidthLog { view }
    func updateNSView(_ nsView: WidthLog, context: Context) {}
}

/// A hosted view that records every width it is given, standing in for the thread's scroll view.
private final class WidthLog: NSView {
    var widths: [CGFloat] = []

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width != widths.last { widths.append(newSize.width) }
    }
}
