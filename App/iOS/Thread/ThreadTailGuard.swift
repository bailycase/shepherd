import SwiftUI
import UIKit
import ShepherdRemote
import ShepherdUI

/// Gets a following transcript out of a stranded scroll position.
///
/// After a width change (the side pane docking, a rotation) iOS 27.0's lazy stack can leave the view at an offset its numbers
/// call the tail but that lies past every row the stack placed. Nothing is realized there, so nothing lays out again and the
/// transcript draws nothing until the reader drags. The scroll view's numbers do not show it, and SwiftUI's visibility reports
/// cache rows after they leave the screen, so each built row carries a native marker: a following transcript with no marker in
/// view is stranded. The guard waits for quiet, then goes the way a reader would: back toward the rows, a page and then two and
/// four at a time, until one is realized, then down a page at a time to the end, and lands on the tail again. The Mac's
/// `ThreadTailGuard` is the same idea over an `NSScrollView`.
///
/// A repair is not over until the view has been seen resting on its tail, so while one is under way a view that rests well
/// short of it is walked down and landed again. Outside a repair a view that rests short of the tail is the reader's, however
/// it got there. The guard acts only on a transcript that follows its tail and that nobody touches, a bounded number of
/// times in a row, and rests between runs of attempts, so a transcript that stays stranded for another reason is never chased
/// in a burst.
@MainActor
final class ThreadTailGuard {
    /// What the transcript knows when a check comes due.
    struct Status {
        var following: Bool
        var hasRows: Bool
        /// What the transcript leaves below its bottom marker: a view that rests there is on its tail.
        var tailGap: CGFloat
    }

    private let markers = NSHashTable<UIView>.weakObjects()
    private weak var finder: UIView?
    private var status: () -> Status = { Status(following: false, hasRows: false, tailGap: 0) }
    private var land: () -> Void = {}
    private var standAside: (Bool) -> Void = { _ in }
    private var lastReading = ContinuousClock.now
    private var check: Task<Void, Never>?
    private var attempts = 0
    /// A repair has begun and the transcript has not been seen resting on its tail since. Only then does a view that rests short
    /// of its tail count as stranded: a reader who scrolled up without a finger (VoiceOver's scroll) is not put back.
    private var unsettled = false
    /// A walk is under way: a check that comes due meanwhile has nothing to add, the walk ends by scheduling one.
    private var walking = false
    /// Bumped when the transcript leaves the screen. A walk that began before ends at its next await without touching anything:
    /// the transcript may have come back and started a walk of its own.
    private var generation = 0

    func register(_ marker: UIView) { markers.add(marker) }

    func find(_ view: UIView) { finder = view }

    /// A scroll-geometry reading: look again once things are quiet.
    /// `standAside` tells the pin that lands the transcript to stop while a walk is under way.
    func suspect(standAside: @escaping (Bool) -> Void, status: @escaping () -> Status, land: @escaping () -> Void) {
        self.standAside = standAside
        self.status = status
        self.land = land
        lastReading = .now
        guard status().following else { return }
        scheduleCheck()
    }

    /// The transcript left the screen.
    func stop() {
        generation += 1
        check?.cancel()
        check = nil
        attempts = 0
        unsettled = false
        walking = false
        standAside(false)
        standAside = { _ in }
        status = { Status(following: false, hasRows: false, tailGap: 0) }
        land = {}
    }

    private var scrollView: UIScrollView? { finder?.enclosingScrollView }

