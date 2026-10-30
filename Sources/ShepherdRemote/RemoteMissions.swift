import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

/// One host's missions as a client shows them (the Mac's Missions page for that host, the iPhone's
/// and iPad's Missions): the host's records, read one at a time and pulled again on each
/// `missionChanged` hint, the reviews and Spec Kit reads the client asked for, and every agent the
/// missions own, so their threads stay out of the thread list. Every action carries the revision
/// the caller displayed; publication and Spec Kit consent the fingerprint it displayed.
@MainActor
@Observable
public final class RemoteMissions {
    public typealias Transport = (RemoteMissionRequest) async throws -> RemoteMissionResult

    public let hostID: UUID
    /// The host offers missions now (`missions.v1`, its experiment on) and is connected.
    public private(set) var available = false
    /// The host's missions in its order, as last read. Kept while disconnected, cleared when the host stops offering them.
    public private(set) var records: [Mission] = []
    /// Agents the host's missions started. Kept across a disconnect: an offline host's last state still lists them.
    public private(set) var agentIDs: Set<AgentID> = []
    /// Why the last read failed; nil once one succeeds.
    public private(set) var error: String?
    public private(set) var startOptions: RemoteMissionStartOptions?
    public private(set) var reviews: [MissionID: [RemoteMissionReview]] = [:]
    public private(set) var specKit: [MissionID: RemoteMissionSpecKit] = [:]
    /// What each running mission's agents say now, as the host last pushed it.
    public private(set) var live: [MissionID: RemoteMissionLive] = [:]

    @ObservationIgnored private var transport: Transport?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var summaries: [RemoteMissionSummary] = []
    /// Missions being read, and the newest revision hinted for each while it was.
    @ObservationIgnored private var fetching: Set<MissionID> = []
    @ObservationIgnored private var hinted: [MissionID: UInt64] = [:]
    @ObservationIgnored private var files: [String: DiffFile] = [:]

    public init(hostID: UUID) { self.hostID = hostID }

    /// The host's connection changed: `transport` while it is connected, `available` while it offers missions.
    public func connect(_ transport: Transport?, available: Bool) {
        generation = UUID()
        self.transport = available ? transport : nil
        fetching = []; hinted = [:]
        let now = available && transport != nil
        if self.available != now { self.available = now }
        if transport != nil && !available {
            if !records.isEmpty { records = [] }
            summaries = []
            reviews = [:]; specKit = [:]; files = [:]; startOptions = nil
        }
        if !now, !live.isEmpty { live = [:] }
    }

    /// Lists the host's missions again and reads each one whose revision moved.
    public func refresh() async {
        guard let transport else { return }
        let generation = generation
        do {
            guard case .list(let list) = try await transport(.list), generation == self.generation else { return }
            summaries = list
            let known = Dictionary(records.map { ($0.id, $0.revision) }, uniquingKeysWith: { first, _ in first })
            let kept = records.filter { record in list.contains { $0.id == record.id } }
            if kept.count != records.count { records = kept }
            updateAgents()
            if error != nil { error = nil }
            for summary in list where known[summary.id] != summary.revision { await fetch(summary.id) }
            reorder()
        } catch {
            guard generation == self.generation else { return }
            self.error = Self.describe(error)
        }
    }

    /// The host's hint: a mission was made or changed (`revision`) or went (nil).
    public func changed(_ id: MissionID, revision: UInt64?) {
        guard let revision else {
            records.removeAll { $0.id == id }
            summaries.removeAll { $0.id == id }
            reviews[id] = nil; specKit[id] = nil; live[id] = nil
            updateAgents()
            return
        }
        if let current = records.first(where: { $0.id == id }), current.revision >= revision { return }
        if fetching.contains(id) { hinted[id] = max(hinted[id] ?? 0, revision); return }
        Task { await fetch(id) }
    }

    public func record(_ id: MissionID) -> Mission? { records.first { $0.id == id } }

    /// The host's push: what a mission's agents say now (empty once nothing runs).
    public func liveChanged(_ id: MissionID, _ value: RemoteMissionLive) {
        guard records.contains(where: { $0.id == id }) || fetching.contains(id) else { return }
        if value.isEmpty { if live[id] != nil { live[id] = nil } } else if live[id] != value { live[id] = value }
    }

