import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol

// The viewer's side of Browser tunnels (docs/browser.md › Remote): one hub per host connection,
// opening a tunnel on demand for each connection the viewer's web view makes to a forwarded port,
// and carrying its bytes over the connection as frames. It knows nothing of WebKit or of which
// ports are forwarded (`BrowserPortForwarder` owns that): it is handed a connected socket and the
// agent and port it is for, and bridges the two.
//
// A dropped connection ends every tunnel of it (`connectionLost`); the next connection to a
// forwarded port opens a new one on the new connection, and the page in the meantime shows an
// ordinary load error. The hub is shared with the iOS client.

/// What a hub needs of the connection it rides on.
public protocol BrowserTunnelLink: AnyObject {
    /// Sends a frame to the host. Called on the hub's queue.
    func sendTunnel(_ frame: BrowserTunnelFrame)
    /// Bytes waiting to go to the host: the hub reads no local socket while too many do. On the
    /// hub's queue.
    var tunnelBacklogBytes: Int { get }
    /// The connection is up and the host carries tunnels. On the hub's queue.
    var tunnelsAvailable: Bool { get }
}

/// What `BrowserTunnelHub.probe` found.
public enum BrowserTunnelProbe: Equatable, Sendable {
    /// The port answered on the host.
    case reachable
    /// Nothing answered: no tunnel, or the host said why (`BrowserTunnelCode`).
    case failed(String)
    /// There is no connection to the host, or it does not carry tunnels.
    case unavailable
}

public final class BrowserTunnelHub: @unchecked Sendable {
    /// Tunnels this hub keeps open at most: the host's per-client limit.
    public static let maxTunnels = BrowserTunnelLimits.perClient

    private let queue: DispatchQueue
    /// The connection. Set once by its owner.
    public weak var link: BrowserTunnelLink?
    private var tunnels: [Int: Tunnel] = [:]
    private var nextID = 1
    private var backedUp = false
    private var keepalive: DispatchSourceTimer?
    /// How long a probe waits for the host's answer.
    public var probeSeconds: TimeInterval = BrowserTunnelLimits.connectSeconds + 5
    /// How often a tunnel is said to be still wanted (tests shorten it).
    public var keepaliveSeconds: TimeInterval = BrowserTunnelLimits.keepaliveSeconds

    private final class Tunnel {
        let id: Int
        var endpoint: TunnelEndpoint?
        var probe: CheckedContinuation<BrowserTunnelProbe, Never>?
        init(id: Int) { self.id = id }
    }

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Tunnels open now (a snapshot, for tests and the pane).
    public var openCount: Int { queue.sync { tunnels.count } }

    // MARK: Opening

    /// Bridges `fd`, a connected socket the viewer's web view opened to a forwarded port, to
    /// `port` on `agentID`'s host. Takes ownership of `fd`: it is closed when the tunnel is over,
    /// or now if no tunnel can be made (no connection, or as many tunnels as the host allows),
    /// which the page sees as a connection reset. Any thread.
    public func bridge(fd: Int32, agentID: AgentID, port: Int) {
        queue.async { [self] in
            guard let link, link.tunnelsAvailable, tunnels.count < Self.maxTunnels else {
                Self.reset(fd)
                return
            }
            let tunnel = Tunnel(id: nextID)
            nextID += 1
            let endpoint = TunnelEndpoint(fd: fd, queue: queue)
            let id = tunnel.id
            endpoint.gate = { [weak self] in self?.gateOpen() ?? false }
            endpoint.onData = { [weak self] bytes in self?.send(.data(tunnel: id, bytes: bytes)) }
            endpoint.onFinish = { [weak self] in self?.send(.finish(tunnel: id)) }
            endpoint.onCredit = { [weak self] bytes in self?.send(.credit(tunnel: id, bytes: bytes)) }
            endpoint.onDone = { [weak self, weak tunnel] in
                if let self, let tunnel { self.remove(tunnel) }
            }
            endpoint.onFailure = { [weak self, weak tunnel] code in
                guard let self, let tunnel else { return }
                self.send(.close(tunnel: tunnel.id, code: code))
                self.remove(tunnel)
            }
            tunnel.endpoint = endpoint
            tunnels[id] = tunnel
            send(.open(tunnel: id, agentID: agentID, port: port))
            endpoint.start()
            startKeepalive()
        }
    }

