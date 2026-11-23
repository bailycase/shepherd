import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Renaming a thread is optimistic: the sidebar row and the header show the submitted name at once
/// (`pendingRenames`, a presentation overlay), and the host stays the only writer of the name.
/// Snapshots are never edited, so a stale one cannot undo the rename and a failed one needs no restore.
extension ShepherdViewModel {
    /// The name the host's last snapshot gives a thread row; nil when it is not a thread.
    func hostThreadName(_ row: SidebarRowID) -> String? {
        switch row {
        case .local(let id): state.agents.first { $0.id == id }?.name
        case .remote(let ref): remoteAgent(ref)?.name
        default: nil
        }
    }

    /// What the thread's row and header show: the submitted name while its rename is pending.
    func presentedThreadName(_ row: SidebarRowID, hostName: String) -> String {
        pendingRenames.presented(row, hostName: hostName)
    }

    /// A hand-typed name is final: pi's namer must never overwrite it. Shows at once; the latest
    /// submit wins; a refusal restores the host's name and says why.
    func renameThread(_ row: SidebarRowID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let host = hostThreadName(row),
              pendingRenames.presented(row, hostName: host) != trimmed else { return }
        if pendingRenames.submit(row, name: trimmed, hostName: host) { sendPendingRename(row) }
    }

    private func sendPendingRename(_ row: SidebarRowID) {
        guard let name = pendingRenames.beginSend(row) else { return }
        send(rename: name, of: row)
    }

    private func send(rename name: String, of row: SidebarRowID) {
        let hosts = remoteHosts
        let ref: RemoteAgentRef? = switch row {
        case .local(let id): localRef(id)
        case .remote(let target): target
        default: nil
        }
        let operation: @MainActor () async -> Void = { [weak self] in
            var failure: Error?
            do {
                guard let ref else { throw BackgroundHostClient.HostStarting() }
                try await hosts.agentAction(ref, action: .rename(name: name))
            } catch { failure = error }
            self?.renameEnded(row, sent: name, failure: failure)
        }
        // This Mac's writes stay in order with the others; a paired host has its own connection.
        if case .local = row { enqueuePersistence("agent rename") { await operation() } }
        else { Task { await operation() } }
    }

    private func renameEnded(_ row: SidebarRowID, sent name: String, failure: Error?) {
        switch pendingRenames.completed(row, sent: name, failed: failure != nil) {
        case .resend(let next): send(rename: next, of: row)
        case .settled: reconcilePendingRenames()
        case .reverted:
            NSLog("Shepherd: agent rename failed: \(failure.map(String.init(describing:)) ?? "")")
            if let failure { fail("Couldn’t rename the agent", failure) }
        case .ignored: break
        }
    }

    /// Lets each pending rename see the newest host snapshot: it leaves once the host shows it.
    func reconcilePendingRenames() {
        guard !pendingRenames.isEmpty else { return }
        var next = pendingRenames
        for row in next.keys { next.observe(row, hostName: hostThreadName(row)) }
        if next != pendingRenames { pendingRenames = next }
    }

    /// `source` with each pending rename shown: names only, nothing else of a snapshot changes.
    func applyingPendingRenames(to source: SidebarSource) -> SidebarSource {
        guard !pendingRenames.isEmpty else { return source }
        var source = source
        for i in source.local.agents.indices {
            let agent = source.local.agents[i]
            let name = pendingRenames.presented(.local(agent.id), hostName: agent.name)
            if name != agent.name { source.local.agents[i].name = name }
        }
        for h in source.hosts.indices {
            let host = source.hosts[h].id
            for i in source.hosts[h].state.agents.indices {
                let agent = source.hosts[h].state.agents[i]
                let name = pendingRenames.presented(.remote(.init(hostID: host, agentID: agent.id)), hostName: agent.name)
                if name != agent.name { source.hosts[h].state.agents[i].name = name }
            }
        }
        return source
    }
}
