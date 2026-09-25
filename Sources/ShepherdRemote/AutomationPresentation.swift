import Foundation
import ShepherdCore
import ShepherdProtocol

// A host's automations as a client shows them (the iPhone and iPad Automations screens, the
// Mac's remote sidebar): plain values derived once per change from each host's pushed state and
// the runs it kept (`RemoteAutomationRequest.runs`). What a row offers follows what the host can
// take: a host without `automationsCapability`, or one that is offline, shows them read-only.

/// One automation on one host.
public struct AutomationKey: Hashable, Codable, Sendable {
    public var host: UUID
    public var automation: AutomationID

    public init(host: UUID, automation: AutomationID) {
        self.host = host
        self.automation = automation
    }
}

/// A host as the Automations screens read it.
public struct AutomationHost: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var connected: Bool
    /// It serves `RemoteRequest.automation` (`automationsCapability`).
    public var manageable: Bool
    public var state: ShepherdState

    public init(id: UUID, name: String, connected: Bool, manageable: Bool, state: ShepherdState) {
        self.id = id
        self.name = name
        self.connected = connected
        self.manageable = manageable
        self.state = state
    }
}

/// What can be done with an automation from here, and why not when nothing can.
public struct AutomationAbilities: Equatable, Sendable {
    public var toggle: Bool
    public var run: Bool
    public var stop: Bool
    public var edit: Bool
    /// Why the automation is read-only here ("Host offline"), nil when it is not.
    public var readOnlyReason: String?

    public static let none = AutomationAbilities(toggle: false, run: false, stop: false, edit: false, readOnlyReason: nil)

    public init(toggle: Bool, run: Bool, stop: Bool, edit: Bool, readOnlyReason: String?) {
        self.toggle = toggle
        self.run = run
        self.stop = stop
        self.edit = edit
        self.readOnlyReason = readOnlyReason
    }

    public init(host: AutomationHost, running: Bool) {
        let can = host.connected && host.manageable
        self.init(toggle: can, run: can && !running, stop: can && running, edit: can,
                  readOnlyReason: !host.connected ? "Host offline"
                      : host.manageable ? nil : "Update Shepherd on \(host.name) to manage its automations from here.")
    }
}

/// How a run or an automation reads: a word and the state that colors it.
public enum AutomationTone: Equatable, Sendable {
    case running, attention, done, stopped, failed, off
}

/// One run in a history list or chart.
public struct AutomationRunRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// "Sep 24 02:00"; "Today 02:00" in the last-run card.
    public var started: String
    public var startedAt: Date
    /// "finished", "asked you", "running", "stopped", "interrupted".
    public var word: String
    public var tone: AutomationTone
    /// How long it took ("43s", "4m"); nil while it runs.
    public var duration: String?
    public var seconds: Double?
    /// Its agent, while it still exists on the host: the run opens as that thread.
    public var agent: FleetRef?
}

/// A bar of the runs chart: its height as a share of the longest run shown (0...1).
public struct AutomationRunBar: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var height: Double
    public var tone: AutomationTone
    /// "Sep 24 02:00, finished, 43s", for VoiceOver.
    public var label: String
}

/// An automation's row: its name, when it runs and where, and how its last run went.
public struct AutomationListRow: Identifiable, Equatable, Sendable {
    public var id: AutomationKey { key }
    public var key: AutomationKey
    public var name: String
    public var prompt: String
    /// "When Shepherd starts" while it is on, else "By hand".
    public var when: String
    /// The working directory's last component ("Shepherd").
    public var place: String
    public var cwd: String
    public var enabled: Bool
    /// "Running", "Asked you", "Finished", "Stopped", "Interrupted", "Not run yet"; "On" or "Off"
    /// while its runs are not read.
    public var status: String
    public var tone: AutomationTone
    /// A live run counts up from here; an ended one says how long ago it moved.
    public var clock: Clock?
    /// Its current run's agent: the row opens it.
    public var run: FleetRef?
    public var hostName: String
    /// The host's name, when more than one host is known.
    public var hostTag: String?
    public var offline: Bool
    public var abilities: AutomationAbilities

    public enum Clock: Equatable, Sendable {
        case elapsed(since: Date)
        case ago(Date)
    }

