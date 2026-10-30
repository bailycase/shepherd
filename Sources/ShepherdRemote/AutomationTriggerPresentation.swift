import Foundation
import ShepherdCore
import ShepherdProtocol

// Triggered automations as a client words them (`automationTriggersCapability`): what fires a
// run ("Weekdays at 09:00", "GitHub: issue labeled shepherd in owner/repo"), how the trigger
// stands ("Paused", with the host's reason), and the events waiting for a free slot. Pure values,
// derived with `AutomationsModel`.

/// A day of the week as an RRULE names it, Monday first.
public enum AutomationWeekday: String, CaseIterable, Hashable, Sendable {
    case mo = "MO", tu = "TU", we = "WE", th = "TH", fr = "FR", sa = "SA", su = "SU"

    /// "Mon".
    public var short: String {
        switch self {
        case .mo: "Mon"
        case .tu: "Tue"
        case .we: "Wed"
        case .th: "Thu"
        case .fr: "Fri"
        case .sa: "Sat"
        case .su: "Sun"
        }
    }

    public static let weekdays: Set<Self> = [.mo, .tu, .we, .th, .fr]
    public static let weekend: Set<Self> = [.sa, .su]
}

/// The schedules the editor offers, and anything else as custom RRULE text.
public enum AutomationSchedulePreset: Hashable, Sendable {
    case every(minutes: Int)
    case daily(hour: Int, minute: Int)
    case weekly(days: Set<AutomationWeekday>, hour: Int, minute: Int)
    case custom(String)

    /// The preset an RRULE is, else `.custom` with the text as written.
    public init(rrule: String) {
        self = Self.preset(rrule) ?? .custom(rrule)
    }

