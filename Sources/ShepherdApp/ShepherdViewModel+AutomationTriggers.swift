import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Triggered automations: the background host's `AutomationTriggers` decides when a run starts and
/// `SessionServer.startTriggeredRun` starts it; this is the app's view of their status and runs,
/// and the Automations page's controls. Project-owned runs' admission is the Project runtime's
/// (`ProjectCoordinatorController.install`).
@MainActor
extension ShepherdViewModel {
    /// Re-reads every triggered automation's status and runs (the Automations page and sidebar).
    func refreshAutomationTriggers() {
        let automations = state.automations.filter(\.isTriggered)
        Task { @MainActor in
            var statuses: [AutomationID: AutomationTriggerStatus] = [:]
            // The host's statuses; one it can't answer keeps what was read before. Each says
            // whether all are paused; with none triggered nothing is.
            for automation in automations {
                guard let key = localAutomationKey(automation.id) else { continue }
                if case .status(let status)? = try? await remoteHosts.automation(key, request: .status) {
                    statuses[automation.id] = status
                } else {
                    statuses[automation.id] = automationTriggerStatuses[automation.id]
                }
            }
            let allPaused = statuses.values.first?.allPaused ?? false
            if statuses != automationTriggerStatuses { automationTriggerStatuses = statuses }
            if allPaused != automationTriggersAllPaused { automationTriggersAllPaused = allPaused }
            await loadLocalAutomationRuns()
            await findRunPullRequests()
        }
    }

    func postAutomationBanner(title: String, body: String) {
        notifications.post(AgentBanners.automation(title: title, body: body))
    }

    /// Finished worktree runs: the PR their branch opened, read once per run through `gh`.
    private func findRunPullRequests() async {
        for (automationID, runs) in localAutomationRuns {
            for run in runs where run.pullRequestURL == nil && run.settledAt != nil {
                guard let agentID = run.agentID, !checkedRunPullRequests.contains(agentID),
                      let agent = state.agents.first(where: { $0.id == agentID }), agent.automationOrigin != nil,
                      let branch = agent.worktreeBranch else { continue }
                checkedRunPullRequests.insert(agentID)
                let cwd = worktreeCheckoutPath(agent)
                let output = await LoginShell.run("gh pr view \(shellQuoted(branch)) --json url --jq .url", cwd: cwd, timeout: 20)
                let url = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if output.status == 0, url.hasPrefix("https://") {
                    if let key = localAutomationKey(automationID) {
                        _ = try? await remoteHosts.automation(key, request: .setRunPullRequest(agentID: agentID, url: url))
                    }
                } else {
                    // Look again after its next turn.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(600))
                        self?.checkedRunPullRequests.remove(agentID)
                    }
                }
            }
        }
    }

    /// The user opened a run's thread: its unread dot goes.
    func markAutomationRunsRead(_ agentID: AgentID) {
        guard localAutomationRuns.values.contains(where: { $0.contains { $0.agentID == agentID && $0.unread } }) else { return }
        for (id, runs) in localAutomationRuns {
            guard let key = localAutomationKey(id) else { continue }
            for run in runs where run.agentID == agentID && run.unread { sendToLocalHost(key, .markRead(runID: run.id)) }
        }
    }

    // MARK: Controls (the Automations page and sidebar)

    func pauseAutomationTrigger(_ id: AutomationID) {
        if let key = localAutomationKey(id) { sendToLocalHost(key, .pause) }
    }

    func resumeAutomationTrigger(_ id: AutomationID) {
        if let key = localAutomationKey(id) { sendToLocalHost(key, .resume) }
    }

    func setAllAutomationTriggersPaused(_ paused: Bool) {
        // The host's request names an automation; any triggered one does.
        guard let key = state.automations.first(where: \.isTriggered).flatMap({ localAutomationKey($0.id) }) else { return }
        sendToLocalHost(key, .setAllPaused(paused: paused))
    }

    func runPendingAutomationEvent(_ id: AutomationID, eventID: String) {
        if let key = localAutomationKey(id) { sendToLocalHost(key, .runEvent(eventID: eventID)) }
    }

    func dismissAutomationEvent(_ id: AutomationID, eventID: String) {
        if let key = localAutomationKey(id) { sendToLocalHost(key, .dismissEvent(eventID: eventID)) }
    }
}
