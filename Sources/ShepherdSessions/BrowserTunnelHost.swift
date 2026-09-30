import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The host's side of Browser tunnels (docs/browser.md › Remote): a remote client asks for a
// connection to a port on this Mac, and the host connects to that port on its own loopback and
// carries the bytes both ways over the client's authenticated connection.
//
// This is not a general proxy, and that is the point of its shape. A tunnel names only a port, never
// an address: the host connects to `127.0.0.1` and, failing that, `::1`, and nothing else, so a
// client (or a page in its web view) cannot reach a LAN machine, a metadata service or the internet
// from the host through it. It is for one agent's thread that this client may see. It is capped
// per client and per host, closed when idle, and every tunnel of a connection ends with the
// connection.
//
// All of it runs on the server's queue, like every socket the server owns, and none of it blocks:
// sockets are nonblocking, connects finish on a write source, reads and writes are paced by the
// tunnel's credit (`TunnelEndpoint`) and by how much waits in the client's write queue.

/// The host-wide part: the limits and how many tunnels the host carries in all.
final class BrowserTunnelHost {
    struct Limits {
        var perClient = BrowserTunnelLimits.perClient
        var perHost = BrowserTunnelLimits.perHost
        var idle = BrowserTunnelLimits.idleSeconds
        var connect = BrowserTunnelLimits.connectSeconds
        var pauseBacklog = BrowserTunnelLimits.pauseBacklogBytes
        var resumeBacklog = BrowserTunnelLimits.resumeBacklogBytes
    }

    /// Tests shorten them. Read on the server queue.
    var limits = Limits()
    /// Tunnels open across every client (server queue).
    private(set) var count = 0

    fileprivate func opened() { count += 1 }
    fileprivate func closed() { count -= 1 }
}

/// One remote client's tunnels.
final class BrowserTunnelSession {
    private let host: BrowserTunnelHost
    private let queue: DispatchQueue
    private let emit: (BrowserTunnelFrame) -> Void
    private let backlog: () -> Int
    private var tunnels: [Int: Tunnel] = [:]
    private var backedUp = false
    private var scanner: DispatchSourceTimer?

    /// `emit` sends a frame to the client; `backlog` is how many bytes wait in its write queue.
    init(host: BrowserTunnelHost, queue: DispatchQueue, emit: @escaping (BrowserTunnelFrame) -> Void, backlog: @escaping () -> Int) {
        self.host = host
        self.queue = queue
        self.emit = emit
        self.backlog = backlog
    }

    var count: Int { tunnels.count }
    /// Reads are held for the client's write queue to drain (`backlogDidDrain` lets them go).
    var isPaused: Bool { backedUp }

    private final class Tunnel {
        let id: Int
        let port: Int
        let openedAt = DispatchTime.now()
        var lastFromClient = DispatchTime.now()
        var connector: LoopbackConnector?
        var endpoint: TunnelEndpoint?
        /// What the client sent before the port answered, in order, and whether it finished.
        var early: [Data] = []
        var earlyBytes = 0
        var earlyFinish = false

        init(id: Int, port: Int) {
            self.id = id
            self.port = port
        }
    }

    // MARK: Frames from the client

    /// One frame from the client. `authorize` says whether the client may open a tunnel for an
    /// agent (it exists, and this client sees it).
    func handle(_ frame: BrowserTunnelFrame, authorize: (AgentID) -> Bool) {
        switch frame {
        case .open(let id, let agentID, let port):
            open(id, agentID: agentID, port: port, authorize: authorize)
        case .data(let id, let bytes):
            guard let tunnel = tunnels[id] else { return }
            tunnel.lastFromClient = .now()
            if let endpoint = tunnel.endpoint {
                endpoint.receive(bytes)
            } else {
                // The client may send at once. Held until the port answers, at most a window.
                tunnel.earlyBytes += bytes.count
                guard bytes.count <= BrowserTunnelLimits.chunkBytes, tunnel.earlyBytes <= BrowserTunnelLimits.window else {
                    end(tunnel, code: BrowserTunnelCode.violation)
                    return
                }
                tunnel.early.append(bytes)
            }
        case .credit(let id, let bytes):
            tunnels[id]?.endpoint?.grant(bytes)
        case .finish(let id):
            guard let tunnel = tunnels[id] else { return }
            tunnel.lastFromClient = .now()
            if let endpoint = tunnel.endpoint { endpoint.receiveFinish() } else { tunnel.earlyFinish = true }
        case .close(let id, _):
            if let tunnel = tunnels[id] { remove(tunnel) }
        case .keepalive(let id):
            tunnels[id]?.lastFromClient = .now()
        case .opened:
            // Only a host says it.
            emit(.close(tunnel: frame.tunnel, code: BrowserTunnelCode.violation))
        }
    }

