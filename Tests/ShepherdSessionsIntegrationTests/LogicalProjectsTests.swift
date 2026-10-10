import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Logical projects service", .integrationTimeLimit)
struct LogicalProjectsTests {
    private func value(_ result: LogicalProjectsResult) throws -> Project {
        guard case .project(let project) = result else { throw WireError("Expected a project") }
        return project
    }

    private func refusal(_ code: String, _ action: () async throws -> LogicalProjectsResult) async {
        do { _ = try await action(); Issue.record("Expected \(code)") }
        catch let error as LogicalProjectsError { #expect(error.code == code) }
        catch let error as RemoteHostClientError {
            guard case .rejected(let actual, _) = error else { Issue.record("Unexpected \(error)"); return }
            #expect(actual == code)
        } catch { Issue.record("Unexpected \(error)") }
    }

    @Test func localCreationIsIdempotentPrivatePersistedAndStartsNoSession() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let id = ProjectID()
        let request = LogicalProjectsRequest.create(projectID: id, name: "Release", goal: "Ship assigned work")
        let project = try value(await host.server.logicalProjects(request))
        #expect(project.settings.maxConcurrentWorkers == 3)
        #expect(!project.paused && project.coordinatorAgentID == nil)
        #expect(project.linkedSpaces.isEmpty && project.memory.isEmpty)
        #expect(try await host.server.logicalProjects(request) == .project(project))
        #expect(try await host.server.logicalProjects(.list) == .projects([project]))
        #expect(try await host.server.logicalProjects(.get(projectID: id)) == .project(project))
        #expect(try host.persisted().projects == [project])
        #expect(await host.server.listSessions().isEmpty)
        #expect(host.server.state.agents.isEmpty && host.server.state.spaces.isEmpty)
        for path in ["logical-projects", "logical-projects/\(id)"] {
            let attrs = try FileManager.default.attributesOfItem(atPath: host.dir.appendingPathComponent(path).path)
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
        try await eventually("project broadcast") { host.broadcasts.current.last?.projects == [project] }
        let updated = try value(await host.server.logicalProjects(.edit(projectID: id, expectedRevision: 1, name: "Edited", goal: "Goal")))
        #expect(try await host.server.logicalProjects(request) == .project(updated))
        #expect(host.server.state.projects.count == 1)
    }

    @Test func twoRemoteClientsUseTheOwnerStateAndRefuseEveryStaleMutationWithoutWrites() async throws {
        let remote = try RemoteHost()
        remote.server.setProjectsEnabled(true)
        defer { remote.stop() }
        let a = try await remote.typed(), b = try await remote.typed()
        defer { a.disconnect(); b.disconnect() }
        #expect(a.capabilities.contains(RemoteProtocol.logicalProjectsCapability))
        let pushed = Locked<[Project]>([])
        a.onStateChanged = { state in pushed.withValue { $0 = state.projects } }
        let id = ProjectID()
        let created = try value(await a.logicalProjects(.create(projectID: id, name: "Shared", goal: "")))
        let edited = try value(await b.logicalProjects(.edit(projectID: id, expectedRevision: created.revision, name: "By B", goal: "New")))
        let before = try Data(contentsOf: remote.host.stateURL)
        let memory = ProjectMemoryID(), space = SpaceID()
        let stale: [LogicalProjectsRequest] = [
            .edit(projectID: id, expectedRevision: 1, name: "Old", goal: ""),
            .settings(projectID: id, expectedRevision: 1, settings: .init()),
            .setPaused(projectID: id, expectedRevision: 1, paused: false),
            .addMemory(projectID: id, expectedRevision: 1, memoryID: memory, text: "Old", source: "user"),
            .forgetMemory(projectID: id, expectedRevision: 1, memoryID: memory),
            .linkSpace(projectID: id, expectedRevision: 1, spaceID: space),
            .unlinkSpace(projectID: id, expectedRevision: 1, spaceID: space),
            .delete(projectID: id, expectedRevision: 1),
        ]
        for request in stale { await refusal("stale_project") { try await a.logicalProjects(request) } }
        #expect(try Data(contentsOf: remote.host.stateURL) == before)
        #expect(try await a.logicalProjects(.get(projectID: id)) == .project(edited))
        #expect(try await b.logicalProjects(.list) == .projects([edited]))
        try await eventually("other client's project edit broadcast") { pushed.current == [edited] }
        #expect(try await b.logicalProjects(.delete(projectID: id, expectedRevision: edited.revision)) == .deleted(projectID: id))
        #expect(try await a.logicalProjects(.list) == .projects([]))
    }

    @Test func settingsMemorySpaceLinksAndPauseAreRealRevisionCheckedRemoteMutations() async throws {
        let remote = try RemoteHost()
        remote.server.setProjectsEnabled(true)
        defer { remote.stop() }
        let space = Space(name: "Repository", path: remote.host.dir.path)
        try await remote.host.seed(ShepherdState(spaces: [space]))
        let client = try await remote.typed()
        defer { client.disconnect() }
        let id = ProjectID(), memory = ProjectMemoryID()
        var project = try value(await client.logicalProjects(.create(projectID: id, name: "Project", goal: "")))
        let settings = LogicalProjectSettings(maxConcurrentWorkers: 6, conversationModel: "future/provider-model",
                                               threadModel: "stub/model-b", instructions: String(repeating: "🦊", count: 16_000), canRequestSpaceLinks: false)
        project = try value(await client.logicalProjects(.settings(projectID: id, expectedRevision: project.revision, settings: settings)))
        #expect(project.settings == settings)
        var tooLong = settings
        tooLong.instructions += "x"
        let invalid = tooLong, revision = project.revision
        await refusal("invalid_project") { try await client.logicalProjects(.settings(projectID: id, expectedRevision: revision, settings: invalid)) }
        await refusal("no_such_space") { try await client.logicalProjects(.linkSpace(projectID: id, expectedRevision: revision, spaceID: SpaceID())) }
        project = try value(await client.logicalProjects(.linkSpace(projectID: id, expectedRevision: project.revision, spaceID: space.id)))
        #expect(project.linkedSpaces.map(\.spaceID) == [space.id])
        #expect(project.linkedSpaces.first?.provenance == .user)
        #expect((project.linkedSpaces.first?.linkedAt ?? 0) > 0)
        project = try value(await client.logicalProjects(.unlinkSpace(projectID: id, expectedRevision: project.revision, spaceID: space.id)))
        #expect(project.linkedSpaces.isEmpty)
        project = try value(await client.logicalProjects(.addMemory(projectID: id, expectedRevision: project.revision, memoryID: memory, text: "Use staging", source: "user")))
        #expect(project.memory.map(\.id) == [memory])
        #expect(project.memory.first?.source == "user")
        #expect((project.memory.first?.createdAt ?? 0) > 0)
        project = try value(await client.logicalProjects(.forgetMemory(projectID: id, expectedRevision: project.revision, memoryID: memory)))
        #expect(project.memory.isEmpty)
        project = try value(await client.logicalProjects(.setPaused(projectID: id, expectedRevision: project.revision, paused: false)))
        #expect(!project.paused)
        project = try value(await client.logicalProjects(.setPaused(projectID: id, expectedRevision: project.revision, paused: true)))
        #expect(project.paused)
        #expect(try remote.host.persisted().projects == [project])
        #expect(await remote.server.listSessions().isEmpty)
    }

    @Test func restartPausesWithoutLaunchingAndClearsOnlyStaleCoordinatorReferences() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        let id = ProjectID()
        _ = try await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: ""))
        let resumed = try value(await host.server.logicalProjects(.setPaused(projectID: id, expectedRevision: 1, paused: false)))
        host.stop(keepFiles: true)
        var persisted = try host.persisted()
        persisted.projects[0].coordinatorAgentID = AgentID()
        try JSONEncoder().encode(persisted).write(to: host.stateURL, options: .atomic)
        let restarted = try ScratchServer(dir: host.dir)
        defer { restarted.stop() }
        let project = try #require(restarted.server.state.projects.first)
        #expect(project.paused)
        #expect(project.revision == resumed.revision + 1)
        #expect(project.coordinatorAgentID == nil)
        #expect(await restarted.server.listSessions().isEmpty)
        #expect(try restarted.persisted().projects == [project])
    }

    @Test func deletingRetainsOrdinaryAgentsWorktreesSpacesAndProjectArtifacts() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let worktree = host.dir.appendingPathComponent("worktree")
        _ = try git(["worktree", "add", "-b", "ordinary", worktree.path], in: repo)
        let space = Space(name: "Source", path: repo.path)
        var worker = Fixture.agent(in: space)
        worker.agent.worktreePath = worktree.path
        worker.agent.worktreeBranch = "ordinary"
        let state = Fixture.workspace([worker], space: space)
        try await host.seed(state)
        let id = ProjectID()
        _ = try await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: ""))
        let artifact = host.dir.appendingPathComponent("logical-projects/\(id)/keep.txt")
        try Data("keep".utf8).write(to: artifact)
        #expect(try await host.server.logicalProjects(.delete(projectID: id, expectedRevision: 1)) == .deleted(projectID: id))
        #expect(host.server.state == state)
        #expect(try Data(contentsOf: artifact) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath: worktree.path))
        #expect(try git(["branch", "--list", "ordinary"], in: repo).contains("ordinary"))
        await refusal("project_directory_exists") { try await host.server.logicalProjects(.create(projectID: id, name: "Reuse", goal: "")) }
    }

    @Test func filesystemFailuresAndUnknownDirectoriesNeverCommitOrRemoveAnything() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let root = host.dir.appendingPathComponent("logical-projects")
        let elsewhere = host.dir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: elsewhere)
        await refusal("project_directory") { try await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Symlink", goal: "")) }
        #expect(host.server.state.projects.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        try FileManager.default.removeItem(at: root) // removes only this test's symlink
        try Data("not a directory".utf8).write(to: root)
        await refusal("project_directory") { try await host.server.logicalProjects(.create(projectID: ProjectID(), name: "File", goal: "")) }
        #expect(try Data(contentsOf: root) == Data("not a directory".utf8))
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let id = ProjectID(), unknown = root.appendingPathComponent(ProjectID().rawValue)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        let unknownID = ProjectID(rawValue: unknown.lastPathComponent)
        await refusal("project_directory_exists") { try await host.server.logicalProjects(.create(projectID: unknownID, name: "Unknown", goal: "")) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(id.rawValue), withDestinationURL: elsewhere)
        await refusal("project_directory_exists") { try await host.server.logicalProjects(.create(projectID: id, name: "Link", goal: "")) }
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(host.server.state.projects.isEmpty)
    }

    @Test func persistenceFailureLeavesMetadataUnchangedAndRetainsTheStagedDirectory() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        try FileManager.default.createDirectory(at: host.stateURL, withIntermediateDirectories: false)
        let id = ProjectID()
        await #expect(throws: SessionServerError.self) {
            try await host.server.logicalProjects(.create(projectID: id, name: "No write", goal: ""))
        }
        #expect(host.server.state.projects.isEmpty)
        #expect(FileManager.default.fileExists(atPath: host.dir.appendingPathComponent("logical-projects/\(id)").path))
        await refusal("project_directory_exists") { try await host.server.logicalProjects(.create(projectID: id, name: "Retry", goal: "")) }
    }

    @Test func aStateStageWriteFailureLeavesTheExistingProjectAndFileUnchanged() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let id = ProjectID()
        let created = try value(await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: "")))
        let bytes = try Data(contentsOf: host.stateURL)
        #expect(chmod(host.dir.path, 0o500) == 0)
        defer { _ = chmod(host.dir.path, 0o700) }
        await #expect(throws: POSIXError.self) {
            try await host.server.logicalProjects(.settings(projectID: id, expectedRevision: 1, settings: .init(instructions: "Must not land")))
        }
        #expect(host.server.state.projects == [created])
        #expect(try Data(contentsOf: host.stateURL) == bytes)
    }

    @Test func initialSpaceLinksAreAtomicAndRetryDoesNotReplaceTheChosenPayload() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let space = Space(name: "Repo", path: host.dir.path)
        try await host.seed(ShepherdState(spaces: [space]))
        let id = ProjectID()
        await refusal("no_such_space") {
            try await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: "", linkedSpaceIDs: [space.id, SpaceID()]))
        }
        #expect(host.server.state.projects.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: host.dir.appendingPathComponent("logical-projects").path))
        let project = try value(await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: "", linkedSpaceIDs: [space.id])))
        #expect(project.linkedSpaces.map(\.spaceID) == [space.id])
        #expect(try await host.server.logicalProjects(.create(projectID: id, name: "Different", goal: "Different", linkedSpaceIDs: [])) == .project(project))
        #expect(try host.persisted().projects == [project])
    }

    @Test func directoryWorkDoesNotBlockTheServerAndSpaceValidationRepeatsBeforeCommit() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let space = Space(name: "Repo", path: host.dir.path)
        try await host.seed(ShepherdState(spaces: [space]))
        let gate = DispatchSemaphore(value: 0)
        host.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let id = ProjectID()
        let create = Task { try await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: "", linkedSpaceIDs: [space.id])) }
        try await eventually("directory staging admitted") {
            await withCheckedContinuation { continuation in
                host.server.queue.async { continuation.resume(returning: host.server.logicalProjectCreates.contains(id)) }
            }
        }
        // An unfenced duplicate does not create a second directory or silently overwrite the first.
        await refusal("project_busy") { try await host.server.logicalProjects(.create(projectID: id, name: "Other", goal: "")) }
        try await host.server.putState(ShepherdState())
        #expect(try await host.server.logicalProjects(.list) == .projects([]))
        gate.signal()
        await refusal("no_such_space") { try await create.value }
        #expect(host.server.state.projects.isEmpty)
        #expect(FileManager.default.fileExists(atPath: host.dir.appendingPathComponent("logical-projects/\(id)").path))
    }

    @Test func stagedSavesRecheckRevisionsAndNeverOverwriteAConcurrentWorkspaceChange() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let id = ProjectID()
        _ = try await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: ""))
        let gate = DispatchSemaphore(value: 0)
        host.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let first = Task { try await host.server.logicalProjects(.edit(projectID: id, expectedRevision: 1, name: "First", goal: "")) }
        try await eventually("first save staged") {
            await withCheckedContinuation { continuation in
                host.server.queue.async { continuation.resume(returning: host.server.logicalProjectSaveCount == 1) }
            }
        }
        let second = Task { try await host.server.logicalProjects(.edit(projectID: id, expectedRevision: 1, name: "Second", goal: "")) }
        try await eventually("second save staged") {
            await withCheckedContinuation { continuation in
                host.server.queue.async { continuation.resume(returning: host.server.logicalProjectSaveCount == 2) }
            }
        }
        gate.signal()
        let saved = try value(await first.value)
        await refusal("stale_project") { try await second.value }
        #expect(try host.persisted().projects == [saved])

        host.server.logicalProjectFiles.async { gate.wait() }
        let pending = Task { try await host.server.logicalProjects(.edit(projectID: id, expectedRevision: saved.revision, name: "Unsafe", goal: "")) }
        try await eventually("save waiting on disk") {
            await withCheckedContinuation { continuation in
                host.server.queue.async { continuation.resume(returning: host.server.logicalProjectSaveCount == 1) }
            }
        }
        var replacement = host.server.state
        replacement.spaces.append(Space(name: "Keep this", path: host.dir.path))
        try await host.server.putState(replacement)
        let bytes = try Data(contentsOf: host.stateURL)
        gate.signal()
        await refusal("workspace_changed") { try await pending.value }
        #expect(host.server.state == replacement)
        #expect(try Data(contentsOf: host.stateURL) == bytes)
    }

    @Test func pendingStateSavesAreBoundedAndOnlyOneRevisionWins() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let id = ProjectID()
        _ = try await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: ""))
        let gate = DispatchSemaphore(value: 0)
        host.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        var tasks: [Task<LogicalProjectsResult, Error>] = []
        for index in 0..<8 {
            tasks.append(Task { try await host.server.logicalProjects(.edit(projectID: id, expectedRevision: 1, name: "Save \(index)", goal: "")) })
        }
        try await eventually("save backpressure reached") {
            await withCheckedContinuation { continuation in
                host.server.queue.async { continuation.resume(returning: host.server.logicalProjectSaveCount == 8) }
            }
        }
        await refusal("project_busy") { try await host.server.logicalProjects(.setPaused(projectID: id, expectedRevision: 1, paused: true)) }
        gate.signal()
        var successful = 0
        for task in tasks {
            do { _ = try await task.value; successful += 1 }
            catch let error as LogicalProjectsError { #expect(error.code == "stale_project") }
        }
        #expect(successful == 1)
        #expect(host.server.state.projects.first?.revision == 2)
    }

    @Test func anOptionalCoordinatorReferenceDoesNotAuthorizeDeletingAnOrdinaryAgent() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        let space = Space(name: "Source", path: host.dir.path)
        let worker = Fixture.agent(in: space)
        try await host.seed(Fixture.workspace([worker], space: space))
        let id = ProjectID()
        _ = try await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: ""))
        host.stop(keepFiles: true)
        var disk = try host.persisted()
        disk.projects[0].coordinatorAgentID = worker.agent.id
        try JSONEncoder().encode(disk).write(to: host.stateURL, options: .atomic)
        let restarted = try ScratchServer(dir: host.dir)
        defer { restarted.stop() }
        restarted.server.setProjectsEnabled(true)
        let project = try #require(restarted.server.state.projects.first)
        #expect(project.coordinatorAgentID == worker.agent.id)
        _ = try await restarted.server.logicalProjects(.delete(projectID: id, expectedRevision: project.revision))
        #expect(restarted.server.state.agents == [worker.agent])
        #expect(restarted.server.state.tabs == [worker.tab])
        #expect(restarted.server.state.spaces == [space])
    }

    @Test func stoppingDuringDirectoryStagingCannotCreateAProjectAfterRestart() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let gate = DispatchSemaphore(value: 0)
        host.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let id = ProjectID()
        let pending = Task { try await host.server.logicalProjects(.create(projectID: id, name: "Never resurrect", goal: "")) }
        try await eventually("creation admitted") {
            await withCheckedContinuation { continuation in
                host.server.queue.async { continuation.resume(returning: host.server.logicalProjectCreates.contains(id)) }
            }
        }
        host.server.stop()
        try host.server.start()
        gate.signal()
        await refusal("conflict") { try await pending.value }
        #expect(host.server.state.projects.isEmpty)
        #expect(await host.server.listSessions().isEmpty)
    }

    @Test func projectCountLimitIsEnforcedByTheService() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        for index in 0..<Project.maximumCount {
            _ = try await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Project \(index)", goal: ""))
        }
        let rejected = ProjectID()
        await refusal("project_limit") { try await host.server.logicalProjects(.create(projectID: rejected, name: "Overflow", goal: "")) }
        #expect(host.server.state.projects.count == Project.maximumCount)
        #expect(!FileManager.default.fileExists(atPath: host.dir.appendingPathComponent("logical-projects/\(rejected)").path))
    }

    @Test func capabilityRefusalWorksBeforeSendingAndAtTheListener() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        remote.server.advertisedCapabilities.removeAll { $0 == RemoteProtocol.logicalProjectsCapability }
        let client = try await remote.typed()
        defer { client.disconnect() }
        #expect(!client.capabilities.contains(RemoteProtocol.logicalProjectsCapability))
        await refusal("update_required") { try await client.logicalProjects(.list) }
        let raw = try await remote.raw()
        try raw.send(.logicalProjects(id: 9, request: .list))
        guard case .error(9, let code, _) = try await raw.next() else { Issue.record("Expected refusal"); return }
        #expect(code == "unsupported")
        #expect(remote.server.state.projects.isEmpty)
    }

    @Test func invalidIDsAndNamesNeverReachTheFilesystemAndBulkStateCannotBypassRevisions() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        await refusal("invalid_project") { try await host.server.logicalProjects(.create(projectID: .init(rawValue: "../escape"), name: "Escape", goal: "")) }
        await refusal("invalid_project") { try await host.server.logicalProjects(.create(projectID: ProjectID(), name: " \n", goal: "")) }
        #expect(!FileManager.default.fileExists(atPath: host.dir.appendingPathComponent("logical-projects").path))
        await #expect(throws: LogicalProjectsError.self) {
            try await host.server.putState(ShepherdState(projects: [Project(name: "Bypass")]))
        }
    }
}
