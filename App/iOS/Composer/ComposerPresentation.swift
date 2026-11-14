import Foundation
import Observation
import ShepherdRemote
import ShepherdProtocol

/// Sheet and scroll intent belongs to the window, unlike a thread's shared draft/attachments.
@MainActor @Observable
final class ComposerPresentation {
    var choosingModel = false
    var showingContext = false
    // The compact and regular shells rebuild their transcript when the scene changes width.
    // Keep reader intent and disclosures here with this window's existing scroll/find intent.

    /// The reader's place: the follower, which every scroll frame may change, and the turn kept for the next mount. Bookkeeping, so not
    /// observed. The transcript draws only the five values below that mirror it, which `publish()` writes when they change.
    @ObservationIgnored private var place = NativeTranscriptPlace(mountsAtTail: ComposerPresentation.nativeTail)
    var scrollFollower: NativeScrollFollower { place.follower }
    /// How many times the follower changed, counted only where not `nativeTail`: there the transcript draws from every change, as it
    /// did when it observed the follower. Without a render at the finger's touch-down, a drag from the tail there was put back on
    /// it by SwiftUI's next update of the scroll view.
    private(set) var followerChanges = 0
    /// Whether the transcript follows its tail: the size-change anchor, the jump pill and the history gate draw from it.
    private(set) var follows = true
    /// Output arrived while the reader was away from the tail: the jump pill draws from it.
    private(set) var unseen = false
    /// The turn SwiftUI keeps under the top edge, put back there by the next mount of the transcript. Nil while following where
    /// `nativeTail`: a following transcript mounts at its tail, and a turn kept from then would put it back at the top of the
    /// reply it was reading.
    private(set) var visibleTurn: String?
    /// Whether the next mount restores a turn: the initial anchor draws from it, where `nativeTail`.
    private(set) var restoresTurn = false
    /// The last row the transcript had when the bottom marker was kept: what the position handed to SwiftUI depends on besides
    /// `visibleTurn` and `follows`, so the transcript draws again when the marker is kept for another tail.
    private(set) var markerTail: String?
    var openThinking: Set<String> = []
    var editing: NativeQueuedMessage?
    var editText = ""
    private(set) var findRequest: ThreadFindRequest?

    func find(_ entryID: String) { findRequest = ThreadFindRequest(entryID: entryID) }

    /// Whether a following transcript mounts at its tail and leans on SwiftUI's bottom anchors: before iOS 27.1. From 27.1 a bottom
    /// anchor can retain a lazy stack's estimated height after a fold, so the transcript follows by scrolling alone and behaves as it
    /// did before a following transcript mounted at its tail: it keeps the turn it is on whether it follows or not, opens with no
    /// initial anchor, and draws again from every change of the follower (`followerChanges`). A Duo measured this path forced on at 27.1:
    /// a stream of a long reply rests on the tail either way (no landings, against about 320), but a re-open of the long thread mounts the
    /// stack at the end of its estimated height and draws nothing for 26 frames (about 840 ms) until the tail guard repairs it, where this
    /// path draws a row in its second frame. Lift it where `thread-remount-tail` passes on a Duo with it forced on.
    static var nativeTail: Bool {
        if #available(iOS 27.1, *) { false } else { true }
    }

    /// Takes the follower as the transcript changed it, writing what it draws only when that changed, so a scroll frame that
    /// changes nothing it shows redraws nothing.
    func follow(_ next: NativeScrollFollower) {
        place.follow(next)
        if !Self.nativeTail { followerChanges &+= 1 }
        publish()
    }

    /// A transcript mounting with no turn to restore must follow its tail (`NativeTranscriptPlace.mount()`).
    func mount() {
        place.mount()
        publish()
    }

    /// The transcript left the screen: a follower who holds the bottom marker is handed it again once the landing after the next mount
    /// has settled, not at the mount (`NativeTranscriptPlace.leave()`).
    func leave() {
        place.leave()
        publish()
    }

    /// Another session's turns replace the ones kept (`NativeTranscriptPlace.newSession()`).
    func newSession() {
        place.newSession()
        publish()
    }

    /// SwiftUI's writes through the transcript's position binding. Where `nativeTail` they are not kept while following, and equal
    /// ones notify nothing, so the layout a position change sets off never sees `visibleTurn` change. `tail` is the transcript's last
    /// row, which the bottom marker is kept for.
    func noteVisibleTurn(_ id: String?, tail: String? = nil) {
        place.note(id, tail: tail)
        publish()
    }

    /// What the transcript hands SwiftUI as its position: `visibleTurn`, but not the bottom marker once rows have joined after it
    /// (`NativeTranscriptPlace.position(tail:)`). The guard reads the three values that mirror what the answer depends on, so a
    /// change of any of them draws.
    func position(tail: String?) -> String? {
        guard visibleTurn == NativeTranscriptPlace.bottomMarker, follows, markerTail != tail else { return visibleTurn }
        return place.position(tail: tail)
    }

    /// Whether a follower's bottom marker is withheld for the transcript's last row `tail` (`NativeTranscriptPlace.withholdsMarker`).
    func withholdsMarker(tail: String?) -> Bool { place.withholdsMarker(tail: tail) }

    /// The landings after new rows joined have settled: a follower whose marker was withheld keeps it again, for the tail as it is
    /// (`NativeTranscriptPlace.hold(tail:)`). Not while a finger is on the thread.
    func hold(tail: String?) {
        guard !place.follower.userScrolling else { return }
        place.hold(tail: tail)
        publish()
    }

    /// Keeps the oldest loaded turn at the top while older ones load above it, when SwiftUI has none to keep.
    func pinHistoryTurn(_ id: String?) {
        place.pin(id)
        publish()
    }

    private func publish() {
        if follows != place.follows { follows = place.follows }
        if unseen != place.unseen { unseen = place.unseen }
        if visibleTurn != place.turn { visibleTurn = place.turn }
        if restoresTurn != place.restoresTurn { restoresTurn = place.restoresTurn }
        if markerTail != place.markerTail { markerTail = place.markerTail }
    }
}

@MainActor
final class ComposerPresentations {
    private var states: [AgentRef: ComposerPresentation] = [:]

    func state(for ref: AgentRef) -> ComposerPresentation {
        if let state = states[ref] { return state }
        let state = ComposerPresentation()
        states[ref] = state
        return state
    }

    func forget(host: UUID) { states = states.filter { $0.key.host != host } }
}
