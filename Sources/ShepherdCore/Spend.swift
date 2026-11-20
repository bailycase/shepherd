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

/// A thread's spend: the session totals pi last reported and what they grew by on `day`.
public struct AgentSpend: Codable, Hashable, Sendable {
    /// The session's total tokens as last reported.
    public var tokens: Int
    /// The session's estimated cost as last reported; nil when pi reports none.
    public var cost: Double?
    /// The local calendar day `today` belongs to (`SpendDay.key`).
    public var day: String
    /// Growth since `day` began, by model: the model the thread ran when the totals moved.
    public var today: [ModelSpend]

    public init(tokens: Int, cost: Double?, day: String, today: [ModelSpend] = []) {
        self.tokens = tokens
        self.cost = cost
        self.day = day
        self.today = today
    }

    /// The spend after pi reported `tokens` and `cost` while the thread ran `model` on `day`. The first report is a baseline (a
    /// resumed thread's earlier days are not today's); later ones add the growth to `day`'s entry for the model, and a new day starts
    /// the entries over. Totals that went down (`/new` started a fresh session) count whole. Nil `tokens` is no report.
    public static func updated(_ previous: AgentSpend?, tokens: Int?, cost: Double?, model: String?, day: String) -> AgentSpend? {
        guard let tokens else { return previous }
        guard var spend = previous else { return AgentSpend(tokens: tokens, cost: cost, day: day) }
        if spend.day != day {
            spend.day = day
            spend.today = []
        }
        let tokenGrowth = tokens >= spend.tokens ? tokens - spend.tokens : tokens
        var costGrowth: Double?
        if let cost {
            let before = spend.cost ?? 0
            costGrowth = cost >= before ? cost - before : cost
        }
        if tokenGrowth > 0 || (costGrowth ?? 0) > 0 {
            if let index = spend.today.firstIndex(where: { $0.model == model }) {
                spend.today[index].tokens += tokenGrowth
                if let costGrowth { spend.today[index].cost = (spend.today[index].cost ?? 0) + costGrowth }
            } else {
                spend.today.append(ModelSpend(model: model, tokens: tokenGrowth, cost: costGrowth))
            }
        }
        spend.tokens = tokens
        spend.cost = cost
        return spend
    }
}

/// The local calendar day a spend belongs to.
public enum SpendDay {
    /// "2026-05-14", in `calendar`'s time zone.
    public static func key(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
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

    /// What `spends` added up to on `day`. A thread whose entries are from another day adds nothing.
    public static func today(_ spends: [AgentSpend], day: String) -> SpendRollup {
        var byModel: [String: Line] = [:]
        for spend in spends where spend.day == day {
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
        spend.flatMap { line(tokens: $0.tokens, cost: $0.cost) }
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
