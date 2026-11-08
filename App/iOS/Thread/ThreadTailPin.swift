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
/// frames, and they belong at the tail. That is a fixed number of landings in passes per pin, so a
/// layout that asks again inside its own passes cannot spin there. A tail that will not settle stops
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

    /// A scroll-geometry reading, and the follower's answer to it. A resize takes a turn even when
    /// no landing is wanted, so its flag does not carry into a later landing's count.
    func reading(distance: Double, wants: Bool, resized: Bool, land: @escaping Land) {
        self.land = land
        self.resized = self.resized || resized
        repin.reading(distance: distance, wants: wants, resized: resized)
        if !scrolling, repin.takeInPass() {
            let resizing = self.resized
            self.resized = false
            SHRenderProbe.tick("thread.tailLandingInPass")
            land(resizing)
        }
        if !scrolling, repin.pending || self.resized { schedule() }
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

    /// The transcript left the screen: nothing lands through a proxy that may outlive it.
    func stop() {
        turn?.cancel()
        quiet?.cancel()
        turn = nil
        quiet = nil
        land = nil
        repin = NativeTailRepin()
        scrolling = false
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
        if repin.stalled, !stalled {
            MobileSignposts.tailStalled()
            SHRenderProbe.tick("thread.tailStalled")
        }
        if lands { land?(resizing) }
        watch()
    }

    /// While stalled and left alone, one try after `quietWait`, then again a little later.
    private func watch() {
        quiet?.cancel()
        quiet = nil
        guard repin.stalled, repin.quietTries < NativeTailRepin.maxQuietTries else { return }
        let wait = repin.quietWait
        quiet = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            quiet = nil
            repin.quietPassed()
            schedule()
        }
    }
}
