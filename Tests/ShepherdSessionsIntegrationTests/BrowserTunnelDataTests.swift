import CryptoKit
import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// What crosses a Browser tunnel (docs/browser.md › Remote): a real host on a real listener, a real
/// `RemoteHostClient` and its hub, and a local server on an ephemeral port standing in for the
/// host's dev server. The far end of each tunnel is a socket pair, as WebKit's connection to a
/// forwarded port is a socket the hub owns.
@Suite("Browser tunnel data", .integrationTimeLimit)
struct BrowserTunnelDataTests {
    @Test func anHTTPGetReachesTheHostsDevServerAndBack() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: dev.port)
        let reply = await peer.http("GET", "/hello")
        #expect(reply.status == "HTTP/1.1 200 OK")
        #expect(String(decoding: reply.body, as: UTF8.self) == "hello from the host")
        #expect(dev.requests.current == ["GET /hello HTTP/1.1"])
        try await eventually("the tunnel to end on both sides") { client.tunnels.openCount == 0 && host.server.browserTunnelCount == 0 }
    }

    @Test func aPostOfSeveralMegabytesArrivesIntact() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        let size = 6 * 1024 * 1024 + 123
        let body = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 % 253) })
        let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: dev.port)
        let reply = await peer.http("POST", "/sum", body: body)
        #expect(reply.status == "HTTP/1.1 200 OK")
        let json = try #require(try JSONSerialization.jsonObject(with: reply.body) as? [String: Any])
        #expect(json["bytes"] as? Int == body.count)
        #expect(json["sha256"] as? String == SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
    }

    @Test func aLargeResponseArrivesIntactAndInOrder() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        let size = 5 * 1024 * 1024 + 7
        let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: dev.port)
        let reply = await peer.http("GET", "/bytes?n=\(size)")
        #expect(reply.body.count == size)
        #expect(reply.body == Data((0..<size).map { UInt8($0 % 251) }))
    }

    @Test func aWebSocketEchoesThroughATunnel() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: dev.port)
        let key = Data((0..<16).map { UInt8($0) }).base64EncodedString()
        await peer.send(Data("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
        let upgrade = await peer.readUntil(Data("\r\n\r\n".utf8))
        #expect(String(decoding: upgrade, as: UTF8.self).hasPrefix("HTTP/1.1 101"))

        // A small text message and a 100 KB binary one (two chunks of the tunnel) come back as sent.
        for payload in [Data("ping".utf8), Data((0..<100_000).map { UInt8($0 % 253) })] {
            let opcode: UInt8 = payload.count == 4 ? 0x1 : 0x2
            await peer.send(Self.maskedFrame(opcode, payload))
            let echoed = try #require(await peer.unmaskedFrame())
            #expect(echoed.opcode == opcode)
            #expect(echoed.payload == payload)
        }
        await peer.send(Self.maskedFrame(0x8, Data()))
        _ = await peer.readToEnd(timeout: 5)
    }

    @Test func manyTunnelsRunAtOnce() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        let count = 40
        let replies = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<count {
                let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: dev.port)
                group.addTask { String(decoding: await peer.http("GET", "/hello").body, as: UTF8.self) }
            }
            var all: [String] = []
            for try await reply in group { all.append(reply) }
            return all
        }
        #expect(replies.count == count && replies.allSatisfy { $0 == "hello from the host" })
        try await eventually("every tunnel to end") { client.tunnels.openCount == 0 && host.server.browserTunnelCount == 0 }
    }

    /// A dev server listening on `::1` only (Vite on `localhost`, often) is reached: the host tries
    /// `127.0.0.1` and then `::1`.
    @Test func aDevServerOnlyOnIPv6IsReached() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture(family: .ipv6)
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: dev.port)
        #expect(String(decoding: await peer.http("GET", "/hello").body, as: UTF8.self) == "hello from the host")
    }

    @Test func aHalfCloseStillLetsTheResponseCome() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let echo = try LoopbackServer.echo()
        defer { echo.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        // Sends, half-closes its write side, and still reads what the echo sends back.
        let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: echo.port)
        await peer.send(Data("half closed".utf8))
        peer.finish()
        #expect(String(decoding: await peer.readToEnd(), as: UTF8.self) == "half closed")
    }

    // MARK: Pace

    /// A page that stops reading holds the dev server's writes back: the host does not read a
    /// target beyond the window the viewer has room for, so what the dev server got to write
    /// stays bounded (the window, and the kernel's socket buffers) instead of growing.
    @Test func aViewerThatStopsReadingHoldsTheSenderBack() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let written = Locked(0)
        let firehose = try LoopbackServer.firehose(written: written)
        defer { firehose.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: firehose.port)
        // It reads a little, then stops.
        let first = await peer.read(10_000)
        #expect(first.count == 10_000)
        var settled = 0
        try await eventually("the sender to stop") {
            let now = written.current
            defer { settled = now }
            return now == settled && now > 0
        }
        try await Task.sleep(for: .milliseconds(500))
        let stalled = written.current
        #expect(stalled == settled, "it does not keep writing")
        // The window (256 KiB), the tunnel's frames in flight and the sockets' buffers: a few
        // megabytes at most, not the gigabytes an unpaced host would have read by now.
        #expect(stalled < 8 * 1024 * 1024, "the sender wrote \(stalled) bytes")
        // And the connection is alive: reading again lets it run on.
        let more = await peer.read(2 * 1024 * 1024)
        #expect(more.count == 2 * 1024 * 1024)
        #expect(written.current > stalled)
    }

    /// The host's connection to a client that reads nothing at all is not dropped for the tunnels'
    /// sake: however many tunnels a firehose fills, what waits in the client's write queue stays
    /// under what the server allows, and every byte arrives once the client reads.
    @Test func aClientThatReadsNothingIsNotDroppedForItsTunnels() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let written = Locked(0)
        let firehose = try LoopbackServer.firehose(written: written)
        defer { firehose.stop() }
        let client = try await host.raw()
        defer { client.closeConnection() }

        // 40 tunnels, each with a full window of credit: 10 MiB against a 2 MiB write queue.
        for tunnel in 1...40 { try client.sendTunnel(.open(tunnel: tunnel, agentID: host.agent, port: Int(firehose.port))) }
        try await Task.sleep(for: .seconds(1))
        let stalled = written.current
        try await Task.sleep(for: .milliseconds(500))
        #expect(written.current == stalled, "the host stopped reading the firehose")
        // Still connected: it reads what was queued, opened and data frames alike, and answers a request.
        try client.send(.stateFetch(id: 77))
        var sawState = false
        var received = 0
        while !sawState {
            switch try await client.next() {
            case .state(let id, _) where id == 77: sawState = true
            case .tunnel(.data(_, let bytes)): received += bytes.count
            default: break
            }
        }
        #expect(sawState)
        #expect(received > 0)
        #expect(received <= 2 * 1024 * 1024, "no more than the write queue's cap waited for a client that read nothing")
    }

    /// The viewer's connection to the host going away resets every page's connection, and closes
    /// every socket the host held for it.
    @Test func aDroppedConnectionEndsItsTunnelsOnBothSides() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let open = Locked(0)
        let deaf = try LoopbackServer.deaf(open: open)
        defer { deaf.stop() }
        let client = try await host.client()

        let peers = try (0..<5).map { _ in try TunnelPeer(hub: client.tunnels, agent: host.agent, port: deaf.port) }
        try await eventually("the host to hold five sockets") { open.current == 5 && host.server.browserTunnelCount == 5 }
        client.disconnect()
        for peer in peers {
            #expect(await peer.readToEnd(timeout: 10).isEmpty, "the page's connection ends")
        }
        try await eventually("the host to close every socket") { open.current == 0 && host.server.browserTunnelCount == 0 }
        #expect(client.tunnels.openCount == 0)
        // A connection made afterwards has nowhere to go: it resets, and the page shows a load error.
        let late = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: deaf.port)
        #expect(await late.readToEnd(timeout: 10).isEmpty)
    }

    /// What keeps a page's idle WebSocket (Vite's hot reload) open: the viewer says the tunnel is still
    /// wanted while its socket is, so the host's idle rule never reaps it, and reaps one the viewer
    /// has finished with when the target never closes.
    @Test func aKeepaliveHoldsAnIdleTunnelOpenUntilItsPageIsDone() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        var limits = host.server.browserTunnelLimits
        limits.idle = 0.5
        host.server.browserTunnelLimits = limits
        let open = Locked(0)
        let deaf = try LoopbackServer.deaf(open: open)
        defer { deaf.stop() }
        let client = try await host.client()
        defer { client.disconnect() }
        client.tunnels.keepaliveSeconds = 0.15

        let peer = try TunnelPeer(hub: client.tunnels, agent: host.agent, port: deaf.port)
        try await eventually("the host's socket") { open.current == 1 }
        // Well past the idle time with nothing said but the keepalives.
        try await Task.sleep(for: .seconds(1.6))
        #expect(host.server.browserTunnelCount == 1 && open.current == 1, "an idle socket the page still holds stays open")
        // The page is done sending, and the deaf target never closes: the keepalives stop and the
        // host's idle rule takes the tunnel.
        peer.finish()
        try await eventually("the host to reap the tunnel", timeout: .seconds(10)) { host.server.browserTunnelCount == 0 && open.current == 0 }
    }

    @Test func aProbeSaysWhetherAPortAnswers() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }

        #expect(await client.tunnels.probe(agentID: host.agent, port: Int(dev.port)) == .reachable)
        #expect(await client.tunnels.probe(agentID: host.agent, port: Int(try unusedLoopbackPort())) == .failed(BrowserTunnelCode.refused))
        #expect(await client.tunnels.probe(agentID: AgentID(), port: Int(dev.port)) == .failed(BrowserTunnelCode.noSuchAgent))
        try await eventually("the probes' tunnels to end") { client.tunnels.openCount == 0 && host.server.browserTunnelCount == 0 }
    }

    // MARK: WebSocket frames

    /// A masked client frame (opcode, payload).
    static func maskedFrame(_ opcode: UInt8, _ payload: Data) -> Data {
        let mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }
}

extension TunnelPeer {
    /// Reads until `marker` has arrived (and returns everything read, the marker included).
    func readUntil(_ marker: Data, timeout: TimeInterval = 30) async -> Data {
        var data = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while data.range(of: marker) == nil, Date() < deadline {
            let chunk = await read(1, timeout: 1)
            if chunk.isEmpty { continue }
            data.append(chunk)
        }
        return data
    }

    /// The next server frame of a WebSocket (never masked).
    func unmaskedFrame() async -> (opcode: UInt8, payload: Data)? {
        let head = await read(2)
        guard head.count == 2 else { return nil }
        var length = Int(head[1] & 0x7F)
        if length == 126 {
            let extended = await read(2)
            guard extended.count == 2 else { return nil }
            length = Int(extended[0]) << 8 | Int(extended[1])
        } else if length == 127 {
            let extended = await read(8)
            guard extended.count == 8 else { return nil }
            length = extended.reduce(0) { $0 << 8 | Int($1) }
        }
        let payload = await read(length)
        guard payload.count == length else { return nil }
        return (head[0] & 0x0F, payload)
    }
}
