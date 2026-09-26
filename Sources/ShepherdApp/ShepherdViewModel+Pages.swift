import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The Automations and Hosts pages' models, derived from the workspace and each host's
// connection, and what their buttons do. This Mac is a host among the others here
// (`PageHost.localID`); a key on it acts on this Mac's server, any other on its host.

extension ShepherdViewModel {
    // MARK: Automations

    /// This Mac, then every configured host, as the shared automations presentation reads them.
    var automationHosts: [AutomationHost] {
        [AutomationHost(id: PageHost.localID, name: PageHost.localName, connected: true, manageable: true, state: state)]
            + remoteHosts.connections.map { connection in
                AutomationHost(id: connection.id, name: connection.config.name, connected: connection.phase == .connected,
                               manageable: connection.supportsAutomations, state: connection.state)
            }
    }

    /// Every host's runs as last read, by automation.
    var automationRunsByKey: [AutomationKey: [AutomationRun]] {
        var runs = remoteAutomationRuns
        for (id, list) in localAutomationRuns {
            runs[AutomationKey(host: PageHost.localID, automation: id)] = list
        }
        return runs
    }

    /// The Automations page as it stands. Only a host's changes wait; this Mac's land at once.
    func automationsPageModel(now: Date = Date()) -> AutomationsPageModel {
        AutomationsPageModel.make(hosts: automationHosts, runs: automationRunsByKey, selection: automationsPageSelection,
                                  filter: automationsPageFilter, pending: remoteAutomationsPending, now: now)
    }

    /// The page as its view draws it: derived again only when what it reads changed (a run's
    /// "6h ago" moves on at most once a minute).
    var automationsPage: AutomationsPageModel {
        let now = Date()
        let inputs = AutomationsPageInputs(
            hosts: automationHosts, runs: automationRunsByKey, selection: automationsPageSelection,
            filter: automationsPageFilter, pending: remoteAutomationsPending,
            minute: Int(now.timeIntervalSince1970 / 60))
        if let cached = automationsPageCache, cached.inputs == inputs { return cached.model }
        let model = AutomationsPageModel.make(hosts: inputs.hosts, runs: inputs.runs, selection: inputs.selection,
                                              filter: inputs.filter, pending: inputs.pending, now: now)
        automationsPageCache = (inputs, model)
        return model
    }

    /// Changes whenever a run may have started, settled or ended, or an automation came or went:
    /// the page reads the runs again then.
    var automationRunsSignature: [String] {
        automationHosts.flatMap { host in
            host.state.automations.map { automation in
                let status = automation.agentID.flatMap { id in host.state.agents.first { $0.id == id } }?.status
                return "\(host.id)/\(automation.id.rawValue)/\(host.connected)/\(automation.agentID?.rawValue ?? "")/\(status?.rawValue ?? "")"
            }
        }
    }

    /// Reads every automation's runs: this Mac's from its run log, each connected host's from
    /// the host.
    func loadAutomationPageRuns() async {
        await loadLocalAutomationRuns()
        for connection in remoteHosts.connections where connection.phase == .connected {
            for automation in connection.state.automations {
                await loadRemoteAutomationRuns(AutomationKey(host: connection.id, automation: automation.id))
            }
        }
    }

    func setAutomationEnabled(_ key: AutomationKey, _ enabled: Bool) {
        if key.host == PageHost.localID {
            setAutomationEnabled(key.automation, enabled)
        } else {
            performRemoteAutomation(key, .setEnabled(enabled: enabled))
        }
    }

    /// Run Now: a settled run is replaced, a live one refuses.
    func runAutomation(_ key: AutomationKey) {
        if key.host == PageHost.localID {
            runAutomationNow(key.automation)
        } else {
            performRemoteAutomation(key, .run)
        }
    }

    func stopAutomation(_ key: AutomationKey) {
        if key.host == PageHost.localID {
            stopAutomation(key.automation)
        } else {
            performRemoteAutomation(key, .stop)
        }
    }

