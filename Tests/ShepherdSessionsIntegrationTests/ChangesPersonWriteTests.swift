import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

/// What this Mac's app writes for the person, told to its host's Changes engine over `host.sock`
/// (`changes.writes.v1`): a Save or a Revert by path, a branch action or a commit by tree. A turn
/// running meanwhile does not take it for the agent's.
@Suite("Changes: what the app writes for the person", .integrationTimeLimit)
struct ChangesPersonWriteTests {
    /// A host on a local socket, an agent in a repository holding a `tools:1` turn, and the app's connection.
    struct Running {
        let local: LocalListenerTests.Local
        let repo: ChangesRepo
        let pi: PiAgent
        let client: RemoteHostClient
        var changes: ChangesService { local.host.server.changes }

        init() async throws {
            repo = try ChangesRepo(files: ["a.txt": "one\n", "notes.txt": "before\n"])
            try "tool-*\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
            local = try LocalListenerTests.Local()
            pi = try await PiAgent.launch(on: local.host, cwd: repo.url)
            client = try await local.client().0
            let idle = try await pi.ready()
            #expect(try await pi.send("tools:1 edit", from: idle).failureCode == nil)
            let changes = local.host.server.changes, agent = pi.agent.id
            try await eventually("the turn's baseline") { changes.turnStore.latest(agent)?.startTree != nil }
        }

        func stop() {
            client.disconnect()
            local.host.stop()
        }

        func began(_ span: UUID, _ paths: [String]?) async throws {
            _ = try await client.agentQuery(agentID: pi.agent.id, query: .changesWriteBegan(span: span, paths: paths))
        }

        func ended(_ span: UUID) async throws {
            _ = try await client.agentQuery(agentID: pi.agent.id, query: .changesWriteEnded(span: span))
        }

        /// Lets the turn finish and returns its record.
        func finish() async throws -> ChangesTurn {
            FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-1").path, contents: nil)
            try await eventually("the turn to end") { changes.turns(agentID: pi.agent.id).last?.state == .ready }
            return try #require(changes.turns(agentID: pi.agent.id).last)
        }
    }

    @Test func aSaveTheAppReportsStaysOutOfARunningTurnAndItsUndo() async throws {
        let t = try await Running()
        defer { t.stop() }
        #expect(t.client.capabilities.contains(RemoteProtocol.changesWritesCapability))
        try t.repo.write("a.txt", "one\ntwo\n")

        let span = UUID()
        try await t.began(span, [t.repo.path + "/notes.txt"])
        try t.repo.write("notes.txt", "saved\n")
        try await t.ended(span)
        let turn = try await t.finish()

        #expect(turn.files.map(\.path) == ["a.txt"])
        _ = try await t.changes.undoTurn(agentID: t.pi.agent.id, turnID: turn.id)
        #expect(t.repo.read("a.txt") == "one\n" && t.repo.read("notes.txt") == "saved\n")
    }

    @Test func aBranchActionTheAppReportsMakesTheTurnSharedUntilItEnds() async throws {
        let t = try await Running()
        defer { t.stop() }
        let span = UUID()
        try await t.began(span, nil)
        try t.repo.write("a.txt", "one\ntwo\n")
        try t.repo.write("notes.txt", "as the other branch has it\n")
        try await t.ended(span)
        let turn = try await t.finish()

        #expect(turn.fileCount == 0 && !turn.canUndo, "bash-made files and the operation's are all left out of a shared turn")
        #expect(t.changes.writers.withValue { $0.spans.map(\.interval.end).allSatisfy { $0 != nil } }, "ended closes it")
    }

    @Test func whatTheAppLeftOpenIsClosedWhenItsConnectionCloses() async throws {
        let t = try await Running()
        defer { t.stop() }
        try await t.began(UUID(), nil)
        try await t.began(UUID(), [t.repo.path + "/notes.txt"])
        #expect(t.changes.writers.withValue { $0.spans.filter { $0.interval.end == nil }.count } == 2)

        t.client.disconnect()
        try await eventually("the app's open notes to be closed") { t.changes.writers.withValue { $0.spans.allSatisfy { $0.interval.end != nil } } }
    }

    /// The app stops waiting for a slow host and ends the note it began a moment before: the host
    /// reads both before it has opened the first.
    @Test func anEndThatOvertakesItsBeginStillClosesIt() async throws {
        let t = try await Running()
        defer { t.stop() }
        let raw = try Self.rawLocal(t.local)
        defer { raw.closeConnection() }
        try await raw.hello(token: t.local.token)

        let tree = UUID(), save = UUID(), agent = t.pi.agent.id
        let release = DispatchSemaphore(value: 0)
        await t.local.host.server.holdQueue(until: release)
        defer { release.signal() }
        var frames = Data()
        for (id, query) in [(21, RemoteAgentQuery.changesWriteBegan(span: tree, paths: nil)), (22, .changesWriteEnded(span: tree)),
                            (23, .changesWriteBegan(span: save, paths: [t.repo.path + "/notes.txt"])), (24, .changesWriteEnded(span: save))] {
            frames.append(try NDJSON.encode(RemoteRequest.agentQuery(id: id, agentID: agent, query: query)))
        }
        try raw.sendRaw(frames)
        release.signal()

        var answered: Set<Int> = []
        while answered.count < 4 {
            if case .agentResult(let id, _) = try await raw.next() { answered.insert(id) }
        }
        try await eventually("both notes to be closed") {
            t.changes.writers.withValue { $0.spans.count == 2 && $0.spans.allSatisfy { $0.interval.end != nil } }
        }
    }

    /// A connection to the host's local socket, authenticated on the first frame like the app's.
    private static func rawLocal(_ local: LocalListenerTests.Local) throws -> RawRemote {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError("socket: errno \(errno)") }
        var address = try SessionServer.socketAddress(for: local.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            throw WireError("connect: errno \(errno)")
        }
        return RawRemote(connected: fd)
    }

    @Test func theHostRefusesWhatItCannotTrust() async throws {
        let t = try await Running()
        defer { t.stop() }
        for paths in [["relative.txt"], ["/ok.txt", "../escape"], [], (0...ChangesService.personWritePaths).map { "/f\($0)" }] {
            await #expect(throws: RemoteHostClientError.self, "\(paths.count) paths") { try await t.began(UUID(), paths) }
        }
        // A note nobody opened closes nothing: the engine's own Undo spans are not the app's to end.
        let own = t.changes.beginTreeEvent(cwd: t.repo.path)
        try await t.ended(own)
        #expect(t.changes.writers.withValue { $0.spans.first { $0.id == own }?.interval.end == nil })
        t.changes.endWrite(own)
    }

    @Test func aPairedDeviceCannotReportWhatItWrites() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host)
        let client = try await remote.typed()
        defer { client.disconnect() }
        #expect(!client.capabilities.contains(RemoteProtocol.changesWritesCapability))

        let raw = try await remote.raw(authenticated: false)
        defer { raw.closeConnection() }
        try await raw.hello(token: remote.token, capabilities: RemoteProtocol.clientCapabilities)
        for (id, query) in [(7, RemoteAgentQuery.changesWriteBegan(span: UUID(), paths: nil)), (8, .changesWriteEnded(span: UUID()))] {
            try raw.send(.agentQuery(id: id, agentID: pi.agent.id, query: query))
            var reply = try await raw.next()
            while case .stateChanged = reply { reply = try await raw.next() }
            guard case .error(id, "unsupported", _) = reply else {
                Issue.record("expected a refusal for \(query), got \(reply)")
                continue
            }
        }
        #expect(remote.server.changes.writers.withValue { $0.spans.isEmpty })
    }
}