    /// One task waits out the quiet: it sleeps until `tailGuardQuiet` has passed since the last reading, wakes to find a later one
    /// moved the time, and sleeps again, so a transcript that keeps scrolling costs no task per frame.
    private func scheduleCheck() {
        guard check == nil else { return }
        check = Task { @MainActor [weak self] in
            while let due = self?.lastReading.advanced(by: MobileLayout.tailGuardQuiet), due > .now {
                try? await Task.sleep(until: due, clock: .continuous)
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let self else { return }
            check = nil
            await settle()
        }
    }

    private func settle() async {
        guard !walking else { return }
        let state = status()
        // A transcript with no room to show a row (the pane alone at no width) has nothing to repair.
        guard let scroll = scrollView, scroll.window != nil, page > MobileLayout.tailGuardMinimumPage, state.following, state.hasRows,
              !moving(scroll) else {
            attempts = 0
            unsettled = false
            return
        }
        let blank = !rowsInView(scroll)
        guard blank || (unsettled && shortOfTail(scroll, gap: state.tailGap)) else {
            // Rows in view, and the tail too if a repair was under way: nothing left to do.
            attempts = 0
            unsettled = false
            return
        }
        guard attempts < MobileLayout.tailGuardAttempts else {
            // Out of attempts and still stranded: rest, then one more try (never a burst).
            attempts = MobileLayout.tailGuardAttempts - 1
            check = Task { @MainActor [weak self] in
                try? await Task.sleep(for: MobileLayout.tailGuardRest)
                guard !Task.isCancelled, let self else { return }
                check = nil
                await settle()
            }
            return
        }
        attempts += 1
        unsettled = true
        SHRenderProbe.tick("thread.tailRepair")
        standAside(true)
        walking = true
        let run = generation
        // Rows in view but the tail not: landing again may be all it takes; a second time, walk down to it.
        if blank { await walkBack(scroll, run: run) }
        if blank || attempts > 1 { await walkDown(scroll, run: run) }
        guard run == generation else { return }
        walking = false
        standAside(false)
        guard status().following else { return }
        if !moving(scroll) { land() }
        // A repair is judged by the next quiet look.
        lastReading = .now
        scheduleCheck()
    }

    private var page: CGFloat {
        guard let scroll = scrollView else { return 0 }
        let inset = scroll.adjustedContentInset
        return scroll.bounds.height - inset.top - inset.bottom
    }

    /// Whether the walk of generation `run` may go on: the transcript is still the one it began on and still follows its tail.
    private func goesOn(_ run: Int) -> Bool {
        run == generation && status().following
    }

    /// Scrolls a page at a time toward the top, each page twice the last, until a row is realized.
    private func walkBack(_ scroll: UIScrollView, run: Int) async {
        let inset = scroll.adjustedContentInset
        var back = page
        guard back > MobileLayout.tailGuardMinimumPage else { return }
        for _ in 0..<MobileLayout.tailGuardSteps where !rowsInView(scroll) {
            guard goesOn(run), !moving(scroll) else { return }
            let from = scroll.contentOffset.y
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: max(from - back, -inset.top)), animated: false)
            if scroll.contentOffset.y == from { return }
            back *= 2
            try? await Task.sleep(for: MobileLayout.tailGuardStep)
        }
    }

    /// Scrolls a page at a time toward the end of the document, up to the last row the stack placed.
    private func walkDown(_ scroll: UIScrollView, run: Int) async {
        let inset = scroll.adjustedContentInset
        guard page > MobileLayout.tailGuardMinimumPage else { return }
        for _ in 0..<MobileLayout.tailGuardSteps {
            guard goesOn(run), !moving(scroll) else { return }
            let end = max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
            let from = scroll.contentOffset.y
            if from >= end - 1 { return }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(from + page, end)), animated: false)
            try? await Task.sleep(for: MobileLayout.tailGuardStep)
            // Past the last row there is nothing to realize: the walk down is over.
            if !rowsInView(scroll) { return }
        }
    }

    /// A following transcript that rests above its tail by more than the follower's own tolerance: rows are in view, so the
    /// stranded offset is gone, but the repair is not over until the view has been seen on its tail.
    private func shortOfTail(_ scroll: UIScrollView, gap: CGFloat) -> Bool {
        let inset = scroll.adjustedContentInset
        let distance = scroll.contentSize.height + inset.bottom - scroll.contentOffset.y - scroll.bounds.height - gap
        return Double(distance) > NativeScrollFollower.threshold
    }

    /// A finger on the transcript, or its coast: the guard stands aside.
    private func moving(_ scroll: UIScrollView) -> Bool {
        scroll.isTracking || scroll.isDragging || scroll.isDecelerating
    }

    /// Whether a built row shows in the scroll view: placement evidence a cached visibility report cannot give.
    private func rowsInView(_ scroll: UIScrollView) -> Bool {
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        return markers.allObjects.contains { marker in
            guard marker.window != nil, marker.enclosingScrollView === scroll else { return false }
            let frame = marker.convert(marker.bounds, to: scroll)
            return frame.height > 0 && frame.intersects(visible)
        }
    }
}

/// A built row's placement, for `ThreadTailGuard`: a view the size of the row that registers itself.
struct TailRowMarker: UIViewRepresentable {
    let guardian: ThreadTailGuard

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        guardian.register(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}

/// Finds the scroll view the transcript is drawn in from inside its content, where no row has to be built.
struct TailScrollFinder: UIViewRepresentable {
    let guardian: ThreadTailGuard

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        guardian.find(view)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { guardian.find(view) }
}

private extension UIView {
    var enclosingScrollView: UIScrollView? {
        var current = superview
        while let view = current {
            if let scroll = view as? UIScrollView { return scroll }
            current = view.superview
        }
        return nil
    }
}
