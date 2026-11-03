import Foundation
import Observation
import ShepherdCore
import ShepherdRemote

/// Shared across windows. Cold threads keep only navigation choices; no state is persisted.
@MainActor
final class ThreadFilesStores {
    static let shared = ThreadFilesStores()
    static let retainedModels = 8
    static let offscreenBudget = 8 << 20

    private(set) var models: [AgentRef: ThreadFilesModel] = [:]
    private var readers: [AgentRef: Int] = [:]
    private var recent: [AgentRef] = []
    private var forgottenHosts: Set<UUID> = []
    private var liveAgents: [UUID: Set<AgentID>] = [:]

    func model(for ref: AgentRef, hosts: MobileHosts) -> ThreadFilesModel {
        model(for: ref) {
            ThreadFilesModel(list: { [weak hosts] path, hidden in
                try await Self.client(ref, hosts).listFiles(agentID: ref.agent, path: path, showHidden: hidden)
            }, read: { [weak hosts] path in
                try await Self.client(ref, hosts).readFile(agentID: ref.agent, path: path)
            })
        }
    }

    // The factory also lets portable checks exercise this registry without network or SwiftUI.
    func model(for ref: AgentRef, make: () -> ThreadFilesModel) -> ThreadFilesModel {
        if let model = models[ref] { return model }
        let model = make()
        guard !forgottenHosts.contains(ref.host), liveAgents[ref.host]?.contains(ref.agent) != false else {
            model.forget()
            return model
        }
        models[ref] = model
        recent.append(ref)
        model.onRetentionChange = { [weak self, weak model] in
            guard let self, let model, self.models[ref] === model else { return }
            self.trim()
        }
        return model
    }

    func appeared(_ ref: AgentRef, model: ThreadFilesModel) {
        guard models[ref] === model else { return }
        readers[ref, default: 0] += 1
        recent.removeAll { $0 == ref }
        recent.append(ref)
        trim()
    }

    func disappeared(_ ref: AgentRef, model: ThreadFilesModel) {
        guard models[ref] === model, let count = readers[ref] else { return }
        readers[ref] = count > 1 ? count - 1 : nil
        trim()
    }

    private func trim() {
        // ponytail: scan visited refs on Files activity only, not fleet status. Index warm refs
        // separately if a profile shows thousands of visited threads make this significant.
        let warm = recent.filter { (models[$0]?.retainedCost ?? 0) > 0 }
        let shed = ReviewRetention.overflow(recent: warm, keep: Self.retainedModels, budget: Self.offscreenBudget,
                                            cost: { models[$0]?.retainedCost ?? 0 },
                                            shown: { (readers[$0] ?? 0) > 0 || models[$0]?.hasPendingRequests == true })
        for ref in shed { models[ref]?.releasePayload() }
    }

    func forget(host: UUID) {
        forgottenHosts.insert(host)
        liveAgents[host] = nil
        for ref in Array(models.keys) where ref.host == host { remove(ref) }
    }

    /// Only a connected host's membership is authoritative. Status-only updates do not wake us.
    func track(_ hosts: MobileHosts) {
        let live = withObservationTracking {
            hosts.hosts.map { ($0.id, $0.phase.isConnected, $0.agentIDs) }
        } onChange: { [weak self, weak hosts] in
            Task { @MainActor [weak self, weak hosts] in
                guard let self, let hosts else { return }
                self.track(hosts)
            }
        }
        for (host, connected, agents) in live where connected { prune(host: host, live: agents) }
    }

    func prune(host: UUID, live: Set<AgentID>) {
        guard liveAgents[host] != live else { return }
        liveAgents[host] = live
        for ref in Array(models.keys) where ref.host == host && !live.contains(ref.agent) { remove(ref) }
    }

    private func remove(_ ref: AgentRef) {
        models.removeValue(forKey: ref)?.forget()
        readers[ref] = nil
        recent.removeAll { $0 == ref }
    }

    private static func client(_ ref: AgentRef, _ hosts: MobileHosts?) throws -> RemoteHostClient {
        let host = hosts?.host(ref.host)
        guard let client = host?.connectedClient else {
            throw RemoteHostClientError.rejected(code: "offline", message: host.map { "\($0.name) is offline." } ?? "This host was forgotten.")
        }
        return client
    }
}
