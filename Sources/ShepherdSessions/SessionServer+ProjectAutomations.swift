import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// User-only owner entry point. The adapter MUST reserve a ProjectTask slot/activation before
    /// async work, launch idle, and revalidate before native send. It owns failed/unknown/settled
    /// accounting in that same ledger; callback success means admission, not task success.
    public func runProjectAutomation(projectID: ProjectID, expectedRevision: UInt64,
                                     automationID: AutomationID) async throws -> ProjectTaskID {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.requireStarted()
                    try self.requireProjectsEnabled()
                    guard let project = self.store.state.projects.first(where: { $0.id == projectID }) else {
                        throw LogicalProjectsError("no_such_project", "Project no longer exists.")
                    }
                    guard project.revision == expectedRevision else {
                        throw LogicalProjectsError("stale_project", "Project changed. Refresh before running its automation.")
                    }
                    guard !project.paused, !project.interruptPending else {
                        throw LogicalProjectsError("project_paused", "Resume the Project before running its automation.")
                    }
                    guard let automation = self.store.state.automations.first(where: { $0.id == automationID }),
                          automation.projectID == projectID else {
                        throw LogicalProjectsError("project_scope", "Automation does not belong to this Project.")
                    }
                    guard automation.enabled else {
                        throw LogicalProjectsError("automation_disabled", "Enable the automation before running it.")
                    }
                    guard let admit = self.onProjectAutomationRun else {
                        throw LogicalProjectsError("unsupported", "Project automation admission is unavailable on this owner; no run was started.")
                    }
                    let epoch = self.logicalProjectEpoch, generation = self.projectsGeneration
                    admit(projectID, expectedRevision, automationID) { result in
                        self.queue.async {
                            do {
                                let taskID = try result.get()
                                try self.requireStarted()
                                try self.requireProjectsEnabled()
                                guard self.logicalProjectEpoch == epoch, self.projectsGeneration == generation,
                                      let current = self.store.state.projects.first(where: { $0.id == projectID }),
                                      !current.paused, !current.interruptPending,
                                      self.store.state.automations.contains(where: { $0.id == automationID && $0.projectID == projectID && $0.enabled }),
                                      current.tasks.contains(where: { $0.id == taskID }) else {
                                    throw LogicalProjectsError("conflict", "Project automation admission was revoked; inspect the Project before retrying.")
                                }
                                continuation.resume(returning: taskID)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Called inside the existing staged, revision-checked Project settings transaction.
    func applyProjectAutomation(_ action: ProjectAutomationAction, id: AutomationID,
                                projectID: ProjectID, to state: inout ShepherdState) throws {
        let index = state.automations.firstIndex { $0.id == id }
        switch action {
        case .create(let draft):
            guard index == nil else { throw LogicalProjectsError("conflict", "Automation ID already exists.") }
            let fields = try Self.validatedAutomation(draft).get()
            state.automations.append(Automation(id: id, name: fields.name, prompt: fields.prompt,
                                               cwd: fields.cwd, enabled: draft.enabled, projectID: projectID))
        case .link:
            guard let index else { throw LogicalProjectsError("no_such_automation", "Automation no longer exists.") }
            guard state.automations[index].projectID == nil else {
                throw LogicalProjectsError("project_scope", "Automation already belongs to a Project.")
            }
            guard state.automations[index].agentID == nil, !automationStarts.contains(id) else {
                throw LogicalProjectsError("conflict", "Stop the automation before linking it to a Project.")
            }
            state.automations[index].projectID = projectID
        case .update, .setEnabled, .delete:
            guard let index, state.automations[index].projectID == projectID else {
                throw LogicalProjectsError("project_scope", "Automation does not belong to this Project.")
            }
            switch action {
            case .update(let draft):
                let fields = try Self.validatedAutomation(draft).get()
                state.automations[index].name = fields.name
                state.automations[index].prompt = fields.prompt
                state.automations[index].cwd = fields.cwd
                state.automations[index].enabled = draft.enabled
            case .setEnabled(let enabled): state.automations[index].enabled = enabled
            case .delete: state.automations.remove(at: index)
            default: break
            }
        }
        let owned = state.automations.filter { $0.projectID == projectID }
        guard owned.count <= 64, try JSONEncoder().encode(owned).count <= Project.maximumEncodedCollectionBytes else {
            throw LogicalProjectsError("project_limit", "Project automations exceed 64 records or 512 KiB.")
        }
    }

    /// Applied before every workspace commit, including runtime Pause and Project deletion.
    /// Watchers are ephemeral; ordinary Project workers and their worktrees are never removed.
    static func reconcileProjectAutomations(_ state: inout ShepherdState, before: ShepherdState) {
        let projects = Set(state.projects.map(\.id))
        state.automations.removeAll { $0.projectID.map { !projects.contains($0) } ?? false }
        var removed = Set<AgentID>()
        for old in before.automations where old.projectID != nil {
            guard let agent = old.agentID else { continue }
            let current = state.automations.first { $0.id == old.id }
            let project = state.projects.first { $0.id == old.projectID }
            if current == nil || current?.enabled == false || project == nil || project?.paused == true {
                removed.insert(agent)
            }
        }
        // Only a watcher in the reserved automation Space is owned here. A corrupt reference
        // must never authorize deletion of an ordinary worker or its checkout.
        removed = removed.filter { id in
            before.agents.contains { agent in
                agent.id == id && before.spaces.contains { $0.id == agent.spaceID && $0.holdsAutomations }
            }
        }
        let tabs = Set(state.agents.filter { removed.contains($0.id) }.map(\.tabID))
        state.agents.removeAll { removed.contains($0.id) }
        state.tabs.removeAll { tabs.contains($0.id) || $0.inspectorFor.map(removed.contains) == true }
        for i in state.automations.indices where state.automations[i].agentID.map(removed.contains) == true {
            state.automations[i].agentID = nil
        }
    }

    /// Fences linking while an ordinary automation launch crosses async creation stages.
    public func beginAutomationStart(_ id: AutomationID) async throws {
        try await enqueue {
            guard let automation = self.store.state.automations.first(where: { $0.id == id }) else {
                throw SessionServerError.noSuchAutomation(id)
            }
            guard automation.projectID == nil else { throw Self.projectAutomationScopeError }
            guard self.automationStarts.insert(id).inserted else {
                throw LogicalProjectsError("conflict", "Automation is already starting.")
            }
        }
    }

    public func endAutomationStart(_ id: AutomationID) async {
        _ = try? await enqueue { self.automationStarts.remove(id) }
    }

    static var projectAutomationScopeError: LogicalProjectsError {
        LogicalProjectsError("project_scope", "Use the Project's revision-checked automation settings; legacy automation actions cannot change Project-owned records.")
    }
}
