import Foundation
import Observation
import ShepherdRemote
import ShepherdProtocol

/// Sheet and scroll intent belongs to the window, unlike a thread's shared draft/attachments.
@MainActor @Observable
final class ComposerPresentation {
    var choosingModel = false
    var showingContext = false
    var editing: NativeQueuedMessage?
    var editText = ""
    private(set) var findRequest: ThreadFindRequest?

    func find(_ entryID: String) { findRequest = ThreadFindRequest(entryID: entryID) }
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
