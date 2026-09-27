import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The Automations page's New automation, Edit, switch and Delete, on this Mac's server and on a
/// host over the remote protocol: each lands on the host that owns the automation, and the page
/// reads it back from that host's state.
@Suite("Automations page actions", .mainActorExclusive)
@MainActor
struct AutomationsPageActionTests {
    @Test func thisMacsAutomationIsCreatedEditedSwitchedAndDeletedFromThePage() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let draft = RemoteAutomationDraft(name: "Triage new issues", prompt: "triage", cwd: app.dir.path, enabled: false)

        try await vm.saveAutomation(nil, host: PageHost.localID, draft: draft)
        let saved = try #require(app.server.state.automations.first)
        #expect(saved.name == "Triage new issues" && !saved.enabled && saved.agentID == nil, "saving starts no run")
        let key = AutomationKey(host: PageHost.localID, automation: saved.id)
        #expect(vm.automationsPageSelection == key)
        #expect(vm.automationsPageModel().rows.map(\.host) == ["This Mac"])
        #expect(vm.automationsPageModel().detail?.name == "Triage new issues")

        var edited = draft
        edited.name = "Triage overnight issues"
        edited.prompt = "triage what came in overnight"
        try await vm.saveAutomation(key, host: PageHost.localID, draft: edited)
        #expect(app.server.state.automations.map(\.name) == ["Triage overnight issues"])
        #expect(app.server.state.automations.first?.id == saved.id)

        vm.setAutomationEnabled(key, true)
        try await eventuallyOnMain("the switch to land") { app.server.state.automations.first?.enabled == true }
        #expect(vm.automationsPageModel().rows.first?.enabled == true)

        await vm.loadAutomationPageRuns()
        #expect(vm.localAutomationRuns[saved.id] == [], "the run log read, with no runs yet")
        #expect(vm.automationsPageModel().detail?.runsNote == "No runs yet.")

        vm.deleteAutomation(key)
        try await eventuallyOnMain("the automation to go") { app.server.state.automations.isEmpty }
        #expect(vm.automationsPageSelection == nil)
        #expect(vm.automationsPageModel().emptyText?.hasPrefix("No automations yet") == true)
    }

    @Test func aHostsAutomationIsCreatedEditedSwitchedAndDeletedOnTheHost() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let vm = try await local.start()
        try await remote.host.start(with: ShepherdState())
        let connection = try await remote.connect(local.remoteHosts, name: "build-01")
        let host = remote.host.server
        #expect(vm.automationEditorHosts.map(\.name) == ["This Mac", "build-01"])

        let draft = RemoteAutomationDraft(name: "Nightly migrations dry run", prompt: "migrate", cwd: remote.host.dir.path,
                                          enabled: false)
        try await vm.saveAutomation(nil, host: connection.id, draft: draft)
        try await eventuallyOnMain("the host to save it") { !host.state.automations.isEmpty }
        let saved = try #require(host.state.automations.first)
        #expect(saved.name == draft.name && saved.agentID == nil)
        let key = AutomationKey(host: connection.id, automation: saved.id)
        #expect(vm.automationsPageSelection == key)
        try await eventuallyOnMain("the host's state to reach the page") {
            vm.automationsPageModel().rows.map(\.host) == ["build-01"]
        }

        var edited = draft
        edited.prompt = "migrate against a copy of prod"
        try await vm.saveAutomation(key, host: connection.id, draft: edited)
        try await eventuallyOnMain("the host to take the edit") {
            host.state.automations.map(\.prompt) == ["migrate against a copy of prod"]
        }

        vm.setAutomationEnabled(key, true)
        try await eventuallyOnMain("the host to switch it on") {
            host.state.automations.first?.enabled == true && !vm.remoteAutomationsPending.contains(key)
        }
        await vm.loadAutomationPageRuns()
        #expect(vm.remoteAutomationRuns[key] == [])

        vm.deleteAutomation(key)
        try await eventuallyOnMain("the host to delete it") {
            host.state.automations.isEmpty && !vm.remoteAutomationsPending.contains(key)
        }
    }

    /// Run Now from the page starts a run on this Mac, its detail lists the run, and opening the
    /// run's thread leaves the page for that thread.
    @Test func runNowStartsARunWhoseThreadOpensFromThePage() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let automation = Automation(name: "watch CI", prompt: "watch the build", cwd: app.dir.path, enabled: false)
        let vm = try await app.start(with: ShepherdState(spaces: [Fixture.space(path: app.dir.path)], automations: [automation]))
        let key = AutomationKey(host: PageHost.localID, automation: automation.id)
        vm.openDestination(.automations)
        vm.automationsPageSelection = key
        #expect(vm.shownDestination == .automations)

        vm.runAutomation(key)
        try await eventuallyOnMain("the run to start", timeout: .seconds(30)) {
            app.server.state.automations.first?.agentID != nil
        }
        let run = try #require(app.server.state.automations.first?.agentID)
        await vm.loadAutomationPageRuns()
        let thread = try #require(vm.automationsPageModel().detail?.runs.first?.thread)
        #expect(thread == FleetRef(host: PageHost.localID, agent: run))

        vm.openThread(thread)
        #expect(vm.selectedAgentID == run)
        #expect(vm.destination == nil && vm.shownDestination == nil, "a run's thread takes the column off the page")
    }
}
