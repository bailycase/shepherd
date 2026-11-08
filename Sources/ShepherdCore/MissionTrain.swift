import Foundation

/// MXTrain: a published mission's pull requests merged one at a time, in an order worked out from the
/// map's data wires, each through update → CI → merge (→ staging → soak) before the next starts.
/// Host-owned receipts: the owner's Start authorizes exactly these PRs, this order and these rules.
public struct MissionTrain: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case running, paused, done }

    public struct Rules: Codable, Hashable, Sendable {
        public enum Between: String, Codable, Sendable, CaseIterable { case mergeOnly, soak, stagingSoak }
        public enum Lockfiles: String, Codable, Sendable, CaseIterable { case fix, pause }
        public enum RedCI: String, Codable, Sendable, CaseIterable { case pause, revertPause }
        public enum Window: String, Codable, Sendable, CaseIterable { case anyTime, weekdays }
        public var between: Between
        public var soakMinutes: Int
        public var lockfiles: Lockfiles
        public var redCI: RedCI
        public var window: Window
        /// Per repository: the owner's staging deploy and soak health commands, run in the mission worktree.
        public var staging: [SpaceID: String]
        public var health: [SpaceID: String]

        public init(between: Between = .mergeOnly, soakMinutes: Int = 10, lockfiles: Lockfiles = .fix, redCI: RedCI = .revertPause,
                    window: Window = .anyTime, staging: [SpaceID: String] = [:], health: [SpaceID: String] = [:]) {
            self.between = between; self.soakMinutes = soakMinutes; self.lockfiles = lockfiles; self.redCI = redCI
            self.window = window; self.staging = staging; self.health = health
        }

        /// Weekdays 9:00 to 16:00 in the host's time zone.
        public func open(at date: Date, calendar: Calendar = .current) -> Bool {
            guard window == .weekdays else { return true }
            let parts = calendar.dateComponents([.weekday, .hour], from: date)
            guard let weekday = parts.weekday, let hour = parts.hour else { return true }
            return (2...6).contains(weekday) && (9..<16).contains(hour)
        }
    }

    public enum StepKind: String, Codable, Sendable { case update, ci, merge, staging, soak }
    public enum StepStatus: String, Codable, Sendable { case pending, running, done, failed, fixed, skipped }

    public struct Step: Codable, Hashable, Sendable {
        public var kind: StepKind
        public var status: StepStatus
        public var at: Double?
        /// What the host saw: a conflict, the regenerated lockfile, a soak's last health output.
        public var note: String?
        public init(kind: StepKind, status: StepStatus = .pending, at: Double? = nil, note: String? = nil) {
            self.kind = kind; self.status = status; self.at = at; self.note = note
        }
    }

    public struct Car: Codable, Hashable, Sendable, Identifiable {
        public var spaceID: SpaceID
        public var steps: [Step]
        public var id: SpaceID { spaceID }
        public init(spaceID: SpaceID, steps: [Step]) { self.spaceID = spaceID; self.steps = steps }
        public var merged: Bool { steps.contains { $0.kind == .merge && $0.status == .done } }
        public var finished: Bool { steps.allSatisfy { [.done, .fixed, .skipped].contains($0.status) } }
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var at: Double
        public var subject: String
        public var text: String
        /// Who did it: "train", "auto · rule", "soak", "someone else", "you".
        public var by: String
        public init(at: Double, subject: String, text: String, by: String) { self.at = at; self.subject = subject; self.text = text; self.by = by }
    }

    public var status: Status
    public var rules: Rules
    public var cars: [Car]
    public var log: [Entry]
    public var startedAt: Double
    /// Why the train paused, for the owner.
    public var notice: String?
    /// Set by Skip soak: the soak in progress ends now.
    public var skipSoak: Bool?

    public init(order: [SpaceID], rules: Rules, startedAt: Double) {
        status = .running; self.rules = rules; self.startedAt = startedAt; log = []
        cars = order.map { Car(spaceID: $0, steps: Self.steps(rules)) }
    }

    public static func steps(_ rules: Rules) -> [Step] {
        let kinds: [StepKind] = switch rules.between {
        case .mergeOnly: [.update, .ci, .merge]
        case .soak: [.update, .ci, .merge, .soak]
        case .stagingSoak: [.update, .ci, .merge, .staging, .soak]
        }
        return kinds.map { Step(kind: $0) }
    }

    public var merged: Int { cars.filter(\.merged).count }
    /// The car the train works on now: the first that hasn't finished.
    public var current: Int? { cars.firstIndex { !$0.finished } }

    /// Stops the train where it is: a running step goes back to pending (it runs again on Resume).
    public mutating func pause(_ notice: String) {
        status = .paused
        self.notice = notice
        for car in cars.indices { for step in cars[car].steps.indices where cars[car].steps[step].status == .running { cars[car].steps[step].status = .pending } }
    }

    public mutating func record(_ entry: Entry) { log = Array((log + [entry]).suffix(80)) }

    public func validate() throws {
        guard cars.count <= 32, Set(cars.map(\.spaceID)).count == cars.count, log.count <= 80,
              (0...24 * 60).contains(rules.soakMinutes), startedAt.isFinite,
              notice.map({ $0.utf8.count <= 4_096 }) ?? true,
              (Array(rules.staging.values) + Array(rules.health.values)).allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4_000 }),
              cars.allSatisfy({ $0.steps.count <= 8 && $0.steps.allSatisfy { ($0.note?.utf8.count ?? 0) <= 2_048 } }),
              log.allSatisfy({ $0.subject.utf8.count <= 800 && $0.text.utf8.count <= 800 && $0.by.utf8.count <= 64 }) else {
            throw MissionError("invalid_mission_run", "Invalid merge train record.")
        }
    }
}

