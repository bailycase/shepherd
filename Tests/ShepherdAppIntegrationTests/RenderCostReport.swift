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
            if run == 0 { SHRenderProbe.start() }
            hides.append(await MainThreadCPU.milliseconds { try? await thread.show(false) })
            if run == 0 { hidden = SHRenderProbe.stop(); SHRenderProbe.start() }
            shows.append(await MainThreadCPU.milliseconds { try? await thread.show(true) })
            if run == 0 { shown = SHRenderProbe.stop() }
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
        SHRenderProbe.start()
        for round in 0..<3 {
            for agent in agents.dropFirst().prefix(6) {
                var next = vm.state
                if let index = next.agents.firstIndex(where: { $0.id == agent.agent.id }) {
                    next.agents[index].status = round.isMultiple(of: 2) ? .working : .done
                }
                costs.append(await cost(window) { vm.adopt(next) })
            }
        }
        let counts = SHRenderProbe.stop().mapValues { $0 / costs.count }
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
            SHRenderProbe.start()
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
            renders.append(SHRenderProbe.stop()["highlight.render", default: 0])
            perChunk.append(MainThreadCPU.median(costs))
            thread.close()
        }
        report.add("thread writing a Swift fence (15 chunks, 100 ms apart)", "code chunk: main-thread CPU (median of 3)",
                   ms: MainThreadCPU.median(perChunk))
        report.add("thread writing a Swift fence (15 chunks, 100 ms apart)", "code chunk: process CPU, all threads (median of 3)",
                   ms: MainThreadCPU.median(processPerChunk))
        report.add("thread writing a Swift fence (15 chunks, 100 ms apart)", "tree-sitter renders", "\(renders)")
    }

    /// One 3,000-line Python fence written in 2 KB chunks, 40 ms apart, as a reply writes it: the
    /// main thread's cost per chunk, the process's CPU and instructions for the whole stream, and
    /// how much heap and footprint the fence takes while it grows and keeps once the reply is done.
    @Test func streamedLongFence() async throws {
        let code = FenceStream.python(lines: 3_000)
        let chunks = stride(from: 0, to: code.utf8.count, by: 2_048).map { String(decoding: code.utf8.prefix(min($0 + 2_048, code.utf8.count)), as: UTF8.self) }
        let window = OffscreenWindow(size: CGSize(width: 720, height: 800), dark: false,
                                     HighlightedCodeBlock(code: "", language: "python", writing: true))
        defer { window.close() }
        ListPerf.settle(window)
        try await Task.sleep(for: Self.atRest)
        let before = FenceStream.Memory.now()
        var costs: [Double] = []
        var peakHeap = before.heap
        SHRenderProbe.start()
        let process = ProcessCPU.now()
        let instructions = ListPerf.instructions()
        for chunk in chunks {
            costs.append(await cost(window) {
                window.show(HighlightedCodeBlock(code: chunk, language: "python", writing: true))
                try? await Task.sleep(for: .milliseconds(40))
            })
            peakHeap = max(peakHeap, FenceStream.Memory.now().heap)
        }
        let streamCPU = ListPerf.milliseconds(ProcessCPU.now() - process)
        let streamInstructions = ListPerf.instructions() - instructions
        let streaming = SHRenderProbe.stop()
        let peak = FenceStream.Memory.now()
        window.show(HighlightedCodeBlock(code: code, language: "python", writing: false))
        let key = CodeHighlightCache.Key(fence: code, language: "python")
        try await eventuallyOnMain("the finished fence to be colored") {
            ListPerf.settle(window)
            return CodeHighlightCache.cached(key) != nil
        }
        try await Task.sleep(for: .seconds(2))
        ListPerf.settle(window)
        let after = FenceStream.Memory.now()
        let label = "3,000-line Python fence (\(chunks.count) chunks of 2 KB, 40 ms apart)"
        report.add(label, "chunk: main-thread CPU median · p95 · worst", String(format: "%.2f ms · %.2f ms · %.2f ms",
            MainThreadCPU.median(costs), costs.sorted()[costs.count * 95 / 100], costs.max() ?? 0))
        report.add(label, "stream: main-thread CPU total", ms: costs.reduce(0, +))
        report.add(label, "stream: process CPU, all threads", ms: streamCPU)
        report.add(label, "stream: instructions", String(format: "%.0f M", streamInstructions))
        report.add(label, "heap in use: before · peak while streaming · after the reply",
                   String(format: "%.1f · %.1f · %.1f MB", before.heapMB, Double(peakHeap) / 1_048_576, after.heapMB))
        report.add(label, "footprint: before · after streaming · after the reply · lifetime peak",
                   String(format: "%.1f · %.1f · %.1f · %.1f MB", before.footprintMB, peak.footprintMB, after.footprintMB, after.peakFootprintMB))
        report.add(label, "bodies and work while streaming", counts: streaming.filter {
            ["code.highlighted", "code.nativeUpdated", "thread.codeAttributes", "layout.codeMeasured", "highlight.render",
             "highlight.units", "code.styledUnits", "code.laidOutUnits"].contains($0.key) })
    }

    /// Real thread rows containing prose and code, rather than the short replies used by the
    /// mounted-workspace resize report. No input events are sent to the off-screen window.
    @Test(arguments: [12, 500])
    func scrollingAndResizingRichThreads(codeLines: Int) async throws {
        let label = "rich thread (60 turns, \(codeLines)-line code fences)"
        let reply = ThreadFixture.answer + "\n\n" + ListPerformanceTests.codeReply(codeLines)
        let key = try #require(nativeMarkdownBlocks(reply).compactMap { block -> CodeHighlightCache.Key? in
            guard case .code(let code, let language) = block else { return nil }
            return CodeHighlightCache.Key(fence: code, language: language)
        }.first)
        let messages = (0..<60).flatMap { index in
            [ThreadFixture.user("u\(index)", "Review implementation \(index)"), ThreadFixture.assistant("a\(index)", reply)]
        }
        let thread = FakeThread(ThreadFixture.snapshot(messages), header: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("syntax coloring to finish before measuring rich scrolling") {
            CodeHighlightCache.cached(key) != nil
        }
        #expect(CodeHighlightCache.cached(key)?.runs.contains { run in
            let color: Color? = run.foregroundColor
            return color != nil
        } == true,
                "the measured thread must contain syntax colors, not a plain-text fallback")
        try await Task.sleep(for: Self.atRest)
        let scroll = try #require(ListPerf.scrollView(in: thread.window))
        #expect(scroll.frame.height <= thread.window.host.bounds.height, "measure the thread, not a nested code scroller")
        let up = ListPerf.scroll(thread.window, scroll, step: -200, steps: 60)
        let down = ListPerf.scroll(thread.window, scroll, step: 200, steps: 60)
        report.add("\(label) ↑", scroll: up)
        report.add("\(label) ↓", scroll: down)
        var costs: [Double] = []
        let counts = ListPerf.counting {
            for step in Array(0..<50) + Array((0..<50).reversed()) {
                let start = ListPerf.threadCPU()
                thread.window.window.setContentSize(CGSize(width: 900 - CGFloat(step) * 8, height: 600))
                ListPerf.settle(thread.window)
                costs.append(ListPerf.threadCPU() - start)
            }
        }
        report.add(label, "resize: main-thread CPU per 8 pt frame (median)", ms: MainThreadCPU.median(costs))
        report.add(label, "resize: work", counts: counts)
        #expect(thread.store.rows.count == messages.count)
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
    /// main-thread CPU, and bodies), then the first show of an agent nobody has opened, which
    /// mounts its layout, and a flip back to the first, which mounts nothing.
    @Test func launchIntoFortyAgents() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, agents) = try await MountedWorkspace.start(40, in: app, mounting: .launch)
        try await Task.sleep(for: Self.atRest)
        var window: OffscreenWindow!
        SHRenderProbe.start()
        let start = ContinuousClock.now
        let firstCPU = await MainThreadCPU.milliseconds {
            window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
            ListPerf.settle(window)
        }
        let firstWall = ListPerf.milliseconds(ContinuousClock.now - start)
        let keys = ["layout.agentLayout", "thread.view", "composer.body", "deck.mount"]
        let first = SHRenderProbe.stop().filter { keys.contains($0.key) }
        defer { window.close() }
        let visible = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the visible thread to load", timeout: .seconds(60)) { visible.ready }
        ListPerf.settle(window)
        try await Task.sleep(for: Self.atRest)

        func switchTo(_ index: Int) async -> (wall: Double, cpu: Double, counts: [String: Int]) {
            SHRenderProbe.start()
            let begin = ContinuousClock.now
            let cpu = await MainThreadCPU.milliseconds {
                vm.selectAgent(agents[index].agent.id)
                ListPerf.settle(window)
            }
            let wall = ListPerf.milliseconds(ContinuousClock.now - begin)
            return (wall, cpu, SHRenderProbe.stop().filter { keys.contains($0.key) })
        }
        let firstShow = await switchTo(20)
        try await Task.sleep(for: Self.atRest)
        let flip = await switchTo(0)

        let section = "workspace launch (40 agents)"
        report.add(section, "first frame: wall / main-thread CPU", String(format: "%.1f ms / %.1f ms", firstWall, firstCPU))
        report.add(section, "first frame: bodies and mounts", counts: first)
        report.add(section, "first show of an agent nobody opened: wall / main-thread CPU", String(format: "%.1f ms / %.1f ms", firstShow.wall, firstShow.cpu))
        report.add(section, "first show: bodies and mounts", counts: firstShow.counts)
        report.add(section, "flip back: wall / main-thread CPU", String(format: "%.1f ms / %.1f ms", flip.wall, flip.cpu))
        report.add(section, "flip back: bodies and mounts", counts: flip.counts)
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
                withSHAnimation(.pane) { vm.openReview(agentID: agents[0].agent.id, path: nil) }
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
        SHRenderProbe.start()
        let cpu = await MainThreadCPU.milliseconds {
            vm.selectAgent(agents[0].agent.id)
            ListPerf.settle(window)
        }
        let counts = SHRenderProbe.stop().filter { ["layout.agentLayout", "thread.view", "composer.body", "thread.rowBuilder"].contains($0.key) }
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

