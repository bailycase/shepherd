import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Revision hints (`native.revisions.v1`) for the whole app: each host watches the ordinary threads
/// some view shows now, in any window (`ThreadStores.shownRefs`), at most `limit`, and its
/// `nativeThreadChanged` marks the thread to be read again. One owner per `MobileHosts`: views
/// never subscribe or set the client's callback themselves.
///
/// A host's watch set is replaced as threads come and go on screen, emptied when none shows, and
/// sent again on every new connection (a reconnect starts unwatched). One subscription request is
/// in flight per host; the newest set follows when it returns. A refusal is not retried until the
/// set or the connection changes: polling remains the fallback. Hints start no pi and send no
/// read themselves.
@MainActor
final class ThreadRevisionHints {
    /// The host's cap on a connection's watch set.
    static let limit = 64

    private struct Watch: Equatable {
        let session: UUID
        let agents: [AgentID]
    }

    private let hosts: MobileHosts
    private let threads: ThreadStores
    private let onHint: (AgentRef) -> Void
    /// What each host was last asked to watch, on which connection.
    private var sent: [UUID: Watch] = [:]
    private var wanted: [UUID: Watch] = [:]
    private var sending: Set<UUID> = []

    /// `onHint` hears each hint for a thread the host watched: Home's digest and the thread's
    /// live store read again.
    init(hosts: MobileHosts, threads: ThreadStores, onHint: @escaping (AgentRef) -> Void) {
        self.hosts = hosts
        self.threads = threads
        self.onHint = onHint
        hosts.onNativeThreadChanged = { [weak self] host, agentID in
            guard let self, self.sent[host.id]?.session == host.session, self.sent[host.id]?.agents.contains(agentID) == true else { return }
            self.onHint(AgentRef(host: host.id, agent: agentID))
        }
        track()
    }

    /// The ordinary threads shown on `host`, in a stable order, at most `limit`.
    /// ponytail: past 64 shown threads the first 64 by id are watched; the rest keep polling.
    static func watchable(_ shown: [AgentRef], on host: MobileHost) -> [AgentID] {
        let state = host.threadState
        let ids = shown.compactMap { ref -> AgentID? in
            guard ref.host == host.id, let agent = state.agents.first(where: { $0.id == ref.agent }),
                  !state.isDesignAgent(agent), agent.coordinatorFor == nil, agent.projectWorkerFor == nil else { return nil }
            return agent.id
        }
        return Array(Set(ids).sorted { $0.rawValue < $1.rawValue }.prefix(limit))
    }

    private func track() {
        let next = withObservationTracking { () -> [UUID: Watch] in
            let shown = threads.shownRefs
            var next: [UUID: Watch] = [:]
            for host in hosts.hosts {
                guard let session = host.session, host.supports(RemoteProtocol.nativeThreadRevisionsCapability) else { continue }
                next[host.id] = Watch(session: session, agents: Self.watchable(shown, on: host))
            }
            return next
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        wanted = next
        // A host gone, offline or without hints watches nothing on this device.
        for id in sent.keys where next[id] == nil { sent[id] = nil }
        for id in next.keys { sync(id) }
    }

    private func sync(_ id: UUID) {
        guard let want = wanted[id], sent[id] != want, !sending.contains(id),
              let host = hosts.host(id), host.session == want.session, let client = host.connectedClient else { return }
        // A new connection starts unwatched: nothing to clear.
        if want.agents.isEmpty, sent[id]?.session != want.session {
            sent[id] = want
            return
        }
        sending.insert(id)
        Task { @MainActor [weak self] in
            // A refusal (a thread gone between sets) is not retried for this set: polling covers it.
            try? await client.subscribeNativeThreads(want.agents)
            guard let self else { return }
            sending.remove(id)
            if hosts.host(id)?.session == want.session { sent[id] = want }
            sync(id)
        }
    }
}
