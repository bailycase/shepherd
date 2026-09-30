import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol

// Which ports of a remote thread's host are forwarded on this Mac (docs/browser.md › Remote).
//
// A remote thread's page renders in this Mac's own web view, and its URL stays `localhost:5173`.
// WebKit sends `localhost`, `127.0.0.1` and `[::1]` straight to the loopback, never to a proxy (measured:
// docs/browser.md › The spike), so the only way for that page to reach the host's dev server is a
// listener on this Mac's loopback at the same port number. This is that listener. Each accepted
// connection is bridged to a tunnel (`BrowserTunnelHub`) for the owning thread's host.
//
// What that costs is said plainly, because it is what the choice is:
//
// - **A port has one owner.** `localhost:5173` on this Mac can be one thing. If another page's tunnel
//   holds it, or another program on this Mac listens on it, the claim is refused with the reason,
//   never silently pointed at the wrong machine. A program already listening on it (a dev server the
//   user runs here) is found by connecting to the loopback first, so a wildcard listener that would
//   accept loopback connections counts.
// - **The listener is this Mac's loopback port**, so any program or page on this Mac reaches the
//   host's port through it while it is held, as with `ssh -L`. A page of another thread reaches
//   its own thread's host only through its own claims.
// - Only ports a page was opened on (or a dev server it started) are held. A page that calls
//   another `localhost` port needs that port claimed too.
//
// It is shared with the iOS client.

/// A slot the connection's hub sits in, for a listener that outlives one connection: the app fills
/// it when a host connects and empties it when the connection goes, and a connection made to a
/// forwarded port while it is empty is reset (the page shows an ordinary load error).
public final class BrowserTunnelHubSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BrowserTunnelHub?

    public init() {}

    public var hub: BrowserTunnelHub? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

public final class BrowserPortForwarder: @unchecked Sendable {
    /// Who holds a port: one remote thread's page, named for the message a refused claim shows.
    public struct Owner: Hashable, Sendable {
        public let id: String
        public let hostName: String

        public init(id: String, hostName: String) {
            self.id = id
            self.hostName = hostName
        }

        public static func == (a: Owner, b: Owner) -> Bool { a.id == b.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Why a port could not be forwarded.
    public enum Refusal: Error, Equatable, Sendable {
        /// Another program on this Mac listens on it.
        case inUse(port: Int)
        /// Another thread's page holds it, for `hostName`.
        case forwardedFor(port: Int, hostName: String)
        /// The system does not let this app listen on a port below 1024.
        case privileged(port: Int)
        /// The port is not 1...65535.
        case invalid(port: Int)
        /// Something else went wrong binding it.
        case failed(port: Int, errno: Int32)

        public var port: Int {
            switch self {
            case .inUse(let port), .forwardedFor(let port, _), .privileged(let port), .invalid(let port), .failed(let port, _): port
            }
        }

        /// What the pane says, for the host `hostName`.
        public func message(hostName: String) -> String {
            switch self {
            case .inUse(let port):
                "Port \(port) is in use on this Mac, so \(hostName)’s \(port) can’t be forwarded. Stop what is using it and try again."
            case .forwardedFor(let port, let other):
                "Port \(port) is already forwarded from \(other), for another thread’s page."
            case .privileged(let port):
                "Port \(port) is below 1024, and this Mac doesn’t let Shepherd listen on it, so \(hostName)’s \(port) can’t be forwarded."
            case .invalid(let port):
                "\(port) is not a port."
            case .failed(let port, let code):
                "Port \(port) can’t be forwarded from \(hostName): \(String(cString: strerror(code)))."
            }
        }
    }

    private let queue = DispatchQueue(label: "shepherd.browser.forward")
    private let lock = NSLock()
    private var listeners: [Int: Listener] = [:]

    public init() {}

    private final class Listener {
        let port: Int
        let hostPort: Int
        let owner: Owner
        var slot: BrowserTunnelHubSlot
        var agent: AgentID
        var sources: [DispatchSourceRead] = []
        /// Signalled when a source's listening socket is closed (its cancel handler has run).
        var closed: [DispatchSemaphore] = []

        init(port: Int, hostPort: Int, owner: Owner, slot: BrowserTunnelHubSlot, agent: AgentID) {
            self.port = port
            self.hostPort = hostPort
            self.owner = owner
            self.slot = slot
            self.agent = agent
        }
    }

    /// Holds `port` on this Mac's loopback for `owner`: connections made to it go through `slot`'s
    /// hub to `port` on `agent`'s host. Claiming a port `owner` already holds is fine, and moves it
    /// to the new slot and agent. Nil when it is forwarded now, else why not.
    ///
    /// `hostPort` is the port on the host, the same number unless a test's host is this very Mac
    /// (whose loopback cannot hold both the dev server and its forward at one port).
    @discardableResult
    public func claim(port: Int, hostPort: Int? = nil, owner: Owner, slot: BrowserTunnelHubSlot, agent: AgentID) -> Refusal? {
        guard (1...65535).contains(port) else { return .invalid(port: port) }
        lock.lock()
        defer { lock.unlock() }
        if let existing = listeners[port] {
            guard existing.owner == owner else { return .forwardedFor(port: port, hostName: existing.owner.hostName) }
            existing.slot = slot
            existing.agent = agent
            return nil
        }
        if port < 1024 { return .privileged(port: port) }
        switch Self.bind(port: port) {
        case .failure(let refusal):
            return refusal
        case .success(let descriptors):
            let listener = Listener(port: port, hostPort: hostPort ?? port, owner: owner, slot: slot, agent: agent)
            for fd in descriptors {
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self, weak listener] in
                    guard let self, let listener else { return }
                    self.accept(on: fd, for: listener)
                }
                let closed = DispatchSemaphore(value: 0)
                source.setCancelHandler {
                    Darwin.close(fd)
                    closed.signal()
                }
                listener.sources.append(source)
                listener.closed.append(closed)
                source.activate()
            }
            listeners[port] = listener
            return nil
        }
    }