/// A long fence and what the process holds.
enum FenceStream {
    /// `lines` lines of Python: functions with docstrings, comments, strings and numbers.
    static func python(lines: Int) -> String {
        var out: [String] = []
        var index = 0
        while out.count < lines {
            out += [
                "",
                "def handler_\(index)(request, limit=\(index % 97)):",
                "    \"\"\"Handle request \(index) and return the sheep that fit.\"\"\"",
                "    # count the flock before anything else",
                "    flock = [name for name in request.names if len(name) > \(index % 7)]",
                "    if not flock:",
                "        return {\"status\": \"empty\", \"id\": \(index)}",
                "    return {\"status\": \"ok\", \"count\": len(flock), \"limit\": limit}",
            ]
            index += 1
        }
        return out.prefix(lines).joined(separator: "\n")
    }

    struct Memory {
        var heap: Int
        var footprint: UInt64
        var peakFootprint: UInt64

        var heapMB: Double { Double(heap) / 1_048_576 }
        var footprintMB: Double { Double(footprint) / 1_048_576 }
        var peakFootprintMB: Double { Double(peakFootprint) / 1_048_576 }

        /// The malloc heap in use, and the footprint the kernel charges the process.
        static func now() -> Memory {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            var info = rusage_info_v4()
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            return Memory(heap: Int(stats.size_in_use), footprint: info.ri_phys_footprint, peakFootprint: info.ri_lifetime_max_phys_footprint)
        }
    }
}
