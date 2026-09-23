import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The toolbar's and workspace's motion, recorded from off-screen windows: the status pill
/// easing between states while its clock ticks without motion, the counters rolling, the
/// toolbar replaced at once when switching agents, and the empty workspace cross-fading.
@Suite("Shell motion", .mainActorExclusive)
@MainActor
struct ShellMotionTests {
    // MARK: Toolbar

    @MainActor @Observable
    final class Served {
        var snapshot = ShellMotionTests.snapshot(running: false)
    }

    static func snapshot(running: Bool) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: running ? 2 : 1, running: running,
                             supportedActions: ["send", "abort"], dialogsSupported: true, dialogs: [],
                             messages: [NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Go")],
                                                            truncated: false, timestamp: Date().timeIntervalSince1970 * 1000)],
                             provisional: [], clipped: false)
    }

    /// Idle → Running cross-fades the word and eases the tint; the running clock then ticks
    /// without motion.
    @Test func theStatusPillEasesBetweenStatesAndItsClockTicksWithoutMotion() async throws {
        let served = Served()
        let store = NativeThreadStore()
        let request: NativeThreadStore.Request = { value in
            if case .send(_, _, let operation, _, _, _) = value { return .accepted(operationID: operation) }
            return .snapshot(value: served.snapshot)
        }
        let size = CGSize(width: 240, height: 40)
        let window = OffscreenWindow(size: size, dark: false,
                                     ThreadStatusPill(store: store)
                                         .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                         .padding(.leading, 10)
                                         .background(Color.white)
                                         .task { await store.run(request: request) })
        defer { window.close() }
        try await eventuallyOnMain("the thread to load") { store.ready }
        let row = CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)
        _ = await MotionProbe.record(window, region: row, timeout: 0.5) {}

        let starting = await MotionProbe.record(window, region: row) {
            served.snapshot = Self.snapshot(running: true)
            Task { await store.refresh() }
        }
        #expect(threadPillState(store) == .running)
        #expect(!starting.inBetween.isEmpty, "the pill eases from Idle to Running")

        // Wait out the second the running clock shows, and catch it ticking over.
        let ticking = await MotionProbe.record(window, region: row, stillFrames: 12, timeout: 2.5) {}
        #expect(!ticking.settled.matches(ticking.before), "the clock ticked")
        #expect(ticking.inBetween.isEmpty, "a tick is not animated")
    }

    @MainActor @Observable
    final class Counters {
        var text: String? = "3 turns · 12k ctx"
    }

    /// The toolbar's counters roll as the thread reports them.
    @Test func theToolbarCountersRoll() async {
        let counters = Counters()
        let size = CGSize(width: 600, height: NWToolbarMetrics.height)
        let window = OffscreenWindow(size: size, dark: false, CountersToolbar(counters: counters))
        defer { window.close() }
        let row = CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)

        let recording = await MotionProbe.record(window, region: row) { counters.text = "4 turns · 18k ctx" }

        #expect(!recording.inBetween.isEmpty, "the digits roll")
    }

    private struct CountersToolbar: View {
        let counters: Counters

        var body: some View {
            NWThreadToolbar("Title", counters: counters.text, status: { EmptyView() }, options: { EmptyView() })
        }
    }

    /// Switching agents replaces the toolbar at once: one agent's status and counters never
    /// animate into another's.
    @Test func switchingAgentsReplacesTheToolbarAtOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let first = try await app.liveAgent("first agent", in: space, order: 0)
        let second = try await app.liveAgent("second", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [first, second]))
        let size = CGSize(width: 1280, height: 600)
        let window = OffscreenWindow(size: size, dark: false, RootView(vm: vm))
        defer { window.close() }
        for agent in [second, first] {
            vm.selectAgent(agent.agent.id)
            let store = vm.threadStores.store(for: agent.agent.id)
            try await eventuallyOnMain("\(agent.agent.name)'s thread to load", timeout: .seconds(20)) { store.ready }
        }
        let toolbar = CGRect(x: 0, y: NWToolbarMetrics.height / 2, width: size.width, height: 1)
        _ = await MotionProbe.record(window, region: toolbar, timeout: 0.5) {}

        let switching = await MotionProbe.record(window, region: toolbar) { vm.selectAgent(second.agent.id) }

        #expect(!switching.settled.matches(switching.before), "the toolbar changed")
        #expect(switching.inBetween.isEmpty, "the toolbar swaps at once")
    }

    // MARK: Workspace

    /// Switching agents is a visibility flip across the window: the sidebar's selection, the
    /// toolbar, and a review pane open beside one of them never ease between the two. The
    /// thread's own body is left out: a thread coming back on screen refreshes, and its "last
    /// known thread" notice clears a frame later, which is the thread's state, not motion.
    @Test func switchingAgentsChangesTheSidebarToolbarAndRightPaneAtOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let first = try await app.liveAgent("first agent", in: space, order: 0)
        let second = try await app.liveAgent("second", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [first, second]))
        vm.reviewDiffLoader = { _, reference in ([], reference) }
        let size = CGSize(width: 1280, height: 600)
        let window = OffscreenWindow(size: size, dark: false, RootView(vm: vm))
        defer { window.close() }
        for agent in [second, first] {
            vm.selectAgent(agent.agent.id)
            let store = vm.threadStores.store(for: agent.agent.id)
            try await eventuallyOnMain("\(agent.agent.name)'s thread to load", timeout: .seconds(20)) { store.ready }
        }
        vm.toggleReviewPane()
        #expect(vm.isReviewPaneShowing)
        _ = await MotionProbe.record(window, timeout: 1) {}

        let column = CGFloat(app.settings.sidebarWidth) + AppLayout.dividerWidth
        let pane = ShellLayout.rightPane(containerWidth: size.width - column, preferredWidth: nil)
        for agent in [second, first, second] {
            let threadEnd = agent.agent.id == first.agent.id ? size.width - pane.width - AppLayout.dividerWidth : size.width
            let thread = CGRect(x: column, y: NWToolbarMetrics.height, width: threadEnd - column, height: size.height - NWToolbarMetrics.height)
            let switching = await MotionProbe.record(window) { vm.selectAgent(agent.agent.id) }
            #expect(!switching.settled.matches(switching.before), "the window changed")
            let caught = switching.inBetween.filter { frame in
                differs(frame, from: switching.before, outside: thread) && differs(frame, from: switching.settled, outside: thread)
            }
            #expect(caught.isEmpty, "\(agent.agent.name) appears at once, but \(caught.count) frames were caught between")
        }
    }

    /// Whether any pixel outside `excluded` (in points, one pixel per point) differs.
    private func differs(_ frame: MotionRecording.Frame, from other: MotionRecording.Frame, outside excluded: CGRect) -> Bool {
        let a = frame.bitmap, b = other.bitmap
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow,
              let pa = a.bitmapData, let pb = b.bitmapData else { return true }
        let size = a.bitsPerPixel / 8
        for y in 0..<a.pixelsHigh {
            let row = y * a.bytesPerRow
            if !(Int(excluded.minY)..<Int(excluded.maxY)).contains(y) {
                if memcmp(pa + row, pb + row, a.pixelsWide * size) != 0 { return true }
                continue
            }
            let lead = max(0, min(a.pixelsWide, Int(excluded.minX))), trail = max(lead, min(a.pixelsWide, Int(excluded.maxX)))
            if memcmp(pa + row, pb + row, lead * size) != 0 { return true }
            if memcmp(pa + row + trail * size, pb + row + trail * size, (a.pixelsWide - trail) * size) != 0 { return true }
        }
        return false
    }

    /// Selecting another empty space cross-fades the empty state's words.
    @Test func theEmptyWorkspaceCrossFadesBetweenSpaces() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let one = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        let two = Fixture.space("two", path: app.dir.appendingPathComponent("two").path)
        let vm = try await app.start(with: ShepherdState(spaces: [one, two]))
        vm.selectSpace(one.id)
        let size = CGSize(width: 1280, height: 600)
        let window = OffscreenWindow(size: size, dark: false, RootView(vm: vm))
        defer { window.close() }
        // Down the middle of the workspace beside the sidebar, where the empty state's words sit.
        let column = AppLayout.sidebarDefaultWidth + AppLayout.dividerWidth
        let band = CGRect(x: column + (size.width - column) / 2 - 200, y: 0, width: 400, height: size.height)
        _ = await MotionProbe.record(window, region: band, timeout: 0.5) {}

        let recording = await MotionProbe.record(window, region: band) { vm.selectSpace(two.id) }

        #expect(!recording.settled.matches(recording.before), "the words changed")
        #expect(!recording.inBetween.isEmpty, "they cross-fade")
    }
}
