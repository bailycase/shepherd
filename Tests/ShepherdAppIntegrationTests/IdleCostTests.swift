import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// What the app costs while nothing changes (DESIGN.md › Performance): motion no one sees draws no
/// frames. A spinner or a glow in a layout the workspace keeps mounted but hidden, or in a row a
/// lazy stack has let go of, is paused. Counted in frames the clock-driven motions draw
/// (`NWRenderProbe`), which a slow machine doesn't change.
@Suite("Idle cost", .mainActorExclusive)
@MainActor
struct IdleCostTests {
    static let clockKeys = ["ui.spinnerFrame", "ui.glowFrame", "ui.shimmerFrame"]

    /// Clock frames drawn over `seconds` of run loop.
    static func clockFrames(over seconds: Double = 1) async -> Int {
        NWRenderProbe.start()
        try? await Task.sleep(for: .seconds(seconds))
        let counts = NWRenderProbe.stop()
        return clockKeys.reduce(0) { $0 + counts[$1, default: 0] }
    }

    /// A thread that has loaded draws no spinner: "Starting pi…" is gone for good, not turning
    /// where no one sees it.
    @Test func aLoadedThreadDrawsNoSpinnerFrames() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2)))
        defer { thread.close() }
        try await thread.waitUntilReady()

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
    }

    /// The control: a thread whose pi is still starting shows its spinner, and it turns.
    @Test func aVisibleStartingThreadStillSpins() async throws {
        let thread = FakeThread(ThreadFixture.snapshot([]), starting: true)
        defer { thread.close() }
        let store = thread.store
        try await eventuallyOnMain("pi to be reported starting") { store.starting }
        ListPerf.settle(thread.window)

        let frames = await Self.clockFrames()

        #expect(frames > 0, "\(frames) clock frames")
    }

    /// Layouts the workspace keeps mounted behind the visible one draw no clock frames, though
    /// their threads (never shown, so never loaded) still hold their "Starting pi…" spinners.
    @Test func hiddenLayoutsDrawNoClockFrames() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<4 { agents.append(try await app.liveAgent("a\(index)", in: space, order: index)) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        let visible = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(30)) { visible.ready }
        ListPerf.settle(window)
        #expect(vm.mountedTabs.count == agents.count)

        let frames = await Self.clockFrames()

        #expect(frames == 0, "\(frames) clock frames")
    }

    /// A paused spinner resumes as its layout comes back on screen.
    @Test func aLayoutShownAgainResumesItsSpinner() async throws {
        let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2) + [ThreadFixture.user("u", "Go")],
                                                       provisional: [ThreadFixture.streaming("Working on it.")], running: true))
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.visibility.motionPaused = true
        ListPerf.settle(thread.window)
        #expect(await Self.clockFrames(over: 0.5) == 0, "paused while hidden")

        thread.visibility.motionPaused = false
        ListPerf.settle(thread.window)

        #expect(await Self.clockFrames() > 0)
    }
}

/// Main-thread CPU while idle, reported rather than asserted (it depends on the machine):
///
///     SHEPHERD_PERF_REPORT=1 swift test --filter IdleCostReport
@Suite("Idle cost report", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PERF_REPORT"] != nil))
@MainActor
struct IdleCostReport {
    private let report = PerfReport()

    /// A relaunch restores twelve agents: one on screen, eleven mounted behind it and never
    /// visited. Idle for four seconds.
    @Test func restoredWorkspaceIdle() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        var agents: [AgentFixture] = []
        for index in 0..<12 { agents.append(try await app.liveAgent("a\(index)", in: space, order: index)) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        vm.selectAgent(agents[0].agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        let visible = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready }
        ListPerf.settle(window)

        var cpu: [Double] = []
        var frames: [Int] = []
        for _ in 0..<3 {
            var counted = 0
            cpu.append(await MainThreadCPU.milliseconds {
                NWRenderProbe.start()
                try? await Task.sleep(for: .seconds(4))
                counted = NWRenderProbe.stop().filter { IdleCostTests.clockKeys.contains($0.key) }.values.reduce(0, +)
            })
            frames.append(counted)
        }
        report.add("restored workspace (12 agents, 1 visible)", "idle 4 s: clock frames", "\(frames)")
        report.add("restored workspace (12 agents, 1 visible)", "idle 4 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
    }

    /// One loaded thread of two messages, idle for two seconds.
    @Test func loadedThreadIdle() async throws {
        var cpu: [Double] = []
        var frames: [Int] = []
        for _ in 0..<3 {
            let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(2)))
            try await thread.waitUntilReady()
            var counted = 0
            cpu.append(await MainThreadCPU.milliseconds {
                NWRenderProbe.start()
                try? await Task.sleep(for: .seconds(2))
                counted = NWRenderProbe.stop().filter { IdleCostTests.clockKeys.contains($0.key) }.values.reduce(0, +)
            })
            frames.append(counted)
            thread.close()
        }
        report.add("loaded thread (2 messages)", "idle 2 s: clock frames", "\(frames)")
        report.add("loaded thread (2 messages)", "idle 2 s: main-thread CPU (median of 3)", ms: MainThreadCPU.median(cpu))
    }
}
