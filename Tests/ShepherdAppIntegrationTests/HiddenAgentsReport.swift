import AppKit
import Foundation
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// What an update in the visible layout costs beside 0, 10 and 30 hidden agents, in
/// instructions retired (nearly independent of how busy the machine is), printed as
/// `PERF | … | … | …`: a scroll step in the Changes pane, a keystroke, a status report, and a
/// switch. (A streamed reply's pulls land between the run loop's turns, where nothing here can
/// fence one off from the server's and pi's work; `ListPerformanceTests` counts its updates.)
/// Build it in release for numbers that match the app (AGENTS.md › Testing);
/// `ListPerformanceTests` pins the counts behind them.
///
///     SHEPHERD_PERF_REPORT=1 swift test --filter HiddenAgentsReport
@Suite("Hidden agents report", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PERF_REPORT"] != nil))
@MainActor
struct HiddenAgentsReport {
    private let report = PerfReport()

    /// The mean of `values` without the slowest tenth (a stray display cycle, a pull landing).
    private static func trimmedMean(_ values: [Double]) -> Double {
        let kept = values.sorted().dropLast(values.count / 10)
        return kept.isEmpty ? 0 : kept.reduce(0, +) / Double(kept.count)
    }

    /// Each change's instructions, as the workspace makes them.
    @MainActor private final class Tally {
        var values: [Double] = []

        func measure(_ change: () -> Void) {
            let start = ListPerf.instructions()
            change()
            values.append(ListPerf.instructions() - start)
        }
    }

    @Test(arguments: [0, 10, 30])
    func updatesInTheVisibleLayout(hidden: Int) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let workspace = try await HiddenAgentsWorkspace.open(hidden: hidden, in: app)
        defer { workspace.close() }
        let name = "workspace (\(hidden) hidden)"
        report.add(name, "taking part", "\(workspace.census())")

        let fine = workspace.scroll(step: 1, steps: 200)
        let coarse = workspace.scroll(step: 40, steps: 300)
        report.add(name, "diff 1 pt step: instructions mean · p95", String(format: "%.2f M · %.2f M", fine.instructionsMean, fine.instructionsP95))
        report.add(name, "diff 40 pt step: instructions mean · p95", String(format: "%.2f M · %.2f M", coarse.instructionsMean, coarse.instructionsP95))

        let keystrokes = Tally()
        workspace.type(100, each: keystrokes.measure)
        report.add(name, "keystroke: instructions", String(format: "%.2f M", Self.trimmedMean(keystrokes.values)))

        let reports = Tally()
        workspace.reportStatus(60, each: reports.measure)
        report.add(name, "status report: instructions", String(format: "%.2f M", Self.trimmedMean(reports.values)))

        if hidden > 0 {
            var switches: [Double] = []
            for index in 0..<10 {
                let start = ListPerf.instructions()
                workspace.vm.selectAgent(workspace.agents[index.isMultiple(of: 2) ? 1 : 0].agent.id)
                ListPerf.settle(workspace.window)
                switches.append(ListPerf.instructions() - start)
                // What the switch sets off after its frame (the thread's first pull) lands apart.
                for _ in 0..<3 {
                    try await Task.sleep(for: .milliseconds(30))
                    ListPerf.settle(workspace.window)
                }
            }
            report.add(name, "switch: instructions, median of 10", String(format: "%.2f M", switches.sorted()[switches.count / 2]))
        }
    }
}
