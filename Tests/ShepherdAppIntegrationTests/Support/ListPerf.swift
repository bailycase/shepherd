import AppKit
import QuartzCore
import ShepherdUI
import SwiftUI

/// Measures long lists in an off-screen window: the main thread's time for a change and the
/// layout and display it causes, scrolling in steps the way a reader does (each step one layout
/// pass), and how many rows evaluated their `body` meanwhile (`NWRenderProbe`). Nothing here
/// sends an event: scrolling moves the clip view, as `ThreadScrollingTests` does.
@MainActor
enum ListPerf {
    /// Main-thread milliseconds for `change` plus the update, layout, and display it causes.
    @discardableResult
    static func time(_ window: OffscreenWindow, _ change: () -> Void = {}) -> Double {
        let start = ContinuousClock.now
        change()
        settle(window)
        return milliseconds(ContinuousClock.now - start)
    }

    /// Runs the pending update, layout, and display now.
    static func settle(_ window: OffscreenWindow) {
        window.layout()
        window.host.displayIfNeeded()
        CATransaction.flush()
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// SwiftUI's lazy stacks build more rows in two thread budgets (see `ListPerformanceTests`)
    /// on macOS 26, or built with Xcode 26's SDK (Swift 6.3) on 27, whatever the machine's speed.
    static var olderLazyStacks: Bool {
        #if compiler(>=6.4)
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
        #else
        true
        #endif
    }

    /// Row bodies counted while `work` runs, by probe key.
    static func counting(_ work: () -> Void) -> [String: Int] {
        NWRenderProbe.start()
        work()
        return NWRenderProbe.stop()
    }

    /// The list under test: the scroll view with the tallest frame in the window.
    /// With `trailing`, the tallest of those that end furthest right (a pane docked beside a
    /// thread).
    static func scrollView(in window: OffscreenWindow, trailing: Bool = false) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] + $0.subviews.flatMap(all) } ?? view.subviews.flatMap(all)
        }
        let views = all(window.host)
        guard trailing else { return views.max { $0.frame.height < $1.frame.height } }
        func right(_ view: NSScrollView) -> CGFloat { view.convert(view.bounds, to: nil).maxX }
        return views.max { (right($0), $0.frame.height) < (right($1), $1.frame.height) }
    }

    /// The main thread's CPU time so far, in milliseconds. Unlike the wall clock, other
    /// processes busy on the machine (parallel builds) barely move it.
    static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
    }

    /// Instructions this process has retired so far, in millions: nearly independent of how busy
    /// the machine is, so a change's cost compares across runs.
    static func instructions() -> Double {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Double(info.ri_instructions) / 1e6 : 0
    }

    /// The layers in the window that cast a shadow, and how many layers each one's subtree
    /// holds. Core Animation draws a shadow without a path from the whole subtree's alpha, again
    /// whenever anything in it changes.
    static func shadowedLayers(in window: OffscreenWindow) -> [(layer: CALayer, subtree: Int)] {
        func size(_ layer: CALayer) -> Int { 1 + (layer.sublayers ?? []).reduce(0) { $0 + size($1) } }
        func walk(_ layer: CALayer) -> [(layer: CALayer, subtree: Int)] {
            let own = layer.shadowOpacity > 0 ? [(layer: layer, subtree: size(layer))] : []
            return own + (layer.sublayers ?? []).flatMap(walk)
        }
        return window.host.layer.map(walk) ?? []
    }

    /// One pass of scrolling: each step's milliseconds.
    struct Scroll {
        /// Each step's instructions, in millions (the whole process: the main thread's work).
        var instructions: [Double] = []
        var instructionsMean: Double { instructions.isEmpty ? 0 : instructions.reduce(0, +) / Double(instructions.count) }
        var instructionsP95: Double {
            guard !instructions.isEmpty else { return 0 }
            let sorted = instructions.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))]
        }
        var steps: [Double] = []
        /// Each step's main-thread CPU milliseconds.
        var cpu: [Double] = []
        /// How far it moved, in points.
        var distance: CGFloat = 0

        var cpuMean: Double { cpu.isEmpty ? 0 : cpu.reduce(0, +) / Double(cpu.count) }
        var cpuMedian: Double { cpu.isEmpty ? 0 : cpu.sorted()[cpu.count / 2] }
        var cpuP95: Double {
            guard !cpu.isEmpty else { return 0 }
            let sorted = cpu.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))]
        }

        var total: Double { steps.reduce(0, +) }
        var mean: Double { steps.isEmpty ? 0 : total / Double(steps.count) }
        var worst: Double { steps.max() ?? 0 }
        /// The 95th percentile step.
        var p95: Double {
            guard !steps.isEmpty else { return 0 }
            let sorted = steps.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))]
        }
    }

    /// Scrolls `scroll` by `step` points at a time (down, or up when `step` is negative) for up to
    /// `steps` steps or until it stops moving, timing each step's layout and display.
    static func scroll(_ window: OffscreenWindow, _ scroll: NSScrollView, step: CGFloat, steps: Int) -> Scroll {
        var result = Scroll()
        let clip = scroll.contentView
        for _ in 0..<steps {
            let before = clip.bounds.origin.y
            let start = ContinuousClock.now
            let cpu = threadCPU()
            let retired = instructions()
            let target = NSRect(origin: NSPoint(x: clip.bounds.origin.x, y: before + step), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            scroll.reflectScrolledClipView(clip)
            settle(window)
            result.steps.append(milliseconds(ContinuousClock.now - start))
            result.cpu.append(threadCPU() - cpu)
            result.instructions.append(instructions() - retired)
            let moved = clip.bounds.origin.y - before
            result.distance += abs(moved)
            if abs(moved) < 0.5 { break }
        }
        return result
    }

    /// Scrolls to the very top or bottom at once (a reader dragging the scroller).
    static func jump(_ window: OffscreenWindow, _ scroll: NSScrollView, toEnd: Bool) {
        let clip = scroll.contentView
        let y = toEnd ? (scroll.documentView?.bounds.height ?? 0) : -10_000
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        settle(window)
    }
}

/// A table of measurements printed at the end of a report run.
@MainActor
final class PerfReport {
    struct Row {
        var list: String
        var metric: String
        var value: String
    }

    private(set) var rows: [Row] = []

    func add(_ list: String, _ metric: String, _ value: String) {
        rows.append(Row(list: list, metric: metric, value: value))
        print("PERF | \(list) | \(metric) | \(value)")
    }

    func add(_ list: String, _ metric: String, ms: Double) {
        add(list, metric, String(format: "%.1f ms", ms))
    }

    func add(_ list: String, scroll: ListPerf.Scroll) {
        add(list, "scroll: steps · mean · p95 · worst",
            String(format: "%d · %.2f ms · %.2f ms · %.2f ms (%.0f pt)", scroll.steps.count, scroll.mean, scroll.p95, scroll.worst, scroll.distance))
        add(list, "scroll: main-thread CPU mean · p50 · p95",
            String(format: "%.2f ms · %.2f ms · %.2f ms", scroll.cpuMean, scroll.cpuMedian, scroll.cpuP95))
        add(list, "scroll: instructions mean · p95", String(format: "%.1f M · %.1f M", scroll.instructionsMean, scroll.instructionsP95))
    }

    func add(_ list: String, _ metric: String, counts: [String: Int]) {
        let text = counts.isEmpty ? "none" : counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        add(list, metric, text)
    }
}