/// The order a mission's pull requests merge in, from the map's data wires: a repository whose output another
/// repository's stations take goes first. Ties keep the smaller diff first, then the map's lane order.
public struct MissionTrainOrder: Hashable, Sendable {
    public struct Reason: Hashable, Sendable {
        public var lanes: [SpaceID]
        public var title: String
        public var text: String
    }
    public var lanes: [SpaceID]
    public var reasons: [Reason]

    public init(plan: MissionPlan, sizes: [SpaceID: Int] = [:]) {
        let laneOf = Dictionary(uniqueKeysWithValues: plan.stations.map { ($0.id, $0.laneID) })
        let name = { (id: SpaceID) in plan.lanes.first { $0.spaceID == id }?.name ?? "repository" }
        // feeds[a] = lanes taking a's output, with the output's name.
        var feeds: [SpaceID: [SpaceID: String]] = [:]
        for wire in plan.dependencies where wire.kind == .data {
            guard let from = laneOf[wire.source] ?? nil, let to = laneOf[wire.target] ?? nil, from != to else { continue }
            feeds[from, default: [:]][to] = feeds[from]?[to] ?? wire.artifact ?? "its output"
        }
        var remaining = plan.lanes.map(\.spaceID), order: [SpaceID] = [], reasons: [Reason] = []
        let rank = { (id: SpaceID) in (sizes[id] ?? Int.max, plan.lanes.firstIndex { $0.spaceID == id } ?? 0) }
        while !remaining.isEmpty {
            // Lanes nothing remaining feeds; a cycle of wires falls back to the whole remainder.
            var ready = remaining.filter { lane in !remaining.contains { feeds[$0]?[lane] != nil && $0 != lane } }
            if ready.isEmpty { ready = remaining }
            ready.sort { rank($0) < rank($1) }
            for lane in ready {
                let takers = (feeds[lane] ?? [:]).keys.filter { remaining.contains($0) }
                if !takers.isEmpty {
                    let artifacts = Set(takers.compactMap { feeds[lane]?[$0] }).sorted()
                    let everyone = takers.count == remaining.count - 1
                    reasons.append(Reason(lanes: [lane], title: "\(name(lane)) \(everyone ? "first" : "before \(takers.map(name).sorted().joined(separator: ", "))")",
                                          text: "\(everyone ? "Every other lane" : takers.map(name).sorted().joined(separator: " and ")) takes \(artifacts.joined(separator: ", ")) from it, so it merges before they build on main."))
                }
            }
            let quiet = ready.filter { lane in (feeds[lane] ?? [:]).keys.allSatisfy { !remaining.contains($0) } }
            if quiet.count > 1 {
                reasons.append(Reason(lanes: quiet, title: quiet.map(name).joined(separator: ", then "),
                                      text: "They share no wire, so either order is safe. The smaller diff goes first."))
            }
            order += ready
            remaining.removeAll { ready.contains($0) }
        }
        lanes = order
        self.reasons = reasons
    }

    /// An order the owner chose is safe when no repository merges before one whose output it takes.
    public static func allows(_ order: [SpaceID], plan: MissionPlan) -> Bool {
        let laneOf = Dictionary(uniqueKeysWithValues: plan.stations.map { ($0.id, $0.laneID) })
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return plan.dependencies.filter { $0.kind == .data }.allSatisfy { wire in
            guard let from = laneOf[wire.source] ?? nil, let to = laneOf[wire.target] ?? nil, from != to,
                  let a = position[from], let b = position[to] else { return true }
            return a < b
        }
    }
}
