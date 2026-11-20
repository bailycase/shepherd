import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

/// One remote thread's page and the host ports it forwards, for a viewer
/// that holds them only while it can use them: the iOS client lets every port go when its connection
/// to the host drops (which the app's going to the background does) and takes them again when it is
/// back, so nothing listens on the device's loopback while the app can't serve it. A page holds at
/// most `limit` ports, so its links can't have the device hold a listener for each.
///
/// Use it from one thread (the iOS client's main actor).
public final class BrowserPagePorts {
    /// Ports one page may hold at once, as many as a host's agent may have the Mac's page hold.
    public static let limit = 8

    public let forwarder: BrowserPortForwarder
    public let owner: BrowserPortForwarder.Owner
    public let agent: AgentID
    /// The connection's hub, filled while the host is connected.
    public let slot: BrowserTunnelHubSlot
    /// The ports the page named and got, in the order it named them; taken again on `resume`.
    public private(set) var ports: [Int] = []
    /// The ports are held now (between `resume` and `suspend`).
    public private(set) var isActive = false
    /// Tests only: the port on the host a port here reaches, where it is not the same one (a test's
    /// host is this very machine, whose loopback cannot hold a dev server and its forward at one port).
    public var hostPorts: [Int: Int] = [:]

    public init(forwarder: BrowserPortForwarder, owner: BrowserPortForwarder.Owner, agent: AgentID, slot: BrowserTunnelHubSlot) {
        self.forwarder = forwarder
        self.owner = owner
        self.agent = agent
        self.slot = slot
    }

    /// Forwards the port `url` names on the host, when it names one there (a `localhost`,
    /// `127.0.0.1` or `[::1]` URL; any other is on the web and needs none). Nil when it is forwarded
    /// or needs no forward; else why not, and the page must not load it: while suspended nothing
    /// listens, and the device's own program on that port would answer in the host's place.
    public func forward(_ url: URL) -> BrowserPortForwarder.Refusal? {
        guard let port = BrowserTunnelTarget.port(of: url) else { return nil }
        guard isActive else { return .failed(port: port, errno: ENOTCONN) }
        if !ports.contains(port), ports.count >= Self.limit { return .tooMany(port: port, limit: Self.limit) }
        if let refusal = forwarder.claim(port: port, hostPort: hostPorts[port], owner: owner, slot: slot, agent: agent) { return refusal }
        if !ports.contains(port) { ports.append(port) }
        return nil
    }

    /// The host is connected (again): every port the page held is taken again. A port whose old
    /// sockets have not closed yet is claimed again once the close lands, not forgotten as in use.
    /// The ones that can't be (something else took one meanwhile) are let go and returned, so the
    /// page can say why.
    @discardableResult
    public func resume() async -> [BrowserPortForwarder.Refusal] {
        isActive = true
        var refused: [BrowserPortForwarder.Refusal] = []
        for port in ports {
            var refusal = forwarder.claim(port: port, hostPort: hostPorts[port], owner: owner, slot: slot, agent: agent)
            if case .inUse = refusal {
                // The old sockets may still be closing from `suspend`: wait for the real close and
                // try once more, so a late close does not read as another program's. A refusal that
                // is still there afterwards is genuine, and the port is let go below.
                await forwarder.waitForClose(of: port)
                refusal = forwarder.claim(port: port, hostPort: hostPorts[port], owner: owner, slot: slot, agent: agent)
            }
            if let refusal { refused.append(refusal) }
        }
        ports.removeAll { port in refused.contains { $0.port == port } }
        return refused
    }

    /// The host went away or the app is leaving the foreground: every port is let go now (the
    /// listening sockets close shortly after, without blocking the caller) and remembered for `resume`.
    public func suspend() {
        isActive = false
        forwarder.release(owner)
    }

    /// The page is gone: nothing is held or remembered.
    public func close() {
        suspend()
        ports.removeAll()
    }
}
