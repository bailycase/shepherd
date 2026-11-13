import Foundation

/// Hands the bottom marker back to SwiftUI after new rows joined a following transcript whose reader had kept it.
///
/// SwiftUI keeps a view on the tail through everything that grows it while the bottom marker is its position, and lands a
/// reply's growth with a handful of landings. The pass that adds rows after the marker resolves it against the lazy stack's
/// estimate, though, so a follower who kept it has it withheld there (`NativeTranscriptPlace.position(tail:)`) and the pin lands the
/// view instead. Once a landing has been made and `MobileLayout.tailHoldWait` has passed with no row joining since, the layout of
/// those rows is settled and the marker is the position again, which is what stops the pin landing for every step of the reply.
/// A follower whose marker was never withheld starts no wait (`NativeTranscriptPlace.withholdsMarker(tail:)`).
@MainActor
final class ThreadTailHold {
    private var wait: Task<Void, Never>?
    /// The transcript is off the screen: a landing asked for before it left starts no wait.
    private var stopped = false

    /// A landing was made: the marker is held again after the wait, once however many landings come meanwhile.
    func landed(hold: @escaping @MainActor () -> Void) {
        guard wait == nil, !stopped else { return }
        wait = Task { @MainActor [weak self] in
            try? await Task.sleep(for: MobileLayout.tailHoldWait)
            guard !Task.isCancelled, let self else { return }
            wait = nil
            hold()
        }
    }

    /// The transcript left the screen: nothing is held for a view that may be gone.
    func stop() {
        stopped = true
        wait?.cancel()
        wait = nil
    }

    /// The transcript is on the screen again: a screen pushed over the thread was popped.
    func resume() { stopped = false }
}
