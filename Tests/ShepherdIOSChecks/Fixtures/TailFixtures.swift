import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

extension FixtureCatalog {
    static var tail: [FixtureScreen] {
        let thread = FixtureData.ref(FixtureData.preview)
        return [
            // The docked side pane opened and closed five times over the long thread, an iPad in landscape or portrait: the
            // transcript draws three seconds after each (it was blank on iOS 27.0 after most opens).
            FixtureScreen(name: "pad-pane-long-reply-ink", hosts: TailFixture.hosts(), routes: [.thread(thread)], prepare: TailFixture.paneInk),
            // An iPad turned to the other orientation and back, three times, over the long thread: it draws at 2 s and 5 s after each turn.
            FixtureScreen(name: "thread-rotate-long-reply", hosts: TailFixture.hosts(), routes: [.thread(thread)], prepare: TailFixture.rotate),
            // Ten flings up through the thread and back to the end of the long thread: its last line above the composer, rows drawn.
            FixtureScreen(name: "thread-flings-rows", hosts: TailFixture.hosts(), routes: [.thread(thread)], prepare: TailFixture.flings),
            // The long thread mounted again (the phone pops it and pushes it back; the iPad opens other threads until it is no longer
            // retained): its first frame with a row is at the tail and drawn, after at most one landing and a few blank frames.
            FixtureScreen(name: "thread-remount-tail", hosts: TailFixture.remountHosts(), routes: [.thread(thread)], prepare: TailFixture.remountTail),
            // A 300 pt drag up from the tail of the 24 KB reply moves the view by the drag and no more: nothing sends it to the reply's top.
            FixtureScreen(name: "thread-detach-in-reply", hosts: TailFixture.hosts(), routes: [.thread(thread)], prepare: TailFixture.detachInReply),
            // A reader who scrolled up past the reply and left comes back to the row they left at the top.
            FixtureScreen(name: "thread-detached-remount", hosts: TailFixture.remountHosts(), routes: [.thread(thread)], prepare: TailFixture.detachedRemount),
        ]
    }
}

/// "duo-pane-long-reply": a following thread whose newest reply is 24 KB, with the side pane
/// opened and closed ten times in a row (`withSHAnimation(.pane)`, as the toolbar button does).
/// Where the pane toggle rebuilds the detail column, the new transcript mounts on the long reply
/// and lands on its tail inside the layout pass; the audit saw that spin the main thread
/// (ios-duo-1). After each toggle it checks that the landings stayed few, at most `inPassLimit` of them
/// ran inside a layout pass (the mount's first ones), the pin did not give up (in a pass or after one),
/// the reply ends above the composer and the transcript draws.
/// A watchdog thread fails the run if the main queue stops answering. Run it posed open on the Duo,
/// or in landscape on an iPad; where there is no side pane it says so.
enum TailFixture {
    static let toggles = 10
    /// Landings with the content moving by itself that one toggle may make: this screen's empirical
    /// ceiling (the merge base lands 22 to 29 times per open; the fix 2 to 6, up to 8 of them in a layout
    /// pass, which count here too). The repin itself guarantees less: a tail that nears on every turn
    /// but never rests lands up to `maxRun` times.
    static let landingCeiling = 2 * NativeTailRepin.limit + 1
    /// A pin lands inside a layout pass at most `inPassLimit` times per mount. Where a toggle remounts the
    /// transcript (the open Duo) that is per toggle; where the pin outlives the toggles (the iPad) it is
    /// per launch.
    static let inPassCeiling = NativeTailRepin.inPassLimit
    /// A drawn transcript is mostly text on a background; a blank one has no ink.
    static let inkFloor = 0.02

    static func hosts() -> [FixtureHostData] {
        ThreadFixtures.hosts(preview: thread())
    }

    /// 150 short turns, then a question and a reply that runs 24 KB.
    static func thread() -> NativeThreadSnapshot {
        typealias F = FixtureData
        var messages: [NativeThreadMessage] = []
        for turn in 0..<150 {
            let at = Double(turn) * 20_000
            messages.append(F.user("t\(turn)u", "Reply with exactly: tail-\(turn)", at: at))
            messages.append(F.assistant("t\(turn)a", "tail-\(turn)", at: at + 2_000))
        }
        messages.append(F.user("lu", "Write up the whole outbox design, section by section.", at: 3_100_000))
        messages.append(F.assistant("la", longReply(cycles: 24), at: 3_110_000))
        return F.snapshot(messages)
    }

