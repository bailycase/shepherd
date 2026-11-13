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
    /// Whether the transcript follows its tail: the size-change anchor, the jump pill and the history gate draw from it.
    private(set) var follows = true
    /// Output arrived while the reader was away from the tail: the jump pill draws from it.
    private(set) var unseen = false
    /// The turn SwiftUI keeps under the top edge while the reader is away from the tail, put back there by the next mount of
    /// the transcript. Nil while following: a following transcript mounts at its tail, and a turn kept from then would put it
    /// back at the top of the reply it was reading.
    private(set) var visibleTurn: String?
    /// Whether the next mount restores a turn: the initial anchor draws from it.
    private(set) var restoresTurn = false
    var openThinking: Set<String> = []
    var editing: NativeQueuedMessage?
    var editText = ""
    private(set) var findRequest: ThreadFindRequest?

    func find(_ entryID: String) { findRequest = ThreadFindRequest(entryID: entryID) }

    /// Takes the follower as the transcript changed it, writing what it draws only when that changed, so a scroll frame that
    /// changes nothing it shows redraws nothing. Returning to the tail forgets the turn kept for a reader who was away.
    func follow(_ next: NativeScrollFollower) {
        let returned = next.sticky && !scrollFollower.sticky
        scrollFollower = next
        if follows != next.sticky { follows = next.sticky }
        if unseen != next.unseen { unseen = next.unseen }
        if returned { keepTurn(nil) }
    }

    /// SwiftUI's writes through the transcript's position binding. While following they are not kept, and equal ones notify nothing,
    /// so the layout a position change sets off never sees `visibleTurn` change.
    func noteVisibleTurn(_ id: String?) {
        keepTurn(scrollFollower.sticky ? nil : id)
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
