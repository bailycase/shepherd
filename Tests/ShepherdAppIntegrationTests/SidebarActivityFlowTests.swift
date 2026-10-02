import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Sidebar activity flow", .mainActorExclusive)
@MainActor
struct SidebarActivityFlowTests {
    @Test func readingDoneKeepsItUntilAnotherThreadAndMarkAllSeenClearsEvenSelectedDone() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("workspace", path: app.dir.path)
        let first = Fixture.agent("first", in: space, status: .done)
        let second = Fixture.agent("second", in: space, order: 1, status: .done)
        let idle = Fixture.agent("idle", in: space, order: 2)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [first, second, idle]))
        vm.selectAgent(first.agent.id)
        let before = vm.sidebarLists.done.map(\.id)
        vm.selectAgent(first.agent.id)
        #expect(vm.sidebarLists.done.map(\.id) == before)
        vm.openDestination(.newThread)
        #expect(vm.sidebarLists.done.map(\.id) == before, "pages do not end reading")
        vm.selectAgent(first.agent.id)
        #expect(vm.sidebarLists.done.map(\.id) == before)
        vm.selectAgent(second.agent.id)
        #expect(vm.sidebarLists.done.map(\.id) == [.local(second.agent.id)])
        #expect(vm.sidebarLists.recents.contains { $0.id == .local(first.agent.id) })
        vm.markAllSidebarDoneSeen()
        #expect(vm.sidebarLists.done.isEmpty, "Mark all seen explicitly clears the selected row too")
        #expect(vm.selectedAgentID == second.agent.id)
        var next = vm.state
        let index = try #require(next.agents.firstIndex { $0.id == first.agent.id })
        next.agents[index].status = .working
        vm.adopt(next)
        next.agents[index].status = .done
        vm.adopt(next)
        #expect(vm.sidebarLists.done.map(\.id) == [.local(first.agent.id)])
        vm.selectAgent(idle.agent.id)
        #expect(vm.sidebarLists.done.map(\.id) == [.local(first.agent.id)], "only the completion actually read gets marked")
        vm.selectAgent(first.agent.id)
        vm.openDestination(.automations)
        next.agents[index].status = .working
        vm.adopt(next)
        next.agents[index].status = .done
        vm.adopt(next)
        vm.selectAgent(idle.agent.id)
        #expect(vm.sidebarLists.done.map(\.id) == [.local(first.agent.id)], "a new completion covered by a page was not read")
        vm.selectAgent(first.agent.id)
        vm.selectAgent(idle.agent.id)
        #expect(vm.sidebarLists.done.isEmpty)
    }

    @Test func actualStatusCallbackAndAdoptionCountOneCompletionAndRefusedSendDoesNotResurrectIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("workspace", path: app.dir.path)
        let live = try await app.liveAgent("worker", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [live]))
        let ready = try await app.readyThread(live.agent.id)
        let reporter = try ExtensionClient(path: app.scratch.socketPath)
        try reporter.send(.setAgentStatus(agentID: live.agent.id, status: .working))
        try await eventuallyOnMain("working") { !vm.sidebarLists.working.isEmpty }
        try reporter.send(.setAgentStatus(agentID: live.agent.id, status: .done))
        try await eventuallyOnMain("done") { !vm.sidebarLists.done.isEmpty }
        let completion = try #require(vm.sidebarLists.done.first?.completion)
        vm.markAllSidebarDoneSeen()
        let reply = try await app.server.nativeThread(agentID: live.agent.id, request: .send(
            expectedSessionID: "stale", generation: ready.generation, operationID: UUID(), text: "do not run", delivery: .followUp))
        guard case .failure = reply else { Issue.record("A stale send must be refused"); return }
        try reporter.send(.setAgentStatus(agentID: live.agent.id, status: .done))
        try await eventuallyOnMain("refused-send activity adopted") { vm.state == app.server.state }
        #expect(vm.sidebarLists.done.isEmpty)
        #expect(vm.sidebarLists.recents.first?.completion == completion)
    }

    @Test func disclosureStateSurvivesViewModelRelaunchAndSelectionRevealsItsGroup() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("workspace", path: app.dir.path)
        let idle = Fixture.agent("idle", in: space)
        let done = Fixture.agent("done", in: space, order: 1, status: .done)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [idle, done]))
        for section in SidebarActivitySection.allCases { vm.toggleActivitySection(section) }
        #expect(vm.sidebarWalkRows.isEmpty)
        #expect(vm.sidebarShortcutRows.isEmpty)
        let relaunched = ShepherdViewModel(
            server: app.server, settings: app.settings, keybindings: app.keybindings, themeManager: app.themeManager,
            remoteHosts: app.remoteHosts, sidebarDefaults: app.defaults, themeInstaller: { _ in },
            restoresAgentsAtLaunch: false, checkoutReader: nil)
        #expect(relaunched.collapsedActivitySections == Set(SidebarActivitySection.allCases))
        vm.selectAgent(done.agent.id)
        #expect(!vm.collapsedActivitySections.contains(.done))
        #expect(vm.collapsedActivitySections.contains(.working) && vm.collapsedActivitySections.contains(.recents))
        #expect(vm.sidebarWalkRows.map(\.id) == [.local(done.agent.id)])
    }

    @Test func deletingASpaceBehindAPageKeepsThePageAndDoesNotReadTheFallbackThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let firstSpace = Fixture.space("first", path: app.dir.appendingPathComponent("first").path)
        let secondSpace = Fixture.space("second", path: app.dir.appendingPathComponent("second").path)
        var first = Fixture.agent("first", in: firstSpace)
        var second = Fixture.agent("second", in: secondSpace, status: .done)
        // Launch on the idle thread, so the fallback completion has never been read.
        first.agent.lastActiveAt = 2000
        second.agent.lastActiveAt = 1000
        let vm = try await app.start(with: Fixture.state(spaces: [firstSpace, secondSpace], agents: [first, second]))
        vm.selectAgent(first.agent.id)
        vm.openDestination(.automations)
        #expect(vm.sidebarLists.done.map(\.id) == [.local(second.agent.id)])
        vm.deleteSpace(firstSpace.id)
        #expect(vm.shownDestination == .automations)
        #expect(vm.selectedAgentID == second.agent.id)
        #expect(vm.sidebarLists.done.map(\.id) == [.local(second.agent.id)])
        await app.settle()
    }

    @Test func remoteDoneKeepsItsPlaceAcrossPagesThenMovesWhenALocalThreadOpens() async throws {
        let app = try AppHarness(), remote = try RemoteHostHarness()
        defer { app.stop(); remote.stop() }
        let localSpace = Fixture.space("local", path: app.dir.path)
        let local = Fixture.agent("local", in: localSpace)
        let vm = try await app.start(with: Fixture.state(spaces: [localSpace], agents: [local]))
        let space = Fixture.space("remote", path: remote.host.dir.path)
        let done = Fixture.agent("remote done", in: space, status: .done)
        try await remote.host.server.putState(Fixture.state(spaces: [space], agents: [done]))
        let connection = try await remote.connect(app.remoteHosts)
        let id = SidebarRowID.remote(.init(hostID: connection.id, agentID: done.agent.id))
        try await eventuallyOnMain("remote Done") { vm.sidebarLists.done.map(\.id) == [id] }
        vm.selectSidebarRow(id)
        vm.openDestination(.automations)
        #expect(vm.sidebarLists.done.map(\.id) == [id])
        vm.selectSidebarRow(id)
        #expect(vm.sidebarLists.done.map(\.id) == [id])
        vm.selectAgent(local.agent.id)
        #expect(vm.sidebarLists.done.isEmpty)
        #expect(vm.sidebarLists.recents.contains { $0.id == id })
        vm.selectSidebarRow(id)
        #expect(vm.sidebarLists.done.isEmpty, "a previously seen remote turn stays seen")
    }

    @Test func toolActivityIsMeasuredAndBoundedToTenSamples() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let id = AgentID()
        for index in 0..<20 { vm.recordSidebarActivity(id, at: Date(timeIntervalSince1970: Double(index * 2))) }
        #expect(vm.sidebarActivitySamples[id] == Array(repeating: 0.5, count: 10))
    }

    @Test func disclosuresAndMarkAllSeenTakeRealAccessibilityPresses() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors {
                for density in NWDensity.allCases { try await Self.pressControls(density: density) }
            }
        }
    }

    private static func pressControls(density: NWDensity) async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("workspace", path: app.dir.path)
        let fixtures = [Fixture.agent("pinned", in: space), Fixture.agent("asking", in: space, order: 1, status: .blocked),
                        Fixture.agent("working", in: space, order: 2, status: .working),
                        Fixture.agent("finished", in: space, order: 3, status: .done), Fixture.agent("idle", in: space, order: 4)]
        var state = Fixture.state(spaces: [space], agents: fixtures)
        state.designs = [Design(name: "Dashboard", createdAt: 1, lastActiveAt: 2, boardCount: 4)]
        let vm = try await app.start(with: state)
        vm.settings.designToolEnabled = true
        vm.pinThread(.local(fixtures[0].agent.id))
        let window = OffscreenWindow(size: CGSize(width: 232, height: 650), dark: true, SidebarView(vm: vm).nwDensity(density))
        defer { window.close() }
        for section in SidebarActivitySection.allCases {
            try await eventuallyOnMain("\(section.title) disclosure") { window.layout(); return window.controls().contains { $0.label == "\(section.title), 1, expanded" } }
            let control = try window.press("\(section.title), 1, expanded")
            #expect(control.frame.height >= HitArea.desktop.minimum)
            #expect(vm.collapsedActivitySections.contains(section))
            let label = "\(section.title), 1, collapsed\(section == .working ? ", running" : "")"
            try await eventuallyOnMain("collapsed header") { window.layout(); return window.controls().contains { $0.label == label } }
            try window.press(label)
            #expect(!vm.collapsedActivitySections.contains(section))
        }
        try window.press("finished, done")
        #expect(vm.selectedAgentID == fixtures[3].agent.id)
        #expect(vm.sidebarLists.done.count == 1, "opening Done does not mark it seen")
        let expandedButton = try window.press("Mark all seen")
        #expect(expandedButton.frame.height >= HitArea.desktop.minimum)
        #expect(vm.sidebarLists.done.isEmpty)
        #expect(vm.selectedAgentID == fixtures[3].agent.id, "Mark all seen does not change selection")
        #expect(!vm.collapsedActivitySections.contains(.done))
        var next = vm.state
        let index = try #require(next.agents.firstIndex { $0.id == fixtures[3].agent.id })
        next.agents[index].status = .working
        vm.adopt(next)
        next.agents[index].status = .done
        vm.adopt(next)
        #expect(vm.sidebarLists.done.count == 1, "a new completion returns to Done")
        vm.toggleActivitySection(.done)
        try await eventuallyOnMain("folded Done still has Mark all seen") { window.layout(); return window.controls().contains { $0.label == "Mark all seen" } }
        let button = try window.press("Mark all seen")
        #expect(button.frame.height >= HitArea.desktop.minimum)
        #expect(vm.sidebarLists.done.isEmpty)
        #expect(vm.selectedAgentID == fixtures[3].agent.id)
        #expect(vm.collapsedActivitySections.contains(.done), "the separate button does not toggle Done")
        try await eventuallyOnMain("Done header disappears") { window.layout(); return !window.controls().contains { $0.label?.hasPrefix("Done,") == true } }
        try window.press("idle, idle")
        #expect(vm.selectedAgentID == fixtures[4].agent.id)
    }
}