    /// About 1 KB of prose, a list and a code block per cycle.
    static func longReply(cycles: Int) -> String {
        let topics = ["queue", "outbox", "ledger", "retry", "lease", "cursor", "batch", "replay"]
        return (1...cycles).map { n in
            let topic = topics[n % topics.count]
            return """
            ## Part \(n): the \(topic) path

            Every message the service sends first lands in the \(topic) table inside the same transaction as the change that caused it, \
            so a crash between the two can never lose one or send one twice. A relay reads the rows in order, hands each to the broker, \
            and marks it sent only after the broker has acknowledged it; a row whose acknowledgement never arrives is read again on the next pass.

            - Keep the \(topic) rows small and append-only.
            - Number them per aggregate so a consumer can drop a duplicate.
            - Delete a row only after every consumer has moved past it.

            ```swift
            func relay\(n)(batch: [Row]) async throws {
                for row in batch { try await broker.send(row.payload, key: row.aggregate) }
            }
            ```
            """
        }.joined(separator: "\n\n")
    }

    @MainActor static func togglePane(_ app: MobileApp) async {
        let navigator = app.navigator
        let ref = FixtureData.ref(FixtureData.preview)
        let store = app.threads.store(for: ref)
        await FixtureWindows.wait("the long thread", seconds: 20) { store.rows.count > 150 && FollowFixture.threadScrollView() != nil }
        try? await Task.sleep(for: .seconds(1.5))
        guard FollowFixture.threadScrollView()?.traitCollection.horizontalSizeClass == .regular else {
            return FixtureCheck.report("FIXTURE CHECK ok: no side pane on this layout")
        }
        MainQueueWatchdog.start(limit: 5)
        // Every toggle is measured before any verdict, so a failing run still shows all ten.
        var measured: [String] = []
        var verdicts: [(ok: Bool, line: String)] = []
        for toggle in 1...toggles {
            SHRenderProbe.start()
            withSHAnimation(.pane) { navigator.sidePane.isOpen.toggle() }
            await settle()
            let counts = SHRenderProbe.stop()
            let content = counts["thread.tailLanding", default: 0]
            let resized = counts["thread.tailLandingResized", default: 0]
            let inPass = counts["thread.tailLandingInPass", default: 0]
            let stalled = counts["thread.tailStalled", default: 0]
            let pane = navigator.sidePane.isOpen ? "open" : "closed"
            let gutter = FollowFixture.threadScrollView()?.traitCollection.horizontalSizeClass == .regular ? MobileLayout.padThreadGutter : MobileLayout.gutter
            // The pin leaves a tail within repinSlack of the marker where it is.
            let tail = FollowFixture.tail { $0 <= gutter + NativeScrollFollower.repinSlack }
            let distance = Int((tail?.distance ?? .infinity).rounded())
            let ink = FollowFixture.transcriptInk()
            let percent = Int((ink * 100).rounded())
            measured.append("toggle \(toggle) (pane \(pane)): \(content) landings with the content moving, \(resized) with the width, \(inPass) in a layout pass, \(stalled) stalls, \(distance)pt above the tail, \(percent)% ink")
            verdicts.append((content <= landingCeiling && stalled == 0, "toggle \(toggle): at most \(landingCeiling) landings with the content moving, none stalled"))
            verdicts.append((inPass <= inPassCeiling, "toggle \(toggle): at most \(inPassCeiling) landings inside a layout pass"))
            verdicts.append((tail?.valid == true, "toggle \(toggle): the reply ends above the composer"))
            verdicts.append((ink >= inkFloor, "toggle \(toggle): the transcript draws"))
        }
        measured.forEach { FixtureCheck.report("FIXTURE CHECK ok: \($0)") }
        let failed = verdicts.filter { !$0.ok }
        if let first = failed.first { FixtureCheck.report("FIXTURE CHECK FAILED: \(failed.count) of \(verdicts.count) checks, the first: \(first.line)") }
        FixtureCheck.report("FIXTURE CHECK ok: \(verdicts.count) checks over \(toggles) toggles")
    }

    /// What the thread shows: the share of its visible rect that is drawn, how far its visible bottom sits above the end of the
    /// content, whether the reply's last line is above the composer (`atTail`), and whether the view is past the end of the
    /// content (`notPastEnd` false: a blank band, whatever the numbers of the rows say).
    struct Reading {
        var ink: Double
        var distance: Int
        var atTail: Bool
        var notPastEnd: Bool
    }

