import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project conversation input images", .integrationTimeLimit)
struct ProjectMessageImagesTests {
    typealias Rig = ProjectRuntimeTests.Rig
    // A valid static 1x1 PNG, with valid IHDR/IDAT/IEND CRCs; never a user's photo.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    static var image: NativeImage { .init(mimeType: "image/png", data: png, name: "tiny.png") }

    private func blob(_ rig: Rig, _ id: ProjectID, _ operation: UUID, index: Int = 0) -> URL {
        rig.host.dir.appendingPathComponent("logical-projects/\(id)/.inputs/\(operation.uuidString.lowercased())/\(LogicalProjectDirectory.inputID(operation: operation, index: index).uuidString.lowercased())")
    }

    private func coordinator(_ rig: Rig, _ id: ProjectID) async throws -> PiAgent {
        try await eventually("coordinator launched") {
            guard let agent = rig.host.server.state.projects.first(where: { $0.id == id })?.coordinatorAgentID else { return false }
            return rig.agents.current[agent] != nil
        }
        let id = try #require(rig.host.server.state.projects.first(where: { $0.id == id })?.coordinatorAgentID)
        return try #require(rig.agents.current[id])
    }

    private func assertImage(_ prompt: [String: Any], text: String) throws {
        #expect(prompt["message"] as? String == text)
        let images = try #require(prompt["images"] as? [[String: Any]])
        #expect(images.count == 1)
        #expect(images.first?["mimeType"] as? String == "image/png")
        #expect(images.first?["data"] as? String == Self.png.base64EncodedString())
    }

