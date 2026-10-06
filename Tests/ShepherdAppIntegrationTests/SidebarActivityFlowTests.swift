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

    @Test func publishedChildrenKeepADoneParentWorkingUntilTheLastChildSettlesWithoutChangingItsTurnStatus() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("workspace", path: app.dir.path)
        let parent = try await app.liveAgent("parent", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [parent]))
        _ = try await app.readyThread(parent.agent.id)
        let publisher = try ExtensionClient(path: app.scratch.socketPath)
        try publisher.send(.setAgentStatus(agentID: parent.agent.id, status: .done))
        try await eventuallyOnMain("the parent's completed turn") { vm.sidebarLists.done.count == 1 }
        let first = try #require(vm.sidebarLists.done.first?.completion)
        vm.markAllSidebarDoneSeen()
        let children = [ChildRun(runID: "first", label: "worker", state: "running"),
                        ChildRun(runID: "second", label: "reviewer", state: "running")]
        try publisher.send(.setAgentChildren(agentID: parent.agent.id, children: children))
        try await eventuallyOnMain("child work to put the parent in Working") { vm.sidebarLists.working.map(\.id) == [.local(parent.agent.id)] }
        #expect(vm.state.agents.first?.status == .done && app.server.state.agents.first?.status == .done)
        #expect(vm.sidebarLists.done.isEmpty && vm.sidebarLists.working.first?.completion == nil)
        #expect(vm.sidebarTree.projects.first?.rollup == .running)
        #expect(vm.sidebarCompletions.records[.local(parent.agent.id)]?.finished == false)
        var finished = children
        finished[0].state = "complete"
        try publisher.send(.setAgentChildren(agentID: parent.agent.id, children: finished))
        try await eventuallyOnMain("the first child to finish") { vm.children(of: parent.agent.id).first?.state == "complete" }
        #expect(vm.sidebarLists.working.count == 1 && vm.sidebarLists.done.isEmpty)
        finished[1].state = "failed"
        try publisher.send(.setAgentChildren(agentID: parent.agent.id, children: finished))
        try await eventuallyOnMain("the last child to finish and produce unseen Done") { vm.sidebarLists.done.count == 1 }
        let completion = try #require(vm.sidebarLists.done.first?.completion)
        #expect(completion != first)
        #expect(vm.sidebarTree.projects.first?.rollup == .quiet)
        #expect(vm.state.agents.first?.status == .done && app.server.state.agents.first?.status == .done)
        vm.applyAgentChildren(parent.agent.id, finished)
        #expect(vm.sidebarLists.done.first?.completion == completion, "a repeated publish is not another completion")
        vm.applyAgentChildren(parent.agent.id, [children[0]])
        #expect(vm.sidebarLists.working.count == 1)
        vm.childRuns.clear(agent: parent.agent.id)
        #expect(vm.sidebarLists.done.count == 1, "cleared child display state cannot strand the parent in Working")
    }

    @Test func remoteChildRefreshKeepsADoneParentWorkingAndThenCreatesAnUnseenCompletion() async throws {
        let app = try AppHarness(), remote = try RemoteHostHarness()
        defer { app.stop(); remote.stop() }
        let space = Fixture.space("remote", path: remote.host.dir.path)
        let parent = Fixture.agent("remote parent", in: space, status: .done)
        let hostVM = try await remote.host.start(with: Fixture.state(spaces: [space], agents: [parent]))
        let child = ChildRun(runID: "child", label: "worker", state: "running")
        hostVM.applyAgentChildren(parent.agent.id, [child])
        let vm = try await app.start()
        let connection = try await remote.connect(app.remoteHosts)
        let id = SidebarRowID.remote(.init(hostID: connection.id, agentID: parent.agent.id))
        try await eventuallyOnMain("remote child work to reach Working") { vm.sidebarLists.working.map(\.id) == [id] }
        #expect(vm.sidebarLists.done.isEmpty)
        #expect(vm.sidebarLists.working.first?.accessory == .tag(connection.config.name))
        #expect(vm.sidebarTree.projects.first?.rollup == .running)
        #expect(connection.state.agents.first?.status == .done && hostVM.state.agents.first?.status == .done)
        hostVM.applyAgentChildren(parent.agent.id, [ChildRun(runID: "child", label: "worker", state: "complete")])
        try await eventuallyOnMain("remote child completion") { vm.sidebarLists.done.map(\.id) == [id] }
        let first = try #require(vm.sidebarLists.done.first?.completion)
        vm.markAllSidebarDoneSeen()
        hostVM.applyAgentChildren(parent.agent.id, [child])
        try await eventuallyOnMain("remote child work to resume") { vm.sidebarLists.working.map(\.id) == [id] }
        hostVM.applyAgentChildren(parent.agent.id, [])
        try await eventuallyOnMain("remote removal to create another unseen completion") { vm.sidebarLists.done.map(\.id) == [id] }
        #expect(vm.sidebarLists.done.first?.completion != first)
        remote.host.server.stopRemoteListener()
        try await eventuallyOnMain("the host to disconnect") { connection.phase != .connected }
        #expect(vm.sidebarLists.working.isEmpty && vm.sidebarLists.done.isEmpty)
        #expect(vm.sidebarLists.recents.first?.id == id && vm.sidebarLists.recents.first?.offline == true)
    }

    @Test(arguments: [(false, "running"), (true, "running"), (true, "complete"), (true, "removed"), (true, "deleted")])
    func disconnectingOrReconnectingDuringRemoteChildWorkDoesNotInventACompletion(disconnect: Bool, childState: String) async throws {
        let app = try AppHarness(), remote = try RemoteHostHarness()
        defer { app.stop(); remote.stop() }
        let space = Fixture.space("remote", path: remote.host.dir.path)
        let parent = Fixture.agent("remote parent", in: space, status: .done)
        let hostVM = try await remote.host.start(with: Fixture.state(spaces: [space], agents: [parent]))
        let vm = try await app.start()
        let connection = try await remote.connect(app.remoteHosts)
        let id = SidebarRowID.remote(.init(hostID: connection.id, agentID: parent.agent.id))
        try await eventuallyOnMain("the parent's initial completion") { vm.sidebarLists.done.map(\.id) == [id] }
        vm.markAllSidebarDoneSeen()
        let child = ChildRun(runID: "child", label: "worker", state: "running")
        hostVM.applyAgentChildren(parent.agent.id, [child])
        try await eventuallyOnMain("live remote child work") { vm.sidebarLists.working.map(\.id) == [id] }
        let before = try #require(vm.sidebarCompletions.records[id])
        #expect(!before.finished)

        if disconnect {
            remote.host.server.stopRemoteListener()
            try await eventuallyOnMain("the host to disconnect") { connection.phase != .connected }
        } else {
            app.remoteHosts.reconnect(id: connection.id)
        }
        #expect(connection.children[parent.agent.id] == [child], "the last child snapshot stays cached offline")
        #expect(vm.sidebarCompletions.records[id] == before, "disconnection is not a completed turn")
        #expect(vm.sidebarLists.done.isEmpty && vm.sidebarLists.working.isEmpty)
        #expect(vm.sidebarLists.recents.first?.id == id && vm.sidebarLists.recents.first?.offline == true)

        if childState == "deleted" {
            try await remote.host.server.putState(ShepherdState(spaces: [space]))
        } else if childState != "running" {
            hostVM.applyAgentChildren(parent.agent.id, childState == "removed" ? [] :
                [ChildRun(runID: "child", label: "worker", state: childState)])
        }
        if disconnect {
            _ = try remote.host.server.startRemoteListener(port: remote.port,
                tokenURL: remote.host.dir.appendingPathComponent("remote-token"))
            app.remoteHosts.reconnect(id: connection.id)
        }
        if childState == "deleted" {
            try await eventuallyOnMain("reconnection to prune the deleted parent's cached children") {
                connection.phase == .connected && connection.state.agents.isEmpty && connection.children.isEmpty
            }
            #expect(vm.sidebarCompletions.records[id] == nil && vm.sidebarLists.all.isEmpty)
        } else {
            if childState == "running" {
                try await eventuallyOnMain("reconnection to restore live child work") {
                    connection.phase == .connected && vm.sidebarLists.working.map(\.id) == [id]
                }
                #expect(vm.sidebarCompletions.records[id] == before, "reconnecting to the same live child is not another completion")
                hostVM.applyAgentChildren(parent.agent.id, [ChildRun(runID: "child", label: "worker", state: "complete")])
            }
            try await eventuallyOnMain("the fresh child's actual completion") { vm.sidebarLists.done.map(\.id) == [id] }
            #expect(connection.children[parent.agent.id] == (childState == "removed" ? [] :
                [ChildRun(runID: "child", label: "worker", state: "complete")]))
            #expect(connection.state.agents.first?.status == .done && hostVM.state.agents.first?.status == .done)
            #expect(vm.sidebarLists.done.first?.completion == before.generation + 1, "only the real child completion advances the generation")
            let completed = vm.sidebarCompletions.records[id]
            app.remoteHosts.reconnect(id: connection.id)
            try await eventuallyOnMain("the settled host to reconnect") { connection.phase == .connected }
            #expect(vm.sidebarCompletions.records[id] == completed, "reconnecting after completion does not count it twice")
        }
        app.remoteHosts.removeHost(id: connection.id)
        #expect(app.remoteHosts.connections.isEmpty && connection.browserClient == nil)
        #expect(vm.sidebarCompletions.records[id] == nil && vm.sidebarLists.all.isEmpty)
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
                        Fixture.agent("working", in: space, order: 2),
                        Fixture.agent("finished", in: space, order: 3, status: .done), Fixture.agent("idle", in: space, order: 4)]
        var state = Fixture.state(spaces: [space], agents: fixtures)
        state.designs = [Design(name: "Dashboard", createdAt: 1, lastActiveAt: 2, boardCount: 4)]
        let vm = try await app.start(with: state)
        vm.settings.designToolEnabled = true
        vm.pinThread(.local(fixtures[0].agent.id))
        var completed = vm.state
        completed.agents[2].status = .done
        vm.adopt(completed)
        vm.applyAgentChildren(fixtures[2].agent.id, [ChildRun(runID: "child", label: "worker", state: "running")])
        #expect(vm.sidebarActivityItems.first == .header(.done, count: 1, collapsed: false))
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
        let startingRow = try window.press("working, running")
        withKnownIssue("Compact sidebar rows are 22pt, below the 24pt desktop hit area") {
            #expect(startingRow.frame.height >= HitArea.desktop.minimum)
        } when: { density == .compact }
        #expect(vm.selectedAgentID == fixtures[2].agent.id)
        #expect(vm.sidebarLists.working.map(\.id) == [.local(fixtures[2].agent.id)])
        #expect(vm.state.agents[2].status == .done, "the working row reflects children, not a rewritten parent turn")
        try window.press("finished, done")
        #expect(vm.selectedAgentID == fixtures[3].agent.id)
        #expect(vm.sidebarLists.done.count == 1, "opening Done does not mark it seen")
        let expandedButton = try window.press("Mark all seen")
        #expect(expandedButton.frame.height >= HitArea.desktop.minimum)
        #expect(vm.sidebarLists.done.isEmpty)
        #expect(vm.selectedAgentID == fixtures[3].agent.id, "Mark all seen does not change selection")
        #expect(!vm.collapsedActivitySections.contains(.done))
        #expect(vm.sidebarActivityItems.first == .header(.pinned, count: 1, collapsed: false))
        var next = vm.state
        let index = try #require(next.agents.firstIndex { $0.id == fixtures[3].agent.id })
        next.agents[index].status = .working
        vm.adopt(next)
        next.agents[index].status = .done
        vm.adopt(next)
        #expect(vm.sidebarLists.done.count == 1, "a new completion returns to Done")
        #expect(vm.sidebarActivityItems.first == .header(.done, count: 1, collapsed: false))
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
        vm.applyAgentChildren(fixtures[2].agent.id, [ChildRun(runID: "child", label: "worker", state: "complete")])
        vm.toggleActivitySection(.done)
        try await eventuallyOnMain("the parent row to enter Done after its child finishes") { window.layout(); return window.controls().contains { $0.label == "working, done" } }
        try window.press("working, done")
        #expect(vm.selectedAgentID == fixtures[2].agent.id)
        try window.press("idle, idle")
        #expect(vm.sidebarLists.done.isEmpty && vm.sidebarLists.recents.contains { $0.id == .local(fixtures[2].agent.id) })
    }
}
