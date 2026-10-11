import Foundation
import ShepherdCore

/// A status edge identifies a completion. Activity alone does not: even a refused send stamps
/// lastActiveAt. Keep our own generation so two turns in the same millisecond remain distinct.
struct SidebarCompletions: Equatable {
    struct Record: Equatable {
        var finished: Bool
        var activity: Double?
        var generation: Int
        var completedAt: Double?
    }

    private(set) var records: [SidebarRowID: Record] = [:]
    private var generation = 0
    private var endpoints: [UUID: UUID] = [:]
    private var connected: Set<UUID> = []

    mutating func reconcile(_ source: SidebarSource, endpoints nextEndpoints: [UUID: UUID]) {
        let local = Set(source.local.agents.map(\.id))
        let hosts = Set(source.hosts.map(\.id))
        records = records.filter { id, _ in
            switch id {
            case .local(let agent): local.contains(agent)
            case .remote(let ref): hosts.contains(ref.hostID) && endpoints[ref.hostID] == nextEndpoints[ref.hostID]
            case .design: false
            }
        }
        let runs = Dictionary(source.openRuns.values.compactMap { run in run.agentID.map { ($0, run) } },
                              uniquingKeysWith: { first, _ in first })
        for agent in source.local.agents where source.local.isOrdinaryThread(agent) {
            let settled = runs[agent.id]?.settledAt
            observe(.local(agent.id), finished: agent.status == .done || (agent.status == .idle && settled != nil),
                    activity: agent.lastActiveAt, completedAt: agent.lastActiveAt ?? settled.map { $0 * 1000 }
                        ?? source.statusSince[agent.id].map { $0.timeIntervalSince1970 * 1000 }, catchUp: false)
        }
        for host in source.hosts where !host.offline {
            let live = Set(host.state.agents.map(\.id))
            records = records.filter { id, _ in
                if case .remote(let ref) = id, ref.hostID == host.id { return live.contains(ref.agentID) }
                return true
            }
            let catchUp = !connected.contains(host.id) || endpoints[host.id] != nextEndpoints[host.id]
            for agent in host.state.agents where host.state.isOrdinaryThread(agent) {
                observe(.remote(.init(hostID: host.id, agentID: agent.id)), finished: agent.status == .done,
                        activity: agent.lastActiveAt, completedAt: agent.lastActiveAt, catchUp: catchUp)
            }
        }
        connected = Set(source.hosts.filter { !$0.offline }.map(\.id))
        endpoints = nextEndpoints
    }

    private mutating func observe(_ id: SidebarRowID, finished: Bool, activity: Double?, completedAt: Double?, catchUp: Bool) {
        let previous = records[id]
        // ponytail: a changed stamp after a disconnect is a completion hint. A refused send
        // while disconnected is indistinguishable; add a host completion token if exactness is required.
        let newCompletion = finished && (previous?.finished != true || (catchUp && previous?.activity != activity))
        if newCompletion { generation += 1 }
        records[id] = Record(finished: finished, activity: activity,
                             generation: newCompletion ? generation : previous?.generation ?? 0,
                             completedAt: newCompletion ? completedAt : previous?.completedAt)
    }
}

@MainActor
extension ShepherdViewModel {
    func reconcileSidebarCompletions() {
        var completions = sidebarCompletions
        completions.reconcile(sidebarSource, endpoints: Dictionary(uniqueKeysWithValues:
            remoteHosts.connections.map { ($0.id, $0.endpointID) }))
        if completions != sidebarCompletions { sidebarCompletions = completions }
        if let reading = sidebarReadingThread, reading == selectedSidebarRow,
           let record = completions.records[reading], record.finished {
            sidebarReadingCompletion = record.generation
        }
        let kept = sidebarSeenCompletions.filter { completions.records[$0.key] != nil }
        if kept != sidebarSeenCompletions { sidebarSeenCompletions = kept }
        let live = Set(state.agents.map(\.id))
        let samples = sidebarActivitySamples.filter { live.contains($0.key) }
        if samples != sidebarActivitySamples { sidebarActivitySamples = samples }
        sidebarActivityLast = sidebarActivityLast.filter { live.contains($0.key) }
    }
}
