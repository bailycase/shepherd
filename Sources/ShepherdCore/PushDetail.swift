import Foundation

/// What a push's long-press preview draws (NotifPhoneRich, NotifPhoneReview), carried in the
/// relay's `detail` field and forwarded as `shepherd.detail`. Every list and string is bounded
/// so the whole event stays inside the relay's 2048-byte body; the relay checks the same bounds.
public struct PushDetail: Codable, Hashable, Sendable {
    public struct Lane: Codable, Hashable, Sendable {
        public enum State: String, Codable, Sendable { case done, running, failed, waiting }
        public var name: String
        /// Its stations in plan order, as their latest attempts left them.
        public var states: [State]
        /// "done", the running station's title, "stuck" or "waiting".
        public var status: String
        public init(name: String, states: [State], status: String) {
            self.name = name; self.states = states; self.status = status
        }
    }
    public struct Stuck: Codable, Hashable, Sendable {
        public var lane: String
        /// Attempts made at the approved plan, at least `tries.count`.
        public var count: Int
        /// The last attempts, oldest first: each one's first line.
        public var tries: [String]
        public init(lane: String, count: Int, tries: [String]) { self.lane = lane; self.count = count; self.tries = tries }
    }
    public struct Repo: Codable, Hashable, Sendable {
        public var name: String
        public var pr: Int?
        public var added: Int?
        public var removed: Int?
        public init(name: String, pr: Int? = nil, added: Int? = nil, removed: Int? = nil) {
            self.name = name; self.pr = pr; self.added = added; self.removed = removed
        }
    }
    public struct Contract: Codable, Hashable, Sendable {
        public var passed: Int
        public var total: Int
        public init(passed: Int, total: Int) { self.passed = passed; self.total = total }
    }

    public var lanes: [Lane]?
    public var stuck: Stuck?
    /// Why the mission stopped, in its own words.
    public var read: String?
    public var repos: [Repo]?
    public var contract: Contract?
    /// A question's options, each a button under the push.
    public var options: [String]?

    public init(lanes: [Lane]? = nil, stuck: Stuck? = nil, read: String? = nil, repos: [Repo]? = nil,
                contract: Contract? = nil, options: [String]? = nil) {
        self.lanes = lanes; self.stuck = stuck; self.read = read; self.repos = repos
        self.contract = contract; self.options = options
    }

    /// The relay's bounds (shepherd-landing `detail`): counts, then characters per string.
    public enum Limit {
        public static let lanes = 5, states = 6, laneName = 24, status = 16
        public static let tries = 3, attempt = 60, read = 200
        public static let repos = 6, repoName = 40
        public static let options = 4, option = 40
    }

    /// A stopped mission: its lanes, the lane stuck at its retry limit with its last tries, and the notice.
    public static func blocked(_ mission: Mission) -> PushDetail? {
        guard let run = mission.run, let plan = mission.draft.plan else { return nil }
        let lanes = plan.lanes.prefix(Limit.lanes).compactMap { lane -> Lane? in
            let stations = plan.stations.filter { $0.laneID == lane.spaceID }
            guard !stations.isEmpty else { return nil }
            let latest = stations.map { run.latest($0.id) }
            let states: [Lane.State] = latest.map { attempt in
                switch attempt?.status {
                case .succeeded: .done
                case .running: .running
                case .failed, .interrupted: .failed
                case .superseded, nil: .waiting
                }
            }
            let status = states.contains(.failed) ? "stuck"
                : states.contains(.running) ? stations[states.firstIndex(of: .running)!].title
                : states.allSatisfy { $0 == .done } ? "done" : "waiting"
            return Lane(name: clip(lane.name, Limit.laneName), states: Array(states.prefix(Limit.states)),
                        status: clip(status, Limit.status))
        }
        var stuck: Stuck?
        if let station = plan.stations.first(where: { $0.laneID != nil && run.latest($0.id)?.status == .failed }),
           let lane = plan.lanes.first(where: { $0.spaceID == station.laneID }) {
            let tries = run.attempts.filter { $0.stationID == station.id && $0.planRevision == mission.approvedPlanRevision }
            let lines = tries.suffix(Limit.tries).compactMap { attempt in
                attempt.output.split(whereSeparator: \.isNewline).first.map { clip(String($0), Limit.attempt) }
            }
            if !tries.isEmpty { stuck = Stuck(lane: clip(lane.name, Limit.laneName), count: tries.count, tries: lines) }
        }
        let detail = PushDetail(lanes: lanes.isEmpty ? nil : lanes, stuck: stuck, read: run.notice.map { clip($0, Limit.read) })
        return detail == PushDetail() ? nil : detail
    }

