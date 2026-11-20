import AppKit
import ShepherdRemote

/// Stop all working threads: the Agent menu's item and the palette's command. Every thread whose
/// turn is working, on this Mac and on each connected host, stops through its own Stop
/// (`StopAllWorking`).
@MainActor
extension ShepherdViewModel {
    /// The threads working now: this Mac's, then each connected host's.
    var workingThreads: [StopAllWorking.Target] {
        var targets = remoteHosts.localHost.map { StopAllWorking.targets(host: $0.id, in: state) } ?? []
        for connection in remoteHosts.connections where connection.phase == .connected {
            targets += StopAllWorking.targets(host: connection.id, in: connection.state)
        }
        return targets
    }

    /// Asks first, naming the count; nothing working beeps like the other menu commands.
    func requestStopAll() {
        let targets = workingThreads
        guard !targets.isEmpty else { NSSound.beep(); return }
        stopAllConfirm = targets
    }

    func confirmStopAll(_ targets: [StopAllWorking.Target]) {
        stopAllConfirm = nil
        Task {
            let outcome = await StopAllWorking.run(targets) { [remoteHosts] target, request in
                try await remoteHosts.nativeThread(RemoteAgentRef(hostID: target.host, agentID: target.agent), request: request)
            }
            actionError = ActionError(title: outcome.title, message: outcome.message)
        }
    }
}
