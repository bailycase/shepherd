import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project history review regressions", .serialized)
struct ProjectHistoryReviewTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func artifactAndProposalReferencesSurviveManyTaskRetirementsAndReloads() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json"), store = StateStore(url: url)
        var first: ProjectTask?
        for i in 0..<160 {
            try store.update { state in
                if state.projects.isEmpty { state.projects = [Project(name: "Provenance")] }
                var task = ProjectTask(operationID: UUID(), workerAgentID: AgentID(), spaceID: SpaceID(), title: "Task \(i)", prompt: "task \(i)")
                task.phase = .resolved
                state.projects[0].tasks.append(task)
                if first == nil { first = task }
                if i < 16 {
                    for n in 0..<2 {
                        state.projects[0].artifacts.append(.init(id: UUID(), key: .init(ownerID: state.projects[0].ownerID, projectID: state.projects[0].id, operationID: task.operationID), taskID: task.id, workerAgentID: task.workerAgentID, sessionID: "s", generation: "g", artifactName: "result-\(i)-\(n).txt", size: 1, sha256: String(repeating: "a", count: 64), sourceIdentity: String(repeating: "b", count: 64)))
                    }
                }
                if i < 32 {
                    state.projects[0].spaceProposals.append(.init(id: UUID(), operationID: UUID(), spaceID: SpaceID(), displayPath: "retain exact proposal \(i)", originTaskID: task.id))
                }
                state.projects[0].revision += 1
            }
            try store.update { _ in }
            let project = StateStore(url: url).state.projects[0]
            try project.validate()
            #expect(project.tasks.count <= 17 && project.referencedTasks.count <= 40)
            #expect(project.artifacts.count == min(i + 1, 16) * 2)
            #expect(project.spaceProposals.count == min(i + 1, 32))
        }
        let p = store.state.projects[0], oldest = try #require(first)
        #expect(!p.tasks.contains { $0.id == oldest.id })
        #expect(p.referencedTasks.contains { $0.taskID == oldest.id && $0.workerAgentID == oldest.workerAgentID && $0.operations.contains(oldest.operationID) })
        // A referenced operation also survives repeated activations while its task stays live.
        let firstArtifact = try #require(p.artifacts.first)
        var reused = try #require(try ProjectHistoryStore(beside: url).taskByID(p, id: firstArtifact.taskID))
        reused.phase = .settled
        try store.update { $0.projects[0].tasks.append(reused); $0.projects[0].revision += 1 }
        for _ in 0..<12 {
            let previous = reused.operationID; reused.previousOperations = (reused.previousOperations ?? []) + [previous]; reused.operationID = UUID()
            try store.update { state in
                let index = state.projects[0].tasks.firstIndex { $0.id == reused.id }!
                state.projects[0].tasks[index] = reused; state.projects[0].revision += 1
            }
            try store.state.validate()
            reused = try #require(store.state.projects[0].tasks.first { $0.id == reused.id })
        }
        #expect(reused.previousOperations?.contains(firstArtifact.key.operationID) == true)
        var forged = p; forged.artifacts[0].workerAgentID = AgentID()
        #expect(throws: (any Error).self) { try forged.validate() }
        forged = p; forged.spaceProposals[0].originTaskID = ProjectTaskID()
        #expect(throws: (any Error).self) { try forged.validate() }
    }

    @Test func referencedOldOperationSurvivesManyFollowUps() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json"), store = StateStore(url: url)
        var task = ProjectTask(operationID: UUID(), workerAgentID: AgentID(), spaceID: SpaceID(), title: "Linked", prompt: "linked")
        task.phase = .settled
        var project = Project(name: "Operation proof"); project.tasks = [task]
        project.artifacts = [.init(id: UUID(), key: .init(ownerID: project.ownerID, projectID: project.id, operationID: task.operationID), taskID: task.id, workerAgentID: task.workerAgentID, sessionID: "s", generation: "g", artifactName: "artifact.txt", size: 1, sha256: String(repeating: "a", count: 64), sourceIdentity: String(repeating: "b", count: 64))]
        try store.update { $0.projects = [project] }
        for _ in 0..<70 {
            try store.update { state in
                let old = state.projects[0].tasks[0].operationID
                state.projects[0].tasks[0].previousOperations = (state.projects[0].tasks[0].previousOperations ?? []) + [old]
                state.projects[0].tasks[0].operationID = UUID(); state.projects[0].revision += 1
            }
            try store.state.projects[0].validate()
            #expect((store.state.projects[0].tasks[0].previousOperations ?? []).count <= 2)
            #expect(store.state.projects[0].referencedTasks.count <= 1)
        }
        try StateStore(url: url).state.projects[0].validate()
    }

    @Test func terminalDiagnosticSurvivesRecoveryButDoesNotLeakToLaterSuccess() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json"), store = StateStore(url: url)
        var task = ProjectTask(operationID: UUID(), workerAgentID: AgentID(), spaceID: SpaceID(), title: "Warning", prompt: "warn")
        task.phase = .running; task.workerSessionID = "exact-session"; task.nativeDeliveryID = task.operationID
        try store.update { $0.projects = [Project(name: "Diagnostics")]; $0.projects[0].tasks = [task] }
        try store.update { state in
            state.projects[0].tasks[0].phase = .settled
            state.projects[0].tasks[0].error = "Native warning: interrupted output is incomplete"
            let source = ProjectEventSource(kind: .settled, taskID: task.id, operationID: task.operationID, workerAgentID: task.workerAgentID, sessionID: task.workerSessionID)
            SessionServer.appendProjectEvent(&state.projects[0], source: source, data: "warning", result: .init(text: "visible partial", complete: false, stopReason: "error"))
            state.projects[0].revision += 1
        }
        let reload = StateStore(url: url)
        try reload.update { $0.projects[0].revision += 1 }
        #expect(reload.state.projects[0].tasks[0].error == "Native warning: interrupted output is incomplete")
        let oldOperation = task.operationID
        try reload.update { state in
            task.operationID = UUID(); task.nativeDeliveryID = task.operationID; task.phase = .settled; task.error = nil
            state.projects[0].tasks[0] = task
            let source = ProjectEventSource(kind: .settled, taskID: task.id, operationID: task.operationID, workerAgentID: task.workerAgentID, sessionID: task.workerSessionID)
            SessionServer.appendProjectEvent(&state.projects[0], source: source, data: "success", result: .init(text: "visible final", complete: true, stopReason: "stop"))
            state.projects[0].revision += 1
        }
        #expect(reload.state.projects[0].tasks[0].error == nil)
        let retained = try ProjectHistoryStore(beside: url).record(reload.state.projects[0], kind: "terminal-task", id: oldOperation.uuidString, as: ProjectTask.self)
        #expect(retained?.error == "Native warning: interrupted output is incomplete")
    }

    @Test func archivedWorkerRouteIsAuthorizedWithoutReactivatingTasks() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.host.stop() }
        let project = try await rig.create()
        let spaceID = try #require(rig.host.server.state.spaces.first?.id)
        _ = try await rig.perform(project.id, .message(operationID: UUID(), text: "coordinator"))
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: spaceID, title: "Archived worker", prompt: "tools:0"))
        try await eventually("first task settles") { rig.host.server.state.projects[0].tasks.first?.phase == .settled }
        let original = try #require(rig.host.server.state.projects[0].tasks.first), worker = original.workerAgentID, taskID = original.id
        let grant = try await rig.host.server.projectWorkerReadGrant(project.id)
        try await rig.host.server.enqueue {
            try rig.host.server.store.update { state in
                state.projects[0].tasks[0].phase = .resolved
                for j in state.projects[0].messages.indices { state.projects[0].messages[j].phase = .delivered }
                for i in 0..<24 {
                    var task = ProjectTask(operationID: UUID(), spaceID: spaceID, title: "Archived", prompt: "archived \(i)")
                    task.phase = .resolved
                    state.projects[0].tasks.append(task)
                }
                state.projects[0].revision += 1
            }
            try rig.host.server.store.update { $0.projects[0].revision += 1 }
        }
        let live = rig.host.server.state.projects[0]
        #expect(!live.tasks.contains { $0.id == taskID } && rig.host.server.state.isProjectWorker(worker))
        let routed = try await rig.host.server.projectRuntime(project.id, expectedRevision: live.revision, request: .worker(taskID: taskID))
        #expect(routed.tasks.count == 1 && routed.tasks[0].id == taskID && routed.tasks[0].workerAgentID == worker && routed.tasks[0].workerSessionID == original.workerSessionID)
        let native = try await rig.host.server.nativeThread(agentID: worker, request: .snapshot(expectedSessionID: original.workerSessionID))
        guard case .snapshot(let thread) = native else { Issue.record("Archived route must open the actual native thread"); return }
        #expect(thread.piSessionID == original.workerSessionID)
        #expect(!rig.host.server.state.projects[0].tasks.contains { $0.id == taskID })
        await #expect(throws: (any Error).self) { try await rig.host.server.projectRuntime(project.id, expectedRevision: live.revision, request: .worker(taskID: ProjectTaskID())) }
        await #expect(throws: (any Error).self) { try await rig.host.server.projectTool(agentID: AgentID(), projectID: project.id, expectedRevision: live.revision, request: .worker(taskID: taskID)) }
        rig.host.server.setProjectsEnabled(false)
        try await eventually("Projects disabled") { !rig.host.server.projectsEnabled }
        rig.host.server.setProjectsEnabled(true)
        try await eventually("Projects re-enabled") { rig.host.server.projectsEnabled }
        await #expect(throws: (any Error).self) { try await rig.host.server.validateProjectWorkerRead(project.id, grant: grant) }
        _ = try await rig.host.server.updateRuntimeProject(project.id) { state in
            var missingSource = original; missingSource.workerSessionID = nil; state.tasks.append(missingSource)
        }
        await #expect(throws: (any Error).self) { try await rig.host.server.projectRuntime(project.id, expectedRevision: rig.host.server.state.projects[0].revision, request: .worker(taskID: taskID)) }
    }

    @Test(arguments: [false, true]) func executorBlockedResultReadCannotOutliveProjectsPermission(reenable: Bool) async throws {
        let host = try RemoteHost(); defer { host.stop() }
        let key = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID())
        var receipt = ProjectExecutionReceipt(key: key, phase: .settled); receipt.sessionID = "s"; receipt.generation = "g"; receipt.matchedUserEntryID = "u"
        let space = Space(name: "Executor", path: host.host.dir.path), spaceID = space.id
        try await host.server.enqueue { try host.server.store.update { $0.spaces.append(space) } }
        receipt.assignment = .init(key: key, taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: spaceID, title: "Read", prompt: "Read")
        try ProjectHistoryStore(beside: host.server.store.url).retainExecutionResult(receipt, result: .init(text: "must not escape", complete: true, stopReason: "stop"))
        let saved = receipt
        try await host.server.enqueue { try host.server.store.update { $0.projectExecutions.append(saved) } }
        try await host.server.setProjectsEnabled(true)
        let baseline = try await host.server.projectExecution(.result(key: key, offset: 0, sha256: nil))
        #expect(baseline.resultPage?.availability == .complete && baseline.resultPage?.data.isEmpty == false)
        let gate = DispatchSemaphore(value: 0), entered = Locked(false), scheduled = Locked(false)
        host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        defer { gate.signal() }
        try await eventually("disk gated") { entered.current }
        let read = Task { try await withCheckedThrowingContinuation { (c: CheckedContinuation<ProjectExecutionResult, Error>) in
            host.server.queue.async {
                host.server.projectExecutionOnQueue(.result(key: key, offset: 0, sha256: nil)) { c.resume(with: $0) }
                scheduled.withValue { $0 = true }
            }
        } }
        try await eventually("read scheduled") { scheduled.current }
        host.server.setProjectsEnabled(false)
        try await eventually("disabled") { !host.server.projectsEnabled }
        if reenable { host.server.setProjectsEnabled(true); try await eventually("re-enabled") { host.server.projectsEnabled } }
        gate.signal()
        await #expect(throws: (any Error).self) { try await read.value }
    }

    @Test(arguments: ["disable", "reenable", "owner", "caller", "host", "owner-restore", "caller-restore", "host-restore", "pause"])
    func ownerBlockedReadRevalidatesGrantButPauseIsNotRevocation(change: String) async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.host.stop() }
        let project = try await rig.create(), id = ProjectTaskID(), operation = UUID(), worker = AgentID()
        let spaceID = try #require(rig.host.server.state.spaces.first?.id)
        _ = try await rig.perform(project.id, .message(operationID: UUID(), text: "coordinator"))
        try await rig.host.server.enqueue {
            try rig.host.server.store.update { state in
                var task = ProjectTask(id: id, operationID: operation, workerAgentID: worker, spaceID: spaceID, title: "Retained", prompt: "retained")
                task.phase = .settled
                state.projects[0].tasks = [task]; state.projects[0].revision += 1
                let source = ProjectEventSource(kind: .settled, taskID: id, operationID: operation, workerAgentID: worker, sessionID: nil)
                SessionServer.appendProjectEvent(&state.projects[0], source: source, data: "receipt", result: .init(text: "only original grant", complete: true, stopReason: "stop"))
            }
        }
        let caller = try #require(rig.host.server.state.projects[0].coordinatorAgentID)
        try await eventually("coordinator installed") { rig.host.server.state.agents.contains { $0.id == caller && $0.coordinatorFor == project.id } }
        let snapshot = rig.host.server.state.projects[0]
        let token = try await rig.host.server.projectWorkerReadGrant(project.id)
        var grant = token; grant.caller = caller
        let captured = grant
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        rig.host.server.projectHistoryReads.async { entered.withValue { $0 = true }; gate.wait() }
        defer { gate.signal() }
        try await eventually("owner disk gated") { entered.current }
        let read = Task { try await rig.host.server.readProjectHistory(snapshot, request: .result(taskID: id, operationID: operation, offset: 0, sha256: nil), grant: captured) }
        if change == "disable" || change == "reenable" {
            rig.host.server.setProjectsEnabled(false); try await eventually("owner disabled") { !rig.host.server.projectsEnabled }
            if change == "reenable" { rig.host.server.setProjectsEnabled(true); try await eventually("owner re-enabled") { rig.host.server.projectsEnabled } }
        } else {
            try await rig.host.server.enqueue {
                let before = rig.host.server.store.state
                try rig.host.server.store.update { state in
                if change == "owner" || change == "owner-restore" { state.projects[0].ownerID = UUID() }
                if change == "caller" || change == "caller-restore" { state.projects[0].coordinatorAgentID = nil; state.agents.firstIndex { $0.id == caller }.map { state.agents[$0].coordinatorFor = nil } }
                if change == "host" || change == "host-restore" { state.projects[0].linkedSpaces = [] }
                if change == "pause" { state.projects[0].paused = true }
                state.projects[0].revision += 1
                }
                rig.host.server.stateDidCommit(before: before)
            }
        }
        if change.hasSuffix("-restore") {
            try await rig.host.server.enqueue {
                let before = rig.host.server.store.state
                try rig.host.server.store.update { state in
                if change == "owner-restore" { state.projects[0].ownerID = snapshot.ownerID }
                if change == "caller-restore" { state.projects[0].coordinatorAgentID = caller; state.agents.firstIndex { $0.id == caller }.map { state.agents[$0].coordinatorFor = project.id } }
                if change == "host-restore" { state.projects[0].linkedSpaces = snapshot.linkedSpaces }
                }
                rig.host.server.stateDidCommit(before: before)
            }
        }
        gate.signal()
        if change == "pause" { #expect(try await read.value.resultPage?.availability == .complete) }
        else { await #expect(throws: (any Error).self) { try await read.value } }
    }

    @Test func repeatedScopesRetireHotTombstonesAndRejectStaleChildrenAfterRestart() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let p = try await rig.create(), spaceID = try #require(rig.host.server.state.spaces.first?.id)
        _ = try await rig.perform(p.id, .message(operationID: UUID(), text: "coordinator"))
        var operation = UUID(), taskID = ProjectTaskID(), worker = AgentID(), oldScope: ProjectChildScope?
        for i in 0..<70 {
            let assigned = try await rig.perform(p.id, i == 0 ? .assign(operationID: operation, spaceID: spaceID, title: "Repeated scope", prompt: "tools:0") : .followUp(taskID: taskID, operationID: operation, text: "tools:0"))
            taskID = try #require(assigned.tasks.first?.id)
            worker = try #require(assigned.tasks.first?.workerAgentID)
            try await eventually("worker settles") { rig.host.server.state.projects[0].tasks.first { $0.id == taskID }?.phase == .settled }
            let thread = try #require(rig.agents.current[worker]?.server.rpcThread(forAgent: worker))
            let scope = ProjectChildScope(key: .init(ownerID: rig.host.server.state.projects[0].ownerID, projectID: p.id, operationID: operation), workerAgentID: worker, sessionID: try #require(thread.piSessionID), generation: thread.generation, epoch: rig.host.server.state.projects[0].tasks[0].childScopeEpoch ?? 0)
            if i == 0 { oldScope = scope }
            let counts = try await rig.host.server.enqueue { (rig.host.server.projectChildClosed.count, rig.host.server.projectChildStopped.count, rig.host.server.currentProjectChildScope.count) }
            #expect(counts.0 <= Project.retainedMessages && counts.1 <= Project.retainedMessages && counts.2 == 0)
            #expect(try await rig.host.server.enqueue { !rig.host.server.canResumeProjectChildScope(scope) })
            operation = UUID()
        }
        let stale = try #require(oldScope)
        #expect(try await rig.host.server.enqueue { !rig.host.server.canResumeProjectChildScope(stale) && rig.host.server.state.isProjectWorker(worker) })
        let client = try ExtensionClient(path: rig.host.socketPath); defer { client.closeConnection() }
        try client.send(.helloChildren(agentID: worker, projectScopes: true))
        try client.send(.childScope(id: 17, agentID: worker, sessionID: stale.sessionID, userTimestamp: nil))
        guard case .error(17, "project_scope", _) = try client.readReply() else { Issue.record("Retired Project activation admitted a child scope"); return }
        rig.host.stop(keepFiles: true)
        let restarted = try ProjectRuntimeTests.Rig(dir: rig.host.dir); defer { restarted.stop() }
        #expect(restarted.host.server.state.isProjectWorker(worker))
        #expect(try await restarted.host.server.enqueue { !restarted.host.server.canResumeProjectChildScope(stale) && restarted.host.server.projectChildClosed.isEmpty })
    }
}
