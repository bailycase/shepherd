import Foundation

public enum MissionMarker: Sendable {}
public typealias MissionID = Identifier<MissionMarker>
public enum MissionStationMarker: Sendable {}
public typealias MissionStationID = Identifier<MissionStationMarker>

public struct MissionError: Error, CustomStringConvertible, Equatable, Sendable {
    public var code: String
    public var description: String
    public init(_ code: String, _ description: String) {
        self.code = code
        self.description = description
    }
}

/// A saved brief, approved map and host-owned execution receipts. Map approval never authorizes a push.
public struct Mission: Codable, Hashable, Sendable, Identifiable {
    public var id: MissionID
    public var revision: UInt64
    public var draft: MissionDraft
    /// Approval belongs to this exact draft revision, not to later edits or PR contents.
    public var approvedPlanRevision: UInt64?
    public var run: MissionRun?

    public init(id: MissionID = MissionID(), revision: UInt64 = 1, draft: MissionDraft,
                approvedPlanRevision: UInt64? = nil, run: MissionRun? = nil) {
        self.id = id
        self.revision = revision
        self.draft = draft
        self.approvedPlanRevision = approvedPlanRevision
        self.run = run
    }

    public static let maximumCount = 32
    public static let maximumEncodedCollectionBytes = 1024 * 1024
    public static let maximumEncodedBytes = 256 * 1024

    public func validate() throws {
        guard UUID(uuidString: id.rawValue)?.uuidString.lowercased() == id.rawValue,
              revision > 0, revision < UInt64.max,
              approvedPlanRevision.map({ $0 > 0 && $0 <= revision }) ?? true else {
            throw MissionError("invalid_mission", "Invalid mission identity, revision or plan approval.")
        }
        try draft.validate()
        guard try JSONEncoder().encode(draft).count <= 64 * 1024 else { throw MissionError("mission_limit", "Mission plan exceeds the 64 KiB planning budget.") }
        if approvedPlanRevision != nil { try draft.validateForApproval() }
        try run?.validate()
        guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else {
            throw MissionError("mission_limit", "Mission exceeds its 256 KiB record budget. Full agent transcripts remain in their threads.")
        }
    }
}

/// The planner's specification and task map, kept separate from owner-assigned identity and approval.
public struct MissionDraft: Codable, Hashable, Sendable {
    public var title: String
    public var goal: String
    public var requirements: [String]
    /// References supplied or discovered during intake, never executable instructions.
    public var context: [String]
    public var plan: MissionPlan?
    public var spaceIDs: [SpaceID] { plan?.lanes.map(\.spaceID) ?? [] }
    public var limits: MissionLimits { plan?.limits ?? MissionLimits() }

    public init(title: String, goal: String, requirements: [String] = [], context: [String] = [], plan: MissionPlan? = nil) {
        self.title = title
        self.goal = goal
        self.requirements = requirements
        self.context = context
        self.plan = plan
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 800,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 16_000,
              requirements.count <= 64, context.count <= 64,
              (requirements + context).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4_000 }) else {
            throw MissionError("invalid_mission", "A mission needs a bounded title, destination and nonempty requirement/context entries.")
        }
        try plan?.validate()
    }

    public func validateForApproval() throws {
        try validate()
        guard !requirements.isEmpty, let plan, !plan.lanes.isEmpty else {
            throw MissionError("invalid_mission", "Define the requirements and repository lanes before approving the map.")
        }
        let workers = plan.stations.filter { $0.kind == .worker }
        let validators = Set(plan.stations.filter { $0.kind == .validator }.map(\.id))
        guard !workers.isEmpty, !validators.isEmpty else {
            throw MissionError("invalid_mission", "The map needs a worker and an independent validator.")
        }
        for worker in workers {
            guard !validators.isDisjoint(with: plan.dataDescendants(of: [worker.id])) else {
                throw MissionError("invalid_mission", "Every worker's output must reach an independent validator through data wires before review.")
            }
        }
    }
}

/// These are proposed execution limits, not a claim that planning has spent or reserved tokens.
public struct MissionLimits: Codable, Hashable, Sendable {
    public var tokens: Int
    public var seconds: Double
    public var concurrentStations: Int
    public var retries: Int
    public var dollars: Double

    public init(tokens: Int = 6_000_000, seconds: Double = 4 * 60 * 60, concurrentStations: Int = 3, retries: Int = 2, dollars: Double = 25) {
        self.tokens = tokens
        self.seconds = seconds
        self.concurrentStations = concurrentStations
        self.retries = retries
        self.dollars = dollars
    }

