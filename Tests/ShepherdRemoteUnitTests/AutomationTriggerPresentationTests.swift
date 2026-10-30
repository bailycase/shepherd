import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Automation triggers on a client")
struct AutomationTriggerPresentationTests {
    typealias T = AutomationPresentationTests
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = T.utc
        return calendar
    }

    static func triggered(_ trigger: AutomationTrigger, destination: AutomationDestination = .newThread) -> Automation {
        var automation = T.automation("a")
        automation.trigger = trigger
        automation.destination = destination
        return automation
    }

    // MARK: Summaries

    @Test(arguments: [
        ("FREQ=MINUTELY;INTERVAL=30", "Every 30 min"),
        ("FREQ=HOURLY;INTERVAL=1", "Every hour"),
        ("FREQ=HOURLY;INTERVAL=2", "Every 2 hours"),
        ("FREQ=DAILY;BYHOUR=9;BYMINUTE=0", "Daily at 09:00"),
        ("RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9;BYMINUTE=0", "Weekdays at 09:00"),
        ("FREQ=WEEKLY;BYDAY=SU,SA;BYHOUR=10;BYMINUTE=30", "Weekends at 10:30"),
        ("FREQ=WEEKLY;BYDAY=TH,MO;BYHOUR=18;BYMINUTE=5", "Mon, Thu at 18:05"),
        ("FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9", "Custom: FREQ=MONTHLY;BYMONTHDAY=1;BYHOUR=9"),
        ("FREQ=DAILY;INTERVAL=2;BYHOUR=9;BYMINUTE=0", "Custom: FREQ=DAILY;INTERVAL=2;BYHOUR=9;BYMINUTE=0"),
    ])
    func schedulesReadAsTheirPreset(_ rrule: String, _ summary: String) {
        #expect(AutomationTriggerText.summary(.schedule(AutomationSchedule(rrule: rrule))) == summary)
    }

    @Test(arguments: [
        AutomationSchedulePreset.every(minutes: 15), .every(minutes: 120), .daily(hour: 7, minute: 45),
        .weekly(days: [.we, .mo], hour: 9, minute: 0),
    ])
    func presetsRoundTripThroughTheirRule(_ preset: AutomationSchedulePreset) {
        #expect(AutomationSchedulePreset(rrule: preset.rrule) == preset)
        #expect((try? RRule.parse(preset.rrule)) != nil)
    }

    @Test func gitHubSummariesNameTheEventFiltersAndRepo() {
        let one = GitHubTrigger(repo: "owner/repo", events: [.issueLabeled], labels: ["shepherd"])
        #expect(AutomationTriggerText.summary(.github([one])) == "GitHub: issue labeled shepherd in owner/repo")
        let two = GitHubTrigger(events: [.pullRequestReview, .pullRequestComment], labels: ["bot"], number: 12)
        #expect(AutomationTriggerText.summary(.github([two, one])) == "GitHub: #12 PR review or PR comment with bot (+1 more)")
        #expect(AutomationTriggerText.summary(.manual) == nil)
    }

    // MARK: Rows and detail

    @Test func aTriggeredRowSaysWhatFiresItAndCountsUnread() throws {
        let automation = Self.triggered(.schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0")))
        var unread = T.run(0, .finished, took: 40, agent: "r1", id: 1)
        unread.unread = true
        let live = T.run(100, .running, agent: "r2", id: 2)
        let model = AutomationsModel(hosts: [T.host([automation], agents: [("r1", .done), ("r2", .working)])],
                                     runs: [T.key("a"): [unread, live]])
        let row = try #require(model.rows.first)
        #expect(row.triggered && row.when == "Daily at 09:00" && row.unread == 1)
        #expect(row.status == "Running" && row.tone == .running && row.run == nil)
        #expect(row.abilities.run && !row.abilities.stop)
        #expect(row.runsOn == "Studio · a new thread each run")
        // Its row, not a Running now card, says how its runs go.
        #expect(model.live.isEmpty && model.quiet.map(\.key) == [T.key("a")])
    }

    @Test(arguments: [
        (AutomationTriggerStatus.State.paused, Optional("GitHub sign-in expired"), "Paused", AutomationTone.failed, true),
        (.paused, nil, "Paused", .stopped, true),
        (.retrying, "Rate limited", "Retrying", .attention, false),
        (.active, nil, "Watching", .done, false),
        (.off, nil, "Off", .off, false),
    ])
    func triggerStatesReadAsAWordAndTone(_ state: AutomationTriggerStatus.State, _ reason: String?, _ word: String,
                                         _ tone: AutomationTone, _ paused: Bool) {
        let words = AutomationTriggerState(AutomationTriggerStatus(state: state, reason: reason),
                                           trigger: .github([GitHubTrigger(events: [.issueOpened])]))
        #expect(words.word == word && words.tone == tone && words.reason == reason && words.paused == paused)
    }

    @Test func aPausedTriggerShowsOnTheRowAndItsDetailListsPending() throws {
        let automation = Self.triggered(.github([GitHubTrigger(repo: "o/r", events: [.issueLabeled], labels: ["shepherd"])]))
        let event = AutomationEvent(id: "e1", kind: .issueLabeled, repo: "o/r", number: 12, title: "Fix login crash",
                                    url: "https://github.com/o/r/issues/12", detail: "shepherd", occurredAt: T.t0)
        let status = AutomationTriggerStatus(state: .paused, reason: "Daily limit reached", pending: [event],
                                             lastCheckedAt: T.t0, runsToday: 20)
        let model = AutomationsModel(hosts: [T.host([automation])], runs: [T.key("a"): []], statuses: [T.key("a"): status])
        let row = try #require(model.rows.first)
        #expect(row.status == "Paused" && row.tone == .failed)
        let detail = try #require(model.detail(T.key("a"), runs: [], status: status, now: Date(timeIntervalSince1970: T.t0 + 60),
                                               timeZone: T.utc, locale: T.posix)?.trigger)
        #expect(detail.state?.reason == "Daily limit reached" && detail.state?.paused == true)
        #expect(detail.today == "20 of 20 runs" && detail.checked == "Today 02:00")
        #expect(detail.pending == [AutomationPendingRow(id: "e1", summary: "#12 Fix login crash · issue labeled shepherd",
                                                        url: URL(string: "https://github.com/o/r/issues/12"), when: "Sep 24 02:00")])
        #expect(detail.gate == "Collaborators" && detail.gateWarning == nil && detail.workspace == "New worktree")
        #expect(detail.limits == "2 at once · 20 a day" && detail.model == "Default")
    }

    @Test func runRowsCarryTheirTriggerPullRequestAndFailure() throws {
        let automation = Self.triggered(.github([GitHubTrigger(events: [.issueOpened])]))
        let run = AutomationRun(startedAt: T.t0, endedAt: T.t0 + 1, result: .failed, trigger: "#3 Crash · issue opened",
                                triggerURL: "https://github.com/o/r/issues/3", pullRequestURL: "https://github.com/o/r/pull/4",
                                unread: true, failure: "Worktree couldn't be made")
        let model = AutomationsModel(hosts: [T.host([automation])], runs: [T.key("a"): [run]])
        let row = try #require(model.detail(T.key("a"), runs: [run], timeZone: T.utc, locale: T.posix)?.runs.first)
        #expect(row.word == "didn't start" && row.tone == .failed && row.unread)
        #expect(row.trigger == "#3 Crash · issue opened" && row.failure == "Worktree couldn't be made")
        #expect(row.pullRequestURL == URL(string: "https://github.com/o/r/pull/4"))
    }

    // MARK: Form

    @Test func theFormRoundTripsSavedSettings() {
        var automation = Self.triggered(.github([GitHubTrigger(repo: "o/r", events: [.issueLabeled, .pullRequestLabeled],
                                                               labels: ["a", "b"], authors: ["me"], titleContains: "crash", number: 7)]),
                                        destination: .thread(AgentID(rawValue: "t")))
        automation.workspace = .local
        automation.authorGate = .anyone
        automation.limits = AutomationLimits(maxConcurrent: 3, maxPerDay: 40)
        automation.model = "m"
        automation.thinking = .high
        automation.serviceTier = .fast
        let settings = AutomationSettings(of: automation)
        #expect(AutomationTriggerForm(settings).settings == settings)
    }

    @Test func theFormChecksWhatTheHostWouldRefuse() {
        var form = AutomationTriggerForm()
        form.kind = .schedule
        form.scheduleKind = .every
        form.everyMinutes = 2
        #expect(form.check(calendar: Self.utcCalendar).error == "Runs must be at least 5 minutes apart.")
        form.scheduleKind = .custom
        form.custom = "FREQ=FORTNIGHTLY"
        #expect(form.check(calendar: Self.utcCalendar).error?.contains("FORTNIGHTLY") == true)
        form.scheduleKind = .weekly
        form.days = []
        #expect(form.check(calendar: Self.utcCalendar).error == "Choose at least one day.")
        form.kind = .github
        form.github[0].number = "twelve"
        #expect(form.check(calendar: Self.utcCalendar).error == "Number must be a whole number, like 12.")
        form.github[0].number = "12"
        form.github[0].events = []
        #expect(form.check(calendar: Self.utcCalendar).error == "A GitHub trigger needs at least one event.")
        form.kind = .manual
        form.maxPerDay = 0
        #expect(form.check(calendar: Self.utcCalendar).error == "Runs a day must be 1 to 200.")
    }

    @Test func theFormPreviewsTheNextRun() {
        var form = AutomationTriggerForm()
        form.kind = .schedule
        form.scheduleKind = .daily
        form.hour = 9
        form.minute = 0
        // 02:00 UTC: today's 09:00 is next.
        let check = form.check(now: Date(timeIntervalSince1970: T.t0), calendar: Self.utcCalendar, locale: T.posix)
        #expect(check == AutomationTriggerForm.Check(next: "Today 09:00"))
        #expect(form.settings.destination == .newThread)
    }

    @Test func triggerRequestsNeedTheCapability() {
        #expect(RemoteAutomationRequest.status.needsTriggers && RemoteAutomationRequest.markRead(runID: UUID()).needsTriggers)
        #expect(!RemoteAutomationRequest.update(draft: RemoteAutomationDraft(name: "a", prompt: "b", cwd: "/", enabled: true)).needsTriggers)
        #expect(RemoteAutomationRequest.update(draft: RemoteAutomationDraft(name: "a", prompt: "b", cwd: "/", enabled: true,
                                                                            settings: AutomationSettings())).needsTriggers)
    }
}
