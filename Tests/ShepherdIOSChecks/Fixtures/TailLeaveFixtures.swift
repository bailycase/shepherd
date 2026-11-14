import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A transcript that is off the screen is not always one that unmounts: a screen pushed over the thread and popped leaves the stack
// where it was. Where the follower holds the bottom marker (iOS 27.1) these screens check it still holds it.
extension TailFixture {
    /// Screens pushed over the thread and popped per launch.
    static let pushCycles = 3

    /// Pushes a screen over the thread the way the layout does and waits until its transcript is off the screen. False when the
    /// screen never covered it.
    @MainActor static func pushOver(_ app: MobileApp) async -> Bool {
        weak let thread = FollowFixture.threadScrollView()
        app.navigator.open(.search(.search(query: "outbox")))
        await FixtureWindows.wait("the pushed screen to cover the thread", seconds: 6) { thread?.window == nil }
        try? await Task.sleep(for: .milliseconds(700))
        return thread?.window == nil
    }

    /// Pops the screen `pushOver` pushed.
    @MainActor static func popBack(_ app: MobileApp) {
        let navigator = app.navigator
        switch navigator.layout {
        case .phone: if case .search? = navigator[path: navigator.tab].last { navigator[path: navigator.tab].removeLast() }
        case .pad: if case .search? = navigator.padPath.last { navigator.padPath.removeLast() }
        }
    }

