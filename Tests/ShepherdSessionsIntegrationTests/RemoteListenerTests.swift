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

    /// Asking pi for its models shells out; it must not hold the server queue meanwhile.
    @Test func aModelListingDoesNotBlockOtherRequests() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.raw()
        try client.send(.listModels(id: 1))
        try client.send(.stateFetch(id: 2))
        let frames = try await client.frames(until: { if case .models = $0 { true } else { false } }, timeout: .seconds(60))
        let stateIndex = frames.firstIndex { if case .state(2, _) = $0 { true } else { false } }
        #expect(stateIndex != nil && stateIndex! < frames.count - 1, "the state reply overtook the model listing")
    }
}
