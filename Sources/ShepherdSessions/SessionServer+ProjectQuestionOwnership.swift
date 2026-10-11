import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// Live native consumption is the evidence. Unknown state or a missing scope alone does
    /// not prove takeover, especially after a reconnect, restart, or failed cancellation.
    func projectScopeWasTakenOver(_ scope: ProjectChildScope?) -> Bool {
        guard let scope, projectChildTakenOver.contains(scope),
              currentProjectChildScope[scope.workerAgentID] != scope,
              let thread = rpcThread(forAgent: scope.workerAgentID),
              thread.piSessionID == scope.sessionID, thread.generation == scope.generation else { return false }
        return true
    }

    public func projectWorkerWasTakenOver(_ id: ProjectID, taskID: ProjectTaskID,
                                         sessionID: String, generation: String) async throws -> Bool {
        try await enqueue {
            let project = try self.runtimeProject(id)
            guard let task = project.tasks.first(where: { $0.id == taskID }), task.destination == .local,
                  task.workerSessionID == sessionID, let thread = self.rpcThread(forAgent: task.workerAgentID),
                  thread.piSessionID == sessionID, thread.generation == generation else { return false }
            return self.projectScopeWasTakenOver(self.projectChildScope(project, task: task, thread: thread))
        }
    }
}
