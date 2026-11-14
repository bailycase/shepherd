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
            // retained): a built row shows from its first frame, at the tail and drawn, with no repair by the tail guard and at most one
            // landing, and it rests on its tail. The frames before that row, the time to it and the memory the mount takes are reported.
            // Where it does not mount at its tail by design (iOS 27.1, `ComposerPresentation.nativeTail`) the distance and landings are
            // reported, and on iOS 27.1 a blank frame or a repair fails the open.
            FixtureScreen(name: "thread-remount-tail", hosts: TailFixture.remountHosts(), routes: [.thread(thread)],
                          prepare: { app in await TailFixture.remountTail(app) }),
            // A 300 pt drag up from the tail of the 24 KB reply moves the view by the drag and no more (nothing sends it to the reply's
            // top), and the transcript renders no time at touch-down and at most four times over the whole drag (where
            // `ComposerPresentation.nativeTail`: on iOS 27.1 it draws from every change of the follower, and these are reported).
            FixtureScreen(name: "thread-detach-in-reply", hosts: TailFixture.hosts(), routes: [.thread(thread)], prepare: TailFixture.detachInReply),
            // A reader who dragged up inside the reply, and one who scrolled up past it, come back to the row they left at the top.
            FixtureScreen(name: "thread-detached-remount", hosts: TailFixture.remountHosts(), routes: [.thread(thread)], prepare: TailFixture.detachedRemount),
            // The same re-open over the long thread with a short line from the person after the 24 KB reply: the reply is the last row
            // but one, and most of the view (the base drew nothing for 18 frames).
            FixtureScreen(name: "thread-remount-follow-up", hosts: TailFixture.followUpHosts(), routes: [.thread(thread)],
                          prepare: { app in await TailFixture.remountTail(app, rows: 151) }),
            // A reader detached inside the reply with no turn kept (SwiftUI left the position binding nil) comes back to the tail and follows it.
            FixtureScreen(name: "thread-unplaced-remount", hosts: TailFixture.remountHosts(), routes: [.thread(thread)], prepare: TailFixture.unplacedRemount),
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
        FixtureData.snapshot(messages())
    }

    static func messages() -> [NativeThreadMessage] {
        typealias F = FixtureData
        var messages: [NativeThreadMessage] = []
        for turn in 0..<150 {
            let at = Double(turn) * 20_000
            messages.append(F.user("t\(turn)u", "Reply with exactly: tail-\(turn)", at: at))
            messages.append(F.assistant("t\(turn)a", "tail-\(turn)", at: at + 2_000))
        }
        messages.append(F.user("lu", "Write up the whole outbox design, section by section.", at: 3_100_000))
        messages.append(F.assistant("la", longReply(cycles: 24), at: 3_110_000))
        return messages
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
    @MainActor static func ready(_ app: MobileApp, rows: Int = 150) async {
        let store = app.threads.store(for: FixtureData.ref(FixtureData.preview))
        await FixtureWindows.wait("the long thread", seconds: 20) { store.rows.count > rows && FollowFixture.threadScrollView() != nil }
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
    /// Landings with the content or the width moving that one re-open may make.
    static let remountLandings = 1
    /// How many display frames a re-opened transcript may show with its scroll view in place and no row in view (the base mounted an
    /// iPad in landscape on iOS 27.0 at 18 to 27 of them, every time, until the tail guard walked back to the rows; it now shows none,
    /// and a frame is all the transition's first layout could still cost).
    static let remountBlankFrames = 1
    /// How far from the tail the first frame with a row may be: the follower's own tolerance.
    static let firstFrameReach = NativeScrollFollower.threshold
    /// Whether this runs on iOS 27.1 or later, where `ComposerPresentation.nativeTail` is off and a re-open was measured on a Duo.
    static let fromIOS271: Bool = { if #available(iOS 27.1, *) { true } else { false } }()
    /// How far past the end of its content a view may be: a point or two of rounding.
    static let overshootTolerance = 2
    /// The row's top may sit this far from the top edge once a detached reader's row is restored.
    static let restoreTolerance: CGFloat = 8
    /// Renders of the transcript that a drag inside one row may cause: the detach, the two turns SwiftUI reports after it, and
    /// now and then one more (3 in 8 of 10 drags on an iPad Pro 13 in the simulator, 4 in one; the merge base drew it 5 times in all
    /// but the one a load average of 274 disturbed).
    static let dragRenders = 4

    /// The long thread, and short ones in the other seats, so the iPad's other threads add nothing tall to the window.
    static func remountHosts() -> [FixtureHostData] {
        var hosts = hosts()
        for agent in [FixtureData.extensions, FixtureData.dock, FixtureData.deletion] { hosts[0].threads[agent] = FixtureData.thread() }
        return hosts
    }

    /// `remountHosts` over the long thread and a short line from the person after its reply.
    static func followUpHosts() -> [FixtureHostData] {
        var hosts = remountHosts()
        hosts[0].threads[FixtureData.preview] = FixtureData.snapshot(messages() + [FixtureData.user("fu", "Thanks, that is what I needed.", at: 3_200_000)])
        return hosts
    }

    /// The app's physical footprint now, in megabytes (what the system charges it).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
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
    @MainActor static func shownThreadScroll() -> UIScrollView? {
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
    @MainActor static func builtRows(in scroll: UIScrollView) -> Int {
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

    /// Every built row the scroll view holds, in its content's coordinates, in view or not (`builtRows` counts those in view).
    @MainActor fileprivate static func placedRows(in scroll: UIScrollView) -> [CGRect] {
        let limit = scroll.contentSize.height * 0.9
        var frames: [CGRect] = []
        func walk(_ view: UIView) {
            if type(of: view) == UIView.self, !view.isUserInteractionEnabled, view.accessibilityElementsHidden, !view.isAccessibilityElement,
               view.subviews.isEmpty, view.bounds.height > 0, view.bounds.height < limit, view.bounds.width > scroll.bounds.width * 0.3 {
                frames.append(view.convert(view.bounds, to: scroll))
            }
            view.subviews.forEach(walk)
        }
        walk(scroll)
        return frames.sorted { $0.minY < $1.minY }
    }

    @MainActor static func tailDistance(of scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.contentOffset.y - scroll.bounds.height
    }

    /// "thread-remount-tail": the long thread leaves and comes back `remountCycles` times. Display frame by display frame from the
    /// open, the scroll view has a built row in view from its first frame (at most `remountBlankFrames` without one), no repair by
    /// the tail guard is needed, that row is within the follower's tolerance of the tail and drawn (on iOS 27.1 it was the reply's
    /// top, about 16,000 pt up), after at most `remountLandings` landing, and the thread comes to rest on its tail. What mounting
    /// costs is reported with it: the time to the first row and the footprint, against the one the thread gave back on leaving.
    ///
    /// The base mounted the lazy stack at the end of its estimated height (about 250,000 pt for this thread) while the nine rows it
    /// had built at the end of the thread stood at about 28,000 pt, so no row was in view for 18 to 27 frames, until the guard walked
    /// back to them (`ThreadTailGuard`). Where the transcript does not mount at its tail (`ComposerPresentation.nativeTail` is false,
    /// iOS 27.1) the distance and landings are reported too; on iOS 27.1 a blank frame or a repair fails the open whichever way
    /// `nativeTail` goes, which is what lifting it does until the last turns are laid out for real. Set `TAIL_TRACE` in the launch
    /// environment to have every frame of a mount described.
    @MainActor static func remountTail(_ app: MobileApp, rows: Int = 150, holdingMarker: Bool = false) async {
        let ref = FixtureData.ref(FixtureData.preview)
        await ready(app, rows: rows)
        MainQueueWatchdog.start(limit: 5)
        var verdicts: [(ok: Bool, line: String)] = []
        if holdingMarker {
            // A reader who drags to the end leaves holding the bottom marker, which SwiftUI reports at the end of that drag (not where
            // `nativeTail`). A view already at the end has no drag to make, so the reader first goes back up a little.
            guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
            await Finger(scroll: scroll).drag(by: -600)
            await Finger(scroll: scroll).toEnd()
            try? await Task.sleep(for: .seconds(1.5))
            let kept = app.navigator.composerPresentation.state(for: ref).visibleTurn
            FixtureCheck.report("FIXTURE CHECK ok: the reader leaves holding \(kept ?? "no turn")")
            if !ComposerPresentation.nativeTail { verdicts.append((kept == NativeTranscriptPlace.bottomMarker, "the reader holds the bottom marker when they leave")) }
        }
        let pad = app.navigator.layout == .pad
        var measured: [String] = []
        var onlyInkAndRest = 0
        let gap = shownThreadScroll().map(gutter(of:)) ?? 0
        let place = app.navigator.composerPresentation.state(for: ref)
        FixtureCheck.report("FIXTURE CHECK ok: before the re-opens the reader follows \(place.follows) and keeps \(place.visibleTurn.map { "turn \($0)" } ?? "no turn")")
        for cycle in 1...remountCycles {
            await leave(app)
            // What the thread gave back when it left is read after a pause, for the views to be freed.
            try? await Task.sleep(for: .milliseconds(700))
            let away = footprintMB()
            SHRenderProbe.start()
            let frames = MountFrames()
            frames.start()
            app.navigator.open(.thread(ref))
            await FixtureWindows.wait("a built row after the re-open", seconds: 15) { frames.firstRow != nil }
            await settle()
            let counts = SHRenderProbe.stop()
            let mounted = footprintMB()
            let result = frames.stop()
            let landings = counts["thread.tailLanding", default: 0] + counts["thread.tailLandingResized", default: 0]
            let rest = shown()
            let first = result.firstRow
            let reach = first?.distance
            let percent = Int(((first?.ink ?? 0) * 100).rounded())
            if result.blank > 0 { measured.append("  cycle \(cycle) blank frames (content height:offset): \(result.blankTrace.prefix(6) + result.blankTrace.suffix(2))") }
            result.placementTrace.forEach { measured.append("  cycle \(cycle) \($0)") }
            measured.append("cycle \(cycle) (\(pad ? "pad" : "phone"), keeps \(place.visibleTurn ?? "no turn")): first row at frame \(first?.frame ?? -1) (\(Int((first?.milliseconds ?? -1).rounded())) ms), "
                + "\(result.blank) blank frames, \(reach.map { Int($0.rounded()) } ?? -1)pt from the tail, \(percent)% ink, \(landings) landings, "
                + "\(counts["thread.tailRepair", default: 0]) repairs, \(counts["thread.tailMountJump", default: 0]) mount jumps, \(counts["thread.transcript", default: 0]) renders, \(result.away) frames away from the tail after it (worst \(result.farthest)pt); "
                + "at rest \(rest.distance)pt from the tail, \(Int((rest.ink * 100).rounded()))% ink; "
                + "footprint \(Int(away.rounded())) MB away, \(Int(mounted.rounded())) MB mounted (+\(Int((mounted - away).rounded())))")
            let repaired = counts["thread.tailRepair", default: 0] > 0
            // A view past the end of its content shows a blank band: on iOS 27.1 the guard's jump left one 39 pt past it at rest, and the
            // first frame with a row stood up to 49 pt past it.
            verdicts.append((rest.distance >= -overshootTolerance, "cycle \(cycle): the thread rests on its content, not past its end"))
            if Self.fromIOS271 {
                verdicts.append((reach.map { Int($0.rounded()) >= -overshootTolerance } ?? false, "cycle \(cycle): the first frame with a row is not past the end of the content"))
                // iOS 27.1 opens at the tail through the pin's landings, so a re-open has no stranded stack for the guard to jump out of.
                verdicts.append((counts["thread.tailMountJump", default: 0] == 0, "cycle \(cycle): the re-open needed no mount jump"))
                // iOS 27.1 opens as the merge base did, which needs no repair and shows no blank frame, whichever way `nativeTail` goes.
                // Mounting it at its tail there stranded the stack at the end of its estimated height: 26 blank frames (about 840 ms) and a
                // repair on every re-open on the Duo's cover display, and two repairs on the open one. Its first frame with a row has drawn
                // nothing yet on the open Duo, on the merge base too, so beyond the wait only the rest is judged.
                onlyInkAndRest += 1
                verdicts.append((result.blank == 0 && !repaired, "cycle \(cycle): no blank frame before the first row, and no repair"))
            } else {
                verdicts.append((result.blank <= remountBlankFrames, "cycle \(cycle): at most \(remountBlankFrames) frames with no row in view, not \(result.blank)"))
                verdicts.append((!repaired, "cycle \(cycle): the tail guard had nothing to repair"))
                verdicts.append((reach.map { $0 <= firstFrameReach + gap && $0 >= -NativeScrollFollower.repinSlack } ?? false,
                                 "cycle \(cycle): the first frame with a row is within \(Int(firstFrameReach))pt of where a landing leaves the view"))
                verdicts.append((landings <= remountLandings, "cycle \(cycle): at most \(remountLandings) landing"))
            }
            if !Self.fromIOS271 { verdicts.append(((first?.ink ?? 0) >= inkFloor, "cycle \(cycle): the first frame with a row draws")) }
            verdicts.append((rest.atTail && rest.ink >= inkFloor, "cycle \(cycle): the thread rests on its tail, drawn"))
        }
        measured.forEach { FixtureCheck.report("FIXTURE CHECK ok: \($0)") }
        let failed = verdicts.filter { !$0.ok }
        if let first = failed.first { FixtureCheck.report("FIXTURE CHECK FAILED: \(failed.count) of \(verdicts.count) checks, the first: \(first.line)") }
        FixtureCheck.report("FIXTURE CHECK ok: \(verdicts.count) checks over \(remountCycles) re-opens, \(onlyInkAndRest) of them judged only on ink and rest")
    }

    /// A finger already down on `scroll`, which stood at `start`, drags it `steps` times 50 pt toward the top, a display frame apart
    /// (the pan stepped as `FollowFixture.jump` does). Returns how far the view was at worst from where the drag alone puts it.
    @MainActor private static func dragUp(_ scroll: UIScrollView, from start: CGFloat, steps: Int) async -> CGFloat {
        let pan = scroll.panGestureRecognizer
        var worst: CGFloat = 0
        for step in 1...steps {
            pan.setTranslation(CGPoint(x: 0, y: step * 50), in: scroll)
            pan.state = .changed
            scroll.contentOffset.y -= 50
            try? await Task.sleep(for: .milliseconds(16))
            worst = max(worst, abs((start - scroll.contentOffset.y) - CGFloat(step * 50)))
        }
        return worst
    }

    /// "thread-detach-in-reply": from the tail of the 24 KB reply the reader drags 300 pt up in 50 pt steps (the pan stepped as
    /// `FollowFixture.jump` does). At each step the offset has moved by the drag, give or take 8 pt, and so it does after the lift:
    /// nothing sends the view to the reply's top when the reader lets go of the tail, and the reader is detached. The drag stays
    /// inside one row, so the transcript draws only for what changed in it: a finger coming down renders it no time, and the
    /// detach and the two turns SwiftUI then reports at the top edge (the bottom marker, then the reply) at most `dragRenders`
    /// times between them. The merge base drew it once at touch-down and five times over the whole drag, and so does iOS 27.1
    /// (not `ComposerPresentation.nativeTail`), so there the renders are reported, not judged: with the turn kept and no render at
    /// touch-down, SwiftUI's next update of the scroll view put the drag's first 50 pt step back (an iPad in portrait).
    @MainActor static func detachInReply(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        await ready(app)
        guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
        MainQueueWatchdog.start(limit: 5)
        _ = await shown(within: .seconds(5)) { $0.atTail && $0.ink >= inkFloor }
        let start = scroll.contentOffset.y
        let pan = scroll.panGestureRecognizer
        SHRenderProbe.start()
        pan.state = .began
        try? await Task.sleep(for: .milliseconds(200))
        let touchDown = SHRenderProbe.count("thread.transcript")
        let worst = await dragUp(scroll, from: start, steps: 6)
        pan.state = .ended
        let dragged = await FollowFixture.transcriptRendersAtRest()
        let walks = "\(SHRenderProbe.count("thread.tailMountJump")) mount jumps, \(SHRenderProbe.count("thread.tailRepair")) repairs"
        SHRenderProbe.stop()
        let moved = start - scroll.contentOffset.y
        let detached = !app.navigator.composerPresentation.state(for: ref).scrollFollower.sticky
        let ink = FollowFixture.transcriptInk()
        FixtureCheck.report("FIXTURE CHECK ok: the drag moved the view \(Int(moved.rounded()))pt of 300, \(Int(worst.rounded()))pt at worst mid-drag, "
            + "\(detached ? "detached" : "still following"), \(Int((ink * 100).rounded()))% ink; the transcript rendered \(touchDown) times at touch-down "
            + "and \(dragged) over the whole drag; \(walks)")
        let held = abs(moved - 300) <= restoreTolerance && worst <= restoreTolerance && detached && ink >= inkFloor
        FixtureCheck.report("FIXTURE CHECK \(held ? "ok" : "FAILED"): a drag up inside the reply moves the view by the drag and detaches the reader")
        guard ComposerPresentation.nativeTail else { return }
        FixtureCheck.report("FIXTURE CHECK \(touchDown == 0 ? "ok" : "FAILED"): touch-down alone renders the transcript no time")
        FixtureCheck.report("FIXTURE CHECK \(dragged <= dragRenders ? "ok" : "FAILED"): the whole drag renders the transcript at most \(dragRenders) times")
    }

    /// "thread-detached-remount": a reader who left the tail comes back after the transcript was torn down and built again. Two
    /// readers, one after the other on the same launch.
    ///
    /// The first drags 300 pt up from the tail, inside the 24 KB reply. SwiftUI writes the turn under the top edge once the drag
    /// has left the tail (the bottom marker, then the reply), so the reply is the row kept, and the reader comes back detached with
    /// the reply's top at the top edge, as on the merge base. Nothing is kept only when SwiftUI leaves the position binding nil
    /// (`unplacedRemount`).
    ///
    /// The second scrolls up past the reply and the row before it, leaves, and comes back. The row SwiftUI kept under the top edge
    /// is the one at the top again, within `restoreTolerance` (and one turn spacing more on iOS 27.1), and the thread draws.
    @MainActor static func detachedRemount(_ app: MobileApp) async {
        await ready(app)
        MainQueueWatchdog.start(limit: 5)
        await detachedInReplyRemount(app, forgetting: false)
        await detachedPastReplyRemount(app)
    }

    /// "thread-unplaced-remount": a reader detached inside the reply whom SwiftUI left with no turn to restore (it can leave the
    /// position binding nil at a boundary, as after a jump; here it is written nil once the drag is at rest) leaves and comes back.
    /// Where `ComposerPresentation.nativeTail` the transcript opens on its bottom anchor when no turn is kept, so it must also follow
    /// the tail: a follower still detached would leave it at the tail without following new output, with the jump pill showing while
    /// the agent runs. On iOS 27.1 the transcript opens as the merge base did, and this is reported.
    @MainActor static func unplacedRemount(_ app: MobileApp) async {
        await ready(app)
        MainQueueWatchdog.start(limit: 5)
        await detachedInReplyRemount(app, forgetting: true)
    }

    /// Drags 300 pt up from the tail inside the reply, waits for the view to rest, leaves, and comes back; then reports and judges
    /// where the reader is. `forgetting` first takes the turn kept away, as a nil write from SwiftUI would.
    @MainActor private static func detachedInReplyRemount(_ app: MobileApp, forgetting: Bool) async {
        let ref = FixtureData.ref(FixtureData.preview)
        guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
        let presentation = app.navigator.composerPresentation.state(for: ref)
        _ = await shown(within: .seconds(5)) { $0.atTail && $0.ink >= inkFloor }
        let start = scroll.contentOffset.y
        let pan = scroll.panGestureRecognizer
        pan.state = .began
        try? await Task.sleep(for: .milliseconds(200))
        _ = await dragUp(scroll, from: start, steps: 6)
        pan.state = .ended
        await FixtureWindows.wait("the thread at rest", seconds: 10) { !scroll.isDragging && !scroll.isDecelerating && !scroll.isTracking }
        try? await Task.sleep(for: .seconds(1.5))
        if forgetting { presentation.noteVisibleTurn(nil) }
        let moved = Int((start - scroll.contentOffset.y).rounded())
        let row = presentation.visibleTurn
        let detached = !presentation.scrollFollower.sticky
        await leave(app)
        let frames = MountFrames()
        frames.start()
        app.navigator.open(.thread(ref))
        await FixtureWindows.wait("a built row after the re-open", seconds: 15) { frames.firstRow != nil }
        await settle()
        _ = frames.stop()
        let back = presentation.visibleTurn
        let top = shownThreadScroll().flatMap { topRow(in: $0) }
        let rest = shown()
        let follows = presentation.follows && presentation.scrollFollower.sticky
        // The jump pill shows for a detached reader while the agent runs (`running`) or after output they have not seen.
        let pill = NativeScrollFollower.showsJump(sticky: presentation.follows, unseen: presentation.unseen, running: true)
        FixtureCheck.report("FIXTURE CHECK ok: dragged \(moved)pt up inside the reply, left \(detached ? "detached" : "still following") "
            + "with \(row.map { "row \($0)" } ?? "no row") kept; back on \(back.map { "row \($0)" } ?? "no row"), its top "
            + "\(top.map { String(Int($0.offset.rounded())) } ?? "unread")pt from the top edge, \(rest.distance)pt from the tail, "
            + "\(follows ? "following" : "detached"), \(pill ? "with" : "without") the jump pill while the agent runs, \(Int((rest.ink * 100).rounded()))% ink")
        if forgetting {
            guard ComposerPresentation.nativeTail else { return }
            FixtureCheck.report("FIXTURE CHECK \(detached && row == nil ? "ok" : "FAILED"): the reader is detached with no row kept")
            FixtureCheck.report("FIXTURE CHECK \(follows && !pill && rest.atTail && rest.ink >= inkFloor ? "ok" : "FAILED"): "
                + "a reader with no row to come back to returns to the tail, following it, with no jump pill")
        } else {
            // The reply is some 10,000 pt of lazily measured text, so its top lands within a few tens of points of the top edge, not
            // within `restoreTolerance` as a short row's does (-18 pt and -15 pt on the merge base too): it is the row that is judged.
            let held = row != nil && detached && back == row && rest.distance > Int(firstFrameReach) && rest.ink >= inkFloor
            FixtureCheck.report("FIXTURE CHECK \(held ? "ok" : "FAILED"): a reader detached inside the reply comes back to the row they left, detached")
        }
    }

    @MainActor private static func detachedPastReplyRemount(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
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
        // iOS 27.1 puts the restored row's top one turn spacing under the top edge (24 pt on the Duo, on the merge base too), where 27.0
        // puts it within `restoreTolerance`.
        let tolerance = restoreTolerance + (Self.fromIOS271 ? MobileLayout.turnSpacing : 0)
        let held = row != nil && detached && back == row && top.map { abs($0.offset) <= tolerance } == true && ink >= inkFloor
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
        /// Frames after the first row more than a landing's slack short of where a landing leaves the view, and the farthest of them.
        var away = 0
        var farthest = 0
        /// The scroll view's content height, offset and built rows in view on the frames before the first row, as far as the first 40.
        var blankTrace: [String] = []
        /// With `TAIL_TRACE` set: the same frames in full (see `placement`), and the first frames after the first row.
        var placementTrace: [String] = []
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
        if Self.traces, result.placementTrace.count < 70 { result.placementTrace.append(placement(of: scroll, inView: rows, at: result.frames)) }
        if firstRow == nil {
            guard rows > 0 else {
                result.blank += 1
                if result.blankTrace.count < 40 { result.blankTrace.append("\(Int(scroll.contentSize.height)):\(Int(scroll.contentOffset.y))") }
                return
            }
            firstRow = FirstRow(frame: result.frames, milliseconds: (CACurrentMediaTime() - started) * 1000, distance: distance,
                                ink: FollowFixture.transcriptInk())
        } else if distance > NativeScrollFollower.repinSlack + TailFixture.gutter(of: scroll) {
            result.away += 1
            result.farthest = max(result.farthest, Int(distance.rounded()))
        }
    }

    /// Set `TAIL_TRACE` in the launch environment to have every frame of a mount described.
    private static let traces = ProcessInfo.processInfo.environment["TAIL_TRACE"] != nil

    /// One frame: the content height and offset, the built rows in view, then how many rows are built and where the first and
    /// last of them sit in the content, against the viewport, with the repairs the guard has begun so far.
    private func placement(of scroll: UIScrollView, inView: Int, at frame: Int) -> String {
        let placed = TailFixture.placedRows(in: scroll)
        let span = placed.isEmpty ? "none" : "\(Int(placed[0].minY))..\(Int(placed[placed.count - 1].maxY))"
        let tall = placed.max { $0.height < $1.height }.map { "tallest \(Int($0.height)) at \(Int($0.minY))" } ?? ""
        return "f\(frame) h\(Int(scroll.contentSize.height)) y\(Int(scroll.contentOffset.y)) view \(Int(scroll.bounds.height)) "
            + "inview \(inView) built \(placed.count) \(span) \(tall) repairs \(SHRenderProbe.count("thread.tailRepair")) "
            + "landings \(SHRenderProbe.count("thread.tailLanding") + SHRenderProbe.count("thread.tailLandingResized"))"
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

