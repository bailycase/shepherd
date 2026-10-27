import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// A sheet item for a value that is not itself `Identifiable` (a remote agent, an error).
struct SheetItem<Value: Hashable>: Identifiable {
    let value: Value
    var id: Value { value }
}

/// A failed action for the error sheet: its title says what was attempted, the message why it failed.
struct ActionError: Hashable {
    static let genericTitle = "Something went wrong"
    var title: String
    var message: String

    /// The error as a sentence: a `LocalizedError`'s description, a `ChangesError`'s message, a
    /// `CustomStringConvertible`'s text, else Foundation's wording. Never a Swift value dump.
    static func describe(_ error: Error) -> String {
        if let changes = error as? ChangesError { return changes.message }
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        if let text = error as? CustomStringConvertible { return text.description }
        return error.localizedDescription
    }
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

    var agentDeleteAgent: Agent? {
        get { agent(id: agentDeleteTarget) }
        set { agentDeleteTarget = newValue?.id }
    }

    /// Runs the action a confirmed dialog left for after its dismissal, once.
    func runAfterDialogDismiss() {
        let action = afterDialogDismiss
        afterDialogDismiss = nil
        action?()
    }

    var remoteRenameItem: SheetItem<RemoteAgentRef>? {
        get { remoteRenameTarget.map(SheetItem.init) }
        set { remoteRenameTarget = newValue?.value }
    }

    var remoteWorktreeItem: RemoteWorktreeSheetItem? {
        get { remoteWorktreeSheet.map { RemoteWorktreeSheetItem(target: $0, finalize: remoteWorktreeFinalize) } }
        set { remoteWorktreeSheet = newValue?.target }
    }

    var actionErrorItem: SheetItem<ActionError>? {
        get { actionError.map(SheetItem.init) }
        set { actionError = newValue?.value }
    }
}
