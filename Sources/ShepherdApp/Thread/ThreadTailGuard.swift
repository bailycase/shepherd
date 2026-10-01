import AppKit
import ShepherdRemote
import ShepherdUI
import SwiftUI

/// Keeps a following thread on its tail, and gets it out of a stranded scroll position.
///
/// The thread's lazy stack knows the height of the rows it has measured and guesses the rest, and
/// its total, the offset a `scrollTo` lands on, and the rows it places are each read from those
/// guesses at a different moment. Over rows that differ a lot in height (a long answer, a turn of
/// a hundred tool calls) the guesses move by hundreds to thousands of points as rows are realized
/// and forgotten, under a view that follows its tail: a turn settling into its footer, the composer
/// or the terminal panel resizing, and a long history opening all do it. Two things happen:
///
/// - The view comes to rest short of the tail, and nothing lays out again, so it stays there
///   (`scrollTo` aimed at the end it believed in).
/// - The view ends at an offset the geometry calls the tail but that lies past every row the stack
///   placed. Nothing is realized there, so nothing lays out again either, and the thread draws
///   nothing until the reader scrolls hundreds of points up, which a thread that keeps following
///   will not let them do.
///
/// Neither shows in the scroll view's numbers. SwiftUI says which rows are in view, though
/// (`onScrollTargetVisibilityChange`), and while the thread follows its tail the bottom marker is
/// one of them. This waits for things to be quiet and the marker to be missing, lands on the tail
/// again, and when that was not enough goes the way a reader would: back toward the rows if not
/// even one is in view (a viewport, two, four… at a time), then down a page at a time until the
/// marker is realized, which is where the stack's guesses meet its rows.
///
/// A workaround for the stack, not a feature: `ThreadTailFlowTests` keeps the case it stands on
/// (with it switched off) as a known issue, so the test says when SwiftUI no longer needs it.
@MainActor
final class ThreadTailGuard {
    /// The scroll targets in view, as SwiftUI last said.
    private(set) var visible: [String] = []
    /// The scroll view is being walked: the follower leaves it alone meanwhile.
    private(set) var repairing = false
    /// Off, the thread is left as the stack leaves it (a test showing what it is for).
    var enabled = true
    /// What the thread's last render knew, read when a check comes due.
    var hasRows = false
    var active = false
    var following = false
    var userScrolling = false
    /// How far the visible bottom sits above the end of the content, as the scroll view last
    /// reported it (`NativeScrollProbe`).
    var distance = 0.0
    /// The scroll target at the end of the thread, and how to scroll there.
    var bottomID = ""
    var land: () -> Void = {}
    var scrollView: () -> NSScrollView? = { nil }
    private var check: Task<Void, Never>?
    private var settling = false
    private var attempts = 0
    private var changed = ContinuousClock.now
    private var readerUntil = ContinuousClock.now

    /// How far above its tail a following thread may rest; how long things must be quiet before
    /// a stranded thread counts, and at most how long a busy one is waited for (a thread drawing
    /// nothing, and one that only misses its tail); how long after a reader moves it is left alone;
    /// how long a step waits for rows to be realized; how many steps a walk takes at most; and how
    /// many times in a row the thread is put back before it is left as it is.
    nonisolated static let band = NativeScrollFollower.threshold
    nonisolated static let quiet: Duration = .milliseconds(80)
    nonisolated static let blankBusy: Duration = .milliseconds(160)
    nonisolated static let busy: Duration = .milliseconds(600)
    nonisolated static let recheck: Duration = .milliseconds(60)
    nonisolated static let hands: Duration = .milliseconds(500)
    nonisolated static let stepWait: Duration = .milliseconds(40)
    nonisolated static let maxSteps = 60
    nonisolated static let maxAttempts = 8

    func targets(_ ids: [String]) {
        visible = ids
        suspect()
    }

