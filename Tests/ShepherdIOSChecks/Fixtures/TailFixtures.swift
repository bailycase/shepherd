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

