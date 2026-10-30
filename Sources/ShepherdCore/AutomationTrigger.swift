import Foundation

// What starts an automation's run, where the run goes and the bounds it runs under. The trigger
// decides when; the automation's prompt decides what each run does. Every type decodes older
// or partial JSON with the defaults below, so a record saved before triggers reads as manual.

/// When an automation fires.
public enum AutomationTrigger: Hashable, Sendable, Codable {
    /// Run now only: the legacy watcher automation (and auto-start at launch when enabled).
    case manual
    /// A calendar recurrence (RFC 5545 RRULE), anchored at `start` (seconds since 1970).
    case schedule(AutomationSchedule)
    /// GitHub activity, polled through the user's `gh`. One to `GitHubTrigger.maxPerAutomation`.
    case github([GitHubTrigger])

    public var isManual: Bool { self == .manual }

    private enum CodingKeys: String, CodingKey { case type, rrule, start, triggers }
    private enum Kind: String, Codable { case manual, schedule, github }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(Kind.self, forKey: .type) ?? .manual {
        case .manual: self = .manual
        case .schedule:
            self = .schedule(AutomationSchedule(
                rrule: try c.decode(String.self, forKey: .rrule),
                start: try c.decodeIfPresent(Double.self, forKey: .start)))
        case .github: self = .github(try c.decode([GitHubTrigger].self, forKey: .triggers))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual: try c.encode(Kind.manual, forKey: .type)
        case .schedule(let schedule):
            try c.encode(Kind.schedule, forKey: .type)
            try c.encode(schedule.rrule, forKey: .rrule)
            try c.encodeIfPresent(schedule.start, forKey: .start)
        case .github(let triggers):
            try c.encode(Kind.github, forKey: .type)
            try c.encode(triggers, forKey: .triggers)
        }
    }

    /// The reason this trigger can't be saved, nil when it can.
    public func validationError(now: Date = Date(), calendar: Calendar = .current) -> String? {
        switch self {
        case .manual: return nil
        case .schedule(let schedule): return schedule.validationError(now: now, calendar: calendar)
        case .github(let triggers):
            guard (1...GitHubTrigger.maxPerAutomation).contains(triggers.count) else {
                return "An automation watches 1 to \(GitHubTrigger.maxPerAutomation) GitHub triggers."
            }
            return triggers.lazy.compactMap(\.validationError).first
        }
    }
}

/// A recurrence: an RRULE body ("FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0", an optional
/// "RRULE:" prefix allowed) and its anchor. Times are the host's local time zone.
public struct AutomationSchedule: Hashable, Sendable, Codable {
    /// The shortest gap allowed between two runs.
    public static let minimumInterval: TimeInterval = 5 * 60

    public var rrule: String
    /// DTSTART, seconds since 1970. Nil anchors at the moment the schedule was saved.
    public var start: Double?

    public init(rrule: String, start: Double? = nil) {
        self.rrule = rrule
        self.start = start
    }

    /// The first run strictly after `date`, nil when the rule has ended.
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let rule = try? RRule.parse(rrule, calendar: calendar) else { return nil }
        let anchor = start.map { Date(timeIntervalSince1970: $0) } ?? date
        return rule.recurrences(of: anchor, in: date..<Date.distantFuture).lazy.first { $0 > date }
    }

    public func validationError(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let rule: Calendar.RecurrenceRule
        do { rule = try RRule.parse(rrule, calendar: calendar) } catch { return "\(error)" }
        let anchor = start.map { Date(timeIntervalSince1970: $0) } ?? now
        // Sample the first runs: every gap must clear the minimum, whatever produced it.
        let sample = Array(rule.recurrences(of: anchor).prefix(64))
        for (a, b) in zip(sample, sample.dropFirst()) where b.timeIntervalSince(a) < Self.minimumInterval {
            return "Runs must be at least 5 minutes apart."
        }
        return nil
    }
}

