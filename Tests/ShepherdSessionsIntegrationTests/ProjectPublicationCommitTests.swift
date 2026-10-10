import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project publication commit fences", .integrationTimeLimit)
struct ProjectPublicationCommitTests {
    @Test(arguments: ["pause", "disable", "disableEnable", "manual", "delete", "restart", "replacement"])
    func revocationAfterHashPreventsLocalRename(_ action: String) async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let source = try makeScratchDirectory()
        let (project, task) = try await ProjectPublicationTests().worker(rig, cwd: source)
        let pi = try #require(rig.agents.current[task.workerAgentID])
        try Data("prepared bytes".utf8).write(to: source.appendingPathComponent("source.txt"))
        let held = Locked<CheckedContinuation<Void, Never>?>(nil)
        defer { held.withValue { $0?.resume(); $0 = nil } }
        try await rig.host.server.enqueue {
            rig.host.server.publicationBeforeCommit = { await withCheckedContinuation { continuation in held.withValue { $0 = continuation } } }
        }
        let id = UUID()
        let publishing = Task { try await rig.host.server.projectPublish(task.workerAgentID,
            request: .publish(publicationID: id, sourcePath: "source.txt", artifactName: "report.txt")) }
        try await eventually("hashed snapshot before final rename") { held.current != nil }
        switch action {
        case "pause": _ = try await rig.perform(project.id, .pause)
        case "delete":
            _ = try await rig.host.server.logicalProjects(.delete(projectID: project.id, expectedRevision: rig.host.server.state.projects[0].revision))
        case "disable", "disableEnable":
            rig.host.server.setProjectsEnabled(false)
            if action == "disableEnable" { rig.host.server.setProjectsEnabled(true) }
        case "manual":
            _ = try await pi.send("tools:2 manual", delivery: .steer, from: pi.ready())
            try Data().write(to: source.appendingPathComponent("tool-1"))
        case "restart": rig.host.server.stop(); try rig.host.server.start()
        case "replacement":
            let session = try await rig.host.server.createSession(params: .init(cwd: source.path, command: StubPi.command, runtime: .rpc))
            try await rig.host.server.updatePaneSession(tabID: pi.agent.tabID, paneID: try #require(pi.agent.paneID), sessionID: session.id)
        default: preconditionFailure()
        }
        try await eventually("authority revoked before rename") {
            try await rig.host.server.enqueue { (try? rig.host.server.publicationAuthority(task.workerAgentID)) == nil }
        }
        held.withValue { $0?.resume(); $0 = nil }
        await #expect(throws: (any Error).self) { try await publishing.value }
        #expect(!FileManager.default.fileExists(atPath: rig.host.dir.appendingPathComponent("logical-projects/\(project.id)/report.txt").path))
        #expect(try ProjectPublicationFiles.retained(id, beside: rig.host.server.store.url)?.state == .staged)
    }

