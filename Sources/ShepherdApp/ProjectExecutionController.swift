import Foundation
import ShepherdCore
import ShepherdProtocol

/// Executor-only ordinary worker creation. No owner placement, hidden Space or caller path.
@MainActor
final class ProjectExecutionController {
    private weak var vm: ShepherdViewModel?
    init(vm: ShepherdViewModel) { self.vm = vm }

    func launch(_ assignment: ProjectExecutionAssignment) async throws -> AgentID {
        guard let vm else { throw AgentStartFailure(message: "Executor closed") }
        guard vm.settings.projectsEnabled else { throw LogicalProjectsError("unsupported", "Enable Projects in Settings > Experiments.") }
        guard let receipt = vm.server.state.projectExecutions.first(where: { $0.key == assignment.key }),
              receipt.assignment == assignment, receipt.phase == .reserved,
              let space = vm.server.state.spaces.first(where: { $0.id == assignment.executorSpaceID && !$0.hidden && !$0.holdsDesigns && !$0.holdsProjects }) else {
            throw AgentStartFailure(message: "Execution reservation or visible Space is no longer available.")
        }
        if receipt.previousOperationID == nil, let model = assignment.model, !vm.server.modelListing().models.contains(model) {
            throw AgentStartFailure(message: "Selected model is unavailable on this executor.")
        }
        vm.sessions.stateDidChange(vm.server.state)
        vm.state = vm.server.state
        if let operation = receipt.previousOperationID {
            guard let previous = vm.state.projectExecutions.first(where: {
                $0.key.operationID == operation && $0.key.ownerID == receipt.key.ownerID && $0.key.projectID == receipt.key.projectID
            }), let entry = previous.matchedUserEntryID,
            let agent = vm.state.agents.first(where: { $0.id == assignment.reservedWorkerID }),
            agent.spaceID == space.id, agent.effectivePiSessionID == previous.sessionID,
            let tab = vm.state.tabs.first(where: { $0.id == agent.tabID }),
            let pane = tab.layout.leaves.first(where: { $0.id == agent.paneID }),
            (pane.cwd as NSString).expandingTildeInPath == (space.path as NSString).expandingTildeInPath else {
                throw AgentStartFailure(message: "The original worker or conversation identity is no longer available.")
            }
            if let session = pane.sessionID, await vm.server.sessionInfo(sessionID: session)?.isAlive == true {
                return agent.id // A manual idle restoration won the race; the receiver revalidates it.
            }
            vm.sessions.detachPane(pane.id)
            vm.sessions.reserveAgentPane(pane.id)
            try await vm.sessions.createAgentSession(pane: pane, tab: tab, agent: agent, openingPrompt: nil,
                                                     requiredHistoryEntryID: entry)
            return agent.id
        }
        return try await vm.startAgent(NewAgentConfig(spaceID: space.id, workingDirectory: space.path,
                                                     reservedAgentID: assignment.reservedWorkerID,
                                                     model: assignment.model, thinking: .medium, initialPrompt: nil,
                                                     initialName: assignment.title), selectAfter: false, focusWindow: false)
    }
}

extension ShepherdViewModel {
    func installProjectExecution() {
        let controller = ProjectExecutionController(vm: self)
        server.onProjectExecutionLaunch = { request, completion in
            Task { @MainActor in
                do { completion(.success(try await controller.launch(request))) }
                catch { completion(.failure(error)) }
            }
        }
    }
}
