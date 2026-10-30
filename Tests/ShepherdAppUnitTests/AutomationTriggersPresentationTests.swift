import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The Mac's automation triggers as drawn: the editor's form (presets to RRULE and back, what
/// blocks a save, the settings it sends), the line under a triggered automation's name, the
/// sidebar's Automations badge, and run threads folded under their automation in the space tree.
@Suite("Automation triggers presentation")
@MainActor
struct AutomationTriggersPresentationTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
    /// Wed Sep 24 2025 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_758_700_800)

    // MARK: Form

    @Test func presetsRoundTripThroughTheirRRule() {
        let presets: [MacSchedulePreset] = [
            .everyMinutes(15), .daily(hour: 9, minute: 30), .weekly(weekdays: [2, 4], hour: 9, minute: 0),
        ]
        for preset in presets {
            #expect(MacSchedulePreset(rrule: preset.rrule) == preset)
            #expect(MacSchedulePreset(rrule: "RRULE:" + preset.rrule.lowercased()) == preset)
        }
        #expect(MacSchedulePreset(rrule: "FREQ=WEEKLY;BYDAY=MO,TH;BYHOUR=9;BYMINUTE=0").summary == "Mon, Thu at 09:00")
        #expect(MacSchedulePreset(rrule: "FREQ=MONTHLY;BYMONTHDAY=1") == .custom("FREQ=MONTHLY;BYMONTHDAY=1"))
        #expect(MacSchedulePreset.daily(hour: 9, minute: 5).summary == "Daily at 09:05")
    }

    @Test func formBlocksWhatTheHostWouldRefuse() {
        var form = MacTriggerForm()
        #expect(form.validationError(now: now, calendar: calendar) == nil)
        form.kind = .schedule
        form.preset = .weekly
        form.weekdays = []
        #expect(form.validationError(now: now, calendar: calendar) == "Pick at least one day.")
        form.preset = .custom
        form.customRRule = "FREQ=MINUTELY"
        #expect(form.validationError(now: now, calendar: calendar) == "Runs must be at least 5 minutes apart.")
        form.customRRule = "FREQ=SOMETIMES"
        #expect(form.validationError(now: now, calendar: calendar)?.contains("isn't supported") == true)
        form.kind = .github
        form.github[0].events = []
        #expect(form.validationError(now: now, calendar: calendar) == "A GitHub trigger needs at least one event.")
        form.github[0].events = [.pullRequestOpened]
        form.github[0].number = "12a"
        #expect(form.validationError(now: now, calendar: calendar) == "Trigger 1: the number must be a whole number.")
        form.github[0].number = "#12"
        #expect(form.validationError(now: now, calendar: calendar) == nil)
        form.kind = .manual
        form.thread = AgentID()
        #expect(form.validationError(now: now, calendar: calendar) != nil)
    }

    @Test func formSendsEverySettingAndShowsTheNextRun() throws {
        var form = MacTriggerForm()
        form.kind = .schedule
        form.preset = .daily
        form.hour = 9
        form.minute = 0
        form.workspace = .local
        form.maxConcurrent = 3
        form.model = "gpt-5"
        let next = try #require(form.nextRun(after: now, calendar: calendar))
        #expect(next == now.addingTimeInterval(3600))
        var automation = Automation(name: "nightly", prompt: "p", cwd: "/tmp")
        try form.settings.apply(to: &automation)
        #expect(automation.trigger == .schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0")))
        #expect(automation.workspace == .local && automation.limits.maxConcurrent == 3 && automation.model == "gpt-5")
        #expect(automation.thinking == nil)
        // Read back, the form is what was saved, and an unchanged schedule keeps its anchor.
        automation.trigger = .schedule(AutomationSchedule(rrule: form.schedulePreset.rrule, start: 42))
        let reread = MacTriggerForm(automation)
        #expect(reread.preset == .daily && reread.hour == 9 && reread.workspace == .local)
        #expect(reread.schedule.start == 42)
    }

    @Test func githubFieldsBecomeATrigger() {
        var field = GitHubTriggerForm()
        field.repo = " acme/app "
        field.events = [.pullRequestOpened, .issueLabeled]
        field.labels = "shepherd, , bug"
        field.authors = "@octocat"
        let trigger = field.trigger
        #expect(trigger.repo == "acme/app")
        #expect(trigger.events == [.issueLabeled, .pullRequestOpened])
        #expect(trigger.labels == ["shepherd", "bug"])
        #expect(trigger.authors == ["octocat"])
        #expect(trigger.titleContains == nil && trigger.number == nil)
        #expect(GitHubTriggerForm(trigger).trigger == trigger)
    }

    // MARK: Page

    private func note(_ status: AutomationTriggerStatus?, trigger: AutomationTrigger = .github([GitHubTrigger(events: [.issueOpened])]),
                      allPaused: Bool = false) -> (String, AgentState?)? {
        let automation = Automation(name: "a", prompt: "p", cwd: "/tmp", trigger: trigger)
        return AutomationsPageModel.note(automation, status: status, allPaused: allPaused, now: now, timeZone: utc, locale: locale)
    }

    @Test func theNoteSaysWhyATriggerIsntWatchingElseWhatComesNext() {
        #expect(note(nil) == nil)
        #expect(note(AutomationTriggerStatus(state: .active), trigger: .manual) == nil)
        let event = AutomationEvent(id: "e", title: "t", occurredAt: 0)
        let active = note(AutomationTriggerStatus(state: .active, pending: [event, event], nextRunAt: now.timeIntervalSince1970 + 3600,
                                                  runsToday: 4))
        #expect(active?.0 == "2 waiting · Next run 09:00 · 4/20 today")
        #expect(active?.1 == nil)
        let failing = note(AutomationTriggerStatus(state: .paused, reason: "gh isn't signed in"))
        #expect(failing?.0 == "Paused · gh isn't signed in" && failing?.1 == .failed)
        #expect(note(AutomationTriggerStatus(state: .paused))?.0 == "Paused")
        let retrying = note(AutomationTriggerStatus(state: .retrying, reason: "rate limited", retryAt: now.timeIntervalSince1970 + 600))
        #expect(retrying?.0 == "Retrying at 08:10 · rate limited" && retrying?.1 == .attention)
        #expect(note(AutomationTriggerStatus(state: .active), allPaused: true)?.0 == "Paused · all triggers")
        #expect(AutomationsPageModel.when(now.addingTimeInterval(86_400), now: now, timeZone: utc, locale: locale) == "tomorrow 08:00")
    }

    @Test func aTriggeredDetailIsAnInbox() throws {
        var automation = Automation(name: "pr-loop", prompt: "fix it", cwd: "/tmp",
                                    trigger: .github([GitHubTrigger(repo: "acme/app", events: [.issueLabeled], labels: ["shepherd"])]))
        automation.limits = AutomationLimits(maxConcurrent: 2, maxPerDay: 20)
        let key = AutomationKey(host: PageHost.localID, automation: automation.id)
        let host = AutomationHost(id: PageHost.localID, name: PageHost.localName, connected: true, manageable: true,
                                  state: ShepherdState(automations: [automation]))
        let runs = [AutomationRun(startedAt: now.timeIntervalSince1970 - 600, settledAt: now.timeIntervalSince1970 - 300,
                                  result: .finished, trigger: "#12 Fix login crash · issue labeled shepherd",
                                  pullRequestURL: "https://github.com/acme/app/pull/13", unread: true),
                    AutomationRun(startedAt: now.timeIntervalSince1970 - 60, endedAt: now.timeIntervalSince1970 - 60, result: .failed,
                                  failure: "Not a git repository")]
        let pending = AutomationEvent(id: "e1", kind: .issueLabeled, repo: "acme/app", number: 14, title: "Crash", detail: "shepherd",
                                      occurredAt: now.timeIntervalSince1970 - 720)
        let status = AutomationTriggerStatus(state: .paused, reason: "gh isn't signed in", pending: [pending], runsToday: 2)
        let model = AutomationsPageModel.make(hosts: [host], runs: [key: runs], selection: key, filter: "", triggers: [key: status],
                                              now: now, timeZone: utc, locale: locale)
        let row = try #require(model.rows.first)
        #expect(row.trigger == "GitHub" && row.unread == 1 && row.noteState == .failed)
        #expect(model.hasTriggers)
        let detail = try #require(model.detail)
        #expect(detail.triggered && detail.paused == true)
        #expect(detail.summary == "On GitHub activity in acme/app · a new worktree thread each run")
        #expect(detail.banner == AutomationsPageBanner(state: .failed, title: "Paused", message: "gh isn't signed in", canResume: true))
        #expect(detail.pending == [AutomationsPageEvent(id: "e1", title: "#14 Crash · issue labeled shepherd", waited: "12m ago")])
        #expect(detail.runs.map(\.trigger) == ["Run now", "#12 Fix login crash · issue labeled shepherd"])
        #expect(detail.runs.last?.unread == true && detail.runs.last?.pullRequest?.absoluteString.hasSuffix("/pull/13") == true)
        #expect(detail.runs.first?.failure == "Not a git repository" && detail.runs.first?.word == "didn't start")
        #expect(detail.facts.map(\.label).prefix(4) == ["GitHub", "Who", "Runs in", "Limits"])
        #expect(detail.facts.first { $0.label == "Limits" }?.value == "2 at once · 20 a day · 2 today")
    }

    // MARK: Sidebar

    @Test func theAutomationsRowSaysWhatNeedsALook() {
        let id = AutomationID()
        let unread = [id: [AutomationRun(startedAt: 0, result: .finished, unread: true), AutomationRun(startedAt: 1, result: .finished)]]
        #expect(SidebarDerivation.automationsTrailing(runs: unread, statuses: [:], allPaused: false) == .count(1))
        let failing = [id: AutomationTriggerStatus(state: .paused, reason: "gh isn't signed in")]
        #expect(SidebarDerivation.automationsTrailing(runs: unread, statuses: failing, allPaused: false) == .alert("1 paused"))
        #expect(SidebarDerivation.automationsTrailing(runs: [:], statuses: [:], allPaused: true) == .alert("paused"))
        #expect(SidebarDerivation.automationsTrailing(runs: [:], statuses: [id: AutomationTriggerStatus(state: .paused)], allPaused: false)
            == .none)
    }

    @Test func runThreadsFoldUnderTheirAutomationInTheirSpace() throws {
        let space = Fixture.space("shepherd", path: "/code/shepherd")
        let automation = Automation(name: "pr-loop", prompt: "p", cwd: "/code/shepherd",
                                    trigger: .github([GitHubTrigger(events: [.issueOpened])]))
        func run(_ name: String, at: Double, status: AgentStatus = .idle) -> Agent {
            var agent = Fixture.agent(name, in: space).agent
            agent.automationOrigin = AutomationOrigin(automationID: automation.id)
            agent.lastActiveAt = at
            agent.status = status
            return agent
        }
        var mine = Fixture.agent("mine", in: space).agent
        mine.lastActiveAt = 20
        let first = run("#12 Fix login", at: 30, status: .blocked), second = run("#13 Flaky", at: 10)
        let state = ShepherdState(spaces: [space], agents: [first, mine, second], automations: [automation])
        let tree = SidebarDerivation.tree(SidebarSource(local: state, unreadRuns: [second.id]), options: SidebarTreeOptions())
        let project = try #require(tree.projects.first)
        // The group sits where its newest run falls, its runs together.
        #expect(project.rows.map(\.title) == ["#12 Fix login", "#13 Flaky", "mine"])
        let group = try #require(project.runGroups[automation.id])
        #expect(group.count == 2 && group.unread == 1 && group.rollup == .waiting && group.name == "pr-loop")

        // Closed (the default): one group row, and its runs are out of ⌘-digit reach.
        let closed = tree.items(collapsed: [], selected: nil, shortcuts: false, connected: [])
        #expect(closed.filter { if case .runGroup = $0 { true } else { false } }.count == 1)
        #expect(tree.visibleRows(collapsed: []).map(\.title) == ["mine"])
        #expect(closed.compactMap { if case .row(let row) = $0 { row.title } else { nil } } == ["mine"])

        let open: Set<String> = [SidebarRunGroupRow.key(project: project.id, automation: automation.id)]
        let rows = tree.items(collapsed: open, selected: nil, shortcuts: false, connected: [])
            .compactMap { if case .row(let row) = $0 { row } else { nil } }
        #expect(rows.map(\.title) == ["#12 Fix login", "#13 Flaky", "mine"])
        #expect(rows.map(\.projectDepth) == [1, 1, 0])
        #expect(tree.visibleRows(collapsed: open).count == 3)
    }
}
