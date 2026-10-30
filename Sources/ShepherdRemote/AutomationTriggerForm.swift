import Foundation
import ShepherdCore
import ShepherdProtocol

/// The editor's trigger sections as plain values (iPhone and iPad, on a host with
/// `automationTriggersCapability`): what fires a run, where it goes, who may fire it, its limits
/// and pins. `settings` is what the draft sends; `check` says what can't be saved and when the
/// schedule next runs.
public struct AutomationTriggerForm: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case manual, schedule, github

        public var title: String {
            switch self {
            case .manual: "Manual"
            case .schedule: "Schedule"
            case .github: "GitHub"
            }
        }
    }

    public enum ScheduleKind: String, CaseIterable, Sendable {
        case every, daily, weekly, custom

        public var title: String {
            switch self {
            case .every: "Every few minutes"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .custom: "Custom RRULE"
            }
        }
    }

    /// One GitHub trigger as typed: lists comma-separated, the number as text.
    public struct GitHub: Equatable, Identifiable, Sendable {
        public var id = UUID()
        /// "owner/name"; empty is the folder's origin.
        public var repo = ""
        public var events: Set<GitHubEventKind> = [.issueLabeled]
        public var labels = ""
        public var authors = ""
        public var title = ""
        public var number = ""

        public init() {}

        init(_ trigger: GitHubTrigger) {
            repo = trigger.repo ?? ""
            events = Set(trigger.events)
            labels = trigger.labels.joined(separator: ", ")
            authors = trigger.authors.joined(separator: ", ")
            title = trigger.titleContains ?? ""
            number = trigger.number.map(String.init) ?? ""
        }

        var trigger: GitHubTrigger {
            let trimmed = number.trimmingCharacters(in: .whitespaces)
            return GitHubTrigger(repo: Self.text(repo), events: GitHubEventKind.allCases.filter(events.contains),
                                 labels: Self.list(labels), authors: Self.list(authors).map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 },
                                 titleContains: Self.text(title), number: Int(trimmed))
        }

        var numberError: String? {
            let trimmed = number.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || Int(trimmed) != nil ? nil : "Number must be a whole number, like 12."
        }

        static func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        static func list(_ value: String) -> [String] {
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    /// What `check` found: the first thing that can't be saved, and when a schedule runs next.
    public struct Check: Equatable, Sendable {
        public var error: String?
        /// "Today 09:00".
        public var next: String?

        public init(error: String? = nil, next: String? = nil) {
            self.error = error
            self.next = next
        }
    }

    /// The fewest minutes Every takes (the host's minimum gap).
    public static let minimumMinutes = Int(AutomationSchedule.minimumInterval / 60)

    public var kind: Kind = .manual
    public var scheduleKind: ScheduleKind = .daily
    public var everyMinutes = 30
    public var hour = 9
    public var minute = 0
    public var days: Set<AutomationWeekday> = AutomationWeekday.weekdays
    public var custom = ""
    /// The saved schedule's anchor, kept through an edit.
    public var start: Double?
    public var github: [GitHub] = [GitHub()]
    /// Nil: a new thread each run.
    public var thread: AgentID?
    public var workspace: AutomationWorkspace = .worktree
    public var gate: AutomationAuthorGate = .collaborators
    public var maxConcurrent = AutomationLimits.default.maxConcurrent
    public var maxPerDay = AutomationLimits.default.maxPerDay
    /// "" is the host's default when the run starts.
    public var model = ""
    public var thinking = ""

    public init() {}

    public init(_ settings: AutomationSettings) {
        switch settings.trigger ?? .manual {
        case .manual: kind = .manual
        case .schedule(let schedule):
            kind = .schedule
            start = schedule.start
            switch AutomationSchedulePreset(rrule: schedule.rrule) {
            case .every(let minutes): (scheduleKind, everyMinutes) = (.every, minutes)
            case .daily(let h, let m): (scheduleKind, hour, minute) = (.daily, h, m)
            case .weekly(let d, let h, let m): (scheduleKind, days, hour, minute) = (.weekly, d, h, m)
            case .custom(let text): (scheduleKind, custom) = (.custom, text)
            }
        case .github(let triggers):
            kind = .github
            github = triggers.isEmpty ? [GitHub()] : triggers.map(GitHub.init)
        }
        if case .thread(let id) = settings.destination { thread = id }
        workspace = settings.workspace ?? .worktree
        gate = settings.authorGate ?? .collaborators
        let limits = settings.limits ?? .default
        (maxConcurrent, maxPerDay) = (limits.maxConcurrent, limits.maxPerDay)
        model = settings.model ?? ""
        thinking = settings.thinking ?? ""
    }

    public var preset: AutomationSchedulePreset {
        switch scheduleKind {
        case .every: .every(minutes: everyMinutes)
        case .daily: .daily(hour: hour, minute: minute)
        case .weekly: .weekly(days: days, hour: hour, minute: minute)
        case .custom: .custom(custom)
        }
    }

    public var trigger: AutomationTrigger {
        switch kind {
        case .manual: .manual
        case .schedule: .schedule(AutomationSchedule(rrule: preset.rrule, start: start))
        case .github: .github(github.map(\.trigger))
        }
    }

    /// Everything the form sets. Speed is not on the form, so it stays as the host has it.
    public var settings: AutomationSettings {
        AutomationSettings(trigger: trigger, destination: kind == .manual ? .newThread : thread.map { .thread($0) } ?? .newThread,
                           workspace: workspace, authorGate: gate,
                           limits: AutomationLimits(maxConcurrent: maxConcurrent, maxPerDay: maxPerDay),
                           model: model, thinking: thinking)
    }

    public var canAddGitHub: Bool { github.count < GitHubTrigger.maxPerAutomation }

    /// The rule the host will apply, and the next run.
    public func check(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> Check {
        if kind == .schedule, scheduleKind == .weekly, days.isEmpty { return Check(error: "Choose at least one day.") }
        if kind == .schedule, scheduleKind == .custom, custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Check(error: "Type an RRULE, like FREQ=WEEKLY;BYDAY=MO;BYHOUR=9;BYMINUTE=0.")
        }
        if kind == .github, let error = github.lazy.compactMap(\.numberError).first { return Check(error: error) }
        if let error = trigger.validationError(now: now, calendar: calendar)
            ?? AutomationLimits(maxConcurrent: maxConcurrent, maxPerDay: maxPerDay).validationError {
            return Check(error: error)
        }
        guard case .schedule(let schedule) = trigger else { return Check() }
        guard let next = schedule.next(after: now, calendar: calendar) else { return Check(error: "This rule never runs again.") }
        return Check(next: AutomationsModel.dayTime(next, now: now, timeZone: calendar.timeZone, locale: locale))
    }
}
