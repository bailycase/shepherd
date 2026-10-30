import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The Mac's automation triggers as drawn: what the editor adds to the shared form (speed, a
/// changed rule's anchor), the line under a triggered automation's name, a host's inbox, the
/// sidebar's Automations badge, and run threads folded under their automation in the space tree
/// and in Activity.
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

    // The presets, validation and round trip live with the shared form (ShepherdRemoteUnitTests);
    // these are what the Mac editor adds on top: speed, and a changed rule's anchor.

    @Test func theFormSendsSpeedAndAnUnchangedRuleKeepsItsAnchor() throws {
        var automation = Automation(name: "nightly", prompt: "p", cwd: "/tmp",
                                    trigger: .schedule(AutomationSchedule(rrule: "FREQ=MINUTELY;INTERVAL=30", start: 42)))
        var form = AutomationTriggerForm(AutomationSettings(of: automation))
        #expect(form.scheduleKind == .every && form.everyMinutes == 30 && form.start == 42)
        #expect(form.anchorNote == nil, "a saved interval keeps counting from its anchor")
        form.speed = ServiceTier.fast.rawValue
        form.model = "gpt-5"
        try form.settings.apply(to: &automation)
        #expect(automation.serviceTier == .fast && automation.model == "gpt-5")
        #expect(automation.trigger == .schedule(AutomationSchedule(rrule: "FREQ=MINUTELY;INTERVAL=30", start: 42)))

        // A changed interval is anchored when it's saved, and the editor says so.
        form.everyMinutes = 45
        #expect(form.anchorNote == "Every 45 min, counted from when you save")
        #expect(form.trigger == .schedule(AutomationSchedule(rrule: "FREQ=MINUTELY;INTERVAL=45")))
        form.everyMinutes = 30
        #expect(form.trigger == .schedule(AutomationSchedule(rrule: "FREQ=MINUTELY;INTERVAL=30", start: 42)), "changed back, the anchor returns")
        form.scheduleKind = .daily
        #expect(form.anchorNote == nil, "a daily time doesn't count from the save")
        form.speed = ""
        try form.settings.apply(to: &automation)
        #expect(automation.serviceTier == nil)
        // A new interval has no anchor yet.
        // A schedule an older Mac editor saved, on the second, reads as its preset.
        #expect(AutomationSchedulePreset(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0") == .daily(hour: 9, minute: 0))
        var fresh = AutomationTriggerForm()
        fresh.kind = .schedule
        fresh.scheduleKind = .every
        #expect(fresh.anchorNote == "Every 30 min, counted from when you save")
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

    @Test func runThreadsFoldUnderTheirAutomationInActivity() throws {
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
        let asking = run("#14 Asks", at: 40, status: .blocked)
        let working = run("#12 Fix login", at: 30, status: .working), done = run("#13 Flaky", at: 10)
        let state = ShepherdState(spaces: [space], agents: [asking, working, mine, done], automations: [automation])
        let key = AutomationKey(host: PageHost.localID, automation: automation.id)
        let lists = SidebarDerivation.lists(SidebarSource(local: state, unreadRunCounts: [key: 1]))
        // The asking run stays in Needs you; the others leave Working and Recents for Automations.
        #expect(lists.needsYou.map(\.title) == ["#14 Asks"])
        #expect(lists.automations.map(\.title) == ["#12 Fix login", "#13 Flaky"])
        #expect(lists.working.isEmpty && lists.recents.map(\.title) == ["mine"])
        let row = try #require(lists.automationRows.first)
        #expect(row.runs == 2 && row.unread == 1 && row.attention && row.word == "asked you" && row.name == "pr-loop")

        // Closed (the default): one automation row in Automations and its runs out of ⌘↑/↓'s reach.
        let closed = lists.items(collapsed: [])
        #expect(closed.filter { if case .automation = $0 { true } else { false } }.count == 1)
        #expect(!closed.contains { if case .row(let row) = $0 { row.foldedUnder != nil } else { false } })
        #expect(!lists.visibleRows(collapsed: []).contains { $0.foldedUnder != nil })

        let open: Set<String> = [SidebarLists.runGroupKey(key)]
        let rows = lists.items(collapsed: [], openRunGroups: open).compactMap { if case .row(let row) = $0 { row.title } else { nil } }
        #expect(rows.contains("#12 Fix login") && rows.contains("#13 Flaky"))
        #expect(lists.visibleRows(collapsed: [], openRunGroups: open).count == 4)
    }

    @Test func aHostsTriggeredAutomationGetsTheInboxAndItsOwnPauseAll() throws {
        let hostID = UUID()
        let automation = Automation(name: "nightly", prompt: "p", cwd: "/srv",
                                    trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0")))
        let key = AutomationKey(host: hostID, automation: automation.id)
        let local = AutomationHost(id: PageHost.localID, name: PageHost.localName, connected: true, manageable: true,
                                   state: ShepherdState(), triggers: true)
        func host(triggers: Bool) -> AutomationHost {
            AutomationHost(id: hostID, name: "build-01", connected: true, manageable: true,
                           state: ShepherdState(automations: [automation]), triggers: triggers)
        }
        let event = AutomationEvent(id: "schedule:1", title: "Scheduled run", occurredAt: now.timeIntervalSince1970 - 60)
        let paused = AutomationTriggerStatus(state: .paused, pending: [event], allPaused: true, timeZone: "Europe/Berlin")
        let model = AutomationsPageModel.make(hosts: [local, host(triggers: true)], runs: [key: []], selection: key, filter: "",
                                              triggers: [key: paused], now: now, timeZone: utc, locale: locale)
        #expect(model.hostPauses == [AutomationsPageHostPause(id: hostID, name: "build-01", paused: true)])
        #expect(model.pauseMenuTitle == "Paused on build-01")
        let detail = try #require(model.detail)
        #expect(detail.paused == true && detail.pending.map(\.id) == ["schedule:1"])
        #expect(detail.banner?.title == "All triggers on build-01 are paused" && detail.banner?.resumesAll == true)

        // A host without triggers sends no status: the facts alone, no Pause and nothing waiting.
        let old = AutomationsPageModel.make(hosts: [local, host(triggers: false)], runs: [key: []], selection: key, filter: "",
                                            now: now, timeZone: utc, locale: locale)
        #expect(old.hostPauses.isEmpty && old.detail?.paused == nil && old.detail?.banner == nil && old.detail?.pending == [])
        #expect(old.detail?.facts.first?.value == "Daily at 09:00")
    }
}
