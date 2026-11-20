import ShepherdUI
import UIKit

/// Like ListPerformanceTests, budget bodies, not milliseconds. Count from before navigation
/// through the fixture runner's first settled frame, including SwiftUI's viewport prefetch.
@MainActor
enum ListPerformanceFixture {
    static func start() { SHRenderProbe.start() }

    static func check(rows: Int, expected: Int, viewports: Int = 2, probes: String...) {
        let counts = SHRenderProbe.stop()
        let count = probes.reduce(0) { $0 + counts[$1, default: 0] }
        guard let window = FixtureWindows.shared.primary?.windows.first(where: \.isKeyWindow) else {
            FixtureCheck.fail("No window for the list budget")
        }
        // The whole window overestimates the scroll viewport; each row takes at least one
        // touch target's height. Allow extra rows for prefetch and the first settled layout.
        let onScreen = Int(window.bounds.height / SH.Height.touch) + 1
        let budget = viewports * onScreen
        let passes = rows == expected && (1...budget).contains(count)
        FixtureCheck.report("FIXTURE CHECK \(passes ? "ok" : "FAILED"): \(probes.joined(separator: "/")) built \(count) bodies for \(rows)/\(expected) rows (budget \(budget))")
    }
}