    private func open(_ id: Int, agentID: AgentID, port: Int, authorize: (AgentID) -> Bool) {
        // An id in use breaks the protocol: the tunnel already there is ended as well.
        if let existing = tunnels[id] {
            end(existing, code: BrowserTunnelCode.violation)
            return
        }
        guard (1...65535).contains(port) else {
            emit(.close(tunnel: id, code: BrowserTunnelCode.invalidPort))
            return
        }
        guard authorize(agentID) else {
            emit(.close(tunnel: id, code: BrowserTunnelCode.noSuchAgent))
            return
        }
        guard tunnels.count < host.limits.perClient, host.count < host.limits.perHost else {
            emit(.close(tunnel: id, code: BrowserTunnelCode.tooMany))
            return
        }
        let tunnel = Tunnel(id: id, port: port)
        tunnels[id] = tunnel
        host.opened()
        startScanning()
        tunnel.connector = LoopbackConnector(port: port, queue: queue, timeout: host.limits.connect) { [weak self, weak tunnel] result in
            guard let self, let tunnel, self.tunnels[tunnel.id] === tunnel else {
                if case .success(let fd) = result { Darwin.close(fd) }
                return
            }
            tunnel.connector = nil
            switch result {
            case .success(let fd): self.connected(tunnel, fd: fd)
            case .failure(let failure): self.end(tunnel, code: failure.code)
            }
        }
    }

    private func connected(_ tunnel: Tunnel, fd: Int32) {
        let endpoint = TunnelEndpoint(fd: fd, queue: queue)
        let id = tunnel.id
        endpoint.gate = { [weak self] in self?.gateOpen() ?? false }
        endpoint.onData = { [weak self] bytes in self?.emit(.data(tunnel: id, bytes: bytes)) }
        endpoint.onFinish = { [weak self] in self?.emit(.finish(tunnel: id)) }
        endpoint.onCredit = { [weak self] bytes in self?.emit(.credit(tunnel: id, bytes: bytes)) }
        endpoint.onDone = { [weak self, weak tunnel] in
            if let self, let tunnel { self.remove(tunnel) }
        }
        endpoint.onFailure = { [weak self, weak tunnel] code in
            if let self, let tunnel { self.end(tunnel, code: code) }
        }
        tunnel.endpoint = endpoint
        endpoint.start()
        emit(.opened(tunnel: id))
        let early = tunnel.early
        let finished = tunnel.earlyFinish
        tunnel.early = []
        tunnel.earlyBytes = 0
        for bytes in early where tunnels[id] === tunnel { endpoint.receive(bytes) }
        if finished, tunnels[id] === tunnel { endpoint.receiveFinish() }
    }

    // MARK: Ending

    /// The tunnel is over and the client is told why.
    private func end(_ tunnel: Tunnel, code: String) {
        guard tunnels[tunnel.id] === tunnel else { return }
        remove(tunnel)
        emit(.close(tunnel: tunnel.id, code: code))
    }

    /// The tunnel is over; nobody is told.
    private func remove(_ tunnel: Tunnel) {
        guard tunnels[tunnel.id] === tunnel else { return }
        tunnels.removeValue(forKey: tunnel.id)
        tunnel.connector?.cancel()
        tunnel.connector = nil
        tunnel.endpoint?.close()
        tunnel.endpoint = nil
        host.closed()
        if tunnels.isEmpty { stopScanning() }
    }

    /// The client's connection is gone (or tunnels are switched off): every tunnel ends, every
    /// socket closes.
    func closeAll() {
        for tunnel in Array(tunnels.values) { remove(tunnel) }
    }

    /// Tunnels are switched off while some are open: each is told.
    func endAll(code: String) {
        for tunnel in Array(tunnels.values) { end(tunnel, code: code) }
    }

    // MARK: Pace

    /// Whether the client's write queue has room: with hysteresis, so reads stop at the high water
    /// and start again only below the low one.
    private func gateOpen() -> Bool {
        let waiting = backlog()
        if backedUp {
            if waiting <= host.limits.resumeBacklog { backedUp = false }
        } else if waiting >= host.limits.pauseBacklog {
            backedUp = true
        }
        return !backedUp
    }