    private enum CodingKeys: String, CodingKey { case tokens, seconds, concurrentStations, retries, dollars }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decode(Int.self, forKey: .tokens)
        seconds = try c.decode(Double.self, forKey: .seconds)
        concurrentStations = try c.decode(Int.self, forKey: .concurrentStations)
        retries = try c.decode(Int.self, forKey: .retries)
        dollars = try c.decodeIfPresent(Double.self, forKey: .dollars) ?? 25
    }

    public func validate() throws {
        guard tokens > 0, tokens < Int.max, seconds.isFinite, seconds > 0, dollars.isFinite, dollars > 0,
              (1...16).contains(concurrentStations), (0...10).contains(retries) else {
            throw MissionError("invalid_mission", "Limits require positive tokens/time, 1 to 16 concurrent stations and 0 to 10 retries.")
        }
    }
}

/// A lane names a Space on the owning host. Repository/worktree resolution happens at launch,
/// never by interpreting a planner-supplied filesystem path.
public struct MissionLane: Codable, Hashable, Sendable, Identifiable {
    public var spaceID: SpaceID
    public var name: String
    /// Exact local or origin tracking ref selected by the owner, not a model-selected default.
    public var baseBranch: String?
    public var id: SpaceID { spaceID }

    public init(spaceID: SpaceID, name: String, baseBranch: String? = nil) {
        self.spaceID = spaceID
        self.name = name
        self.baseBranch = baseBranch
    }
}

public struct MissionStation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case research, worker, check, decision, validator }
    public var id: MissionStationID
    public var kind: Kind
    /// Nil is the mission orchestration lane. Workers and command checks require a repository lane.
    public var laneID: SpaceID?
    public var title: String
    public var goal: String
    public var model: String?
    public var command: String?
    public var doneWhen: [String]

    public init(id: MissionStationID = MissionStationID(), kind: Kind, laneID: SpaceID? = nil,
                title: String, goal: String, model: String? = nil, command: String? = nil, doneWhen: [String] = []) {
        self.id = id
        self.kind = kind
        self.laneID = laneID
        self.title = title
        self.goal = goal
        self.model = model
        self.command = command
        self.doneWhen = doneWhen
    }
}

public struct MissionDependency: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case flow, data }
    public var source: MissionStationID
    public var target: MissionStationID
    public var kind: Kind
    /// A named output, not the artifact's runtime version or its contents.
    public var artifact: String?

    public init(source: MissionStationID, target: MissionStationID, kind: Kind = .flow, artifact: String? = nil) {
        self.source = source
        self.target = target
        self.kind = kind
        self.artifact = artifact
    }
}

public struct MissionPlan: Codable, Hashable, Sendable {
    public var lanes: [MissionLane]
    public var stations: [MissionStation]
    public var dependencies: [MissionDependency]
    public var limits: MissionLimits

    public init(lanes: [MissionLane] = [], stations: [MissionStation] = [], dependencies: [MissionDependency] = [],
                limits: MissionLimits = MissionLimits()) {
        self.lanes = lanes
        self.stations = stations
        self.dependencies = dependencies
        self.limits = limits
    }

    public func validate() throws { _ = try orderedStations() }

