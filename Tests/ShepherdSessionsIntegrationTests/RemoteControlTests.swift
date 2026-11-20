import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Remote requests that change the host or ask the host GUI to act: pane control, spaces,
/// agent creation and actions, host directories, uploads, and the native thread over TCP.
@Suite("Remote control", .integrationTimeLimit)
struct RemoteControlTests {
    // MARK: - Terminal control

    /// A client from before terminals were tabs only asks to split beside a pane, in an axis: the
    /// wire still says so, and the host's handler gets the request as it came (it opens a tab).
    @Test func terminalRequestsRouteThroughTheHostHandler() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let (agentID, anchor, opened) = (AgentID(), PaneID(), PaneID())
        let seen = Locked<[PaneRequest]>([])
        r.server.onRemotePaneRequest = { request, respond in
            seen.withValue { $0.append(request) }
            if case .open = request {
                respond(.opened(PaneInfo(id: opened, cwd: "/tmp", isAgentPane: false, isFocused: false, isAlive: true)))
            } else {
                respond(.ok)
            }
        }
        let client = try await r.typed()
        defer { client.disconnect() }

        #expect(try await client.openPane(agentID: agentID, relativeTo: anchor, axis: .vertical) == opened)
        #expect(try await client.openPane(agentID: agentID, relativeTo: anchor, axis: .horizontal) == opened)
        try await client.closePane(agentID: agentID, paneID: opened)
        #expect(seen.current == [
            .open(agentID: agentID, axis: .vertical, cwd: nil, relativeTo: anchor, command: nil),
            .open(agentID: agentID, axis: .horizontal, cwd: nil, relativeTo: anchor, command: nil),
            .close(agentID: agentID, paneID: opened),
        ])
    }

    /// An older client's divider drag: terminals have no splits, so the host answers it as it
    /// answers what it does not serve, never reaches its handler, and keeps the connection.
    @Test func anOlderClientsSplitResizeIsAnsweredUnsupportedAndNeverReachesTheHandler() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let seen = Locked<[PaneRequest]>([])
        r.server.onRemotePaneRequest = { request, respond in
            seen.withValue { $0.append(request) }
            respond(.ok)
        }
        let agentID = AgentID()
        let split = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(LeafPane(cwd: "/tmp")), second: .leaf(LeafPane(cwd: "/tmp")))
        let client = try await r.typed()
        defer { client.disconnect() }

        do {
            try await client.resizePaneSplit(agentID: agentID, split: split, ratio: 0.7)
            Issue.record("the resize was accepted")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == "unsupported")
            #expect(message == "Terminals are tabs and have no splits to resize.")
        }
        let closing = PaneID()
        try await client.closePane(agentID: agentID, paneID: closing)
        #expect(seen.current == [.close(agentID: agentID, paneID: closing)], "only the close reached the handler, on the same connection")
    }

    @Test func terminalRequestsFailCleanlyWithoutAHandlerOrWithAWrongOutcome() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.raw()
        try client.send(.closePane(id: 3, agentID: AgentID(), paneID: PaneID()))
        #expect(try await client.next() == .error(id: 3, code: "unsupported", message: "host cannot mutate terminals"))

        r.server.onRemotePaneRequest = { _, respond in respond(.panes([])) }
        try client.send(.closePane(id: 4, agentID: AgentID(), paneID: PaneID()))
        #expect(try await client.next() == .error(id: 4, code: "protocol", message: "unexpected terminal reply"))
        r.server.onRemotePaneRequest = { _, respond in respond(.failed(code: "not_closable", message: "the layout's only terminal cannot be closed")) }
        try client.send(.closePane(id: 5, agentID: AgentID(), paneID: PaneID()))
        #expect(try await client.next() == .error(id: 5, code: "not_closable", message: "the layout's only terminal cannot be closed"))
    }

    // MARK: - Spaces and directories

    /// A remote space is pure state: the space alone, with no layout, in one snapshot.
    @Test func addSpaceCreatesTheSpaceWithoutALayout() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let folder = try makeScratchDirectory("project")
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = try await r.typed()
        defer { client.disconnect() }

        let spaceID = try await client.addSpace(path: folder.path)
        #expect(r.server.state == ShepherdState(spaces: [Space(id: spaceID, name: folder.lastPathComponent, path: folder.path)]))
        await drainMainQueue()
        #expect(r.host.broadcasts.current.count == 1)
    }

    /// A project added from another Mac goes on top, as one added on this Mac does.
    @Test func aRemotelyAddedSpaceGoesFirst() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let existing = Fixture.space("existing")
        try await r.server.addSpace(existing)
        let folder = try makeScratchDirectory("project")
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = try await r.typed()
        defer { client.disconnect() }

        let spaceID = try await client.addSpace(path: folder.path)
        #expect(r.server.state.spaces.map(\.id) == [spaceID, existing.id])
    }

    @Test func addSpaceRejectsDuplicatesAndMissingDirectories() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let folder = try makeScratchDirectory("project")
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = try await r.raw()
        try client.send(.addSpace(id: 1, path: folder.path))
        _ = try await client.frames(until: { if case .spaceAdded = $0 { true } else { false } })

        try client.send(.addSpace(id: 2, path: folder.path))
        guard case .error(2, "conflict", _) = try await client.next() else { Issue.record("expected conflict"); return }
        try client.send(.addSpace(id: 3, path: "/definitely/not/a/dir"))
        guard case .error(3, "no_such_directory", _) = try await client.next() else { Issue.record("expected no_such_directory"); return }
        #expect(r.server.state.spaces.count == 1)
    }

    @Test func listDirReturnsSortedSubdirectoriesIncludingHiddenOnes() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let folder = try makeScratchDirectory("browse")
        defer { try? FileManager.default.removeItem(at: folder) }
        let directories = ["beta", "Alpha", ".pi"] + (0..<2_100).map { "folder-\($0)" }
        for name in directories {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("file.txt").path, contents: Data())
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked"), withDestinationURL: folder.appendingPathComponent("beta"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("broken"), withDestinationURL: folder.appendingPathComponent("missing"))
        let client = try await r.typed()
        defer { client.disconnect() }

        let listing = try await client.listDir(path: folder.path)
        #expect(listing.path == folder.path)
        #expect(listing.dirs == (directories + ["linked"]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(listing.parent == folder.deletingLastPathComponent().path)
        await #expect(throws: RemoteHostClientError.self) { _ = try await client.listDir(path: folder.appendingPathComponent("missing").path) }
    }

    @Test func heldDirectoryReadsKeepTheServerResponsiveAndStayReservedAfterTimeout() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let folder = try makeScratchDirectory("held-directory")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("child"), withIntermediateDirectories: true)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let reads = Locked(0)
        let cancelled = Locked(0)
        r.server.enumerateRemoteDirectory = { path in
            let number = reads.withValue { $0 += 1; return $0 }
            if number <= SessionServer.directoryReadLimit {
                signal.yield(())
                release.wait()
                if Task.isCancelled { cancelled.withValue { $0 += 1 } }
            }
            return try FileManager.default.contentsOfDirectory(atPath: path)
        }
        // Exercise the production five-second deadline, without a wall-clock performance assertion.
        #expect(SessionServer.directoryReadTimeout == 5 && SessionServer.directoryReadLimit == 2)
        defer { release.signal(); release.signal(); signal.finish() }
        let client = try await r.raw()
        try client.send(.listDir(id: 10, path: folder.path))
        try client.send(.listDir(id: 11, path: folder.path))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        try client.send(.listDir(id: 12, path: folder.path))
        guard case .error(12, "busy", _) = try await client.next() else { Issue.record("expected busy"); return }
        try client.send(.stateFetch(id: 13))
        guard case .state(13, _) = try await client.next() else {
            Issue.record("the server must handle other requests while filesystem reads are held"); return
        }
        var timedOut: Set<Int> = []
        for _ in 0..<2 {
            guard case .error(let id, "timeout", _) = try await client.next() else { Issue.record("expected timeout"); return }
            timedOut.insert(id)
        }
        #expect(timedOut == [10, 11])
        try client.send(.listDir(id: 14, path: folder.path))
        guard case .error(14, "busy", _) = try await client.next() else { Issue.record("timed-out syscalls must retain their slots"); return }
        release.signal(); release.signal()
        try await eventually("cancelled filesystem calls exit") { cancelled.current == 2 }
        try await eventually("directory slots become available without publishing stale replies") {
            try client.send(.listDir(id: 15, path: folder.path))
            switch try await client.next() {
            case .error(15, "busy", _): return false
            case .dirListing(15, _, _, let dirs): return dirs == ["child"]
            default: Issue.record("unexpected stale directory reply"); return true
            }
        }
        #expect(reads.current == 3)
    }

    @Test func replacedDirectoryRequestsCancelWithoutPublishingTheirOldReply() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let folder = try makeScratchDirectory("replaced-directory")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let reads = Locked(0)
        let cancelled = Locked(false)
        r.server.enumerateRemoteDirectory = { path in
            if reads.withValue({ $0 += 1; return $0 }) == 1 {
                signal.yield(())
                release.wait()
                cancelled.withValue { $0 = Task.isCancelled }
            }
            return try FileManager.default.contentsOfDirectory(atPath: path)
        }
        defer { release.signal(); signal.finish() }
        let client = try await r.raw()
        try client.send(.listDir(id: 10, path: folder.path))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        try client.send(.listDir(id: 10, path: folder.path))
        guard case .dirListing(10, _, _, _) = try await client.next() else { Issue.record("expected replacement listing"); return }
        release.signal()
        try await eventually("replaced read observes cancellation") { cancelled.current }
        client.closeConnection()
        let replacement = try await r.typed()
        defer { replacement.disconnect() }
        #expect(try await replacement.listDir(path: folder.path).dirs.isEmpty)
    }

    // MARK: - Agents

    @Test func createAgentHandsTheWholeRequestToTheHost() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        try await r.host.seed(ShepherdState(spaces: [space]))
        let minted = AgentID()
        let seen = Locked<RemoteCreateAgentRequest?>(nil)
        r.server.onRemoteCreateAgent = { request, done in seen.withValue { $0 = request }; done(.success(minted)) }
        let client = try await r.typed()
        defer { client.disconnect() }

        let image = NativeImage(mimeType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]), name: "shot.png")
        let id = try await client.createAgent(spaceID: space.id, cwd: "/tmp/checkout", model: "some/model", thinking: .high, initialPrompt: "hello",
                                              worktreeBranch: "worktree/x", worktreeBase: "origin/main", worktreeFetchFirst: false,
                                              initialImages: [image], serviceTier: .fast)
        #expect(id == minted)
        let request = try #require(seen.current)
        #expect(request.spaceID == space.id && request.cwd == "/tmp/checkout" && request.model == "some/model")
        #expect(request.thinking == .high && request.initialPrompt == "hello" && request.initialImages == [image])
        #expect(request.serviceTier == .fast)
        #expect(request.worktreeBranch == "worktree/x" && request.worktreeBase == "origin/main" && request.worktreeFetchFirst == false)
    }

    @Test func createAgentIsRejectedWithoutAHandlerOrForAnUnknownSpace() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        try await r.host.seed(ShepherdState(spaces: [space]))
        let client = try await r.raw()
        let create = { (id: Int, spaceID: SpaceID) in RemoteRequest.createAgent(id: id, spaceID: spaceID, cwd: nil, model: nil, thinking: nil, initialPrompt: nil,
                                                                                  worktreeBranch: nil, worktreeBase: nil, worktreeFetchFirst: nil) }
        try client.send(create(1, space.id))
        guard case .error(1, "unsupported", _) = try await client.next() else { Issue.record("expected unsupported"); return }

        let reached = Locked(false)
        r.server.onRemoteCreateAgent = { _, done in reached.withValue { $0 = true }; done(.success(AgentID())) }
        try client.send(create(2, SpaceID()))
        guard case .error(2, "no_such_space", _) = try await client.next() else { Issue.record("expected no_such_space"); return }
        #expect(!reached.current)

        r.server.onRemoteCreateAgent = { _, done in done(.failure(RemoteCreateAgentError("pi is not installed"))) }
        try client.send(create(3, space.id))
        #expect(try await client.next() == .error(id: 3, code: "create_failed", message: "pi is not installed"))

        // Images pi would refuse once the agent exists are refused before anything is made.
        r.server.onRemoteCreateAgent = { _, done in reached.withValue { $0 = true }; done(.success(AgentID())) }
        let image = NativeImage(mimeType: "image/png", data: Data([1]))
        let invalid: [(prompt: String?, images: [NativeImage])] = [
            ("look", Array(repeating: image, count: NativeImage.maxPerSend + 1)),
            ("look", [NativeImage(mimeType: "text/plain", data: Data([1]))]),
            (nil, [image]),
        ]
        for (offset, request) in invalid.enumerated() {
            let id = 10 + offset
            try client.send(.createAgent(id: id, spaceID: space.id, cwd: nil, model: nil, thinking: nil, initialPrompt: request.prompt,
                                         initialImages: request.images))
            guard case .error(id, "invalid", _) = try await client.next() else { Issue.record("expected invalid for \(offset)"); return }
        }
        #expect(!reached.current)
    }

    @Test func creationOptionsComeFromTheHost() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        try await r.host.seed(ShepherdState(spaces: [space]))
        let options = RemoteCreationOptions(base: "origin/release", note: "cached", fetchFirst: false, model: "host/model", thinking: .high, serviceTier: .fast)
        let seen = Locked<[String]>([])
        r.server.onRemoteCreationOptions = { spaceID, cwd, fetch, done in
            seen.withValue { $0.append("\(spaceID == space.id) \(cwd ?? "-") \(String(describing: fetch))") }
            done(.success(options))
        }
        let client = try await r.typed()
        defer { client.disconnect() }

        #expect(try await client.creationOptions(spaceID: space.id, cwd: "/host/checkout", fetchFirst: false) == options)
        #expect(seen.current == ["true /host/checkout Optional(false)"])
        await #expect(throws: RemoteHostClientError.self) { _ = try await client.creationOptions(spaceID: SpaceID(), cwd: nil, fetchFirst: nil) }
    }

    /// A client from before minimal, xhigh and max reads the host's default level as the nearest
    /// one it knows; a current client reads it as it is.
    @Test(arguments: [(ThinkingLevel.xhigh, false, ThinkingLevel.high), (.minimal, false, .low), (.xhigh, true, .xhigh), (.medium, false, .medium)])
    func creationOptionsCarryALevelTheClientDecodes(level: ThinkingLevel, current: Bool, expected: ThinkingLevel) async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        try await r.host.seed(ShepherdState(spaces: [space]))
        r.server.onRemoteCreationOptions = { _, _, _, done in
            done(.success(RemoteCreationOptions(base: "origin/main", note: "", fetchFirst: false, model: nil, thinking: level)))
        }
        let client = try RawRemote(port: r.port)
        try await client.hello(token: r.token, capabilities: current ? RemoteProtocol.clientCapabilities : nil)
        try client.send(.creationOptions(id: 2, spaceID: space.id, cwd: nil, fetchFirst: false))
        guard case .creationOptions(2, let options) = try await client.next() else { Issue.record("expected options"); return }
        #expect(options.thinking == expected)
    }

    @Test func agentActionsRouteToTheHostAndNeedAKnownAgent() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await r.host.seed(Fixture.workspace([worker], space: space))
        let client = try await r.raw()

        try client.send(.agentAction(id: 1, agentID: worker.agent.id, action: .rename(name: "x")))
        guard case .error(1, "unsupported", _) = try await client.next() else { Issue.record("expected unsupported"); return }

        let seen = Locked<[RemoteAgentAction]>([])
        r.server.onRemoteAgentAction = { _, action, done in
            seen.withValue { $0.append(action) }
            if case .rename = action { done(.success(())) } else { done(.failure(RemoteCreateAgentError("nope"))) }
        }
        try client.send(.agentAction(id: 2, agentID: worker.agent.id, action: .rename(name: "Renamed")))
        #expect(try await client.next() == .ok(id: 2))
        try client.send(.agentAction(id: 3, agentID: worker.agent.id, action: .deleteKeepingWorktree))
        #expect(try await client.next() == .error(id: 3, code: "action_failed", message: "nope"))
        try client.send(.agentAction(id: 4, agentID: AgentID(), action: .deleteKeepingWorktree))
        guard case .error(4, "no_such_agent", _) = try await client.next() else { Issue.record("expected no_such_agent"); return }
        #expect(seen.current == [.rename(name: "Renamed"), .deleteKeepingWorktree])
    }

    /// Space actions are this Mac's own app's (the local socket): a paired client is refused and
    /// nothing changes.
    @Test func aPairedClientCannotChangeSpaces() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Space(name: "acme-web", path: r.host.dir.path)
        try await r.server.addSpace(space)
        let client = try await r.raw()
        try client.send(.spaceAction(id: 1, spaceID: space.id, action: .rename(name: "renamed")))
        guard case .error(1, "unsupported", _) = try await client.next() else { Issue.record("expected unsupported"); return }
        #expect(r.server.state.spaces.first?.name == "acme-web")
        try client.send(.startThread(id: 2, thread: RemoteThreadStart(spaceID: space.id)))
        guard case .error(2, "unsupported", _) = try await client.next() else { Issue.record("expected unsupported"); return }
        #expect(r.server.state.agents.isEmpty)
    }

    @Test func agentQueriesRouteToTheHost() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let agentID = AgentID()
        let client = try await r.raw()
        try client.send(.agentQuery(id: 1, agentID: agentID, query: .children))
        guard case .error(1, "unavailable", _) = try await client.next() else { Issue.record("expected unavailable"); return }

        let rows = [ChildRun(runID: "native-1", label: "w", state: "running")]
        r.server.onRemoteAgentQuery = { id, query, _, done in
            done(id == agentID && query == .children ? .success(.children(rows)) : .failure(RemoteCreateAgentError("wrong")))
        }
        try client.send(.agentQuery(id: 2, agentID: agentID, query: .children))
        #expect(try await client.next() == .agentResult(id: 2, result: .children(rows)))
    }

    /// A GUI answer that arrives after its connection closed must not reach whoever reuses the fd.
    @Test func aLateAnswerNeverReachesAReplacementConnection() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await r.host.seed(Fixture.workspace([worker], space: space))
        let parked = Locked<[(Result<Void, RemoteCreateAgentError>) -> Void]>([])
        r.server.onRemoteAgentAction = { _, _, done in parked.withValue { $0.append(done) } }
        let first = try await r.raw()
        try first.send(.agentAction(id: 77, agentID: worker.agent.id, action: .rename(name: "private")))
        try await eventually("the action to reach the host") { !parked.current.isEmpty }
        first.closeConnection()
        let second = try await r.raw()

        parked.current[0](.failure(RemoteCreateAgentError("first client's result")))
        try second.send(.stateFetch(id: 2))
        guard case .state(2, _) = try await second.next() else { Issue.record("the replacement received another client's reply"); return }
    }

    // MARK: - Uploads

    @Test func anUploadLandsAsAPrivateFileForTheSession() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("cat")
        let source = r.host.dir.appendingPathComponent("source.bin")
        let bytes = Data((0..<(RemoteProtocol.uploadChunkBytes + 31)).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let client = try await r.typed()
        defer { client.disconnect() }

        let path = try await client.upload(file: source, sessionID: info.id)
        #expect(path.hasPrefix(r.host.dir.appendingPathComponent("remote-drops").path + "/"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    /// One upload per connection, owned by it: another connection cannot write into it, and a
    /// dropped connection takes its partial file with it.
    @Test func uploadsBelongToTheirConnection() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("cat")
        let owner = try await r.raw()
        try owner.send(.upload(id: 1, action: .begin(sessionID: info.id, name: "partial", size: 3)))
        guard case .uploadResult(1, .ready(let uploadID)) = try await owner.next() else { Issue.record("expected ready"); return }
        try owner.send(.upload(id: 2, action: .begin(sessionID: info.id, name: "second", size: 1)))
        guard case .error(2, "upload_failed", _) = try await owner.next() else { Issue.record("a second upload was accepted"); return }

        let intruder = try await r.raw()
        try intruder.send(.upload(id: 1, action: .chunk(uploadID: uploadID, data: Data([1]))))
        guard case .error(1, "upload_failed", _) = try await intruder.next() else { Issue.record("a foreign chunk was accepted"); return }

        try owner.send(.upload(id: 3, action: .chunk(uploadID: uploadID, data: Data([1]))))
        #expect(try await owner.next() == .ok(id: 3))
        owner.closeConnection()
        let partial = r.host.dir.appendingPathComponent("remote-drops/\(uploadID.uuidString)-partial")
        try await eventually("the partial file to be removed") { !FileManager.default.fileExists(atPath: partial.path) }
    }

    @Test func uploadsNeedALiveSessionAndACompleteFile() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("cat")
        let client = try await r.raw()
        try client.send(.upload(id: 1, action: .begin(sessionID: SessionID(), name: "f", size: 1)))
        guard case .error(1, "upload_failed", _) = try await client.next() else { Issue.record("an upload for no session was accepted"); return }

        try client.send(.upload(id: 2, action: .begin(sessionID: info.id, name: "f", size: 2)))
        guard case .uploadResult(2, .ready(let uploadID)) = try await client.next() else { Issue.record("expected ready"); return }
        try client.send(.upload(id: 3, action: .finish(uploadID: uploadID)))
        guard case .error(3, "upload_failed", _) = try await client.next() else { Issue.record("an incomplete upload finished"); return }
        // A failed finish ends the upload; a new one may begin.
        try client.send(.upload(id: 4, action: .begin(sessionID: info.id, name: "g", size: 1)))
        guard case .uploadResult(4, .ready) = try await client.next() else { Issue.record("expected ready"); return }
        try client.send(.upload(id: 5, action: .cancel(uploadID: UUID())))
        #expect(try await client.next() == .ok(id: 5))
    }

    // MARK: - Native thread over TCP

    @Test func theNativeThreadIsServedOverTCP() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let pi = try await PiAgent.launch(on: r.host)
        let local = try await pi.ready()
        let client = try await r.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.nativeThreadCapability))

        guard case .snapshot(let remote) = try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()) else {
            Issue.record("expected a snapshot"); return
        }
        #expect(remote.piSessionID == local.piSessionID && remote.generation == local.generation)
        #expect(remote.messages == local.messages)
    }

    @Test func tcpNativeTextUsesTransportBoundsAndUnknownAgentsAreRefused() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let pi = try await PiAgent.launch(on: r.host)
        let s = try await pi.ready()
        let client = try await r.raw()
        // State pushes may precede a request's reply. Queue one deterministically.
        try await r.server.renameAgent(pi.agent.id, to: "Limit fixture")
        func nextReply() async throws -> RemoteReply {
            try await client.next(timeout: .seconds(10), where: {
                if case .stateChanged = $0 { return false }
                return true
            })
        }
        // Complete text within the transport frame is valid; there is no separate 64 KiB cap.
        let operation = UUID()
        let text = String(repeating: "x", count: 64 * 1024)
        try client.send(.nativeThread(id: 1, agentID: pi.agent.id, request: .send(
            expectedSessionID: s.piSessionID, generation: s.generation, operationID: operation,
            text: text, delivery: .followUp)))
        guard case .nativeThread(1, .accepted(let accepted)) = try await nextReply() else {
            Issue.record("valid text was not accepted"); return
        }
        #expect(accepted == operation)
        #expect(try await pi.waitForStdin("prompt")["message"] as? String == text)

        try client.send(.nativeThread(id: 2, agentID: AgentID(), request: .snapshot()))
        guard case .error(2, "native_unavailable", _) = try await nextReply() else { Issue.record("an unknown agent was served"); return }

        // A raw peer bypasses the typed client's preflight: the host must enforce its frame cap.
        // It may close while the last bytes are still being written.
        try? client.send(.nativeThread(id: 3, agentID: pi.agent.id, request: .send(
            expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
            text: String(repeating: "x", count: NDJSON.maxPayloadBytes + 1), delivery: .followUp)))
        #expect(try await client.disconnected())
        #expect(pi.stdin("prompt").count == 1, "an oversized frame must never reach pi")
    }
}
