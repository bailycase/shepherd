import Foundation
import CryptoKit
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Durable Project history and exact results", .integrationTimeLimit)
struct ProjectHistoryTests {
    final class Files {
        let directory: URL
        let url: URL
        var store: StateStore
        init(_ project: Project) throws {
            directory = try makeScratchDirectory("ph")
            url = directory.appendingPathComponent("state.json")
            try JSONEncoder().encode(ShepherdState(projects: [project])).write(to: url)
            store = StateStore(url: url)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var project: Project { store.state.projects[0] }
        func update(_ change: (inout Project) -> Void = { _ in }) throws {
            try store.update { state in
                change(&state.projects[0]); state.projects[0].revision += 1
            }
        }
        func reload() { store = StateStore(url: url) }
        func history(_ task: ProjectTaskID? = nil) throws -> [ProjectHistoryEntry] {
            let db = try ProjectHistoryStore(beside: url)
            var entries: [ProjectHistoryEntry] = [], before: Int64?
            repeat {
                let page = try db.history(project, task: task, before: before, includeBodies: true)
                entries += page; before = page.last?.sequence
            } while before != nil
            return entries
        }
    }
    static func project() -> Project {
        var project = Project(name: "Long-lived Project", coordinatorAgentID: AgentID())
        project.tasks = (0..<3).map { ProjectTask(operationID: UUID(), spaceID: SpaceID(), title: "Task \($0)", prompt: "Assigned", phase: .running) }
        return project
    }
    static func source(_ project: Project, task: Int = 0, kind: ProjectEventSource.Kind = .settled) -> ProjectEventSource {
        let item = project.tasks[task]
        return .init(kind: kind, taskID: item.id, operationID: item.operationID, workerAgentID: item.workerAgentID, sessionID: "session-\(task)", generation: "generation-\(task)")
    }
    static func full(_ text: String) -> ProjectVisibleResult { .init(text: text, complete: true, stopReason: "stop") }

    @Test func hundredsOfMixedMessagesSurviveReloadWithoutHotGrowthOrOldEventReplay() throws {
        let files = try Files(Self.project())
        let first = Self.source(files.project)
        for index in 0..<240 {
            try files.update { p in
                for i in p.messages.indices { p.messages[i].phase = .delivered }
                if index.isMultiple(of: 2) {
                    let slot = (index / 2) % 3
                    if index != 0 {
                        p.tasks[slot].previousOperations = (p.tasks[slot].previousOperations ?? []) + [p.tasks[slot].operationID]
                        p.tasks[slot].operationID = UUID(); p.tasks[slot].revision += 1
                    }
                    p.tasks[slot].phase = .settled
                    SessionServer.appendProjectEvent(&p, source: Self.source(p, task: slot), data: "native receipt \(index)", result: Self.full("complete final \(index)"))
                } else {
                    var human = ProjectMessage(id: UUID(), text: "human \(index)", phase: .delivered)
                    human.humanSubmitted = true; p.messages.append(human)
                }
            }
            #expect(files.project.messages.count <= 35)
            #expect(try JSONEncoder().encode(files.store.state).count < 60_000)
            #expect(files.project.tasks.allSatisfy { ($0.previousOperations?.count ?? 0) <= 1 })
            if index.isMultiple(of: 40) { files.reload() }
        }
        try files.update(); files.reload()
        #expect(try files.history().count == 240)
        let original = try #require(try files.history().first { $0.source == first })
        let selected = try ProjectHistoryStore(beside: files.url).result(files.project, task: first.taskID, operation: first.operationID, offset: 0, hash: nil)
        #expect(selected.availability == .complete && String(decoding: selected.data, as: UTF8.self) == "complete final 0")
        #expect(selected.identity?.eventID == original.messageID && selected.identity?.source == first)
        #expect(!files.project.messages.contains { $0.source == first })
        try files.update { p in SessionServer.appendProjectEvent(&p, source: first, data: "delayed duplicate", result: Self.full("must not replace the result")) }
        try files.update(); files.reload()
        #expect(try files.history().count == 240)
        #expect(!files.project.messages.contains { $0.source == first }, "Archived duplicates cannot wake the coordinator again.")
        let replay = try ProjectHistoryStore(beside: files.url).result(files.project, task: first.taskID, operation: first.operationID, offset: 0, hash: nil)
        #expect(replay.data == selected.data && replay.sha256 == selected.sha256 && replay.identity == selected.identity)
    }

