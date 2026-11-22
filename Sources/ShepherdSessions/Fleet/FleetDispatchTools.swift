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
        let probe = FleetDispatchRecord(parentHostID: hostID, parentHostName: hostName(), title: "", task: "", repoKey: repoKey,
                                        spaceID: state.agents.first { $0.id == agentID }?.spaceID, createdAt: now)
        let xcode = needsXcode(probe)
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
            return FleetHostInfo(name: mac.name, isThisMac: mac.isLocal, room: room, connected: mac.connected, problems: mac.problems(needsXcode: xcode),
                                 without: mac.withoutCommands.isEmpty ? nil : mac.withoutCommands, hasRepo: mac.hasRepo, weight: mac.weight.title)
        }
    }

    /// The most dispatches `fleet_read` lists; the rest are counted, not sent.
    static let listRowsMax = 20

    /// The dispatches this Mac sent, newest first, as `fleet_read` lists them to `agentID`, at most `listRowsMax`, and how many older ones it left out.
    /// `mine` marks the ones that thread sent, the only ones its other `fleet_*` tools reach. For another thread's dispatch the title and branch are
    /// shown only when the sender gave the title (else the title is the task's first line and the branch is made from it: a prompt): older records
    /// never recorded that, so they are hidden too. Every text is one short line. A moved thread is no dispatch. Reads what the engine holds;
    /// touches no Mac.
    func listRows(for agentID: AgentID) -> (rows: [FleetDispatchListRow], omitted: Int) {
        let all = outbound.values.filter { $0.kind != .move }.sorted { $0.createdAt > $1.createdAt }
        let rows = all.prefix(Self.listRowsMax).map { record -> FleetDispatchListRow in
            let mine = record.parentAgentID == agentID
            let shown = mine || record.titleGiven
            return FleetDispatchListRow(dispatchID: record.id.uuidString.lowercased(), state: record.state.rawValue, host: record.targetHostName?.listLabel(),
                                        title: shown ? record.title.listLabel() : "(untitled)", branch: shown ? record.branch?.listLabel() : nil,
                                        mine: mine, closed: record.closeReport != nil)
        }
        return (Array(rows), all.count - rows.count)
    }

    /// Why a thread may not use the fleet tools, or nil: a project worker, a coordinator, a design's agent and an automation
    /// run never send work on (`fleet_scope`). How deep a thread is limits only what it starts (`depthProblem`).
    static func scopeProblem(for agentID: AgentID, in state: ShepherdState, unattended: Set<AgentID>) -> FleetDispatchRefusal? {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else {
            return FleetDispatchRefusal(code: "no_such_agent", message: "unknown agent \(agentID)")
        }
        let reason: String? = if state.isProjectWorker(agentID) { "a project worker" }
            else if state.isProjectCoordinator(agent) { "a project coordinator" }
            else if state.isDesignAgent(agent) { "a design's agent" }
            else if unattended.contains(agentID) { "an automation run" }
            else { nil }
        guard let reason else { return nil }
        return FleetDispatchRefusal(code: FleetDispatchCode.fleetScope,
                                    message: "\(reason.prefix(1).uppercased() + reason.dropFirst()) can't send work to other Macs. Ask the thread that started it.")
    }

    /// Why a thread may not start another, here or on another Mac, or nil: it is `StartedBy.maxDepth` threads below one the person started.
    static func depthProblem(for agentID: AgentID, in state: ShepherdState) -> FleetDispatchRefusal? {
        guard let agent = state.agents.first(where: { $0.id == agentID }), agent.threadDepth >= StartedBy.maxDepth else { return nil }
        return FleetDispatchRefusal(code: FleetDispatchCode.tooDeep, message: tooDeep)
    }

    static let tooDeep = "This thread is \(StartedBy.maxDepth) threads below one the person started, so it can't start more. Do the work here, or ask the thread that started it."
}
