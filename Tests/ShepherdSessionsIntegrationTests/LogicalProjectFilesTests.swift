import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Owner Project artifacts", .integrationTimeLimit)
struct LogicalProjectFilesTests {
    private func create(_ host: ScratchServer, id: ProjectID = .init()) async throws -> (ProjectID, URL) {
        host.server.setProjectsEnabled(true)
        _ = try await host.server.logicalProjects(.create(projectID: id, name: "Artifacts", goal: ""))
        return (id, host.dir.appendingPathComponent("logical-projects/\(id)"))
    }

    private func refused(_ code: String, _ action: () async throws -> LogicalProjectsResult) async {
        do { _ = try await action(); Issue.record("Expected \(code)") }
        catch let error as LogicalProjectsError { #expect(error.code == code) }
        catch let error as RemoteHostClientError {
            guard case .rejected(let actual, _) = error else { Issue.record("Unexpected \(error)"); return }
            #expect(actual == code)
        } catch { Issue.record("Unexpected \(error)") }
    }

    @Test func listsRealOwnerArtifactsAndReadsBoundedTextAndImagesWithoutInventingProvenance() async throws {
        let h = try ScratchServer(); defer { h.stop() }
        let (id, root) = try await create(h)
        guard case .files(let empty) = try await h.server.logicalProjects(.files(projectID: id, path: "")) else { throw WireError("listing") }
        #expect(empty.entries.isEmpty && !empty.truncated)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("reports"), withIntermediateDirectories: false)
        let text = Data("🦊 owner report".utf8)
        try text.write(to: root.appendingPathComponent("reports/result.command"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1234)], ofItemAtPath: root.appendingPathComponent("reports/result.command").path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".pi"), withIntermediateDirectories: false)
        for path in [".pi/auth.json", "session.jsonl", "worker.log", "settings.json"] { try Data("secret context".utf8).write(to: root.appendingPathComponent(path)) }
        guard case .files(let top) = try await h.server.logicalProjects(.files(projectID: id, path: "")),
              case .files(let nested) = try await h.server.logicalProjects(.files(projectID: id, path: "reports")),
              case .file(let file) = try await h.server.logicalProjects(.read(projectID: id, path: "reports/result.command")) else { throw WireError("files") }
        #expect(top.entries.map(\.name) == ["reports"] && top.entries.first?.kind == .folder)
        #expect(nested.path == "reports" && !nested.truncated)
        #expect(nested.entries == [.init(name: "result.command", relativePath: "reports/result.command", kind: .file, size: Int64(text.count), modifiedAt: 1_234_000)])
        #expect(nested.entries.allSatisfy { $0.taskID == nil })
        #expect(file.data == text && file.mimeType == "text/plain; charset=utf-8")
        #expect(file.relativePath == "reports/result.command" && file.projectID == id)
        for (name, bytes, mime) in [("a.png", Data([137, 80, 78, 71, 13, 10, 26, 10]), "image/png"), ("a.jpg", Data([255, 216, 255]), "image/jpeg")] {
            try bytes.write(to: root.appendingPathComponent(name))
            guard case .file(let image) = try await h.server.logicalProjects(.read(projectID: id, path: name)) else { throw WireError("image") }
            #expect(image.data == bytes && image.mimeType == mime)
        }
        #expect(await h.server.listSessions().isEmpty)
    }

    @Test func traversalLinksSpecialFilesAndUnpublishedInternalPathsAreRefused() async throws {
        let h = try ScratchServer(); defer { h.stop() }
        let (id, root) = try await create(h)
        let outside = h.dir.appendingPathComponent("outside.txt")
        try Data("not an artifact".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: h.dir)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
        #expect(link(outside.path, root.appendingPathComponent("hard.txt").path) == 0)
        #expect(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0)
        for path in ["../outside.txt", outside.path, "escape/../outside.txt", "a\0b", "a//b", "./a", ".pi/auth.json", "session.jsonl", "worker.log", String(repeating: "a", count: 1025)] {
            await refused("invalid_path") { try await h.server.logicalProjects(.read(projectID: id, path: path)) }
        }
        for path in ["escape/outside.txt", "link.txt", "hard.txt", "pipe"] {
            await refused("project_directory") { try await h.server.logicalProjects(.read(projectID: id, path: path)) }
        }
        await refused("project_directory") { try await h.server.logicalProjects(.files(projectID: id, path: "escape")) }
        guard case .files(let listing) = try await h.server.logicalProjects(.files(projectID: id, path: "")) else { throw WireError("listing") }
        #expect(listing.entries.isEmpty)
        #expect(try Data(contentsOf: outside) == Data("not an artifact".utf8))
    }

    @Test func oversizeAndUnsupportedReadsFailAndListingsAndRepliesStayBounded() async throws {
        let h = try ScratchServer(); defer { h.stop() }
        let (id, root) = try await create(h)
        try Data(repeating: 65, count: LogicalProjectFile.maximumBytes + 1).write(to: root.appendingPathComponent("large.txt"))
        try Data([0, 255, 128]).write(to: root.appendingPathComponent("binary"))
        await refused("file_too_large") { try await h.server.logicalProjects(.read(projectID: id, path: "large.txt")) }
        await refused("unsupported_file") { try await h.server.logicalProjects(.read(projectID: id, path: "binary")) }
        let text = Data(repeating: 65, count: LogicalProjectFile.maximumBytes)
        try text.write(to: root.appendingPathComponent("limit.txt"))
        let read = try await h.server.logicalProjects(.read(projectID: id, path: "limit.txt"))
        guard case .file(let file) = read else { throw WireError("file") }
        #expect(file.data == text)
        #expect(try JSONEncoder().encode(RemoteReply.logicalProjects(id: 1, result: read)).count < 1_048_576)
        for index in 0...LogicalProjectFileListing.maximumEntries { try Data().write(to: root.appendingPathComponent("file-\(index)")) }
        let result = try await h.server.logicalProjects(.files(projectID: id, path: ""))
        guard case .files(let listing) = result else { throw WireError("listing") }
        #expect(listing.truncated && listing.entries.count == LogicalProjectFileListing.maximumEntries)
        #expect(try JSONEncoder().encode(RemoteReply.logicalProjects(id: 1, result: result)).count < 1_048_576)
    }

    @Test func TCPReadsTheForeignOwnersRootNotTheViewersAndOldHostsRefuseGracefully() async throws {
        let remote = try RemoteHost(); defer { remote.stop() }
        let viewer = try ScratchServer(); defer { viewer.stop() }
        let (id, root) = try await create(remote.host)
        let (_, viewerRoot) = try await create(viewer, id: id)
        try Data("owner bytes".utf8).write(to: root.appendingPathComponent("report.txt"))
        try Data("viewer bytes".utf8).write(to: viewerRoot.appendingPathComponent("report.txt"))
        let client = try await remote.typed(); defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.logicalProjectFilesCapability))
        guard case .file(let file) = try await client.logicalProjects(.read(projectID: id, path: "report.txt")),
              case .files(let files) = try await client.logicalProjects(.files(projectID: id, path: "")) else { throw WireError("remote files") }
        #expect(file.data == Data("owner bytes".utf8) && files.entries.first?.size == 11)
        remote.server.advertisedCapabilities.removeAll { $0 == RemoteProtocol.logicalProjectFilesCapability }
        let old = try await remote.typed(); defer { old.disconnect() }
        await refused("update_required") { try await old.logicalProjects(.files(projectID: id, path: "")) }
        #expect(try await old.logicalProjects(.list) == .projects(remote.server.state.projects))
        let raw = try await remote.raw()
        try raw.send(.logicalProjects(id: 99, request: .read(projectID: id, path: "report.txt")))
        guard case .error(99, let code, _) = try await raw.next() else { throw WireError("capability error") }
        #expect(code == "unsupported")
    }

    @Test func pendingArtifactRequestsAreBoundedWithoutBlockingOrdinaryProjectRequests() async throws {
        let h = try ScratchServer(); defer { h.stop() }
        let (id, _) = try await create(h)
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let pending = (0..<8).map { _ in Task { try await h.server.logicalProjects(.files(projectID: id, path: "")) } }
        try await eventually("artifact backpressure reached") {
            await withCheckedContinuation { c in h.server.queue.async { c.resume(returning: h.server.logicalProjectReadCount == 8) } }
        }
        await refused("project_busy") { try await h.server.logicalProjects(.files(projectID: id, path: "")) }
        #expect(try await h.server.logicalProjects(.list) == .projects(h.server.state.projects))
        gate.signal()
        for task in pending {
            guard case .files(let listing) = try await task.value else { throw WireError("listing") }
            #expect(listing.entries.isEmpty && !listing.truncated)
        }
    }

    @Test(arguments: ["restart", "edit", "delete"])
    func anAsyncReadCannotPublishAfterItsOwnerFenceChanges(_ change: String) async throws {
        let h = try ScratchServer(); defer { h.stop() }
        let (id, root) = try await create(h)
        try Data("old bytes".utf8).write(to: root.appendingPathComponent("a.txt"))
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        var mutation: Task<LogicalProjectsResult, Error>?
        if change != "restart" {
            mutation = Task { try await h.server.logicalProjects(change == "delete" ? .delete(projectID: id, expectedRevision: 1) : .edit(projectID: id, expectedRevision: 1, name: "Changed", goal: "")) }
            try await eventually("mutation staged before read") {
                await withCheckedContinuation { c in h.server.queue.async { c.resume(returning: h.server.logicalProjectSaveCount == 1) } }
            }
        }
        let pending = Task { try await h.server.logicalProjects(.read(projectID: id, path: "a.txt")) }
        try await eventually("read admitted off state queue") {
            await withCheckedContinuation { c in h.server.queue.async { c.resume(returning: h.server.logicalProjectReadCount == 1) } }
        }
        #expect(try await h.server.logicalProjects(.list) == .projects(h.server.state.projects))
        if change == "restart" { h.server.stop(); try h.server.start() }
        gate.signal()
        if let mutation { _ = try await mutation.value }
        await refused(change == "restart" ? "conflict" : change == "delete" ? "no_such_project" : "stale_project") { try await pending.value }
    }
}
