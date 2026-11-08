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

/// Lands the transcript on its tail after the layout pass that asked, never inside it: the
/// scroll geometry's action only records, and one main-actor task per run-loop turn asks
/// `NativeTailRepin` whether landing still helps. A tail that will not settle stops being
/// chased, and a quiet watch gives it a try now and then. Not observed: nothing draws from it.
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

    /// A scroll-geometry reading, and the follower's answer to it.
    func reading(distance: Double, wants: Bool, resized: Bool, land: @escaping Land) {
        self.land = land
        self.resized = self.resized || resized
        repin.reading(distance: distance, wants: wants, resized: resized)
        if !scrolling, repin.pending || resized { schedule() }
        watch()
    }

    /// New output at the tail.
    func outputArrived() {
        repin.outputArrived()
        schedule()
    }

    /// The reader sent a message, or asks for the latest: land on the next turn.
    func asked(_ land: @escaping Land) {
        self.land = land
        repin.asked()
        schedule()
    }

    /// A scroll of the reader's started or ended.
    func reader(scrolling: Bool) {
        self.scrolling = scrolling
        repin.reader(scrolling: scrolling)
        if !scrolling, repin.pending { schedule() }
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

    private func run() {
        guard !scrolling else { return }
        let resizing = resized
        resized = false
        let stalled = repin.stalled
        let lands = repin.take()
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
