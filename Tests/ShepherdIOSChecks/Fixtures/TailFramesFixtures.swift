import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension FixtureCatalog {
    static var tailFrames: [FixtureScreen] {
        [FixtureScreen(name: "tail-frames", hosts: TailFrames.hosts(), routes: [.thread(FixtureData.ref(FixtureData.preview))],
                       prepare: TailFrames.run)]
    }
}

/// "tail-frames": where the following thread's tail sits against the composer on every display
/// frame, through what moves the viewport: the keyboard rising and falling, the composer growing
/// and shrinking under a long draft, a question card joining, folding, opening and leaving, the
/// side pane opening and closing, and the thread mounting again. The landing comes after the
/// layout that asked for it and outside its animation; this is what that costs on screen.
///
/// Each phase prints how many frames the tail sat lower than at rest (behind the composer) and
/// higher (a gap open above it), against the composer's drawn background and against the scroll
/// view's bottom inset, and the first frames away from rest. A question card's and the pane's
/// frames measure the card's layers and a lazy stack's estimates too: read them against the other
/// build's. It reports and never fails: run it on two builds and compare the lines, with `-p`
/// products of one tree and, for the baseline, the merge base's `ThreadScreen.swift` in place of
/// the pin (the PR records both).
@MainActor
enum TailFrames {
    /// A gap this small is the tail resting; more is a frame drawn away from it.
    static let rest: CGFloat = 2
    static let cycles = 3
    /// The thread's host answers by stage: 0 plain, 1 with a question for the agent, 2 plain again.
    private nonisolated static let stage = Stage()

    static func hosts() -> [FixtureHostData] {
        var hosts = TailFixture.hosts()
        let earlier = hosts[0].reply
        hosts[0].reply = { request in
            guard case .nativeThread(let id, let agentID, .snapshot(_, _, let after)) = request, agentID == FixtureData.preview else {
                return earlier?(request)
            }
            let snapshot = stage.snapshot
            if after == snapshot.revision {
                return .nativeThread(id: id, result: .unchanged(piSessionID: snapshot.piSessionID, generation: snapshot.generation,
                                                                revision: snapshot.revision))
            }
            return .nativeThread(id: id, result: .snapshot(value: snapshot))
        }
        return hosts
    }

