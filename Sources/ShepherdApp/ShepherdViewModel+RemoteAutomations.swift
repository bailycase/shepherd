import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A remote host's automations: the shared presentation of them, their runs, and the changes
// that go to the host (`RemoteAutomationRequest`), which applies the same rules as its own. A
// host with `automationTriggersCapability` gets This Mac's inbox: its triggers' status, pending
// events, Pause and Resume, Pause all, unread runs and the editor's settings.

extension ShepherdViewModel {
    /// How often the Automations page reads a host's trigger status while it is on screen.
    static let remoteTriggerRefresh: Duration = .seconds(30)

    /// A connected host's automations as the shared presentation reads them.
    func remoteAutomationsModel(_ connection: RemoteHostStore.Connection) -> AutomationsModel {
        let host = AutomationHost(id: connection.id, name: connection.config.name, connected: connection.phase == .connected,
                                  manageable: connection.supportsAutomations, state: connection.state,
                                  triggers: connection.supportsAutomationTriggers)
        let runs = remoteAutomationRuns.filter { $0.key.host == connection.id }
        return AutomationsModel(hosts: [host], runs: runs)
    }

    /// Reads the runs the host kept. A host that cannot say keeps what was read before.
    func loadRemoteAutomationRuns(_ key: AutomationKey) async {
        guard remoteHosts.connections.first(where: { $0.id == key.host })?.supportsAutomations == true else { return }
        guard case .runs(let runs)? = try? await remoteHosts.automation(key, request: .runs) else { return }
        if remoteAutomationRuns[key] != runs { remoteAutomationRuns[key] = runs }
    }

    /// Sends one change to the host; a refusal shows the failed-action dialog. A trigger change
    /// reads the host's status and runs again.
    func performRemoteAutomation(_ key: AutomationKey, _ request: RemoteAutomationRequest) {
        guard !remoteAutomationsPending.contains(key) else { return }
        remoteAutomationsPending.insert(key)
        Task {
            defer { remoteAutomationsPending.remove(key) }
            do {
                try await remoteHosts.automation(key, request: request)
                if request == .delete { remoteAutomationRuns[key] = nil }
            } catch {
                remoteActionError = AutomationsModel.failureText(request, error)
            }
            guard request.needsTriggers || request == .run else { return }
            if case .setAllPaused = request {
                await refreshRemoteAutomationTriggers(host: key.host)
            } else {
                await refreshRemoteAutomationTrigger(key)
            }
            await loadRemoteAutomationRuns(key)
        }
    }

    // MARK: Triggers

    /// Connected hosts that serve triggers.
    private var triggerConnections: [RemoteHostStore.Connection] {
        remoteHosts.connections.filter { $0.phase == .connected && $0.supportsAutomationTriggers }
    }

    /// This Mac, or a connected host that serves triggers: the editor sends its settings there.
    func automationTriggersServed(_ host: UUID) -> Bool {
        host == PageHost.localID || triggerConnections.contains { $0.id == host }
    }

    /// Reads every triggered automation's status on each host that serves triggers (or only
    /// `host`). A host that doesn't answer keeps what was read before; a gone automation drops.
    func refreshRemoteAutomationTriggers(host: UUID? = nil) async {
        for connection in triggerConnections where host == nil || connection.id == host {
            let keys = connection.state.automations.filter(\.isTriggered).map { AutomationKey(host: connection.id, automation: $0.id) }
            for key in keys { await refreshRemoteAutomationTrigger(key) }
            let stale = remoteAutomationTriggerStatuses.keys.filter { $0.host == connection.id && !keys.contains($0) }
            for key in stale { remoteAutomationTriggerStatuses[key] = nil }
        }
    }

    func refreshRemoteAutomationTrigger(_ key: AutomationKey) async {
        guard triggerConnections.contains(where: { $0.id == key.host }),
              case .status(let status)? = try? await remoteHosts.automation(key, request: .status) else { return }
        if remoteAutomationTriggerStatuses[key] != status { remoteAutomationTriggerStatuses[key] = status }
    }

    /// While the Automations page is on screen: each host's trigger status now, then every
    /// `remoteTriggerRefresh`. Ends when the page goes (its task is cancelled).
    func watchRemoteAutomationTriggers() async {
        while !Task.isCancelled {
            await refreshRemoteAutomationTriggers()
            try? await Task.sleep(for: Self.remoteTriggerRefresh)
        }
    }

    /// Pause all triggers on a host (the automation named is incidental: the first triggered one).
    func setRemoteAutomationTriggersPaused(_ host: UUID, _ paused: Bool) {
        guard let connection = triggerConnections.first(where: { $0.id == host }),
              let automation = connection.state.automations.first(where: \.isTriggered) else { return }
        performRemoteAutomation(AutomationKey(host: host, automation: automation.id), .setAllPaused(paused: paused))
    }

    /// The user opened a host's run thread: its unread dot goes, here at once and on the host.
    func markRemoteAutomationRunsRead(hostID: UUID, agentID: AgentID) {
        guard triggerConnections.contains(where: { $0.id == hostID }) else { return }
        for (key, runs) in remoteAutomationRuns where key.host == hostID {
            let unread = runs.filter { $0.agentID == agentID && $0.unread }
            guard !unread.isEmpty else { continue }
            remoteAutomationRuns[key] = runs.map { run in
                var run = run
                if run.agentID == agentID { run.unread = false }
                return run
            }
            Task {
                for run in unread { _ = try? await remoteHosts.automation(key, request: .markRead(runID: run.id)) }
                await loadRemoteAutomationRuns(key)
            }
        }
    }

    // MARK: Editor

    /// Threads a run can message: the host's own threads, not runs, designs or hidden spaces'.
    func automationDestinationThreads(_ host: UUID) -> [(id: AgentID, name: String)] {
        let state = host == PageHost.localID ? state : remoteHosts.connections.first { $0.id == host }?.state
        guard let state else { return [] }
        let hidden = Set(state.spaces.filter(\.hidden).map(\.id))
        return state.agents.filter { $0.automationOrigin == nil && $0.designID == nil && !hidden.contains($0.spaceID) }
            .map { ($0.id, $0.name) }
    }

    /// The models a run on `host` can pin.
    func automationEditorModels(_ host: UUID) async -> [String] {
        if host == PageHost.localID {
            let server = server
            return await Task.detached { server.modelListing().models }.value
        }
        return (try? await remoteHosts.listModels(hostID: host))?.models ?? []
    }

    /// The zone a host's schedules run in: This Mac's, or what the host's trigger status said
    /// (nil until one is read).
    func automationHostTimeZone(_ host: UUID) -> TimeZone? {
        if host == PageHost.localID { return .current }
        return remoteAutomationTriggerStatuses.first { $0.key.host == host && $0.value.timeZone != nil }
            .flatMap { TimeZone(identifier: $0.value.timeZone!) }
    }
}
