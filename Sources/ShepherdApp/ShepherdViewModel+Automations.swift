import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Automations: saved monitoring prompts run by ordinary agents. The
/// automation persists in state.json; its running agent is ephemeral and
/// behaves exactly like any hand-created agent (status, panes, deletion).
extension ShepherdViewModel {
    /// Serve automations through the server: the `automation_*` tools, remote clients and the
    /// trigger clock. Runs start and go through this view model, so panes, selection and the
    /// thread store follow them. Installed once at VM creation, like installPaneControl.
    func installAutomationControl() {
        var hosting = AutomationHosting(
            defaults: { [unowned self] in
                AutomationHosting.Defaults(model: settings.defaultModel(piHome: server.pi.home), thinking: settings.defaultThinking,
                                           serviceTier: settings.defaultServiceTier,
                                           worktreeFetchBeforeCreate: settings.worktreeFetchBeforeCreate,
                                           projectsEnabled: settings.projectsEnabled)
            },
            startAgent: { [unowned self] config in try await startAgent(config, selectAfter: false) },
            deleteAgent: { [unowned self] id in try await deleteAgentPersisted(id) },
            stopRun: { [unowned self] id in deleteAgent(id) })
        // Selected before the old run goes, so its deletion has no selection to fall back from.
        // A run off screen leaves the selection alone.
        hosting.replacingRun = { [unowned self] old, new in if selectedAgentID == old { selectAgent(new) } }
        hosting.stateChanged = { [weak self] in self?.adoptCanonical() }
        hosting.triggersChanged = { [weak self] in self?.refreshAutomationTriggers() }
        hosting.notify = { [weak self] title, body in self?.postAutomationBanner(title: title, body: body) }
        server.serveAutomations(hosting)
        installProjectAutomationAdmission()
    }

    /// This Mac's automation as the background host's request key, while the host owns the
    /// workspace; nil in process.
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
        guard let key = localAutomationKey(id) else { return try await server.startAutomation(id) }
        // The run on screen gives way to its replacement, as `replacingRun` selects it in process.
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
        if let key = localAutomationKey(id) { return sendToLocalHost(key, .stop) }
        do { try server.stopAutomation(id) } catch { remoteActionError = "\(error)" }
    }

    func deleteAutomation(_ id: AutomationID) {
        guard ownerState.automations.first(where: { $0.id == id })?.projectID == nil else {
            remoteActionError = "Use the Project's revision-checked automation settings."
            return
        }
        // The host stops its run, removes it and forgets its trigger in one request.
        if let key = localAutomationKey(id) {
            localAutomationRuns[id] = nil
            return sendToLocalHost(key, .delete)
        }
        stopAutomation(id)
        Task { @MainActor in
            do { try await server.removeAutomation(id) } catch { remoteActionError = "Couldn’t delete the automation: \(error)" }
            await server.automationTriggers.forget(id)
            adoptCanonical()
        }
    }

    /// Auto-start enabled automations once at launch, after the workspace is
    /// adopted. Runs died with the previous app instance; enabled means the
    /// user wants the watch standing.
    func autoStartAutomations() {
        startRemoteAutomationWatch()
        // The background host starts its own at its launch.
        guard localHost == nil else { return }
        let server = server
        Task { @MainActor in await server.autoStartAutomations() }
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
        guard var automation = state.automations.first(where: { $0.id == id }), automation.enabled != enabled else { return }
        automation.enabled = enabled
        if let key = localAutomationKey(id) { return sendToLocalHost(key, .setEnabled(enabled: enabled)) }
        Task { @MainActor in
            do {
                try await server.updateAutomation(automation)
                adoptCanonical()
            } catch {
                remoteActionError = "Couldn't turn the automation \(enabled ? "on" : "off"): \(error)"
            }
        }
    }

    /// Saves a new automation (`id` nil) or replaces an existing one's name, prompt, folder and
    /// switch, as the agents' `automation_*` tools do. A new one starts no run. Returns its id.
    @discardableResult
    func saveAutomation(_ id: AutomationID?, draft: RemoteAutomationDraft) async throws -> AutomationID {
        if let host = localHost {
            let key = AutomationKey(host: host.id, automation: id ?? AutomationID())
            let request: RemoteAutomationRequest = id == nil ? .create(draft: draft) : .update(draft: draft)
            do { try await remoteHosts.automation(key, request: request) } catch {
                throw AgentStartFailure(message: AutomationsModel.failureText(request, error))
            }
            return key.automation
        }
        if let id {
            guard var automation = state.automations.first(where: { $0.id == id }) else {
                throw AgentStartFailure(message: "The automation no longer exists")
            }
            automation.name = draft.name
            automation.prompt = draft.prompt
            automation.cwd = draft.cwd
            automation.enabled = draft.enabled
            try draft.settings?.apply(to: &automation)
            try await server.updateAutomation(automation)
            adoptCanonical()
            refreshAutomationTriggers()
            return id
        }
        var automation = Automation(name: draft.name, prompt: draft.prompt, cwd: draft.cwd, enabled: draft.enabled)
        try draft.settings?.apply(to: &automation)
        try await server.addAutomation(automation)
        adoptCanonical()
        refreshAutomationTriggers()
        return automation.id
    }

    /// Reads each of this Mac's automations' runs from the run log (the Automations page).
    func loadLocalAutomationRuns() async {
        var runs: [AutomationID: [AutomationRun]] = [:]
        for automation in state.automations {
            if let key = localAutomationKey(automation.id) {
                // One the host can't answer keeps what was read before.
                guard case .runs(let list)? = try? await remoteHosts.automation(key, request: .runs) else {
                    runs[automation.id] = localAutomationRuns[automation.id]
                    continue
                }
                runs[automation.id] = list
            } else {
                runs[automation.id] = await server.automationRuns(automation.id)
            }
        }
        if runs != localAutomationRuns { localAutomationRuns = runs }
        // As the client, the open runs come from the runs read (`AutomationRunLog.openRuns`).
        guard localHost != nil else { return }
        let open = runs.compactMapValues { list in
            list.last.flatMap { run in run.endedAt == nil || (run.agentID != nil && run.settledAt == nil) ? run : nil }
        }
        if open != openAutomationRuns {
            openAutomationRuns = open
            reconcileSidebarCompletions()
        }
    }

    private func adoptCanonical() {
        let canonical = server.state
        sessions.stateDidChange(canonical)
        adopt(canonical)
    }
}