    /// The server's write queue for the client drained: reads that were held may go on.
    func backlogDidDrain() {
        guard backedUp, backlog() <= host.limits.resumeBacklog else { return }
        backedUp = false
        for tunnel in tunnels.values { tunnel.endpoint?.gateChanged() }
    }

    // MARK: Idle and slow connects

    private func startScanning() {
        guard scanner == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(0.05, min(5, host.limits.idle / 4))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.scan() }
        scanner = timer
        timer.activate()
    }

    private func stopScanning() {
        scanner?.cancel()
        scanner = nil
    }

    private func scan() {
        let now = DispatchTime.now()
        for tunnel in Array(tunnels.values) {
            if tunnel.endpoint == nil {
                if seconds(from: tunnel.openedAt, to: now) > host.limits.connect { end(tunnel, code: BrowserTunnelCode.timeout) }
                continue
            }
            let last = max(tunnel.lastFromClient.uptimeNanoseconds, tunnel.endpoint?.lastActivity.uptimeNanoseconds ?? 0)
            if seconds(from: DispatchTime(uptimeNanoseconds: last), to: now) > host.limits.idle {
                end(tunnel, code: BrowserTunnelCode.idle)
            }
        }
    }

    private func seconds(from a: DispatchTime, to b: DispatchTime) -> TimeInterval {
        Double(b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1_000_000_000
    }
}

/// Connects to a port on this Mac's loopback, `127.0.0.1` first and `::1` if nothing answers there
/// (a dev server may listen on either: Vite on `localhost` often takes only `::1`). No other address
/// is ever tried. Nonblocking: the connect finishes on a write source on the caller's queue.
final class LoopbackConnector {
    private let port: UInt16
    private let queue: DispatchQueue
    private let completion: (Result<Int32, ConnectFailure>) -> Void
    private var candidates: [Int32] = [AF_INET, AF_INET6]
    private var source: DispatchSourceWrite?
    private var fd: Int32 = -1
    private var finished = false
    private var timer: DispatchSourceTimer?

    /// The tunnel code the attempt ended with.
    struct ConnectFailure: Error {
        let code: String
    }

    init(port: Int, queue: DispatchQueue, timeout: TimeInterval, completion: @escaping (Result<Int32, ConnectFailure>) -> Void) {
        self.port = UInt16(port)
        self.queue = queue
        self.completion = completion
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(ConnectFailure(code: BrowserTunnelCode.timeout))) }
        self.timer = timer
        timer.activate()
        // The caller has not stored this yet: start on the next turn so its state is in place.
        queue.async { [self] in tryNext() }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        teardownAttempt()
        timer?.cancel()
        timer = nil
    }

    private func tryNext() {
        guard !finished else { return }
        guard !candidates.isEmpty else {
            finish(.failure(ConnectFailure(code: BrowserTunnelCode.refused)))
            return
        }
        let family = candidates.removeFirst()
        let socketFD = socket(family, SOCK_STREAM, 0)
        guard socketFD >= 0 else { tryNext(); return }
        _ = fcntl(socketFD, F_SETFL, fcntl(socketFD, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let status: Int32
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
            status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        if status == 0 {
            finish(.success(socketFD))
            return
        }
        guard errno == EINPROGRESS else {
            Darwin.close(socketFD)
            tryNext()
            return
        }
        fd = socketFD
        let writable = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: queue)
        let box = KeepBox()
        writable.setCancelHandler { if !box.keep { Darwin.close(socketFD) } }
        writable.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &error, &size) != 0 { error = errno }
            if error == 0 {
                box.keep = true
                self.fd = -1
                self.source?.cancel()
                self.source = nil
                self.finish(.success(socketFD))
            } else {
                self.source?.cancel()
                self.source = nil
                self.fd = -1
                self.tryNext()
            }
        }
        source = writable
        writable.activate()
    }

    private final class KeepBox { var keep = false }

    private func teardownAttempt() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func finish(_ result: Result<Int32, ConnectFailure>) {
        guard !finished else {
            if case .success(let fd) = result { Darwin.close(fd) }
            return
        }
        finished = true
        timer?.cancel()
        timer = nil
        teardownAttempt()
        completion(result)
    }
}
