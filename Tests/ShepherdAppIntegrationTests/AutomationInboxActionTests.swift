import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A triggered automation's inbox on the Automations page, on This Mac (real accessibility
/// presses on the page) and on a host over the remote protocol (the view model's entry points
/// the same buttons call): Run now and Dismiss on a pending event, Pause and Resume, Pause all,
/// opening a run clears its unread dot, and the editor's settings (speed included) land on the
/// automation. A stand-in GitHub labels three issues; a limit of one run a day leaves two waiting.
@Suite("Automation inbox actions", .mainActorExclusive)
struct AutomationInboxActionTests {
    /// Three issues labeled shepherd a moment after the trigger first looked.
    static func labeledIssues(at: Date) -> [GitHubItem] {
        (12...14).map { number in
            GitHubItem(repo: "acme/app", number: number, isPullRequest: false, title: "Issue \(number)", body: "b",
                       url: "https://github.com/acme/app/issues/\(number)", createdAt: at.addingTimeInterval(-3600), author: "maintainer",
                       association: "OWNER", labels: ["shepherd"], headOID: nil,
                       events: [.init(id: "LE\(number)", at: at.addingTimeInterval(Double(number)), activity: .labeled(label: "shepherd", actor: "maintainer"))])
        }
    }

    static func loop(cwd: String) -> Automation {
        Automation(name: "issue loop", prompt: "Fix the issue.", cwd: cwd,
                   trigger: .github([GitHubTrigger(events: [.issueLabeled], labels: ["shepherd"])]),
                   workspace: .local, limits: AutomationLimits(maxConcurrent: 1, maxPerDay: 1))
    }

    /// Finishes a run's opening turn, then reports it asking as pi's status extension would (the
    /// stub pi loads none): its run waits on the user, unread.
    @MainActor
    static func settle(_ agentID: AgentID, on app: AppHarness) async throws {
        let server = app.server
        try await eventuallyAsync("the run's opening turn to finish", timeout: .seconds(30)) {
            guard case .snapshot(let snapshot) = try await server.nativeThread(agentID: agentID, request: .snapshot()) else { return false }
            return !snapshot.running && snapshot.messages.contains { $0.role == "user" }
        }
        let reporter = try ExtensionClient(path: app.scratch.socketPath)
        try reporter.send(.setAgentStatus(agentID: agentID, status: .blocked))
        try await eventuallyOnMain("the run to ask") { server.state.agents.first { $0.id == agentID }?.status == .blocked }
    }

    // MARK: This Mac, pressed