    private static func preset(_ text: String) -> Self? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if body.hasPrefix("RRULE:") { body.removeFirst(6) }
        var parts: [String: String] = [:]
        for part in body.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, parts[pair[0]] == nil else { return nil }
            parts[pair[0]] = pair[1]
        }
        // On the minute is what every preset means (an older editor wrote it out).
        if parts["BYSECOND"] == "0" { parts["BYSECOND"] = nil }
        let interval = parts.removeValue(forKey: "INTERVAL").map { Int($0) } ?? 1
        guard let interval, interval > 0, let freq = parts.removeValue(forKey: "FREQ") else { return nil }
        switch freq {
        case "MINUTELY" where parts.isEmpty: return .every(minutes: interval)
        case "HOURLY" where parts.isEmpty: return .every(minutes: interval * 60)
        case "DAILY", "WEEKLY":
            guard interval == 1, let hour = parts.removeValue(forKey: "BYHOUR").flatMap(Int.init), (0...23).contains(hour),
                  let minute = parts.removeValue(forKey: "BYMINUTE").flatMap(Int.init), (0...59).contains(minute) else { return nil }
            if freq == "DAILY" { return parts.isEmpty ? .daily(hour: hour, minute: minute) : nil }
            guard let days = parts.removeValue(forKey: "BYDAY"), parts.isEmpty else { return nil }
            let set = days.split(separator: ",").map { AutomationWeekday(rawValue: String($0)) }
            guard !set.isEmpty, !set.contains(nil) else { return nil }
            return .weekly(days: Set(set.compactMap { $0 }), hour: hour, minute: minute)
        default: return nil
        }
    }

    /// The RRULE the host saves.
    public var rrule: String {
        switch self {
        case .every(let minutes):
            minutes % 60 == 0 ? "FREQ=HOURLY;INTERVAL=\(minutes / 60)" : "FREQ=MINUTELY;INTERVAL=\(minutes)"
        case .daily(let hour, let minute):
            "FREQ=DAILY;BYHOUR=\(hour);BYMINUTE=\(minute)"
        case .weekly(let days, let hour, let minute):
            "FREQ=WEEKLY;BYDAY=\(AutomationWeekday.allCases.filter(days.contains).map(\.rawValue).joined(separator: ","));BYHOUR=\(hour);BYMINUTE=\(minute)"
        case .custom(let text):
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// "Every 30 min", "Every 2 hours", "Daily at 09:00", "Weekdays at 09:00", "Mon, Thu at 18:30",
    /// "Custom: FREQ=MONTHLY;BYMONTHDAY=1".
    public var summary: String {
        switch self {
        case .every(let minutes):
            if minutes % 60 != 0 { return "Every \(minutes) min" }
            return minutes == 60 ? "Every hour" : "Every \(minutes / 60) hours"
        case .daily(let hour, let minute):
            return "Daily at \(Self.clock(hour, minute))"
        case .weekly(let days, let hour, let minute):
            let at = Self.clock(hour, minute)
            if days.count == 7 { return "Daily at \(at)" }
            if days == AutomationWeekday.weekdays { return "Weekdays at \(at)" }
            if days == AutomationWeekday.weekend { return "Weekends at \(at)" }
            return AutomationWeekday.allCases.filter(days.contains).map(\.short).joined(separator: ", ") + " at \(at)"
        case .custom(let text):
            return "Custom: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    static func clock(_ hour: Int, _ minute: Int) -> String { String(format: "%02d:%02d", hour, minute) }
}

public enum AutomationTriggerText {
    /// What fires a run, nil for a manual automation.
    public static func summary(_ trigger: AutomationTrigger) -> String? {
        switch trigger {
        case .manual: return nil
        case .schedule(let schedule): return AutomationSchedulePreset(rrule: schedule.rrule).summary
        case .github(let triggers):
            guard let first = triggers.first else { return "GitHub" }
            return "GitHub: " + github(first) + (triggers.count > 1 ? " (+\(triggers.count - 1) more)" : "")
        }
    }

    /// "issue labeled shepherd in owner/repo", "#12 PR review or PR comment".
    public static func github(_ trigger: GitHubTrigger) -> String {
        var text = trigger.events.isEmpty ? "no events" : trigger.events.map(\.label).joined(separator: " or ")
        if !trigger.labels.isEmpty {
            let labeled = trigger.events.allSatisfy { $0 == .issueLabeled || $0 == .pullRequestLabeled }
            text += (labeled ? " " : " with ") + trigger.labels.joined(separator: ", ")
        }
        if let number = trigger.number { text = "#\(number) " + text }
        if let repo = trigger.repo, !repo.isEmpty { text += " in \(repo)" }
        return text
    }

    public static func destination(_ destination: AutomationDestination, threadName: String?) -> String {
        switch destination {
        case .newThread: "a new thread each run"
        case .thread: "messages \(threadName ?? "a thread that's gone")"
        }
    }

    public static func workspace(_ workspace: AutomationWorkspace) -> String {
        switch workspace {
        case .worktree: "New worktree"
        case .local: "The folder itself"
        }
    }

    public static func gate(_ gate: AutomationAuthorGate) -> String {
        switch gate {
        case .collaborators: "Collaborators"
        case .contributors: "Contributors"
        case .anyone: "Anyone"
        }
    }

    /// Said under Who can trigger when it is wider than collaborators.
    public static func gateWarning(_ gate: AutomationAuthorGate) -> String? {
        switch gate {
        case .collaborators: nil
        case .contributors: "Anyone with a merged commit can start a run that works in your repo."
        case .anyone: "Anyone who can open an issue can start a run that works in your repo. Their text reaches the agent."
        }
    }

    /// "Default", "claude-sonnet-4 · high", "claude-sonnet-4 · high · Fast".
    public static func model(_ settings: AutomationSettings) -> String {
        let speed = settings.serviceTier.flatMap(ServiceTier.init(rawValue:))?.title
        let parts = [settings.model, settings.thinking, speed].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Default" : parts.joined(separator: " · ")
    }
}

/// How a trigger stands, in a word and the tone that colors it.
public struct AutomationTriggerState: Equatable, Sendable {
    /// "Watching", "Scheduled", "Paused", "Retrying", "Off".
    public var word: String
    public var tone: AutomationTone
    /// Why it's paused or retrying, from the host.
    public var reason: String?
    /// Resume is offered (else Pause).
    public var paused: Bool

    public init(_ status: AutomationTriggerStatus, trigger: AutomationTrigger) {
        switch status.state {
        case .off:
            (word, tone, reason, paused) = ("Off", .off, nil, false)
        case .paused:
            // A lasting error pauses with a reason; a person's pause has none.
            (word, tone, reason, paused) = ("Paused", status.reason == nil ? .stopped : .failed, status.reason, true)
        case .retrying:
            (word, tone, reason, paused) = ("Retrying", .attention, status.reason, false)
        case .active where status.allPaused:
            (word, tone, reason, paused) = ("Paused", .stopped, "Every trigger on this host is paused.", false)
        case .active:
            if case .schedule = trigger { (word, tone, reason, paused) = ("Scheduled", .done, nil, false) }
            else { (word, tone, reason, paused) = ("Watching", .done, nil, false) }
        }
    }
}

/// An event waiting for a free slot (Run now starts it past the caps; Dismiss drops it).
public struct AutomationPendingRow: Identifiable, Equatable, Sendable {
    public var id: String
    /// "#12 Fix login crash · issue labeled shepherd".
    public var summary: String
    public var url: URL?
    /// "Sep 24 02:00".
    public var when: String
}

/// A triggered automation's trigger in its detail.
public struct AutomationTriggerDetail: Equatable, Sendable {
    public var summary: String
    /// Nil until the host's status is read.
    public var state: AutomationTriggerState?
    /// "Today 09:00".
    public var next: String?
    /// "Today 09:12".
    public var checked: String?
    /// "Today 09:20", while retrying.
    public var retry: String?
    /// "3 of 20 runs" (today).
    public var today: String?
    public var pending: [AutomationPendingRow]
    public var allPaused: Bool
    /// The facts under the trigger.
    public var runsOn: String
    public var workspace: String?
    public var gate: String?
    public var gateWarning: String?
    public var limits: String
    public var model: String

    static func of(_ row: AutomationListRow, status: AutomationTriggerStatus?, now: Date, timeZone: TimeZone,
                   locale: Locale) -> AutomationTriggerDetail? {
        let settings = row.settings
        guard let trigger = settings.trigger, let summary = AutomationTriggerText.summary(trigger) else { return nil }
        let day: (Double?) -> String? = { seconds in
            seconds.map { AutomationsModel.dayTime(Date(timeIntervalSince1970: $0), now: now, timeZone: timeZone, locale: locale) }
        }
        let limits = settings.limits ?? .default
        var github = false
        if case .github = trigger { github = true }
        let gate = settings.authorGate ?? .collaborators
        return AutomationTriggerDetail(
            summary: summary, state: status.map { AutomationTriggerState($0, trigger: trigger) },
            next: day(status?.nextRunAt), checked: github ? day(status?.lastCheckedAt) : nil,
            retry: status?.state == .retrying ? day(status?.retryAt) : nil,
            today: status.map { "\($0.runsToday) of \(limits.maxPerDay) runs" },
            pending: (status?.pending ?? []).map { event in
                AutomationPendingRow(id: event.id, summary: event.summary, url: event.url.flatMap(URL.init(string:)),
                                     when: AutomationsModel.stamp(Date(timeIntervalSince1970: event.occurredAt), timeZone: timeZone, locale: locale))
            },
            allPaused: status?.allPaused ?? false,
            runsOn: row.runsOn,
            workspace: settings.destination == .newThread || settings.destination == nil
                ? AutomationTriggerText.workspace(settings.workspace ?? .worktree) : nil,
            gate: github ? AutomationTriggerText.gate(gate) : nil,
            gateWarning: github ? AutomationTriggerText.gateWarning(gate) : nil,
            limits: "\(limits.maxConcurrent) at once · \(limits.maxPerDay) a day",
            model: AutomationTriggerText.model(settings))
    }
}

extension RemoteAutomationRequest {
    /// Only a host with `automationTriggersCapability` takes it: the trigger requests, and a
    /// draft that carries settings (an older host would save the fields and drop the trigger).
    public var needsTriggers: Bool {
        switch self {
        case .status, .pause, .resume, .runEvent, .dismissEvent, .markRead, .setAllPaused: true
        case .create(let draft), .update(let draft): draft.settings != nil
        case .setEnabled, .run, .stop, .runs, .delete: false
        }
    }
}