    @Test(arguments: ["pause", "disable", "disableEnable", "delete", "restart", "binding", "newRun"])
    func revocationAfterHashPreventsOwnerPullRename(_ action: String) async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let project = try await rig.create(), bytes = Data("retained remote bytes".utf8)
        let host = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        let space = Space(name: "Executor", path: "/unused")
        let task = ProjectTask(id: .init(), operationID: UUID(), workerAgentID: .init(), spaceID: space.id,
                               title: "Settled worker", prompt: "Done", phase: .settled, host: host)
        var artifact = ProjectArtifactReceipt(id: UUID(), key: .init(ownerID: project.ownerID, projectID: project.id, operationID: task.operationID),
            taskID: task.id, workerAgentID: task.workerAgentID, sessionID: "session", generation: "generation", artifactName: "remote.txt",
            size: Int64(bytes.count), sha256: ProjectPublicationFiles.hash(bytes), sourceIdentity: ProjectPublicationFiles.hash(Data("source.txt".utf8)))
        artifact.executor = host
        let receipt = artifact, url = rig.host.server.store.url
        try ProjectPublicationFiles.stage(bytes, receipt: receipt, beside: url)
        _ = try await rig.host.server.updateRuntimeProject(project.id) {
            $0.tasks = [task]; $0.artifacts = [receipt]; $0.settings.allowedHosts = [host]
            $0.linkedSpaces = [.init(spaceID: space.id, linkedAt: 0, host: host)]
        }
        rig.host.server.setProjectExecutionSpaces([host: [space]])
        rig.host.server.onProjectPlacement = { _, _, done in done(.failure(WireError("No network read needed for retained snapshot"))) }
        let held = Locked<CheckedContinuation<Void, Never>?>(nil)
        defer { held.withValue { $0?.resume(); $0 = nil } }
        try await rig.host.server.enqueue {
            rig.host.server.publicationBeforeCommit = { await withCheckedContinuation { continuation in held.withValue { $0 = continuation } } }
        }
        _ = try await rig.perform(project.id, .resume)
        try await eventually("remote snapshot hashed before owner rename") { held.current != nil }
        switch action {
        case "pause": _ = try await rig.perform(project.id, .pause)
        case "delete":
            _ = try await rig.host.server.logicalProjects(.delete(projectID: project.id, expectedRevision: rig.host.server.state.projects[0].revision))
        case "restart": rig.host.server.stop(); try rig.host.server.start()
        case "disable", "disableEnable":
            rig.host.server.setProjectsEnabled(false)
            if action == "disableEnable" { rig.host.server.setProjectsEnabled(true) }
        case "binding":
            guard case .remote(let hostID, _) = host else { preconditionFailure() }
            rig.host.server.setProjectExecutionSpaces([.remote(hostID: hostID, bindingID: UUID()): [space]])
        case "newRun":
            _ = try await rig.perform(project.id, .pause)
            try await eventually("pause acknowledged") { rig.host.server.state.projects.first?.interruptPending == false }
            _ = try await rig.perform(project.id, .resume)
        default: preconditionFailure()
        }
        held.withValue { $0?.resume(); $0 = nil }
        try await eventually("revoked owner transfer completed") {
            try await rig.host.server.enqueue { rig.host.server.publicationTransfers.isEmpty }
        }
        #expect(!FileManager.default.fileExists(atPath: rig.host.dir.appendingPathComponent("logical-projects/\(project.id)/remote.txt").path))
        #expect(try ProjectPublicationFiles.retained(receipt.id, beside: url) == receipt)
        #expect(rig.host.server.state.projects.first?.artifacts.first?.state != .ready)
    }

    @Test(arguments: ["bytes", "sameBytes", "replacement", "symlink", "link", "manifest", "directory", "staging", "ancestor", "stagingAncestor", "collision"])
    func preparedDescriptorsRefuseDirtyFilesAndReplacedDirectories(_ attack: String) throws {
        let host = try ScratchServer(); defer { host.stop() }
        let project = ProjectID(), url = host.server.store.url, bytes = Data("original".utf8)
        try LogicalProjectDirectory.create(id: project, beside: url)
        let receipt = ProjectArtifactReceipt(id: UUID(), key: .init(ownerID: UUID(), projectID: project, operationID: UUID()),
            taskID: .init(), workerAgentID: .init(), sessionID: "s", generation: "g", artifactName: "report.txt", size: Int64(bytes.count),
            sha256: ProjectPublicationFiles.hash(bytes), sourceIdentity: ProjectPublicationFiles.hash(Data("source.txt".utf8)))
        try ProjectPublicationFiles.stage(bytes, receipt: receipt, beside: url)
        let prepared = try ProjectPublicationFiles.prepareCommit(receipt, beside: url)
        let staging = host.dir.appendingPathComponent("project-publications/\(receipt.id.uuidString.lowercased())"), source = staging.appendingPathComponent("bytes")
        let target = host.dir.appendingPathComponent("logical-projects/\(project)/report.txt")
        switch attack {
        case "bytes": try Data("modified".utf8).write(to: source)
        case "sameBytes": try bytes.write(to: source)
        case "replacement", "symlink":
            let original = staging.appendingPathComponent("old")
            try FileManager.default.moveItem(at: source, to: original)
            if attack == "symlink" { try FileManager.default.createSymbolicLink(at: source, withDestinationURL: original) }
            else { try bytes.write(to: source) }
        case "manifest":
            let manifest = staging.appendingPathComponent("receipt.json")
            try Data(contentsOf: manifest).write(to: manifest)
        case "staging":
            try FileManager.default.moveItem(at: staging, to: staging.appendingPathExtension("old"))
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        case "stagingAncestor":
            let root = staging.deletingLastPathComponent()
            try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("old"))
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        case "link": #expect(link(source.path, staging.appendingPathComponent("alias").path) == 0)
        case "directory":
            let owner = target.deletingLastPathComponent()
            try FileManager.default.moveItem(at: owner, to: owner.appendingPathExtension("old"))
            try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: false)
        case "ancestor":
            let root = host.dir.appendingPathComponent("logical-projects")
            try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("old"))
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        case "collision": try Data("foreign".utf8).write(to: target)
        default: preconditionFailure()
        }
        #expect(throws: LogicalProjectsError.self) { try prepared.rename() }
        if attack == "collision" { #expect(try Data(contentsOf: target) == Data("foreign".utf8)) }
        else { #expect(!FileManager.default.fileExists(atPath: target.path)) }
    }

    @Test func rejectedSourcesDoNotAllocateLedgerIdentitiesAndAValidPublishStillWorks() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let source = try makeScratchDirectory()
        let (_, task) = try await ProjectPublicationTests().worker(rig, cwd: source)
        try Data("api_key = sk-12345678901234567890123456".utf8).write(to: source.appendingPathComponent("secret.txt"))
        try Data("valid".utf8).write(to: source.appendingPathComponent("valid.txt"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.txt"), withDestinationURL: source.appendingPathComponent("valid.txt"))
        let large = source.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let file = try FileHandle(forWritingTo: large); try file.truncate(atOffset: UInt64(ProjectArtifactReceipt.maximumBytes + 1)); try file.close()
        for index in 0..<132 {
            let path = ["missing-\(index).txt", "secret.txt", "large.txt", "link.txt"][index % 4]
            await #expect(throws: LogicalProjectsError.self) {
                try await rig.host.server.projectPublish(task.workerAgentID, request: .publish(publicationID: UUID(), sourcePath: path, artifactName: "rejected-\(index).txt"))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: rig.host.dir.appendingPathComponent("project-publications").path))
        let published = try await rig.host.server.projectPublish(task.workerAgentID,
            request: .publish(publicationID: UUID(), sourcePath: "valid.txt", artifactName: "valid.txt"))
        #expect(published.artifact?.state == .ready)
    }

    @Test func existingIncompleteOrCorruptIdentitiesRefuseAndRealSnapshotsStillFillTheLedger() throws {
        let host = try ScratchServer(); defer { host.stop() }
        let url = host.server.store.url, bytes = Data("ok".utf8)
        for name in ["empty", "bytes", "receipt.json"] {
            let id = UUID()
            try ProjectPublicationFiles.withStore(id, beside: url, create: true) { parent in
                if name != "empty" { try ProjectPublicationFiles.write(bytes, name: name, at: parent) }
            }
            #expect(throws: (any Error).self) { try ProjectPublicationFiles.retained(id, beside: url) }
        }
        let full = try ScratchServer(); defer { full.stop() }
        for _ in 0..<128 {
            let receipt = ProjectArtifactReceipt(id: UUID(), key: .init(ownerID: UUID(), projectID: .init(), operationID: UUID()),
                taskID: .init(), workerAgentID: .init(), sessionID: "s", generation: "g", artifactName: "report.txt", size: Int64(bytes.count),
                sha256: ProjectPublicationFiles.hash(bytes), sourceIdentity: ProjectPublicationFiles.hash(Data("source.txt".utf8)))
            try ProjectPublicationFiles.stage(bytes, receipt: receipt, beside: full.server.store.url)
            #expect(try ProjectPublicationFiles.retained(receipt.id, beside: full.server.store.url) == receipt)
        }
        #expect(try ProjectPublicationFiles.retained(UUID(), beside: full.server.store.url) == nil)
        #expect(throws: LogicalProjectsError.self) { try ProjectPublicationFiles.withStore(UUID(), beside: full.server.store.url, create: true) { _ in () } }
    }
}
