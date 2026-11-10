import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdProtocol

/// Executor-only ordinary worker creation. No owner placement, hidden Space or caller path.
@MainActor
final class ProjectExecutionController {
    private let hosting: RuntimeHosting
    init(hosting: RuntimeHosting) { self.hosting = hosting }

    func launch(_ assignment: ProjectExecutionAssignment) async throws -> AgentID {
        let server = hosting.server
        guard hosting.settings.projectsEnabled else { throw LogicalProjectsError("unsupported", "Enable Projects in Settings > Experiments.") }
        guard let receipt = server.state.projectExecutions.first(where: { $0.key == assignment.key }),
              receipt.assignment == assignment, receipt.phase == .reserved,
              let space = server.state.spaces.first(where: { $0.id == assignment.executorSpaceID && !$0.hidden && !$0.holdsDesigns && !$0.holdsProjects }) else {
            throw AgentStartFailure(message: "Execution reservation or visible Space is no longer available.")
        }
        if receipt.previousOperationID == nil, let model = assignment.model, !server.modelListing().models.contains(model) {
            throw AgentStartFailure(message: "Selected model is unavailable on this executor.")
        }
        let state = server.state
        if let operation = receipt.previousOperationID {
            guard let previous = state.projectExecutions.first(where: {
                $0.key.operationID == operation && $0.key.ownerID == receipt.key.ownerID && $0.key.projectID == receipt.key.projectID
            }), let entry = previous.matchedUserEntryID,
            let agent = state.agents.first(where: { $0.id == assignment.reservedWorkerID }),
            agent.spaceID == space.id, agent.effectivePiSessionID == previous.sessionID,
            let tab = state.tabs.first(where: { $0.id == agent.tabID }),
            let pane = tab.layout.leaves.first(where: { $0.id == agent.paneID }),
            (pane.cwd as NSString).expandingTildeInPath == (space.path as NSString).expandingTildeInPath else {
                throw AgentStartFailure(message: "The original worker or conversation identity is no longer available.")
            }
            if let session = pane.sessionID, await server.sessionInfo(sessionID: session)?.isAlive == true {
                return agent.id // A manual idle restoration won the race; the receiver revalidates it.
            }
            try await hosting.restartAgent(agent, tab, pane, entry)
            return agent.id
        }
        return try await hosting.startAgent(NewAgentConfig(spaceID: space.id, workingDirectory: space.path,
                                                          reservedAgentID: assignment.reservedWorkerID,
                                                          model: assignment.model,
                                                          thinking: assignment.thinking.flatMap(ThinkingLevel.init(rawValue:)) ?? hosting.settings.agentDefaults.thinking,
                                                          initialPrompt: nil,
                                                          initialName: assignment.title))
    }

    /// Serves executions placed on this executor (`onProjectExecutionLaunch`).
    func install() {
        hosting.server.onProjectExecutionLaunch = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { completion(.failure(AgentStartFailure(message: "Executor closed"))); return }
                do { completion(.success(try await self.launch(request))) }
                catch { completion(.failure(error)) }
            }
        }
    }
}
