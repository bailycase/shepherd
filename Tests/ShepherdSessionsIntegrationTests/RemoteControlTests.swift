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
    // MARK: - Pane control

    @Test func paneRequestsRouteThroughTheHostHandler() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let (agentID, anchor, opened) = (AgentID(), PaneID(), PaneID())
        let split = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(LeafPane(id: anchor, cwd: "/tmp")), second: .leaf(LeafPane(id: opened, cwd: "/tmp")))
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
        try await client.resizePaneSplit(agentID: agentID, split: split, ratio: 0.7)
        try await client.closePane(agentID: agentID, paneID: opened)
        #expect(seen.current == [
            .open(agentID: agentID, axis: .vertical, cwd: nil, relativeTo: anchor, command: nil),
            .resizeSplit(agentID: agentID, split: split, ratio: 0.7),
            .close(agentID: agentID, paneID: opened),
        ])
    }

    @Test func paneRequestsFailCleanlyWithoutAHandlerOrWithAWrongOutcome() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.raw()
        try client.send(.closePane(id: 3, agentID: AgentID(), paneID: PaneID()))
        #expect(try await client.next() == .error(id: 3, code: "unsupported", message: "host cannot mutate panes"))

        r.server.onRemotePaneRequest = { _, respond in respond(.panes([])) }
        try client.send(.closePane(id: 4, agentID: AgentID(), paneID: PaneID()))
        #expect(try await client.next() == .error(id: 4, code: "protocol", message: "unexpected pane reply"))
        r.server.onRemotePaneRequest = { _, respond in respond(.failed(code: "not_closable", message: "last pane")) }
        try client.send(.closePane(id: 5, agentID: AgentID(), paneID: PaneID()))
        #expect(try await client.next() == .error(id: 5, code: "not_closable", message: "last pane"))
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
        for name in ["beta", "Alpha", ".pi"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("file.txt").path, contents: Data())
        let client = try await r.typed()
        defer { client.disconnect() }

        let listing = try await client.listDir(path: folder.path)
        #expect(listing.path == folder.path)
        #expect(listing.dirs == [".pi", "Alpha", "beta"])
        #expect(listing.parent == folder.deletingLastPathComponent().path)
        #expect(try await client.listDir(path: "").path == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(try await client.listDir(path: "/").parent == nil)
        await #expect(throws: RemoteHostClientError.self) { _ = try await client.listDir(path: "/definitely/not/a/dir") }
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

        let id = try await client.createAgent(spaceID: space.id, cwd: "/tmp/checkout", model: "some/model", thinking: .high, initialPrompt: "hello",
                                              worktreeBranch: "worktree/x", worktreeBase: "origin/main", worktreeFetchFirst: false)
        #expect(id == minted)
        let request = try #require(seen.current)
        #expect(request.spaceID == space.id && request.cwd == "/tmp/checkout" && request.model == "some/model")
        #expect(request.thinking == .high && request.initialPrompt == "hello")
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
    }

    @Test func creationOptionsComeFromTheHost() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        try await r.host.seed(ShepherdState(spaces: [space]))
        let options = RemoteCreationOptions(base: "origin/release", note: "cached", fetchFirst: false, model: "host/model", thinking: .high)
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

    @Test func agentQueriesRouteToTheHost() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let agentID = AgentID()
        let client = try await r.raw()
        try client.send(.agentQuery(id: 1, agentID: agentID, query: .children))
        guard case .error(1, "unavailable", _) = try await client.next() else { Issue.record("expected unavailable"); return }

        let rows = [ChildRun(runID: "native-1", label: "w", state: "running")]
        r.server.onRemoteAgentQuery = { id, query, done in
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

    @Test func tcpNativeRequestsAreBoundedAndNeedARunningPi() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let pi = try await PiAgent.launch(on: r.host)
        let s = try await pi.ready()
        let client = try await r.raw()
        try client.send(.nativeThread(id: 1, agentID: pi.agent.id, request: .send(
            expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
            text: String(repeating: "x", count: 64 * 1024), delivery: .followUp)))
        guard case .error(1, "native_limit", _) = try await client.next() else { Issue.record("an oversized request was accepted"); return }

        try client.send(.nativeThread(id: 2, agentID: AgentID(), request: .snapshot()))
        guard case .error(2, "native_unavailable", _) = try await client.next() else { Issue.record("an unknown agent was served"); return }
        #expect(pi.stdin("prompt").isEmpty)
    }
}
