import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Automations: saved monitoring prompts run by ordinary agents. The
/// automation persists in state.json; its running agent is ephemeral and
/// behaves exactly like any hand-created agent (status, panes, deletion).
extension ShepherdViewModel {
    /// This Mac's automation as the background host's request key; nil until the host connects.
    func localAutomationKey(_ id: AutomationID) -> AutomationKey? {
        localHost.map { AutomationKey(host: $0.id, automation: id) }
    }

    /// One of this Mac's automations' changes, sent to the background host that owns them; a
    /// refusal shows the failed-action dialog. The host's `automationsChanged` brings the result,
    /// and a trigger's change reads its status again here too.
    func sendToLocalHost(_ key: AutomationKey, _ request: RemoteAutomationRequest) {
        Task { @MainActor in
            do { try await remoteHosts.automation(key, request: request) } catch {
                remoteActionError = AutomationsModel.failureText(request, error)
            }
            if request.needsTriggers { refreshAutomationTriggers() }
        }
    }

    func startAutomation(_ id: AutomationID) async throws {
        guard let key = localAutomationKey(id) else { throw BackgroundHostClient.HostStarting() }
        // The run on screen gives way to its replacement.
        let old = state.automations.first { $0.id == id }?.agentID
        let onScreen = old != nil && selectedAgentID == old
        try await remoteHosts.automation(key, request: .run)
        if onScreen, let new = state.automations.first(where: { $0.id == id })?.agentID, new != old,
           state.agents.contains(where: { $0.id == new }) {
            selectAgent(new)
        }
    }

    /// Stop an unscoped run. Project-owned runs require the owner's revision-checked service,
    /// even when a sidebar menu was opened before its association reached the view model.
    func stopAutomation(_ id: AutomationID) {
        if let key = localAutomationKey(id) { sendToLocalHost(key, .stop) }
    }

    func deleteAutomation(_ id: AutomationID) {
        guard state.automations.first(where: { $0.id == id })?.projectID == nil else {
            remoteActionError = "Use the Project's revision-checked automation settings."
            return
        }
        // The host stops its run, removes it and forgets its trigger in one request.
        guard let key = localAutomationKey(id) else { return }
        localAutomationRuns[id] = nil
        sendToLocalHost(key, .delete)
    }

    /// Watches paired hosts' automations once at launch; the background host starts its own.
    func autoStartAutomations() {
        startRemoteAutomationWatch()
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

    /// Turns an automation on (it starts a run when Shepherd launches) or off. A refusal shows
    /// the failed-action dialog.
    func setAutomationEnabled(_ id: AutomationID, _ enabled: Bool) {
        guard let automation = state.automations.first(where: { $0.id == id }), automation.enabled != enabled else { return }
        if let key = localAutomationKey(id) { sendToLocalHost(key, .setEnabled(enabled: enabled)) }
    }

    /// Saves a new automation (`id` nil) or replaces an existing one's name, prompt, folder and
    /// switch, as the agents' `automation_*` tools do. A new one starts no run. Returns its id.
    @discardableResult
    func saveAutomation(_ id: AutomationID?, draft: RemoteAutomationDraft) async throws -> AutomationID {
        guard let host = localHost else { throw BackgroundHostClient.HostStarting() }
        let key = AutomationKey(host: host.id, automation: id ?? AutomationID())
        let request: RemoteAutomationRequest = id == nil ? .create(draft: draft) : .update(draft: draft)
        do { try await remoteHosts.automation(key, request: request) } catch {
            throw AgentStartFailure(message: AutomationsModel.failureText(request, error))
        }
        return key.automation
    }
    /// Reads each of this Mac's automations' runs from the run log (the Automations page).
    func loadLocalAutomationRuns() async {
        var runs: [AutomationID: [AutomationRun]] = [:]
        for automation in state.automations {
            // One the host can't answer keeps what was read before.
            guard let key = localAutomationKey(automation.id),
                  case .runs(let list)? = try? await remoteHosts.automation(key, request: .runs) else {
                runs[automation.id] = localAutomationRuns[automation.id]
                continue
            }
            runs[automation.id] = list
        }
        if runs != localAutomationRuns { localAutomationRuns = runs }
        // The open runs come from the runs read (`AutomationRunLog.openRuns`).
        let open = runs.compactMapValues { list in
            list.last.flatMap { run in run.endedAt == nil || (run.agentID != nil && run.settledAt == nil) ? run : nil }
        }
        if open != openAutomationRuns {
            openAutomationRuns = open
            reconcileSidebarCompletions()
        }
    }
}
