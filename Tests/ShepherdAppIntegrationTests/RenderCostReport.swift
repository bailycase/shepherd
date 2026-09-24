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

/// What the thread and the workspace cost the main thread for the changes they take most often
/// (a streamed chunk, a poll, a switch, a status report), printed as `PERF | … | … | …`.
/// Timings depend on the machine, so this reports rather than asserts; the budgets that hold on
/// any machine are counts in `ListPerformanceTests` and `IdleCostTests`.
///
///     SHEPHERD_PERF_REPORT=1 swift test --filter RenderCostReport
@Suite("Render cost report", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PERF_REPORT"] != nil))
@MainActor
struct RenderCostReport {
    private let report = PerfReport()

    /// How long a thread just opened is left alone before measuring: what opening sets off
    /// (the composer reading the model catalog) lands first, instead of in the first change.
    static let atRest: Duration = .milliseconds(800)

    /// Main-thread milliseconds for `change` and the update, layout, and display it causes.
    private func cost(_ window: OffscreenWindow, _ change: () async -> Void) async -> Double {
        await MainThreadCPU.milliseconds {
            await change()
            ListPerf.settle(window)
        }
    }

    /// Ten prose chunks streamed into a sixty-turn thread under its toolbar: the median
    /// main-thread cost of one chunk, over three runs.
    @Test func streamedProseChunk() async throws {
        var perChunk: [Double] = []
        for _ in 0..<3 {
            let snapshot = ThreadFixture.snapshot(ThreadFixture.history(120) + [ThreadFixture.user("u", "Go on")],
                                                  provisional: [ThreadFixture.streaming("Streaming")], running: true,
                                                  stats: NativeThreadStats(contextTokens: 42_000))
            let thread = FakeThread(snapshot, header: true)
            try await thread.waitUntilReady()
            try await Task.sleep(for: Self.atRest)
            var costs: [Double] = []
            for index in 1...10 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming("Streaming" + String(repeating: " more words in the reply", count: index * 4))]
                costs.append(await cost(thread.window) { await thread.serve(next) })
            }
            perChunk.append(MainThreadCPU.median(costs))
            thread.close()
        }
        report.add("thread (60 turns) under its toolbar", "streamed prose chunk: main-thread CPU (median of 3)",
                   ms: MainThreadCPU.median(perChunk))
    }

    /// Hiding a sixty-turn thread and showing it again (its first pull brings nothing new):
    /// main-thread CPU for each flip, and the bodies each rebuilds.
    @Test func switchAwayAndBack() async throws {
        var hides: [Double] = [], shows: [Double] = []
        var hidden: [String: Int] = [:], shown: [String: Int] = [:]
        for run in 0..<3 {
            let snapshot = ThreadFixture.snapshot(ThreadFixture.history(120), stats: NativeThreadStats(contextTokens: 42_000))
            let thread = FakeThread(snapshot, header: true)
            try await thread.waitUntilReady()
            try await Task.sleep(for: Self.atRest)
            if run == 0 { NWRenderProbe.start() }
            hides.append(await MainThreadCPU.milliseconds { try? await thread.show(false) })
            if run == 0 { hidden = NWRenderProbe.stop(); NWRenderProbe.start() }
            shows.append(await MainThreadCPU.milliseconds { try? await thread.show(true) })
            if run == 0 { shown = NWRenderProbe.stop() }
            thread.close()
        }
        report.add("thread (60 turns) under its toolbar", "switch: hide / show main-thread CPU (median of 3)",
                   String(format: "%.1f ms / %.1f ms", MainThreadCPU.median(hides), MainThreadCPU.median(shows)))
        report.add("thread (60 turns) under its toolbar", "switch: hide", counts: hidden)
        report.add("thread (60 turns) under its toolbar", "switch: show", counts: shown)
    }

    /// A hidden agent's status report with 12 and 30 layouts mounted: main-thread CPU per report
    /// and the layout bodies it reruns.
    @Test(arguments: [12, 30]) func statusReportWithLayoutsMounted(count: Int) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(count, in: app)
        defer { window.close() }
        try await Task.sleep(for: Self.atRest)
        var costs: [Double] = []
        NWRenderProbe.start()
        for round in 0..<3 {
            for agent in agents.dropFirst().prefix(6) {
                var next = vm.state
                if let index = next.agents.firstIndex(where: { $0.id == agent.agent.id }) {
                    next.agents[index].status = round.isMultiple(of: 2) ? .working : .done
                }
                costs.append(await cost(window) { vm.adopt(next) })
            }
        }
        let counts = NWRenderProbe.stop().mapValues { $0 / costs.count }
        report.add("workspace (\(count) layouts mounted)", "hidden agent's status report: main-thread CPU (median)",
                   ms: MainThreadCPU.median(costs))
        report.add("workspace (\(count) layouts mounted)", "hidden agent's status report: bodies each", counts: counts)
    }

    /// Fifteen chunks of a reply writing a Swift fence that grows to about a hundred lines, one
    /// every 100 ms: the median main-thread cost of a chunk, over three runs, with the colors'
    /// tree-sitter renders counted.
    @Test func streamedCodeChunk() async throws {
        var perChunk: [Double] = [], processPerChunk: [Double] = []
        var renders: [Int] = []
        for run in 0..<3 {
            // Each run its own code, so no run colors from another's cache.
            func reply(_ lines: Int) -> String { ListPerformanceTests.codeReply(lines).replacingOccurrences(of: "value", with: "value\(run)_") }
            let turn = ThreadFixture.history(2) + [ThreadFixture.user("u", "Write it")]
            let thread = FakeThread(ThreadFixture.snapshot(turn, provisional: [ThreadFixture.streaming(reply(2))], running: true))
            try await thread.waitUntilReady()
            try await Task.sleep(for: Self.atRest)
            var costs: [Double] = []
            NWRenderProbe.start()
            let process = ProcessCPU.now()
            for chunk in 1...15 {
                var next = thread.snapshot
                next.revision += 1
                next.provisional = [ThreadFixture.streaming(reply(2 + chunk * 7) + "    let partial")]
                costs.append(await cost(thread.window) {
                    await thread.serve(next)
                    try? await Task.sleep(for: .milliseconds(100))
                })
            }
            processPerChunk.append(ListPerf.milliseconds(ProcessCPU.now() - process) / 15)
            renders.append(NWRenderProbe.stop()["highlight.render", default: 0])
            perChunk.append(MainThreadCPU.median(costs))
            thread.close()
        }
        report.add("thread writing a Swift fence (15 chunks, 100 ms apart)", "code chunk: main-thread CPU (median of 3)",
                   ms: MainThreadCPU.median(perChunk))
        report.add("thread writing a Swift fence (15 chunks, 100 ms apart)", "code chunk: process CPU, all threads (median of 3)",
                   ms: MainThreadCPU.median(processPerChunk))
        report.add("thread writing a Swift fence (15 chunks, 100 ms apart)", "tree-sitter renders", "\(renders)")
    }

    /// A host whose revision moves every 20 ms for 4 s, prose streaming into a thread of 50 or
    /// 540 messages, pulled by the poll alone or pushed as a local pi's are: the changes that
    /// reach the screen, the median gap between them, and main-thread CPU per second of
    /// streaming (medians of 3 interleaved runs).
    @Test(arguments: [50, 540]) func streamingPolledOrPushed(messages: Int) async throws {
        var changes: [Bool: [Double]] = [:], gaps: [Bool: [Double]] = [:], cpu: [Bool: [Double]] = [:]
        for _ in 0..<3 {
            for push in [false, true] {
                let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(messages) + [ThreadFixture.user("u", "Go on")],
                                                               provisional: [ThreadFixture.streaming("Streaming")], running: true))
                try await thread.waitUntilReady()
                try await Task.sleep(for: Self.atRest)
                let adoptions = Adoptions(thread.store)
                let ms = try await MainThreadCPU.milliseconds { try await thread.stream(for: .seconds(4), push: push) }
                adoptions.stop()
                changes[push, default: []].append(Double(adoptions.count))
                gaps[push, default: []].append(adoptions.medianGap)
                cpu[push, default: []].append(ms / 4)
                thread.close()
            }
        }
        for push in [false, true] {
            let list = "streaming, a revision every 20 ms (\(messages) messages, \(push ? "pushed" : "polled"))"
            report.add(list, "on-screen changes in 4 s", String(format: "%.0f", MainThreadCPU.median(changes[push] ?? [])))
            report.add(list, "median gap between changes", ms: MainThreadCPU.median(gaps[push] ?? []))
            report.add(list, "main-thread CPU per second of streaming", ms: MainThreadCPU.median(cpu[push] ?? []))
        }
    }

    /// Launching into a workspace of forty agents: the first populated frame (its wall time,
    /// main-thread CPU, and bodies), then, while the other layouts mount, the longest stretch
    /// the main thread went without waiting.
    @Test func launchIntoFortyAgents() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(40, in: app)
        try await Task.sleep(for: Self.atRest)
        var window: OffscreenWindow!
        NWRenderProbe.start()
        let start = ContinuousClock.now
        let firstCPU = await MainThreadCPU.milliseconds {
            window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
            ListPerf.settle(window)
        }
        let firstWall = ListPerf.milliseconds(ContinuousClock.now - start)
        let first = NWRenderProbe.stop().filter { ["layout.agentLayout", "thread.view", "composer.body"].contains($0.key) }
        defer { window.close() }
        let monitor = MainTurnMonitor()
        monitor.start()
        let drainStart = ContinuousClock.now
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        ListPerf.settle(window)
        let drained = ListPerf.milliseconds(ContinuousClock.now - drainStart)
        try await Task.sleep(for: .milliseconds(300))
        monitor.stop()
        report.add("workspace launch (40 agents)", "first frame: wall / main-thread CPU", String(format: "%.1f ms / %.1f ms", firstWall, firstCPU))
        report.add("workspace launch (40 agents)", "first frame: bodies", counts: first)
        report.add("workspace launch (40 agents)", "the rest mounted after", String(format: "%.0f ms", drained))
        report.add("workspace launch (40 agents)", "longest main-thread turns while they mount",
                   monitor.durations.sorted(by: >).prefix(5).map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")
                       + String(format: " ms (%d turns)", monitor.turns))
    }

    /// A one-shot motion (the review pane sliding in beside the visible thread) with 5 and 40
    /// layouts mounted behind it: the longest gap between frames while it runs, three times.
    @Test(arguments: [5, 40]) func oneShotMotionWithLayoutsMounted(count: Int) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(count, in: app)
        defer { window.close() }
        try await Task.sleep(for: Self.atRest)
        var gaps: [Double] = []
        for _ in 0..<3 {
            let opened = await FrameTimer.measure(window, region: CGRect(x: 0, y: 400, width: 1200, height: 1)) {
                withNWAnimation(.pane) { vm.openReview(agentID: agents[0].agent.id, path: nil) }
            }
            gaps.append(opened.longestGap * 1000)
            let review = try #require(vm.reviewSessions.values.first)
            vm.cancelReview(review)
            ListPerf.settle(window)
            try await Task.sleep(for: .milliseconds(400))
        }
        report.add("review pane sliding in (\(count) layouts mounted)", "longest frame gap (median of 3)", ms: MainThreadCPU.median(gaps))
    }

    /// Dragging the window's edge 8 pt a frame with 1, 5, and 12 layouts mounted in the full
    /// shell: main-thread CPU per frame (median of three drags of 12 frames).
    @Test(arguments: [1, 5, 12]) func liveResizeFrameWithLayoutsMounted(count: Int) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(count, in: app)
        let window = OffscreenWindow(size: CGSize(width: 1400, height: 800), dark: true, RootView(vm: vm))
        defer { window.close() }
        let visible = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready }
        try await eventuallyOnMain("every layout to mount") { vm.mountedTabs.count == agents.count }
        try await Task.sleep(for: Self.atRest)
        ListPerf.settle(window)
        var drags: [Double] = []
        for drag in 0..<3 {
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window.window)
            ListPerf.settle(window)
            var frames: [Double] = []
            for step in 1...12 {
                let width = drag.isMultiple(of: 2) ? 1400 - CGFloat(step) * 8 : 1304 + CGFloat(step) * 8
                frames.append(await MainThreadCPU.milliseconds {
                    window.window.setContentSize(NSSize(width: width, height: 800))
                    ListPerf.settle(window)
                })
            }
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window.window)
            ListPerf.settle(window)
            drags.append(MainThreadCPU.median(frames))
        }
        report.add("live resize (\(count) layouts mounted)", "main-thread CPU per 8 pt frame (median of 3)", ms: MainThreadCPU.median(drags))
    }

    /// Returning to a thread-only agent hidden past the park delay, after five other visits:
    /// main-thread CPU for the switch and the bodies it builds.
    @Test func returnToAThreadOnlyAgentHiddenLong() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(7, in: app)
        defer { window.close() }
        for agent in agents.dropFirst(2) {
            vm.selectAgent(agent.agent.id)
            ListPerf.settle(window)
        }
        vm.sweepColdPanes(now: Date().addingTimeInterval(60))
        ListPerf.settle(window)
        let parked = vm.parkedTabIDs.contains(agents[0].tab.id)
        try await Task.sleep(for: Self.atRest)
        NWRenderProbe.start()
        let cpu = await MainThreadCPU.milliseconds {
            vm.selectAgent(agents[0].agent.id)
            ListPerf.settle(window)
        }
        let counts = NWRenderProbe.stop().filter { ["layout.agentLayout", "thread.view", "composer.body", "thread.rowBuilder"].contains($0.key) }
        report.add("returning to a thread-only agent hidden 60 s", "was parked", "\(parked)")
        report.add("returning to a thread-only agent hidden 60 s", "switch: main-thread CPU", ms: cpu)
        report.add("returning to a thread-only agent hidden 60 s", "switch: bodies", counts: counts)
    }

    /// A poll that moves only the context count.
    @Test func statsOnlyPoll() async throws {
        var runs: [Double] = []
        for _ in 0..<3 {
            let snapshot = ThreadFixture.snapshot(ThreadFixture.history(120), stats: NativeThreadStats(contextTokens: 42_000))
            let thread = FakeThread(snapshot, header: true)
            try await thread.waitUntilReady()
            try await Task.sleep(for: Self.atRest)
            var costs: [Double] = []
            for index in 1...10 {
                var next = thread.snapshot
                next.revision += 1
                next.stats = NativeThreadStats(contextTokens: 42_000 + index * 1_000)
                costs.append(await cost(thread.window) { await thread.serve(next) })
            }
            runs.append(MainThreadCPU.median(costs))
            thread.close()
        }
        report.add("thread (60 turns) under its toolbar", "stats-only poll: main-thread CPU (median of 3)", ms: MainThreadCPU.median(runs))
    }
}