    @Test func fullLegacyMigrationPreservesHumanProofQuestionsAttachmentsAndUnknowns() throws {
        var project = Self.project(); project.tasks[0].phase = .waiting
        let question = ProjectMessage(id: UUID(), text: #"{"id":"native-question","kind":"select","options":["Staging","Production"]}"#, phase: .delivered, source: Self.source(project, kind: .question))
        var human = ProjectMessage(id: UUID(), text: "Staging, not Production", phase: .delivered, images: [.init(id: UUID(), mimeType: "image/png", name: "approval.png", byteCount: 68)])
        human.humanSubmitted = true
        var answer = ProjectQuestionAnswer(operationID: UUID(), sessionID: "session-0", generation: "generation-0", dialogID: "native-question", request: Data("real answer envelope".utf8))
        answer.phase = .unknown
        human.answerReceipts = [.init(taskID: project.tasks[0].id, questionEventID: question.id, nativeAnswer: answer)]
        let unknown = ProjectMessage(id: UUID(), text: "dispatch uncertain", phase: .unknown)
        let queued = ProjectMessage(id: UUID(), text: "not sent", phase: .queued)
        let delivering = ProjectMessage(id: UUID(), text: "in flight", phase: .delivering)
        let failed = ProjectMessage(id: UUID(), text: "definitely failed", phase: .failed)
        project.messages = [question, human, unknown, queued, delivering, failed] + (0..<58).map { ProjectMessage(id: UUID(), text: "legacy \($0)", phase: .delivered) }
        let files = try Files(project)
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("project-history.sqlite").path))
        try files.update(); files.reload(); try files.update()
        #expect(files.project.messages.count == Project.retainedMessages)
        for pinned in [question, human, unknown, queued, delivering] { #expect(files.project.messages.contains(pinned)) }
        let history = try files.history()
        #expect(history.count == 64)
        #expect(history.first { $0.messageID == human.id }?.message == human)
        #expect(history.first { $0.messageID == question.id }?.message == question)
        #expect(history.first { $0.messageID == failed.id }?.phase == .failed)
        #expect(history.first { $0.messageID == unknown.id }?.phase == .unknown)
        let proof = try #require(try ProjectHistoryStore(beside: files.url).chatAnswer(files.project, operation: answer.operationID))
        #expect(proof.humanReplyID == human.id && proof.receipt.nativeAnswer == answer)
        var differentOwner = files.project; differentOwner.ownerID = UUID()
        #expect(try ProjectHistoryStore(beside: files.url).chatAnswer(differentOwner, operation: answer.operationID) == nil)
        try files.update(); files.reload()
        #expect(try files.history().count == 64, "Migration/restart is idempotent, not eviction or a provenance reset.")
    }

    @Test func resultCommitSurvivesWorkspaceFailureWithoutReplayingNativeWork() throws {
        var project = Self.project(); project.tasks[0].phase = .running
        project.tasks[0].workerSessionID = "same-native-session"; project.tasks[0].nativeDeliveryID = UUID()
        let files = try Files(project)
        var candidate = files.store.state
        candidate.projects[0].tasks[0].phase = .settled; candidate.projects[0].tasks[0].settledAt = 123
        let source = Self.source(project)
        SessionServer.appendProjectEvent(&candidate.projects[0], source: source, data: "receipt", result: Self.full("complete before rename"))
        candidate.projects[0].revision += 1
        let staged = try StateStore.stageLogicalProjects(candidate, before: files.store.state, at: files.url)
        defer { try? FileManager.default.removeItem(at: staged.url) }
        files.reload() // No JSON rename: durable native completion is the only additional proof.
        #expect(files.project.tasks[0].phase == .running)
        try files.update()
        #expect(files.project.tasks[0].phase == .settled && files.project.tasks[0].settledAt == 123)
        let history = try ProjectHistoryStore(beside: files.url)
        let page = try history.result(files.project, task: source.taskID, operation: source.operationID, offset: 0, hash: nil)
        #expect(page.availability == .complete && String(decoding: page.data, as: UTF8.self) == "complete before rename")
        #expect(files.project.messages.filter { $0.source == source }.count == 1)
        try files.update(); files.reload(); try files.update()
        #expect(files.project.messages.filter { $0.source == source }.count == 1)
    }