    /// A landing leaves the view at the thread's bottom padding, and the pin counts a view within `repinSlack` of that as at
    /// rest: the same test `duo-pane-long-reply` makes.
    @MainActor static func shown() -> Reading {
        guard let scroll = FollowFixture.threadScrollView(), let tail = FollowFixture.tail({ $0 <= gutter(of: scroll) + NativeScrollFollower.repinSlack }),
              let any = FollowFixture.tail({ _ in true }) else {
            FixtureCheck.fail("the thread has no scroll view")
        }
        return Reading(ink: FollowFixture.transcriptInk(), distance: Int(tail.distance.rounded()), atTail: tail.valid, notPastEnd: any.valid)
    }

    static func gutter(of scroll: UIScrollView) -> CGFloat {
        scroll.traitCollection.horizontalSizeClass == .regular ? MobileLayout.padThreadGutter : MobileLayout.gutter
    }

    /// Waits for the long thread to be on screen with its rows built.
    @MainActor static func ready(_ app: MobileApp) async {
        let store = app.threads.store(for: FixtureData.ref(FixtureData.preview))
        await FixtureWindows.wait("the long thread", seconds: 20) { store.rows.count > 150 && FollowFixture.threadScrollView() != nil }
        try? await Task.sleep(for: .seconds(1.5))
    }

    /// Waits up to `limit` for `holds` of what the thread shows, and returns the last look.
    @MainActor static func shown(within limit: Duration, until holds: (Reading) -> Bool) async -> Reading {
        let clock = ContinuousClock()
        let started = clock.now
        var now = shown()
        while !holds(now), clock.now - started < limit {
            try? await Task.sleep(for: .milliseconds(100))
            now = shown()
        }
        return now
    }

    static let paneCycles = 5
    /// How long after a toggle the pane screen looks, in tenths of a second.
    static let settleTenths = 30
    /// Each round turns to the other orientation and back; three fit the harness's 60 s launch budget.
    static let rotationRounds = 3

    /// "pad-pane-long-reply-ink": the pane opens and closes `paneCycles` times; `settleTenths` tenths of a second after each the
    /// transcript has ink and its reply ends above the composer. Every state is measured before any verdict.
    @MainActor static func paneInk(_ app: MobileApp) async {
        let navigator = app.navigator
        await ready(app)
        guard FollowFixture.threadScrollView()?.traitCollection.horizontalSizeClass == .regular else {
            return FixtureCheck.report("FIXTURE CHECK ok: no side pane on this layout")
        }
        MainQueueWatchdog.start(limit: 5)
        SHRenderProbe.start()
        var blank: [String: Int] = ["open": 0, "closed": 0]
        var stranded: [String: Int] = ["open": 0, "closed": 0]
        for cycle in 1...paneCycles {
            for _ in 1...2 {
                withSHAnimation(.pane) { navigator.sidePane.isOpen.toggle() }
                // One look at the pixels, after the wait: drawing the view while it settles forces layouts that hide the strand.
                // The scroll view's own numbers are read every 100 ms meanwhile, which does not. The guard's repair of a first
                // open over rows nobody has measured takes up to 3 s: the content's estimate collapses from hundreds of thousands
                // of points to the thread's real height while it walks.
                var distances: [Int] = []
                var sizes: [Int] = []
                for _ in 1...settleTenths {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let scroll = FollowFixture.threadScrollView(), let tail = FollowFixture.tail({ _ in true }) {
                        distances.append(Int(tail.distance.rounded()))
                        sizes.append(Int(scroll.contentSize.height.rounded()))
                    }
                }
                let pane = navigator.sidePane.isOpen ? "open" : "closed"
                let now = shown()
                if now.ink < inkFloor { blank[pane, default: 0] += 1 }
                if !now.atTail { stranded[pane, default: 0] += 1 }
                FixtureCheck.report("FIXTURE CHECK ok: cycle \(cycle), pane \(pane): \(Int((now.ink * 100).rounded()))% ink, \(now.distance)pt above the tail")
                if now.ink < inkFloor || !now.atTail {
                    FixtureCheck.report("FIXTURE CHECK ok:   distance from the tail every 100 ms: \(distances); content height: \(sizes)")
                }
            }
        }
        let summary = "blank after \(blank["open", default: 0]) of \(paneCycles) opens and \(blank["closed", default: 0]) of \(paneCycles) closes, "
            + "reply off the composer after \(stranded["open", default: 0]) and \(stranded["closed", default: 0]), "
            + "\(SHRenderProbe.count("thread.tailRepair")) tail repairs"
        let held = blank.values.allSatisfy { $0 == 0 } && stranded.values.allSatisfy { $0 == 0 }
        FixtureCheck.report("FIXTURE CHECK \(held ? "ok" : "FAILED"): the pane's toggles leave the transcript drawn: \(summary)")
    }

