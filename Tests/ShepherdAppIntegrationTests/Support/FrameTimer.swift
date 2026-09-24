import AppKit
import QuartzCore
import SwiftUI

/// Times what a change costs the main thread in an off-screen window: how long until its first
/// frame draws, and the longest the main thread went without drawing while it settled. Every
/// poll lays the window out and draws `region`, so a stall anywhere on the main thread (a
/// layout pass, an update in a run-loop observer, an animation frame) shows up as a gap.
@MainActor
enum FrameTimer {
    struct Result: CustomStringConvertible {
        /// Seconds from the change to the first frame that differs from the one before it.
        var firstFrame: Double?
        /// The longest gap between two consecutive frames, in seconds.
        var longestGap: Double
        /// Seconds until the region held still.
        var settled: Double
        var frames: Int

        var description: String {
            String(format: "first frame %.1f ms · longest gap %.1f ms · settled %.0f ms · %d frames",
                   (firstFrame ?? .nan) * 1000, longestGap * 1000, settled * 1000, frames)
        }
    }

    /// Runs `change`, then draws `region` about every millisecond until it has changed and held
    /// still for `stillFrames` draws (or `timeout` passes).
    static func measure(_ window: OffscreenWindow, region: CGRect, stillFrames: Int = 10, timeout: TimeInterval = 5,
                        change: () -> Void) async -> Result {
        window.layout()
        let before = capture(window, region)
        let start = CACurrentMediaTime()
        change()
        window.layout()
        var previous = capture(window, region)
        var last = CACurrentMediaTime()
        var result = Result(firstFrame: previous == before ? nil : last - start, longestGap: last - start, settled: 0, frames: 1)
        var still = 0
        while CACurrentMediaTime() - start < timeout {
            try? await Task.sleep(for: .milliseconds(1))
            window.layout()
            let frame = capture(window, region)
            let now = CACurrentMediaTime()
            result.longestGap = max(result.longestGap, now - last)
            result.frames += 1
            last = now
            if result.firstFrame == nil, frame != before { result.firstFrame = now - start }
            still = frame == previous ? still + 1 : 0
            previous = frame
            if result.firstFrame != nil, still >= stillFrames { break }
        }
        result.settled = last - start
        return result
    }

    /// One drawing of a region: RGBA bytes, one pixel per point, rows from the top.
    struct Capture: Equatable {
        let data: Data
        let bytesPerRow: Int
        let width: Int
        let height: Int
    }

    /// Draws `region` once.
    static func capture(_ window: OffscreenWindow, _ region: CGRect) -> Capture {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(region.width.rounded(.up)), pixelsHigh: Int(region.height.rounded(.up)),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = region.size
        window.host.cacheDisplay(in: region, to: bitmap)
        return Capture(data: Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerPlane), bytesPerRow: bitmap.bytesPerRow,
                       width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    }

    /// Seconds `work` takes, with the window laid out and `region` drawn after it.
    static func time(_ window: OffscreenWindow, region: CGRect, _ work: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        work()
        window.layout()
        _ = capture(window, region)
        return CACurrentMediaTime() - start
    }
}

extension Array where Element == Double {
    /// "mean 1.2 · p95 3.4 · max 5.6 ms".
    var millisecondSummary: String {
        guard !isEmpty else { return "no samples" }
        let sorted = self.sorted()
        let p95 = sorted[Swift.min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return String(format: "mean %.2f · p95 %.2f · max %.2f ms (n=%d)", reduce(0, +) / Double(count) * 1000, p95 * 1000,
                      (sorted.last ?? 0) * 1000, count)
    }
}
