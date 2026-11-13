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

    /// The reader's place against the tail, which every scroll frame may change: bookkeeping, so not observed. The transcript
    /// draws only the three values below that mirror it, which `follow(_:)` writes when they change.
    @ObservationIgnored private(set) var scrollFollower = NativeScrollFollower()
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
    /// changes nothing it shows redraws nothing. Where `nativeTail`, returning to the tail forgets the turn kept for a reader who
    /// was away.
    func follow(_ next: NativeScrollFollower) {
        let returned = next.sticky && !scrollFollower.sticky
        scrollFollower = next
        if !Self.nativeTail { followerChanges &+= 1 }
        if follows != next.sticky { follows = next.sticky }
        if unseen != next.unseen { unseen = next.unseen }
        if returned, Self.nativeTail { keepTurn(nil) }
    }

    /// A transcript mounting with no turn to restore opens on its bottom anchor, at its tail, so the reader must follow it. One left
    /// detached with nothing kept (SwiftUI can leave the position nil, as after a jump) would sit there with no follow of the tail,
    /// the jump pill showing while the agent runs, and, where the tail guard repairs only a following transcript, a blank one on an
    /// iPad in landscape. Where not `nativeTail` the turn is kept as it was before the transcript opened at its tail, and nothing
    /// changes.
    func mount() {
        guard Self.nativeTail, !restoresTurn, !follows else { return }
        var next = scrollFollower
        next.jumpToLatest()
        follow(next)
    }

    /// SwiftUI's writes through the transcript's position binding. Where `nativeTail` they are not kept while following, and equal
    /// ones notify nothing, so the layout a position change sets off never sees `visibleTurn` change.
    func noteVisibleTurn(_ id: String?) {
        keepTurn(scrollFollower.sticky && Self.nativeTail ? nil : id)
    }

    /// Keeps the oldest loaded turn at the top while older ones load above it, when SwiftUI has none to keep.
    func pinHistoryTurn(_ id: String?) {
        guard visibleTurn == nil, let id else { return }
        keepTurn(id)
    }

    private func keepTurn(_ id: String?) {
        if visibleTurn != id { visibleTurn = id }
        if restoresTurn != (id != nil) { restoresTurn = id != nil }
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
