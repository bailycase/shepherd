import Foundation
import ShepherdCore

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

    var actionErrorItem: SheetItem<String>? {
        get { remoteActionError.map(SheetItem.init) }
        set { remoteActionError = newValue?.value }
    }
}