    @Test func thisMacsInboxControlsTakeRealPresses() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressInbox() }
        }
    }

    @MainActor
    private static func pressInbox() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let repo = try makeScratchRepo()
        let items = Locked<[GitHubItem]>([])
        let app = try AppHarness(triggerSource: AutomationTriggers.Source(activity: { _ in items.current }, originRepo: { _ in "acme/app" }))
        defer { app.stop() }
        let space = Fixture.space(path: repo.path)
        var state = Fixture.state(spaces: [space], agents: [])
        let automation = loop(cwd: repo.path)
        state.automations = [automation]
        let vm = try await app.start(with: state)
        let id = automation.id
        items.withValue { $0 = labeledIssues(at: Date().addingTimeInterval(5)) }
        await app.server.automationTriggers.resume(id)
        await app.server.automationTriggers.tick()
        func runs() -> [Agent] { vm.state.agents.filter { $0.automationOrigin?.automationID == id } }
        try await eventuallyOnMain("one run and two waiting", timeout: .seconds(20)) {
            vm.refreshAutomationTriggers()
            return runs().count == 1 && vm.automationTriggerStatuses[id]?.pending.count == 2
        }

        vm.automationsPageSelection = AutomationKey(host: PageHost.localID, automation: id)
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 900), dark: true, AutomationsDestination(vm: vm))
        defer { window.close() }
        func control(_ match: (String) -> Bool) -> Control? {
            window.controls().first { $0.label.map(match) == true && $0.isEnabled }
        }

        // Run now on a waiting event starts it past the limits.
        try await eventuallyOnMain("the waiting events are drawn") { control { $0.hasPrefix("Run #") && $0.hasSuffix(" now") } != nil }
        try window.press(try #require(control { $0.hasPrefix("Run #") && $0.hasSuffix(" now") }?.label))
        try await eventuallyOnMain("a second run, one still waiting", timeout: .seconds(20)) {
            runs().count == 2 && vm.automationTriggerStatuses[id]?.pending.count == 1
        }
        // Dismiss drops the last one.
        try await eventuallyOnMain("one waiting event is drawn") {
            control { $0.hasPrefix("Dismiss #") } != nil && control { $0.hasPrefix("Run #") && $0.hasSuffix(" now") } != nil
                && window.controls().filter { $0.label?.hasPrefix("Dismiss #") == true }.count == 1
        }
        try window.press(try #require(control { $0.hasPrefix("Dismiss #") }?.label))
        try await eventuallyOnMain("nothing waits") { vm.automationTriggerStatuses[id]?.pending.isEmpty == true }

        // Pause, then Resume from the banner.
        try await eventuallyOnMain("Pause is drawn") { control { $0 == "Pause" } != nil }
        try window.press("Pause")
        try await eventuallyOnMain("the trigger to pause") { vm.automationTriggerStatuses[id]?.state == .paused }
        try await eventuallyOnMain("Resume is drawn") { control { $0 == "Resume" } != nil }
        try window.press("Resume")
        try await eventuallyOnMain("the trigger to resume") { vm.automationTriggerStatuses[id]?.state == .active }

        // Pause all triggers, and back.
        let pauseAll = try #require(window.controls().first { $0.label == "Pause all triggers" })
        try window.press("Pause all triggers", role: pauseAll.role)
        try await eventuallyOnMain("every trigger to pause") { vm.automationTriggersAllPaused }
        try await eventuallyOnMain("the switch shows it") { window.controls().contains { $0.label == "Pause all triggers" } }
        try window.press("Pause all triggers", role: pauseAll.role)
        try await eventuallyOnMain("every trigger to resume") { !vm.automationTriggersAllPaused }

        // A run that asks is unread until its thread is opened from the inbox.
        try await settle(try #require(runs().first?.id), on: app)
        try await eventuallyOnMain("a run to ask, unread", timeout: .seconds(20)) {
            vm.refreshAutomationTriggers()
            return vm.localAutomationRuns[id]?.contains { $0.unread && $0.agentID != nil } == true
        }
        let unread = try #require(vm.localAutomationRuns[id]?.first { $0.unread && $0.agentID != nil })
        try await eventuallyOnMain("the unread run is drawn") { control { $0.hasPrefix("unread, ") } != nil }
        try window.press(try #require(control { $0.hasPrefix("unread, ") }?.label))
        #expect(vm.selectedAgentID == unread.agentID)
        try await eventuallyOnMain("its unread dot to go") {
            vm.localAutomationRuns[id]?.first { $0.id == unread.id }?.unread == false
        }
    }

    // MARK: A host

    @Test @MainActor func aHostsInboxWorksFromThisMac() async throws {
        try StubPi.installAsEngine()
        let items = Locked<[GitHubItem]>([])
        let local = try AppHarness()
        let remote = try RemoteHostHarness(triggerSource: AutomationTriggers.Source(activity: { _ in items.current },
                                                                                  originRepo: { _ in "acme/app" }))
        defer { local.stop(); remote.stop() }
        let vm = try await local.start()
        let repo = try makeScratchRepo()
        let automation = Self.loop(cwd: repo.path)
        var hostState = Fixture.state(spaces: [Fixture.space(path: repo.path)], agents: [])
        hostState.automations = [automation]
        try await remote.host.start(with: hostState)
        let host = remote.host.server
        let connection = try await remote.connect(local.remoteHosts, name: "build-01")
        #expect(connection.supportsAutomationTriggers && vm.automationTriggersServed(connection.id))
        let key = AutomationKey(host: connection.id, automation: automation.id)

        items.withValue { $0 = Self.labeledIssues(at: Date().addingTimeInterval(5)) }
        await host.automationTriggers.resume(automation.id)
        await host.automationTriggers.tick()
        func runs() -> [Agent] { host.state.agents.filter { $0.automationOrigin?.automationID == automation.id } }
        try await eventuallyAsync("one run and two waiting on the host", timeout: .seconds(20)) {
            await vm.refreshRemoteAutomationTriggers()
            return runs().count == 1 && vm.remoteAutomationTriggerStatuses[key]?.pending.count == 2
        }
        // The page reads the host's inbox, and previews schedules in its time zone.
        #expect(vm.automationHostTimeZone(connection.id) == TimeZone.current)
        vm.automationsPageSelection = key
        #expect(vm.automationsPageModel().detail?.pending.count == 2)

        // Run now on a waiting event, then Dismiss the other.
        let waiting = try #require(vm.remoteAutomationTriggerStatuses[key]?.pending)
        vm.runPendingAutomationEvent(key, eventID: waiting[0].id)
        try await eventuallyOnMain("a second run on the host", timeout: .seconds(20)) {
            runs().count == 2 && vm.remoteAutomationTriggerStatuses[key]?.pending.count == 1
        }
        try await eventuallyOnMain("the change to land") { !vm.remoteAutomationsPending.contains(key) }
        vm.dismissAutomationEvent(key, eventID: waiting[1].id)
        try await eventuallyOnMain("nothing waits") { vm.remoteAutomationTriggerStatuses[key]?.pending.isEmpty == true }

        // Pause and Resume.
        try await eventuallyOnMain("the change to land") { !vm.remoteAutomationsPending.contains(key) }
        vm.pauseAutomationTrigger(key)
        try await eventuallyOnMain("the host's trigger to pause") { vm.remoteAutomationTriggerStatuses[key]?.state == .paused }
        #expect(vm.automationsPageModel().detail?.paused == true)
        try await eventuallyOnMain("the change to land") { !vm.remoteAutomationsPending.contains(key) }
        vm.resumeAutomationTrigger(key)
        try await eventuallyOnMain("the host's trigger to resume") { vm.remoteAutomationTriggerStatuses[key]?.state == .active }

        // Pause all on the host, from its row in the header's menu.
        try await eventuallyOnMain("the change to land") { !vm.remoteAutomationsPending.contains(key) }
        vm.setAllAutomationTriggersPaused(host: connection.id, true)
        try await eventuallyOnMain("every trigger on the host to pause") { vm.remoteAutomationTriggerStatuses[key]?.allPaused == true }
        #expect(vm.automationsPageModel().hostPauses.first?.paused == true)
        #expect(!vm.automationTriggersAllPaused, "This Mac's own switch is untouched")
        try await eventuallyOnMain("the change to land") { !vm.remoteAutomationsPending.contains(key) }
        vm.setAllAutomationTriggersPaused(host: connection.id, false)
        try await eventuallyOnMain("the host's triggers to resume") { vm.remoteAutomationTriggerStatuses[key]?.allPaused == false }

        // Opening an unread run's thread clears its dot on the host.
        try await Self.settle(try #require(runs().first?.id), on: remote.host)
        try await eventuallyAsync("a run to ask, unread, on the host", timeout: .seconds(20)) {
            await vm.loadRemoteAutomationRuns(key)
            return vm.remoteAutomationRuns[key]?.contains { $0.unread && $0.agentID != nil } == true
        }
        let unread = try #require(vm.remoteAutomationRuns[key]?.first { $0.unread && $0.agentID != nil })
        vm.openThread(FleetRef(host: connection.id, agent: try #require(unread.agentID)))
        #expect(vm.selectedRemoteAgent?.agentID == unread.agentID)
        let automationID = automation.id
        try await eventually("the host to mark it read") { @Sendable in
            await host.automationRuns(automationID).first { $0.id == unread.id }?.unread == false
        }

        // The editor's settings, speed included, land on the host's automation.
        var form = AutomationTriggerForm(AutomationSettings(of: automation))
        form.speed = ServiceTier.fast.rawValue
        form.maxPerDay = 5
        form.thinking = ThinkingLevel.high.rawValue
        let draft = RemoteAutomationDraft(name: automation.name, prompt: automation.prompt, cwd: automation.cwd, enabled: true,
                                          settings: form.settings)
        try await vm.saveAutomation(key, host: connection.id, draft: draft)
        try await eventuallyOnMain("the settings to land on the host") {
            host.state.automations.first?.serviceTier == .fast
        }
        let saved = try #require(host.state.automations.first)
        #expect(saved.limits.maxPerDay == 5 && saved.thinking == .high && saved.trigger == automation.trigger)
    }

    // MARK: Editor on This Mac

    @Test @MainActor func thisMacsEditorSavesEveryPinIncludingSpeed() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        var form = AutomationTriggerForm()
        form.kind = .schedule
        form.scheduleKind = .every
        form.everyMinutes = 30
        form.speed = ServiceTier.fast.rawValue
        form.model = ScratchServer.standInModels.models.first ?? ""
        #expect(form.anchorNote == "Every 30 min, counted from when you save")
        let draft = RemoteAutomationDraft(name: "Every half hour", prompt: "p", cwd: app.dir.path, enabled: false, settings: form.settings)
        try await vm.saveAutomation(nil, host: PageHost.localID, draft: draft)
        let saved = try #require(app.server.state.automations.first)
        #expect(saved.serviceTier == .fast && saved.model == form.model.nilIfEmpty)
        #expect(saved.trigger == .schedule(AutomationSchedule(rrule: "FREQ=MINUTELY;INTERVAL=30")))

        // Read back, the editor shows what was saved; clearing Speed saves the default.
        let key = AutomationKey(host: PageHost.localID, automation: saved.id)
        var reread = AutomationTriggerForm(try #require(vm.automationDraft(key)?.settings))
        #expect(reread.speed == ServiceTier.fast.rawValue)
        reread.speed = ""
        var edited = draft
        edited.settings = reread.settings
        try await vm.saveAutomation(key, host: PageHost.localID, draft: edited)
        #expect(app.server.state.automations.first?.serviceTier == nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