    /// Stops its run and removes it.
    func deleteAutomation(_ key: AutomationKey) {
        if automationsPageSelection == key { automationsPageSelection = nil }
        if key.host == PageHost.localID {
            deleteAutomation(key.automation)
        } else {
            performRemoteAutomation(key, .delete)
        }
    }

    /// Opens a run's thread, on this Mac or its host.
    func openThread(_ ref: FleetRef) {
        if ref.host == PageHost.localID {
            guard state.agents.contains(where: { $0.id == ref.agent }) else { return }
            selectAgent(ref.agent)
        } else {
            selectRemoteAgent(hostID: ref.host, agentID: ref.agent)
        }
    }

    /// The automation as saved on its host, for the editor; nil once it is gone.
    func automationDraft(_ key: AutomationKey) -> RemoteAutomationDraft? {
        guard let automation = automationHosts.first(where: { $0.id == key.host })?.state.automations
            .first(where: { $0.id == key.automation }) else { return nil }
        return RemoteAutomationDraft(name: automation.name, prompt: automation.prompt, cwd: automation.cwd,
                                     enabled: automation.enabled)
    }

    /// Hosts a new automation can be saved on: this Mac, and each connected host that serves
    /// automations.
    var automationEditorHosts: [(id: UUID, name: String)] {
        [(PageHost.localID, PageHost.localName)] + remoteHosts.connections
            .filter { $0.phase == .connected && $0.supportsAutomations }
            .map { ($0.id, $0.config.name) }
    }

    /// Saves the editor's draft on its host (`key` nil: a new automation on `host`) and selects
    /// it. Throws what the host said, worded for the sheet.
    func saveAutomation(_ key: AutomationKey?, host: UUID, draft: RemoteAutomationDraft) async throws {
        if host == PageHost.localID {
            let id = try await saveAutomation(key?.automation, draft: draft)
            automationsPageSelection = AutomationKey(host: host, automation: id)
            return
        }
        let target = key ?? AutomationKey(host: host, automation: AutomationID())
        let request: RemoteAutomationRequest = key == nil ? .create(draft: draft) : .update(draft: draft)
        do {
            try await remoteHosts.automation(target, request: request)
        } catch {
            throw AgentStartFailure(message: AutomationsModel.failureText(request, error))
        }
        automationsPageSelection = target
    }

    // MARK: Hosts

    /// This Mac and every configured host, as the Hosts page shows them.
    func hostsPageModel(agentVersion: String?) -> HostsPageModel {
        HostsPageModel.make(local: state, agentVersion: agentVersion, remotes: hostsPageRemotes, columns: AppLayout.hostColumns)
    }

    /// The page as its view draws it, derived again only when what it reads changed.
    func hostsPage(agentVersion: String?) -> HostsPageModel {
        let inputs = HostsPageInputs(local: state, agentVersion: agentVersion, remotes: hostsPageRemotes)
        if let cached = hostsPageCache, cached.inputs == inputs { return cached.model }
        let model = HostsPageModel.make(local: inputs.local, agentVersion: agentVersion, remotes: inputs.remotes,
                                        columns: AppLayout.hostColumns)
        hostsPageCache = (inputs, model)
        return model
    }

    private var hostsPageRemotes: [HostsPageRemote] {
        remoteHosts.connections.map { connection in
            HostsPageRemote(id: connection.id, name: connection.config.name, address: connection.config.host,
                            port: connection.config.port, phase: connection.phase, state: connection.state,
                            lastSeen: connection.lastSeen)
        }
    }

    /// Add host: the host form lives in Settings ▸ Remote.
    func showAddHost() {
        settingsSection = .remote
        showSettings = true
    }
}

/// What the Automations page is derived from.
struct AutomationsPageInputs: Equatable {
    var hosts: [AutomationHost]
    var runs: [AutomationKey: [AutomationRun]]
    var selection: AutomationKey?
    var filter: String
    var pending: Set<AutomationKey>
    /// The minute its relative times were worded in.
    var minute: Int
}

/// What the Hosts page is derived from.
struct HostsPageInputs: Equatable {
    var local: ShepherdState
    var agentVersion: String?
    var remotes: [HostsPageRemote]
}
