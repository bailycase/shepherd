import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Undo and Redo of an agent's turn from its "Edited N files" card (ChangesStates ›
/// ChangesCard): the host puts back the files the turn changed, in the working tree and nothing
/// else, and refuses, naming the files, when any changed since. No dialog: Redo undoes an Undo
/// until the next turn starts. The card follows the host's record in the next snapshot; this
/// store holds only what is on its way and why the host refused.
@MainActor
@Observable
final class TurnUndoStore {
    static let shared = TurnUndoStore()

    /// Turns whose Undo or Redo is on its way.
    private(set) var busy: Set<UUID> = []
    /// Why the host refused, for the alert.
    var failure: Failure?

    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    func undo(_ turnID: UUID, ref: AgentRef, hosts: MobileHosts, threads: ThreadStores) {
        run(.changesUndoTurn(turnID: turnID), turnID: turnID, title: "Couldn't undo the agent's edits", ref: ref, hosts: hosts, threads: threads)
    }

    func redo(_ turnID: UUID, ref: AgentRef, hosts: MobileHosts, threads: ThreadStores) {
        run(.changesRedoTurn(turnID: turnID), turnID: turnID, title: "Couldn't redo the agent's edits", ref: ref, hosts: hosts, threads: threads)
    }

    private func run(_ query: RemoteAgentQuery, turnID: UUID, title: String, ref: AgentRef, hosts: MobileHosts, threads: ThreadStores) {
        guard !busy.contains(turnID) else { return }
        guard let client = hosts.host(ref.host)?.connectedClient else {
            failure = Failure(title: title, message: "The host is offline.")
            return
        }
        busy.insert(turnID)
        Task {
            defer { busy.remove(turnID) }
            do {
                guard case .changesTurn = try await client.agentQuery(agentID: ref.agent, query: query) else {
                    throw RemoteReviewError.unexpectedReply
                }
                // The card follows the host's record: pull it now rather than at the next poll.
                await threads.store(for: ref).refresh()
                // A review of the turn compares the files as they are now.
                ReviewStores.shared.store(for: ref).refresh()
            } catch {
                failure = Failure(title: title, message: reviewErrorText(error))
            }
        }
    }
}

extension View {
    /// The alert for an Undo or Redo the host refused.
    func turnUndoAlert() -> some View {
        modifier(TurnUndoAlert())
    }
}

private struct TurnUndoAlert: ViewModifier {
    func body(content: Content) -> some View {
        let store = TurnUndoStore.shared
        content.alert(store.failure?.title ?? "", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } }),
                      presenting: store.failure) { _ in
            Button("OK", role: .cancel) { store.failure = nil }
        } message: { failure in
            Text(failure.message)
        }
    }
}
