import AppKit
import Foundation
import QuartzCore
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Real native scrolling/layout/display on a paced main run loop. This measures missed CPU
/// deadlines, not physical display presentation or GPU FPS. No synthetic user input is posted.
@Suite("Changes scroll frame report", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PERF_REPORT"] == "1"))
@MainActor
struct ChangesScrollFrameReport {
    @Test(arguments: [false, true], [100, 300])
    func continuousHighlightedScrolling(split: Bool, step: Int) async throws {
        let files = ListFixtures.realisticReview()
        let model = ListFixtures.reviewModel([files[5], files[12]])
        model.session.layoutChoice = split ? .split : .unified
        let window = OffscreenWindow(size: CGSize(width: split ? 1000 : 600, height: 800), dark: true,
                                     ReviewPaneContent(model: model))
        defer { window.close() }
        try await eventuallyOnMain("the large diff to finish syntax highlighting") { model.highlights.count == 2 }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))
        let clock = ContinuousClock()
        let budget = Duration.nanoseconds(8_333_333)
        var next = clock.now + budget
        var starts: [ContinuousClock.Instant] = []
        var costs: [Double] = []
        var draws: [Double] = []
        var moved: CGFloat = 0
        var direction: CGFloat = 1
        NWRenderProbe.start()
        for _ in 0..<360 {
            try await clock.sleep(until: next)
            let start = clock.now
            starts.append(start)
            let before = scroll.contentView.bounds.origin.y
            let sample = ListPerf.scroll(window, scroll, step: direction * CGFloat(step), steps: 1)
            costs.append(sample.steps.first ?? 0)
            let drawing = clock.now
            _ = FrameTimer.capture(window, window.host.bounds)
            draws.append(ListPerf.milliseconds(clock.now - drawing))
            moved += abs(scroll.contentView.bounds.origin.y - before)
            if scroll.contentView.bounds.origin.y == before { direction *= -1 }
            // Keep the requested 120Hz pace without catch-up loops after a missed deadline.
            next = max(next + budget, clock.now)
        }
        let counts = NWRenderProbe.stop()
        let gaps = zip(starts.dropFirst(), starts).map { ListPerf.milliseconds($0 - $1) }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        #expect(moved > 20_000, "the benchmark must actually traverse the long file")
        #if DEBUG
        #expect(counts["diff.line", default: 0] > 100)
        #endif
        print(String(format: "SCROLL-FRAMES %@ step %d: moved %.0fpt; layout/display mean %.2fms p95 %.2fms; capture mean %.2fms; frame gap p50 %.2fms p95 %.2fms worst %.2fms; >12.5ms %d/%d; rows %d",
                     split ? "split" : "unified", step, moved, costs.reduce(0,+) / Double(costs.count), percentile(costs, 0.95), draws.reduce(0,+) / Double(draws.count),
                     percentile(gaps, 0.5), percentile(gaps, 0.95), gaps.max() ?? 0,
                     gaps.filter { $0 > 12.5 }.count, gaps.count, counts["diff.line", default: 0]))
    }
}
