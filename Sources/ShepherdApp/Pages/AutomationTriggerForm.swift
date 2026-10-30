import Foundation
import ShepherdCore

// The automation editor's Trigger, Destination, Workspace, Who can trigger, Limits and pins as
// plain values: read from a saved automation, edited by the sheet, and written back as one
// `AutomationSettings` patch. The sheet keeps one of these in its state and parses nothing in
// its body.

/// A schedule as the editor offers it: three presets, or an RRULE typed by hand.
enum AutomationSchedulePreset: Hashable {
    case everyMinutes(Int)
    /// `hour`, `minute`, local time.
    case daily(hour: Int, minute: Int)
    /// `weekdays` are 1 (Sunday) to 7 (Saturday), as `Calendar` numbers them.
    case weekly(weekdays: Set<Int>, hour: Int, minute: Int)
    case custom(String)

    enum Kind: Hashable { case minutes, daily, weekly, custom }

    var kind: Kind {
        switch self {
        case .everyMinutes: .minutes
        case .daily: .daily
        case .weekly: .weekly
        case .custom: .custom
        }
    }

    private static let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// The RRULE body it saves.
    var rrule: String {
        switch self {
        case .everyMinutes(let n): "FREQ=MINUTELY;INTERVAL=\(n)"
        case .daily(let hour, let minute): "FREQ=DAILY;BYHOUR=\(hour);BYMINUTE=\(minute);BYSECOND=0"
        case .weekly(let days, let hour, let minute):
            "FREQ=WEEKLY;BYDAY=\(days.sorted().map { Self.codes[$0 - 1] }.joined(separator: ","));BYHOUR=\(hour);BYMINUTE=\(minute);BYSECOND=0"
        case .custom(let text): text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The preset a saved RRULE is, else custom (its text as saved).
    init(rrule text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.uppercased().hasPrefix("RRULE:") { body.removeFirst(6) }
        var parts: [String: String] = [:]
        for part in body.uppercased().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, parts[pair[0]] == nil else { self = .custom(text); return }
            parts[pair[0]] = pair[1]
        }
        if parts["BYSECOND"] == "0" { parts["BYSECOND"] = nil }
        let hour = parts["BYHOUR"].flatMap(Int.init), minute = parts["BYMINUTE"].flatMap(Int.init)
        let keys = Set(parts.keys)
        switch parts["FREQ"] {
        case "MINUTELY" where keys == ["FREQ", "INTERVAL"]:
            if let n = parts["INTERVAL"].flatMap(Int.init) { self = .everyMinutes(n); return }
        case "DAILY" where keys == ["FREQ", "BYHOUR", "BYMINUTE"]:
            if let hour, let minute { self = .daily(hour: hour, minute: minute); return }
        case "WEEKLY" where keys == ["FREQ", "BYDAY", "BYHOUR", "BYMINUTE"]:
            let days = parts["BYDAY"]!.split(separator: ",").map { Self.codes.firstIndex(of: String($0)).map { $0 + 1 } }
            if let hour, let minute, !days.contains(nil) {
                self = .weekly(weekdays: Set(days.compactMap { $0 }), hour: hour, minute: minute)
                return
            }
        default: break
        }
        self = .custom(text)
    }

    /// "Every 15 minutes", "Daily at 09:00", "Mon, Wed at 09:00", or the RRULE.
    var summary: String {
        switch self {
        case .everyMinutes(let n): n == 1 ? "Every minute" : "Every \(n) minutes"
        case .daily(let hour, let minute): "Daily at \(Self.clock(hour, minute))"
        case .weekly(let days, let hour, let minute):
            "\(days.sorted().map { Self.dayNames[$0 - 1] }.joined(separator: ", ")) at \(Self.clock(hour, minute))"
        case .custom(let text): text
        }
    }

    static func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
    static func dayName(_ weekday: Int) -> String { dayNames[weekday - 1] }
}

/// One GitHub trigger's fields as typed: lists as comma-separated text, the number as text.
struct GitHubTriggerForm: Hashable, Identifiable {
    var id = UUID()
    var repo = ""
    var events: Set<GitHubEventKind> = [.issueLabeled]
    var labels = ""
    var authors = ""
    var titleContains = ""
    var number = ""

    init() {}

    init(_ trigger: GitHubTrigger) {
        repo = trigger.repo ?? ""
        events = Set(trigger.events)
        labels = trigger.labels.joined(separator: ", ")
        authors = trigger.authors.joined(separator: ", ")
        titleContains = trigger.titleContains ?? ""
        number = trigger.number.map(String.init) ?? ""
    }

