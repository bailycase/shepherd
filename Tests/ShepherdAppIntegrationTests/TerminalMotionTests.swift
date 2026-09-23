import AppKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp
import TerminalSurfaceKit

/// A real Ghostty surface beside a pane that slides in and narrows it, the way the docked
/// sidebar, a split, or a right pane move a terminal. Every grid the surface reports is a PTY
/// resize (SIGWINCH, and a remote smallest-viewer recompute), so it must take its final grid
/// once rather than one per cell the animated edge crosses.
@Suite("Terminal motion", .serialized, .mainActorExclusive)
@MainActor
struct TerminalMotionTests {
    @MainActor @Observable
    final class Model {
        var open = false
    }

    private struct PaneBesideTerminal<Terminal: View>: View {
        let model: Model
        @ViewBuilder let terminal: () -> Terminal

        var body: some View {
            HStack(spacing: 0) {
                if model.open {
                    Color.black.frame(width: Self.paneWidth).nwTransition(.pane, edge: .leading)
                }
                terminal()
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .nwAnimation(.pane, value: model.open)
        }

        static var size: CGSize { CGSize(width: 600, height: 200) }
        static var paneWidth: CGFloat { 160 }
    }

    /// The grids a surface reports while a pane slides in beside it, besides the full-width grid
    /// it had before (whose report can trail the mount under load).
    private func gridsWhileAPaneSlidesIn(_ terminal: AppTerminalModel, view: some View, model: Model) async throws -> (grids: [String], animated: Bool) {
        var grids: [String] = []
        terminal.onResize = { grids.append("\($0)x\($1)") }
        let window = OffscreenWindow(size: PaneBesideTerminal<EmptyView>.size, dark: false, view)
        defer { window.close() }
        try await eventuallyOnMain("the surface to report its first grid", timeout: .seconds(30)) { !grids.isEmpty }
        let initial = grids[grids.count - 1]
        let strip = CGRect(x: 0, y: PaneBesideTerminal<EmptyView>.size.height / 2, width: PaneBesideTerminal<EmptyView>.size.width, height: 1)
        let recording = await MotionProbe.record(window, region: strip) {
            grids.removeAll()
            model.open = true
        }
        // The last report can trail the picture by a runloop turn.
        try await eventuallyOnMain("the surface to report its narrower grid", timeout: .seconds(30)) { grids.contains { $0 != initial } }
        return (grids.filter { $0 != initial }, !recording.inBetween.isEmpty)
    }

    @Test func aTerminalTakesItsFinalGridOnceWhileAPaneSlidesInBesideIt() async throws {
        let model = Model()
        let terminal = AppTerminalModel(terminal: ShepherdTheme.nightWatchLight.terminal)
        let view = PaneBesideTerminal(model: model) { AppTerminalView(model: terminal, isFocused: false) }

        let (grids, animated) = try await gridsWhileAPaneSlidesIn(terminal, view: view, model: model)

        #expect(animated, "the pane slides")
        #expect(grids.count == 1, "one PTY resize, not one per column: \(grids)")
    }

    /// The control: the same surface without `AppTerminalView`'s `nwInstant()` is resized
    /// frame by frame, so the check above is not vacuous.
    @Test func withoutInstantTheSameSurfaceIsResizedFrameByFrame() async throws {
        let model = Model()
        let terminal = AppTerminalModel(terminal: ShepherdTheme.nightWatchLight.terminal)
        let view = PaneBesideTerminal(model: model) { TerminalSurfaceView(model: terminal.model, isFocused: false) }

        let (grids, animated) = try await gridsWhileAPaneSlidesIn(terminal, view: view, model: model)

        #expect(animated, "the pane slides")
        #expect(Set(grids).count > 3, "\(grids)")
    }
}