    /// "thread-rotate-long-reply": the iPad turns to the other orientation and back, `rotationRounds` times; at 2 s and 5 s after each turn the
    /// transcript has ink and its reply ends above the composer.
    @MainActor static func rotate(_ app: MobileApp) async {
        await ready(app)
        guard UIDevice.current.userInterfaceIdiom == .pad,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return FixtureCheck.report("FIXTURE CHECK ok: only an iPad turns")
        }
        MainQueueWatchdog.start(limit: 5)
        SHRenderProbe.start()
        let wide = scene.effectiveGeometry.interfaceOrientation.isLandscape
        let turns: [(mask: UIInterfaceOrientationMask, name: String)] = wide
            ? [(.portrait, "portrait"), (.landscapeRight, "landscape")]
            : [(.landscapeRight, "landscape"), (.portrait, "portrait")]
        var blank = 0
        var stranded = 0
        var looks = 0
        for round in 1...rotationRounds {
            for turn in turns {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: turn.mask)) { _ in }
                await FixtureWindows.wait("the turn to \(turn.name)", seconds: 5) {
                    turn.mask == .portrait ? scene.effectiveGeometry.interfaceOrientation.isPortrait
                        : scene.effectiveGeometry.interfaceOrientation.isLandscape
                }
                var readings: [String] = []
                for (seconds, wait) in [(2, 2.0), (5, 3.0)] {
                    try? await Task.sleep(for: .seconds(wait))
                    let now = shown()
                    looks += 1
                    if now.ink < inkFloor { blank += 1 }
                    if !now.atTail { stranded += 1 }
                    readings.append("\(Int((now.ink * 100).rounded()))% ink at \(seconds) s (\(now.distance)pt above the tail)")
                }
                FixtureCheck.report("FIXTURE CHECK ok: round \(round), to \(turn.name): \(readings.joined(separator: ", "))")
            }
        }
        let held = blank == 0 && stranded == 0
        FixtureCheck.report("FIXTURE CHECK \(held ? "ok" : "FAILED"): the turns leave the transcript drawn: blank in \(blank) of \(looks) looks, reply off the composer in \(stranded), \(SHRenderProbe.count("thread.tailRepair")) tail repairs")
    }

    static let flingCount = 10

    /// A finger on the thread's scroll view: its pan recognizer stepped through a drag of `distance` points (positive: toward the
    /// end) at 1,600 pt a frame, then let go. The recognizer's translation grows with the drag, as a finger's does, whatever the
    /// scroll view reads of it, as `FollowFixture.jump` does.
    @MainActor struct Finger {
        let scroll: UIScrollView

        var top: CGFloat { -scroll.adjustedContentInset.top }
        var end: CGFloat { max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height) }

        /// `stopWhen` lets go early, as a reader does when what they dragged for has arrived. `frame` is how far the finger goes in
        /// one display frame (a long dive goes faster than a read).
        func drag(by distance: CGFloat, frame: CGFloat = 1_600, stopWhen: () -> Bool = { false }) async {
            let pan = scroll.panGestureRecognizer
            pan.state = .began
            let start = scroll.contentOffset.y
            let target = min(max(start + distance, top), end)
            var frames = 0
            while abs(target - scroll.contentOffset.y) > 1, frames < 80, !stopWhen() {
                let step = min(frame, abs(target - scroll.contentOffset.y)) * (target > scroll.contentOffset.y ? 1 : -1)
                scroll.contentOffset.y += step
                pan.setTranslation(CGPoint(x: 0, y: start - scroll.contentOffset.y), in: scroll)
                pan.state = .changed
                frames += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
            pan.state = .ended
        }

        /// Drags to the end of the thread, up to `tries` tries (the content moves under the finger as the rows are measured).
        func toEnd(tries: Int = 8) async {
            for _ in 1...tries where scroll.contentOffset.y < end - 1 {
                await drag(by: 100_000)
            }
        }

        /// What a reader does: drags to the end, looks, and goes on while the transcript is drawn but the end is not in view
        /// (a lazy stack moves its end under a finger as it measures). A transcript that draws nothing is not gone on from.
        func toEndAndLook() async -> Reading {
            var now = Reading(ink: 0, distance: 0, atTail: false, notPastEnd: false)
            for _ in 1...3 {
                await toEnd()
                now = await TailFixture.shown(within: .seconds(2)) { $0.ink >= TailFixture.inkFloor && $0.atTail }
                if now.atTail || now.ink < TailFixture.inkFloor { break }
            }
            return now
        }
    }

    /// "thread-flings-rows": the reader flings up through the thread by a different depth each time and back down to the end of
    /// it. Within 2 s of each landing at the end the view rests at the tail with the transcript drawn: the reply's last line
    /// above the composer (a phone or the closed Duo drew nothing after some flings). Every fling is measured before the verdict; ten fit the harness's 60 s
    /// launch budget.
    @MainActor static func flings(_ app: MobileApp) async {
        await ready(app)
        guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
        MainQueueWatchdog.start(limit: 5)
        SHRenderProbe.start()
        let finger = Finger(scroll: scroll)
        let clock = ContinuousClock()
        var off = 0
        for fling in 1...flingCount {
            let started = clock.now
            await finger.drag(by: -CGFloat(1 + fling % 5) * 3_000)
            try? await Task.sleep(for: .milliseconds(50))
            let now = await finger.toEndAndLook()
            if now.ink < inkFloor || !now.atTail { off += 1 }
            let took = (clock.now - started).components.seconds
            FixtureCheck.report("FIXTURE CHECK ok: fling \(fling) of \(flingCount): \(Int((now.ink * 100).rounded()))% ink, \(now.distance)pt above the tail"
                + "\(now.notPastEnd ? "" : ", PAST THE END"), in \(took) s")
            fflush(stdout)
        }
        FixtureCheck.report("FIXTURE CHECK \(off == 0 ? "ok" : "FAILED"): \(flingCount) flings end at the tail with the rows drawn: \(off) did not, \(SHRenderProbe.count("thread.tailRepair")) tail repairs")
    }

    /// Waits until 300 ms pass with no landing, no stretch where the main thread was too busy to
    /// answer (a landing may be queued behind what blocked it) and no movement of the thread's scroll view (the tail guard's repair
    /// walks it for a while before it lands), at most 3 s.
    @MainActor private static func settle() async {
        func landings() -> Int { SHRenderProbe.count("thread.tailLanding") + SHRenderProbe.count("thread.tailLandingResized") }
        let clock = ContinuousClock()
        let started = clock.now
        var last = landings()
        var offset = FollowFixture.threadScrollView()?.contentOffset.y
        var quietSince = started
        var woke = started
        while clock.now - started < .seconds(3), clock.now - quietSince < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(20))
            let now = clock.now
            let moved = FollowFixture.threadScrollView()?.contentOffset.y
            if now - woke > .milliseconds(100) || landings() != last || moved != offset {
                last = landings()
                offset = moved
                quietSince = now
            }
            woke = now
        }
    }
}