    /// Blank fields are unset; an unreadable number stays as typed so validation names it.
    var trigger: GitHubTrigger {
        func list(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let repo = repo.trimmingCharacters(in: .whitespaces)
        let title = titleContains.trimmingCharacters(in: .whitespaces)
        let number = number.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return GitHubTrigger(repo: repo.isEmpty ? nil : repo,
                             events: GitHubEventKind.allCases.filter(events.contains),
                             labels: list(labels), authors: list(authors).map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 },
                             titleContains: title.isEmpty ? nil : title,
                             number: number.isEmpty ? nil : (Int(number) ?? -1))
    }
}

/// The editor's trigger and run settings.
struct AutomationTriggerForm: Equatable {
    enum Kind: Hashable { case manual, schedule, github }

    var kind: Kind = .manual
    var preset: AutomationSchedulePreset.Kind = .daily
    var intervalMinutes = 60
    var hour = 9
    var minute = 0
    var weekdays: Set<Int> = [2]
    var customRRule = ""
    /// A saved schedule's anchor, kept while its rule is unchanged.
    var scheduleStart: Double?
    var savedRRule: String?
    var github: [GitHubTriggerForm] = [GitHubTriggerForm()]
    /// Nil sends each run to a new thread.
    var thread: AgentID?
    var workspace: AutomationWorkspace = .worktree
    var authorGate: AutomationAuthorGate = .collaborators
    var maxConcurrent = AutomationLimits.default.maxConcurrent
    var maxPerDay = AutomationLimits.default.maxPerDay
    /// "" is the default when the run starts.
    var model = ""
    var thinking = ""

    init() {}

    init(_ automation: Automation) {
        switch automation.trigger {
        case .manual: kind = .manual
        case .schedule(let schedule):
            kind = .schedule
            savedRRule = schedule.rrule
            scheduleStart = schedule.start
            switch AutomationSchedulePreset(rrule: schedule.rrule) {
            case .everyMinutes(let n): (preset, intervalMinutes) = (.minutes, n)
            case .daily(let h, let m): (preset, hour, minute) = (.daily, h, m)
            case .weekly(let days, let h, let m): (preset, weekdays, hour, minute) = (.weekly, days, h, m)
            case .custom(let text): (preset, customRRule) = (.custom, text)
            }
        case .github(let triggers):
            kind = .github
            github = triggers.map(GitHubTriggerForm.init)
        }
        if case .thread(let id) = automation.destination { thread = id }
        workspace = automation.workspace
        authorGate = automation.authorGate
        maxConcurrent = automation.limits.maxConcurrent
        maxPerDay = automation.limits.maxPerDay
        model = automation.model ?? ""
        thinking = automation.thinking?.rawValue ?? ""
    }

    var schedulePreset: AutomationSchedulePreset {
        switch preset {
        case .minutes: .everyMinutes(intervalMinutes)
        case .daily: .daily(hour: hour, minute: minute)
        case .weekly: .weekly(weekdays: weekdays, hour: hour, minute: minute)
        case .custom: .custom(customRRule)
        }
    }

    var schedule: AutomationSchedule {
        let rrule = schedulePreset.rrule
        return AutomationSchedule(rrule: rrule, start: rrule == savedRRule ? scheduleStart : nil)
    }

    var trigger: AutomationTrigger {
        switch kind {
        case .manual: .manual
        case .schedule: .schedule(schedule)
        case .github: .github(github.map(\.trigger))
        }
    }

    /// The first thing that keeps it from saving, in words for the sheet; nil when it can.
    func validationError(now: Date = Date(), calendar: Calendar = .current) -> String? {
        if kind == .schedule {
            if preset == .weekly, weekdays.isEmpty { return "Pick at least one day." }
            if preset == .custom, customRRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Type an RRULE, like FREQ=WEEKLY;BYDAY=MO;BYHOUR=9."
            }
        }
        if kind == .github, let index = github.firstIndex(where: { $0.trigger.number == -1 }) {
            return "Trigger \(index + 1): the number must be a whole number."
        }
        if let error = trigger.validationError(now: now, calendar: calendar) { return error }
        if thread != nil, kind == .manual { return "Sending runs to a thread needs a schedule or GitHub trigger." }
        return nil
    }

    /// The schedule's next run, for the preview; nil when it isn't a valid schedule.
    func nextRun(after now: Date, calendar: Calendar = .current) -> Date? {
        guard kind == .schedule, validationError(now: now, calendar: calendar) == nil else { return nil }
        return schedule.next(after: now, calendar: calendar)
    }

    /// Every setting, as the patch the save sends.
    var settings: AutomationSettings {
        AutomationSettings(trigger: trigger, destination: thread.map(AutomationDestination.thread) ?? .newThread,
                           workspace: workspace, authorGate: authorGate,
                           limits: AutomationLimits(maxConcurrent: maxConcurrent, maxPerDay: maxPerDay),
                           model: model, thinking: thinking)
    }

    /// Who can trigger, widened past collaborators, says so.
    var gateWarning: String? {
        guard kind == .github else { return nil }
        return switch authorGate {
        case .collaborators: nil
        case .contributors: "Anyone with a merged commit can start a run with their issue or PR text."
        case .anyone: "Anyone who can open an issue can start a run with their text. Runs read it as untrusted, but keep limits low."
        }
    }
}