    /// Lets go of every port `owner` holds. The listening sockets are closed when it returns, so the
    /// port can be claimed again at once (a claim that found a socket still open would read it as
    /// another program's).
    public func release(_ owner: Owner) {
        lock.lock()
        let held = listeners.filter { $0.value.owner == owner }
        for port in held.keys { listeners.removeValue(forKey: port) }
        lock.unlock()
        for listener in held.values { listener.sources.forEach { $0.cancel() } }
        for listener in held.values {
            for closed in listener.closed { _ = closed.wait(timeout: .now() + 2) }
        }
    }

    /// The ports `owner` holds.
    public func ports(of owner: Owner) -> Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(listeners.filter { $0.value.owner == owner }.keys)
    }

    /// Who holds `port`, if anyone.
    public func owner(of port: Int) -> Owner? {
        lock.lock()
        defer { lock.unlock() }
        return listeners[port]?.owner
    }

    // MARK: Accepting

    private func accept(on listenFD: Int32, for listener: Listener) {
        while true {
            let fd = Darwin.accept(listenFD, nil, nil)
            if fd < 0 { return }
            lock.lock()
            let hub = listener.slot.hub
            let agent = listener.agent
            lock.unlock()
            guard let hub else {
                // No connection to the host now: the page's connection resets, an ordinary load error.
                var linger = linger(l_onoff: 1, l_linger: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
                Darwin.close(fd)
                continue
            }
            hub.bridge(fd: fd, agentID: agent, port: listener.hostPort)
        }
    }

    // MARK: Binding

    /// Listening sockets on `127.0.0.1` and `[::1]` at `port`, both or (with no IPv6 loopback) the
    /// first. Nothing on either address may answer already: a listener that does (its own, or a
    /// wildcard one that takes loopback connections) is the user's, and a `localhost:port` page
    /// must not silently reach it instead of the host.
    static func bind(port: Int) -> Result<[Int32], Refusal> {
        if answers(port: port, family: AF_INET) || answers(port: port, family: AF_INET6) { return .failure(.inUse(port: port)) }
        var bound: [Int32] = []
        for family in [AF_INET, AF_INET6] {
            switch listen(port: port, family: family) {
            case .success(let fd):
                bound.append(fd)
            case .failure(let failure):
                let code = failure.code
                // No IPv6 loopback is fine; anything else undoes the claim.
                if family == AF_INET6, code == EADDRNOTAVAIL || code == EAFNOSUPPORT, !bound.isEmpty { continue }
                for fd in bound { Darwin.close(fd) }
                switch code {
                case EADDRINUSE: return .failure(.inUse(port: port))
                case EACCES: return .failure(.privileged(port: port))
                default: return .failure(.failed(port: port, errno: code))
                }
            }
        }
        return .success(bound)
    }

    private static func withLoopback<R>(port: Int, family: Int32, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(port).bigEndian
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
    }

    /// Whether something accepts a connection on the loopback at `port`. The loopback answers or
    /// refuses at once, so this does not wait.
    private static func answers(port: Int, family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let result = withLoopback(port: port, family: family) { address, length -> (status: Int32, error: Int32) in
            let status = Darwin.connect(fd, address, length)
            return (status, errno)
        }
        if result.status == 0 { return true }
        guard result.error == EINPROGRESS || result.error == EINTR else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 250) > 0 else { return false }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }

    /// An errno from binding or listening.
    private struct SocketFailure: Error {
        let code: Int32
    }

    private static func listen(port: Int, family: Int32) -> Result<Int32, SocketFailure> {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(SocketFailure(code: errno)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        // A port a listener held a moment ago may have connections in TIME_WAIT; nothing listens
        // on it (`answers` said so), so reusing it is safe.
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if family == AF_INET6 { _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size)) }
        let bound = withLoopback(port: port, family: family) { address, length -> (status: Int32, error: Int32) in
            let status = Darwin.bind(fd, address, length)
            return (status, errno)
        }
        guard bound.status == 0 else {
            Darwin.close(fd)
            return .failure(SocketFailure(code: bound.error))
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            return .failure(SocketFailure(code: code))
        }
        return .success(fd)
    }
}
