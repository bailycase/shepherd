import Foundation
import ShepherdCore
import ShepherdProtocol

/// Moving an agent one place within its sidebar group on a remote host. The host only moves an
/// agent before another (`RemoteAgentAction.reorder(target:)`), and only within a space; a
/// group is a space's plain agents or its worktree agents, as the Mac's sidebar draws them.
public enum AgentReorder {
    public enum Direction: Hashable, Sendable, CaseIterable { case up, down }

    /// One host request: `agent` goes directly before `before`.
    public struct Move: Hashable, Sendable {
        public var agent: AgentID
        public var before: AgentID

        public init(agent: AgentID, before: AgentID) {
            self.agent = agent
            self.before = before
        }
    }

    /// The group `id` belongs to, in the host's order.
    public static func group(_ agents: [Agent], of id: AgentID) -> [AgentID] {
        guard let agent = agents.first(where: { $0.id == id }) else { return [] }
        return agents.filter { $0.spaceID == agent.spaceID && ($0.worktreeBranch != nil) == (agent.worktreeBranch != nil) }.map(\.id)
    }

    /// The requests that move `id` one place `direction`, in order; empty at the group's end.
    /// Moving down past the last agent is two requests (as the Mac's drop below the last row):
    /// before the next agent, then that agent before it.
    public static func moves(_ agents: [Agent], moving id: AgentID, _ direction: Direction) -> [Move] {
        let group = group(agents, of: id)
        guard let index = group.firstIndex(of: id) else { return [] }
        switch direction {
        case .up:
            guard index > 0 else { return [] }
            return [Move(agent: id, before: group[index - 1])]
        case .down:
            if index + 2 < group.count { return [Move(agent: id, before: group[index + 2])] }
            guard index + 1 < group.count else { return [] }
            let next = group[index + 1]
            return [Move(agent: id, before: next), Move(agent: next, before: id)]
        }
    }
}

/// Renaming an agent: the name the host gets, or nil when there is nothing to send.
public enum AgentRename {
    public static func name(_ text: String, current: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current else { return nil }
        return name
    }
}

/// Deleting a worktree agent from a client, with the Mac's Delete Worktree Agent semantics: the
/// host reports the checkout, its branch and any unreconciled work (`worktreeInfo`); work that
/// would be lost must be acknowledged; the confirmation carries that warning and the checkout's
/// fingerprint, so the host refuses if anything changed since. "Delete agent only" keeps the
/// checkout and branch.
public enum WorktreeDeletion {
    public static func canDelete(_ info: RemoteWorktreeInfo?, acknowledged: Bool, submitting: Bool) -> Bool {
        guard let info, !submitting else { return false }
        return info.warning == nil || acknowledged
    }

    /// The confirmed request for `operationID`.
    public static func query(_ info: RemoteWorktreeInfo, operationID: UUID) -> RemoteAgentQuery {
        .deleteWorktree(operationID: operationID, confirmedWarning: info.warning, fingerprint: info.fingerprint)
    }

    public static func lossMessage(_ warning: String) -> String {
        "\(warning) will be lost with the worktree."
    }

    /// What a failed start means. A host refusal left nothing running, so the operation is
    /// forgotten; anything else (a dropped connection, a timeout) may have started it, so its
    /// status is still checked and the delete is never sent again.
    public enum StartFailure: Equatable, Sendable {
        case refused(String)
        case unknown(String)
    }

    public static func startFailure(_ error: Error) -> StartFailure {
        if case RemoteHostClientError.rejected(_, let message) = error { return .refused(message) }
        return .unknown("Outcome not yet known: \(error). Don’t delete again; its status is checked when the host answers.")
    }
}
