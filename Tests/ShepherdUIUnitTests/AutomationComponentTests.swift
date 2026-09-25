import Testing
@testable import ShepherdUI

/// The Automations components' pure parts.
@Suite("Automations components")
struct AutomationComponentTests {
    /// The run chart's heading counts its bars, and one bar is a single run.
    @Test(arguments: [(1, "Last run"), (2, "Last 2 runs"), (14, "Last 14 runs")])
    func theRunChartsHeadingCountsItsRuns(runs: Int, title: String) {
        #expect(NWRunBars.title(runs: runs) == title)
    }
}
