import ShepherdCore

/// Which snapshots of the host's workspace the view model adopts: each one, unless a newer one is already queued
/// behind it (`RemoteHostClient.newerStateQueued`). That one waits as `unadopted` for the callbacks that read the
/// newest workspace (`latest`). The last of a burst is always adopted, and so is every `maxSkips`-th, so a steady
/// stream cannot starve the screen.
struct StateAdoption {
    static let maxSkips = 32

    private(set) var unadopted: ShepherdState?
    private(set) var skipped = 0

    /// What to adopt for `state`, a snapshot received now: nil when a newer one is queued behind it.
    mutating func received(_ state: ShepherdState, newerQueued: Bool) -> ShepherdState? {
        guard newerQueued, skipped < Self.maxSkips else {
            unadopted = nil
            skipped = 0
            return state
        }
        unadopted = state
        skipped += 1
        return nil
    }

    /// A snapshot adopted outside the stream (`adopt`): never older than a push that arrived before it,
    /// as the host's pushes and the caller's reads are one ordered stream.
    mutating func adoptedDirectly() {
        unadopted = nil
        skipped = 0
    }

    /// The newest snapshot received: the waiting one, else the adopted one.
    func latest(_ adopted: ShepherdState) -> ShepherdState { unadopted ?? adopted }
}

/// An agent's status change between two snapshots of the workspace: the agent as the newer one has it (so it
/// carries the new status, which the banners read) and the status it had before.
struct StatusEdge: Equatable {
    let agent: Agent
    let old: AgentStatus

    /// Each agent of `newer` whose status differs from its status in `older`, in `newer`'s order. An agent
    /// `older` lacks has no old status, so no edge.
    static func between(_ older: ShepherdState, and newer: ShepherdState) -> [StatusEdge] {
        var edges: [StatusEdge] = []
        var byID: [AgentID: AgentStatus]?
        for (index, agent) in newer.agents.enumerated() {
            let old: AgentStatus?
            // The same agents in the same order, as a burst of status reports leaves them, need no lookup.
            if index < older.agents.count, older.agents[index].id == agent.id {
                old = older.agents[index].status
            } else {
                if byID == nil { byID = Dictionary(older.agents.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first }) }
                old = byID?[agent.id]
            }
            if let old, old != agent.status { edges.append(StatusEdge(agent: agent, old: old)) }
        }
        return edges
    }
}
