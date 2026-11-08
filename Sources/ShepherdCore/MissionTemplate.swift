import Foundation

/// A finished mission's map kept to start the next one from (MXTemplateSave, MXTemplates, MXTemplateStart): its
/// stations and wires, what a new mission fills in, what the run taught it, and how its runs went. Saved for you
/// alone on this Mac, or for your team as `.shepherd/maps/<id>.yml` in a repository (JSON, which is YAML too).
public struct MissionTemplate: Codable, Hashable, Sendable, Identifiable {
    public struct Input: Codable, Hashable, Sendable {
        public enum FilledBy: String, Codable, Sendable { case goal, planner, you }
        public var name: String
        public var kind: String
        /// What the run it came from used.
        public var example: String
        public var filledBy: FilledBy
        public init(name: String, kind: String, example: String, filledBy: FilledBy) {
            self.name = name; self.kind = kind; self.example = example; self.filledBy = filledBy
        }
    }

    public struct Learned: Codable, Hashable, Sendable {
        public var at: Double
        public var text: String
        public init(at: Double, text: String) { self.at = at; self.text = text }
    }

    /// One line of "Changed from this run": `+` learned, `=` kept, `−` dropped.
    public struct Change: Hashable, Sendable {
        public var sign: String
        public var name: String
        public var text: String
        public var learned: Bool
    }

    public var id: String
    public var name: String
    public var summary: String
    public var inputs: [Input]
    /// The map. Its lanes are the repositories the run used, by name; a new mission maps them onto its own.
    public var plan: MissionPlan
    public var requirements: [String]
    public var learned: [Learned]
    public var runs: Int
    public var seconds: Double
    public var tokens: Int
    /// The repository a team template lives in (by name); nil for one kept on this Mac.
    public var team: String?

    public init(id: String, name: String, summary: String, inputs: [Input], plan: MissionPlan, requirements: [String],
                learned: [Learned] = [], runs: Int = 1, seconds: Double = 0, tokens: Int = 0, team: String? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.inputs = inputs; self.plan = plan
        self.requirements = requirements; self.learned = learned; self.runs = runs; self.seconds = seconds; self.tokens = tokens; self.team = team
    }

    /// "add-an-event-across-services": the file name a template saves under.
    public static func slug(_ name: String) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(8)
        return words.isEmpty ? "map" : words.joined(separator: "-")
    }

    /// A template from a finished mission: the map without the stations it never ran, every decision the
    /// owner settled turned into an input asked up front, and what its retries taught.
    public static func from(_ mission: Mission, name: String, summary: String, at now: Double) -> MissionTemplate {
        let run = mission.run
        var plan = mission.draft.plan ?? MissionPlan()
        let ran = Set(run?.attempts.compactMap(\.stationID) ?? [])
        // A finished mission's stations that never ran were a route not taken.
        if run?.phase == .done || run?.phase == .review {
            for station in plan.stations where !ran.contains(station.id) && station.kind != .decision { plan = plan.removing(station.id) }
        }
        var inputs = [Input(name: "goal", kind: "destination", example: String(mission.draft.goal.prefix(120)), filledBy: .goal)]
        inputs += plan.lanes.map { Input(name: $0.name, kind: "repo", example: $0.name, filledBy: .planner) }
        var learned: [Learned] = []
        for station in plan.stations where station.kind == .decision {
            let answer = run?.latest(station.id)?.output ?? ""
            inputs.append(Input(name: station.title, kind: "decision", example: String(answer.prefix(120)), filledBy: .you))
            if !answer.isEmpty { learned.append(Learned(at: now, text: "Ask for \(station.title) before drafting")) }
        }
        for station in plan.stations where station.kind == .check || station.kind == .validator {
            if (run?.attempts.filter { $0.stationID == station.id }.count ?? 0) > 1 { learned.append(Learned(at: now, text: "\(station.title) needed a retry; keep retry ≤\(plan.limits.retries)")) }
        }
        // A new mission draws its own lanes; the template keeps their names and drops branch choices.
        plan.lanes = plan.lanes.map { MissionLane(spaceID: $0.spaceID, name: $0.name) }
        return MissionTemplate(id: slug(name), name: name, summary: summary, inputs: inputs, plan: plan, requirements: mission.draft.requirements,
                               learned: learned, runs: 1, seconds: run?.elapsedSeconds ?? 0, tokens: run?.tokens ?? 0)
    }

    /// What the template changes from the mission it came from.
    public func changes(from mission: Mission) -> [Change] {
        var lines: [Change] = []
        let kept = Set(plan.stations.map(\.id))
        for input in inputs where input.filledBy == .you { lines.append(Change(sign: "+", name: input.name, text: "asked before drafting", learned: true)) }
        let gates = plan.stations.filter { $0.kind == .check }.map(\.title)
        if !gates.isEmpty { lines.append(Change(sign: "=", name: "retry ≤\(plan.limits.retries)", text: "on \(gates.joined(separator: ", "))", learned: false)) }
        lines.append(Change(sign: "↻", name: "contract", text: "\(requirements.count) checks become inputs to fill", learned: false))
        for station in mission.draft.plan?.stations ?? [] where !kept.contains(station.id) {
            lines.append(Change(sign: "−", name: station.title, text: "route was never taken", learned: false))
        }
        return lines
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 80, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty, name.utf8.count <= 200, summary.utf8.count <= 4_000,
              inputs.count <= 64, requirements.count <= 64, learned.count <= 64, runs >= 0, seconds.isFinite, tokens >= 0 else {
            throw MissionError("invalid_template", "Invalid mission template.")
        }
        try plan.validate()
    }

    public var encoded: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}
