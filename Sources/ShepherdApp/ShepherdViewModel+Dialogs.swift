import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

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

/// The remote worktree sheet: which remote agent's delete it confirms.
struct RemoteWorktreeSheetItem: Identifiable {
    let target: RemoteAgentRef
    var id: RemoteAgentRef { target }
}

/// A host's agent in the Delete agent dialog: the agent as its host last pushed it, and the host the
/// dialog names.
struct RemoteDeleteItem: Identifiable, Hashable {
    let target: RemoteAgentRef
    let agent: Agent
    /// Nil for the background host on this Mac: its threads are This Mac's and take This Mac's words.
    let hostName: String?
    var id: RemoteAgentRef { target }

    static func hostName(_ config: RemoteHostStore.HostConfig) -> String? {
        config.localSocket == nil ? config.name : nil
    }
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

    var automationDeleteAutomation: Automation? {
        get { automationDeleteTarget.flatMap { id in state.automations.first { $0.id == id } } }
        set { automationDeleteTarget = newValue?.id }
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

    /// The remote Delete agent sheet is down. A target whose agent went while it was open (deleted
    /// elsewhere) is cleared, so AppDialogs stops reading the hosts; a newer request's target, whose
    /// agent is still there, stays.
    func remoteDeleteDismissed() {
        if remoteDeleteTarget != nil, remoteDeleteItem == nil { remoteDeleteTarget = nil }
        runAfterDialogDismiss()
    }

    var remoteRenameItem: SheetItem<RemoteAgentRef>? {
        get { remoteRenameTarget.map(SheetItem.init) }
        set { remoteRenameTarget = newValue?.value }
    }

    var remoteWorktreeItem: RemoteWorktreeSheetItem? {
        get { remoteWorktreeSheet.map { RemoteWorktreeSheetItem(target: $0) } }
        set { remoteWorktreeSheet = newValue?.target }
    }

    /// Nil when nothing waits, or when the agent or its host is gone (which dismisses the dialog).
    /// Reads the hosts only while a delete waits.
    var remoteDeleteItem: RemoteDeleteItem? {
        get {
            guard let target = remoteDeleteTarget,
                  let connection = remoteHosts.connections.first(where: { $0.id == target.hostID }),
                  let agent = connection.state.agents.first(where: { $0.id == target.agentID }) else { return nil }
            return RemoteDeleteItem(target: target, agent: agent, hostName: RemoteDeleteItem.hostName(connection.config))
        }
        set { if remoteDeleteTarget != newValue?.target { remoteDeleteTarget = newValue?.target } }
    }

    var actionErrorItem: SheetItem<ActionError>? {
        get { actionError.map(SheetItem.init) }
        set { actionError = newValue?.value }
    }
}
