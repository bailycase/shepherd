import Foundation
import ShepherdRemote
import ShepherdUI

/// What the transcript's scroll view reports: the tail probe, and the width the rows wrap to,
/// which the probe does not carry.
struct TailReading: Equatable {
    var probe: NativeScrollProbe
    var width: Double

    /// The viewport itself changed since `old`: the rows re-wrap, or the composer, the keyboard
    /// or a bar moved the edge the tail sits on. Such a reading is never evidence that landing
    /// again does not help.
    func resized(from old: TailReading) -> Bool {
        let slack = NativeScrollFollower.repinSlack
        return abs(width - old.width) > slack
            || abs(probe.container - old.probe.container) > slack
            || abs(probe.inset - old.probe.inset) > slack
            || abs(probe.insetTop - old.probe.insetTop) > slack
    }
}

/// Lands the transcript on its tail after the layout pass that asked, not inside it: the scroll
/// geometry's action only records, and one main-actor task per run-loop turn asks `NativeTailRepin`
/// whether landing still helps. The exception is a pin's first few landings, which run in the pass
/// that asks for them (`NativeTailRepin.takeInPass`): a transcript that mounts draws those passes'
/// frames, and they belong at the tail. That is a fixed number of landings in passes per thread the pin
/// shows, so a layout that asks again inside its own passes cannot spin there. A tail that will not settle stops
/// being chased, and a quiet watch gives it a try now and then. Not observed: nothing draws from it.
@MainActor
final class ThreadTailPin {
    typealias Land = @MainActor (_ resized: Bool) -> Void

    private var repin = NativeTailRepin()
    private var land: Land?
    private var turn: Task<Void, Never>?
    private var quiet: Task<Void, Never>?
    private var scrolling = false
    /// A reading since the last turn changed the viewport, so the landing it asks for is a resize's.
    private var resized = false
    /// When the last reading or quiet try came: a stalled tail is left alone for `quietWait` from then.
    private var lastSeen = ContinuousClock.now

    /// A scroll-geometry reading, and the follower's answer to it. A resize takes a turn even when
    /// no landing is wanted, so its flag does not carry into a later landing's count. A stalled
    /// tail takes no turn for a reading that only moved it: output, an ask and the quiet watch have
    /// their own.
    func reading(distance: Double, wants: Bool, resized: Bool, land: @escaping Land) {
        self.land = land
        lastSeen = ContinuousClock.now
        guard !repin.held else { return }
        self.resized = self.resized || resized
        repin.reading(distance: distance, wants: wants, resized: resized)
        let stalled = repin.stalled
        let inPass = !scrolling && repin.takeInPass()
        noteStall(since: stalled)
        if inPass {
            let resizing = self.resized
            self.resized = false
            SHRenderProbe.tick("thread.tailLandingInPass")
            land(resizing)
        }
        if !scrolling, (repin.pending && !repin.stalled) || self.resized { schedule() }
        watch()
    }

    /// New output at the tail.
    func outputArrived() {
        repin.outputArrived()
        schedule()
    }

    /// The reader sent a message, or asks for the latest: land on the next turn, even while the
    /// thread coasts after a flick (landing ends the coast). A finger on it holds the landing back.
    func asked(_ land: @escaping Land) {
        self.land = land
        repin.asked()
        schedule()
    }

    /// The reader's scroll started, changed phase or ended; `touching` is a finger on the thread.
    func reader(scrolling: Bool, touching: Bool) {
        self.scrolling = scrolling
        repin.reader(scrolling: scrolling, touching: touching)
        if repin.wantsTurn { schedule() }
        watch()
    }

    /// The transcript now shows another thread (the session changed, or a reused view got a new ref):
    /// what the pin knew of the old one is no use, and the new one gets its own landings in passes,
    /// `inPassLimit` of them, like a mount. A session or a ref changes by an event, never by a layout
    /// pass, so a layout that asks again cannot refill them. The landing closure stays for the next
    /// reading to replace.
    func reset() {
        forget(refillingPass: true)
    }

    /// The tail guard starts or ends a walk of the scroll view (`NativeTailRepin.hold`): its landings are dropped, so the pin
    /// neither lands nor counts meanwhile.
    func standAside(_ aside: Bool) {
        if aside {
            repin.hold()
            turn?.cancel()
            quiet?.cancel()
            turn = nil
            quiet = nil
            resized = false
        } else {
            repin.release()
            watch()
        }
    }

    /// The transcript left the screen: nothing lands through a proxy that may outlive it. Its landings
    /// in passes stay spent: whatever hides and shows the view again is not a new thread.
    func stop() {
        forget(refillingPass: false)
        repin.release()
        repin.reader(scrolling: false, touching: false)
        land = nil
        scrolling = false
    }

    private func forget(refillingPass: Bool) {
        turn?.cancel()
        quiet?.cancel()
        turn = nil
        quiet = nil
        repin.newThread(refillingPass: refillingPass)
        resized = false
    }

    private func schedule() {
        guard turn == nil else { return }
        turn = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            turn = nil
            run()
        }
    }

    /// The repin decides what a turn does while the reader scrolls: automatic landings wait for the
    /// scroll to end, the reader's own asks do not.
    private func run() {
        let resizing = resized
        let stalled = repin.stalled
        let lands = repin.take()
        if lands || !scrolling { resized = false }
        noteStall(since: stalled)
        if lands { land?(resizing) }
        watch()
    }

    /// Reports the pin giving up, from a turn or from a pass: after a stall in a pass, readings take
    /// no turn and every later turn starts stalled, so nothing else would see it.
    private func noteStall(since stalled: Bool) {
        guard repin.stalled, !stalled else { return }
        MobileSignposts.tailStalled()
        SHRenderProbe.tick("thread.tailStalled")
    }

    /// While stalled, one task waits out the quiet: it sleeps until `quietWait` has passed since the
    /// last reading, wakes to find a later one moved the time, and sleeps again, so a thread that
    /// keeps scrolling costs no task per frame. Then the tail gets one try, and the wait doubles.
    private func watch() {
        guard repin.stalled, repin.quietTries < NativeTailRepin.maxQuietTries else {
            quiet?.cancel()
            quiet = nil
            return
        }
        guard quiet == nil else { return }
        quiet = Task { @MainActor [weak self] in
            while let due = self?.quietDue, due > ContinuousClock.now {
                try? await Task.sleep(until: due, clock: .continuous)
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled, let self else { return }
            quiet = nil
            lastSeen = ContinuousClock.now
            repin.quietPassed()
            schedule()
        }
    }

    private var quietDue: ContinuousClock.Instant { lastSeen.advanced(by: repin.quietWait) }
}
