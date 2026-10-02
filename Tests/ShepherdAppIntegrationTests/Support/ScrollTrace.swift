import AppKit
import Foundation

/// Every move of a thread's scroll view, as it happens: the clip view's offset, the document's
/// height and the insets, stamped with the time and with what the test was doing. AppKit tells it
/// (the clip view's bounds, the document's frame), a fast timer reads the insets, which post
/// nothing, and a run-loop observer notes what each turn of the main run loop left, which is what
/// Core Animation commits and so the only states a display can show (`drawn`). A test reads from the
/// trace what a reader would call a jump (the view leaving its tail), not just where the view ended.
///
/// The lazy stack's total height takes values thousands of points off inside one layout pass, so a
/// reading of the scroll view taken between passes can show a state no frame ever drew; `drawn` is
/// the trace to judge by, and `frames` (every change) is the one to read when looking for why.
@MainActor
final class ScrollTrace {
    struct Frame: CustomStringConvertible {
        var t: Double
        var offset: CGFloat
        var content: CGFloat
        var viewport: CGFloat
        var insetTop: CGFloat
        var insetBottom: CGFloat
        var source: String
        var step: String
        /// SwiftUI's own word: the bottom marker is in view (nil: not told).
        var tail: Bool?
        /// The tail guard is walking the scroll view.
        var repairing = false

        /// How far the visible bottom sits above the end of the content: 0 at the tail.
        var distance: CGFloat { content - (offset + viewport - insetBottom) }

        var description: String {
            let time = String(format: "%7.1f", t * 1000)
            return "\(time) ms  offset \(fmt(offset))  content \(fmt(content))  viewport \(fmt(viewport))  inset \(fmt(insetTop))/\(fmt(insetBottom))  "
                + "\(fmt(distance)) above the tail  [\(source)] \(step)"
        }

        private func fmt(_ v: CGFloat) -> String { String(Int(v.rounded())) }
    }

    /// Every change of any number, in the order AppKit made it.
    private(set) var frames: [Frame] = []
    /// The scroll view as each turn of the main run loop left it.
    private(set) var drawn: [Frame] = []
    /// What the test is doing; stamped on every frame until it changes.
    private(set) var step = ""
    /// Whether SwiftUI says the thread's bottom marker is in view, and whether the guard is walking the view.
    var probe: () -> (tail: Bool, repairing: Bool)? = { nil }
    private let scroll: NSScrollView
    private var observer: CFRunLoopObserver?
    private var tokens: [NSObjectProtocol] = []
    private var timer: Timer?
    private let started = ContinuousClock.now

    init(_ scroll: NSScrollView) {
        self.scroll = scroll
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        tokens.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture("bounds") }
        })
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            tokens.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture("document") }
            })
        }
        let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture("tick") }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // After Core Animation's own observer (order 2,000,000), so the state it commits is the one read.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.captureDrawn() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        capture("start")
        captureDrawn()
    }

    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        timer?.invalidate()
        timer = nil
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }

    private func reading(_ source: String) -> Frame {
        let clip = scroll.contentView
        let elapsed = ContinuousClock.now - started
        let probed = probe()
        return Frame(t: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                     offset: clip.bounds.origin.y, content: scroll.documentView?.bounds.height ?? 0, viewport: clip.bounds.height,
                     insetTop: scroll.contentInsets.top, insetBottom: scroll.contentInsets.bottom, source: source, step: step,
                     tail: probed?.tail, repairing: probed?.repairing ?? false)
    }

    private func same(_ a: Frame, _ b: Frame) -> Bool {
        a.offset == b.offset && a.content == b.content && a.viewport == b.viewport && a.insetTop == b.insetTop && a.insetBottom == b.insetBottom
            && a.step == b.step && a.tail == b.tail && a.repairing == b.repairing
    }

    private func captureDrawn() {
        let frame = reading("loop")
        if let last = drawn.last, same(last, frame) { return }
        drawn.append(frame)
    }

    private func capture(_ source: String) {
        let frame = reading(source)
        if let last = frames.last, same(last, frame), source != "mark" { return }
        frames.append(frame)
    }

    /// Puts a line in the trace at the current state, and stamps what follows with `step`.
    func mark(_ step: String) {
        self.step = step
        capture("mark")
        captureDrawn()
    }

    // MARK: Reading it

    private func drawn(from step: String?) -> ArraySlice<Frame> {
        guard let step else { return drawn[...] }
        guard let start = drawn.firstIndex(where: { $0.step.hasPrefix(step) }) else { return [] }
        return drawn[start...]
    }

    /// How far the view ended from its tail.
    var end: CGFloat { drawn.last?.distance ?? 0 }

    /// A move that took the view away from its tail: the offset fell by more than `limit` between two
    /// drawn frames while the view ended farther from the tail than it began (a view whose content
    /// merely shrank under it is clamped to the end, and is not this).
    struct Retreat: CustomStringConvertible {
        var by: CGFloat
        var farther: CGFloat
        var frame: Frame
        var description: String { "offset -\(Int(by)) (\(Int(farther)) farther from the tail): \(frame)" }
    }

    func retreats(over limit: CGFloat = 40, from step: String? = nil) -> [Retreat] {
        let slice = Array(drawn(from: step))
        guard slice.count > 1 else { return [] }
        return (1..<slice.count).compactMap { i in
            let up = slice[i - 1].offset - slice[i].offset
            let farther = slice[i].distance - slice[i - 1].distance
            return up > limit && farther > limit ? Retreat(by: up, farther: farther, frame: slice[i]) : nil
        }
    }

    /// The largest distance from the tail in the drawn frames from `step` on.
    func worstDistance(from step: String? = nil) -> CGFloat {
        drawn(from: step).map(\.distance).max() ?? 0
    }

    /// How long, in seconds, the view stood more than `band` above its tail in the drawn frames from
    /// `step` on (each frame counted until the next one).
    func secondsAwayFromTheTail(band: CGFloat = 80, from step: String? = nil) -> Double {
        let slice = Array(drawn(from: step))
        guard slice.count > 1 else { return 0 }
        return (0..<(slice.count - 1)).filter { slice[$0].distance > band }.reduce(0) { $0 + slice[$1 + 1].t - slice[$1].t }
    }

    /// How long, in seconds, the numbers called the view the tail (within `band`) while SwiftUI said the
    /// bottom marker was not in view and the guard was not walking it: the thread rests on rows that are
    /// not its end, and nothing in its own numbers says so. Needs `probe`.
    func secondsOnThePhantomTail(band: CGFloat = 80, from step: String? = nil) -> Double {
        let slice = Array(drawn(from: step))
        guard slice.count > 1 else { return 0 }
        return (0..<(slice.count - 1)).filter {
            slice[$0].tail == false && !slice[$0].repairing && slice[$0].distance <= band && slice[$0].distance >= -2
        }.reduce(0) { $0 + slice[$1 + 1].t - slice[$1].t }
    }

    /// The trace as lines, for a failure message: every drawn frame (`allFrames` false) or every change.
    func report(from step: String? = nil, limit: Int = 60, allFrames: Bool = false) -> String {
        let source: [Frame]
        if allFrames {
            source = step.flatMap { name in frames.firstIndex(where: { $0.step.hasPrefix(name) }).map { Array(frames[$0...]) } } ?? frames
        } else {
            source = Array(drawn(from: step))
        }
        return source.prefix(limit).map(\.description).joined(separator: "\n") + (source.count > limit ? "\n… \(source.count - limit) more" : "")
    }
}
