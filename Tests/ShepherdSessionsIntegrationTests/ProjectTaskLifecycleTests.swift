import Foundation
import CryptoKit
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Terminal Project assignments", .integrationTimeLimit)
struct ProjectTaskLifecycleTests {
    typealias Rig = ProjectRuntimeTests.Rig

    @Test(arguments: ["hot", "retired", "reloaded"])
    func resolvedFollowUpsRefuseAcrossOwnerToolAndRemoteRoutesWithoutLosingHistory(storage: String) async throws {
        let initial = try Rig(); defer { initial.stop() }
        let project = try await initial.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await initial.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Original assignment", prompt: "hello"))
        try await eventually("original turn settled, assignment unresolved") { initial.host.server.state.projects.first?.tasks.first?.phase == .settled }
        let original = try #require(initial.host.server.state.projects.first?.tasks.first)
        let worker = try #require(initial.agents.current[original.workerAgentID])
        let follow = ProjectRuntimeRequest.followUp(taskID: original.id, operationID: UUID(), text: "tools:1", thinking: "high")
        _ = try await initial.perform(project.id, follow)
        try await eventually("same-task follow-up consumed") { worker.stdin("prompt").count == 2 }
        try await eventually("follow-up publication authority") {
            try await initial.host.server.enqueue { (try? initial.host.server.publicationAuthority(original.workerAgentID)) != nil }
        }
        let bytes = Data("retained assignment artifact".utf8)
        try bytes.write(to: initial.host.dir.appendingPathComponent("source.txt"))
        let published = try await initial.host.server.projectPublish(original.workerAgentID,
            request: .publish(publicationID: UUID(), sourcePath: "source.txt", artifactName: "result.txt"))
        let artifact = try #require(published.artifact)
        try Data().write(to: initial.host.dir.appendingPathComponent("tool-1"))
        try await eventually("follow-up settled without resolving assignment") { initial.host.server.state.projects.first?.tasks.first?.phase == .settled }
        let iterated = try #require(initial.host.server.state.projects.first?.tasks.first)
        #expect(iterated.workerAgentID == original.workerAgentID && iterated.workerSessionID == original.workerSessionID)
        #expect(iterated.operationID == follow.operationID && iterated.thinking == "high")
        #expect(initial.agents.current.count == 1)
        _ = try await initial.perform(project.id, .resolve(taskID: original.id, operationID: UUID()))
        if storage != "hot" {
            // Private constructed history, not live user data. Exercise actual ledger retirement.
            try await initial.host.server.enqueue {
                try initial.host.server.store.update { state in
                    // Mirror the app launcher's persisted worker binding for historical open/read.
                    if let i = state.agents.firstIndex(where: { $0.id == original.workerAgentID }) {
                        state.agents[i].projectWorkerFor = project.id
                        state.agents[i].piSessionID = original.workerSessionID
                    }
                    for i in 0..<24 {
                        state.projects[0].tasks.append(.init(operationID: UUID(), spaceID: space, title: "Closed \(i)", prompt: "fixture", phase: .resolved))
                    }
                    state.projects[0].revision += 1
                }
                try initial.host.server.store.update { $0.projects[0].revision += 1 }
            }
            #expect(!initial.host.server.state.projects[0].tasks.contains { $0.id == original.id })
            #expect(initial.host.server.state.projects[0].referencedTasks.contains { $0.taskID == original.id })
        }
        let rig: Rig
        if storage == "reloaded" {
            let dir = initial.host.dir
            initial.host.server.onProjectRuntimeLaunch = nil; initial.host.stop(keepFiles: true)
            rig = try Rig(dir: dir)
            #expect(await rig.host.server.listSessions().isEmpty)
        } else { rig = initial }
        defer { rig.stop() }
        // The stub recognizes tools:1 even inside quoted receipts. Release that fixture gate
        // in the coordinator cwd too, without rewriting retained evidence or bypassing delivery.
        try Data().write(to: rig.host.dir.appendingPathComponent("logical-projects/\(project.id)/tool-1"))
        // Restore only the coordinator's ordinary conversation, never the resolved worker.
        _ = try await rig.perform(project.id, .message(operationID: UUID(), text: "Read retained task evidence"))
        try await eventually("coordinator consumed retained events") {
            rig.host.server.state.projects[0].messages.allSatisfy { $0.phase == .delivered }
        }
        let before = rig.host.server.state.projects[0], coordinator = try #require(before.coordinatorAgentID)
        let launchedBefore = Set(rig.agents.current.keys)
        let newFollow = ProjectRuntimeRequest.followUp(taskID: original.id, operationID: UUID(), text: "unrelated new assignment", model: "invalid/never-applied", thinking: "low")
        for request in [newFollow, .reopen(taskID: original.id)] {
            do {
                _ = try await rig.host.server.projectRuntime(project.id, expectedRevision: before.revision, request: request)
                Issue.record("Resolved assignment accepted a fresh mutation")
            } catch let error as LogicalProjectsError {
                #expect(error.code == "task_resolved" && error.description.contains("project_assign"))
            }
        }
        let extensionClient = try ExtensionClient(path: rig.host.socketPath)
        defer { extensionClient.closeConnection() }
        try extensionClient.send(.projectRuntime(id: 71, agentID: coordinator, projectID: project.id, expectedRevision: before.revision, request: newFollow))
        guard case .error(71, "task_resolved", let guidance) = try extensionClient.readReply() else { throw WireError("Expected authoritative tool refusal") }
        #expect(guidance.contains("project_assign"))
        let server = rig.host.server
        server.onProjectRuntimeRequest = { _, done in done(.failure(WireError("Action must use owner admission, not the UI callback"))) }
        defer { server.onProjectRuntimeRequest = nil }
        let tokenURL = rig.host.dir.appendingPathComponent("remote-token")
        let port = try server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = RemoteHostClient(); defer { remote.disconnect() }
        _ = try await remote.connect(host: "127.0.0.1", port: port, token: token, clientName: "lifecycle viewer")
        for request in [newFollow, .reopen(taskID: original.id)] {
            do {
                _ = try await remote.projectRuntime(.action(projectID: project.id, expectedRevision: before.revision, request: request))
                Issue.record("Remote owner revived a resolved task")
            } catch RemoteHostClientError.rejected(let code, let message) {
                #expect(code == "task_resolved" && message.contains("project_assign"))
            }
        }
        // An accepted operation replays before the terminal-state check, even with an old revision.
        let replay = try await server.projectRuntime(project.id, expectedRevision: 1, request: follow)
        #expect(replay.operationReceipt?.operationID == follow.operationID)
        _ = try await remote.projectRuntime(.action(projectID: project.id, expectedRevision: 1, request: follow))
        try extensionClient.send(.projectRuntime(id: 72, agentID: coordinator, projectID: project.id, expectedRevision: 1, request: follow))
        guard case .projectRuntime(72, let toolReplay, _, _) = try extensionClient.readReply() else { throw WireError("Expected accepted tool operation replay") }
        #expect(toolReplay.operationReceipt?.operationID == follow.operationID)
        let routed = try await server.projectRuntime(project.id, expectedRevision: before.revision, request: .worker(taskID: original.id))
        #expect(routed.tasks.first?.phase == .resolved && routed.tasks.first?.workerSessionID == original.workerSessionID)
        let inspected = try await server.projectRuntime(project.id, expectedRevision: before.revision, request: .inspect(taskID: original.id))
        #expect(inspected.tasks.first?.operationID == follow.operationID)
        let history = try await server.projectRuntime(project.id, expectedRevision: before.revision, request: .history(taskID: original.id))
        #expect(history.historyPage?.contains { $0.source?.operationID == follow.operationID } == true)
        let result = try await server.projectRuntime(project.id, expectedRevision: before.revision,
            request: .result(taskID: original.id, operationID: try #require(follow.operationID)))
        #expect(result.resultPage?.availability == .complete && result.resultPage?.data.isEmpty == false)
        #expect(result.resultPage?.identity?.source.workerAgentID == original.workerAgentID)
        guard case .file(let file) = try await server.logicalProjects(.read(projectID: project.id, path: "result.txt")),
              case .files(let files) = try await server.logicalProjects(.files(projectID: project.id, path: "")) else { throw WireError("Resolved artifact read") }
        #expect(file.data == bytes && files.entries.first?.taskID == original.id)
        #expect(server.state.projects[0].artifacts == [artifact])
        #expect(server.state.projects[0] == before, "Refusal/replay/read must not restore an archived task, alter identities or commit anything")
        #expect(worker.stdin("prompt").count == 2 && worker.stdin("set_thinking_level").last?["level"] as? String == "high")
        #expect(Set(rig.agents.current.keys) == launchedBefore, "No refusal or replay may launch or restore a worker")
        #expect(rig.agents.current.keys.allSatisfy { storage != "reloaded" || $0 == coordinator }, "Reload/replay must not launch the resolved worker")
    }

    @Test func aNewAssignmentGetsAFreshTaskWorkerAndNativeConversation() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "First", prompt: "original-only-context"))
        try await eventually("first settled") { rig.host.server.state.projects[0].tasks.first?.phase == .settled }
        let first = try #require(rig.host.server.state.projects[0].tasks.first)
        _ = try await rig.perform(project.id, .resolve(taskID: first.id))
        let operation = UUID()
        let request = ProjectRuntimeRequest.assign(operationID: operation, spaceID: space, title: "Next assignment", prompt: "short explicit handoff; read prior result by its operation ID")
        _ = try await rig.perform(project.id, request)
        try await eventually("fresh assignment settled") { rig.host.server.state.projects[0].tasks.last?.phase == .settled }
        let next = try #require(rig.host.server.state.projects[0].tasks.last)
        #expect(next.id != first.id && next.workerAgentID != first.workerAgentID && next.workerSessionID != first.workerSessionID)
        let pi = try #require(rig.agents.current[next.workerAgentID])
        let snapshot = try await pi.snapshot("new worker conversation") { !$0.running && !$0.messages.isEmpty }
        #expect(pi.stdin("prompt").count == 1)
        #expect(!String(decoding: try JSONEncoder().encode(snapshot.messages), as: UTF8.self).contains("original-only-context"))
        #expect(rig.agents.current.count == 2 && rig.host.server.state.projects[0].tasks.first?.phase == .resolved)
        _ = try await rig.host.server.projectRuntime(project.id, expectedRevision: project.revision, request: request)
        #expect(pi.stdin("prompt").count == 1 && rig.host.server.state.projects[0].tasks.count == 2)
    }

    @Test func resolutionWinsAgainstAFollowUpWaitingOnAnOldRevision() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Resolve race", prompt: "hello"))
        try await eventually("settled before race") { rig.host.server.state.projects[0].tasks.first?.phase == .settled }
        let before = rig.host.server.state.projects[0], task = try #require(before.tasks.first)
        let entered = Locked(false), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("write I/O gated") { entered.current }
        let resolving = Task { try await rig.host.server.projectRuntime(project.id, expectedRevision: before.revision, request: .resolve(taskID: task.id)) }
        try await eventually("resolution staged") { try await rig.host.server.enqueue { rig.host.server.projectRuntimeWriterBusy && rig.host.server.logicalProjectSaveCount == 1 } }
        let request = ProjectRuntimeRequest.followUp(taskID: task.id, operationID: UUID(), text: "must not send", thinking: "low")
        let following = Task { try await rig.host.server.projectRuntime(project.id, expectedRevision: before.revision, request: request) }
        try await eventually("follow-up waiting behind resolution") { try await rig.host.server.enqueue { rig.host.server.projectRuntimeWriters.count == 1 } }
        gate.signal()
        let resolved = try await resolving.value
        do { _ = try await following.value; Issue.record("Stale follow-up reopened a resolved assignment") }
        catch let error as LogicalProjectsError { #expect(error.code == "stale_project") }
        do { _ = try await rig.perform(project.id, request); Issue.record("Fresh retry reopened a resolved assignment") }
        catch let error as LogicalProjectsError { #expect(error.code == "task_resolved") }
        #expect(rig.host.server.state.projects[0] == resolved)
        #expect(rig.agents.current[task.workerAgentID]?.stdin("prompt").count == 1)
    }

    @Test(arguments: [true, false])
    func legacyAcceptedResolvedFollowUpReplaysWithoutReopeningOrRedispatch(retainedPayloadProof: Bool) async throws {
        let rig = try Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID)
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space, title: "Legacy", prompt: "hello"))
        try await eventually("legacy initial turn settled") { rig.host.server.state.projects[0].tasks.first?.phase == .settled }
        let task = try #require(rig.host.server.state.projects[0].tasks.first)
        _ = try await rig.perform(project.id, .resolve(taskID: task.id))
        let operation = UUID(), request = ProjectRuntimeRequest.followUp(taskID: task.id, operationID: UUID(), text: "accepted by the old contract", thinking: "high")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let command = ProjectCommandReceipt(operationID: try #require(request.operationID), sha256: SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined())
        // Construct an old-version accepted operation with exact replay proof. This is not a new admission.
        _ = try await rig.host.server.updateRuntimeProject(project.id) { p in
            p.tasks[0].previousOperations = [task.operationID]
            p.tasks[0].operationID = command.operationID; p.tasks[0].nativeDeliveryID = operation
            p.tasks[0].prompt = "accepted by the old contract"; p.tasks[0].thinking = "high"
            p.tasks[0].phase = .queued; p.tasks[0].revision += 1
            p.commandReceipt = retainedPayloadProof ? command : nil
        }
        _ = try await rig.host.server.updateRuntimeProject(project.id) { p in
            p.tasks[0].phase = .resolved; p.tasks[0].revision += 1
            p.tasks[0].error = "Retained old-operation diagnostic, not permission to retry"
        }
        let before = rig.host.server.state.projects[0]
        let replay = try await rig.host.server.projectRuntime(project.id, expectedRevision: 1, request: request)
        if retainedPayloadProof {
            #expect(replay.operationReceipt?.operationID == request.operationID)
            #expect(replay.operationReceipt?.task?.nativeDeliveryID == operation)
        } else {
            #expect(replay.tasks.first?.operationID == request.operationID && replay.tasks.first?.nativeDeliveryID == operation)
            #expect(replay.tasks.first?.phase == .resolved, "Older hot operation proof returns current terminal state, not a reopened task")
        }
        #expect(rig.host.server.state.projects[0] == before)
        #expect(rig.agents.current[task.workerAgentID]?.stdin("prompt").count == 1)
        do {
            _ = try await rig.perform(project.id, .followUp(taskID: task.id, operationID: UUID(), text: "accepted by the old contract"))
            Issue.record("A fresh identity must not reuse legacy permission")
        } catch let error as LogicalProjectsError { #expect(error.code == "task_resolved") }
        #expect(rig.host.server.state.projects[0] == before)
    }
}