/// A following thread that mounts again (a re-open, an eviction, a rotation) starts at its tail, and a reader who left it detached
/// comes back to the row they left. These screens run where the long thread's transcript is torn down and built again: the
/// phone pops the thread and pushes it back; the iPad opens other threads until the long one is past `retainedDetails`.
extension TailFixture {
    /// Re-opens per launch; three fit the harness's 60 s launch budget on the iPad, where each also opens four other threads.
    static let remountCycles = 3
    /// Frames a mounting thread may show its scroll view with no built row in view. A re-opened thread whose restore sat the view at
    /// the top of the 24 KB reply drew nothing for 23 to 25 frames on an iPad; the budget is this screen's empirical ceiling.
    static let blankFrameBudget = 4
    /// Landings with the content or the width moving that one re-open may make.
    static let remountLandings = 1
    /// How far from the tail the first frame with a row may be: the follower's own tolerance.
    static let firstFrameReach = NativeScrollFollower.threshold
    /// The row's top may sit this far from the top edge once a detached reader's row is restored.
    static let restoreTolerance: CGFloat = 8

    /// The long thread, and short ones in the other seats, so the iPad's other threads add nothing tall to the window.
    static func remountHosts() -> [FixtureHostData] {
        var hosts = hosts()
        for agent in [FixtureData.extensions, FixtureData.dock, FixtureData.deletion] { hosts[0].threads[agent] = FixtureData.thread() }
        return hosts
    }

    /// Threads to open so the long one is no longer retained: `PadDetailRoot` keeps the last three it showed.
    private static var others: [AgentRef] {
        [FixtureData.ref(FixtureData.extensions), FixtureData.ref(FixtureData.dock), FixtureData.ref(FixtureData.deletion),
         FixtureData.ref(FixtureData.buffer, on: FixtureData.buildBox)]
    }

