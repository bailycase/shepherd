import CryptoKit
import Foundation

/// The planner's own guess at a whole map's cost. A proposal, never a reservation: limits stay the owner's.
public struct MissionEstimate: Codable, Hashable, Sendable {
    public var tokens: Int
    public var seconds: Double
    public init(tokens: Int, seconds: Double) { self.tokens = tokens; self.seconds = seconds }

    public var valid: Bool { tokens >= 0 && tokens < 1_000_000_000 && seconds.isFinite && seconds >= 0 && seconds < 31_536_000 }
    public func fits(_ limits: MissionLimits) -> Bool { tokens <= limits.tokens && seconds <= limits.seconds }
}

/// A revised map the planner proposed against a map that already exists (MXPatch): held beside it until the
/// owner applies or rejects it, so an answer never silently rewrites an approved route.
public struct MissionPatch: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var proposedAt: Double
    /// The fingerprint of the draft this patch was computed from (`MissionPatch.fingerprint`). Apply and the
    /// diff read the mission's current draft, and apply refuses once it moved on.
    public var base: String
    public var draft: MissionDraft
    /// Why this shape, in the planner's words.
    public var summary: String
    /// The decision the patch settles: the question asked, the owner's answer, and the decision station it resolves.
    public var question: String?
    public var answer: String?
    public var resolves: MissionStationID?

    public init(id: UUID = UUID(), proposedAt: Double, base: MissionDraft, draft: MissionDraft, summary: String,
                question: String? = nil, answer: String? = nil, resolves: MissionStationID? = nil) {
        self.id = id; self.proposedAt = proposedAt; self.base = Self.fingerprint(base); self.draft = draft; self.summary = summary
        self.question = question; self.answer = answer; self.resolves = resolves
    }

    /// The patch settles a decision ("clears fog"): only those may apply on their own.
    public var clearsFog: Bool { answer != nil }
    /// What the patch changes against `current`, the mission's draft now.
    public func diff(from current: MissionDraft) -> MissionPlanDiff { MissionPlanDiff(from: current.plan ?? MissionPlan(), to: draft.plan ?? MissionPlan()) }
    public func applies(to current: MissionDraft) -> Bool { base == Self.fingerprint(current) }

    public static func fingerprint(_ draft: MissionDraft) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(draft)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func validate() throws {
        guard summary.utf8.count <= 4_096, base.utf8.count <= 128, [question, answer].allSatisfy({ ($0?.utf8.count ?? 0) <= 4_096 }),
              proposedAt.isFinite, proposedAt >= 0, draft.plan?.estimate?.valid ?? true else {
            throw MissionError("invalid_mission_run", "Invalid map patch.")
        }
        try draft.validate()
    }
}

/// A decision the owner settled through an applied patch, for the patch inspector's "Decisions so far".
public struct MissionDecisionRecord: Codable, Hashable, Sendable {
    public var station: String
    public var answer: String
    public var at: Double
    public init(station: String, answer: String, at: Double) { self.station = station; self.answer = answer; self.at = at }
}

/// What a patch changes, station by station and wire by wire.
public struct MissionPlanDiff: Hashable, Sendable {
    public var added: [MissionStation]
    public var removed: [MissionStation]
    public var changed: [MissionStation]
    public var addedWires: [MissionDependency]
    public var removedWires: [MissionDependency]

    public init(from old: MissionPlan, to new: MissionPlan) {
        let before = Dictionary(uniqueKeysWithValues: old.stations.map { ($0.id, $0) })
        let after = Set(new.stations.map(\.id))
        added = new.stations.filter { before[$0.id] == nil }
        removed = old.stations.filter { !after.contains($0.id) }
        changed = new.stations.filter { station in before[station.id].map { $0 != station } ?? false }
        let oldWires = Set(old.dependencies), newWires = Set(new.dependencies)
        addedWires = new.dependencies.filter { !oldWires.contains($0) }
        removedWires = old.dependencies.filter { !newWires.contains($0) }
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && addedWires.isEmpty && removedWires.isEmpty }
}

public extension MissionRun {
    /// The owner applied `patch`: its decision is a succeeded receipt on the station it resolves (so dependants
    /// may run) and a line in the decision log. The caller saves `patch.draft` as the mission's draft.
    mutating func settle(_ patch: MissionPatch, at now: Double) {
        if let station = patch.resolves, let answer = patch.answer {
            var receipt = MissionAttempt(stationID: station, status: .succeeded, output: String(answer.prefix(4_096)))
            receipt.startedAt = now; receipt.endedAt = now
            attempts.append(receipt)
        }
        if let answer = patch.answer {
            let name = patch.resolves.flatMap { id in patch.draft.plan?.stations.first { $0.id == id }?.title } ?? "decision"
            decisions = Array(((decisions ?? []) + [MissionDecisionRecord(station: name, answer: String(answer.prefix(400)), at: now)]).suffix(32))
        }
        self.patch = nil
    }
}