    /// Both wire types constrain execution. Retries are bounded attempts, not graph cycles.
    public func orderedStations() throws -> [MissionStationID] {
        try limits.validate()
        guard lanes.count <= 32, stations.count <= 128, dependencies.count <= 512 else {
            throw MissionError("mission_limit", "A map supports at most 32 lanes, 128 stations and 512 dependencies.")
        }
        let laneIDs = Set(lanes.map(\.spaceID)), stationIDs = Set(stations.map(\.id))
        guard laneIDs.count == lanes.count, stationIDs.count == stations.count,
              Set(dependencies).count == dependencies.count else {
            throw MissionError("invalid_mission", "Lane, station and dependency identities must be unique.")
        }
        for lane in lanes {
            guard UUID(uuidString: lane.spaceID.rawValue)?.uuidString.lowercased() == lane.spaceID.rawValue,
                  !lane.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, lane.name.utf8.count <= 800 else {
                throw MissionError("invalid_mission", "A lane needs a valid Space identity and a bounded name.")
            }
        }
        for station in stations {
            guard UUID(uuidString: station.id.rawValue)?.uuidString.lowercased() == station.id.rawValue,
                  station.laneID.map(laneIDs.contains) ?? true,
                  ![.worker, .check].contains(station.kind) || station.laneID != nil,
                  !station.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, station.title.utf8.count <= 800,
                  !station.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, station.goal.utf8.count <= 16_000,
                  station.model.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }) ?? true,
                  station.doneWhen.count <= 32,
                  station.doneWhen.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 4_000 }) else {
                throw MissionError("invalid_mission", "Invalid station identity, lane, goal or completion checks.")
            }
            if station.kind == .check {
                guard let command = station.command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      command.utf8.count <= 4_000 else {
                    throw MissionError("invalid_mission", "A command check needs a bounded command.")
                }
            } else if station.command != nil {
                throw MissionError("invalid_mission", "Only command-check stations may carry a command.")
            }
        }
        var predecessors: [MissionStationID: Set<MissionStationID>] = [:]
        for edge in dependencies {
            guard edge.source != edge.target, stationIDs.contains(edge.source), stationIDs.contains(edge.target) else {
                throw MissionError("invalid_mission", "Dependencies must connect two existing, different stations.")
            }
            if edge.kind == .data {
                guard let artifact = edge.artifact, !artifact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      artifact.utf8.count <= 800 else {
                    throw MissionError("invalid_mission", "A data wire must name the output it carries.")
                }
            } else if edge.artifact != nil {
                throw MissionError("invalid_mission", "Only data wires may carry an output.")
            }
            predecessors[edge.target, default: []].insert(edge.source)
        }
        var remaining = stationIDs, ordered: [MissionStationID] = []
        // ponytail: at most 128 stations; scan in display order instead of maintaining another graph index.
        while !remaining.isEmpty {
            let ready = stations.filter { remaining.contains($0.id) && (predecessors[$0.id] ?? []).isDisjoint(with: remaining) }.map(\.id)
            guard !ready.isEmpty else { throw MissionError("invalid_mission", "Mission dependencies contain a cycle.") }
            ordered += ready
            remaining.subtract(ready)
        }
        return ordered
    }

    /// Which stations consume an output, directly or transitively. Flow-only neighbours are not consumers.
    public func dataConsumers(of sources: Set<MissionStationID>) throws -> [MissionStationID] {
        let order = try orderedStations()
        guard sources.isSubset(of: Set(order)) else { throw MissionError("invalid_mission", "Output source is not in this map.") }
        let affected = dataDescendants(of: sources)
        return order.filter { affected.contains($0) }
    }

    /// The map without a station or any wire touching it.
    public func removing(_ station: MissionStationID) -> MissionPlan {
        var copy = self
        copy.stations.removeAll { $0.id == station }
        copy.dependencies.removeAll { $0.source == station || $0.target == station }
        return copy
    }

    /// The map without a station, its predecessors wired straight to its successors. A data wire
    /// in and out stays data (named for the output it delivered); anything else becomes flow.
    public func bypassing(_ station: MissionStationID) -> MissionPlan {
        let incoming = dependencies.filter { $0.target == station }, outgoing = dependencies.filter { $0.source == station }
        var copy = removing(station)
        for input in incoming {
            for output in outgoing where input.source != output.target {
                let data = input.kind == .data && output.kind == .data
                let wire = MissionDependency(source: input.source, target: output.target, kind: data ? .data : .flow,
                                             artifact: data ? output.artifact : nil)
                if !copy.dependencies.contains(where: { $0.source == wire.source && $0.target == wire.target && $0.kind == wire.kind }) {
                    copy.dependencies.append(wire)
                }
            }
        }
        return copy
    }

    /// A copy of a station in another lane, with the same wires in and out.
    public func duplicating(_ station: MissionStationID, to lane: SpaceID, as id: MissionStationID = MissionStationID()) -> MissionPlan {
        guard var clone = stations.first(where: { $0.id == station }) else { return self }
        var copy = self
        clone.id = id
        clone.laneID = lane
        copy.stations.insert(clone, at: (stations.firstIndex { $0.id == station } ?? stations.count - 1) + 1)
        for wire in dependencies {
            if wire.target == station { copy.dependencies.append(MissionDependency(source: wire.source, target: id, kind: wire.kind, artifact: wire.artifact)) }
            if wire.source == station { copy.dependencies.append(MissionDependency(source: id, target: wire.target, kind: wire.kind, artifact: wire.artifact)) }
        }
        return copy
    }

    fileprivate func dataDescendants(of sources: Set<MissionStationID>) -> Set<MissionStationID> {
        var reached = sources
        while true {
            let next = Set(dependencies.filter { $0.kind == .data && reached.contains($0.source) }.map(\.target))
            let added = next.subtracting(reached)
            if added.isEmpty { return reached.subtracting(sources) }
            reached.formUnion(added)
        }
    }
}

public extension ShepherdState {
    /// Missions never ride ordinary fleet snapshots (a record can approach the frame cap): a client
    /// that lists `missions.v1` reads them through its own requests.
    var withoutMissions: ShepherdState {
        var copy = self
        copy.missions = []
        return copy
    }
}
