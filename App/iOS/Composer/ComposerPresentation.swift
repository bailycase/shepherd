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
    /// observed. The transcript draws only the four values below that mirror it, which `publish()` writes when they change.
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
    var openThinking: Set<String> = []
    var editing: NativeQueuedMessage?
    var editText = ""
    private(set) var findRequest: ThreadFindRequest?

    func find(_ entryID: String) { findRequest = ThreadFindRequest(entryID: entryID) }

    /// Whether a following transcript mounts at its tail and leans on SwiftUI's bottom anchors: before iOS 27.1. From 27.1 a bottom
    /// anchor can retain a lazy stack's estimated height after a fold, so the transcript follows by scrolling alone and behaves as it
    /// did before a following transcript mounted at its tail: it keeps the turn it is on whether it follows or not, opens with no
    /// initial anchor, and draws again from every change of the follower (`followerChanges`). No iPhone Duo has measured a mount at the
    /// tail there (a long reply under a bottom initial anchor); lift it here once one has.
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

    /// SwiftUI's writes through the transcript's position binding. Where `nativeTail` they are not kept while following, and equal
    /// ones notify nothing, so the layout a position change sets off never sees `visibleTurn` change.
    func noteVisibleTurn(_ id: String?) {
        place.note(id)
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
