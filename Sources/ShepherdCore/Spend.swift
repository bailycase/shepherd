import Foundation

// What a thread has spent, as pi reports it (`get_session_stats`): tokens and the catalog's cost estimate. The agent keeps the
// session's running totals and what they grew by today, per model, so a day's total and its breakdown add up across threads
// without asking pi again. Everything here is pure; the host feeds it (`SessionServer`) and the views only format it.

/// How much one model added to a thread's day.
public struct ModelSpend: Codable, Hashable, Sendable {
    /// pi's model id as the thread ran it; nil when the thread named none.
    public var model: String?
    public var tokens: Int
    /// The catalog estimate; nil when the provider reports none (a subscription).
    public var cost: Double?

    public init(model: String?, tokens: Int, cost: Double?) {
        self.model = model
        self.tokens = tokens
        self.cost = cost
    }
}

/// What one background subagent's own pi process has used, as its run last reported it (cumulative, new messages only: a fork's
/// inherited history is not usage of this run).
public struct ChildSpend: Codable, Hashable, Sendable {
    public var tokens: Int
    public var cost: Double?

    public init(tokens: Int, cost: Double?) {
        self.tokens = tokens
        self.cost = cost
    }
}

/// A subagent run's usage as the extension published it, for `AgentSpend.addingChildren`.
public struct ChildUsage: Hashable, Sendable {
    /// The run's row id (`ChildRun.id`).
    public var id: String
    /// The model the run uses.
    public var model: String?
    public var tokens: Int?
    public var cost: Double?
    /// The run has ended: seen for the first time, it is history rather than today's work.
    public var finished: Bool

    public init(id: String, model: String?, tokens: Int?, cost: Double?, finished: Bool) {
        self.id = id
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.finished = finished
    }
}

/// A thread's spend: the session totals pi last reported, its subagents' own, and what they all grew by on `day`.
public struct AgentSpend: Codable, Hashable, Sendable {
    /// The session's total tokens as last reported.
    public var tokens: Int
    /// The session's estimated cost as last reported; nil until pi has reported one. A report with no cost keeps the last known.
    public var cost: Double?
    /// The calendar day `today` belongs to (`SpendDay.key`), counted in `zone`.
    public var day: String
    /// Growth since `day` began, by model: the model the thread ran when the totals moved.
    public var today: [ModelSpend]
    /// The pi session the totals belong to: another id is a fresh session (`/new`) whose totals all count.
    public var sessionID: String?
    /// The time zone (identifier) the host counted `day` in, so every viewer says the same day is today; nil is the viewer's own.
    public var zone: String?
    /// Each background subagent's usage as last reported, by run id: separate pi processes, so not in `tokens`.
    public var children: [String: ChildSpend]

    public init(tokens: Int, cost: Double?, day: String, zone: String? = nil, today: [ModelSpend] = [], sessionID: String? = nil,
                children: [String: ChildSpend] = [:]) {
        self.tokens = tokens
        self.cost = cost
        self.day = day
        self.today = today
        self.sessionID = sessionID
        self.zone = zone
        self.children = children
    }

