import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Project coordinator owner launch", .mainActorExclusive)
@MainActor
struct ProjectCoordinatorFlowTests {
    @Test func aRemoteViewerUsesTheOwnersControllerAndReadsItsNativeCoordinatorWithoutAFleetRow() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness(); defer { app.stop() }
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment; set before start so the view model's binding applies it
        _ = try await app.start()
        let tokenURL = app.dir.appendingPathComponent("project-viewer-token")
        let port = try app.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let viewer = RemoteHostClient(); defer { viewer.disconnect() }
        _ = try await viewer.connect(host: "127.0.0.1", port: port, token: token, clientName: "Project viewer")
        #expect(viewer.capabilities.contains(RemoteProtocol.logicalProjectRuntimeCapability))
        let space = Space(name: "Owner source", path: app.dir.path)
        try await app.server.addSpace(space)
        guard case .project(let p) = try await viewer.logicalProjects(.create(projectID: ProjectID(), name: "Owner project", goal: "Only assigned work", linkedSpaceIDs: [space.id])) else { Issue.record("Missing project"); return }
        guard case .project(let sent) = try await viewer.projectRuntime(.action(projectID: p.id, expectedRevision: p.revision, request: .message(operationID: UUID(), text: "Remote assigned work"))) else { Issue.record("Missing runtime reply"); return }
        let coordinator = try #require(sent.coordinatorAgentID)
        try await eventuallyAsync("remote native owner conversation") {
            guard case .native(.snapshot(let snapshot)) = try? await viewer.projectRuntime(.conversation(projectID: p.id, request: .snapshot())) else { return false }
            return !snapshot.running && !snapshot.messages.isEmpty
        }
        #expect(app.server.state.agents.contains { $0.id == coordinator && $0.coordinatorFor == p.id })
        let secondViewer = RemoteHostClient(); defer { secondViewer.disconnect() }
        let fleet = try await secondViewer.connect(host: "127.0.0.1", port: port, token: token, clientName: "Second viewer")
        #expect(!fleet.agents.contains { $0.id == coordinator })
        guard case .hosts(let hosts) = try await viewer.projectRuntime(.hosts) else { Issue.record("Missing owner host options"); return }
        #expect(hosts.first?.reference == .local)
        #expect(hosts.first?.name.isEmpty == false)
        let operation = UUID()
        try await eventuallyAsync("remote assignment admitted on owner") {
            guard case .project(let current) = try? await viewer.logicalProjects(.get(projectID: p.id)) else { return false }
            return (try? await viewer.projectRuntime(.action(projectID: p.id, expectedRevision: current.revision,
                request: .assign(operationID: operation, spaceID: space.id, title: "Owner question", prompt: "ask")))) != nil
        }
        try await eventuallyAsync("owner worker asks") { app.server.state.projects.first?.tasks.first?.phase == .waiting }
        let task = try #require(app.server.state.projects.first?.tasks.first)
        guard case .snapshot(let asked) = try await viewer.nativeThread(agentID: task.workerAgentID, request: .snapshot()) else { Issue.record("Missing native worker question"); return }
        #expect(asked.dialogs.first?.id == "uuid-2")
        let answer = NativeThreadRequest.answer(expectedSessionID: asked.piSessionID, generation: asked.generation, operationID: UUID(), dialogID: "uuid-2", answer: .confirm(value: true))
        try await eventuallyAsync("remote Project answer routes to original owner worker") {
            guard case .project(let current) = try? await viewer.logicalProjects(.get(projectID: p.id)),
                  case .native(.accepted) = try? await viewer.projectRuntime(.answer(projectID: p.id, expectedRevision: current.revision, taskID: task.id, request: answer)) else { return false }
            return true
        }
        try await eventuallyAsync("remote owner's worker settles") { app.server.state.projects.first?.tasks.first?.phase == .settled }
        #expect(app.server.state.agents.contains { $0.id == task.workerAgentID })
    }

    @Test func actualAppLauncherKeepsTheCoordinatorIsolatedAndDoesNotSelectAnOrdinaryThread() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness(modelCatalog: { .init(models: ["anthropic/claude-opus-4-5", "anthropic/claude-sonnet-4-5"], defaultModel: "anthropic/claude-opus-4-5") }); defer { app.stop() }
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment; set before start so the view model's binding applies it
        let vm = try await app.start()
        let id = ProjectID()
        guard case .project(let project) = try await app.server.logicalProjects(.create(projectID: id, name: "Project", goal: "Only assigned work")) else { Issue.record("Missing project"); return }
        let settings = LogicalProjectSettings(conversationModel: "anthropic/claude-opus-4-5", threadModel: "anthropic/claude-sonnet-4-5", instructions: "Use the existing tests.")
        guard case .project(let configured) = try await app.server.logicalProjects(.settings(projectID: id, expectedRevision: project.revision, settings: settings)) else { Issue.record("Missing settings"); return }
        let sent = try await vm.projectCoordinator.sendProjectMessage(projectID: id, expectedRevision: configured.revision, operationID: UUID(), text: "hello")
        let coordinator = try #require(sent.coordinatorAgentID)
        try await eventuallyAsync("coordinator session through the app") {
            StubPi.launches().contains { $0.argv.contains(coordinator.rawValue) }
        }
        let launch = try #require(StubPi.launches().last { $0.argv.contains(coordinator.rawValue) })
        #expect(launch.argv.contains("--no-tools") && launch.argv.contains("--no-extensions"))
        #expect(launch.argv.contains("--no-skills") && launch.argv.contains("--no-context-files"))
        #expect(launch.argv.contains("anthropic/claude-opus-4-5"))
        #expect(!launch.argv.contains { $0.hasSuffix("shepherd-panes.ts") || $0.hasSuffix("shepherd-browser.ts") || $0.hasSuffix("shepherd-children.ts") })
        #expect(launch.env["SHEPHERD_PROJECT_COORDINATOR"] == "1")
        #expect(launch.env["SHEPHERD_PROJECT_CONTEXT"]?.contains(project.id.rawValue) == true)
        #expect(launch.env["SHEPHERD_PROJECT_CONTEXT"]?.contains("Use the existing tests.") == false, "Instructions and memory refresh from the owner each turn, not the launch environment")
        #expect(vm.selectedAgentID == nil)
        #expect(app.server.state.agents.first { $0.id == coordinator }?.coordinatorFor == id)
        #expect(!ShepherdViewModel.peerInfos(in: app.server.state, sender: coordinator).contains { $0.id == coordinator }, "A live coordinator must not leak its private cwd through agent_list")
        #expect(vm.projectCoordinator.conversationStore(agentID: coordinator) === vm.threadStores.store(for: coordinator))
        try await eventuallyAsync("coordinator message committed") { app.server.state.projects.first?.messages.first?.phase == .delivered }
        try await eventuallyAsync("coordinator settled") {
            guard case .snapshot(let snapshot) = try? await app.server.nativeThread(agentID: coordinator, request: .snapshot()) else { return false }
            return !snapshot.running && snapshot.model == "anthropic/claude-opus-4-5"
        }
        var changed = settings; changed.conversationModel = "anthropic/claude-sonnet-4-5"
        let ready = try #require(app.server.state.projects.first)
        guard case .project(let updated) = try await app.server.logicalProjects(.settings(projectID: id, expectedRevision: ready.revision, settings: changed)) else { Issue.record("Missing settings"); return }
        _ = try await vm.projectCoordinator.sendProjectMessage(projectID: id, expectedRevision: updated.revision, operationID: UUID(), text: "Use updated model")
        try await eventuallyAsync("live model choice applied to next turn") {
            guard case .snapshot(let snapshot) = try? await app.server.nativeThread(agentID: coordinator, request: .snapshot()) else { return false }
            return !snapshot.running && snapshot.model == "anthropic/claude-sonnet-4-5" && app.server.state.projects.first?.messages.last?.phase == .delivered
        }
        let current = try #require(app.server.state.projects.first)
        _ = try await app.server.logicalProjects(.delete(projectID: id, expectedRevision: current.revision))
        #expect(!app.server.state.agents.contains { $0.id == coordinator })
        #expect(FileManager.default.fileExists(atPath: app.dir.appendingPathComponent("logical-projects/\(id)").path))
    }
}
