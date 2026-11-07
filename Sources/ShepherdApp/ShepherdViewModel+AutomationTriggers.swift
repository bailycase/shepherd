import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Triggered automations: the server's `AutomationTriggers` decides when a run starts and
/// `SessionServer.startTriggeredRun` starts it; this is the app's view of their status and runs,
/// the Project admission of Project-owned runs, and the Automations page's controls.
@MainActor
extension ShepherdViewModel {
    /// Project-owned runs become Project tasks through the Project runtime's own `assign`, which
    /// reserves the task in the Project's ledger under its threads-at-once, time and pause rules
    /// and launches its worker; a repeated operation id is the same task, never a second one.
    func installProjectAutomationAdmission() {
        server.onProjectAutomationRun = { [weak self] projectID, revision, automationID, title, prompt, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(AgentStartFailure(message: "Owner closed"))) }
                do {
                    guard let automation = self.state.automations.first(where: { $0.id == automationID }),
                          let project = self.state.projects.first(where: { $0.id == projectID }),
                          let space = self.state.projectRunSpace(project, cwd: automation.cwd) else {
                        throw LogicalProjectsError("no_such_space", "Link the automation's folder to the Project first.")
                    }
                    let operation = UUID()
                    let updated = try await self.projectCoordinator.perform(
                        projectID: projectID, expectedRevision: revision,
                        request: .assign(operationID: operation, spaceID: space, title: title, prompt: prompt,
                                         model: automation.model, thinking: automation.thinking?.rawValue))
                    guard let task = updated.tasks.first(where: { $0.operationID == operation }) else {
                        throw LogicalProjectsError("conflict", "The Project didn't keep the run's task.")
                    }
                    completion(.success(task.id))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Re-reads every triggered automation's status and runs (the Automations page and sidebar).
    func refreshAutomationTriggers() {
        let triggers = server.automationTriggers
        let automations = state.automations.filter(\.isTriggered)
        Task { @MainActor in
            var statuses: [AutomationID: AutomationTriggerStatus] = [:]
            for automation in automations { statuses[automation.id] = await triggers.status(of: automation) }
            let allPaused = await triggers.allPaused
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
        for (_, runs) in localAutomationRuns {
            for run in runs where run.pullRequestURL == nil && run.settledAt != nil {
                guard let agentID = run.agentID, !checkedRunPullRequests.contains(agentID),
                      let agent = state.agents.first(where: { $0.id == agentID }), agent.automationOrigin != nil,
                      let branch = agent.worktreeBranch else { continue }
                checkedRunPullRequests.insert(agentID)
                let cwd = worktreeCheckoutPath(agent)
                let output = await LoginShell.run("gh pr view \(shellQuoted(branch)) --json url --jq .url", cwd: cwd, timeout: 20)
                let url = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if output.status == 0, url.hasPrefix("https://") {
                    await server.setAutomationRunPullRequest(agentID: agentID, url: url)
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
        Task { @MainActor in
            await server.markAutomationRunsRead(agentID: agentID)
            await loadLocalAutomationRuns()
        }
    }

    // MARK: Controls (the Automations page and sidebar)

    func pauseAutomationTrigger(_ id: AutomationID) {
        let triggers = server.automationTriggers
        Task { await triggers.pause(id); refreshAutomationTriggers() }
    }

    func resumeAutomationTrigger(_ id: AutomationID) {
        let triggers = server.automationTriggers
        Task { await triggers.resume(id); await triggers.tick(); refreshAutomationTriggers() }
    }

    func setAllAutomationTriggersPaused(_ paused: Bool) {
        let triggers = server.automationTriggers
        Task { await triggers.setAllPaused(paused); refreshAutomationTriggers() }
    }

    func runPendingAutomationEvent(_ id: AutomationID, eventID: String) {
        guard let automation = state.automations.first(where: { $0.id == id }) else { return }
        let triggers = server.automationTriggers
        Task { @MainActor in
            do { try await triggers.runPending(automation, eventID: eventID) } catch {
                remoteActionError = "Couldn't start the run: \(error)"
            }
            refreshAutomationTriggers()
        }
    }

    func dismissAutomationEvent(_ id: AutomationID, eventID: String) {
        let triggers = server.automationTriggers
        Task { await triggers.dismiss(id, eventID: eventID); refreshAutomationTriggers() }
    }
}