    /// The reader asked for the tail (a send, the jump pill): put it back as often as it takes.
    func asked() {
        attempts = 0
        following = true
        suspect()
    }

    /// The reader's hands are on the scroll view (a wheel tick, a drag): leave it alone a moment.
    func readerMoved() {
        readerUntil = .now + Self.hands
    }

    /// The thread went away or off screen.
    func stop() {
        check?.cancel()
        check = nil
    }

    private var tailInView: Bool { visible.contains(bottomID) }

    /// Nothing in view, or the tail missing from it while the thread follows it from afar.
    private var strayed: Bool { visible.isEmpty || (following && !tailInView && distance > Self.band) }

    /// A reading that might leave the thread strayed (the geometry changed, rows arrived, the
    /// visible rows changed): look again when things are quiet if it is.
    func suspect(quiet wait: Duration = ThreadTailGuard.quiet) {
        changed = .now
        guard enabled, hasRows, active, !settling else { return }
        guard strayed else {
            attempts = 0
            stop()
            return
        }
        guard check == nil, attempts < Self.maxAttempts else { return }
        let started = ContinuousClock.now
        check = Task { [weak self] in
            // Until things are quiet, or have been busy for long enough: a view that draws nothing
            // is not waited for as long as one that is still finding its tail. Never over a reader.
            while let self {
                let now = ContinuousClock.now
                let waitedLongEnough = now - started >= (self.visible.isEmpty ? Self.blankBusy : Self.busy)
                if now >= self.readerUntil, now - self.changed >= wait || waitedLongEnough { break }
                try? await Task.sleep(for: .milliseconds(20))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.check = nil
            await self.settle()
        }
    }

    private func settle() async {
        guard enabled, hasRows, active, !userScrolling, strayed else { return }
        settling = true
        attempts += 1
        defer {
            settling = false
            suspect(quiet: Self.recheck)
        }
        NWRenderProbe.tick("thread.tailRepair")
        if visible.isEmpty { await walk(by: -1, until: { !self.visible.isEmpty }, doubling: true) }
        guard following, !tailInView else { return }
        if attempts > 1 || visible.isEmpty { await walk(by: 1, until: { self.tailInView }, doubling: false) }
        if following, !userScrolling, active { land() }
    }

    /// Scrolls a page at a time (`direction` -1 is toward the top) until `done`, a reader moves, or
    /// the thread leaves the screen; with `doubling`, each page twice the last.
    private func walk(by direction: CGFloat, until done: () -> Bool, doubling: Bool) async {
        guard let scroll = scrollView(), !repairing else { return }
        let clip = scroll.contentView
        // A scroll view with no room (a layout folded away) has nowhere to go.
        guard clip.bounds.height > 50 else { return }
        repairing = true
        defer { repairing = false }
        var page = clip.bounds.height
        for _ in 0..<Self.maxSteps {
            guard !done(), active, !userScrolling, ContinuousClock.now >= readerUntil, direction < 0 || following,
                  !Task.isCancelled else { return }
            let from = clip.bounds.origin.y
            var bounds = clip.bounds
            bounds.origin.y += direction * (doubling ? page : clip.bounds.height * 0.9)
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
            // At an end of the scroll view there is nowhere further to go.
            if abs(clip.bounds.origin.y - from) < 1 { return }
            try? await Task.sleep(for: Self.stepWait)
            // Past the last row there is nothing to realize: the walk down is over.
            if direction > 0, visible.isEmpty { return }
            if doubling { page *= 2 }
        }
    }
}

/// Finds the scroll view a SwiftUI `ScrollView` is drawn in, from inside its content.
struct ThreadScrollViewFinder: NSViewRepresentable {
    let guardian: ThreadTailGuard

    func makeNSView(context: Context) -> Finder { Finder() }

    func updateNSView(_ view: Finder, context: Context) {
        guardian.scrollView = { [weak view] in view?.enclosingScrollView }
    }

    final class Finder: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