/// RFC 5545 RRULE text to Foundation's `Calendar.RecurrenceRule`, which does the date math.
public enum RRule {
    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public var description: String
    }

    public static func parse(_ text: String, calendar: Calendar = .current) throws -> Calendar.RecurrenceRule {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.uppercased().hasPrefix("RRULE:") { body.removeFirst(6) }
        var parts: [String: String] = [:]
        for part in body.split(separator: ";") where !part.isEmpty {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { throw ParseError(description: "Malformed RRULE part \"\(part)\".") }
            let key = pair[0].uppercased()
            guard parts[key] == nil else { throw ParseError(description: "RRULE repeats \(key).") }
            parts[key] = pair[1]
        }
        guard let freqText = parts.removeValue(forKey: "FREQ") else { throw ParseError(description: "RRULE needs FREQ.") }
        let frequencies: [String: Calendar.RecurrenceRule.Frequency] = [
            "MINUTELY": .minutely, "HOURLY": .hourly, "DAILY": .daily,
            "WEEKLY": .weekly, "MONTHLY": .monthly, "YEARLY": .yearly,
        ]
        guard let frequency = frequencies[freqText.uppercased()] else {
            throw ParseError(description: "FREQ=\(freqText) isn't supported (MINUTELY to YEARLY).")
        }
        var rule = Calendar.RecurrenceRule(calendar: calendar, frequency: frequency)
        rule.matchingPolicy = .nextTimePreservingSmallerComponents
        if let value = parts.removeValue(forKey: "INTERVAL") {
            guard let n = Int(value), n > 0 else { throw ParseError(description: "INTERVAL must be a positive number.") }
            rule.interval = n
        }
        let count = parts.removeValue(forKey: "COUNT")
        let until = parts.removeValue(forKey: "UNTIL")
        switch (count, until) {
        case (.some, .some): throw ParseError(description: "RRULE can't have both COUNT and UNTIL.")
        case (let count?, nil):
            guard let n = Int(count), n > 0 else { throw ParseError(description: "COUNT must be a positive number.") }
            rule.end = .afterOccurrences(n)
        case (nil, let until?):
            guard let date = untilDate(until, calendar: calendar) else { throw ParseError(description: "UNTIL \"\(until)\" isn't a date.") }
            rule.end = .afterDate(date)
        case (nil, nil): break
        }
        if let v = parts.removeValue(forKey: "BYSECOND") { rule.seconds = try ints(v, "BYSECOND", 0...60) }
        if let v = parts.removeValue(forKey: "BYMINUTE") { rule.minutes = try ints(v, "BYMINUTE", 0...59) }
        if let v = parts.removeValue(forKey: "BYHOUR") { rule.hours = try ints(v, "BYHOUR", 0...23) }
        if let v = parts.removeValue(forKey: "BYMONTHDAY") { rule.daysOfTheMonth = try ints(v, "BYMONTHDAY", -31...31, nonzero: true) }
        if let v = parts.removeValue(forKey: "BYYEARDAY") { rule.daysOfTheYear = try ints(v, "BYYEARDAY", -366...366, nonzero: true) }
        if let v = parts.removeValue(forKey: "BYWEEKNO") { rule.weeks = try ints(v, "BYWEEKNO", -53...53, nonzero: true) }
        if let v = parts.removeValue(forKey: "BYMONTH") {
            rule.months = try ints(v, "BYMONTH", 1...12).map { Calendar.RecurrenceRule.Month($0) }
        }
        if let v = parts.removeValue(forKey: "BYSETPOS") { rule.setPositions = try ints(v, "BYSETPOS", -366...366, nonzero: true) }
        if let v = parts.removeValue(forKey: "BYDAY") { rule.weekdays = try weekdays(v) }
        if let v = parts.removeValue(forKey: "WKST") {
            guard weekday(v.uppercased()) != nil else { throw ParseError(description: "WKST \"\(v)\" isn't a weekday.") }
            // Foundation takes the week's first day from the calendar.
            var cal = rule.calendar
            cal.firstWeekday = weekdayNumber(v.uppercased())!
            rule.calendar = cal
        }
        if let unknown = parts.keys.sorted().first { throw ParseError(description: "RRULE part \(unknown) isn't supported.") }
        return rule
    }

    private static let weekdayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    private static func weekday(_ code: String) -> Locale.Weekday? {
        switch code {
        case "SU": .sunday
        case "MO": .monday
        case "TU": .tuesday
        case "WE": .wednesday
        case "TH": .thursday
        case "FR": .friday
        case "SA": .saturday
        default: nil
        }
    }

    private static func weekdayNumber(_ code: String) -> Int? {
        weekdayCodes.firstIndex(of: code).map { $0 + 1 }
    }

    private static func weekdays(_ text: String) throws -> [Calendar.RecurrenceRule.Weekday] {
        try text.split(separator: ",").map { raw in
            let item = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard item.count >= 2, let day = weekday(String(item.suffix(2))) else {
                throw ParseError(description: "BYDAY \"\(raw)\" isn't a weekday.")
            }
            let ordinal = item.dropLast(2)
            if ordinal.isEmpty { return .every(day) }
            guard let n = Int(ordinal), n != 0, (-53...53).contains(n) else {
                throw ParseError(description: "BYDAY \"\(raw)\" has a bad ordinal.")
            }
            return .nth(n, day)
        }
    }

    private static func ints(_ text: String, _ name: String, _ range: ClosedRange<Int>, nonzero: Bool = false) throws -> [Int] {
        try text.split(separator: ",").map { raw in
            guard let n = Int(raw.trimmingCharacters(in: .whitespaces)), range.contains(n), !(nonzero && n == 0) else {
                throw ParseError(description: "\(name) value \"\(raw)\" is out of range.")
            }
            return n
        }
    }

    /// UNTIL as a date (YYYYMMDD, local end of day) or date-time (local, or UTC with Z).
    private static func untilDate(_ text: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = text.hasSuffix("Z") ? TimeZone(identifier: "UTC") : calendar.timeZone
        for format in ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        formatter.dateFormat = "yyyyMMdd"
        guard let day = formatter.date(from: text) else { return nil }
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: day)
    }
}

