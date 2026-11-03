import Foundation
import ShepherdCore
import ShepherdRemote

/// Which remote threads each host is asked to hint about (`native.revisions.v1`): the ordinary
/// threads whose stores are polling on screen in any window, at most `limit` per host, sent only
/// when that set changes. A reconnect starts the host with none, so it is sent again. Hidden
/// threads, project coordinators and threads never shown are never subscribed, and a hint only
/// wakes a store that is already polling; the poll stays as the fallback.
struct RemoteThreadHints {
    static let limit = 64

    /// What each host was last told, by connection; nil until told (or after a reconnect or failure).
    private(set) var sent: [UUID: [AgentID]] = [:]

    /// The IDs to send each host now: hosts whose wanted set changed since it was last told.
    /// `ordinary` says whether a host's agent is an ordinary thread (not a project coordinator).
    mutating func plan(live: Set<RemoteAgentRef>, hosts: Set<UUID>,
                       ordinary: (RemoteAgentRef) -> Bool) -> [UUID: [AgentID]] {
        var wanted: [UUID: [AgentID]] = Dictionary(uniqueKeysWithValues: hosts.map { ($0, []) })
        for ref in live where hosts.contains(ref.hostID) && ordinary(ref) { wanted[ref.hostID]?.append(ref.agentID) }
        var changes: [UUID: [AgentID]] = [:]
        for (host, ids) in wanted {
            let capped = Array(ids.sorted { $0.rawValue < $1.rawValue }.prefix(Self.limit))
            guard sent[host] != capped else { continue }
            // A host never told anything needs no empty subscription.
            if sent[host] == nil, capped.isEmpty { continue }
            sent[host] = capped
            changes[host] = capped
        }
        for host in sent.keys where !hosts.contains(host) { sent[host] = nil }
        return changes
    }

    /// The host reconnected (its subscriptions were cleared) or refused: tell it again next plan.
    mutating func forget(_ host: UUID) { sent[host] = nil }
}