    /// A mission ready to review: its repositories in merge order with their changes, and its checks.
    public static func review(_ mission: Mission) -> PushDetail? {
        guard let run = mission.run, !run.checkouts.isEmpty else { return nil }
        let order = mission.draft.plan?.lanes.map(\.spaceID) ?? []
        let checkouts = run.checkouts.sorted { (order.firstIndex(of: $0.spaceID) ?? .max) < (order.firstIndex(of: $1.spaceID) ?? .max) }
        let repos = checkouts.prefix(Limit.repos).map { checkout in
            Repo(name: clip(URL(fileURLWithPath: checkout.repo).lastPathComponent, Limit.repoName),
                 pr: checkout.prURL.flatMap { URL(string: $0)?.lastPathComponent }.flatMap(Int.init),
                 added: checkout.added, removed: checkout.removed)
        }
        let checks = (mission.draft.plan?.stations ?? []).filter { $0.kind == .check || $0.kind == .validator }
        let passed = checks.filter { run.latest($0.id)?.status == .succeeded }.count
        return PushDetail(repos: repos, contract: checks.isEmpty ? nil : Contract(passed: passed, total: checks.count))
    }

    /// A question's options as buttons, only when every one fits whole: a clipped title would answer something else.
    public static func question(options: [String]) -> PushDetail? {
        guard !options.isEmpty, options.count <= Limit.options,
              options.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= Limit.option && !$0.contains(where: \.isNewline) }) else { return nil }
        return PushDetail(options: options)
    }

    /// Every string, through `transform` (the host's redaction), clipped to its bound again after.
    /// What the relay would refuse is dropped here (an empty string or list), since a refusal
    /// reads as an older relay and costs every later push its detail.
    public func mapText(_ transform: (String) -> String) -> PushDetail {
        func text(_ value: String, _ limit: Int) -> String? {
            let clipped = Self.clip(transform(value), limit)
            return clipped.isEmpty ? nil : clipped
        }
        func nonEmpty<T>(_ items: [T]?) -> [T]? { items?.isEmpty == false ? items : nil }
        var detail = self
        detail.lanes = nonEmpty(lanes?.compactMap { lane in
            guard let name = text(lane.name, Limit.laneName), !lane.states.isEmpty else { return nil }
            return Lane(name: name, states: Array(lane.states.prefix(Limit.states)), status: text(lane.status, Limit.status) ?? "waiting")
        }.prefix(Limit.lanes).map { $0 })
        detail.stuck = stuck.flatMap { stuck in
            text(stuck.lane, Limit.laneName).map { Stuck(lane: $0, count: max(0, stuck.count),
                                                         tries: stuck.tries.suffix(Limit.tries).compactMap { text($0, Limit.attempt) }) }
        }
        detail.read = read.flatMap { text($0, Limit.read) }
        detail.repos = nonEmpty(repos?.compactMap { repo in
            text(repo.name, Limit.repoName).map { Repo(name: $0, pr: repo.pr, added: repo.added, removed: repo.removed) }
        }.prefix(Limit.repos).map { $0 })
        detail.contract = contract.flatMap { $0.passed >= 0 && $0.passed <= $0.total ? $0 : nil }
        // An option is sent whole or not at all.
        if let options, options.map(transform) != options || Self.question(options: options) == nil { detail.options = nil }
        return detail
    }

    /// One line, at most `limit` Unicode scalars (the relay counts code points), with an ellipsis when cut.
    static func clip(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.unicodeScalars.count > limit else { return line }
        return String(String.UnicodeScalarView(line.unicodeScalars.prefix(limit - 1))) + "…"
    }
}
