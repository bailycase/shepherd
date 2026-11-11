import Foundation
import AppKit
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdSessions
@testable import ShepherdApp

@Suite("Project executor app adapter", .mainActorExclusive)
@MainActor
struct ProjectExecutionFlowTests {
    @Test func explicitFollowupRestoresRealPriorHistoryWithoutCreatingAnAgentOrSeedingMissingHistory() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness(); defer { app.stop() }
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment; set before start so the view model's binding applies it
        let messages = app.dir.appendingPathComponent("retained-stub-messages.json")
        try JSONSerialization.data(withJSONObject: ["messagesFile": messages.path]).write(to: app.dir.appendingPathComponent("stub-pi-startup.json"))
        var vm = try await app.start()
        let space = Space(name: "Executor", path: app.dir.path)
        try await app.server.addSpace(space)
        let first = ProjectExecutionAssignment(key: .init(ownerID: UUID(), projectID: ProjectID(), operationID: UUID()),
            taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: space.id, title: "Retained worker", prompt: "tools:0")
        _ = try await app.server.projectExecution(.execute(first))
        try await eventuallyAsync("first real launch settled") { app.server.state.projectExecutions.first?.phase == .settled }
        let proof = try #require(app.server.state.projectExecutions.first)
        let session = try #require(proof.sessionID)
        // The real status extension publishes this; the stub's native session is deliberately named stub-session.
        let extensionClient = try ExtensionClient(path: app.scratch.socketPath)
        try extensionClient.send(.setAgentSession(agentID: first.reservedWorkerID, piSessionID: session))
        try await eventuallyAsync("native session identity retained") { app.server.state.agents.first?.effectivePiSessionID == session }
        // Encode the stub's actual persisted message producer in pi's JSONL container, not invented result text.
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: messages)) as? [[String: Any]])
        let folder = PiSessionFile.projectDirectory(forCwd: space.path, sessionsRoot: app.server.pi.sessionsRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("2026-10-10_\(session).jsonl")
        var lines = [[String: Any]]()
        lines.append(["type": "session", "version": 3, "id": session, "cwd": space.path])
        for (index, message) in raw.enumerated() {
            var entry: [String: Any] = ["type": "message", "id": "entry-\(index)", "message": message]
            if index > 0 { entry["parentId"] = "entry-\(index - 1)" }
            lines.append(entry)
        }
        var data = Data()
        for line in lines { data += try JSONSerialization.data(withJSONObject: line); data += Data("\n".utf8) }
        try data.write(to: file)
        app.server.stop()
        try app.server.start()
        vm = try await app.start()
        var second = first; second.key.operationID = UUID(); second.prompt = "tools:0 explicit continuation"
        _ = try await app.server.projectExecution(.execute(second))
        try await eventuallyAsync("explicit idle restore and follow-up") {
            app.server.state.projectExecutions.first { $0.key == second.key }?.phase.active == false
        }
        let continued = try #require(app.server.state.projectExecutions.first { $0.key == second.key })
        try #require(continued.phase == .settled, "\(continued.outcome ?? "No outcome")")
        #expect(app.server.state.agents.count == 1)
        #expect(StubPi.launches().filter { $0.argv.contains(first.reservedWorkerID.rawValue) || $0.argv.contains(session) }.count == 2)
        #expect(vm.selectedAgentID == nil)
        let lastLaunch = try #require(StubPi.launches().last { $0.argv.contains(session) })
        #expect(!lastLaunch.argv.contains("--model"))
        app.server.stop()
        try FileManager.default.removeItem(at: file)
        try app.server.start()
        vm = try await app.start()
        var third = first; third.key.operationID = UUID(); third.prompt = "tools:0 cannot resurrect missing history"
        _ = try await app.server.projectExecution(.execute(third))
        try await eventuallyAsync("missing history refused") {
            app.server.state.projectExecutions.first { $0.key == third.key }?.phase == .failed
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(PiSessionFile.file(sessionID: session, cwd: space.path, sessionsRoot: app.server.pi.sessionsRoot) == nil)
        #expect(app.server.state.agents.count == 1)
        #expect(await app.server.listSessions().isEmpty)
    }

    @Test func executorNeverSendsProjectDataWhenNativeModelDiffersFromOwnersSelection() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness(); defer { app.stop() }
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment; set before start so the view model's binding applies it
        let messages = app.dir.appendingPathComponent("empty-messages.json")
        try Data("[]".utf8).write(to: messages)
        try JSONSerialization.data(withJSONObject: ["messagesFile": messages.path]).write(to: app.dir.appendingPathComponent("stub-pi-startup.json"))
        _ = try await app.start()
        let space = Space(name: "Executor", path: app.dir.path)
        try await app.server.addSpace(space)
        let assignment = ProjectExecutionAssignment(key: .init(ownerID: UUID(), projectID: ProjectID(), operationID: UUID()),
            taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: space.id,
            title: "Selected provider", prompt: "Private project data", model: "stub/model-b")
        _ = try await app.server.projectExecution(.execute(assignment))
        try await eventuallyAsync("native provider mismatch refused") { app.server.state.projectExecutions.first?.phase == .failed }
        #expect(app.server.state.projectExecutions.first?.matchedUserEntryID == nil)
        let native = try await app.readyThread(assignment.reservedWorkerID)
        #expect(native.messages.isEmpty)
    }

    @Test func reservedOrdinaryWorkerUsesExactSpaceAndModelWithoutSelectionOrOpeningPrompt() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness(); defer { app.stop() }
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment; set before start so the view model's binding applies it
        try Data(#"{"model":{"provider":"stub","id":"model-b"}}"#.utf8).write(to: app.dir.appendingPathComponent("stub-pi-startup.json"))
        let vm = try await app.start()
        let space = Space(name: "Executor", path: app.dir.path)
        try await app.server.addSpace(space)
        let assignment = ProjectExecutionAssignment(key: .init(ownerID: UUID(), projectID: ProjectID(), operationID: UUID()),
            taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: space.id,
            title: "Ordinary task", prompt: "tools:0", instructions: "Use existing tests.", model: "stub/model-b")
        let selected = vm.selectedAgentID
        let keyWindow = NSApplication.shared.keyWindow
        _ = try await app.server.projectExecution(.execute(assignment))
        try await eventuallyAsync("app executor settled") {
            app.server.state.projectExecutions.first { $0.key == assignment.key }?.phase == .settled
        }
        let agent = try #require(app.server.state.agents.first { $0.id == assignment.reservedWorkerID })
        #expect(agent.coordinatorFor == nil && agent.spaceID == space.id)
        #expect(vm.selectedAgentID == selected)
        #expect(NSApplication.shared.keyWindow === keyWindow)
        let launch = try #require(StubPi.launches().last { $0.argv.contains(assignment.reservedWorkerID.rawValue) })
        #expect(launch.argv.contains("stub/model-b"))
        #expect(!launch.argv.contains("tools:0"))
        #expect(launch.env["SHEPHERD_PROJECT_COORDINATOR"] != "1")
        #expect(app.server.state.spaces.count == 1)
        #expect(app.server.state.projectExecutions.first?.matchedUserEntryID != nil)
    }
}
