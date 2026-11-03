import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdRemote

@Suite("Remote Changes cancellation", .mainActorExclusive)
@MainActor
struct RemoteChangesCancellationTests {
    @Test func closingReviewDropsFourHeldReadsWithoutRequestingMoreAndANewReviewWorks() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let peer = try ChangesPeer()
        defer { peer.stop() }
        app.remoteHosts.addHost(name: "fixture", host: "127.0.0.1", port: peer.server.port, token: "fixture")
        let connection = try #require(app.remoteHosts.connections.last)
        try await eventuallyOnMain("remote Changes connected") { connection.phase == .connected }
        let target = RemoteAgentRef(hostID: connection.id, agentID: AgentID())
        func open() -> ReviewSession {
            let session = ReviewSession(agentID: target.agentID, paneID: PaneID(), cwd: "/fixture", reference: nil)
            session.engine = vm.remoteChangesEngine(target)
            vm.remoteReviews[target] = session
            vm.loadChanges(session)
            return session
        }
        let old = open()
        try await eventuallyOnMain("first four remote file replies held") { peer.state.current.fileRequests.count == 4 }
        let task = try #require(old.loadTask)
        vm.cancelReview(old)
        let completed = Locked(false)
        Task { await task.value; completed.withValue { $0 = true } }
        // The transport must release every child's continuation without any host reply.
        try await eventuallyOnMain("cancelled review no longer awaits remote callbacks") { completed.current }
        #expect(peer.state.current.held.count == 4)
        peer.release()
        _ = try await app.remoteHosts.agentQuery(target, query: .changesBranches)
        #expect(peer.state.current.fileRequests.count == 4)
        #expect(old.files.isEmpty)
        let newer = open()
        try await eventuallyOnMain("new review loads on the same connection") { !newer.isLoading }
        #expect(newer.files.count == 9)
        #expect(peer.state.current.fileRequests.count == 13)
        #expect(connection.phase == .connected && peer.server.connections.current == 1)
    }

    @Test(arguments: [RemoteAgentQuery.changesOverview, .changesList(scope: .uncommitted, options: .init()),
        .changesFile(revision: ChangesPeer.revision, path: "file", oldPath: nil, options: .init()),
        .changesBranches, .changesPatch(revision: ChangesPeer.revision, options: .init())])
    func cancellingAChangesReadDropsItsCallbackAndLateReplyKeepsConnectionHealthy(query: RemoteAgentQuery) async throws {
        let peer = try ChangesPeer(holdAll: true)
        defer { peer.stop() }
        let client = RemoteHostClient()
        defer { client.disconnect() }
        _ = try await client.connect(host: "127.0.0.1", port: peer.server.port, token: "fixture", clientName: "fixture")
        let done = Locked(false)
        let request = Task {
            defer { done.withValue { $0 = true } }
            do { _ = try await client.agentQuery(agentID: AgentID(), query: query); return false }
            catch is CancellationError { return true }
            catch { Issue.record(error); return false }
        }
        try await eventuallyOnMain("read reply held") { peer.state.current.held.count == 1 }
        request.cancel()
        try await eventuallyOnMain("read callback dropped before reply") { done.current }
        #expect(await request.value)
        peer.release()
        _ = try await client.request { @Sendable id in .stateFetch(id: id) }
        #expect(peer.server.connections.current == 1)
    }

    @Test(arguments: [RemoteAgentQuery.changesUndoTurn(turnID: UUID()), .changesRedoTurn(turnID: UUID()),
        .changesRevertFile(revision: ChangesPeer.revision, path: "file", oldPath: nil)])
    func cancellingAChangesMutationStillWaitsForItsOutcome(query: RemoteAgentQuery) async throws {
        let peer = try ChangesPeer(holdAll: true)
        defer { peer.stop() }
        let client = RemoteHostClient()
        defer { client.disconnect() }
        _ = try await client.connect(host: "127.0.0.1", port: peer.server.port, token: "fixture", clientName: "fixture")
        let done = Locked(false)
        let request = Task {
            defer { done.withValue { $0 = true } }
            do { _ = try await client.agentQuery(agentID: AgentID(), query: query); return false }
            catch RemoteHostClientError.rejected(let code, _) { return code == "fixture_outcome" }
            catch { Issue.record(error); return false }
        }
        try await eventuallyOnMain("mutation reply held") { peer.state.current.held.count == 1 }
        request.cancel()
        _ = try await client.request { @Sendable id in .stateFetch(id: id) }
        #expect(!done.current, "cancellation cannot abandon a mutation's unknown outcome")
        peer.release()
        #expect(await request.value)
        #expect(peer.server.connections.current == 1)
    }
}

/// Real wire requests with held replies, using the existing isolated loopback server.
private final class ChangesPeer: @unchecked Sendable {
    static let revision = ChangesRevision(old: "aaaa", new: "bbbb")
    struct State {
        var holding = true
        var held: [(Int32, RemoteReply)] = []
        var fileRequests: [String] = []
    }
    let state = Locked(State())
    let server: LoopbackServer

    init(holdAll: Bool = false) throws {
        let state = state
        server = try LoopbackServer { fd in
            while true {
                var line = Data()
                while let byte = LoopbackServer.readExactly(fd, 1), byte != Data([10]), line.count < 64 * 1024 { line.append(byte) }
                guard let request = try? JSONDecoder().decode(RemoteRequest.self, from: line) else { return }
                state.withValue { state in
                    let reply: RemoteReply
                    var hold = false
                    switch request {
                    case .hello(let id, _, _, _, _):
                        reply = .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: [RemoteProtocol.changesCapability, RemoteProtocol.changesRevertCapability])
                    case .stateFetch(let id): reply = .state(id: id, state: ShepherdState())
                    case .agentQuery(let id, _, let query):
                        let result: RemoteAgentResult
                        hold = holdAll
                        switch query {
                        case .changesOverview: result = .changesOverview(ChangesOverview(repository: "/fixture", defaultScope: .uncommitted))
                        case .changesList(let scope, _):
                            result = .changesList(ChangesList(scope: scope, revision: Self.revision,
                                comparison: ChangesComparison(head: "Working tree", base: "HEAD"),
                                files: (0..<9).map { ChangesFile(path: "file\($0)", status: .modified, added: 0, removed: 0) }))
                        case .changesFile(_, let path, _, _):
                            state.fileRequests.append(path)
                            hold = true
                            result = .changesFile(ChangesFileDiff(file: DiffFile(oldPath: path, newPath: path, displayPath: path,
                                isNew: false, isDeleted: false, isRenamed: false, isBinary: false, hunks: [])))
                        case .changesBranches: result = .changesBranches(ChangesBranches(defaultBase: nil, branches: []))
                        case .changesPatch: result = .changesPatch(text: "", truncated: false)
                        default:
                            let reply = RemoteReply.error(id: id, code: "fixture_outcome", message: "Mutation finished.")
                            if state.holding { state.held.append((fd, reply)) }
                            else { Self.send(reply, fd: fd) }
                            return
                        }
                        reply = .agentResult(id: id, result: result)
                    default: return
                    }
                    if state.holding && hold { state.held.append((fd, reply)) }
                    else { Self.send(reply, fd: fd) }
                }
            }
        }
    }

    private static func send(_ reply: RemoteReply, fd: Int32) {
        if let data = try? NDJSON.encode(reply) { LoopbackServer.writeAll(fd, data) }
    }

    func release() {
        state.withValue { state in
            state.holding = false
            for (fd, reply) in state.held { Self.send(reply, fd: fd) }
            state.held.removeAll()
        }
    }
    func stop() { release(); server.stop() }
}
