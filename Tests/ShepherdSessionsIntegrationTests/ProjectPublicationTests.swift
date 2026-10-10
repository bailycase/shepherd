import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project publication", .integrationTimeLimit)
struct ProjectPublicationTests {
    func worker(_ rig: ProjectRuntimeTests.Rig, cwd: URL) async throws -> (Project, ProjectTask) {
        let space = Space(name: "Sources", path: cwd.path)
        try await rig.host.server.addSpace(space)
        guard case .project(let project) = try await rig.host.server.logicalProjects(.create(projectID: .init(), name: "Artifacts", goal: "", linkedSpaceIDs: [space.id])) else { throw WireError("Project") }
        _ = try await rig.perform(project.id, .assign(operationID: UUID(), spaceID: space.id, title: "Report", prompt: "tools:1"))
        try await eventually("native publication authority") {
            guard let task = rig.host.server.state.projects.first?.tasks.first else { return false }
            return try await rig.host.server.enqueue { (try? rig.host.server.publicationAuthority(task.workerAgentID)) != nil }
        }
        let current = try #require(rig.host.server.state.projects.first)
        return (current, try #require(current.tasks.first))
    }

    @Test func workerPublishesRealBytesWithExactTaskProvenanceAndImmutableRetries() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let source = try makeScratchDirectory()
        let (project, task) = try await worker(rig, cwd: source)
        let bytes = Data("artifact from the actual worker cwd".utf8)
        try bytes.write(to: source.appendingPathComponent("source.txt"))
        let id = UUID(), publicationID = UUID()
        let request = ProjectPublicationRequest.publish(publicationID: publicationID, sourcePath: "source.txt", artifactName: "report.txt")
        let lostReply = try ExtensionClient(path: rig.host.socketPath)
        try lostReply.send(.projectPublish(id: 1, agentID: task.workerAgentID, request: request))
        try await eventually("publication request accepted before reply loss") {
            try await rig.host.server.enqueue { rig.host.server.publicationPending.contains(publicationID)
                || rig.host.server.store.state.projects.first?.artifacts.first?.id == publicationID }
        }
        lostReply.closeConnection()
        try await eventually("lost reply still has a durable ready receipt") { rig.host.server.state.projects.first?.artifacts.first?.state == .ready }
        let extensionClient = try ExtensionClient(path: rig.host.socketPath)
        try extensionClient.send(.projectPublish(id: 2, agentID: task.workerAgentID, request: request))
        guard case .projectPublish(2, let published) = try extensionClient.readReply() else { throw WireError("publisher extension retry result") }
        let receipt = try #require(published.artifact)
        #expect(receipt.state == .ready && receipt.taskID == task.id && receipt.key.operationID == task.operationID)
        #expect(receipt.sessionID == task.workerSessionID)
        guard case .files(let listing) = try await rig.host.server.logicalProjects(.files(projectID: project.id, path: "")),
              case .file(let file) = try await rig.host.server.logicalProjects(.read(projectID: project.id, path: "report.txt")) else { throw WireError("files") }
        #expect(listing.entries.count == 1 && listing.entries[0].taskID == task.id)
        #expect(file.data == bytes)
        try Data("changed source is never resnapshotted on retry".utf8).write(to: source.appendingPathComponent("source.txt"))
        #expect(try await rig.host.server.projectPublish(task.workerAgentID, request: request) == published)
        await #expect(throws: LogicalProjectsError.self) {
            try await rig.host.server.projectPublish(task.workerAgentID, request: .publish(publicationID: receipt.id, sourcePath: "different.txt", artifactName: "report.txt"))
        }
        await #expect(throws: LogicalProjectsError.self) {
            try await rig.host.server.projectPublish(task.workerAgentID, request: .publish(publicationID: id, sourcePath: "source.txt", artifactName: "report.txt"))
        }
        guard case .file(let unchanged) = try await rig.host.server.logicalProjects(.read(projectID: project.id, path: "report.txt")) else { throw WireError("read") }
        #expect(unchanged.data == bytes)
        // A foreign replacement never inherits the task's provenance.
        try Data("replacement".utf8).write(to: rig.host.dir.appendingPathComponent("logical-projects/\(project.id)/report.txt"))
        guard case .files(let replaced) = try await rig.host.server.logicalProjects(.files(projectID: project.id, path: "")) else { throw WireError("files") }
        #expect(replaced.entries.first?.taskID == nil)
        rig.host.useRealPeerCheck()
        let impostor = try ExtensionClient(path: rig.host.socketPath)
        try impostor.send(.projectPublish(id: 12, agentID: task.workerAgentID, request: request))
        guard case .error(12, "wrong_process", _) = try impostor.readReply() else { throw WireError("publication peer authentication") }
    }

    @Test func ordinaryAndCoordinatorPeersCannotPublishAndPauseRevokesActiveWorker() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let source = try makeScratchDirectory()
        let (project, task) = try await worker(rig, cwd: source)
        try Data("result".utf8).write(to: source.appendingPathComponent("report.txt"))
        let client = try ExtensionClient(path: rig.host.socketPath)
        try client.send(.projectPublish(id: 9, agentID: AgentID(), request: .publish(publicationID: UUID(), sourcePath: "report.txt", artifactName: "x.txt")))
        guard case .error(9, _, _) = try client.readReply() else { throw WireError("ordinary refusal") }
        let ordinary = try await PiAgent.launch(on: rig.host, cwd: source)
        _ = try await ordinary.send("tools:2", from: ordinary.ready())
        try client.send(.projectPublish(id: 10, agentID: ordinary.agent.id, request: .publish(publicationID: UUID(), sourcePath: "report.txt", artifactName: "ordinary.txt")))
        guard case .error(10, "publication_scope", _) = try client.readReply() else { throw WireError("active ordinary refusal") }
        let coordinator = try await rig.perform(project.id, .message(operationID: UUID(), text: "tools:2"))
        try await eventually("coordinator identity installed") { rig.host.server.state.agents.contains { $0.id == coordinator.coordinatorAgentID } }
        try client.send(.projectPublish(id: 11, agentID: try #require(coordinator.coordinatorAgentID), request: .publish(publicationID: UUID(), sourcePath: "report.txt", artifactName: "coordinator.txt")))
        guard case .error(11, "project_scope", _) = try client.readReply() else { throw WireError("coordinator refusal") }
        _ = try await rig.perform(project.id, .pause)
        #expect(try await rig.host.server.projectPublish(task.workerAgentID, request: .eligibility).active == false)
        await #expect(throws: LogicalProjectsError.self) {
            try await rig.host.server.projectPublish(task.workerAgentID, request: .publish(publicationID: UUID(), sourcePath: "report.txt", artifactName: "x.txt"))
        }
    }

    @Test(arguments: ["pause", "manual", "delete", "restart", "replacement"], [false, true])
    func delayedPublicationCannotOutliveItsNativeAuthority(_ action: String, staged: Bool) async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let source = try makeScratchDirectory()
        let (project, task) = try await worker(rig, cwd: source)
        let pi = try #require(rig.agents.current[task.workerAgentID])
        let bytes = Data("artifact".utf8), id = UUID()
        try bytes.write(to: source.appendingPathComponent("source.txt"))
        if staged {
            let authority = try await rig.host.server.enqueue { try rig.host.server.publicationAuthority(task.workerAgentID) }
            let receipt = ProjectArtifactReceipt(id: id, key: authority.scope.key, taskID: task.id, workerAgentID: task.workerAgentID,
                sessionID: authority.scope.sessionID, generation: authority.scope.generation, artifactName: "report.txt", size: Int64(bytes.count),
                sha256: ProjectPublicationFiles.hash(bytes), sourceIdentity: ProjectPublicationFiles.hash(Data("source.txt".utf8)))
            try await rig.host.server.publicationIO { try ProjectPublicationFiles.stage(bytes, receipt: receipt, beside: rig.host.server.store.url) }
        }
        let entered = Locked(false), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        rig.host.server.logicalProjectFiles.async { entered.withValue { $0 = true }; gate.wait() }
        try await eventually("publication file queue held") { entered.current }
        let publishing = Task { try await rig.host.server.projectPublish(task.workerAgentID,
            request: .publish(publicationID: id, sourcePath: "source.txt", artifactName: "report.txt")) }
        try await eventually("publication admitted before source access") {
            try await rig.host.server.enqueue { rig.host.server.publicationPending.contains(id) }
        }
        var mutation: Task<Void, Never>?
        switch action {
        case "pause": mutation = Task { _ = try? await rig.perform(project.id, .pause) }
        case "delete": mutation = Task {
            _ = try? await rig.host.server.logicalProjects(.delete(projectID: project.id, expectedRevision: rig.host.server.state.projects[0].revision))
        }
        case "manual":
            _ = try await pi.send("tools:2 manual", delivery: .steer, from: pi.ready())
            try Data().write(to: source.appendingPathComponent("tool-1"))
        case "restart": rig.host.server.stop(); try rig.host.server.start()
        case "replacement":
            let session = try await rig.host.server.createSession(params: .init(cwd: source.path, command: StubPi.command, runtime: .rpc))
            try await rig.host.server.updatePaneSession(tabID: pi.agent.tabID, paneID: try #require(pi.agent.paneID), sessionID: session.id)
        default: preconditionFailure()
        }
        try await eventually("native scope revoked during held publication") {
            try await rig.host.server.enqueue { (try? rig.host.server.publicationAuthority(task.workerAgentID)) == nil }
        }
        gate.signal()
        await #expect(throws: (any Error).self) { try await publishing.value }
        await mutation?.value
        #expect(!FileManager.default.fileExists(atPath: rig.host.dir.appendingPathComponent("logical-projects/\(project.id)/report.txt").path))
        #expect(FileManager.default.fileExists(atPath: rig.host.dir.appendingPathComponent("project-publications/\(id.uuidString.lowercased())/bytes").path) == staged)
    }

    @Test func failedProjectPersistenceNeverAcknowledgesPublicationAndSameIDRecoversSnapshot() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let source = try makeScratchDirectory()
        let (project, task) = try await worker(rig, cwd: source)
        let id = UUID(), url = rig.host.server.store.url, original = Data("original immutable bytes".utf8)
        try original.write(to: source.appendingPathComponent("source.txt"))
        #expect(try ProjectPublicationFiles.retained(id, beside: url) == nil)
        let authority = try await rig.host.server.enqueue { try rig.host.server.publicationAuthority(task.workerAgentID) }
        let snapshot = ProjectArtifactReceipt(id: id, key: authority.scope.key, taskID: task.id, workerAgentID: task.workerAgentID,
            sessionID: authority.scope.sessionID, generation: authority.scope.generation, artifactName: "report.txt", size: Int64(original.count),
            sha256: ProjectPublicationFiles.hash(original), sourceIdentity: ProjectPublicationFiles.hash(Data("source.txt".utf8)))
        try ProjectPublicationFiles.stage(original, receipt: snapshot, beside: url)
        #expect(chmod(rig.host.dir.path, 0o500) == 0)
        defer { _ = chmod(rig.host.dir.path, 0o700) }
        let request = ProjectPublicationRequest.publish(publicationID: id, sourcePath: "source.txt", artifactName: "report.txt")
        await #expect(throws: (any Error).self) { try await rig.host.server.projectPublish(task.workerAgentID, request: request) }
        #expect(rig.host.server.state.projects.first?.artifacts.isEmpty == true)
        #expect(try ProjectPublicationFiles.retained(id, beside: url)?.state == .staged)
        #expect(!FileManager.default.fileExists(atPath: rig.host.dir.appendingPathComponent("logical-projects/\(project.id)/report.txt").path))
        #expect(chmod(rig.host.dir.path, 0o700) == 0)
        try Data("mutated source must not replace a staged retry".utf8).write(to: source.appendingPathComponent("source.txt"))
        let result = try await rig.host.server.projectPublish(task.workerAgentID, request: request)
        #expect(result.artifact?.state == .ready)
        guard case .file(let file) = try await rig.host.server.logicalProjects(.read(projectID: project.id, path: "report.txt")) else { throw WireError("file") }
        #expect(file.data == original)
        try Data().write(to: source.appendingPathComponent("tool-1"))
        try await eventually("original publishing turn settled") { rig.host.server.state.projects.first?.tasks.first?.phase == .settled }
        _ = try await rig.perform(project.id, .followUp(taskID: task.id, operationID: UUID(), text: "tools:2 follow-up"))
        #expect(rig.host.server.state.projects.first?.artifacts.first?.id == result.artifact?.id)
        #expect(rig.host.server.state.projects.first?.artifacts.first?.key.operationID == task.operationID)
        try await eventually("follow-up native scope consumed") {
            try await rig.host.server.enqueue {
                guard let authority = try? rig.host.server.publicationAuthority(task.workerAgentID) else { return false }
                return authority.scope.key.operationID != task.operationID
            }
        }
        guard case .files(let listing) = try await rig.host.server.logicalProjects(.files(projectID: project.id, path: "")) else { throw WireError("retained artifact") }
        #expect(listing.entries.first?.taskID == task.id)
    }

    @Test func restartRecoversOnlyProvenCommittedBytesAndDoesNotResumeWork() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let source = try makeScratchDirectory()
        let (project, task) = try await worker(rig, cwd: source)
        let authority = try await rig.host.server.enqueue { try rig.host.server.publicationAuthority(task.workerAgentID) }
        let bytes = Data("recover me".utf8), url = rig.host.server.store.url
        let committed = ProjectArtifactReceipt(id: UUID(), key: authority.scope.key, taskID: task.id, workerAgentID: task.workerAgentID,
            sessionID: authority.scope.sessionID, generation: authority.scope.generation, artifactName: "committed.txt",
            size: Int64(bytes.count), sha256: ProjectPublicationFiles.hash(bytes), sourceIdentity: ProjectPublicationFiles.hash(Data("source.txt".utf8)))
        var uncommitted = committed; uncommitted.id = UUID(); uncommitted.artifactName = "staged.txt"; uncommitted.relativePath = "staged.txt"
        let pending = uncommitted
        _ = try await rig.host.server.updateRuntimeProject(project.id) { $0.artifacts = [committed, pending] }
        try await rig.host.server.publicationIO {
            try ProjectPublicationFiles.stage(bytes, receipt: committed, beside: url)
            try ProjectPublicationFiles.stage(bytes, receipt: pending, beside: url)
            try ProjectPublicationFiles.commit(committed, beside: url)
        }
        // Crash after rename but before ready metadata: immutable manifest + inode prove it.
        #expect(unlink(rig.host.dir.appendingPathComponent("project-publications/\(committed.id.uuidString.lowercased())/ready.json").path) == 0)
        rig.host.server.stop(); try rig.host.server.start()
        try await eventually("ready provenance recovered without worker permission") {
            rig.host.server.state.projects.first?.artifacts.first?.state == .ready
        }
        #expect(rig.host.server.state.projects.first?.artifacts.last?.state == .staged)
        #expect(rig.host.server.state.projects.first?.paused == true)
        #expect(try await rig.host.server.projectPublish(task.workerAgentID, request: .eligibility).active == false)
        #expect(!FileManager.default.fileExists(atPath: rig.host.dir.appendingPathComponent("logical-projects/\(project.id)/staged.txt").path))
        guard case .files(let listing) = try await rig.host.server.logicalProjects(.files(projectID: project.id, path: "")) else { throw WireError("files") }
        #expect(listing.entries.first?.taskID == task.id)
    }

    @Test func sourceTraversalLinksSpecialFilesSecretsAndOversizeAreRefused() throws {
        let source = try makeScratchDirectory(), outside = try makeScratchDirectory()
        let regular = source.appendingPathComponent("safe.txt")
        try Data("hello".utf8).write(to: regular)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.txt"), withDestinationURL: regular)
        #expect(link(regular.path, source.appendingPathComponent("hard.txt").path) == 0)
        #expect(mkfifo(source.appendingPathComponent("pipe").path, 0o600) == 0)
        try Data("api_key = sk-12345678901234567890123456".utf8).write(to: source.appendingPathComponent("secret.txt"))
        let big = source.appendingPathComponent("big.txt")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let file = try FileHandle(forWritingTo: big); try file.truncate(atOffset: UInt64(ProjectArtifactReceipt.maximumBytes + 1)); try file.close()
        for path in ["../escape", "/tmp/escape", ".pi/auth.json", "config/settings.txt", "a//b", "a\\b", "link.txt", "hard.txt", "safe.txt", "pipe", "secret.txt", "big.txt"] {
            #expect(throws: LogicalProjectsError.self) { try ProjectPublicationFiles.source(path, cwd: source.path, protected: [outside.path]) }
        }
        #expect(throws: LogicalProjectsError.self) { try ProjectPublicationFiles.source("secret.txt", cwd: source.path, protected: [source.path]) }
        let redirected = outside.appendingPathComponent("replaced-worktree")
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: source)
        try Data("harmless".utf8).write(to: source.appendingPathComponent("plain.txt"))
        #expect(throws: LogicalProjectsError.self) { try ProjectPublicationFiles.source("plain.txt", cwd: redirected.path, protected: []) }
        let fd = open(big.path, O_RDWR); defer { close(fd) }
        #expect(throws: LogicalProjectsError.self) { try ProjectPublicationFiles.readBounded(fd, limit: 10) }
        #expect(ftruncate(fd, 1) == 0 && lseek(fd, 0, SEEK_SET) == 0)
        var original = stat(); #expect(fstat(fd, &original) == 0)
        // The source grows after its admitted fstat but before descriptor reading.
        #expect(ftruncate(fd, off_t(ProjectArtifactReceipt.maximumBytes + 1)) == 0)
        #expect(throws: LogicalProjectsError.self) { try ProjectPublicationFiles.snapshot(fd, original: original) }
    }

    @Test(arguments: [false, true])
    func twoHostsPullRetainedOfflineBytesAfterSettlementWithoutAnotherTurn(restart: Bool) async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        let source = try makeScratchDirectory()
        var assignment = try await rig.assignment("tools:1")
        let space = Space(name: "Artifact sources", path: source.path)
        try await rig.host.server.addSpace(space)
        assignment.executorSpaceID = space.id; assignment.publicationsEnabled = true
        guard case .project(let project) = try await rig.owner.server.logicalProjects(.create(projectID: assignment.key.projectID, name: "Owner", goal: "")) else { throw WireError("owner") }
        assignment.key.ownerID = project.ownerID
        let hostID = UUID()
        let host = ProjectHostReference.remote(hostID: hostID, bindingID: UUID())
        let assigned = assignment
        _ = try await rig.owner.server.updateRuntimeProject(project.id) { owner in
            owner.settings.allowedHosts = [host]
            owner.linkedSpaces = [.init(spaceID: space.id, linkedAt: 0, host: host)]
            var task = ProjectTask(id: assigned.taskID, operationID: assigned.key.operationID, workerAgentID: assigned.reservedWorkerID,
                spaceID: space.id, title: assigned.title, prompt: assigned.prompt, phase: .running, host: host)
            task.executionAssignment = assigned
            owner.tasks = [task]
        }
        rig.owner.server.setProjectExecutionSpaces([host: [space]])
        rig.owner.server.onProjectRuntimeLaunch = { _, done in done(.failure(WireError("No owner model turn expected"))) }
        _ = try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: .resume)
        _ = try await rig.host.server.projectExecution(.execute(assignment))
        try await eventually("executor consumed publication scope") {
            try await rig.host.server.enqueue { (try? rig.host.server.publicationAuthority(assigned.reservedWorkerID)) != nil }
        }
        let bytes = Data(repeating: 65, count: ProjectArtifactReceipt.chunkBytes + 17)
        try bytes.write(to: source.appendingPathComponent("source.txt"))
        let staged = try await rig.host.server.projectPublish(assignment.reservedWorkerID,
            request: .publish(publicationID: UUID(), sourcePath: "source.txt", artifactName: "remote.txt"))
        #expect(staged.artifact?.state == .staged)
        try Data("do not overwrite".utf8).write(to: rig.owner.dir.appendingPathComponent("logical-projects/\(project.id)/taken.txt"))
        let collision = try await rig.host.server.projectPublish(assignment.reservedWorkerID,
            request: .publish(publicationID: UUID(), sourcePath: "source.txt", artifactName: "taken.txt"))
        #expect(collision.artifact?.state == .staged)
        #expect(rig.owner.server.state.projects.first?.artifacts.isEmpty == true)
        let pi = try await rig.pi(assignment)
        try Data().write(to: source.appendingPathComponent("tool-1"))
        try await eventually("offline worker settled") { rig.receipt(assigned)?.phase == .settled }
        let client = try await rig.remote.typed(); defer { client.disconnect() }
        // A connection that never returns a publication read cannot strand a transfer slot.
        try await rig.owner.server.enqueue { rig.owner.server.publicationTransferDuration = 0.05 }
        let blockedReads = Locked(0)
        rig.owner.server.onProjectPlacement = { _, request, completion in
            if case .publicationRead = request { blockedReads.withValue { $0 += 1 }; return }
            Task {
                do { completion(.success(try await client.projectExecution(request))) }
                catch { completion(.failure(error)) }
            }
        }
        rig.owner.server.reconcileProjectExecutions(host: host)
        try await eventually("bounded stalled transfer") {
            let idle = try await rig.owner.server.enqueue { rig.owner.server.publicationTransfers.isEmpty }
            return blockedReads.current > 0 && idle
        }
        #expect(rig.owner.server.state.projects.first?.artifacts.allSatisfy { $0.state == .staged } == true)
        #expect(pi.stdin("prompt").count == 1)
        if restart {
            rig.owner.server.stop(); try rig.owner.server.start()
            #expect(rig.owner.server.state.projects.first?.paused == true)
        }
        let replacement = ProjectHostReference.remote(hostID: hostID, bindingID: UUID())
        rig.owner.server.setProjectExecutionSpaces([replacement: [space]])
        let beforeReplacement = blockedReads.current
        rig.owner.server.reconcileProjectExecutions(host: host)
        try await eventually("old placement binding refuses artifact reads") {
            try await rig.owner.server.enqueue { rig.owner.server.projectPlacementReads.isEmpty && rig.owner.server.publicationTransfers.isEmpty }
        }
        #expect(blockedReads.current == beforeReplacement)
        #expect(rig.owner.server.state.projects.first?.artifacts.allSatisfy { $0.state == .staged } == true)
        rig.owner.server.setProjectExecutionSpaces([host: [space]])
        try await rig.owner.server.enqueue { rig.owner.server.publicationTransferDuration = ProjectArtifactReceipt.transferSeconds }
        let reads = Locked<[Int64]>([])
        rig.owner.server.onProjectPlacement = { binding, request, completion in
            guard binding == host else { completion(.failure(WireError("changed binding"))); return }
            if case .publicationRead(_, let id, let offset) = request, id == staged.artifact?.id { reads.withValue { $0.append(offset) } }
            Task {
                do { completion(.success(try await client.projectExecution(request))) }
                catch { completion(.failure(error)) }
            }
        }
        rig.owner.server.reconcileProjectExecutions(host: host)
        if restart {
            try await eventually("restarted owner reconciled metadata only") {
                try await rig.owner.server.enqueue { rig.owner.server.projectPlacementReads.isEmpty && rig.owner.server.publicationTransfers.isEmpty }
            }
            #expect(reads.current.isEmpty)
            #expect(rig.owner.server.state.projects.first?.artifacts.allSatisfy { $0.state == .staged } == true)
            #expect(!FileManager.default.fileExists(atPath: rig.owner.dir.appendingPathComponent("logical-projects/\(project.id)/remote.txt").path))
            _ = try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: .resume)
        }
        try await eventually("authorized owner committed retained artifact") { rig.owner.server.state.projects.first?.artifacts.first { $0.id == staged.artifact?.id }?.state == .ready }
        try await eventually("remote name collision is explicitly refused") {
            rig.owner.server.state.projects.first?.artifacts.first { $0.id == collision.artifact?.id }?.state == .refused
        }
        #expect(rig.owner.server.state.projects.first?.artifacts.first { $0.id == collision.artifact?.id }?.refusal == "artifact_collision")
        #expect(try String(contentsOf: rig.owner.dir.appendingPathComponent("logical-projects/\(project.id)/taken.txt"), encoding: .utf8) == "do not overwrite")
        let ready = try #require(rig.owner.server.state.projects.first?.artifacts.first { $0.id == staged.artifact?.id })
        #expect(ready.taskID == assignment.taskID && ready.executor == host)
        #expect(reads.current == [0, Int64(ProjectArtifactReceipt.chunkBytes)])
        #expect(try Data(contentsOf: rig.owner.dir.appendingPathComponent("logical-projects/\(project.id)/remote.txt")) == bytes)
        #expect(pi.stdin("prompt").count == 1)
        guard case .files(let listing) = try await rig.owner.server.logicalProjects(.files(projectID: project.id, path: "")) else { throw WireError("files") }
        #expect(listing.entries.first?.taskID == assignment.taskID)
        rig.owner.server.setProjectExecutionSpaces([:])
        await #expect(throws: LogicalProjectsError.self) {
            try await rig.owner.server.enqueue { _ = try rig.owner.server.publicationOwner(ready, epoch: rig.owner.server.logicalProjectEpoch) }
        }
        rig.host.server.advertisedCapabilities.removeAll { $0 == RemoteProtocol.projectPublicationsCapability }
        let old = try await rig.remote.typed(); defer { old.disconnect() }
        await #expect(throws: RemoteHostClientError.self) {
            try await old.projectExecution(.publicationRead(key: assigned.key, publicationID: ready.id, offset: 0))
        }
        await #expect(throws: RemoteHostClientError.self) { try await old.projectExecution(.execute(assigned)) }
    }

    @Test func privateStagingProvesCommitRecoveryAndNeverAdoptsForeignCollisions() throws {
        let host = try ScratchServer(); defer { host.stop() }
        let project = ProjectID(), state = host.server.store.url
        try LogicalProjectDirectory.create(id: project, beside: state)
        let bytes = Data("result".utf8)
        let receipt = ProjectArtifactReceipt(id: UUID(), key: .init(ownerID: UUID(), projectID: project, operationID: UUID()),
            taskID: .init(), workerAgentID: .init(), sessionID: "session", generation: "generation", artifactName: "report.txt",
            size: Int64(bytes.count), sha256: ProjectPublicationFiles.hash(bytes), sourceIdentity: ProjectPublicationFiles.hash(Data("source.txt".utf8)))
        try ProjectPublicationFiles.stage(bytes, receipt: receipt, beside: state)
        #expect(try ProjectPublicationFiles.retained(receipt.id, beside: state) == receipt)
        try ProjectPublicationFiles.commit(receipt, beside: state)
        // Lost reply / ready-state write failure recovers from manifest + consumed staged bytes.
        try ProjectPublicationFiles.commit(receipt, beside: state)
        var other = receipt; other.id = UUID()
        try ProjectPublicationFiles.stage(bytes, receipt: other, beside: state)
        #expect(throws: LogicalProjectsError.self) { try ProjectPublicationFiles.commit(other, beside: state) }
        #expect(try ProjectPublicationFiles.chunk(other, offset: 0, beside: state) == bytes)
        #expect(throws: LogicalProjectsError.self) { try ProjectPublicationFiles.chunk(other, offset: -1, beside: state) }
    }
}
