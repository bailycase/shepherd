import ShepherdCore

extension ShepherdState {
    /// The state with each agent's live fields cleared: what a turn changes (its status, when it last
    /// moved, the question it waits on and why) and the completion each turn end stamps. Equal for two
    /// states that differ in nothing else, so a view that reads only this reruns when the workspace's
    /// structure changes and not for a status report, a send or a question
    /// (`ShepherdViewModel.workspaceStructure`).
    var withoutLiveAgentFields: ShepherdState {
        var structure = self
        for index in structure.agents.indices {
            structure.agents[index].status = .idle
            structure.agents[index].lastActiveAt = nil
            structure.agents[index].waitingOn = nil
            structure.agents[index].waitingReason = nil
            structure.agents[index].completedAt = nil
            structure.agents[index].seenCompletedAt = nil
        }
        return structure
    }
}

extension ShepherdViewModel {
    /// The agent as the workspace's structure holds it: its status, `lastActiveAt`, `waitingOn`,
    /// `waitingReason`, `completedAt` and `seenCompletedAt` read idle or nil, whatever the agent is
    /// doing. For a view that must not rerun for a turn; one that shows the agent's work reads `state`.
    func structuralAgent(_ id: AgentID?) -> Agent? {
        guard let id else { return nil }
        return workspaceStructure.agents.first { $0.id == id }
    }
}
