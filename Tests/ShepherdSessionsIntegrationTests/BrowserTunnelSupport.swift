import CryptoKit
import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

// What the Browser tunnel tests share: a host with one thread, and the two ends a test talks to
// the tunnel through.

/// A host with an agent in a workspace, the way a remote viewer finds it.
struct TunnelHost {
    let remote: RemoteHost
    let agent: AgentID

    var server: SessionServer { remote.server }

    /// `folder` is the agent's directory (its dev servers are read from there).
    init(folder: String? = nil) async throws {
        remote = try RemoteHost()
        let space = Fixture.space("web", path: folder)
        let seeded = Fixture.agent(in: space)
        try await remote.host.seed(Fixture.workspace([seeded], space: space))
        agent = seeded.agent.id
    }

    func stop() { remote.stop() }

    /// A typed client that lists the tunnel capability, as the Mac app's does.
    func client() async throws -> RemoteHostClient {
        try await remote.typed()
    }

    /// A raw client that says it reads tunnel frames (`clientCapabilities`), or does not.
    func raw(tunnels: Bool = true) async throws -> RawRemote {
        let client = try await remote.raw(authenticated: false)
        let capabilities = tunnels ? RemoteProtocol.clientCapabilities
            : RemoteProtocol.clientCapabilities.filter { $0 != RemoteProtocol.browserTunnelCapability }
        try await client.hello(token: remote.token, capabilities: capabilities)
        return client
    }
}

extension RawRemote {
    /// The next tunnel frame, skipping the state pushes and other frames a host sends meanwhile.
    func nextTunnel(timeout: Duration = .seconds(10)) async throws -> BrowserTunnelFrame {
        while true {
            if case .tunnel(let frame) = try await next(timeout: timeout) { return frame }
        }
    }

    func sendTunnel(_ frame: BrowserTunnelFrame) throws {
        try send(.tunnel(frame))
    }

    /// Opens a tunnel and waits for its first answer.
    func open(_ tunnel: Int, agent: AgentID, port: UInt16) async throws -> BrowserTunnelFrame {
        try sendTunnel(.open(tunnel: tunnel, agentID: agent, port: Int(port)))
        return try await nextTunnel()
    }
}

/// The viewer's web view end of a tunnel: one end of a socket pair whose other end the hub owns,
/// as it would own an accepted connection from WebKit. Blocking reads run off the test's thread.
final class TunnelPeer: @unchecked Sendable {
    let fd: Int32

    /// Bridges a new socket pair to `port` on `agent`'s host through `hub`.
    init(hub: BrowserTunnelHub, agent: AgentID, port: UInt16) throws {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw WireError("socketpair: errno \(errno)") }
        fd = pair[0]
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        hub.bridge(fd: pair[1], agentID: agent, port: Int(port))
    }

    private let closeLock = NSLock()
    private var closed = false

    deinit { close() }

    /// Closes this end, as a web view does when it is done with a connection.
    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    /// Writes all of `data` (blocking: the tunnel's credit paces it).
    func send(_ data: Data) async {
        let fd = fd
        await Task.detached { _ = LoopbackServer.writeAll(fd, data) }.value
    }

    /// Half-closes: no more bytes from this end.
    func finish() { shutdown(fd, SHUT_WR) }

    /// Reads until the tunnel ends (EOF or reset), or `limit` bytes; nil on timeout.
    func readToEnd(timeout: TimeInterval = 30, limit: Int = .max) async -> Data {
        let fd = fd
        return await Task.detached {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let deadline = Date().addingTimeInterval(timeout)
            while data.count < limit, Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&pfd, 1, 100) > 0 else { continue }
                let n = Darwin.read(fd, &buffer, min(buffer.count, limit - data.count))
                // A signal that interrupts the read is not the end of the tunnel.
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }.value
    }

    /// Reads exactly `count` bytes, or fewer if the tunnel ends or `timeout` passes.
    func read(_ count: Int, timeout: TimeInterval = 30) async -> Data {
        await readToEnd(timeout: timeout, limit: count)
    }
}

/// A one-request HTTP exchange through a tunnel: what a page's request is to the host's dev server.
extension TunnelPeer {
    func http(_ method: String, _ path: String, body: Data? = nil) async -> (status: String, body: Data) {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        await send(Data(head.utf8))
        if let body { await send(body) }
        let reply = await readToEnd()
        // The response has ended (the tunnel finished it): the page's connection closes.
        close()
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = reply.range(of: terminator) else { return ("", reply) }
        let status = String(decoding: reply[reply.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")[0]
        return (status, Data(reply[end.upperBound...]))
    }
}

/// A port on the loopback nothing listens on.
func unusedLoopbackPort() throws -> UInt16 {
    let server = try LoopbackServer { close($0) }
    let port = server.port
    server.stop()
    return port
}
