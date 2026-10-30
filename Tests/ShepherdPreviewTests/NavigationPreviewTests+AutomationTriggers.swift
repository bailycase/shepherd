import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Triggered automations on the Mac: the Automations page as an inbox (a GitHub trigger paused by
/// an error with an event waiting, a schedule, a host's), the editor's Schedule (an interval and
/// its Speed pin) and GitHub sections, and run threads folded under their automation in the space
/// tree and in Activity.
extension PreviewTests {
    private static let triggerPageSize = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)

    private struct TriggerFixture {
        let workspace: PreviewWorkspace
        let prLoop: Automation
        let nightly: Automation
        let asking: Agent
        let finished: Agent
    }

    /// shepherd's space with one ordinary thread and two of pr-loop's runs (one asking, one
    /// finished and not opened); pr-loop watches GitHub, Nightly triage runs daily, and Weekly
    /// dependency bumps is the old manual kind.
    private func triggerWorkspace() async throws -> TriggerFixture {
        // The asking run posts its banner as the workspace loads; the banner reads NSApp, as rendering does.
        _ = NSApplication.shared
        let workspace = try PreviewWorkspace()
        let space = Space(name: "shepherd", path: workspace.dir.path)
        let now = Date().timeIntervalSince1970
        // Off, so nothing polls GitHub or ticks while the preview renders; the statuses below say what the page shows.
        let prLoop = Automation(name: "pr-loop", prompt: "Fix the issue and open a PR.", cwd: space.path, enabled: false,
                                trigger: .github([GitHubTrigger(repo: "acme/app", events: [.issueLabeled, .pullRequestComment],
                                                                labels: ["shepherd"])]),
                                authorGate: .contributors, limits: AutomationLimits(maxConcurrent: 2, maxPerDay: 20), model: "claude-sonnet-4-5")
        let nightly = Automation(name: "Nightly triage", prompt: "Triage what came in overnight.", cwd: space.path, enabled: false,
                                 trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0")),
                                 workspace: .local)
        let manual = Automation(name: "Weekly dependency bumps", prompt: "Bump dependencies.", cwd: space.path, enabled: false)
        var (mine, mineTab) = try await workspace.agent("Plan shepherd extensions", in: space, order: 0, status: .working)
        mine.lastActiveAt = (now - 120) * 1000
        var (asking, askingTab) = try await workspace.agent("#12 Fix login crash", in: space, order: 1, status: .blocked)
        asking.automationOrigin = AutomationOrigin(automationID: prLoop.id, trigger: "#12 Fix login crash · issue labeled shepherd")
        asking.waitingOn = "Push to the PR branch?"
        asking.waitingReason = "push?"
        asking.lastActiveAt = now * 1000
        var (finished, finishedTab) = try await workspace.agent("#9 Flaky snapshot test", in: space, order: 2, status: .idle)
        finished.automationOrigin = AutomationOrigin(automationID: prLoop.id, trigger: "#9 Flaky snapshot test · PR comment")
        finished.lastActiveAt = (now - 3600) * 1000
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [mineTab, askingTab, finishedTab], agents: [mine, asking, finished],
                                               automations: [prLoop, nightly, manual]))
        // The view model reads the triggers and run log once the workspace is adopted; the seeded
        // statuses below land after that read, not under it.
        let vm = workspace.vm
        vm.refreshAutomationTriggers()
        try await eventuallyOnMain("the first trigger read") { vm.localAutomationRuns[prLoop.id] != nil }
        try await Task.sleep(for: .milliseconds(100))
        return TriggerFixture(workspace: workspace, prLoop: prLoop, nightly: nightly, asking: asking, finished: finished)
    }

    /// What the host would report: pr-loop paused by an error with an event waiting, its runs
    /// (one asking, one finished with a PR and unread, one that didn't start), the schedule watching.
    private func seedTriggerState(_ fixture: TriggerFixture, on: Bool = true) {
        let vm = fixture.workspace.vm
        let now = Date().timeIntervalSince1970
        let pending = AutomationEvent(id: "acme/app#14", kind: .issueLabeled, repo: "acme/app", number: 14,
                                      title: "Crash when the window closes during a sync", detail: "shepherd", occurredAt: now - 720)
        let nightlyNext: Date? = if case .schedule(let schedule) = fixture.nightly.trigger { schedule.next(after: Date()) } else { nil }
        vm.automationTriggerStatuses = [
            fixture.prLoop.id: AutomationTriggerStatus(state: .paused, reason: "gh isn't signed in. Run gh auth login, then Resume.",
                                                       pending: [pending], lastCheckedAt: now - 1800, runsToday: 3),
            fixture.nightly.id: AutomationTriggerStatus(state: .active, nextRunAt: nightlyNext?.timeIntervalSince1970, runsToday: 1),
        ]
        vm.localAutomationRuns = [
            fixture.prLoop.id: [
                AutomationRun(startedAt: now - 5400, endedAt: now - 5400, result: .failed, trigger: "#7 Docs typo · issue labeled shepherd",
                              failure: "Couldn't make a worktree: the default branch didn't fetch."),
                AutomationRun(startedAt: now - 4000, settledAt: now - 3600, result: .finished, agentID: fixture.finished.id,
                              trigger: "#9 Flaky snapshot test · PR comment", pullRequestURL: "https://github.com/acme/app/pull/10",
                              unread: true),
                AutomationRun(startedAt: now - 300, result: .needsYou, agentID: fixture.asking.id,
                              trigger: "#12 Fix login crash · issue labeled shepherd", unread: true),
            ],
            fixture.nightly.id: [AutomationRun(startedAt: now - 86_400, settledAt: now - 86_000, result: .finished, trigger: "Scheduled run")],
        ]
        vm.automationsPageSelection = AutomationKey(host: PageHost.localID, automation: fixture.prLoop.id)
    }

    /// The page as an inbox: pr-loop selected, paused by gh with #14 waiting and its runs.
    @Test func automationsPageTriggers() async throws {
        let fixture = try await triggerWorkspace()
        defer { fixture.workspace.stop() }
        // Shown as on: the switch's state comes from the automation, the rest from the statuses.
        var state = fixture.workspace.vm.state
        for index in state.automations.indices { state.automations[index].enabled = true }
        let vm = fixture.workspace.vm
        seedTriggerState(fixture)
        let local = AutomationHost(id: PageHost.localID, name: PageHost.localName, connected: true, manageable: true, state: state)
        let model = AutomationsPageModel.make(hosts: [local], runs: vm.automationRunsByKey, selection: vm.automationsPageSelection,
                                              filter: "", triggers: vm.automationTriggersByKey, allPaused: false)
        #expect(model.detail?.pending.count == 1)
        try await Preview.render("page-automations-triggers", size: Self.triggerPageSize) {
            AutomationsPage(model: model, actions: Self.noAutomationActions)
        }
    }

    /// Pause all triggers on: the header's switch, and the schedule selected under its banner.
    @Test func automationsPageAllPaused() async throws {
        let fixture = try await triggerWorkspace()
        defer { fixture.workspace.stop() }
        var state = fixture.workspace.vm.state
        for index in state.automations.indices { state.automations[index].enabled = true }
        let vm = fixture.workspace.vm
        seedTriggerState(fixture)
        let local = AutomationHost(id: PageHost.localID, name: PageHost.localName, connected: true, manageable: true, state: state)
        let model = AutomationsPageModel.make(hosts: [local], runs: vm.automationRunsByKey,
                                              selection: AutomationKey(host: PageHost.localID, automation: fixture.nightly.id),
                                              filter: "", triggers: vm.automationTriggersByKey, allPaused: true)
        #expect(model.allPaused && model.detail?.banner?.canResume == false)
        try await Preview.render("page-automations-all-paused", size: Self.triggerPageSize) {
            AutomationsPage(model: model, actions: Self.noAutomationActions)
        }
    }

    /// Edit pr-loop: the GitHub trigger, who can trigger (widened to contributors, with its warning), and limits.
    @Test func automationEditorGitHub() async throws {
        let fixture = try await triggerWorkspace()
        defer { fixture.workspace.stop() }
        let vm = fixture.workspace.vm
        let key = AutomationKey(host: PageHost.localID, automation: fixture.prLoop.id)
        try await Preview.render("sheet-automation-editor-github",
                                 size: CGSize(width: AppLayout.automationSheetWidth + 80, height: AppLayout.automationSheetBodyMaxHeight + 260)) {
            AutomationEditorSheet(vm: vm, target: .edit(key)) {}
        }
    }

    /// Edit Nightly triage: the Schedule section with its preset, time and next run.
    @Test func automationEditorSchedule() async throws {
        let fixture = try await triggerWorkspace()
        defer { fixture.workspace.stop() }
        let key = AutomationKey(host: PageHost.localID, automation: fixture.nightly.id)
        try await Preview.render("sheet-automation-editor-schedule",
                                 size: CGSize(width: AppLayout.automationSheetWidth + 80, height: AppLayout.automationSheetBodyMaxHeight + 260)) {
            AutomationEditorSheet(vm: fixture.workspace.vm, target: .edit(key)) {}
        }
    }

    /// The space tree: pr-loop's runs folded under it (closed, then open), and the Automations
    /// row's unread count.
    @Test(arguments: [false, true])
    func sidebarAutomationRunGroup(open: Bool) async throws {
        let fixture = try await triggerWorkspace()
        defer { fixture.workspace.stop() }
        let vm = fixture.workspace.vm
        vm.settings.sidebarStyle = .projects
        seedTriggerState(fixture)
        if open, let space = vm.state.spaces.first {
            vm.collapsedProjects.insert(SidebarRunGroupRow.key(project: .local(space.id), automation: fixture.prLoop.id))
        }
        try await Preview.render(open ? "sidebar-automation-runs-open" : "sidebar-automation-runs",
                                 size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 420),
                                 ready: { vm.sidebarTree.projects.first?.runGroups.isEmpty == false }) {
            SidebarView(vm: vm)
        }
    }

    /// Activity's Automations group (the user's request): one row per active automation after Designs and Projects —
    /// pr-loop asking (its asking run also in Needs you) with its unread runs, Nightly triage's next run — with pr-loop's
    /// finished run folded under it (closed, then open). The manual automation isn't running, so it has no row.
    @Test(arguments: [false, true])
    func sidebarActivityAutomationRunGroup(open: Bool) async throws {
        let fixture = try await triggerWorkspace()
        defer { fixture.workspace.stop() }
        let vm = fixture.workspace.vm
        vm.settings.sidebarStyle = .activity
        seedTriggerState(fixture)
        // Shown as on in the sidebar only: the server keeps them off, so nothing polls or fires while it renders.
        for index in vm.state.automations.indices { vm.state.automations[index].enabled = true }
        // Designs and Projects above it, as the user's screenshot draws them.
        vm.settings.designToolEnabled = true
        vm.settings.projectsEnabled = true
        vm.state.designs = [Design(name: "Onboarding flow", createdAt: 1, lastActiveAt: 2, boardCount: 12)]
        let key = AutomationKey(host: PageHost.localID, automation: fixture.prLoop.id)
        if open { vm.collapsedProjects.insert(SidebarLists.runGroupKey(key)) }
        try await Preview.render(open ? "sidebar-activity-automation-runs-open" : "sidebar-activity-automation-runs",
                                 size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 560),
                                 ready: { vm.sidebarLists.automationRows.count == 2 && !vm.sidebarLists.designs.isEmpty }) {
            SidebarView(vm: vm)
        }
    }

    /// A host's triggered automation on the page: build-01 paused all its triggers (the banner's
    /// Resume all, the header's menu), with an event waiting.
    @Test func automationsPageRemoteHostTriggers() async throws {
        let fixture = try await triggerWorkspace()
        defer { fixture.workspace.stop() }
        let vm = fixture.workspace.vm
        seedTriggerState(fixture)
        var state = vm.state
        for index in state.automations.indices { state.automations[index].enabled = true }
        let hostID = UUID()
        let remote = Automation(name: "Nightly migrations dry run", prompt: "Run the migrations against a copy of prod.", cwd: "/srv/app",
                                trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=2;BYMINUTE=0")),
                                serviceTier: .fast)
        let key = AutomationKey(host: hostID, automation: remote.id)
        let now = Date().timeIntervalSince1970
        let status = AutomationTriggerStatus(state: .active, pending: [AutomationEvent(id: "schedule:1", title: "Scheduled run", occurredAt: now - 900)],
                                             runsToday: 0, allPaused: true, timeZone: "Europe/Berlin")
        let hosts = [
            AutomationHost(id: PageHost.localID, name: PageHost.localName, connected: true, manageable: true, state: state, triggers: true),
            AutomationHost(id: hostID, name: "build-01", connected: true, manageable: true, state: ShepherdState(automations: [remote]),
                           triggers: true),
        ]
        var runs = vm.automationRunsByKey
        runs[key] = [AutomationRun(startedAt: now - 86_400, settledAt: now - 86_000, result: .finished, trigger: "Scheduled run", unread: true)]
        var triggers = vm.automationTriggersByKey
        triggers[key] = status
        let model = AutomationsPageModel.make(hosts: hosts, runs: runs, selection: key, filter: "", triggers: triggers, allPaused: false)
        #expect(model.detail?.banner?.resumesAll == true && model.pauseMenuTitle == "Paused on build-01")
        try await Preview.render("page-automations-remote-triggers", size: Self.triggerPageSize) {
            AutomationsPage(model: model, actions: Self.noAutomationActions)
        }
    }

    /// A new every-30-minutes schedule pinned to Fast: the editor says the interval counts from
    /// the save, and shows the Speed pin.
    @Test func automationEditorIntervalAndSpeed() async throws {
        let fixture = try await triggerWorkspace()
        defer { fixture.workspace.stop() }
        let vm = fixture.workspace.vm
        var form = AutomationTriggerForm()
        form.kind = .schedule
        form.scheduleKind = .every
        form.speed = ServiceTier.fast.rawValue
        let cwd = try #require(vm.state.spaces.first?.path)
        try await vm.saveAutomation(nil, host: PageHost.localID, draft: RemoteAutomationDraft(
            name: "Check the build", prompt: "Look at the latest CI run.", cwd: cwd, enabled: true, settings: form.settings))
        let key = try #require(vm.automationsPageSelection)
        try await Preview.render("sheet-automation-editor-interval",
                                 size: CGSize(width: AppLayout.automationSheetWidth + 80, height: AppLayout.automationSheetBodyMaxHeight + 260)) {
            AutomationEditorSheet(vm: vm, target: .edit(key)) {}
        }
    }

    private static let noAutomationActions = AutomationsPageActions(
        setFilter: { _ in }, select: { _ in }, setEnabled: { _, _ in }, run: { _ in }, stop: { _ in }, openThread: { _ in },
        delete: { _ in }, edit: { _ in }, create: {})
}
