import Foundation
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Automations: saved monitoring prompts run by ordinary agents. The
/// automation persists in state.json; its running agent is ephemeral and
/// behaves exactly like any hand-created agent (status, panes, deletion).
extension ShepherdViewModel {
    /// Serve automation socket requests (the pi automation skill): full
    /// CRUD + run control. Installed once at VM creation, like
    /// installPaneControl.
    func installAutomationControl() {
        server.onAutomationRequest = { [weak self] request, completion in
            guard let self else {
                completion(.failed(code: "shutdown", message: "host is shutting down"))
                return
            }
            Task { @MainActor in
                completion(await self.handleAutomationRequest(request))
            }
        }
    }

    private func handleAutomationRequest(_ request: AutomationRequest) async -> AutomationOutcome {
        do {
            switch request {
            case .create(let automation, let start):
                try await server.addAutomation(automation)
                if start {
                    try await startAutomation(automation.id)
                }
                return .ok
            case .list:
                return .automations(state.automations.map { automation in
                    AutomationInfo(
                        id: automation.id,
                        name: automation.name,
                        prompt: automation.prompt,
                        cwd: automation.cwd,
                        enabled: automation.enabled,
                        agentStatus: automationAgent(automation)?.status.rawValue
                    )
                })
            case .update(let automationID, let name, let prompt, let cwd, let enabled):
                guard var automation = state.automations.first(where: { $0.id == automationID }) else {
                    return .failed(code: "not_found", message: "unknown automation \(automationID)")
                }
                if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    automation.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let prompt, !prompt.isEmpty { automation.prompt = prompt }
                if let cwd, !cwd.isEmpty { automation.cwd = cwd }
                if let enabled { automation.enabled = enabled }
                try await server.updateAutomation(automation)
                adoptCanonical()
                return .ok
            case .delete(let automationID):
                guard state.automations.contains(where: { $0.id == automationID }) else {
                    return .failed(code: "not_found", message: "unknown automation \(automationID)")
                }
                // Stop the run too: a skill deleting an automation means
                // "make it gone", not "orphan its agent".
                stopAutomation(automationID)
                try await server.removeAutomation(automationID)
                adoptCanonical()
                return .ok
            case .start(let automationID):
                try await startAutomation(automationID)
                return .ok
            case .stop(let automationID):
                guard state.automations.contains(where: { $0.id == automationID }) else {
                    return .failed(code: "not_found", message: "unknown automation \(automationID)")
                }
                stopAutomation(automationID)
                return .ok
            }
        } catch {
            return .failed(code: "failed", message: String(describing: error))
        }
    }

    /// Start an automation's agent in the reserved hidden space with the stored prompt, and
    /// record the link on the automation. A run still going (or still being started) refuses.
    /// A settled one is replaced once the new run exists (its run stays in the log), so a
    /// settled run on screen hands the workspace straight to the new run's thread.
    func startAutomation(_ id: AutomationID) async throws {
        guard let previous = state.automations.first(where: { $0.id == id }) else {
            throw AgentStartFailure(message: "automation no longer exists")
        }
        guard startingAutomations.insert(id).inserted else {
            throw AgentStartFailure(message: "\(previous.name) is already running")
        }
        defer { startingAutomations.remove(id) }
        let settled = try await settledRun(of: previous)
        guard let automation = state.automations.first(where: { $0.id == id }), automation.agentID == settled else { return }

        let cwd = (automation.cwd as NSString).expandingTildeInPath
        // Watch agents always live in the reserved hidden space — the
        // AUTOMATIONS section is their only surface, never a space's thread
        // rows. The space is just sidebar grouping; the agent's pane runs in
        // the automation's own cwd regardless.
        let spaceID = try await automationsSpaceID()

        let config = NewAgentConfig(
            spaceID: spaceID,
            workingDirectory: cwd,
            model: settings.agentDefaults.model,
            thinking: settings.defaultThinking,
            initialPrompt: automation.prompt,
            isAutomation: true
        )
        let agentID = try await startAgent(config, selectAfter: false)
        // Wear the automation's name; it was chosen deliberately.
        try? await server.renameAgent(agentID, to: automation.name)

        // Re-read: the automation may have been edited while its run started.
        var updated = state.automations.first { $0.id == id } ?? automation
        updated.agentID = agentID
        try await server.updateAutomation(updated)
        adoptCanonical()

        guard let settled, state.agents.contains(where: { $0.id == settled }) else { return }
        // Selected before the old run goes, so its deletion has no selection to fall back from.
        // A run off screen leaves the selection alone.
        if selectedAgentID == settled { selectAgent(agentID) }
        try await deleteAgentPersisted(settled)
    }