    /// "thread-push-pop-marker": a reader who dragged to the end of the long thread (which leaves the bottom marker held, where the
    /// transcript does not mount at its tail) has a screen pushed over the thread and popped, `pushCycles` times. The thread's
    /// scroll view is the one it was (nothing remounted), so the reader still holds the marker and is handed it, and the view rests
    /// on its tail, drawn, with no blank band past its end. On iOS 27.1 a leave that was no unmount withheld the marker, which SwiftUI
    /// then reported as no turn: the first width change after the pop (the window turning, which the screen does next, to the other
    /// orientation and back) needed two landings and a guard jump out of the stack, 6 of 6 launches on a Duo's closed display.
    @MainActor static func pushPop(_ app: MobileApp) async {
        let ref = FixtureData.ref(FixtureData.preview)
        await ready(app)
        MainQueueWatchdog.start(limit: 5)
        guard let scroll = FollowFixture.threadScrollView() else { return FixtureCheck.report("FIXTURE CHECK FAILED: no thread scroll view") }
        let place = app.navigator.composerPresentation.state(for: ref)
        let store = app.threads.store(for: ref)
        let marker = NativeTranscriptPlace.bottomMarker
        let pad = app.navigator.layout == .pad
        let judged = !ComposerPresentation.nativeTail
        // A view already at the end has no drag to make, so the reader first goes back up a little. SwiftUI does not always report the
        // marker at the end of a drag, so a reader who is to hold it tries again.
        for _ in 1...(judged ? 3 : 1) {
            await Finger(scroll: scroll).drag(by: -600)
            await Finger(scroll: scroll).toEnd()
            try? await Task.sleep(for: .seconds(1.5))
            if place.visibleTurn == marker { break }
        }
        var verdicts: [(ok: Bool, line: String)] = []
        FixtureCheck.report("FIXTURE CHECK ok: before the pushes the reader follows \(place.follows) and keeps \(place.visibleTurn ?? "no turn")")
        if judged { verdicts.append((place.visibleTurn == marker, "the reader holds the bottom marker before the pushes")) }
        var measured: [String] = []
        for cycle in 1...pushCycles {
            let covered = await pushOver(app)
            let watch = TailWatch(jolt: bannerJolt, phase: { "" })
            SHRenderProbe.start()
            watch.start()
            popBack(app)
            await FixtureWindows.wait("the thread back", seconds: 10) { FollowFixture.threadScrollView() != nil }
            try? await Task.sleep(for: .seconds(2))
            let counts = SHRenderProbe.stop()
            let result = watch.stop()
            let reused = FollowFixture.threadScrollView() === scroll
            let tail = store.rows.last?.id
            let handed = place.position(tail: tail)
            let withheld = place.withholdsMarker(tail: tail)
            let rest = shown()
            measured.append("cycle \(cycle) (\(pad ? "pad" : "phone")): covered \(covered), view \(reused ? "reused" : "rebuilt"), keeps \(place.visibleTurn ?? "no turn"), "
                + "handed \(handed ?? "nothing"), marker \(withheld ? "withheld" : "held"); over \(result.frames) frames \(result.away) away from the tail (farthest \(result.farthest)pt), "
                + "\(result.blank) with no row, \(result.pastEnd) past the end (deepest \(result.deepest)pt); \(counts["thread.tailLanding", default: 0] + counts["thread.tailLandingResized", default: 0]) landings, "
                + "\(counts["thread.tailRepair", default: 0]) repairs, \(counts["thread.tailMountJump", default: 0]) mount jumps; "
                + "at rest \(rest.distance)pt from the tail, \(Int((rest.ink * 100).rounded()))% ink")
            verdicts.append((covered, "cycle \(cycle): the pushed screen covered the thread"))
            if judged, reused {
                verdicts.append((handed == marker && !withheld, "cycle \(cycle): the reader who left holding the bottom marker is handed it again when the screen comes back"))
            }
            verdicts.append((result.pastEnd == 0 && rest.distance >= -overshootTolerance, "cycle \(cycle): the view is never past the end of its content"))
            verdicts.append((rest.atTail && rest.ink >= inkFloor, "cycle \(cycle): the thread rests on its tail, drawn"))
        }
        // Then the window turns to the other orientation and back, which changes its width where the marker is what keeps the view on
        // the tail: every display frame of each turn is read against the tail.
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let wide = scene.effectiveGeometry.interfaceOrientation.isLandscape
            let turns: [(mask: UIInterfaceOrientationMask, name: String)] = wide ? [(.portrait, "portrait"), (.landscapeRight, "landscape")]
                : [(.landscapeRight, "landscape"), (.portrait, "portrait")]
            for turn in turns {
                let watch = TailWatch(jolt: bannerJolt, phase: { "" })
                SHRenderProbe.start()
                watch.start()
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: turn.mask)) { _ in }
                await FixtureWindows.wait("the turn to \(turn.name)", seconds: 5) {
                    turn.mask == .portrait ? scene.effectiveGeometry.interfaceOrientation.isPortrait : scene.effectiveGeometry.interfaceOrientation.isLandscape
                }
                try? await Task.sleep(for: .seconds(3))
                let counts = SHRenderProbe.stop()
                let result = watch.stop()
                let rest = shown()
                measured.append("turn to \(turn.name): keeps \(place.visibleTurn ?? "no turn"), over \(result.frames) frames \(result.away) away from the tail (farthest \(result.farthest)pt), "
                    + "\(result.blank) with no row, \(result.pastEnd) past the end (deepest \(result.deepest)pt); \(counts["thread.tailLanding", default: 0]) landings, "
                    + "\(counts["thread.tailLandingResized", default: 0]) with the width, \(counts["thread.tailRepair", default: 0]) repairs, \(counts["thread.tailMountJump", default: 0]) mount jumps; "
                    + "at rest \(rest.distance)pt from the tail, \(Int((rest.ink * 100).rounded()))% ink")
                // The first width change after a pop used to need two landings and a guard jump out of a stack the withheld marker had left
                // (the open display's turns need them with or without one, so only the phone is judged).
                if judged, !pad { verdicts.append((counts["thread.tailMountJump", default: 0] == 0, "the turn to \(turn.name) needed no mount jump")) }
                verdicts.append((rest.atTail && rest.ink >= inkFloor, "the thread rests on its tail, drawn, after the turn to \(turn.name)"))
            }
        }
        measured.forEach { FixtureCheck.report("FIXTURE CHECK ok: \($0)") }
        let failed = verdicts.filter { !$0.ok }
        if let first = failed.first { FixtureCheck.report("FIXTURE CHECK FAILED: \(failed.count) of \(verdicts.count) checks, the first: \(first.line)") }
        FixtureCheck.report("FIXTURE CHECK ok: \(verdicts.count) checks over \(pushCycles) pushes")
    }
}
