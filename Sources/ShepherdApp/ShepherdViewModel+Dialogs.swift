import Foundation
import ShepherdCore
import ShepherdSessions

/// A sheet item for a value that is not itself `Identifiable` (a remote agent, an error).
struct SheetItem<Value: Hashable>: Identifiable {
    let value: Value
    var id: Value { value }
}

/// The remote worktree sheet: which remote agent, and whether it finalizes or deletes.
struct RemoteWorktreeSheetItem: Identifiable {
    let target: RemoteAgentRef
    let finalize: Bool
    var id: RemoteAgentRef { target }
}

/// `sheet(item:)` spellings of the dialog targets the menus, palette and sidebar set by id.
/// The sheet receives the value it opened with, so its content never goes blank while it
/// animates away, and a target that disappears (a deleted agent) dismisses its sheet.
extension ShepherdViewModel {
    var worktreeSheetSpace: Space? {
        get { worktreeSheetTarget.flatMap { id in state.spaces.first { $0.id == id } } }
        set { worktreeSheetTarget = newValue?.id }
    }

    var spaceRenameSpace: Space? {
        get { spaceRenameTarget.flatMap { id in state.spaces.first { $0.id == id } } }
        set { spaceRenameTarget = newValue?.id }
    }

    var spaceDeleteSpace: Space? {
        get { spaceDeleteTarget.flatMap { id in state.spaces.first { $0.id == id } } }
        set { spaceDeleteTarget = newValue?.id }
    }

    var agentRenameAgent: Agent? {
        get { agent(id: agentRenameTarget) }
        set { agentRenameTarget = newValue?.id }
    }

    var worktreeDeleteAgent: Agent? {
        get { agent(id: worktreeDeleteTarget) }
        set { worktreeDeleteTarget = newValue?.id }
    }

    var remoteRenameItem: SheetItem<RemoteAgentRef>? {
        get { remoteRenameTarget.map(SheetItem.init) }
        set { remoteRenameTarget = newValue?.value }
    }

    var remoteWorktreeItem: RemoteWorktreeSheetItem? {
        get { remoteWorktreeSheet.map { RemoteWorktreeSheetItem(target: $0, finalize: remoteWorktreeFinalize) } }
        set { remoteWorktreeSheet = newValue?.target }
    }

    /// A peer's deletion request. The sheet closes only through its buttons or the request
    /// lapsing; any other dismissal counts as Cancel, so the requesting agent always hears back.
    var peerDeleteItem: PeerDeleteConfirmation? {
        get { peerDeleteConfirmation }
        set {
            guard newValue == nil, let pending = peerDeleteConfirmation else { return }
            cancelPeerDeletion(requestID: pending.requestID)
        }
    }

    /// The call the approval dialog shows: the oldest waiting, once the Delete agent dialog is not
    /// up (one sheet at a time). Only the dialog's buttons answer, and its ⎋ is Deny, so a dismissal
    /// the sheet reports changes nothing: with several waiting, the queue's next call must not be
    /// denied for the one just answered. A call nobody answers is denied by the server's timeout.
    var peerApprovalItem: AgentApprovalPrompt? {
        get { peerDeleteConfirmation == nil ? peerApprovals.first : nil }
        set {}
    }

    var actionErrorItem: SheetItem<String>? {
        get { remoteActionError.map(SheetItem.init) }
        set { remoteActionError = newValue?.value }
    }
}
