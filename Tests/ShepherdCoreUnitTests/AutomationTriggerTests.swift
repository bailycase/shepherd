import Foundation
import Testing
@testable import ShepherdCore

/// Triggers as saved records: RRULE parsing and next-run math, validation bounds, and JSON that
/// older records and older clients read without losing anything.
@Suite("Automation triggers")
struct AutomationTriggerTests {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @Test(arguments: [
        // Weekdays at 09:00, from a Saturday: next is Monday.
        ("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0", "2026-10-31T10:00:00Z", "2026-11-02T09:00:00Z"),
        ("RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=30", "2026-10-30T09:31:00Z", "2026-10-31T09:30:00Z"),
        // Last Friday of the month (RFC 5545 ordinal weekday).
        ("FREQ=MONTHLY;BYDAY=-1FR;BYHOUR=17;BYMINUTE=0", "2026-10-01T00:00:00Z", "2026-10-30T17:00:00Z"),
        // First of each month (Codex's RRULE example).
        ("FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9;BYMINUTE=0", "2026-10-15T00:00:00Z", "2026-11-01T09:00:00Z"),
        // Every 30 minutes anchored at start.
        ("FREQ=MINUTELY;INTERVAL=30", "2026-10-30T10:10:00Z", "2026-10-30T10:30:00Z"),
    ])
    func nextRun(rrule: String, after: String, expected: String) throws {
        let schedule = AutomationSchedule(rrule: rrule, start: Self.date("2026-10-01T00:00:00Z").timeIntervalSince1970)
        #expect(schedule.next(after: Self.date(after), calendar: Self.utc) == Self.date(expected))
    }

    @Test func countAndUntilEndTheSchedule() {
        let start = Self.date("2026-10-01T09:00:00Z").timeIntervalSince1970
        let counted = AutomationSchedule(rrule: "FREQ=DAILY;COUNT=2", start: start)
        #expect(counted.next(after: Self.date("2026-10-01T10:00:00Z"), calendar: Self.utc) == Self.date("2026-10-02T09:00:00Z"))
        #expect(counted.next(after: Self.date("2026-10-02T10:00:00Z"), calendar: Self.utc) == nil)
        let until = AutomationSchedule(rrule: "FREQ=DAILY;UNTIL=20261003T000000Z", start: start)
        #expect(until.next(after: Self.date("2026-10-03T10:00:00Z"), calendar: Self.utc) == nil)
    }

    @Test(arguments: [
        ("FREQ=SECONDLY", "isn't supported"),
        ("BYHOUR=9", "needs FREQ"),
        ("FREQ=DAILY;BYHOUR=25", "out of range"),
        ("FREQ=DAILY;COUNT=2;UNTIL=20270101", "both COUNT and UNTIL"),
        ("FREQ=DAILY;BYDAY=XX", "isn't a weekday"),
        ("FREQ=DAILY;FOO=1", "FOO isn't supported"),
        ("FREQ=MINUTELY;INTERVAL=1", "5 minutes apart"),
        ("FREQ=HOURLY;BYMINUTE=0,2", "5 minutes apart"),
    ])
    func refusesWhatItCannotRunSafely(rrule: String, message: String) throws {
        let error = try #require(AutomationTrigger.schedule(AutomationSchedule(rrule: rrule)).validationError(calendar: Self.utc))
        #expect(error.contains(message))
    }

    @Test func githubTriggerBounds() {
        #expect(AutomationTrigger.github([]).validationError() != nil)
        let one = GitHubTrigger(repo: "acme/app", events: [.issueLabeled], labels: ["shepherd"])
        #expect(AutomationTrigger.github([one]).validationError() == nil)
        #expect(AutomationTrigger.github(Array(repeating: one, count: 6)).validationError() != nil)
        #expect(AutomationTrigger.github([GitHubTrigger(events: [])]).validationError() != nil)
        #expect(AutomationTrigger.github([GitHubTrigger(repo: "no-slash", events: [.issueOpened])]).validationError() != nil)
    }