    @Test func resolvedTasksArchiveWithoutALifetimeQuota() throws {
        let files = try Files(Self.project())
        var first: ProjectTask?
        for index in 0..<180 {
            var completed = ProjectTask(operationID: UUID(), spaceID: SpaceID(), title: "closed \(index)", prompt: "native work")
            completed.phase = .resolved
            if first == nil { first = completed }
            try files.update { $0.tasks.append(completed) }
            #expect(files.project.tasks.count <= 20)
            #expect(files.project.tasks.count + (files.project.archivedResolvedTaskCount ?? 0) == index + 4)
            if index.isMultiple(of: 19) { files.reload() }
        }
        let archived = try #require(first)
        #expect(!files.project.tasks.contains { $0.id == archived.id })
        let history = try ProjectHistoryStore(beside: files.url)
        #expect(try history.taskByID(files.project, id: archived.id)?.phase == .resolved)
        let count = files.project.archivedResolvedTaskCount
        try files.update { $0.tasks.append(archived) }
        #expect(files.project.tasks.contains { $0.id == archived.id })
        #expect(files.project.archivedResolvedTaskCount == count)
        #expect(try history.taskByID(files.project, id: archived.id)?.operationID == archived.operationID)
    }

    @Test func executorLedgerArchivesPast128WhileUnknownOutcomesRemainLive() throws {
        let files = try Files(Self.project()), first = UUID()
        let owner = files.project.ownerID, projectID = files.project.id
        let uncertainKey = ProjectExecutionKey(ownerID: owner, projectID: projectID, operationID: UUID())
        let uncertainAssignment = ProjectExecutionAssignment(key: uncertainKey, taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: SpaceID(), title: "Uncertain", prompt: "native dispatch outcome is unknown")
        let uncertain = ProjectExecutionReceipt(key: uncertainKey, assignment: uncertainAssignment, phase: .unknown)
        try files.store.update { $0.projectExecutions.append(uncertain) }
        var sample: ProjectExecutionReceipt?
        for index in 0..<180 {
            let key = ProjectExecutionKey(ownerID: owner, projectID: projectID, operationID: index == 0 ? first : UUID())
            let assignment = ProjectExecutionAssignment(key: key, taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: SpaceID(), title: "Settled \(index)", prompt: "fixture native work")
            var receipt = ProjectExecutionReceipt(key: key, assignment: assignment, phase: .settled)
            receipt.sessionID = "native-\(index)"; receipt.generation = "generation-\(index)"; receipt.resultText = "retained index, not full result"
            if index == 0 { sample = receipt }
            try files.store.update { $0.projectExecutions.append(receipt) }
            #expect(files.store.state.projectExecutions.count <= 18)
            #expect(files.store.state.projectExecutions.contains(uncertain))
            if index.isMultiple(of: 37) { files.reload() }
        }
        let retained = try ProjectHistoryStore(beside: files.url).executionHistory(.snapshot(key: try #require(sample).key, watch: false))
        #expect(retained.existing == sample, "Archiving is not loss of old execution/replay identity.")
    }

    @Test func fullLiveQueueRetainsCompletionAndDrainsBeforeNewerHumanInput() throws {
        var project = Self.project()
        project.messages = (0..<64).map { ProjectMessage(id: UUID(), text: "live \($0)") }
        let files = try Files(project), source = Self.source(project)
        let text = String(repeating: "complete visible result 🦊\n", count: 2_000)
        try files.update { p in
            p.tasks[0].phase = .settled
            SessionServer.appendProjectEvent(&p, source: source, data: "receipt only", result: Self.full(text))
        }
        #expect(files.project.tasks[0].phase == .settled && files.project.messages.count == 64)
        #expect(files.project.historyPending == true && !files.project.paused)
        let descriptor = try ProjectHistoryStore(beside: files.url).resultDescriptor(files.project, task: source.taskID, operation: source.operationID)
        #expect(descriptor.availability == .complete && descriptor.totalBytes == text.utf8.count)
        files.reload()
        #expect(files.project.historyPending == true)
        #expect(throws: LogicalProjectsError.self) {
            try files.update { p in p.messages.append(.init(id: UUID(), text: "cannot displace an older result")) }
        }
        let nextOperation = UUID()
        try files.update { p in
            p.tasks[0].previousOperations = [source.operationID]
            p.tasks[0].operationID = nextOperation; p.tasks[0].phase = .running
        }
        try files.update { p in for i in 0..<40 { p.messages[i].phase = .delivered } }
        #expect(files.project.tasks[0].operationID == nextOperation && files.project.tasks[0].phase == .running, "Delivering a delayed old receipt must not settle newer work.")
        let human = ProjectMessage(id: UUID(), text: "newer person input")
        try files.update { p in p.messages.append(human) }
        #expect(files.project.historyPending == false)
        let resultIndex = try #require(files.project.messages.firstIndex { $0.source == source })
        #expect(resultIndex < (try #require(files.project.messages.firstIndex { $0.id == human.id })))
        try files.update { p in p.messages[resultIndex].phase = .unknown }
        files.reload(); try files.update()
        #expect(files.project.messages.filter { $0.source == source }.count == 1)
        #expect(files.project.messages.first { $0.source == source }?.phase == .unknown, "An uncertain wake-up is never automatically resent.")
    }

    @Test func resultCaptureSurvivesWorkspaceCommitCrashAndPagingIsImmutableRedactedAndUTF8Safe() throws {
        let files = try Files(Self.project()), source = Self.source(files.project)
        let secret = "sk-" + String(repeating: "a", count: 40)
        let original = "Bearer " + secret + "\n" + String(repeating: "🦊 visible final\n", count: 70_000)
        var candidate = files.store.state
        candidate.projects[0].revision += 1
        candidate.projects[0].tasks[0].phase = .settled
        SessionServer.appendProjectEvent(&candidate.projects[0], source: source, data: "receipt", result: Self.full(original))
        let staged = try StateStore.stageLogicalProjects(candidate, before: files.store.state, at: files.url)
        try FileManager.default.removeItem(at: staged.url) // crash before the workspace rename, after the durable native capture
        files.reload()
        #expect(files.project.tasks[0].phase == .running, "An uncommitted lifecycle change is not manufactured into success.")
        let db = try ProjectHistoryStore(beside: files.url)
        var offset: Int64 = 0, digest: String?, data = Data(), pages = 0
        repeat {
            let page = try db.result(files.project, task: source.taskID, operation: source.operationID, offset: offset, hash: digest)
            #expect(page.availability == .complete && page.redacted)
            #expect(page.identity?.source == source && page.identity?.deliveryID == source.operationID)
            #expect(page.data.count <= ProjectHistoryStore.chunkBytes)
            #expect(String(data: page.data, encoding: .utf8) != nil)
            #expect(try JSONEncoder().encode(page).count < NDJSON.maxPayloadBytes)
            #expect(String(data: page.data, encoding: .utf8) != nil, "Each result page is valid UTF-8, not a lossy display slice.")
            data.append(page.data); digest = page.sha256; pages += 1
            guard let next = page.nextOffset else { #expect(data.count == page.totalBytes); break }
            #expect(next > offset); offset = next
        } while pages < 1_000
        #expect(data.count > NDJSON.maxPayloadBytes && pages > 128)
        #expect(!String(decoding: data, as: UTF8.self).contains(secret))
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("🦊 visible final\n"))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == digest)
        #expect(throws: LogicalProjectsError.self) { try db.result(files.project, task: source.taskID, operation: source.operationID, offset: 1, hash: nil) }
        #expect(throws: LogicalProjectsError.self) { try db.result(files.project, task: source.taskID, operation: source.operationID, offset: 0, hash: String(repeating: "0", count: 64)) }
        #expect(throws: LogicalProjectsError.self) { try db.result(files.project, task: ProjectTaskID(), operation: source.operationID, offset: 0, hash: nil) }
        try files.update()
        #expect(files.project.messages.contains { $0.source == source }, "The persisted outbox rehydrates the missing wake-up without re-running the worker.")
    }

