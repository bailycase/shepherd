import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A remote host's automations in the sidebar (NavAutomations, NavHosts): a disclosure under the
// host's spaces, one row per automation, and a sheet with its details and runs. Changes go to
// the host (`RemoteAutomationRequest`), which applies the same rules as its own sidebar.

/// One remote automation's sidebar row, as plain values.
struct SidebarRemoteAutomation: Equatable {
    var key: AutomationKey
    var name: String
    var state: AgentState
    var accessory: NWSidebarRow.Accessory
    /// "running", "needs you", "done", "stopped", "off".
    var word: String
    var enabled: Bool
    /// Its run's agent: clicking the row opens it.
    var run: AgentID?
    var selected: Bool
    var abilities: AutomationAbilities
    var pending: Bool
}

/// A host's Automations disclosure row.
struct SidebarRemoteAutomations: Equatable {
    var hostID: UUID
    var count: Int
    /// Runs waiting on you.
    var blocked: Int
    var collapsed: Bool
}

extension ShepherdViewModel {
    /// A connected host's automations as the shared presentation reads them.
    func remoteAutomationsModel(_ connection: RemoteHostStore.Connection) -> AutomationsModel {
        let host = AutomationHost(id: connection.id, name: connection.config.name, connected: connection.phase == .connected,
                                  manageable: connection.supportsAutomations, state: connection.state)
        let runs = remoteAutomationRuns.filter { $0.key.host == connection.id }
        return AutomationsModel(hosts: [host], runs: runs)
    }

    /// Appends a connected host's Automations disclosure and, while it is open, its rows.
    func appendRemoteAutomations(_ connection: RemoteHostStore.Connection, to tree: inout SidebarTree) {
        guard !connection.state.automations.isEmpty else { return }
        let model = remoteAutomationsModel(connection)
        let collapsed = !expandedRemoteAutomations.contains(connection.id)
        tree.append(.remoteAutomations(SidebarRemoteAutomations(
            hostID: connection.id, count: model.rows.count, blocked: model.rows.count { $0.tone == .attention },
            collapsed: collapsed)))
        guard !collapsed else { return }
        for row in model.rows {
            tree.append(.remoteAutomation(Self.sidebarRow(row, selected: row.run.map {
                selectedRemoteAgent == RemoteAgentRef(hostID: $0.host, agentID: $0.agent)
            } ?? false, pending: remoteAutomationsPending.contains(row.key))))
        }
    }

    /// The row's dot and word follow the local Automations rows: its run's state, else stopped
    /// (or off, when it does not start with Shepherd).
    static func sidebarRow(_ row: AutomationListRow, selected: Bool, pending: Bool) -> SidebarRemoteAutomation {
        let state: AgentState, word: String, accessory: NWSidebarRow.Accessory
        if row.run == nil {
            (state, word) = (.idle, row.enabled ? "stopped" : "off")
            accessory = .text(word)
        } else {
            switch row.tone {
            case .attention: (state, word, accessory) = (.attention, "needs you", .ask)
            case .running: (state, word, accessory) = (.running, "running", .text("running"))
            default: (state, word, accessory) = (.done, "done", .text("done"))
            }
        }
        return SidebarRemoteAutomation(key: row.key, name: row.name, state: state, accessory: accessory, word: word,
                                       enabled: row.enabled, run: row.run?.agent, selected: selected,
                                       abilities: row.abilities, pending: pending)
    }

    func toggleRemoteAutomations(_ hostID: UUID) {
        if expandedRemoteAutomations.contains(hostID) {
            expandedRemoteAutomations.remove(hostID)
        } else {
            expandedRemoteAutomations.insert(hostID)
        }
    }

    /// Opens the automation's run, or its details while it has none.
    func openRemoteAutomation(_ row: SidebarRemoteAutomation) {
        if let run = row.run {
            selectRemoteAgent(hostID: row.key.host, agentID: run)
        } else {
            showRemoteAutomation(row.key)
        }
    }

    func showRemoteAutomation(_ key: AutomationKey) {
        remoteAutomationSheet = key
        Task { await loadRemoteAutomationRuns(key) }
    }

    /// Reads the runs the host kept. A host that cannot say keeps what was read before.
    func loadRemoteAutomationRuns(_ key: AutomationKey) async {
        guard remoteHosts.connections.first(where: { $0.id == key.host })?.supportsAutomations == true else { return }
        guard case .runs(let runs)? = try? await remoteHosts.automation(key, request: .runs) else { return }
        if remoteAutomationRuns[key] != runs { remoteAutomationRuns[key] = runs }
    }

    /// Sends one change to the host; a refusal shows the failed-action dialog.
    func performRemoteAutomation(_ key: AutomationKey, _ request: RemoteAutomationRequest) {
        guard !remoteAutomationsPending.contains(key) else { return }
        remoteAutomationsPending.insert(key)
        Task {
            defer { remoteAutomationsPending.remove(key) }
            do {
                try await remoteHosts.automation(key, request: request)
                if request == .delete {
                    if remoteAutomationSheet == key { remoteAutomationSheet = nil }
                    remoteAutomationRuns[key] = nil
                } else if remoteAutomationSheet == key {
                    await loadRemoteAutomationRuns(key)
                }
            } catch {
                remoteActionError = Self.remoteAutomationFailure(request, error)
            }
        }
    }

    static func remoteAutomationFailure(_ request: RemoteAutomationRequest, _ error: Error) -> String {
        let reason: String
        if case RemoteHostClientError.rejected(_, let message) = error { reason = message } else { reason = String(describing: error) }
        let what: String = switch request {
        case .run: "start the run"
        case .stop: "stop the run"
        case .setEnabled(let on): on ? "turn the automation on" : "turn the automation off"
        case .delete: "delete the automation"
        case .create: "save the automation"
        case .update: "save the changes"
        case .runs: "read the runs"
        }
        return "Couldn't \(what): \(reason)"
    }
}