/// GitHub activity an automation reacts to. Kinds Codex offers for pull requests, plus issues.
public enum GitHubEventKind: String, Codable, Hashable, Sendable, CaseIterable {
    case issueOpened
    case issueLabeled
    case issueComment
    case pullRequestOpened
    case pullRequestLabeled
    case pullRequestReview
    case pullRequestComment
    /// New commits on a pull request's head (several pushes between checks are one event).
    case pullRequestCommits
    case pullRequestMerged

    public var isPullRequest: Bool {
        switch self {
        case .issueOpened, .issueLabeled, .issueComment: false
        default: true
        }
    }

    /// Words for a summary row ("issue labeled").
    public var label: String {
        switch self {
        case .issueOpened: "issue opened"
        case .issueLabeled: "issue labeled"
        case .issueComment: "issue comment"
        case .pullRequestOpened: "PR opened"
        case .pullRequestLabeled: "PR labeled"
        case .pullRequestReview: "PR review"
        case .pullRequestComment: "PR comment"
        case .pullRequestCommits: "PR commits"
        case .pullRequestMerged: "PR merged"
        }
    }
}

/// One GitHub trigger: the repository, the activity, and filters that must all match.
public struct GitHubTrigger: Hashable, Sendable, Codable {
    public static let maxPerAutomation = 5

    /// "owner/name". Nil means the `origin` remote of the automation's directory.
    public var repo: String?
    /// Any of these fires. Never empty when saved.
    public var events: [GitHubEventKind]
    /// The issue or PR carries at least one of these (for *Labeled kinds: the label just added).
    public var labels: [String]
    /// The issue's or PR's author is one of these logins (empty: anyone the author gate allows).
    public var authors: [String]
    /// Case-insensitive substring of the title.
    public var titleContains: String?
    /// One issue or PR number only.
    public var number: Int?

    public init(repo: String? = nil, events: [GitHubEventKind], labels: [String] = [], authors: [String] = [],
                titleContains: String? = nil, number: Int? = nil) {
        self.repo = repo
        self.events = events
        self.labels = labels
        self.authors = authors
        self.titleContains = titleContains
        self.number = number
    }

    private enum CodingKeys: String, CodingKey { case repo, events, labels, authors, titleContains, number }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        events = try c.decodeIfPresent([GitHubEventKind].self, forKey: .events) ?? []
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        titleContains = try c.decodeIfPresent(String.self, forKey: .titleContains)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
    }

    public var validationError: String? {
        if events.isEmpty { return "A GitHub trigger needs at least one event." }
        if let repo, repo.split(separator: "/").count != 2 || repo.contains(" ") {
            return "Repository \"\(repo)\" must be owner/name."
        }
        if let number, number <= 0 { return "Issue or PR number must be positive." }
        return nil
    }
}