    /// Reads one mission, then again while a newer revision was hinted during the read.
    private func fetch(_ id: MissionID) async {
        guard let transport, fetching.insert(id).inserted else { return }
        let generation = generation
        defer { if generation == self.generation { fetching.remove(id) } }
        while true {
            hinted[id] = nil
            do {
                guard case .mission(let mission, let current) = try await transport(.get(missionID: id)), generation == self.generation else { return }
                adopt(mission)
                liveChanged(id, current ?? RemoteMissionLive())
            } catch {
                guard generation == self.generation else { return }
                if case RemoteHostClientError.rejected("mission_missing", _) = error { changed(id, revision: nil) }
                else { self.error = Self.describe(error) }
                return
            }
            guard let wanted = hinted[id], wanted > (record(id)?.revision ?? 0) else { return }
        }
    }

    private func adopt(_ mission: Mission) {
        if let index = records.firstIndex(where: { $0.id == mission.id }) {
            if records[index] != mission { records[index] = mission }
        } else {
            records.append(mission)
            reorder()
        }
        let summary = RemoteMissionSummary(mission)
        if let index = summaries.firstIndex(where: { $0.id == mission.id }) { summaries[index] = summary } else { summaries.append(summary) }
        updateAgents()
    }

    /// The host's order (oldest first, as its page lists them).
    private func reorder() {
        let order = Dictionary(summaries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = records.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        if sorted != records { records = sorted }
    }

    private func updateAgents() {
        let ids = Set(summaries.flatMap(\.agentIDs))
        if ids != agentIDs { agentIDs = ids }
    }

    // MARK: Requests

    /// What New mission offers on the host, read again.
    public func loadStartOptions() async throws {
        guard case .startOptions(let options) = try await send(.startOptions) else { throw Self.unexpected }
        if startOptions != options { startOptions = options }
    }

    /// Makes a mission on the host; its planner starts there. Returns its ID.
    public func create(goal: String, spaces: [SpaceID], model: String, branches: [SpaceID: String]) async throws -> MissionID {
        guard case .created(let id) = try await send(.create(goal: goal, spaceIDs: spaces, model: model, branches: branches)) else { throw Self.unexpected }
        await fetch(id)
        return id
    }

    /// One owner action against `revision`, the mission as the caller displayed it. Returns the mission Run again made.
    @discardableResult
    public func perform(_ id: MissionID, revision: UInt64, _ action: RemoteMissionAction) async throws -> MissionID? {
        let result = try await send(.action(missionID: id, revision: revision, action: action))
        switch result {
        case .done(let mission?): adopt(mission)
        case .done(nil): changed(id, revision: nil)
        case .created(let made): await fetch(made); return made
        default: throw Self.unexpected
        }
        return nil
    }

    /// Reads each repository's actual changes again (files and fingerprints).
    public func loadReview(_ id: MissionID) async throws {
        guard case .review(let value) = try await send(.review(missionID: id)) else { throw Self.unexpected }
        if reviews[id] != value { reviews[id] = value }
    }

    /// One reviewed file with its hunks, kept for that repository's review fingerprint.
    public func file(_ id: MissionID, space: SpaceID, path: String) async throws -> DiffFile {
        let fingerprint = reviews[id]?.first { $0.spaceID == space }?.fingerprint ?? ""
        let key = [id.rawValue, space.rawValue, fingerprint, path].joined(separator: "\u{0}")
        if let cached = files[key] { return cached }
        guard case .reviewFile(let file) = try await send(.reviewFile(missionID: id, spaceID: space, path: path)) else { throw Self.unexpected }
        files[key] = file
        return file
    }

    /// Re-reads each repository's stock Spec Kit files and tasks.md progress (reads only).
    public func loadSpecKit(_ id: MissionID) async throws {
        guard case .specKit(let value) = try await send(.specKit(missionID: id)) else { throw Self.unexpected }
        if specKit[id] != value { specKit[id] = value }
    }

    private func send(_ request: RemoteMissionRequest) async throws -> RemoteMissionResult {
        guard let transport else { throw RemoteHostClientError.rejected(code: "update_required", message: RemoteHostClient.missionsRefusal) }
        return try await transport(request)
    }

    private static let unexpected = RemoteHostClientError.rejected(code: "protocol", message: "Unexpected mission reply.")

    /// A refusal's words, else the error's.
    public static func describe(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return String(describing: error)
    }
}

public extension ShepherdState {
    /// The workspace without `agents` and their own tabs: a host's mission agents, whose threads
    /// belong to the mission and never list as ordinary threads (a host sends no missions in its state).
    func withoutAgents(_ agents: Set<AgentID>) -> ShepherdState {
        guard !agents.isEmpty, self.agents.contains(where: { agents.contains($0.id) }) else { return self }
        var copy = self
        let tabs = Set(self.agents.filter { agents.contains($0.id) }.map(\.tabID))
        copy.agents.removeAll { agents.contains($0.id) }
        copy.tabs.removeAll { tabs.contains($0.id) || $0.inspectorFor.map(agents.contains) == true }
        return copy
    }
}
