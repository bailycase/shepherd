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
            try await Task.sleep(for: .milliseconds(200))
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

    /// A poll that moves only the context count.
    @Test func statsOnlyPoll() async throws {
        var runs: [Double] = []
        for _ in 0..<3 {
            let snapshot = ThreadFixture.snapshot(ThreadFixture.history(120), stats: NativeThreadStats(contextTokens: 42_000))
            let thread = FakeThread(snapshot, header: true)
            try await thread.waitUntilReady()
            try await Task.sleep(for: .milliseconds(200))
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