    @Test func authorGate() {
        #expect(AutomationAuthorGate.collaborators.admits("MEMBER"))
        #expect(!AutomationAuthorGate.collaborators.admits("CONTRIBUTOR"))
        #expect(!AutomationAuthorGate.collaborators.admits("NONE"))
        #expect(AutomationAuthorGate.contributors.admits("CONTRIBUTOR"))
        #expect(!AutomationAuthorGate.contributors.admits("FIRST_TIME_CONTRIBUTOR"))
        #expect(AutomationAuthorGate.anyone.admits("NONE"))
    }

    /// A record saved before triggers reads as a manual automation, and a manual one writes the
    /// same JSON as before, so older Shepherds read it unchanged.
    @Test func olderRecordsReadAsManual() throws {
        let json = #"{"id":"a","name":"n","prompt":"p","cwd":"/tmp","enabled":true}"#
        let automation = try JSONDecoder().decode(Automation.self, from: Data(json.utf8))
        #expect(automation.trigger == .manual && automation.limits == .default && automation.destination == .newThread)
        let written = String(decoding: try JSONEncoder().encode(automation), as: UTF8.self)
        #expect(!written.contains("trigger") && !written.contains("limits"))
    }

    @Test func triggeredRecordsRoundTrip() throws {
        let automation = Automation(
            name: "loop", prompt: "speckit it", cwd: "/tmp",
            trigger: .github([GitHubTrigger(repo: "acme/app", events: [.issueLabeled, .pullRequestReview], labels: ["shepherd"])]),
            destination: .thread(AgentID(rawValue: "t")), workspace: .local, authorGate: .anyone,
            limits: AutomationLimits(maxConcurrent: 3, maxPerDay: 9), model: "m", thinking: .high, serviceTier: .fast)
        let decoded = try JSONDecoder().decode(Automation.self, from: JSONEncoder().encode(automation))
        #expect(decoded == automation)
        let schedule = Automation(name: "s", prompt: "p", cwd: "/", trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY", start: 5)))
        #expect(try JSONDecoder().decode(Automation.self, from: JSONEncoder().encode(schedule)) == schedule)
    }

    /// A newer Shepherd's gate value this build doesn't know closes the gate rather than widening it.
    @Test func unknownGateCloses() throws {
        let gate = try JSONDecoder().decode(AutomationAuthorGate.self, from: Data(#""maintainers""#.utf8))
        #expect(gate == .collaborators)
    }

    /// Settings patches keep what they don't name, clear pins with "", and refuse bad values
    /// without touching the automation.
    @Test func settingsPatch() throws {
        var automation = Automation(name: "n", prompt: "p", cwd: "/tmp", model: "pinned")
        try AutomationSettings(trigger: .schedule(AutomationSchedule(rrule: "FREQ=HOURLY"))).apply(to: &automation)
        #expect(automation.model == "pinned" && automation.isTriggered)
        try AutomationSettings(model: "").apply(to: &automation)
        #expect(automation.model == nil)
        let before = automation
        #expect(throws: AutomationSettingsError.self) {
            try AutomationSettings(limits: AutomationLimits(maxConcurrent: 0, maxPerDay: 5)).apply(to: &automation)
        }
        #expect(throws: AutomationSettingsError.self) {
            try AutomationSettings(trigger: .manual, destination: .thread(AgentID(rawValue: "x"))).apply(to: &automation)
        }
        #expect(automation == before)
        // Every setting survives the round trip through a full patch.
        var copy = Automation(name: "n", prompt: "p", cwd: "/tmp")
        try AutomationSettings(of: before).apply(to: &copy)
        #expect(copy.trigger == before.trigger && copy.model == before.model)
    }

    @Test func eventSummary() {
        let labeled = AutomationEvent(id: "a/b#12:labeled:x", kind: .issueLabeled, repo: "a/b", number: 12,
                                      title: "Fix login crash", detail: "shepherd", occurredAt: 0)
        #expect(labeled.summary == "#12 Fix login crash · issue labeled shepherd")
        let body = String(repeating: "x", count: AutomationEvent.bodyLimit + 10)
        #expect(AutomationEvent(id: "e", title: "t", body: body, occurredAt: 0).body?.count == AutomationEvent.bodyLimit)
    }
}
