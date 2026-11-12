import Foundation
import ShepherdCore
import ShepherdProtocol

/// What a thread's `fleet_*` tools are told (server queue).
extension FleetDispatch {
    /// The Macs of the fleet as `fleet_hosts` lists them for `agentID`: how much room each has, what it
    /// lacks, and whether it has the thread's repository.
    func hosts(for agentID: AgentID) -> [FleetHostInfo] {
        let state = host.state()
        let repoKey = state.agents.first { $0.id == agentID }.flatMap { agent in state.spaces.first { $0.id == agent.spaceID }?.repoKey } ?? ""
        let probe = FleetDispatchRecord(parentHostID: hostID, parentHostName: hostName(), title: "", task: "", repoKey: repoKey, createdAt: now)
        let macs = placementMacs(for: probe)
        let scores: [UUID: Double] = Dictionary(uniqueKeysWithValues: macs.map { mac in
            guard let sample = mac.sample, let age = mac.sampleAge, FleetRoom.skip(sample, age: age, weight: mac.weight) == nil else { return (mac.hostID, 0) }
            return (mac.hostID, FleetRoom.score(sample, weight: mac.weight))
        })
        let best = scores.values.max() ?? 0
        return macs.map { mac in
            let room: String
            if let sample = mac.sample, let age = mac.sampleAge {
                switch FleetRoom.skip(sample, age: age, weight: mac.weight) {
                case .manualOnly?: room = "not counted"
                case nil: room = best > 0 && (scores[mac.hostID] ?? 0) >= best ? "most room" : (scores[mac.hostID] ?? 0) >= best * 0.5 ? "some room" : "little room"
                default: room = "no room"
                }
            } else {
                room = mac.connected ? "not counted" : "offline"
            }
            return FleetHostInfo(name: mac.name, isThisMac: mac.isLocal, room: room, connected: mac.connected, problems: mac.problems,
                                 hasRepo: mac.hasRepo, weight: mac.weight.title)
        }
    }

    /// Why a thread may not use the fleet tools, or nil: a dispatched thread, a project worker, a
    /// coordinator, a design's agent and an automation run never send work on (`fleet_scope`).
    static func scopeProblem(for agentID: AgentID, in state: ShepherdState, unattended: Set<AgentID>) -> FleetDispatchRefusal? {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else {
            return FleetDispatchRefusal(code: "no_such_agent", message: "unknown agent \(agentID)")
        }
        let reason: String? = if agent.dispatchedFrom != nil { "a dispatched thread" }
            else if state.isProjectWorker(agentID) { "a project worker" }
            else if state.isProjectCoordinator(agent) { "a project coordinator" }
            else if state.isDesignAgent(agent) { "a design's agent" }
            else if unattended.contains(agentID) { "an automation run" }
            else { nil }
        guard let reason else { return nil }
        return FleetDispatchRefusal(code: FleetDispatchCode.fleetScope,
                                    message: "\(reason.prefix(1).uppercased() + reason.dropFirst()) can't send work to other Macs. Ask the thread that started it.")
    }
}