/// Where a run happens.
public enum AutomationDestination: Hashable, Sendable, Codable {
    /// A new thread per run.
    case newThread
    /// The same existing thread every time: each firing is sent to it as a message.
    case thread(AgentID)

    private enum CodingKeys: String, CodingKey { case type, agentID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let agentID = try c.decodeIfPresent(AgentID.self, forKey: .agentID) {
            self = .thread(agentID)
        } else {
            self = .newThread
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newThread: try c.encode("newThread", forKey: .type)
        case .thread(let agentID):
            try c.encode("thread", forKey: .type)
            try c.encode(agentID, forKey: .agentID)
        }
    }
}

/// Where a new-thread run works on disk.
public enum AutomationWorkspace: String, Codable, Hashable, Sendable, CaseIterable {
    /// A new worktree per run, branched off a fresh fetch of the default branch (a git repo;
    /// anything else runs in place).
    case worktree
    /// The automation's directory itself.
    case local

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .worktree
    }
}

/// Whose GitHub activity may fire a run, by the author's association with the repository.
public enum AutomationAuthorGate: String, Codable, Hashable, Sendable, CaseIterable {
    /// OWNER, MEMBER or COLLABORATOR.
    case collaborators
    /// Also CONTRIBUTOR (has a merged commit).
    case contributors
    /// Anyone who can open an issue.
    case anyone

    public init(from decoder: Decoder) throws {
        // Unknown values close the gate rather than widen it.
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .collaborators
    }

    /// Whether an author with GitHub's `author_association` may fire a run.
    public func admits(_ association: String) -> Bool {
        switch association.uppercased() {
        case "OWNER", "MEMBER", "COLLABORATOR": true
        case "CONTRIBUTOR": self != .collaborators
        default: self == .anyone
        }
    }
}

/// The bounds a triggered automation runs under.
public struct AutomationLimits: Hashable, Sendable, Codable {
    public static let `default` = AutomationLimits(maxConcurrent: 2, maxPerDay: 20)
    public static let concurrentRange = 1...10
    public static let perDayRange = 1...200

    /// Runs going at once; more events wait.
    public var maxConcurrent: Int
    /// Runs started per local calendar day; more events wait.
    public var maxPerDay: Int

    public init(maxConcurrent: Int, maxPerDay: Int) {
        self.maxConcurrent = maxConcurrent
        self.maxPerDay = maxPerDay
    }

    private enum CodingKeys: String, CodingKey { case maxConcurrent, maxPerDay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrent = try c.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? Self.default.maxConcurrent
        maxPerDay = try c.decodeIfPresent(Int.self, forKey: .maxPerDay) ?? Self.default.maxPerDay
    }

    public var validationError: String? {
        if !Self.concurrentRange.contains(maxConcurrent) { return "Runs at once must be 1 to 10." }
        if !Self.perDayRange.contains(maxPerDay) { return "Runs a day must be 1 to 200." }
        return nil
    }
}

/// What fired a run: a GitHub event or a schedule tick. Event text is untrusted input; a run
/// receives it fenced as data, never as part of the automation's prompt.
public struct AutomationEvent: Codable, Hashable, Sendable, Identifiable {
    /// Body text kept per event.
    public static let bodyLimit = 8 * 1024

    /// Dedupe key: unique per occurrence (repo, number, kind, and the action's own id).
    public var id: String
    /// Nil for a schedule tick.
    public var kind: GitHubEventKind?
    public var repo: String?
    public var number: Int?
    public var title: String
    public var url: String?
    public var author: String?
    public var body: String?
    /// For a labeled event, the label added; for commits, the head SHA.
    public var detail: String?
    /// Which of the automation's GitHub triggers matched (0-based).
    public var triggerIndex: Int?
    /// Seconds since 1970.
    public var occurredAt: Double

    public init(id: String, kind: GitHubEventKind? = nil, repo: String? = nil, number: Int? = nil, title: String,
                url: String? = nil, author: String? = nil, body: String? = nil, detail: String? = nil,
                triggerIndex: Int? = nil, occurredAt: Double) {
        self.id = id
        self.kind = kind
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.body = body.map { String($0.prefix(Self.bodyLimit)) }
        self.detail = detail
        self.triggerIndex = triggerIndex
        self.occurredAt = occurredAt
    }