    @Test func legacyClippedReceiptsStayUnavailableAndCaptureNeverIncludesThinking() async throws {
        var project = Self.project()
        var source = Self.source(project); source.generation = nil
        project.messages = [.init(id: UUID(), text: "old clipped result", phase: .delivered, source: source)]
        let files = try Files(project)
        try files.update()
        let page = try ProjectHistoryStore(beside: files.url).result(files.project, task: source.taskID, operation: source.operationID, offset: 0, hash: nil)
        #expect(page.availability == .unavailable && page.data.isEmpty && page.sha256 == nil)
        var replay = source; replay.generation = UUID().uuidString
        try files.update { SessionServer.appendProjectEvent(&$0, source: replay, data: "new generation metadata is not a new result") }
        #expect(try files.history().filter { $0.source?.kind == .settled }.count == 1)
        #expect(try ProjectHistoryStore(beside: files.url).resultDescriptor(files.project, task: source.taskID, operation: source.operationID).availability == .unavailable)
        let raw = Data(#"{"role":"assistant","content":[{"type":"thinking","thinking":"private thought"},{"type":"text","text":"only the visible final"}],"stopReason":"stop"}"#.utf8)
        let message = try JSONDecoder().decode(RPCMessage.self, from: raw)
        let tool = try JSONDecoder().decode(RPCMessage.self, from: Data(#"{"role":"assistant","content":[{"type":"toolCall","id":"tool","name":"read","arguments":{}}],"stopReason":"toolUse"}"#.utf8))
        let visible = RPCThreadState.visibleProjectResult(message), unsupported = RPCThreadState.visibleProjectResult(tool)
        #expect(visible.text == "only the visible final" && visible.complete)
        #expect(!unsupported.complete && unsupported.text.isEmpty)
        let oversized = try JSONSerialization.data(withJSONObject: ["role": "assistant", "content": [["type": "text", "text": String(repeating: "界", count: ProjectVisibleResult.maximumBytes / 3 + 2)]], "stopReason": "stop"])
        let capped = RPCThreadState.visibleProjectResult(try JSONDecoder().decode(RPCMessage.self, from: oversized))
        #expect(!capped.complete && capped.text.utf8.count <= ProjectVisibleResult.maximumBytes)
        #expect(!capped.text.contains("�"))
    }

    @Test func explicitResumeRetriesFailedRetentionNotTheNativePrompt() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID), operation = UUID()
        let assigned = try await rig.perform(project.id, .assign(operationID: operation, spaceID: space, title: "Retention failure", prompt: "tools:0 hold-settle"))
        let task = try #require(assigned.tasks.first)
        try await eventually("worker created") { rig.agents.current[task.workerAgentID] != nil }
        let worker = try #require(rig.agents.current[task.workerAgentID])
        _ = try await worker.snapshot("visible final message before settlement") { $0.running && $0.messages.contains(where: { $0.role == "assistant" && !$0.blocks.isEmpty }) }
        let db = rig.host.server.store.url.deletingLastPathComponent().appendingPathComponent("project-history.sqlite")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: db.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: db.path) }
        worker.releaseSettle()
        do { _ = try await worker.snapshot("native final visible result emitted") { !$0.running && $0.messages.contains(where: { $0.role == "assistant" }) } }
        catch {
            let snapshot = try await worker.request(.snapshot())
            throw WireError("Failed-retention fixture did not settle: \(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self))")
        }
        try await eventually("failed retention pauses admissions") { rig.host.server.state.projects[0].paused }
        let captured = try await rig.host.server.enqueue { rig.host.server.rpcThread(forAgent: task.workerAgentID)?.lastTurnResultDeliveryID }
        #expect(captured == operation)
        await #expect(throws: (any Error).self) { try await rig.perform(project.id, .pause) }
        #expect(rig.host.server.state.projects[0].tasks[0].phase != .settled)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: db.path)
        try await eventually("Resume admitted after earlier failed save drains") {
            do {
                _ = try await rig.host.server.projectRuntime(project.id, expectedRevision: rig.host.server.state.projects[0].revision, request: .resume)
                return true
            } catch let error as LogicalProjectsError where ["stale_project", "project_busy", "workspace_changed"].contains(error.code) { return false }
        }
        try await eventually("explicit retention retry committed") { rig.host.server.state.projects[0].tasks[0].phase == .settled }
        let saved = try await rig.perform(project.id, .result(taskID: task.id, operationID: operation, offset: 0, sha256: nil))
        #expect(saved.resultPage?.availability == .complete)
        #expect(worker.stdin("prompt").count == 1)
    }

