import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp
@testable import ShepherdSessions

@Suite("Project automation launch fencing", .mainActorExclusive)
@MainActor
struct ProjectAutomationAppTests {
    @Test func sidebarStopUsesCanonicalOwnershipAndPreservesAScopedLiveWatcher() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.projectsEnabled = true; app.server.setProjectsEnabled(true)  // the server is used before start, so the host opts in directly too
        let project = ProjectID(), automation = AutomationID()
        _ = try await app.server.logicalProjects(.create(projectID: project, name: "Project", goal: ""))
        _ = try await app.server.logicalProjects(.automation(projectID: project, expectedRevision: 1, automationID: automation,
            action: .create(draft: .init(name: "Watch", prompt: "hang", cwd: app.dir.path, enabled: true))))
        let space = Space(name: "Automations", path: app.dir.path, hidden: true)
        let watcher = try await app.liveAgent("Watch", in: space)
        // An already admitted watcher: the runtime adapter is not exercised by this Stop test.
        let server = app.server, agent = watcher.agent, tab = watcher.tab
        try await server.enqueue { @Sendable in
            try server.mutateState {
                $0.spaces.append(space)
                $0.agents.append(agent)
                $0.tabs.append(tab)
                $0.automations[0].agentID = agent.id
            }
        }
        let vm = try await app.start()
        let ready = try await app.readyThread(watcher.agent.id)
        _ = try await app.server.nativeThread(agentID: watcher.agent.id, request: .send(
            expectedSessionID: ready.piSessionID, generation: ready.generation,
            operationID: UUID(), text: "slow", delivery: .followUp))
        try await eventuallyAsync("watcher working") {
            guard case .snapshot(let snapshot) = try await app.server.nativeThread(agentID: watcher.agent.id, request: .snapshot()) else { return false }
            return snapshot.running
        }
        let before = app.server.state
        let session = try #require(watcher.piPane.sessionID)
        // The menu's mirrored row is stale. Ownership must come from the server, not this copy.
        vm.state.automations[0].projectID = nil
        vm.stopAutomation(automation)
        #expect(vm.remoteActionError == "Use the Project's revision-checked automation controls.")
        await app.settle()
        #expect(app.server.state.projects == before.projects)
        #expect(app.server.state.agents == before.agents)
        #expect(app.server.state.automations == before.automations)
        #expect(await app.server.sessionInfo(sessionID: session)?.isAlive == true)
        guard case .snapshot(let snapshot) = try await app.server.nativeThread(agentID: watcher.agent.id, request: .snapshot()) else {
            Issue.record("Scoped watcher thread disappeared"); return
        }
        #expect(snapshot.running)
    }

    @Test func runtimePauseImmediatelyRemovesPublishedScopedWatcherAndStopsOnlyItsProcess() async throws {
        let app = try AppHarness(); defer { app.stop() }
        app.settings.projectsEnabled = true; app.server.setProjectsEnabled(true)  // the server is used before start, so the host opts in directly too
        let vm = try await app.start()
        let project = ProjectID(), automation = AutomationID()
        _ = try await app.server.logicalProjects(.create(projectID: project, name: "Project", goal: ""))
        _ = try await app.server.logicalProjects(.automation(projectID: project, expectedRevision: 1, automationID: automation,
            action: .create(draft: .init(name: "Watch", prompt: "Watch", cwd: app.dir.path, enabled: true))))
        let watcherSpace = Space(name: "Automations", path: app.dir.path, hidden: true)
        let ordinarySpace = Space(name: "Ordinary work", path: app.dir.path)
        let watcher = try await app.liveAgent("Watch", in: watcherSpace)
        let worker = Fixture.agent("Ordinary worker", in: ordinarySpace)
        let server = app.server, watcherAgent = watcher.agent, watcherTab = watcher.tab
        try await server.enqueue { @Sendable in
            try server.mutateState {
                $0.spaces += [watcherSpace, ordinarySpace]
                $0.agents += [watcherAgent, worker.agent]; $0.tabs += [watcherTab, worker.tab]
                $0.automations[0].agentID = watcherAgent.id
            }
        }
        _ = try await app.readyThread(watcher.agent.id)
        let session = try #require(watcher.piPane.sessionID)
        let artifact = app.dir.appendingPathComponent("ordinary-worker-artifact")
        try Data("keep".utf8).write(to: artifact)
        let revision = try #require(server.state.projects.first?.revision)
        _ = try await vm.projectCoordinator.perform(projectID: project, expectedRevision: revision, request: .pause)
        #expect(server.state.agents == [worker.agent])
        #expect(server.state.tabs == [worker.tab])
        #expect(server.state.automations.first?.agentID == nil)
        #expect(try String(contentsOf: artifact, encoding: .utf8) == "keep")
        try await eventuallyAsync("runtime Pause terminates its watcher") { await server.sessionInfo(sessionID: session)?.isAlive != true }
        #expect(await server.automationRuns(automation).last?.result == .stopped)
        #expect(server.onProjectAutomationRun == nil, "Cleanup must not enable automation admission")
    }

    @Test func startupSkipsProjectOwnedAutomationsAndLegacyRunCannotBypassAdmission() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.projectsEnabled = true; app.server.setProjectsEnabled(true)  // the server is used before start, so the host opts in directly too
        let id = ProjectID(), automation = AutomationID()
        _ = try await app.server.logicalProjects(.create(projectID: id, name: "Project", goal: ""))
        _ = try await app.server.logicalProjects(.automation(projectID: id, expectedRevision: 1, automationID: automation,
            action: .create(draft: .init(name: "Watch", prompt: "hang", cwd: app.dir.path, enabled: true))))
        let vm = try await app.start()
        vm.autoStartAutomations()
        #expect(vm.startingAutomations.isEmpty)
        #expect(await app.server.listSessions().isEmpty)
        do { try await vm.startAutomation(automation); Issue.record("Expected Project scope refusal") }
        catch let error as LogicalProjectsError { #expect(error.code == "project_scope") }
        #expect(app.server.state.agents.isEmpty)
        #expect(app.server.state.automations.first?.agentID == nil)
        #expect(await app.server.listSessions().isEmpty)
    }
}