    private final class Stage: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        private lazy var snapshots: [NativeThreadSnapshot] = (0...2).map { stage in
            var snapshot = TailFixture.thread()
            if stage == 1 {
                snapshot.dialogs = [NativeThreadDialog(id: "d-tail", kind: .select, title: "Where should the relay publish?",
                                                       options: ["Straight to the broker (Recommended)\nOne hop, and the outbox keeps the order.",
                                                                 "Through a staging topic\nA second consumer can replay it first."])]
            }
            snapshot.revision = UInt64(stage + 2)
            return snapshot
        }
        func advance() { lock.withLock { value += 1 } }
        var snapshot: NativeThreadSnapshot { lock.withLock { snapshots[value] } }
    }

    static func run(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        await FixtureWindows.wait("the long thread", seconds: 20) { store.rows.count > 150 && FollowFixture.threadScrollView() != nil }
        try? await Task.sleep(for: .seconds(2))
        let draft = (1...8).map { "Line \($0) of a long message to the agent" }.joined(separator: "\n")
        await measure("idle") { await pause(0.5) }
        for cycle in 1...cycles {
            await measure("keyboard rises (\(cycle))") { FollowFixture.focusComposer(); await pause(1.5) }
            await measure("keyboard falls (\(cycle))") { FollowFixture.composerField()?.resignFirstResponder(); await pause(1.5) }
            await measure("composer grows to 8 lines (\(cycle))") { store.draft = draft; await pause(1.2) }
            await measure("composer shrinks (\(cycle))") { store.draft = ""; await pause(1.2) }
        }
        // The agent asks a question: its card joins the composer, folds to a line and opens again as
        // the reader asks it to (an animated change to what sits above the field), then leaves.
        await measure("question card joins") {
            stage.advance()
            await FixtureWindows.wait("the question", seconds: 15) { store.dialogs.first != nil }
            await pause(1.5)
        }
        if let session = store.session, let dialog = store.dialogs.first {
            let key = session.key + ":" + dialog.id
            let hiding = ComposerStates.shared.state(for: ref)
            for cycle in 1...cycles {
                await measure("question card folds (\(cycle))") { withSHAnimation(.disclosure) { hiding.questionHiding.hide(key) }; await pause(1.2) }
                await measure("question card opens (\(cycle))") { withSHAnimation(.disclosure) { hiding.questionHiding.show() }; await pause(1.2) }
            }
        } else {
            FixtureCheck.report("FIXTURE CHECK ok: no question card to fold")
        }
        await measure("question card leaves") {
            stage.advance()
            await FixtureWindows.wait("the question to go", seconds: 15) { store.dialogs.isEmpty }
            await pause(1.5)
        }
        // Where the side pane docks, toggling it mounts the transcript again; elsewhere the thread
        // leaves the screen and comes back.
        guard FollowFixture.threadScrollView()?.traitCollection.horizontalSizeClass == .regular else {
            for cycle in 1...cycles {
                app.navigator.popToRoot()
                await FixtureWindows.wait("the thread to leave", seconds: 3) { FollowFixture.threadScrollView() == nil }
                await measure("thread mounts again (\(cycle))") {
                    app.navigator.open(.thread(ref))
                    await pause(2)
                }
            }
            return
        }
        for toggle in 1...(2 * cycles) {
            let word = app.navigator.sidePane.isOpen ? "closes" : "opens"
            await measure("pane \(word) (\(toggle))") {
                withSHAnimation(.pane) { app.navigator.sidePane.isOpen.toggle() }
                await pause(1.8)
            }
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The tail's resting distance above the composer's top, from the first measure (idle).
    private static var reference: CGFloat?
    private static var insetReference: CGFloat?

    private static func measure(_ what: String, _ action: () async -> Void) async {
        let recorder = Recorder()
        recorder.start()
        await action()
        FixtureCheck.report("FIXTURE CHECK ok: \(what): \(recorder.stop())")
    }

    /// Reads the thread's scroll view and the composer's layers on every display frame.
    @MainActor private final class Recorder {
        /// What one frame showed, in points, as drawn (the presentation layers).
        struct Frame {
            /// The tail marker (the bottom of the transcript's last row and the gap under it, where a
            /// landing leaves the view), and the composer's top edge: the layer that draws it, and what
            /// the scroll view's bottom inset says. nil: the layers did not name a composer this frame.
            var marker: CGFloat
            var layer: CGFloat?
            var inset: CGFloat
        }

        private var frames: [Frame?] = []
        private var link: CADisplayLink?
        private var scroll: UIScrollView?
        private var keyboards = 0
        private var observer: NSObjectProtocol?

        func start() {
            let ticker = Ticker { [weak self] in self?.tick() }
            let link = CADisplayLink(target: ticker, selector: #selector(Ticker.fire))
            link.add(to: .main, forMode: .common)
            self.link = link
            observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboards += 1 }
            }
        }

        private func tick() {
            if scroll?.window == nil { scroll = FollowFixture.threadScrollView() }
            guard let scroll else { return frames.append(nil) }
            let regular = scroll.traitCollection.horizontalSizeClass == .regular
            let gutter = regular ? MobileLayout.padThreadGutter : MobileLayout.gutter
            let area = Self.frame(of: scroll)
            let marker = Self.shown(CGPoint(x: 0, y: scroll.contentSize.height - gutter), in: scroll.layer).y
            let layer = Self.composer(below: scroll, area: area).map { Self.shown(CGPoint(x: 0, y: $0.bounds.minY), in: $0).y }
            frames.append(Frame(marker: marker, layer: layer, inset: area.maxY - scroll.adjustedContentInset.bottom))
        }

        /// The scroll view's frame as drawn: its top-left is where the layer's bounds origin (the
        /// scroll offset, which may be mid-animation) lands.
        private static func frame(of scroll: UIScrollView) -> CGRect {
            let drawn = scroll.layer.presentation() ?? scroll.layer
            return CGRect(origin: shown(drawn.bounds.origin, in: scroll.layer), size: scroll.bounds.size)
        }

        private static func candidates(in scroll: UIScrollView, area: CGRect) -> [(layer: CALayer, frame: CGRect)] {
            guard let window = scroll.window else { return [] }
            var found: [(layer: CALayer, frame: CGRect)] = []
            func walk(_ layer: CALayer) {
                if layer.delegate is UIScrollView { return }
                if layer.backgroundColor != nil, layer.delegate.map({ String(describing: type(of: $0)).contains("SwiftUILayerDelegate") }) == true {
                    let frame = shown(layer.bounds, in: layer)
                    if frame.width >= area.width * 0.9, frame.height > 40, frame.height < area.height * 0.85, frame.minY > area.minY + 8 {
                        found.append((layer, frame))
                    }
                }
                layer.sublayers?.forEach(walk)
            }
            walk(window.layer)
            return found
        }

        /// The composer's background. The composer draws it twice at one frame (its own and the thread's
        /// around the inset), where a question card's has no twin and reaches past the screen's edge;
        /// the bottom-most such pair, else the bottom-most of the rest.
        private static func composer(below scroll: UIScrollView, area: CGRect) -> CALayer? {
            let found = candidates(in: scroll, area: area)
            func twins(_ candidate: (layer: CALayer, frame: CGRect)) -> Bool {
                found.filter { abs($0.frame.minY - candidate.frame.minY) < 0.5 && abs($0.frame.maxY - candidate.frame.maxY) < 0.5 }.count > 1
            }
            func lowest(_ list: [(layer: CALayer, frame: CGRect)]) -> CALayer? {
                list.max { ($0.frame.maxY, $0.frame.height) < ($1.frame.maxY, $1.frame.height) }?.layer
            }
            return lowest(found.filter(twins)) ?? lowest(found)
        }

        /// A rect in `layer`'s coordinates, in the root layer's as drawn: every layer's presentation
        /// geometry on the way up (positions and scroll offsets mid-animation included).
        private static func shown(_ rect: CGRect, in layer: CALayer) -> CGRect {
            CGRect(origin: shown(rect.origin, in: layer), size: rect.size)
        }

        private static func shown(_ point: CGPoint, in layer: CALayer) -> CGPoint {
            var point = point
            var current: CALayer? = layer
            while let each = current {
                let drawn = each.presentation() ?? each
                let anchor = CGPoint(x: drawn.bounds.origin.x + drawn.anchorPoint.x * drawn.bounds.width,
                                     y: drawn.bounds.origin.y + drawn.anchorPoint.y * drawn.bounds.height)
                point = CGPoint(x: drawn.position.x + point.x - anchor.x, y: drawn.position.y + point.y - anchor.y)
                current = each.superlayer
            }
            return point
        }

        func stop() -> String {
            link?.invalidate()
            link = nil
            observer.map(NotificationCenter.default.removeObserver)
            let seen = frames.compactMap { $0 }
            guard !seen.isEmpty else { return "no thread on screen in \(frames.count) frames" }
            let layer = seen.map { frame in frame.layer.map { $0 - frame.marker } }
            let inset = seen.map { $0.inset - $0.marker }
            // The first measure (idle) names where the tail rests above the composer.
            if TailFrames.reference == nil { TailFrames.reference = Self.median(layer.compactMap { $0 }) }
            if TailFrames.insetReference == nil { TailFrames.insetReference = Self.median(inset) }
            let blank = frames.count - seen.count, unnamed = layer.filter { $0 == nil }.count
            return "\(frames.count) frames, \(keyboards) keyboard events"
                + "; against the composer layer: \(Self.summary(layer, reference: TailFrames.reference))"
                + "; against the inset: \(Self.summary(inset, reference: TailFrames.insetReference))"
                + (blank > 0 ? ", \(blank) with no thread" : "") + (unnamed > 0 ? ", \(unnamed) with no composer layer" : "")
                + "; off frames \(Self.offFrames(layer, reference: TailFrames.reference))"
        }

        private static func median(_ values: [CGFloat]) -> CGFloat? {
            values.isEmpty ? nil : values.sorted()[values.count / 2]
        }

        /// The frames away from rest, in points and in order, as far as the first 16.
        private static func offFrames(_ gaps: [CGFloat?], reference: CGFloat?) -> [Int] {
            guard let reference else { return [] }
            return Array(gaps.compactMap { $0.map { reference - $0 } }.filter { abs($0) > TailFrames.rest }.prefix(16).map { Int($0.rounded()) })
        }

        /// Positive: the tail sits lower than at rest, behind the composer; negative: higher, a gap
        /// opens between the transcript and the composer.
        private static func summary(_ gaps: [CGFloat?], reference: CGFloat?) -> String {
            guard let reference else { return "no composer" }
            let off = gaps.compactMap { $0.map { reference - $0 } }
            func part(_ keep: (CGFloat) -> Bool) -> String {
                var count = 0, longest = 0, run = 0
                for value in off {
                    if keep(value) { count += 1; run += 1; longest = max(longest, run) } else { run = 0 }
                }
                let worst = Int((off.filter(keep).max { abs($0) < abs($1) } ?? 0).rounded())
                return "\(count) (worst \(worst)pt, longest run \(longest))"
            }
            return "behind \(part { $0 > TailFrames.rest }), short \(part { $0 < -TailFrames.rest }), ends \(Int((off.last ?? 0).rounded()))pt from rest"
        }
    }

    private final class Ticker: NSObject {
        let tick: () -> Void
        init(_ tick: @escaping () -> Void) { self.tick = tick }
        @objc func fire() { tick() }
    }
}