    /// Its run is working or waiting on you.
    public var live: Bool { tone == .running || tone == .attention }
}

/// An automation opened on its own (the detail): its row, the runs the host kept, newest first,
/// the chart of the latest, and the last run.
public struct AutomationDetail: Equatable, Sendable {
    public var row: AutomationListRow
    /// Newest first.
    public var runs: [AutomationRunRow]
    /// Oldest first, the latest `chartLimit`.
    public var bars: [AutomationRunBar]
    /// "stopped: 1 · asked: 1", what went other than finished among the bars; nil when all finished.
    public var chartSummary: String?
    /// When the first and the last charted runs started, under the chart's ends.
    public var chartStart: String?
    public var chartEnd: String?
    public var lastRun: AutomationRunRow?
    /// The runs have been read from the host (else they are still loading, or unavailable).
    public var runsKnown: Bool

    public static let chartLimit = 14
}

/// Every host's automations, derived once per change.
public struct AutomationsModel: Equatable, Sendable {
    /// Every automation, host by host, in each host's order.
    public var rows: [AutomationListRow] = []
    public var live: [AutomationListRow] = []
    public var quiet: [AutomationListRow] = []

    public init() {}

    /// `runs` are each automation's runs as the host sent them, oldest first (absent while
    /// they have not been read).
    public init(hosts: [AutomationHost], runs: [AutomationKey: [AutomationRun]]) {
        let tags = hosts.count > 1
        for host in hosts {
            let agents = Dictionary(host.state.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for automation in host.state.automations {
                let key = AutomationKey(host: host.id, automation: automation.id)
                rows.append(Self.row(automation, key: key, host: host, agent: automation.agentID.flatMap { agents[$0] },
                                     runs: runs[key], tag: tags ? host.name : nil))
            }
        }
        live = rows.filter(\.live)
        quiet = rows.filter { !$0.live }
    }

    public func row(_ key: AutomationKey) -> AutomationListRow? {
        rows.first { $0.key == key }
    }

    static func row(_ automation: Automation, key: AutomationKey, host: AutomationHost, agent: Agent?,
                    runs: [AutomationRun]?, tag: String?) -> AutomationListRow {
        let current = agent.flatMap { agent in runs?.last(where: { $0.agentID == agent.id }) }
        let last = runs?.last
        var status: String
        var tone: AutomationTone
        var clock: AutomationListRow.Clock?
        if let agent {
            switch agent.status {
            case .working, .idle where current?.settledAt == nil:
                (status, tone) = ("Running", .running)
                clock = current.map { .elapsed(since: Date(timeIntervalSince1970: $0.startedAt)) }
            case .blocked:
                (status, tone) = ("Asked you", .attention)
            default:
                (status, tone) = ("Finished", .done)
                clock = current.flatMap { $0.settledAt }.map { .ago(Date(timeIntervalSince1970: $0)) }
            }
        } else if let last {
            (status, tone) = (Self.word(last.result).capitalizedFirst, Self.tone(last.result))
            clock = (last.endedAt ?? last.settledAt).map { .ago(Date(timeIntervalSince1970: $0)) }
        } else if runs != nil {
            (status, tone) = automation.enabled ? ("Not run yet", .stopped) : ("Off", .off)
        } else {
            // Its runs are not read yet: say only whether it starts with Shepherd.
            (status, tone) = automation.enabled ? ("On", .stopped) : ("Off", .off)
        }
        if !automation.enabled, agent == nil, runs?.isEmpty == false {
            status = "Off · " + status.lowercasedFirst
        }
        if !host.connected {
            (status, tone, clock) = ("Host offline", .off, nil)
        }
        return AutomationListRow(
            key: key, name: automation.name, prompt: automation.prompt,
            when: automation.enabled ? "When Shepherd starts" : "By hand",
            place: Self.lastComponent(automation.cwd), cwd: automation.cwd, enabled: automation.enabled,
            status: status, tone: tone, clock: clock,
            run: agent.map { FleetRef(host: host.id, agent: $0.id) }, hostName: host.name, hostTag: tag,
            offline: !host.connected, abilities: AutomationAbilities(host: host, running: agent != nil))
    }

    /// The detail of one automation; nil once it is gone from its host. `now`, `timeZone` and
    /// `locale` word the dates (tests fix them).
    public func detail(_ key: AutomationKey, runs: [AutomationRun]?, now: Date = Date(), timeZone: TimeZone = .current,
                       locale: Locale = .current) -> AutomationDetail? {
        guard let row = row(key) else { return nil }
        let rows = (runs ?? []).reversed().map { Self.runRow($0, host: key.host, timeZone: timeZone, locale: locale) }
        let charted = Array((runs ?? []).suffix(AutomationDetail.chartLimit))
        let longest = charted.compactMap(\.duration).max() ?? 0
        let bars = charted.map { run in
            let row = Self.runRow(run, host: key.host, timeZone: timeZone, locale: locale)
            // A run still going, or one too short to measure, draws as a stub.
            let height = longest > 0 ? max(Self.minimumBar, (run.duration ?? 0) / longest) : Self.minimumBar
            return AutomationRunBar(id: run.id, height: height, tone: row.tone,
                                    label: [row.started, row.word, row.duration].compactMap { $0 }.joined(separator: ", "))
        }
        var counts: [(String, Int)] = []
        for (result, word) in [(AutomationRunResult.stopped, "stopped"), (.interrupted, "interrupted"), (.needsYou, "asked")] {
            let count = charted.filter { $0.result == result }.count
            if count > 0 { counts.append((word, count)) }
        }
        var last = rows.first
        if let run = runs?.last { last?.started = Self.dayTime(Date(timeIntervalSince1970: run.startedAt), now: now, timeZone: timeZone, locale: locale) }
        return AutomationDetail(row: row, runs: rows, bars: bars,
                                chartSummary: counts.isEmpty ? nil : counts.map { "\($0.0): \($0.1)" }.joined(separator: " · "),
                                chartStart: charted.first.map { Self.stamp(Date(timeIntervalSince1970: $0.startedAt), timeZone: timeZone, locale: locale) },
                                chartEnd: charted.last.map { Self.stamp(Date(timeIntervalSince1970: $0.startedAt), timeZone: timeZone, locale: locale) },
                                lastRun: last, runsKnown: runs != nil)
    }

    static let minimumBar = 0.08

    static func runRow(_ run: AutomationRun, host: UUID, timeZone: TimeZone, locale: Locale) -> AutomationRunRow {
        let started = Date(timeIntervalSince1970: run.startedAt)
        return AutomationRunRow(id: run.id, started: Self.stamp(started, timeZone: timeZone, locale: locale), startedAt: started,
                                word: word(run.result), tone: tone(run.result),
                                duration: run.duration.map(Self.duration), seconds: run.duration,
                                agent: run.agentID.map { FleetRef(host: host, agent: $0) })
    }

    public static func word(_ result: AutomationRunResult) -> String {
        switch result {
        case .running: "running"
        case .needsYou: "asked you"
        case .finished: "finished"
        case .stopped: "stopped"
        case .interrupted: "interrupted"
        }
    }

    public static func tone(_ result: AutomationRunResult) -> AutomationTone {
        switch result {
        case .running: .running
        case .needsYou: .attention
        case .finished: .done
        case .stopped: .stopped
        case .interrupted: .failed
        }
    }

    /// "Sep 24 02:00".
    static func stamp(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        let calendar = gregorian(timeZone)
        let parts = calendar.dateComponents([.month, .day], from: date)
        let formatter = DateFormatter()
        formatter.locale = locale
        let month = formatter.shortMonthSymbols[(parts.month ?? 1) - 1]
        return "\(month) \(parts.day ?? 1) \(clock(date, timeZone: timeZone))"
    }

    /// "Today 02:00", "Yesterday 02:00", else the stamp.
    static func dayTime(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        let calendar = gregorian(timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return "Today " + clock(date, timeZone: timeZone) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday " + clock(date, timeZone: timeZone)
        }
        return stamp(date, timeZone: timeZone, locale: locale)
    }

    /// "02:00", on a 24-hour clock like the boards.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let parts = gregorian(timeZone).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "43s", "4m", "1h 5m".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

fileprivate extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