    @Test func nativeLocalSettlementHasExactOwnerReadAndOldOperationIsNotTheFollowUp() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), space = try #require(project.linkedSpaces.first?.spaceID), first = UUID()
        let assigned = try await rig.perform(project.id, .assign(operationID: first, spaceID: space, title: "Exact result", prompt: "tools:0"))
        let task = try #require(assigned.tasks.first)
        try await eventually("local final retained") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        let old = try await rig.perform(project.id, .result(taskID: task.id, operationID: first, offset: 0, sha256: nil))
        let page = try #require(old.resultPage), identity = try #require(page.identity)
        #expect(page.availability == .complete && String(decoding: page.data, as: UTF8.self) == "Reply to tools:0")
        #expect(identity.source.operationID == first && identity.source.taskID == task.id && identity.source.workerAgentID == task.workerAgentID)
        #expect(identity.deliveryID == first && identity.source.sessionID != nil && identity.source.generation != nil)
        let second = UUID()
        _ = try await rig.perform(project.id, .followUp(taskID: task.id, operationID: second, text: "tools:0"))
        try await eventually("follow-up settled") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled && rig.agents.current[task.workerAgentID]?.stdin("prompt").count == 2 }
        let again = try await rig.perform(project.id, .result(taskID: task.id, operationID: first, offset: 0, sha256: page.sha256))
        #expect(again.resultPage == page, "An old result's immutable identities and bytes do not become the latest reply")
        let newer = try await rig.perform(project.id, .result(taskID: task.id, operationID: second, offset: 0, sha256: nil))
        #expect(newer.resultPage?.identity?.source.operationID == second && newer.resultPage?.identity?.eventID != identity.eventID)
        let ready = try await rig.perform(project.id, .message(operationID: UUID(), text: "Inspect fixture receipt only"))
        let coordinator = try #require(ready.coordinatorAgentID)
        try await eventually("coordinator native runtime") { rig.agents.current[coordinator] != nil }
        var source = try #require(newer.resultPage?.identity?.source); source.operationID = UUID()
        let legacy = ProjectMessage(id: UUID(), text: #"Worker event. Native content: {"blocks":[{"kind":"thinking","text":"private-hidden"},{"kind":"text","text":"visible final"}]}"#, phase: .delivered, source: source)
        _ = try await rig.host.server.updateRuntimeProject(project.id) { $0.messages.append(legacy) }
        let inspected = try await rig.host.server.projectTool(agentID: coordinator, projectID: project.id,
            expectedRevision: rig.host.server.state.projects[0].revision, request: .inspect(taskID: task.id, operationID: source.operationID))
        #expect(inspected.messages.contains { $0.text.contains("visible final") }, "Messages: \(inspected.messages.map(\.text))")
        #expect(!inspected.messages.contains { $0.text.contains("private-hidden") })
        #expect(rig.host.server.state.projects[0].messages.contains { $0.text.contains("private-hidden") }, "stored evidence is not rewritten")
        await #expect(throws: LogicalProjectsError.self) { try await rig.host.server.projectTool(agentID: task.workerAgentID, projectID: project.id, expectedRevision: rig.host.server.state.projects[0].revision, request: .result(taskID: ProjectTaskID(), operationID: first, offset: 0, sha256: nil)) }
        await #expect(throws: LogicalProjectsError.self) { try await rig.perform(project.id, .result(taskID: ProjectTaskID(), operationID: first, offset: 0, sha256: nil)) }
        _ = try await rig.perform(project.id, .resolve(taskID: task.id, operationID: UUID()))
        _ = try await rig.host.server.updateRuntimeProject(project.id) { project in
            for i in project.messages.indices { project.messages[i].phase = .delivered }
            for index in 0..<20 {
                var completed = ProjectTask(operationID: UUID(), spaceID: space, title: "resolved \(index)", prompt: "fixture completed work")
                completed.phase = .resolved; project.tasks.append(completed)
            }
        }
        _ = try await rig.host.server.updateRuntimeProject(project.id) { _ in }
        #expect(!rig.host.server.state.projects[0].tasks.contains { $0.id == task.id })
        let archived = try await rig.perform(project.id, .result(taskID: task.id, operationID: first, offset: 0, sha256: page.sha256))
        #expect(archived.resultPage == page, "Archiving a resolved task never revokes its exact owner result read.")
        let beforePrompts = rig.agents.current[task.workerAgentID]?.stdin("prompt").count
        rig.host.server.stop(); try rig.host.server.start()
        let restarted = try await rig.perform(project.id, .result(taskID: task.id, operationID: first, offset: 0, sha256: page.sha256))
        #expect(restarted.resultPage == page && rig.agents.current[task.workerAgentID]?.stdin("prompt").count == beforePrompts)
    }

    @Test func remoteExactResultSurvivesBothRestartsAndRevokedBindingNeverFallsBack() async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        var assignment = try await rig.assignment("tools:0 long:14000")
        guard case .project(let project) = try await rig.owner.server.logicalProjects(.create(projectID: assignment.key.projectID, name: "Owner", goal: "")) else { throw WireError("owner") }
        assignment.key.ownerID = project.ownerID
        rig.owner.server.onProjectRuntimeLaunch = { _, done in done(.failure(WireError("No owner model turn expected"))) }
        let hostID = UUID(), binding = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        let exact = assignment
        _ = try await rig.owner.server.updateRuntimeProject(project.id) { owner in
            owner.settings.allowedHosts = [binding]; owner.linkedSpaces = [.init(spaceID: exact.executorSpaceID, linkedAt: 0, host: binding)]
            var task = ProjectTask(id: exact.taskID, operationID: exact.key.operationID, workerAgentID: exact.reservedWorkerID, spaceID: exact.executorSpaceID, title: exact.title, prompt: exact.prompt, phase: .running, host: binding)
            task.executionAssignment = exact; owner.tasks = [task]
        }
        rig.owner.server.setProjectExecutionSpaces([binding: rig.host.server.state.spaces])
        let client = try await rig.remote.typed(); defer { client.disconnect() }
        let routes = Locked<[ProjectHostReference]>([])
        rig.owner.server.onProjectPlacement = { host, request, done in
            routes.withValue { $0.append(host) }
            Task { do { done(.success(try await client.projectExecution(request))) } catch { done(.failure(error)) } }
        }
        _ = try await client.projectExecution(.execute(exact))
        try await eventually("remote settled") { rig.receipt(exact)?.phase == .settled }
        rig.owner.server.reconcileProjectExecutions(host: binding)
        try await eventually("owner has exact remote receipt") { rig.owner.server.state.projects.first?.tasks.first?.executionReceipt?.phase == .settled }
        let read = ProjectRuntimeRequest.result(taskID: exact.taskID, operationID: exact.key.operationID, offset: 0, sha256: nil)
        let workerRead = ProjectRuntimeRequest.worker(taskID: exact.taskID)
        let routedWorker = try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: workerRead)
        #expect(routedWorker.tasks.count == 1 && routedWorker.tasks[0].workerAgentID == exact.reservedWorkerID)
        #expect(routedWorker.tasks[0].destination == binding)
        let nativeSource = try await client.projectExecution(.worker(key: exact.key))
        #expect(nativeSource.receipt.key == exact.key && nativeSource.thread?.piSessionID == nativeSource.receipt.sessionID)
        let ownerRead = try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: read)
        let page = try #require(ownerRead.resultPage), identity = try #require(page.identity)
        #expect(page.availability == .complete)
        var content = page.data
        var cursor = page.nextOffset
        #expect((page.totalBytes ?? 0) > NDJSON.maxPayloadBytes)
        while let offset = cursor {
            let nextRead = ProjectRuntimeRequest.result(taskID: exact.taskID, operationID: exact.key.operationID, offset: offset, sha256: page.sha256)
            let next = try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: nextRead)
            let part = try #require(next.resultPage)
            #expect(part.identity == page.identity && part.originIdentity == page.originIdentity)
            #expect(part.offset == Int64(content.count))
            #expect(try NDJSON.encode(RemoteReply.logicalProjectRuntime(id: 1, result: .project(next))).count < NDJSON.maxPayloadBytes)
            content.append(part.data); cursor = part.nextOffset
        }
        #expect(content.count == page.totalBytes)
        #expect(SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined() == page.sha256)
        #expect(String(decoding: content, as: UTF8.self).hasPrefix("Reply to tools:0 long:14000"))
        #expect(identity.host == binding && identity.source.sessionID == rig.receipt(exact)?.sessionID && identity.source.generation == rig.receipt(exact)?.generation)
        #expect(identity.source.operationID == exact.key.operationID && page.originIdentity?.source.operationID == exact.key.operationID)
        var wrong = exact.key; wrong.ownerID = UUID()
        await #expect(throws: Error.self) { try await client.projectExecution(.result(key: wrong, offset: 0, sha256: nil)) }
        let before = routes.current.count
        rig.owner.server.setProjectExecutionSpaces([.remote(hostID: hostID, bindingID: UUID()): rig.host.server.state.spaces])
        await #expect(throws: LogicalProjectsError.self) { try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: read) }
        await #expect(throws: LogicalProjectsError.self) { try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: workerRead) }
        #expect(routes.current.count == before, "Neither a cached result descriptor nor an archived worker route may bypass revoked original host binding")
        rig.owner.server.setProjectExecutionSpaces([binding: rig.host.server.state.spaces])
        client.disconnect(); rig.host.server.stop(); try rig.host.server.start()
        rig.owner.server.stop(); try rig.owner.server.start()
        let port = try rig.host.server.startRemoteListener(port: 0, tokenURL: rig.host.dir.appendingPathComponent("remote-token"))
        let reconnect = RemoteHostClient(); defer { reconnect.disconnect() }
        _ = try await reconnect.connect(host: "127.0.0.1", port: port, token: rig.remote.token, clientName: "result restart fixture")
        rig.owner.server.onProjectPlacement = { host, request, done in
            #expect(host == binding)
            Task { do { done(.success(try await reconnect.projectExecution(request))) } catch { done(.failure(error)) } }
        }
        rig.owner.server.setProjectExecutionSpaces([binding: rig.host.server.state.spaces])
        let reloaded = try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: read)
        #expect(reloaded.resultPage == page)
        #expect(rig.launches.current == 1, "Reading retained results never dispatches another native prompt")
    }

    @Test func unsafeHistoryStorageFailsWithoutMutatingAcceptedStateOrProof() throws {
        let files = try Files(Self.project())
        let external = files.directory.appendingPathComponent("not-a-database")
        try Data("untouched".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: files.directory.appendingPathComponent("project-history.sqlite"), withDestinationURL: external)
        let before = try Data(contentsOf: files.url)
        #expect(throws: (any Error).self) { try files.update { $0.messages.append(.init(id: UUID(), text: "not accepted")) } }
        #expect(try Data(contentsOf: files.url) == before && files.project.messages.isEmpty)
        #expect(try Data(contentsOf: external) == Data("untouched".utf8))
    }
}