    /// Takes the long thread off the screen and waits until its transcript is gone: the phone pops it; the iPad shows four others.
    @MainActor private static func leave(_ app: MobileApp) async {
        weak let old = FollowFixture.threadScrollView()
        if app.navigator.layout == .pad {
            for other in others {
                app.navigator.open(.thread(other))
                try? await Task.sleep(for: .milliseconds(700))
            }
        } else {
            app.navigator.popToRoot()
        }
        await FixtureWindows.wait("the long thread to leave", seconds: 15) { old?.window == nil }
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// The scroll view of the thread on screen: the tallest one that is not transparent (a retained thread's is).
    @MainActor fileprivate static func shownThreadScroll() -> UIScrollView? {
        var found: [UIScrollView] = []
        func opaque(_ view: UIView) -> Bool {
            var current: UIView? = view
            while let each = current {
                if each.isHidden || each.alpha < 0.5 || each.layer.opacity < 0.5 { return false }
                current = each.superview
            }
            return true
        }
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is UICollectionView), !(scroll is UITextView),
               scroll.contentSize.height > scroll.bounds.height, opaque(scroll) {
                found.append(scroll)
            }
            view.subviews.forEach(walk)
        }
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).forEach(walk)
        return found.max { $0.contentSize.height < $1.contentSize.height }
    }

    /// How many built rows show in `scroll`. Each row carries a native marker (`TailRowMarker`: a plain view that takes no touch, hides
    /// from accessibility and is as tall as its row), which says a row was placed where the scroll view's numbers cannot.
    @MainActor fileprivate static func builtRows(in scroll: UIScrollView) -> Int {
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        let limit = scroll.contentSize.height * 0.9
        var count = 0
        func walk(_ view: UIView) {
            if type(of: view) == UIView.self, !view.isUserInteractionEnabled, view.accessibilityElementsHidden, !view.isAccessibilityElement,
               view.subviews.isEmpty, view.bounds.height > 0, view.bounds.height < limit, view.bounds.width > scroll.bounds.width * 0.3,
               view.convert(view.bounds, to: scroll).intersects(visible) {
                count += 1
            }
            view.subviews.forEach(walk)
        }
        walk(scroll)
        return count
    }

    /// The top built row in view: where its top edge sits against the top of the visible rect, and its height.
    @MainActor fileprivate static func topRow(in scroll: UIScrollView) -> (offset: CGFloat, height: CGFloat)? {
        let visible = scroll.bounds.inset(by: scroll.adjustedContentInset)
        var best: CGRect?
        func walk(_ view: UIView) {
            if type(of: view) == UIView.self, !view.isUserInteractionEnabled, view.accessibilityElementsHidden, !view.isAccessibilityElement,
               view.subviews.isEmpty, view.bounds.height > 0, view.bounds.height < scroll.contentSize.height * 0.9,
               view.bounds.width > scroll.bounds.width * 0.3 {
                let frame = view.convert(view.bounds, to: scroll)
                if frame.maxY > visible.minY + 1, frame.minY < visible.maxY, best.map({ frame.minY < $0.minY }) ?? true { best = frame }
            }
            view.subviews.forEach(walk)
        }
        walk(scroll)
        return best.map { ($0.minY - visible.minY, $0.height) }
    }

    @MainActor fileprivate static func tailDistance(of scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y - scroll.bounds.height
    }

    /// "thread-remount-tail": the long thread leaves and comes back `remountCycles` times. Display frame by display frame from the
    /// open, the first frame with a built row in view is within the follower's tolerance of the tail and drawn (it was the reply's
    /// top, about 16,000 pt up, on iOS 27.1, and nothing at all for 23 to 25 frames on an iPad on 27.0, until the tail guard
    /// repaired it), after at most `remountLandings` landing and `blankFrameBudget` blank frames, and the thread comes to rest on its tail.
    @MainActor static func remountTail(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        await ready(app)
        MainQueueWatchdog.start(limit: 5)
        let pad = app.navigator.layout == .pad
        var measured: [String] = []
        var verdicts: [(ok: Bool, line: String)] = []
        for cycle in 1...remountCycles {
            await leave(app)
            SHRenderProbe.start()
            let frames = MountFrames()
            frames.start()
            app.navigator.open(.thread(ref))
            await FixtureWindows.wait("a built row after the re-open", seconds: 15) { frames.firstRow != nil }
            await settle()
            let counts = SHRenderProbe.stop()
            let result = frames.stop()
            let landings = counts["thread.tailLanding", default: 0] + counts["thread.tailLandingResized", default: 0]
            let rest = shown()
            let first = result.firstRow
            let reach = first?.distance
            let percent = Int(((first?.ink ?? 0) * 100).rounded())
            measured.append("cycle \(cycle) (\(pad ? "pad" : "phone")): first row at frame \(first?.frame ?? -1) (\(Int((first?.milliseconds ?? -1).rounded())) ms), "
                + "\(result.blank) blank frames, \(reach.map { Int($0.rounded()) } ?? -1)pt from the tail, \(percent)% ink, \(landings) landings, "
                + "\(counts["thread.tailRepair", default: 0]) repairs, \(counts["thread.transcript", default: 0]) renders, \(result.away) frames away from the tail after it (worst \(result.farthest)pt); "
                + "at rest \(rest.distance)pt from the tail, \(Int((rest.ink * 100).rounded()))% ink")
            verdicts.append((reach.map { $0 <= firstFrameReach && $0 >= -NativeScrollFollower.repinSlack } ?? false,
                             "cycle \(cycle): the first frame with a row is within \(Int(firstFrameReach))pt of the tail"))
            verdicts.append(((first?.ink ?? 0) >= inkFloor, "cycle \(cycle): the first frame with a row draws"))
            verdicts.append((result.blank <= blankFrameBudget, "cycle \(cycle): at most \(blankFrameBudget) blank frames before it"))
            verdicts.append((landings <= remountLandings, "cycle \(cycle): at most \(remountLandings) landing"))
            verdicts.append((rest.atTail && rest.ink >= inkFloor, "cycle \(cycle): the thread rests on its tail, drawn"))
        }
        measured.forEach { FixtureCheck.report("FIXTURE CHECK ok: \($0)") }
        let failed = verdicts.filter { !$0.ok }
        if let first = failed.first { FixtureCheck.report("FIXTURE CHECK FAILED: \(failed.count) of \(verdicts.count) checks, the first: \(first.line)") }
        FixtureCheck.report("FIXTURE CHECK ok: \(verdicts.count) checks over \(remountCycles) re-opens")
    }

    /// "thread-detach-in-reply": from the tail of the 24 KB reply the reader drags 300 pt up in 50 pt steps (the pan stepped as
    /// `FollowFixture.jump` does). At each step the offset has moved by the drag, give or take 8 pt, and so it does after the lift:
    /// nothing sends the view to the reply's top when the reader lets go of the tail, and the reader is detached.
    @MainActor static func detachInReply(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        await ready(app)
        guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
        MainQueueWatchdog.start(limit: 5)
        _ = await shown(within: .seconds(5)) { $0.atTail && $0.ink >= inkFloor }
        let start = scroll.contentOffset.y
        let pan = scroll.panGestureRecognizer
        var worst: CGFloat = 0
        pan.state = .began
        for step in 1...6 {
            pan.setTranslation(CGPoint(x: 0, y: step * 50), in: scroll)
            pan.state = .changed
            scroll.contentOffset.y -= 50
            try? await Task.sleep(for: .milliseconds(16))
            worst = max(worst, abs((start - scroll.contentOffset.y) - CGFloat(step * 50)))
        }
        pan.state = .ended
        try? await Task.sleep(for: .seconds(1.5))
        let moved = start - scroll.contentOffset.y
        let detached = !app.navigator.composerPresentation.state(for: ref).scrollFollower.sticky
        let ink = FollowFixture.transcriptInk()
        FixtureCheck.report("FIXTURE CHECK ok: the drag moved the view \(Int(moved.rounded()))pt of 300, \(Int(worst.rounded()))pt at worst mid-drag, "
            + "\(detached ? "detached" : "still following"), \(Int((ink * 100).rounded()))% ink")
        let held = abs(moved - 300) <= restoreTolerance && worst <= restoreTolerance && detached && ink >= inkFloor
        FixtureCheck.report("FIXTURE CHECK \(held ? "ok" : "FAILED"): a drag up inside the reply moves the view by the drag and detaches the reader")
    }

    /// "thread-detached-remount": the reader scrolls up past the reply and the row before it, leaves, and comes back. The row SwiftUI
    /// kept under the top edge is the one at the top again, within `restoreTolerance`, and the thread draws.
    @MainActor static func detachedRemount(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        await ready(app)
        guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
        MainQueueWatchdog.start(limit: 5)
        let presentation = app.navigator.composerPresentation.state(for: ref)
        let finger = Finger(scroll: scroll)
        await finger.drag(by: -20_000)
        await FixtureWindows.wait("the thread at rest", seconds: 10) { !scroll.isDragging && !scroll.isDecelerating && !scroll.isTracking }
        try? await Task.sleep(for: .seconds(1.5))
        let row = presentation.visibleTurn
        let detached = !presentation.scrollFollower.sticky
        await leave(app)
        let frames = MountFrames()
        frames.start()
        app.navigator.open(.thread(ref))
        await FixtureWindows.wait("a built row after the re-open", seconds: 15) { frames.firstRow != nil }
        try? await Task.sleep(for: .seconds(2))
        _ = frames.stop()
        let back = presentation.visibleTurn
        let top = shownThreadScroll().flatMap { topRow(in: $0) }
        let ink = FollowFixture.transcriptInk()
        FixtureCheck.report("FIXTURE CHECK ok: left on row \(row ?? "none") \(detached ? "detached" : "still following"); back on row \(back ?? "none"), "
            + "its top \(top.map { String(Int($0.offset.rounded())) } ?? "unread")pt from the top edge, \(Int((ink * 100).rounded()))% ink")
        let held = row != nil && detached && back == row && top.map { abs($0.offset) <= restoreTolerance } == true && ink >= inkFloor
        FixtureCheck.report("FIXTURE CHECK \(held ? "ok" : "FAILED"): a detached reader comes back to the row they left")
    }
}