    /// Whether `port` answers on `agentID`'s host: opens a tunnel and closes it at once.
    public func probe(agentID: AgentID, port: Int) async -> BrowserTunnelProbe {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let link, link.tunnelsAvailable, tunnels.count < Self.maxTunnels else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                let tunnel = Tunnel(id: nextID)
                nextID += 1
                tunnel.probe = continuation
                tunnels[tunnel.id] = tunnel
                send(.open(tunnel: tunnel.id, agentID: agentID, port: port))
                let id = tunnel.id
                queue.asyncAfter(deadline: .now() + probeSeconds) { [weak self] in
                    guard let self, let tunnel = self.tunnels[id], tunnel.probe != nil else { return }
                    self.send(.close(tunnel: id, code: BrowserTunnelCode.timeout))
                    self.remove(tunnel, probeResult: .failed(BrowserTunnelCode.timeout))
                }
            }
        }
    }

    // MARK: From the host (the hub's queue)

    /// A frame from the host, on the hub's queue (the connection's).
    public func receive(_ frame: BrowserTunnelFrame) {
        guard let tunnel = tunnels[frame.tunnel] else { return }
        switch frame {
        case .opened:
            if let probe = tunnel.probe {
                tunnel.probe = nil
                probe.resume(returning: .reachable)
                send(.close(tunnel: tunnel.id, code: nil))
                remove(tunnel)
            }
        case .data(_, let bytes):
            tunnel.endpoint?.receive(bytes)
        case .credit(_, let bytes):
            tunnel.endpoint?.grant(bytes)
        case .finish:
            tunnel.endpoint?.receiveFinish()
        case .close(_, let code):
            remove(tunnel, probeResult: .failed(code ?? BrowserTunnelCode.aborted), abort: true)
        case .open, .keepalive:
            break
        }
    }

    /// The connection went away: every tunnel ends, and its socket resets. On the hub's queue.
    public func connectionLost() {
        for tunnel in Array(tunnels.values) { remove(tunnel, probeResult: .failed(BrowserTunnelCode.aborted), abort: true) }
    }

    /// The connection's write queue drained: local sockets held for it are read again. On the
    /// hub's queue.
    public func backlogDidDrain() {
        guard backedUp else { return }
        _ = gateOpen()
        for tunnel in tunnels.values { tunnel.endpoint?.gateChanged() }
    }

    // MARK: Plumbing

    private func send(_ frame: BrowserTunnelFrame) {
        link?.sendTunnel(frame)
    }

    private func remove(_ tunnel: Tunnel, probeResult: BrowserTunnelProbe? = nil, abort: Bool = false) {
        guard tunnels[tunnel.id] === tunnel else { return }
        tunnels.removeValue(forKey: tunnel.id)
        if let probe = tunnel.probe {
            tunnel.probe = nil
            probe.resume(returning: probeResult ?? .failed(BrowserTunnelCode.aborted))
        }
        if abort { tunnel.endpoint?.abort() } else { tunnel.endpoint?.close() }
        tunnel.endpoint = nil
        if tunnels.isEmpty { stopKeepalive() }
    }

    /// With hysteresis: local sockets are read again only once the connection's queue is low.
    private func gateOpen() -> Bool {
        let waiting = link?.tunnelBacklogBytes ?? 0
        if backedUp {
            if waiting <= BrowserTunnelLimits.resumeBacklogBytes { backedUp = false }
        } else if waiting >= BrowserTunnelLimits.pauseBacklogBytes {
            backedUp = true
        }
        return !backedUp
    }

    private func startKeepalive() {
        guard keepalive == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = keepaliveSeconds
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Only for a tunnel whose local socket is still sending: one it has finished with is left to
            // the host's idle rule, so a target that never closes cannot keep it up for good.
            for tunnel in self.tunnels.values where tunnel.endpoint?.isReadFinished == false { self.send(.keepalive(tunnel: tunnel.id)) }
        }
        keepalive = timer
        timer.activate()
    }

    private func stopKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    /// Closes `fd` so the peer sees a reset, not a clean end.
    private static func reset(_ fd: Int32) {
        var linger = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
        Darwin.close(fd)
    }
}