    private enum CodingKeys: String, CodingKey { case tokens, cost, day, today, sessionID, zone, children }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decode(Int.self, forKey: .tokens)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        day = try c.decode(String.self, forKey: .day)
        today = try c.decodeIfPresent([ModelSpend].self, forKey: .today) ?? []
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        zone = try c.decodeIfPresent(String.self, forKey: .zone)
        children = try c.decodeIfPresent([String: ChildSpend].self, forKey: .children) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tokens, forKey: .tokens)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encode(day, forKey: .day)
        try c.encode(today, forKey: .today)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(zone, forKey: .zone)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }

    /// Everything the thread used: its own session and its subagents' runs.
    public var totalTokens: Int { tokens + children.values.reduce(0) { $0 + $1.tokens } }
    /// The known costs added up; nil when none is known.
    public var totalCost: Double? {
        let costs = [cost].compactMap { $0 } + children.values.compactMap(\.cost)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    /// The spend after pi reported `tokens` and `cost` while the thread ran `model` on `day` (in `zone`). The first report is a
    /// baseline (a resumed thread's earlier days are not today's). Later ones add only growth: a total that went down within the
    /// same session (a retry dropped a failed reply) adds nothing and becomes the new baseline, so the same report again, or what
    /// the retry bills again, is neither lost nor counted twice. Another `sessionID` is a fresh session (`/new`) and counts whole.
    /// A report with no cost keeps the last known one, so `$4 → nil → $5` grew by $1. Nil `tokens` is no report.
    public static func updated(_ previous: AgentSpend?, tokens: Int?, cost: Double?, model: String?, day: String, zone: String? = nil,
                               sessionID: String? = nil) -> AgentSpend? {
        guard let tokens else { return previous }
        guard var spend = previous else {
            return AgentSpend(tokens: tokens, cost: cost, day: day, zone: zone, sessionID: sessionID)
        }
        spend.start(day, zone)
        if let sessionID, let known = spend.sessionID, sessionID != known {
            spend.tokens = 0
            spend.cost = nil
            spend.children = [:]
        }
        if let sessionID { spend.sessionID = sessionID }
        spend.add(model: model, tokens: max(0, tokens - spend.tokens), cost: cost.map { max(0, $0 - (spend.cost ?? 0)) })
        spend.tokens = tokens
        if let cost { spend.cost = cost }
        return spend
    }

    /// The spend after the subagent runs' usage as the extension last published it: what each grew by since it was last seen
    /// joins today, under the model the run uses. A run's first sighting counts whole while it runs and as history once it has
    /// finished (it is a run from before this host knew the thread). Nothing is recorded before the thread's own baseline.
    public static func addingChildren(_ previous: AgentSpend?, _ runs: [ChildUsage], day: String, zone: String? = nil) -> AgentSpend? {
        guard var spend = previous else { return nil }
        spend.start(day, zone)
        for run in runs {
            guard let tokens = run.tokens else { continue }
            let known = spend.children[run.id]
            if known != nil || !run.finished {
                let before = known ?? ChildSpend(tokens: 0, cost: nil)
                spend.add(model: run.model, tokens: max(0, tokens - before.tokens), cost: run.cost.map { max(0, $0 - (before.cost ?? 0)) })
            }
            spend.children[run.id] = ChildSpend(tokens: tokens, cost: run.cost ?? known?.cost)
        }
        return spend
    }

    /// A new day (or zone) starts the entries over.
    private mutating func start(_ day: String, _ zone: String?) {
        guard self.day != day || self.zone != zone else { return }
        self.day = day
        self.zone = zone
        today = []
    }

    private mutating func add(model: String?, tokens: Int, cost: Double?) {
        guard tokens > 0 || (cost ?? 0) > 0 else { return }
        if let index = today.firstIndex(where: { $0.model == model }) {
            today[index].tokens += tokens
            if let cost { today[index].cost = (today[index].cost ?? 0) + cost }
        } else {
            today.append(ModelSpend(model: model, tokens: tokens, cost: cost))
        }
    }
}

/// The calendar day a spend belongs to.
public enum SpendDay {
    /// "2026-05-14", in `calendar`'s time zone.
    public static func key(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The calendar for a spend's zone identifier; this device's for none or an unknown one.
    public static func calendar(zone: String?) -> Calendar {
        var calendar = Calendar.current
        if let zone, let timeZone = TimeZone(identifier: zone) { calendar.timeZone = timeZone }
        return calendar
    }

    /// `date`'s day in `zone`: what a host stamps on a report and every viewer compares, so a day is the same day everywhere.
    public static func key(_ date: Date, zone: String?) -> String { key(date, calendar: calendar(zone: zone)) }

    /// When "today" next changes for any of `spends`: the next midnight in the zone of the one that comes first. Nil for none.
    public static func nextChange(of spends: [AgentSpend], after now: Date) -> Date? {
        Set(spends.map(\.zone)).compactMap { zone in
            calendar(zone: zone).nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
        }.min()
    }
}

/// One day's spend across threads, with its per-model breakdown.
public struct SpendRollup: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        public var model: String?
        public var tokens: Int
        public var cost: Double?
        public var id: String { model ?? "" }
        /// The model as a breakdown row names it.
        public var name: String { SpendFormat.modelName(model) }
        /// "est. $12.10 · 6.1M tok".
        public var text: String { SpendFormat.line(tokens: tokens, cost: cost) ?? "0 tok" }