/// What a thread mounting shows on each display frame from `start()`: when its scroll view is there, when a built row first shows,
/// the blank frames between, and how far from the tail the view is at the first row and after it.
@MainActor final class MountFrames {
    struct FirstRow {
        var frame: Int
        var milliseconds: Double
        var distance: CGFloat
        var ink: Double
    }

    struct Result {
        var frames = 0
        /// Frames with the scroll view in place and no built row in view, before the first row.
        var blank = 0
        var firstRow: FirstRow?
        /// Frames after the first row more than the follower's tolerance from the tail, and the farthest of them.
        var away = 0
        var farthest = 0
    }

    private(set) var firstRow: FirstRow?
    private var result = Result()
    private var link: CADisplayLink?
    private var started = CACurrentMediaTime()
    private weak var scroll: UIScrollView?
    private var ticker: Ticker?

    func start() {
        started = CACurrentMediaTime()
        let ticker = Ticker { [weak self] in self?.tick() }
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.fire))
        link.add(to: .main, forMode: .common)
        self.ticker = ticker
        self.link = link
    }

    func stop() -> Result {
        link?.invalidate()
        link = nil
        var done = result
        done.firstRow = firstRow
        return done
    }

    private func tick() {
        result.frames += 1
        if scroll?.window == nil { scroll = TailFixture.shownThreadScroll() }
        guard let scroll else { return }
        let rows = TailFixture.builtRows(in: scroll)
        let distance = TailFixture.tailDistance(of: scroll)
        if firstRow == nil {
            guard rows > 0 else { return result.blank += 1 }
            firstRow = FirstRow(frame: result.frames, milliseconds: (CACurrentMediaTime() - started) * 1000, distance: distance,
                                ink: FollowFixture.transcriptInk())
        } else if distance > NativeScrollFollower.threshold {
            result.away += 1
            result.farthest = max(result.farthest, Int(distance.rounded()))
        }
    }

    private final class Ticker: NSObject {
        let tick: () -> Void
        init(_ tick: @escaping () -> Void) { self.tick = tick }
        @objc func fire() { tick() }
    }
}

/// Fails the run when the main queue stops answering: a thread asks it for a heartbeat every 50 ms.
/// It catches a spin the queue cannot leave, as the base's landing loop inside one commit was; a
/// loop of tasks keeps answering the heartbeats, and the landing counts and `settle()`'s 3 s cap
/// catch that instead.
final class MainQueueWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = ProcessInfo.processInfo.systemUptime

    static func start(limit: Double) {
        let watchdog = MainQueueWatchdog()
        Thread.detachNewThread {
            while true {
                DispatchQueue.main.async { watchdog.answer() }
                Thread.sleep(forTimeInterval: 0.05)
                let silent = ProcessInfo.processInfo.systemUptime - watchdog.lastAnswer
                if silent > limit {
                    FixtureCheck.fail("the main queue did not answer for \(Int(silent)) s (a landing loop in the transcript?)")
                }
            }
        }
    }

    private func answer() {
        lock.withLock { answered = ProcessInfo.processInfo.systemUptime }
    }

    private var lastAnswer: Double { lock.withLock { answered } }
}

