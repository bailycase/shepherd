import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The optional TCP listener: token handshake, version check, state fetch, pushed state, and
/// its lifecycle alongside the extension socket.
@Suite("Remote listener", .integrationTimeLimit)
struct RemoteListenerTests {
    @Test func aValidHelloIsAnsweredWithTheProtocolAndCapabilities() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.raw(authenticated: false)
        try client.send(.hello(id: 7, token: r.token, clientName: "test", protocolVersion: RemoteProtocol.version))
        #expect(try await client.next() == .helloOk(id: 7, protocolVersion: RemoteProtocol.version, capabilities: RemoteProtocol.capabilities))
    }

    @Test func stateFetchReturnsTheHostsWorkspace() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        try await r.host.seed(ShepherdState(spaces: [space]))
        let client = try await r.raw()
        try client.send(.stateFetch(id: 2))
        #expect(try await client.next() == .state(id: 2, state: ShepherdState(spaces: [space])))
    }

    /// Each failure is a final reply, then the host closes the connection.
    @Test(arguments: [
        ("wrong token", "unauthorized"),
        ("wrong version", "protocol_version"),
        ("no hello", "unauthenticated"),
    ])
    func unauthenticatedClientsAreRejectedAndDisconnected(scenario: String, code: String) async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.raw(authenticated: false)
        switch scenario {
        case "wrong token": try client.send(.hello(id: 1, token: "wrong", clientName: "t", protocolVersion: RemoteProtocol.version))
        case "wrong version": try client.send(.hello(id: 1, token: r.token, clientName: "t", protocolVersion: RemoteProtocol.version + 98))
        default: try client.send(.stateFetch(id: 1))
        }
        let reply = try await client.next()
        guard case .error(_, let got, _) = reply else { Issue.record("expected an error, got \(reply)"); return }
        #expect(got == code)
        #expect(try await client.disconnected())
    }

    /// The host replies `unauthorized` and then closes. The client reports the refusal through
    /// `connect` alone: the close must not reach `onDisconnected`, where an owner would read it
    /// as a dropped connection and retry it forever.
    @Test func aRefusedTokenIsThrownByConnectAndNeverReportedAsADisconnect() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = RemoteHostClient()
        let drops = Locked<[String]>([])
        client.onDisconnected = { reason in drops.withValue { $0.append(reason) } }
        var thrown: (any Error)?
        do {
            _ = try await client.connect(host: "127.0.0.1", port: r.port, token: "wrong", clientName: "t")
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(RemoteHostFailure(error).kind == .tokenRefused)
        // Whatever the client's queue did with the host's close has been handed to main by the
        // time disconnect returns; draining main runs any callback it scheduled.
        client.disconnect()
        await drainMainQueue()
        #expect(drops.current.isEmpty)
    }

    @Test func anEstablishedConnectionReportsItsDropOnce() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.typed()
        let drops = Locked<[String]>([])
        client.onDisconnected = { reason in drops.withValue { $0.append(reason) } }
        r.server.stopRemoteListener()
        try await eventually("the dropped connection to be reported") { !drops.current.isEmpty }
        client.disconnect()
        await drainMainQueue()
        #expect(drops.current.count == 1)
    }

    @Test func anUndecodableFrameDisconnects() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.raw()
        try client.sendRaw(Data("{\"not\":\"a request\"}\n".utf8))
        #expect(try await client.disconnected())
    }

    @Test func aSecondHelloIsAnErrorButKeepsTheConnection() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.raw()
        try client.send(.hello(id: 5, token: r.token, clientName: "again", protocolVersion: RemoteProtocol.version))
        #expect(try await client.next() == .error(id: 5, code: "protocol", message: "already authenticated"))
        try client.send(.stateFetch(id: 6))
        guard case .state(6, _) = try await client.next() else { Issue.record("expected state"); return }
    }

    @Test func hostMutationsArePushedToAuthenticatedClients() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.raw()
        let space = Fixture.space()
        try await r.server.addSpace(space)
        #expect(try await client.next() == .stateChanged(state: ShepherdState(spaces: [space])))
    }

    /// A connection that never authenticated gets no broadcasts: its first frame after a late
    /// hello is the hello reply, not a push it was never entitled to.
    @Test func unauthenticatedClientsReceiveNoPushes() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let lurker = try await r.raw(authenticated: false)
        let witness = try await r.raw()
        try await r.server.addSpace(Fixture.space())
        guard case .stateChanged = try await witness.next() else { Issue.record("expected the witness's push"); return }

        try lurker.send(.hello(id: 1, token: r.token, clientName: "late", protocolVersion: RemoteProtocol.version))
        guard case .helloOk = try await lurker.next() else { Issue.record("the lurker received a push before authenticating"); return }
    }

    @Test func extensionReportsArePushedToRemoteClientsToo() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await r.host.seed(Fixture.workspace([worker], space: space))
        let client = try await r.raw()
        let ext = try ExtensionClient(path: r.host.socketPath)
        try ext.send(.setAgentStatus(agentID: worker.agent.id, status: .working))
        guard case .stateChanged(let state) = try await client.next() else { Issue.record("expected a push"); return }
        #expect(state.agents.first?.status == .working)
    }

    @Test func stoppingTheListenerDropsRemoteClientsButNotExtensions() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await r.host.seed(Fixture.workspace([worker], space: space))
        let client = try await r.raw()

        r.server.stopRemoteListener()
        #expect(try await client.disconnected())
        try await eventually("the port to close") { (try? RawRemote(port: r.port)) == nil }
        let ext = try ExtensionClient(path: r.host.socketPath)
        try ext.send(.setAgentStatus(agentID: worker.agent.id, status: .working))
        try await eventually("the extension report") { r.server.state.agents.first?.status == .working }
    }

    /// Clients connecting while the queue is busy wait in the backlog: the kernel completes each
    /// handshake there, and the queue accepts them all once it is free. Past a backlog the SYN is
    /// dropped and the connect stays in progress.
    @Test func remoteClientsConnectingWhileTheQueueIsBusyAreAllAccepted() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let connections = 64
        let release = DispatchSemaphore(value: 0)
        await r.server.holdQueue(until: release)
        let sockets = try (0..<connections).map { _ in try Self.connectInBackground(port: r.port) }
        let established = try await blocking { Self.established(sockets, within: .seconds(5)) }
        release.signal()
        #expect(established == connections)

        var authenticated = 0
        for fd in sockets {
            if (try? await RawRemote(connected: fd).hello(token: r.token)) != nil { authenticated += 1 }
        }
        #expect(authenticated == connections)
    }

    /// A non-blocking connect to the listener on the loopback address.
    private static func connectInBackground(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError("socket: errno \(errno)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        // Before connecting: a connection the listener never took is reset, setsockopt then
        // fails, and a write would raise SIGPIPE and end the whole test process.
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 || errno == EINPROGRESS else {
            let err = errno
            close(fd)
            throw WireError("connect: errno \(err)")
        }
        return fd
    }

    /// How many of `sockets` finish connecting before `timeout`.
    private static func established(_ sockets: [Int32], within timeout: Duration) -> Int {
        let deadline = ContinuousClock.now + timeout
        var pending = Set(sockets)
        var done = 0
        while !pending.isEmpty, ContinuousClock.now < deadline {
            var fds = pending.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
            guard poll(&fds, nfds_t(fds.count), 50) > 0 else { continue }
            for entry in fds where entry.revents != 0 {
                pending.remove(entry.fd)
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 { done += 1 }
            }
        }
        return done
    }

    @Test func theListenerCanOnlyStartOnce() throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let error = #expect(throws: SessionServerError.self) {
            _ = try r.server.startRemoteListener(port: 0, tokenURL: r.host.dir.appendingPathComponent("remote-token"))
        }
        #expect(error?.description == "remote listener already running")
    }

    @Test func aBusyPortIsReportedNotSwallowed() throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let other = try ScratchServer.fresh()
        defer { other.stop() }
        let error = #expect(throws: SessionServerError.self) {
            _ = try other.server.startRemoteListener(port: r.port, tokenURL: other.dir.appendingPathComponent("remote-token"))
        }
        guard case .system("bind", _)? = error else { Issue.record("expected a bind failure, got \(String(describing: error))"); return }
    }

    /// Asking pi for its models shells out; it must not hold the server queue meanwhile. The
    /// stand-in catalog cannot return until the state reply has arrived, so a listing that held
    /// the queue would never let that reply through.
    @Test func aModelListingDoesNotBlockOtherRequests() async throws {
        let stateArrived = DispatchSemaphore(value: 0)
        let r = try RemoteHost(modelCatalog: {
            _ = stateArrived.wait(timeout: .now() + 30)
            return (["stand-in/model"], "stand-in/model")
        })
        defer { r.stop() }
        let client = try await r.raw()
        try client.send(.listModels(id: 1))
        try client.send(.stateFetch(id: 2))

        let beforeListing = try await client.frames(until: { if case .state(2, _) = $0 { true } else { false } })
        stateArrived.signal()
        #expect(!beforeListing.contains { if case .models = $0 { true } else { false } })
        let listing = try await client.frames(until: { if case .models = $0 { true } else { false } })
        #expect(listing.last == .models(id: 1, models: ["stand-in/model"], defaultModel: "stand-in/model"))
    }
}