    /// One line for a run row ("#12 Fix login crash · issue labeled shepherd").
    public var summary: String {
        guard let kind else { return title }
        let head = number.map { "#\($0) \(title)" } ?? title
        let tail = detail.map { kind == .pullRequestCommits ? String($0.prefix(7)) : $0 }
        return [head, [kind.label, tail].compactMap { $0 }.joined(separator: " ")].joined(separator: " · ")
    }
}

/// Marks a thread a triggered automation started, so its runs survive relaunch as ordinary
/// threads yet still group under their automation.
public struct AutomationOrigin: Codable, Hashable, Sendable {
    public var automationID: AutomationID
    /// The event that fired the run, nil for a schedule tick or Run now.
    public var eventID: String?
    /// The event's one-line summary and page, for the run's row.
    public var trigger: String?
    public var triggerURL: String?

    public init(automationID: AutomationID, eventID: String? = nil, trigger: String? = nil, triggerURL: String? = nil) {
        self.automationID = automationID
        self.eventID = eventID
        self.trigger = trigger
        self.triggerURL = triggerURL
    }
}

/// A change to an automation's trigger settings, as the agent tools, the editor and remote
/// clients send it: a nil field keeps the saved value, so a client that predates a field never
/// clears it.
public struct AutomationSettings: Codable, Hashable, Sendable {
    public var trigger: AutomationTrigger?
    public var destination: AutomationDestination?
    public var workspace: AutomationWorkspace?
    public var authorGate: AutomationAuthorGate?
    public var limits: AutomationLimits?
    /// An empty string clears a pin (back to the default at run time).
    public var model: String?
    public var thinking: String?
    public var serviceTier: String?

    public init(trigger: AutomationTrigger? = nil, destination: AutomationDestination? = nil,
                workspace: AutomationWorkspace? = nil, authorGate: AutomationAuthorGate? = nil,
                limits: AutomationLimits? = nil, model: String? = nil, thinking: String? = nil,
                serviceTier: String? = nil) {
        self.trigger = trigger
        self.destination = destination
        self.workspace = workspace
        self.authorGate = authorGate
        self.limits = limits
        self.model = model
        self.thinking = thinking
        self.serviceTier = serviceTier
    }

    /// Every setting of `automation`, pins included.
    public init(of automation: Automation) {
        self.init(trigger: automation.trigger, destination: automation.destination, workspace: automation.workspace,
                  authorGate: automation.authorGate, limits: automation.limits, model: automation.model ?? "",
                  thinking: automation.thinking?.rawValue ?? "", serviceTier: automation.serviceTier?.rawValue ?? "")
    }

    public var isEmpty: Bool { self == AutomationSettings() }

    /// Applies the set fields, or names the first that can't be saved.
    public func apply(to automation: inout Automation) throws(AutomationSettingsError) {
        var next = automation
        if let trigger { next.trigger = trigger }
        if let destination { next.destination = destination }
        if let workspace { next.workspace = workspace }
        if let authorGate { next.authorGate = authorGate }
        if let limits { next.limits = limits }
        if let model { next.model = model.isEmpty ? nil : model }
        if let thinking {
            if thinking.isEmpty { next.thinking = nil } else {
                guard let level = ThinkingLevel(rawValue: thinking) else {
                    throw AutomationSettingsError(message: "Unknown thinking level \"\(thinking)\".")
                }
                next.thinking = level
            }
        }
        if let serviceTier {
            if serviceTier.isEmpty { next.serviceTier = nil } else {
                guard let tier = ServiceTier(rawValue: serviceTier) else {
                    throw AutomationSettingsError(message: "Unknown speed \"\(serviceTier)\".")
                }
                next.serviceTier = tier
            }
        }
        if let message = next.triggerValidationError { throw AutomationSettingsError(message: message) }
        if case .thread = next.destination, next.trigger.isManual {
            throw AutomationSettingsError(message: "Sending runs to a thread needs a schedule or GitHub trigger.")
        }
        automation = next
    }
}

public struct AutomationSettingsError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}
