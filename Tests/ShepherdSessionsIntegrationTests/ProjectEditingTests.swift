import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project editing", .integrationTimeLimit)
struct ProjectEditingTests {
    @Test func metadataChangesNeverMoveFoldersAndRejectCycles() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let a = Space(name: "Platform A", path: h.dir.appendingPathComponent("a").path)
        let b = Space(name: "Platform B", path: h.dir.appendingPathComponent("b").path)
        let child = Space(name: "Docs", path: a.path + "/docs")
        try FileManager.default.createDirectory(atPath: child.path, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: child.path).appendingPathComponent("keep.txt")
        let bytes = Data("original".utf8)
        try bytes.write(to: file)
        try await h.server.putState(ShepherdState(spaces: [a, b, child]))
        let changed = try await h.server.editProject(child.id, edit: ProjectEdit(name: "Documentation", parentProjectID: b.id.rawValue))
        #expect(changed.name == "Documentation" && changed.path == child.path)
        #expect(changed.parentID == b.id && changed.parentIsExplicit)
        #expect(ProjectNesting.parents(in: h.server.state.spaces)[child.id] == b.id)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!FileManager.default.fileExists(atPath: b.path))
        await #expect(throws: ProjectFileError.self) {
            try await h.server.editProject(b.id, edit: ProjectEdit(parentProjectID: child.id.rawValue))
        }
        await #expect(throws: ProjectFileError.self) {
            try await h.server.editProject(child.id, edit: ProjectEdit(destinationPath: b.path + "/docs"))
        }
        let root = try await h.server.editProject(child.id, edit: ProjectEdit(parentProjectID: ""))
        #expect(root.parentID == nil && root.parentIsExplicit)
        #expect(ProjectNesting.parents(in: h.server.state.spaces)[child.id] == nil)
        #expect(try JSONDecoder().decode(ShepherdState.self, from: Data(contentsOf: h.stateURL)) == h.server.state)
    }

    @Test(arguments: [ProjectEdit.FolderAction.move, .copy])
    func explicitFolderActionsKeepContentsAndUpdateChildPaths(action: ProjectEdit.FolderAction) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let files = try makeScratchDirectory("project-files")
        defer { try? FileManager.default.removeItem(at: files) }
        let source = files.appendingPathComponent("source")
        let destination = files.appendingPathComponent("destination")
        let childURL = source.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        let bytes = Data("file contents".utf8)
        try bytes.write(to: childURL.appendingPathComponent("guide.md"))
        let parent = Space(name: "Platform", path: source.path)
        let child = Space(name: "docs", path: childURL.path)
        try await h.server.putState(ShepherdState(spaces: [parent, child]))
        let changed = try await h.server.editProject(parent.id, edit: ProjectEdit(folderAction: action, destinationPath: destination.path))
        #expect((changed.id == parent.id) == (action == .move))
        #expect(changed.path == destination.path)
        #expect(h.server.state.spaces.first { $0.id == child.id }?.path == (action == .move ? destination.appendingPathComponent("docs").path : child.path))
        if action == .copy { #expect(h.server.state.spaces.contains(parent)) }
        #expect(try Data(contentsOf: destination.appendingPathComponent("docs/guide.md")) == bytes)
        #expect(FileManager.default.fileExists(atPath: source.path) == (action == .copy))
        #expect(try JSONDecoder().decode(ShepherdState.self, from: Data(contentsOf: h.stateURL)) == h.server.state)
        await #expect(throws: ProjectFileError.self) {
            try await h.server.editProject(parent.id, edit: ProjectEdit(folderAction: .copy, destinationPath: destination.path))
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent("docs/guide.md")) == bytes)
    }

    @Test func folderActionsRefuseThreadsLinkedWorktreesAndProtectedState() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let files = try makeScratchDirectory("project-busy")
        defer { try? FileManager.default.removeItem(at: files) }
        let source = files.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let space = Space(name: "Busy", path: source.path)
        let agent = Fixture.agent(in: space, name: "work")
        try await h.server.putState(Fixture.workspace([agent], space: space))
        await #expect(throws: ProjectFileError.self) {
            try await h.server.editProject(space.id, edit: ProjectEdit(folderAction: .move, destinationPath: files.appendingPathComponent("moved").path))
        }
        try await h.server.putState(ShepherdState(spaces: [space]))
        try Data("gitdir: ../outside/.git\n".utf8).write(to: source.appendingPathComponent(".git"))
        await #expect(throws: ProjectFileError.self) {
            try await h.server.editProject(space.id, edit: ProjectEdit(folderAction: .copy, destinationPath: files.appendingPathComponent("copied").path))
        }
        try FileManager.default.removeItem(at: source.appendingPathComponent(".git"))
        try Data("ref: refs/heads/main\n".utf8).write(to: source.appendingPathComponent("HEAD"))
        for directory in ["objects", "worktrees"] { try FileManager.default.createDirectory(at: source.appendingPathComponent(directory), withIntermediateDirectories: false) }
        await #expect(throws: ProjectFileError.self) {
            try await h.server.editProject(space.id, edit: ProjectEdit(folderAction: .move, destinationPath: files.appendingPathComponent("bare-moved").path))
        }
        let protected = Space(name: "Runtime", path: h.dir.path)
        try await h.server.addSpace(protected)
        await #expect(throws: ProjectFileError.self) {
            try await h.server.editProject(protected.id, edit: ProjectEdit(folderAction: .move, destinationPath: files.appendingPathComponent("runtime").path))
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: files.appendingPathComponent("copied").path))
        _ = try await h.server.editProject(space.id, edit: ProjectEdit(name: "Still editable"))
    }

    @Test(arguments: [ProjectEdit.FolderAction.move, .copy])
    func failedPersistencePreservesFilesAndRestoresAMove(action: ProjectEdit.FolderAction) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let files = try makeScratchDirectory("project-rollback")
        defer { try? FileManager.default.removeItem(at: files) }
        let source = files.appendingPathComponent("source"), destination = files.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: source.appendingPathComponent("file"))
        let space = Space(name: "Project", path: source.path)
        try await h.server.addSpace(space)
        try FileManager.default.removeItem(at: h.stateURL)
        try FileManager.default.createDirectory(at: h.stateURL, withIntermediateDirectories: false)
        do {
            _ = try await h.server.editProject(space.id, edit: ProjectEdit(folderAction: action, destinationPath: destination.path))
            Issue.record("Expected failed state persistence")
        } catch let error as ProjectFileError {
            #expect(error.code == "registration_failed")
            #expect(error.description.contains(action == .move ? "moved back" : "left in place"))
        }
        #expect(try String(contentsOf: source.appendingPathComponent("file"), encoding: .utf8) == "keep")
        #expect(FileManager.default.fileExists(atPath: destination.path) == (action == .copy))
        if action == .copy { #expect(try String(contentsOf: destination.appendingPathComponent("file"), encoding: .utf8) == "keep") }
        #expect(h.server.state.spaces == [space])
    }

    @Test func oversizedCopiesAreRejectedBeforeCreatingADestination() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let files = try makeScratchDirectory("project-size")
        defer { try? FileManager.default.removeItem(at: files) }
        let source = files.appendingPathComponent("source"), destination = files.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let sparse = source.appendingPathComponent("large")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 2_147_483_649)
        try handle.close()
        let space = Space(name: "Project", path: source.path)
        try await h.server.addSpace(space)
        do {
            _ = try await h.server.editProject(space.id, edit: ProjectEdit(folderAction: .copy, destinationPath: destination.path))
            Issue.record("Expected transfer limit")
        } catch let error as ProjectFileError { #expect(error.code == "transfer_limit") }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(h.server.state.spaces == [space])
    }

    @Test func activeAgentDirectoryAliasesCannotOverwriteAProjectsDisplayName() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let root = h.dir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let space = Space(name: "Documentation", path: root.path + "/.")
        var agent = Fixture.agent(in: space)
        agent.tab.layout = .leaf(LeafPane(cwd: root.path, agentID: agent.agent.id))
        agent.agent.paneID = agent.tab.layout.firstLeaf.id
        try await h.server.putState(Fixture.workspace([agent], space: space))
        guard case .listing(let listing) = try await h.server.projects.request(.list(offset: 0), state: h.server.state) else {
            Issue.record("Expected listing"); return
        }
        #expect(listing.projects.first { $0.directory == root.path }?.name == "Documentation")
    }

    @Test func existingFolderSpellingIsPreservedAndNoDuplicateDirectoryIsCreated() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let parent = h.dir.appendingPathComponent("parent")
        let docs = parent.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let result = try await h.server.addChildProject(parentPath: parent.path, path: parent.appendingPathComponent("Docs").path, name: "Docs", create: true)
        #expect(result.space.path == docs.path)
        #expect(result.space.name == "docs")
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["docs"])
        let duplicate = try await h.server.addChildProject(parentPath: parent.path, path: parent.appendingPathComponent("DOCS").path, name: "DOCS", create: true)
        #expect(duplicate.space == result.space && !duplicate.created)
    }
}