    /// The agent of an automation's settled run, which its next run replaces; nil when it has
    /// none. A live run (`AutomationRun.isLive`) throws instead: running again never cuts one short.
    private func settledRun(of automation: Automation) async throws -> AgentID? {
        guard let agentID = automation.agentID else { return nil }
        let run = await server.automationRuns(automation.id).last { $0.agentID == agentID }
        // Read after the runs: its agent may have gone, or started a turn, meanwhile.
        guard state.automations.first(where: { $0.id == automation.id })?.agentID == agentID,
              let agent = state.agents.first(where: { $0.id == agentID }) else { return nil }
        guard !AutomationRun.isLive(agentStatus: agent.status, run: run) else {
            throw AgentStartFailure(message: "\(automation.name) is already running")
        }
        return agentID
    }

    /// Stop an automation's run by deleting its agent (the automation itself
    /// stays saved; deleteAgent clears the back-reference server-side).
    func stopAutomation(_ id: AutomationID) {
        guard let agentID = state.automations.first(where: { $0.id == id })?.agentID else { return }
        deleteAgent(agentID)
    }

    func deleteAutomation(_ id: AutomationID) {
        stopAutomation(id)
        Task { @MainActor in
            try? await server.removeAutomation(id)
            adoptCanonical()
        }
    }

    /// Auto-start enabled automations once at launch, after the workspace is
    /// adopted. Runs died with the previous app instance; enabled means the
    /// user wants the watch standing.
    func autoStartAutomations() {
        let pending = state.automations.filter { $0.enabled && $0.agentID == nil }
        guard !pending.isEmpty else { return }
        Task { @MainActor in
            for automation in pending {
                do {
                    try await startAutomation(automation.id)
                } catch {
                    NSLog("Shepherd: automation \(automation.name) failed to start: \(error)")
                }
            }
        }
    }

    /// The reserved hidden space hosting automation agents whose cwd matches
    /// no user space. Created on first use; never rendered as a space row.
    private func automationsSpaceID() async throws -> SpaceID {
        if let existing = state.spaces.first(where: { $0.hidden }) {
            return existing.id
        }
        let space = Space(name: "Automations", path: "~", hidden: true)
        try await server.addSpace(space)
        adoptCanonical()
        return space.id
    }

    /// The agent currently running an automation, if any.
    func automationAgent(_ automation: Automation) -> Agent? {
        automation.agentID.flatMap { id in state.agents.first { $0.id == id } }
    }

    /// The run log's open run of that agent; nil while the log has not caught up with it.
    func automationRun(_ automation: Automation, agent: Agent?) -> AutomationRun? {
        guard let agent, let run = openAutomationRuns[automation.id], run.agentID == agent.id else { return nil }
        return run
    }

    /// Run Now from the sidebar. A refusal (its run is still going, the automation is gone)
    /// shows the failed-action dialog rather than doing nothing.
    func runAutomationNow(_ id: AutomationID) {
        Task { @MainActor in
            do {
                try await startAutomation(id)
            } catch {
                remoteActionError = String(describing: error)
            }
        }
    }

    private func adoptCanonical() {
        let canonical = server.state
        sessions.stateDidChange(canonical)
        adopt(canonical)
    }
}
