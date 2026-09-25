import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A remote host's automations: the shared presentation of them, the sheet with one's details
// and runs, and the changes that go to the host (`RemoteAutomationRequest`), which applies the
// same rules as its own.

extension ShepherdViewModel {
    /// A connected host's automations as the shared presentation reads them.
    func remoteAutomationsModel(_ connection: RemoteHostStore.Connection) -> AutomationsModel {
        let host = AutomationHost(id: connection.id, name: connection.config.name, connected: connection.phase == .connected,
                                  manageable: connection.supportsAutomations, state: connection.state)
        let runs = remoteAutomationRuns.filter { $0.key.host == connection.id }
        return AutomationsModel(hosts: [host], runs: runs)
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
                remoteActionError = AutomationsModel.failureText(request, error)
            }
        }
    }
}
