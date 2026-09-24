import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The sidebar's motion, recorded from off-screen windows over a real server and view model:
/// sliding in docked (the main column snapping) and overlaid in a narrow window (only fading
/// under Reduce Motion), disclosing a space's rows, and easing a row's status dot. Selecting a
/// row lands at once. Removal transitions complete at once in an off-screen window, so these
/// watch what arrives.
@Suite("Sidebar motion", .mainActorExclusive)
@MainActor
struct SidebarMotionTests {
    /// ⇧⌘S with the sidebar hidden: it slides in from the leading edge while the main column
    /// takes its new frame at once (every mounted layout would otherwise reflow each frame).
    @Test func theDockedSidebarSlidesInWhileTheMainColumnSnaps() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.selectSpace(space.id)
        vm.sidebarHidden = true
        let size = CGSize(width: 1280, height: 600)
        let window = OffscreenWindow(size: size, dark: false, RootView(vm: vm))
        defer { window.close() }
        // Through the first section's header, under the window controls.
        let row = CGRect(x: 0, y: 62, width: size.width, height: 1)
        _ = await MotionProbe.record(window, region: row, timeout: 0.5) {}

        let recording = await MotionProbe.record(window, region: row) { vm.toggleSidebar() }

        let edge = Int(app.settings.sidebarWidth) + 1
        #expect(!recording.inBetween.isEmpty, "the sidebar slides in")
        let reach = recording.inBetween.compactMap { $0.lastColumn(differingFrom: recording.settled) }
        #expect(reach.allSatisfy { $0 < edge }, "the main column is already where it settles: \(reach)")
        let sidebarEdges = recording.inBetween.compactMap { $0.firstColumn(differingFrom: recording.settled) }
        #expect(!sidebarEdges.isEmpty, "caught mid-slide")
    }

    /// In a window too narrow to dock it, ⇧⌘S overlays the sidebar: it slides in over the
    /// workspace, or only fades under Reduce Motion.
    @Test(arguments: [false, true])
    func theOverlaidSidebarSlidesInUnlessReduceMotion(reduceMotion: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.selectSpace(space.id)
        let size = CGSize(width: AppLayout.windowMinWidth, height: 600)
        let window = OffscreenWindow(size: size, dark: false,
                                     RootView(vm: vm).environment(\._accessibilityReduceMotion, reduceMotion))
        defer { window.close() }
        try await eventuallyOnMain("the narrow window to hide the sidebar") { vm.sidebarAutoHidden }
        let row = CGRect(x: 0, y: 62, width: size.width, height: 1)
        _ = await MotionProbe.record(window, region: row, timeout: 0.5) {}

        let recording = await MotionProbe.record(window, region: row) { vm.toggleSidebar() }

        #expect(vm.sidebarOverlayShown)
        let spreads = recording.inBetween.compactMap { fadeSpread($0, before: recording.before, settled: recording.settled) }
        #expect(!spreads.isEmpty, "caught arriving in \(recording.frames.count) frames")
        if reduceMotion {
            #expect(spreads.allSatisfy { $0 < 0.35 }, "it fades in place, all of it together: \(spreads)")
        } else {
            #expect(spreads.contains { $0 > 0.6 }, "it slides, covering some columns before others: \(spreads)")
        }
    }

    /// How unevenly a frame sits between `before` and `settled` across the columns that change
    /// most: a cross-fade moves them all together (a small spread), a slide has covered some
    /// and not yet others.
    private func fadeSpread(_ frame: MotionRecording.Frame, before: MotionRecording.Frame, settled: MotionRecording.Frame) -> Double? {
        let columns = (0..<frame.bitmap.pixelsWide).filter { abs(settled.lightness(x: $0) - before.lightness(x: $0)) > 0.25 }
        guard columns.count >= 2 else { return nil }
        let progress = columns.map { x in
            (frame.lightness(x: x) - before.lightness(x: x)) / (settled.lightness(x: x) - before.lightness(x: x))
        }
        return (progress.max() ?? 0) - (progress.min() ?? 0)
    }

    /// Two spaces with three agents each.
    private func twoSpaces(_ app: AppHarness) async throws -> (ShepherdViewModel, Space, [AgentFixture]) {
        let one = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        let two = Fixture.space("two", path: app.dir.appendingPathComponent("two").path)
        let agents = (0..<3).map { Fixture.agent("one-\($0)", in: one, order: $0) }
            + (0..<3).map { Fixture.agent("two-\($0)", in: two, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [one, two], agents: agents))
        return (vm, one, agents)
    }

    private func sidebarWindow(_ vm: ShepherdViewModel) -> OffscreenWindow {
        OffscreenWindow(size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 500), dark: false, SidebarView(vm: vm))
    }

    /// A column down the sidebar through the rows' titles.
    private let titles = CGRect(x: 60, y: 0, width: 1, height: 500)

    /// Expanding a space discloses its agents and moves the rows below; selecting a row lands at
    /// once (⌘1–9, ⌘↑/↓, a click, the palette all go through `selectAgent`).
    @Test func expandingASpaceDisclosesItsRowsAndSelectionLandsAtOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, one, agents) = try await twoSpaces(app)
        vm.collapsedSpaces = [one.id]
        let window = sidebarWindow(vm)
        defer { window.close() }
        _ = await MotionProbe.record(window, region: titles, timeout: 0.5) {}

        let disclosing = await MotionProbe.record(window, region: titles) { vm.toggleSpaceCollapsed(one.id) }
        #expect(!disclosing.inBetween.isEmpty, "the rows disclose")

        // Let the disclosure's spring settle everywhere, not just in the titles' column.
        let full = CGRect(x: 0, y: 0, width: AppLayout.sidebarDefaultWidth, height: 500)
        _ = await MotionProbe.record(window, region: full, timeout: 0.6) {}
        let selecting = await MotionProbe.record(window, region: full) { vm.selectAgent(agents[4].agent.id) }
        #expect(selecting.frames.count > 2 && !selecting.settled.matches(selecting.before), "the selection shows")
        #expect(selecting.inBetween.isEmpty, "selection is not animated")
    }

    /// A status report eases the row's dot to its new state.
    @Test func aStatusReportEasesTheRowsDot() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, _, _) = try await twoSpaces(app)
        let window = sidebarWindow(vm)
        defer { window.close() }
        _ = await MotionProbe.record(window, region: titles, timeout: 0.5) {}
        // The dots' column, down the whole tree.
        let dots = CGRect(x: 0, y: 0, width: 40, height: 500)

        var state = app.server.state
        state.agents[1].status = .done
        let server = app.server, next = state
        let recording = await MotionProbe.record(window, region: dots) { Task { try? await server.putState(next) } }

        #expect(vm.state.agents[1].status == .done)
        #expect(!recording.inBetween.isEmpty, "the dot eases from hollow to done")
    }
}
