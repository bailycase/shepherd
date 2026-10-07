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
/// one of them. That clear marker alone is not content: a thread with no visible row is blank even
/// when its marker is in view. This waits for things to be quiet, lands on the tail again, and when
/// that was not enough goes the way a reader would: back toward the rows if not
/// even one is in view (a viewport, two, four… at a time), then down a page at a time until the
/// marker is realized, which is where the stack's guesses meet its rows.
///
/// The follower stands aside while this walks the scroll view (`repairing`), so a thread that grew
/// meanwhile (a "Thinking…" line, a streamed chunk) is not followed, and a thread whose marker is
/// back in view looks done to SwiftUI while it rests a few points above its tail with the last row
/// under the composer. A repair is therefore not over until the thread has been seen resting on its
/// tail: the next check measures the scroll view itself, and a shortfall of up to the composer's
/// height is closed by scrolling to the end of the document (`unsettled`, `shortfall`).
///
/// `ThreadTailFlowTests` keeps the OS reproducer with recovery disabled as an intermittent known
/// issue. Guard-enabled tests must always recover; a passing disabled run does not make recovery
/// unnecessary.
@MainActor
final class ThreadTailGuard {
    /// The scroll targets in view, as SwiftUI last said.
    private(set) var visible: [String] = []
    /// The scroll view is being walked: the follower leaves it alone meanwhile.
    private(set) var repairing = false
    /// Off, the thread is left as the stack leaves it (a test showing what it is for).
    var enabled = true
    /// What the thread's last render knew, read when a check comes due.
    var rowIDs: Set<String> = [] {
        didSet { if rowIDs != oldValue { suspect() } }
    }
    var active = false {
        didSet { if active && !oldValue { suspect() } }
    }
    var following = false
    var userScrolling = false
    /// How far the visible bottom sits above the end of the content, as the scroll view last
    /// reported it (`NativeScrollProbe`).
    var distance = 0.0
    /// The scroll target at the end of the thread, and how to scroll there.
    var bottomID = ""
    var land: () -> Void = {}
    /// Recreates only the transcript scroll view if bounded scrolling cannot realize a row.
    var rebuild: () -> Void = {}
    var scrollView: () -> NSScrollView? = { nil }
    private var check: Task<Void, Never>?
    private var settling = false
    /// A repair has begun and the thread has not been seen resting on its tail since.
    private var unsettled = false
    private var attempts = 0
    private var rebuilt = false
    private var changed = ContinuousClock.now
    private var readerUntil = ContinuousClock.now

    /// How far above its tail a following thread may rest; how long things must be quiet before
    /// a stranded thread counts, and at most how long a busy one is waited for (a thread drawing
    /// nothing, and one that only misses its tail); how long after a reader moves it is left alone;
    /// how long a step waits for rows to be realized; how many steps a walk takes at most; and how
    /// many times in a row the thread is put back before it is left as it is.
    nonisolated static let band = NativeScrollFollower.threshold
    /// How far short of its tail a repaired thread may rest: the follower's own tolerance.
    nonisolated static let slack = NativeScrollFollower.repinSlack
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
        rebuilt = false
        following = true
        suspect()
    }

    /// A completed turn gets a fresh bounded repair, without changing the reader's position.
    func turnFinished() {
        attempts = 0
        rebuilt = false
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

    private var hasRows: Bool { !rowIDs.isEmpty }
    private var tailInView: Bool { visible.contains(bottomID) }
    /// Completion can evict the live turn's prompt from the history page and replace its reply ID.
    /// A cached target for that old reply is no more evidence of content than the clear marker.
    private var rowsInView: Bool { !rowIDs.isDisjoint(with: visible) }

    /// No content in view, the tail missing from it while the thread follows it from afar, or a
    /// thread that was just repaired resting short of its end.
    private var strayed: Bool { !rowsInView || (following && !tailInView && distance > Self.band) || shortOfTheTail }

    /// A repaired, following thread whose marker is in view and that rests short of the end of its
    /// document (`shortfall`).
    private var shortOfTheTail: Bool {
        guard unsettled, following, tailInView, let scroll = scrollView() else { return false }
        return shortfall(of: scroll) != nil
    }

    /// How far the visible bottom sits above the end of the document, by AppKit: what SwiftUI's
    /// reading (`distance`) says once the layout has settled.
    private func endDistance(of scroll: NSScrollView) -> Double? {
        guard let document = scroll.documentView else { return nil }
        let clip = scroll.contentView
        return Double(document.bounds.height - (clip.bounds.origin.y + clip.bounds.height - scroll.contentInsets.bottom))
    }

    /// How far a view whose marker is in view rests above the end of its document, when that is the
    /// last row under the composer: more than `slack`, and no more than the composer's inset, which
    /// is as far above its end as the marker stays in view. Farther than that the marker is out of
    /// view and the guard's walk is the cure; and past the end of the rows the stack placed the
    /// document's end is not where the rows end, so it is not a place to scroll to.
    private func shortfall(of scroll: NSScrollView) -> Double? {
        guard let gap = endDistance(of: scroll), gap > Self.slack, gap <= Double(scroll.contentInsets.bottom) else { return nil }
        return gap
    }

    /// A reading that might leave the thread strayed (the geometry changed, rows arrived, the
    /// visible rows changed): look again when things are quiet if it is.
    func suspect(quiet wait: Duration = ThreadTailGuard.quiet) {
        changed = .now
        guard enabled, hasRows, active, !settling else { return }
        guard strayed else {
            attempts = 0
            unsettled = false
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
                let waitedLongEnough = now - started >= (self.rowsInView ? Self.busy : Self.blankBusy)
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
        unsettled = true
        attempts += 1
        defer {
            settling = false
            // A collapsed lazy layout can report a fitting document with no realized rows.
            // There is then nowhere to scroll. Rebuild once, without replacing the composer.
            if attempts == Self.maxAttempts, !rebuilt, !rowsInView, following, active,
               !userScrolling, ContinuousClock.now >= readerUntil {
                rebuilt = true
                rebuild()
            }
            suspect(quiet: Self.recheck)
        }
        NWRenderProbe.tick("thread.tailRepair")
        if !rowsInView { await walk(by: -1, until: { self.rowsInView }, doubling: true) }
        guard following else { return }
        // A cached clear marker is not a landing if the walk found no content.
        if rowsInView && tailInView {
            reachTheEnd()
            return
        }
        if attempts > 1 || !rowsInView { await walk(by: 1, until: { self.tailInView }, doubling: false) }
        if following, !userScrolling, active, ContinuousClock.now >= readerUntil { land() }
    }

    /// Scrolls the rest of the way to the end of the document, from where the marker is already in
    /// view. `land` would aim at the end the stack believes in, and undo a landing that was exact.
    private func reachTheEnd() {
        guard !userScrolling, active, ContinuousClock.now >= readerUntil, let scroll = scrollView(),
              let gap = shortfall(of: scroll) else { return }
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y += gap
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
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
            if direction > 0, !rowsInView { return }
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
