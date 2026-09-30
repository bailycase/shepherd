import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Which ports of a remote thread's host are forwarded on this Mac (docs/browser.md › Remote): a
/// listener on the loopback at the port a page's URL names, bridged to a tunnel, with one owner per
/// port and a refusal that says why. The host here is this very Mac, so a test's forward listens
/// on a free port of its own and reaches the dev server's different one (`hostPort`).
@Suite("Browser port forwarder", .integrationTimeLimit)
struct BrowserPortForwarderTests {
    let owner = BrowserPortForwarder.Owner(id: "host-a/agent", hostName: "build-01")

    /// A hub slot filled from a live client.
    private func slot(_ client: RemoteHostClient) -> BrowserTunnelHubSlot {
        let slot = BrowserTunnelHubSlot()
        slot.hub = client.tunnels
        return slot
    }

    /// One GET over a plain TCP connection to `host` (a numeric loopback address) and `port`.
    private func get(_ path: String, host: String, port: UInt16) async -> String? {
        await Task.detached {
            let family = host.contains(":") ? AF_INET6 : AF_INET
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            // A write to a connection the forwarder already reset must not kill the test process.
            var noSigpipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            // A reply that never comes ends the attempt instead of the test.
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let status: Int32
            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
                status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                address.sin6_addr = in6addr_loopback
                status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            guard status == 0 else { return nil }
            LoopbackServer.writeAll(fd, Data("GET \(path) HTTP/1.1\r\nHost: localhost:\(port)\r\nConnection: close\r\n\r\n".utf8))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = read(fd, &buffer, buffer.count)
                // A signal that interrupts the read is not the end of the reply (under load it happens).
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            let text = String(decoding: data, as: UTF8.self)
            return text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        }.value
    }

    /// A connection the forwarder reset: the page got no bytes, and (when the reset beats the end of
    /// its connect, on a slow machine) not even a connection.
    private func isReset(_ reply: String?) -> Bool {
        reply == nil || reply == ""
    }

