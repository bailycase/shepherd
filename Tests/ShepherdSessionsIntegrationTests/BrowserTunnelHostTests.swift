import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// What a host does and refuses with Browser tunnels (docs/browser.md › Remote): only loopback
/// ports, only for an agent the client sees, capped, closed when idle, gone with the connection,
/// and offered only to a client that reads them and while it can serve them.
@Suite("Browser tunnel host", .integrationTimeLimit)
struct BrowserTunnelHostTests {
    // MARK: Refusals

    @Test func aPortNothingListensOnIsRefused() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }
        #expect(try await client.open(1, agent: host.agent, port: try unusedLoopbackPort()) == .close(tunnel: 1, code: BrowserTunnelCode.refused))
        #expect(host.server.browserTunnelCount == 0)
    }

    /// The host connects to `127.0.0.1` and `::1` and nothing else, so a port that only another of
    /// its addresses listens on is not reachable through it: a tunnel is not a general proxy.
    @Test func aServerOnAnotherOfTheHostsAddressesIsNotReachable() async throws {
        guard let address = LoopbackServer.nonLoopbackIPv4() else { return }
        let host = try await TunnelHost()
        defer { host.stop() }
        let open = Locked(0)
        let lan = try LoopbackServer.deaf(open: open, address: address)
        defer { lan.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }

        #expect(try await client.open(1, agent: host.agent, port: lan.port) == .close(tunnel: 1, code: BrowserTunnelCode.refused))
        #expect(lan.connections.current == 0, "the server on the LAN address saw no connection")
    }

    @Test(arguments: [0, -5, 65_536, 1_000_000])
    func aPortOutsideTheRangeIsRefused(_ port: Int) async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }
        try client.sendTunnel(.open(tunnel: 1, agentID: host.agent, port: port))
        #expect(try await client.nextTunnel() == .close(tunnel: 1, code: BrowserTunnelCode.invalidPort))
    }

    @Test func anAgentTheHostDoesNotHaveIsRefused() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }
        #expect(try await client.open(1, agent: AgentID(), port: dev.port) == .close(tunnel: 1, code: BrowserTunnelCode.noSuchAgent))
        #expect(dev.server.connections.current == 0)
    }

    /// A design's agent is not shown to a client that does not see designs (the host's Design tool
    /// is off, or the client is older), so no tunnel is opened for it either.
    @Test func aDesignsAgentIsRefusedToAClientThatDoesNotSeeDesigns() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        var state = host.server.state
        let space = state.spaces[0]
        let seeded = Fixture.agent(in: space, name: "design agent")
        var designAgent = seeded.agent
        designAgent.designID = DesignID()
        state.tabs.append(seeded.tab)
        state.agents.append(designAgent)
        try await host.remote.host.seed(state)
        let client = try await host.raw()
        defer { client.closeConnection() }
        #expect(try await client.open(1, agent: designAgent.id, port: dev.port) == .close(tunnel: 1, code: BrowserTunnelCode.noSuchAgent))
        // A thread is served.
        #expect(try await client.open(2, agent: host.agent, port: dev.port) == .opened(tunnel: 2))
    }

    @Test func anIdInUseBreaksTheProtocolAndEndsThatTunnel() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let deaf = try LoopbackServer.deaf()
        defer { deaf.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }
        #expect(try await client.open(1, agent: host.agent, port: deaf.port) == .opened(tunnel: 1))
        #expect(try await client.open(1, agent: host.agent, port: deaf.port) == .close(tunnel: 1, code: BrowserTunnelCode.violation))
        try await eventually("the host to drop the tunnel") { host.server.browserTunnelCount == 0 }
    }

    @Test func aFrameOverTheChunkSizeBreaksTheProtocol() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let deaf = try LoopbackServer.deaf()
        defer { deaf.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }
        #expect(try await client.open(1, agent: host.agent, port: deaf.port) == .opened(tunnel: 1))
        try client.sendTunnel(.data(tunnel: 1, bytes: Data(count: BrowserTunnelLimits.chunkBytes + 1)))
        #expect(try await client.nextTunnel() == .close(tunnel: 1, code: BrowserTunnelCode.violation))
        try await eventually("the host to drop the tunnel") { host.server.browserTunnelCount == 0 }
    }

    /// A deaf server takes bytes into its socket buffers until they are full, and the host then
    /// holds what it is sent: a sender that goes on past the credit it was given is cut off.
    @Test func moreBytesThanTheCreditBreakTheProtocol() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let deaf = try LoopbackServer.deaf()
        defer { deaf.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }
        #expect(try await client.open(1, agent: host.agent, port: deaf.port) == .opened(tunnel: 1))
        let chunk = Data(count: BrowserTunnelLimits.chunkBytes)
        for _ in 0..<400 { try client.sendTunnel(.data(tunnel: 1, bytes: chunk)) }
        var code: String?
        while code == nil {
            if case .close(1, let reason) = try await client.nextTunnel() { code = reason ?? "" }
        }
        #expect(code == BrowserTunnelCode.violation)
    }

    // MARK: Caps

    @Test func aClientIsHeldToItsTunnelCapAndTheHostToItsOwn() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        var limits = host.server.browserTunnelLimits
        limits.perClient = 3
        limits.perHost = 4
        host.server.browserTunnelLimits = limits
        let deaf = try LoopbackServer.deaf()
        defer { deaf.stop() }
        let a = try await host.raw()
        defer { a.closeConnection() }
        let b = try await host.raw()
        defer { b.closeConnection() }

        for tunnel in 1...3 { #expect(try await a.open(tunnel, agent: host.agent, port: deaf.port) == .opened(tunnel: tunnel)) }
        #expect(try await a.open(4, agent: host.agent, port: deaf.port) == .close(tunnel: 4, code: BrowserTunnelCode.tooMany))
        // The host's cap is across its clients: b has one, and the host is then at four.
        #expect(try await b.open(1, agent: host.agent, port: deaf.port) == .opened(tunnel: 1))
        #expect(try await b.open(2, agent: host.agent, port: deaf.port) == .close(tunnel: 2, code: BrowserTunnelCode.tooMany))
        #expect(host.server.browserTunnelCount == 4)
        // A tunnel that ends gives its place back.
        try a.sendTunnel(.close(tunnel: 1, code: nil))
        try await eventually("a place to free") { host.server.browserTunnelCount == 3 }
        #expect(try await b.open(3, agent: host.agent, port: deaf.port) == .opened(tunnel: 3))
    }

    @Test func theDefaultCapsAre64PerClientAnd256PerHost() {
        #expect(BrowserTunnelHost.Limits().perClient == 64 && BrowserTunnelHost.Limits().perHost == 256)
    }

    // MARK: Idle

    @Test func aTunnelWithNoBytesAndNoKeepaliveIsClosedWhenIdle() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        var limits = host.server.browserTunnelLimits
        limits.idle = 0.4
        host.server.browserTunnelLimits = limits
        let open = Locked(0)
        let deaf = try LoopbackServer.deaf(open: open)
        defer { deaf.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }

        #expect(try await client.open(1, agent: host.agent, port: deaf.port) == .opened(tunnel: 1))
        #expect(try await client.nextTunnel() == .close(tunnel: 1, code: BrowserTunnelCode.idle))
        try await eventually("the host's socket to close") { open.current == 0 && host.server.browserTunnelCount == 0 }
    }

    /// A page's idle WebSocket stays open because its viewer says it is wanted.
    @Test func aKeepaliveKeepsATunnelOpen() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        var limits = host.server.browserTunnelLimits
        limits.idle = 0.5
        host.server.browserTunnelLimits = limits
        let deaf = try LoopbackServer.deaf()
        defer { deaf.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }

        #expect(try await client.open(1, agent: host.agent, port: deaf.port) == .opened(tunnel: 1))
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(150))
            try client.sendTunnel(.keepalive(tunnel: 1))
        }
        #expect(host.server.browserTunnelCount == 1, "1.8 s on, well past the idle time")
    }

    // MARK: Cleanup

    @Test func aRawConnectionThatDropsTakesItsTunnelsWithIt() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let open = Locked(0)
        let deaf = try LoopbackServer.deaf(open: open)
        defer { deaf.stop() }
        let client = try await host.raw()
        for tunnel in 1...6 { #expect(try await client.open(tunnel, agent: host.agent, port: deaf.port) == .opened(tunnel: tunnel)) }
        #expect(open.current == 6 && host.server.browserTunnelCount == 6)
        client.closeConnection()
        try await eventually("the host to close every socket") { open.current == 0 && host.server.browserTunnelCount == 0 }
    }

    @Test func stoppingTheListenerClosesEveryTunnel() async throws {
        let host = try await TunnelHost()
        let open = Locked(0)
        let deaf = try LoopbackServer.deaf(open: open)
        defer { deaf.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }
        #expect(try await client.open(1, agent: host.agent, port: deaf.port) == .opened(tunnel: 1))
        host.stop()
        try await eventually("the socket to close") { open.current == 0 }
    }

    // MARK: Capability

    @Test func theHostOffersTheCapabilityAndAClientThatListsItIsServed() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let client = try await host.client()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.browserTunnelCapability))
    }

    @Test func aHostWithoutTheCapabilityCarriesNoTunnelAndSaysSo() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        remote.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.browserTunnelCapability }
        let space = Fixture.space()
        let seeded = Fixture.agent(in: space)
        try await remote.host.seed(Fixture.workspace([seeded], space: space))
        let dev = try DevServerFixture()
        defer { dev.stop() }

        let typed = try await remote.typed()
        defer { typed.disconnect() }
        #expect(!typed.capabilities.contains(RemoteProtocol.browserTunnelCapability))
        #expect(await typed.tunnels.probe(agentID: seeded.agent.id, port: Int(dev.port)) == .unavailable)
        await #expect(throws: RemoteHostClientError.self) { _ = try await typed.devServers(agentID: seeded.agent.id) }
        await #expect(throws: RemoteHostClientError.self) { try await typed.openTerminal(agentID: seeded.agent.id, cwd: "/tmp", command: "x") }

        // A client that asks anyway is refused, and nothing connects.
        let raw = try await remote.raw(authenticated: false)
        defer { raw.closeConnection() }
        try await raw.hello(token: remote.token, capabilities: RemoteProtocol.clientCapabilities)
        #expect(try await raw.open(1, agent: seeded.agent.id, port: dev.port) == .close(tunnel: 1, code: BrowserTunnelCode.unsupported))
        try raw.send(.agentQuery(id: 9, agentID: seeded.agent.id, query: .devServers))
        var answer = try await raw.next()
        while case .stateChanged = answer { answer = try await raw.next() }
        guard case .error(9, "unsupported", _) = answer else { Issue.record("expected unsupported, got \(answer)"); return }
        #expect(dev.server.connections.current == 0)
    }

    @Test func aClientThatDoesNotListTheCapabilityIsNotServed() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let older = try await host.raw(tunnels: false)
        defer { older.closeConnection() }

        #expect(try await older.open(1, agent: host.agent, port: dev.port) == .close(tunnel: 1, code: BrowserTunnelCode.unsupported))
        #expect(dev.server.connections.current == 0)
        // Everything else works as it always did for it.
        try older.send(.stateFetch(id: 5))
        var reply = try await older.next()
        while case .stateChanged = reply { reply = try await older.next() }
        guard case .state(5, let state) = reply else { Issue.record("expected the state, got \(reply)"); return }
        #expect(state.agents.count == 1)
    }

    /// The host can switch tunnels off while clients are connected: they are told what it offers
    /// now, and the open tunnels end.
    @Test func switchingTunnelsOffTellsClientsAndEndsTheOpenOnes() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let open = Locked(0)
        let deaf = try LoopbackServer.deaf(open: open)
        defer { deaf.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }
        #expect(try await client.open(1, agent: host.agent, port: deaf.port) == .opened(tunnel: 1))

        host.server.setBrowserTunnelsServed(false)
        var sawClose = false
        var sawCapabilities: [String]?
        while !(sawClose && sawCapabilities != nil) {
            switch try await client.next() {
            case .tunnel(.close(1, let code)): sawClose = code == BrowserTunnelCode.unsupported
            case .capabilitiesChanged(let list): sawCapabilities = list
            default: break
            }
        }
        #expect(sawCapabilities?.contains(RemoteProtocol.browserTunnelCapability) == false)
        try await eventually("the socket to close") { open.current == 0 }
        #expect(try await client.open(2, agent: host.agent, port: deaf.port) == .close(tunnel: 2, code: BrowserTunnelCode.unsupported))
        // And back on: offered again.
        host.server.setBrowserTunnelsServed(true)
        var offered = false
        while !offered { if case .capabilitiesChanged(let list) = try await client.next() { offered = list.contains(RemoteProtocol.browserTunnelCapability) } }
        #expect(try await client.open(3, agent: host.agent, port: deaf.port) == .opened(tunnel: 3))
    }

    // MARK: Dev servers and the terminal

    @Test func theHostReadsItsThreadsFolderForDevServers() async throws {
        let folder = try makeScratchDirectory("thread-folder")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"name":"acme-web","scripts":{"dev":"vite","preview":"vite preview","test":"vitest"}}"#.utf8)
            .write(to: folder.appendingPathComponent("package.json"))
        try Data().write(to: folder.appendingPathComponent("pnpm-lock.yaml"))
        let host = try await TunnelHost(folder: folder.path)
        defer { host.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        let servers = try await client.devServers(agentID: host.agent)
        #expect(servers.map(\.command) == ["pnpm dev", "pnpm preview"])
        #expect(servers.map(\.port) == [5173, 4173])
        #expect(servers.first?.detail == "from package.json · acme-web")
        #expect(URL(fileURLWithPath: servers[0].directory).standardizedFileURL.path == folder.standardizedFileURL.path)
        await #expect(throws: RemoteHostClientError.self) { _ = try await client.devServers(agentID: AgentID()) }
    }

    @Test func aFolderWithNoPackageOffersNoDevServers() async throws {
        let folder = try makeScratchDirectory("empty-folder")
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await TunnelHost(folder: folder.path)
        defer { host.stop() }
        let client = try await host.client()
        defer { client.disconnect() }
        #expect(try await client.devServers(agentID: host.agent).isEmpty)
    }

    @Test func startRunsTheCommandInANewTerminalPaneThroughTheHostsHandler() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let seen = Locked<[PaneRequest]>([])
        host.server.onRemoteAgentAction = { agent, action, done in
            if case .openTerminal(let cwd, let command) = action {
                seen.withValue { $0.append(.open(agentID: agent, axis: .vertical, cwd: cwd, relativeTo: nil, command: command)) }
            }
            done(.success(()))
        }
        let client = try await host.client()
        defer { client.disconnect() }
        try await client.openTerminal(agentID: host.agent, cwd: "/host/repo/apps/web", command: "pnpm dev")
        #expect(seen.current == [.open(agentID: host.agent, axis: .vertical, cwd: "/host/repo/apps/web", relativeTo: nil, command: "pnpm dev")])
    }
}