        public init(model: String?, tokens: Int, cost: Double?) {
            self.model = model
            self.tokens = tokens
            self.cost = cost
        }
    }

    public var tokens: Int
    /// The known costs added up; nil when no thread had one. Threads that report none add tokens only.
    public var cost: Double?
    /// Costliest model first, then the most tokens, then by name.
    public var models: [Line]

    public init(tokens: Int = 0, cost: Double? = nil, models: [Line] = []) {
        self.tokens = tokens
        self.cost = cost
        self.models = models
    }

    public static let empty = SpendRollup()

    /// Nothing was spent: the header says nothing.
    public var isEmpty: Bool { tokens == 0 && (cost ?? 0) <= 0 }

    /// What `spends` added up to on the day `now` is, in each spend's own zone. A thread whose entries are from another day adds nothing.
    public static func today(_ spends: [AgentSpend], now: Date = Date()) -> SpendRollup {
        var byModel: [String: Line] = [:]
        for spend in spends where spend.day == SpendDay.key(now, zone: spend.zone) {
            for entry in spend.today {
                let key = entry.model ?? ""
                var line = byModel[key] ?? Line(model: entry.model, tokens: 0, cost: nil)
                line.tokens += entry.tokens
                if let cost = entry.cost { line.cost = (line.cost ?? 0) + cost }
                byModel[key] = line
            }
        }
        let lines = byModel.values.filter { $0.tokens > 0 || ($0.cost ?? 0) > 0 }.sorted {
            if ($0.cost ?? 0) != ($1.cost ?? 0) { return ($0.cost ?? 0) > ($1.cost ?? 0) }
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return ($0.model ?? "") < ($1.model ?? "")
        }
        let costs = lines.compactMap(\.cost)
        return SpendRollup(tokens: lines.reduce(0) { $0 + $1.tokens }, cost: costs.isEmpty ? nil : costs.reduce(0, +), models: lines)
    }
}

/// A day's rollup as a page header says it, formatted once when the spend or the day changes so a view only draws it.
public struct SpendSummary: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        /// The model.
        public var name: String
        /// "est. $12.10 · 6.1M tok".
        public var value: String
    }

    /// "est. $34.50 · 12.4M tok".
    public var total: String
    public var rows: [Row]

    /// Nil when nothing was spent: the header says nothing.
    public init?(_ rollup: SpendRollup) {
        guard let total = SpendFormat.line(rollup) else { return nil }
        self.total = total
        rows = rollup.models.map { Row(id: $0.id, name: $0.name, value: $0.text) }
    }

    /// What `spends` came to on the day `now` is.
    public init?(_ spends: [AgentSpend], now: Date = Date()) { self.init(SpendRollup.today(spends, now: now)) }
}

/// How spend reads: "est. $4.20 · 3.1M tok". The cost is pi's catalog estimate, so it says "est."; a thread with no cost (a
/// subscription, a local model) shows its tokens alone.
public enum SpendFormat {
    /// "950", "12.4k", "3.1M".
    public static func tokens(_ count: Int) -> String {
        func scaled(_ value: Double, _ unit: String) -> String {
            let text = String(format: "%.1f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        switch count {
        case ..<1_000: return "\(max(0, count))"
        case ..<999_950: return scaled(Double(count) / 1_000, "k")
        case ..<999_950_000: return scaled(Double(count) / 1_000_000, "M")
        default: return scaled(Double(count) / 1_000_000_000, "B")
        }
    }

    /// "$4.20", "<$0.01".
    public static func cost(_ amount: Double) -> String {
        if amount < 0.005 { return "<$0.01" }
        if amount < 1_000 { return String(format: "$%.2f", amount) }
        return String(format: "$%.0f", amount)
    }

    /// "est. $4.20 · 3.1M tok"; "3.1M tok" without a cost; "est. $0.30" without tokens; nil for nothing.
    public static func line(tokens: Int?, cost: Double?) -> String? {
        var parts: [String] = []
        if let cost, cost > 0 { parts.append("est. \(Self.cost(cost))") }
        if let tokens, tokens > 0 { parts.append("\(Self.tokens(tokens)) tok") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A thread's whole session, for its sidebar row; nil while unknown.
    public static func line(_ spend: AgentSpend?) -> String? {
        spend.flatMap { line(tokens: $0.totalTokens, cost: $0.totalCost) }
    }

    /// The cost alone ("est. $4.20"), or the tokens when the thread has no cost: for a line with little room.
    public static func brief(_ spend: AgentSpend?) -> String? {
        guard let spend else { return nil }
        return (spend.totalCost ?? 0) > 0 ? line(tokens: nil, cost: spend.totalCost) : line(tokens: spend.totalTokens, cost: nil)
    }

    /// A day's total, for a page header; nil when nothing was spent.
    public static func line(_ rollup: SpendRollup) -> String? {
        rollup.isEmpty ? nil : line(tokens: rollup.tokens, cost: rollup.cost)
    }

    /// A model's name for a breakdown row: pi's id without its provider ("anthropic/claude-sonnet-4" → "claude-sonnet-4").
    public static func modelName(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "Unknown model" }
        return model.split(separator: "/").last.map(String.init) ?? model
    }
}