    @Test func aClaimedPortReachesTheHostsDevServerOnBothLoopbackAddresses() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }
        let forwarder = BrowserPortForwarder()
        let local = Int(try unusedLoopbackPort())
        defer { forwarder.release(owner) }

        #expect(forwarder.claim(port: local, hostPort: Int(dev.port), owner: owner, slot: slot(client), agent: host.agent) == nil)
        #expect(forwarder.ports(of: owner) == [local])
        let first = await get("/hello", host: "127.0.0.1", port: UInt16(local))
        #expect(first == "hello from the host", "got \(String(describing: first)); the dev server saw \(dev.requests.current)")
        let second = await get("/hello", host: "::1", port: UInt16(local))
        #expect(second == "hello from the host", "got \(String(describing: second)); the dev server saw \(dev.requests.current)")
        // `localhost`, as a page names it, resolves to either.
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://localhost:\(local)/hello")!)
        #expect(String(decoding: data, as: UTF8.self) == "hello from the host")
    }

    @Test func aPortAnotherProgramListensOnIsRefusedAndLeftAlone() async throws {
        let mine = try DevServerFixture()
        defer { mine.stop() }
        let forwarder = BrowserPortForwarder()
        #expect(forwarder.claim(port: Int(mine.port), owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == .inUse(port: Int(mine.port)))
        #expect(forwarder.ports(of: owner).isEmpty)
        // The other program still answers, and saw nothing of the forwarder but a connection probe.
        #expect(await get("/hello", host: "127.0.0.1", port: mine.port) == "hello from the host")
    }

    /// A program listening on the IPv6 loopback alone (Vite on `localhost` often) is the user's too.
    @Test func aPortOnlyTheIPv6LoopbackHoldsIsRefused() async throws {
        let mine = try DevServerFixture(family: .ipv6)
        defer { mine.stop() }
        let forwarder = BrowserPortForwarder()
        #expect(forwarder.claim(port: Int(mine.port), owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == .inUse(port: Int(mine.port)))
    }

    /// A program listening on every address takes loopback connections, so it holds the port too.
    @Test func aPortAProgramListensOnEverywhereIsRefused() async throws {
        let wildcard = try LoopbackServer(address: "0.0.0.0") { close($0) }
        defer { wildcard.stop() }
        let forwarder = BrowserPortForwarder()
        #expect(forwarder.claim(port: Int(wildcard.port), owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == .inUse(port: Int(wildcard.port)))
    }

    @Test func aPortHasOneOwner() async throws {
        let forwarder = BrowserPortForwarder()
        let other = BrowserPortForwarder.Owner(id: "host-b/agent", hostName: "build-02")
        let port = Int(try unusedLoopbackPort())
        defer { forwarder.release(owner); forwarder.release(other) }
        #expect(forwarder.claim(port: port, owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == nil)
        // Its owner may claim it again; another thread's page is told who holds it.
        #expect(forwarder.claim(port: port, owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == nil)
        #expect(forwarder.claim(port: port, owner: other, slot: BrowserTunnelHubSlot(), agent: AgentID())
            == .forwardedFor(port: port, hostName: "build-01"))
        #expect(forwarder.owner(of: port) == owner)
        // Once released, it is free for the other.
        forwarder.release(owner)
        #expect(forwarder.owner(of: port) == nil)
        #expect(forwarder.claim(port: port, owner: other, slot: BrowserTunnelHubSlot(), agent: AgentID()) == nil)
    }

    @Test func aReleasedPortNoLongerListens() async throws {
        let forwarder = BrowserPortForwarder()
        let port = Int(try unusedLoopbackPort())
        #expect(forwarder.claim(port: port, owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == nil)
        forwarder.release(owner)
        try await eventually("the listener to close") { await get("/", host: "127.0.0.1", port: UInt16(port)) == nil }
    }

    /// A page that loaded, a claim released, and the same port claimed again straight away: the
    /// connections the first left in TIME_WAIT must not read as a program using the port.
    @Test func aPortCanBeClaimedAgainRightAfterItWasUsed() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let client = try await host.client()
        defer { client.disconnect() }
        let forwarder = BrowserPortForwarder()
        let port = Int(try unusedLoopbackPort())
        defer { forwarder.release(owner) }

        for round in 0..<3 {
            #expect(forwarder.claim(port: port, hostPort: Int(dev.port), owner: owner, slot: slot(client), agent: host.agent) == nil)
            let reply = await get("/hello", host: "127.0.0.1", port: UInt16(port))
            #expect(reply == "hello from the host", "round \(round) got \(String(describing: reply)); the dev server saw \(dev.requests.current)")
            forwarder.release(owner)
        }
    }

    @Test func aPortBelow1024IsRefusedWithoutTryingToBindIt() {
        let forwarder = BrowserPortForwarder()
        #expect(forwarder.claim(port: 80, owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == .privileged(port: 80))
        #expect(forwarder.claim(port: 0, owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == .invalid(port: 0))
        #expect(forwarder.claim(port: 70_000, owner: owner, slot: BrowserTunnelHubSlot(), agent: AgentID()) == .invalid(port: 70_000))
    }

    /// The connection to the host is gone: the page's connection to a held port resets at once,
    /// and comes back to work when a connection is there again.
    @Test func withNoConnectionAConnectionToAHeldPortResetsAndWorksAgainWhenOneIsBack() async throws {
        let host = try await TunnelHost()
        defer { host.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let forwarder = BrowserPortForwarder()
        let empty = BrowserTunnelHubSlot()
        let port = Int(try unusedLoopbackPort())
        defer { forwarder.release(owner) }
        #expect(forwarder.claim(port: port, hostPort: Int(dev.port), owner: owner, slot: empty, agent: host.agent) == nil)
        #expect(await isReset(get("/hello", host: "127.0.0.1", port: UInt16(port))))

        // A host connects (the store fills the slot), then drops, then another connection comes.
        let first = try await host.client()
        empty.hub = first.tunnels
        #expect(await get("/hello", host: "127.0.0.1", port: UInt16(port)) == "hello from the host")
        first.disconnect()
        try await eventually("the first client to be gone") { first.tunnels.openCount == 0 }
        #expect(await isReset(get("/hello", host: "127.0.0.1", port: UInt16(port))), "the dropped connection's hub has nowhere to send")
        let second = try await host.client()
        defer { second.disconnect() }
        empty.hub = second.tunnels
        #expect(await get("/hello", host: "127.0.0.1", port: UInt16(port)) == "hello from the host")
    }

    @Test func aRefusalSaysWhyInTheHostsName() {
        #expect(BrowserPortForwarder.Refusal.inUse(port: 5173).message(hostName: "build-01")
            == "Port 5173 is in use on this Mac, so build-01’s 5173 can’t be forwarded. Stop what is using it and try again.")
        #expect(BrowserPortForwarder.Refusal.forwardedFor(port: 5173, hostName: "build-02").message(hostName: "build-01")
            == "Port 5173 is already forwarded from build-02, for another thread’s page.")
        #expect(BrowserPortForwarder.Refusal.privileged(port: 80).message(hostName: "build-01").contains("below 1024"))
        #expect(BrowserPortForwarder.Refusal.inUse(port: 5173).port == 5173)
    }
}
