import AppKit
import QuartzCore
import SwiftUI

/// Frames of an off-screen window captured while a change animates. SwiftUI keeps animating in
/// a window that is on no screen (its display link still ticks and `cacheDisplay` draws the
/// current frame), so a test can watch motion without showing a window or taking focus.
///
/// Record a thin strip across what moves (a row of pixels through a pane, a column through a
/// disclosure), then compare frames with `before` and `settled`:
///
/// ```swift
/// let recording = await MotionProbe.record(window, region: strip) { model.open = true }
/// #expect(!recording.inBetween.isEmpty)                       // it animated
/// let edges = recording.inBetween.compactMap { $0.firstColumn(differingFrom: recording.before) }
/// ```
@MainActor
struct MotionRecording {
    struct Frame {
        /// Seconds since the change.
        let time: TimeInterval
        let bitmap: NSBitmapImageRep

        func matches(_ other: Frame) -> Bool {
            guard sameShape(other), let a = bitmap.bitmapData, let b = other.bitmap.bitmapData else { return false }
            return memcmp(a, b, bitmap.bytesPerPlane) == 0
        }

        /// The first column, from the left, where this frame differs from `other` in any row:
        /// in a strip across a pane opening from the trailing edge, the pane's leading edge so
        /// far. Nil when the frames match.
        func firstColumn(differingFrom other: Frame) -> Int? {
            (0..<bitmap.pixelsWide).first { x in (0..<bitmap.pixelsHigh).contains { y in !pixel(x, y, equals: other) } }
        }

        /// The last column where this frame differs from `other` (a pane from the leading edge).
        func lastColumn(differingFrom other: Frame) -> Int? {
            (0..<bitmap.pixelsWide).reversed().first { x in (0..<bitmap.pixelsHigh).contains { y in !pixel(x, y, equals: other) } }
        }

        /// The first row, from the top, where this frame differs from `other`.
        func firstRow(differingFrom other: Frame) -> Int? {
            (0..<bitmap.pixelsHigh).first { y in (0..<bitmap.pixelsWide).contains { x in !pixel(x, y, equals: other) } }
        }

        /// The last row where this frame differs from `other`: in a column through an expanding
        /// disclosure, how far its content reaches so far.
        func lastRow(differingFrom other: Frame) -> Int? {
            (0..<bitmap.pixelsHigh).reversed().first { y in (0..<bitmap.pixelsWide).contains { x in !pixel(x, y, equals: other) } }
        }

        /// 0 (black) … 1 (white): the pixel's mean component, composited over white.
        func lightness(x: Int, y: Int = 0) -> Double {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1 }
            let alpha = Double(color.alphaComponent)
            return Double(color.redComponent + color.greenComponent + color.blueComponent) / 3 * alpha + (1 - alpha)
        }

        private func sameShape(_ other: Frame) -> Bool {
            bitmap.pixelsWide == other.bitmap.pixelsWide && bitmap.pixelsHigh == other.bitmap.pixelsHigh
                && bitmap.bytesPerRow == other.bitmap.bytesPerRow && bitmap.bitsPerPixel == other.bitmap.bitsPerPixel
        }

        private func pixel(_ x: Int, _ y: Int, equals other: Frame) -> Bool {
            guard sameShape(other), let a = bitmap.bitmapData, let b = other.bitmap.bitmapData else { return false }
            let size = bitmap.bitsPerPixel / 8
            let offset = y * bitmap.bytesPerRow + x * size
            return memcmp(a + offset, b + offset, size) == 0
        }
    }

    /// The first frame is the state before the change; the last is the settled state.
    let frames: [Frame]
    var before: Frame { frames[0] }
    var settled: Frame { frames[frames.count - 1] }

    /// Frames caught between the two states: they differ from both ends. Empty when the change
    /// applied at once.
    var inBetween: [Frame] {
        frames.dropFirst().dropLast().filter { !$0.matches(before) && !$0.matches(settled) }
    }
}

@MainActor
enum MotionProbe {
    /// Captures `region` of the window's content (all of it when nil) before `change`, then
    /// every few milliseconds until the picture has changed and held still for `stillFrames`
    /// captures, or `timeout` passes. `change` runs outside any animation, as a view model's
    /// mutation does: the view under test must attach its own motion (`nwAnimation`,
    /// `nwTransition`). Wrap `change` in `withNWAnimation` to test an action-driven change.
    ///
    /// Keep the region thin: every capture draws it.
    static func record(_ window: OffscreenWindow, region: CGRect? = nil, stillFrames: Int = 12,
                       timeout: TimeInterval = 5, change: () -> Void) async -> MotionRecording {
        window.layout()
        let rect = region ?? window.host.bounds
        let start = CACurrentMediaTime()
        var frames = [capture(window.host, rect, at: 0)]
        change()
        var still = 0
        var changed = false
        while CACurrentMediaTime() - start < timeout {
            try? await Task.sleep(for: .milliseconds(4))
            let frame = capture(window.host, rect, at: CACurrentMediaTime() - start)
            if frame.matches(frames[frames.count - 1]) {
                still += 1
            } else {
                still = 0
                changed = true
            }
            frames.append(frame)
            if changed, still >= stillFrames { break }
        }
        return MotionRecording(frames: frames)
    }

    private static func capture(_ view: NSView, _ rect: CGRect, at time: TimeInterval) -> MotionRecording.Frame {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: rect)!
        view.cacheDisplay(in: rect, to: bitmap)
        return MotionRecording.Frame(time: time, bitmap: bitmap)
    }
}
