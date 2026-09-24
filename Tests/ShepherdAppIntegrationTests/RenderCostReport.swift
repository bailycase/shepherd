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
