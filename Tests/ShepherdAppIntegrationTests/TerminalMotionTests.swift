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
        // A mounting surface can report a transient grid before its full-width one: wait until
        // its reports have been quiet for a while.
        var seen = 0
        var quietSince = ContinuousClock.now
        try await eventuallyOnMain("the surface to settle on its first grid", timeout: .seconds(30)) {
            if grids.count != seen { seen = grids.count; quietSince = .now }
            return !grids.isEmpty && ContinuousClock.now - quietSince > .milliseconds(500)
        }
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

/// The same rule in the real shell: a shell pane split beside an agent's thread, in `RootView`,
/// while the docked sidebar slides away and back and the right pane slides in beside the
/// agent's whole layout.
@Suite("Terminal motion in the shell", .serialized, .mainActorExclusive)
@MainActor
struct ShellTerminalMotionTests {
    /// Every grid the shell's surface reports.
    @MainActor
    final class GridLog {
        var grids: [String] = []
    }

    /// The right pane docks beside the whole layout, measured against the main column (1207pt
    /// here, so it docks), not inside the thread's half (603pt, where it would overlay the
    /// thread): the shell narrows with the layout, once.
    @Test func aShellPaneBesideTheThreadResizesOncePerSidebarSlideAndOnceForTheRightPane() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent("agent", in: space, auxiliary: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        vm.reviewDiffLoader = { _, reference in ([], reference) }
        vm.selectAgent(agent.agent.id)
        let shell = vm.sessions.session(for: agent.auxiliary[0], in: agent.tab)
        let log = GridLog()
        let forward = shell.terminal.onResize
        shell.terminal.onResize = { cols, rows in
            log.grids.append("\(cols)x\(rows)")
            forward?(cols, rows)
        }
        let size = CGSize(width: 1440, height: 600)
        let window = OffscreenWindow(size: size, dark: false, RootView(vm: vm))
        defer { window.close() }
        let store = vm.threadStores.store(for: agent.agent.id)
        try await eventuallyOnMain("the thread to load", timeout: .seconds(20)) { store.ready }
        try await eventuallyOnMain("the shell to go live", timeout: .seconds(30)) { shell.phase == .live }
        try await quiet(log)
        // Through the sidebar's first section header and the workspace beside it.
        let row = CGRect(x: 0, y: 62, width: size.width, height: 1)

        for hidden in [true, false] {
            let before = log.grids.count
            let recording = await MotionProbe.record(window, region: row) { vm.toggleSidebar() }
            try await quiet(log)
            #expect(vm.sidebarHidden == hidden)
            #expect(log.grids.count - before == 1, "one PTY resize per slide (hidden: \(hidden)): \(log.grids[before...])")
            if !hidden { #expect(!recording.inBetween.isEmpty, "the sidebar slides in") }
        }

        let before = log.grids.count
        let opening = await MotionProbe.record(window, region: row) { vm.toggleReviewPane() }
        try await quiet(log)
        #expect(vm.isReviewPaneShowing)
        #expect(!opening.inBetween.isEmpty, "the review slides in")
        #expect(log.grids.count - before == 1, "one PTY resize as the docked pane opens: \(log.grids[before...])")
    }

    /// Waits until the surface's grid reports have been quiet for a while.
    private func quiet(_ log: GridLog) async throws {
        var seen = log.grids.count
        var since = ContinuousClock.now
        try await eventuallyOnMain("the shell's grid reports to go quiet", timeout: .seconds(30)) {
            if log.grids.count != seen { seen = log.grids.count; since = .now }
            return ContinuousClock.now - since > .milliseconds(600)
        }
    }
}