    @Test(arguments: ["", "Describe this picture"])
    func firstMessageCarriesOriginalImageBytesAndRetriesNeverSendTwice(_ text: String) async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), operation = UUID()
        let sent = try await rig.perform(p.id, .message(operationID: operation, text: text, images: [Self.image]))
        let pi = try await coordinator(rig, p.id)
        try assertImage(await pi.waitForStdin("prompt"), text: text)
        try await eventually("image submission delivered") { rig.host.server.state.projects.first?.messages.first?.phase == .delivered }
        let before = try FileManager.default.attributesOfItem(atPath: blob(rig, p.id, operation).path)[.systemFileNumber] as? NSNumber
        let retry = try await rig.host.server.projectRuntime(p.id, expectedRevision: p.revision,
            request: .message(operationID: operation, text: "retry must not change payload", images: []))
        #expect(retry.messages.count == 1 && retry.messages[0].text == text)
        #expect(pi.stdin("prompt").count == 1)
        #expect(sent.messages.first?.images?.first?.byteCount == Self.png.count)
        let toolCopy = try await rig.host.server.projectTool(agentID: pi.agent.id, projectID: p.id, expectedRevision: 0, request: .read)
        #expect(toolCopy.messages.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(toolCopy), as: UTF8.self).contains("tiny.png"))
        #expect(try FileManager.default.attributesOfItem(atPath: blob(rig, p.id, operation).path)[.systemFileNumber] as? NSNumber == before)
    }

    @Test func pausedImageOnlySubmissionIsDurablePrivateAndExplicitResumeSendsItOnceAfterRestart() async throws {
        let rig = try Rig()
        let p = try await rig.create(), operation = UUID()
        _ = try await rig.perform(p.id, .pause)
        let queued = try await rig.perform(p.id, .message(operationID: operation, text: "", images: [Self.image]))
        #expect(queued.paused && queued.messages.first?.phase == .queued && queued.coordinatorAgentID == nil)
        #expect(await rig.host.server.listSessions().isEmpty)
        let stateBytes = try Data(contentsOf: rig.host.stateURL)
        #expect(!String(decoding: stateBytes, as: UTF8.self).contains(Self.png.base64EncodedString()))
        #expect(!String(decoding: try JSONEncoder().encode(LogicalProjectsResult.project(queued)), as: UTF8.self).contains(Self.png.base64EncodedString()))
        guard case .files(let listing) = try await rig.host.server.logicalProjects(.files(projectID: p.id, path: "")) else { throw WireError("files") }
        #expect(listing.entries.isEmpty)
        rig.host.server.onProjectRuntimeLaunch = nil; rig.host.stop(keepFiles: true)
        let restarted = try Rig(dir: rig.host.dir); defer { restarted.stop() }
        #expect(restarted.host.server.state.projects.first?.paused == true)
        #expect(restarted.host.server.state.projects.first?.messages.first?.images == queued.messages.first?.images)
        #expect(await restarted.host.server.listSessions().isEmpty)
        _ = try await restarted.perform(p.id, .resume)
        let pi = try await coordinator(restarted, p.id)
        try assertImage(await pi.waitForStdin("prompt"), text: "")
        try await eventually("restored submission delivered once") { restarted.host.server.state.projects.first?.messages.first?.phase == .delivered }
        _ = try await restarted.perform(p.id, .message(operationID: operation, text: "", images: [Self.image]))
        #expect(pi.stdin("prompt").count == 1)
    }

    @Test func pauseDuringNativePreparationKeepsTheOriginalImageQueuedUntilExplicitResume() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create()
        _ = try await rig.perform(p.id, .message(operationID: UUID(), text: "first"))
        let pi = try await coordinator(rig, p.id)
        _ = try await pi.waitForStdin("prompt")
        _ = try await pi.snapshot("initial turn settled") { !$0.running }
        let prepared = Locked<(() -> Void)?>(nil)
        try await rig.host.server.enqueue { rig.host.server.rpcThread(forAgent: pi.agent.id)?.beforePrompt = { done in prepared.withValue { $0 = done } } }
        let operation = UUID()
        _ = try await rig.perform(p.id, .message(operationID: operation, text: "image after pause", images: [Self.image]))
        try await eventually("image native preparation held") { prepared.current != nil }
        #expect(pi.stdin("prompt").count == 1)
        _ = try await rig.perform(p.id, .pause)
        try await eventually("unsent image requeued and pause acknowledged") {
            let p = rig.host.server.state.projects.first
            return p?.messages.last?.phase == .queued && p?.interruptPending == false
        }
        try await rig.host.server.enqueue {
            rig.host.server.rpcThread(forAgent: pi.agent.id)?.beforePrompt = nil
            prepared.current?()
        }
        #expect(pi.stdin("prompt").count == 1)
        _ = try await rig.perform(p.id, .resume)
        try assertImage(await pi.waitForStdin("prompt", count: 2), text: "image after pause")
        try await eventually("image delivered after resume") { rig.host.server.state.projects.first?.messages.last?.phase == .delivered }
        #expect(pi.stdin("prompt").count == 2)
    }

    @Test func restartDuringBlobStorageCannotAcceptOrSendTheOldSubmission() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create()
        let gate = DispatchSemaphore(value: 0)
        rig.host.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let pending = Task { try await rig.host.server.projectRuntime(p.id, expectedRevision: p.revision,
            request: .message(operationID: UUID(), text: "old lifecycle", images: [Self.image])) }
        try await eventually("image disk write admitted off state queue") {
            await withCheckedContinuation { c in rig.host.server.queue.async { c.resume(returning: rig.host.server.projectInputWriteCount == 1) } }
        }
        rig.host.server.stop(); try rig.host.server.start()
        gate.signal()
        await #expect(throws: LogicalProjectsError.self) { try await pending.value }
        #expect(rig.host.server.state.projects.first?.messages.isEmpty == true)
        #expect(await rig.host.server.listSessions().isEmpty)
    }

    @Test func anAcceptedImageWithUnknownConsumptionIsNotReplayedAfterRestartOrResume() async throws {
        let rig = try Rig()
        let p = try await rig.create()
        _ = try await rig.perform(p.id, .message(operationID: UUID(), text: "tools:0 hold-start", images: [Self.image]))
        let pi = try await coordinator(rig, p.id)
        try assertImage(await pi.waitForStdin("prompt"), text: "tools:0 hold-start")
        _ = try await pi.snapshot("accepted image awaiting user consumption") { $0.running }
        #expect(rig.host.server.state.projects.first?.messages.first?.phase == .delivering)
        rig.host.server.onProjectRuntimeLaunch = nil; rig.host.stop(keepFiles: true)
        let restarted = try Rig(dir: rig.host.dir); defer { restarted.stop() }
        #expect(restarted.host.server.state.projects.first?.paused == true)
        #expect(restarted.host.server.state.projects.first?.messages.first?.phase == .unknown)
        #expect(await restarted.host.server.listSessions().isEmpty)
        _ = try await restarted.perform(p.id, .resume)
        _ = try await restarted.perform(p.id, .message(operationID: UUID(), text: "new human message"))
        let new = try await coordinator(restarted, p.id)
        // The resumed coordinator uses the same scratch log file, which retains its old send.
        let prompt = try await new.waitForStdin("prompt", count: 2)
        #expect(prompt["message"] as? String == "new human message")
        #expect((prompt["images"] as? [[String: Any]] ?? []).isEmpty)
        #expect(new.stdin("prompt").count == 2)
        #expect(restarted.host.server.state.projects.first?.messages.first?.phase == .unknown)
    }

    @Test func invalidImagesCannotWriteBlobsOrAcceptAMessage() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create()
        let invalid: [[NativeImage]] = [Array(repeating: Self.image, count: 5),
            [.init(mimeType: "text/plain", data: Self.png)],
            [.init(mimeType: "image/png", data: Data(count: NativeImage.maxBytes + 1))],
            Array(repeating: .init(mimeType: "image/png", data: Data(count: NativeImage.maxBytes)), count: 3)]
        for images in invalid {
            await #expect(throws: LogicalProjectsError.self) { try await rig.perform(p.id, .message(operationID: UUID(), text: "Do not send text alone", images: images)) }
        }
        #expect(rig.host.server.state.projects.first?.messages.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: rig.host.dir.appendingPathComponent("logical-projects/\(p.id)/.inputs").path))
        #expect(await rig.host.server.listSessions().isEmpty)
    }

    @Test func concurrentDuplicateUploadsShareOneReceiptAndStorageBackpressureIsBounded() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), operation = UUID()
        _ = try await rig.perform(p.id, .pause)
        try await eventually("pause receipt settled") { rig.host.server.state.projects.first?.interruptPending == false }
        let revision = try #require(rig.host.server.state.projects.first?.revision)
        let gate = DispatchSemaphore(value: 0)
        rig.host.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let pending = (0..<8).map { _ in Task { try await rig.host.server.projectRuntime(p.id, expectedRevision: revision,
            request: .message(operationID: operation, text: "", images: [Self.image])) } }
        try await eventually("eight input writes pending") {
            await withCheckedContinuation { c in rig.host.server.queue.async { c.resume(returning: rig.host.server.projectInputWriteCount == 8) } }
        }
        do {
            _ = try await rig.host.server.projectRuntime(p.id, expectedRevision: revision, request: .message(operationID: UUID(), text: "", images: [Self.image]))
            Issue.record("Expected input storage backpressure")
        } catch let error as LogicalProjectsError { #expect(error.code == "project_busy") }
        gate.signal()
        for request in pending { #expect(try await request.value.messages.count == 1) }
        #expect(rig.host.server.state.projects.first?.messages.map(\.id) == [operation])
        #expect(try FileManager.default.contentsOfDirectory(atPath: blob(rig, p.id, operation).deletingLastPathComponent().path).count == 1)
        #expect(await rig.host.server.listSessions().isEmpty)
    }

    @Test func failedReceiptWriteRetainsImmutableBlobForRetryAndNeverSendsTextOnly() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), operation = UUID()
        _ = try await rig.perform(p.id, .pause)
        #expect(chmod(rig.host.dir.path, 0o500) == 0)
        defer { _ = chmod(rig.host.dir.path, 0o700) }
        await #expect(throws: (any Error).self) { try await rig.perform(p.id, .message(operationID: operation, text: "with image", images: [Self.image])) }
        #expect(rig.host.server.state.projects.first?.messages.isEmpty == true)
        #expect(await rig.host.server.listSessions().isEmpty)
        let original = try FileManager.default.attributesOfItem(atPath: blob(rig, p.id, operation).path)[.systemFileNumber] as? NSNumber
        #expect(chmod(rig.host.dir.path, 0o700) == 0)
        let accepted = try await rig.perform(p.id, .message(operationID: operation, text: "with image", images: [Self.image]))
        #expect(accepted.messages.count == 1)
        #expect(try FileManager.default.attributesOfItem(atPath: blob(rig, p.id, operation).path)[.systemFileNumber] as? NSNumber == original)
    }

    @Test(arguments: ["missing", "symlink", "hardlink", "fifo"])
    func unavailableOrSubstitutedInputCannotFallBackToTextOnly(_ kind: String) async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create(), operation = UUID()
        _ = try await rig.perform(p.id, .pause)
        _ = try await rig.perform(p.id, .message(operationID: operation, text: "requires image", images: [Self.image]))
        let path = blob(rig, p.id, operation)
        let external = rig.host.dir.appendingPathComponent("external.png")
        try Self.png.write(to: external)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: external.path)
        try FileManager.default.removeItem(at: path)
        switch kind {
        case "symlink": try FileManager.default.createSymbolicLink(at: path, withDestinationURL: external)
        case "hardlink": #expect(link(external.path, path.path) == 0)
        case "fifo": #expect(mkfifo(path.path, 0o600) == 0)
        default: break
        }
        _ = try await rig.perform(p.id, .resume)
        try await eventually("input failure stops without sending") { rig.host.server.state.projects.first?.messages.first?.phase == .failed }
        let pi = try await coordinator(rig, p.id)
        #expect(pi.stdin("prompt").isEmpty)
        #expect(try Data(contentsOf: external) == Self.png)
    }

    @Test func localNativeImageLimitsAllowFiveMiBWithoutPuttingBytesInProjectState() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create()
        _ = try await rig.perform(p.id, .pause)
        let images = [NativeImage(mimeType: "image/png", data: Data(count: NativeImage.maxBytes)),
                      NativeImage(mimeType: "image/png", data: Data(count: NativeImage.maxBytes)),
                      NativeImage(mimeType: "image/png", data: Data(count: 1024 * 1024))]
        let accepted = try await rig.perform(p.id, .message(operationID: UUID(), text: "", images: images))
        let message = try #require(accepted.messages.first)
        #expect(message.images?.reduce(0, { $0 + $1.byteCount }) == NativeImage.maxBytesPerSend)
        let loaded: [NativeImage] = try await withCheckedThrowingContinuation { continuation in
            rig.host.server.logicalProjectFiles.async {
                continuation.resume(with: Result { try LogicalProjectDirectory.loadInputs(id: p.id, message: message, beside: rig.host.stateURL) })
            }
        }
        #expect(loaded == images)
        #expect(try Data(contentsOf: rig.host.stateURL).count < Project.maximumEncodedCollectionBytes)
        #expect(await rig.host.server.listSessions().isEmpty)
    }

    @Test func anUntrustedInputDirectoryCannotCaptureUploads() async throws {
        let rig = try Rig(); defer { rig.stop() }
        let p = try await rig.create()
        let outside = rig.host.dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: rig.host.dir.appendingPathComponent("logical-projects/\(p.id)/.inputs"), withDestinationURL: outside)
        await #expect(throws: LogicalProjectsError.self) { try await rig.perform(p.id, .message(operationID: UUID(), text: "image", images: [Self.image])) }
        #expect(rig.host.server.state.projects.first?.messages.isEmpty == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func remoteFramesAreBoundedBeforeSendingAndOnlyTheAuthenticatedOwnerReceivesBytes() async throws {
        let owner = try Rig(); defer { owner.stop() }
        let viewer = try Rig(); defer { viewer.stop() }
        let p = try await owner.create(), foreign = try await viewer.create()
        let calls = Locked(0), server = owner.host.server
        server.onProjectRuntimeRequest = { [weak server] request, done in
            calls.withValue { $0 += 1 }
            guard let server, case .action(let id, let revision, let action) = request else { done(.failure(WireError("action"))); return }
            Task { do { done(.success(.project(try await server.projectRuntime(id, expectedRevision: revision, request: action)))) } catch { done(.failure(error)) } }
        }
        defer { server.onProjectRuntimeRequest = nil }
        let tokenURL = owner.host.dir.appendingPathComponent("remote-token")
        let port = try server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient(); defer { client.disconnect() }
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "viewer")
        #expect(client.capabilities.contains(RemoteProtocol.projectMessageImagesCapability))
        let over = NativeImage(mimeType: "image/png", data: Data(count: 800_000))
        do {
            _ = try await client.projectRuntime(.action(projectID: p.id, expectedRevision: p.revision, request: .message(operationID: UUID(), text: "", images: [over])))
            Issue.record("Expected frame refusal")
        } catch let error as RemoteHostClientError { if case .rejected(let code, _) = error { #expect(code == "too_large") } else { Issue.record("\(error)") } }
        #expect(calls.current == 0 && server.state.projects.first?.messages.isEmpty == true)
        await #expect(throws: RemoteHostClientError.self) {
            try await client.projectRuntime(.action(projectID: foreign.id, expectedRevision: foreign.revision, request: .message(operationID: UUID(), text: "", images: [Self.image])))
        }
        #expect(viewer.host.server.state.projects.first?.messages.isEmpty == true)
        let operation = UUID()
        _ = try await viewer.host.server.logicalProjects(.create(projectID: p.id, name: "Same ID on viewer", goal: ""))
        let decoy = blob(viewer, p.id, operation)
        try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("viewer-local decoy, never read".utf8).write(to: decoy)
        _ = try await client.projectRuntime(.action(projectID: p.id, expectedRevision: p.revision, request: .message(operationID: operation, text: "owner image", images: [Self.image])))
        try assertImage(await coordinator(owner, p.id).waitForStdin("prompt"), text: "owner image")
        #expect(try Data(contentsOf: blob(owner, p.id, operation)) == Self.png)
        #expect(try Data(contentsOf: decoy) == Data("viewer-local decoy, never read".utf8))
        #expect(!FileManager.default.fileExists(atPath: blob(viewer, foreign.id, operation).path))
        let before = calls.current
        server.advertisedCapabilities.removeAll { $0 == RemoteProtocol.projectMessageImagesCapability }
        let old = RemoteHostClient(); defer { old.disconnect() }
        _ = try await old.connect(host: "127.0.0.1", port: port, token: token, clientName: "old")
        do {
            _ = try await old.projectRuntime(.action(projectID: p.id, expectedRevision: p.revision, request: .message(operationID: UUID(), text: "", images: [Self.image])))
            Issue.record("Expected old-host refusal")
        } catch let error as RemoteHostClientError { if case .rejected(let code, _) = error { #expect(code == "update_required") } else { Issue.record("\(error)") } }
        #expect(calls.current == before)
        let raw = try RawRemote(port: port)
        try await raw.hello(token: token)
        try raw.send(.logicalProjectRuntime(id: 19, request: .action(projectID: p.id, expectedRevision: p.revision,
            request: .message(operationID: UUID(), text: "", images: [Self.image]))))
        guard case .error(19, let code, _) = try await raw.next() else { throw WireError("old listener refusal") }
        #expect(code == "unsupported" && calls.current == before)
        let bad = RemoteHostClient(); defer { bad.disconnect() }
        await #expect(throws: (any Error).self) { try await bad.connect(host: "127.0.0.1", port: port, token: "wrong", clientName: "unauthenticated") }
        #expect(calls.current == before)
    }
}
