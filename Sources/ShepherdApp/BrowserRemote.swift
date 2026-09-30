import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A remote thread's Browser page (docs/browser.md › Remote): the page renders in this Mac's own web
// view, its URL stays `localhost:5173/checkout`, and its traffic to the host's loopback ports is
// carried to the host over the authenticated connection (ShepherdRemote's tunnels). This is what
// such a page asks of its host, apart from the web view itself (`BrowserHost.swift`, the only file
// that imports WebKit): forwarding the ports its URLs name, waiting for a dev server through the
// tunnel, and the host's dev servers and Start.

/// The ties of one remote thread's page to its host.
@MainActor
final class BrowserRemote {
    let ref: RemoteAgentRef
    private weak var hosts: RemoteHostStore?
    /// The ports of remote hosts forwarded on this Mac, shared by every remote page.
    let ports: BrowserPortForwarder
    private let emptySlot = BrowserTunnelHubSlot()
    /// Tests only: the port on the host that a forwarded port here reaches, where it is not the
    /// same one (a test's host is this very Mac, whose loopback cannot hold a dev server and its
    /// forward at one port).
    var hostPorts: [Int: Int] = [:]
    /// Previews only: a page drawn at `localhost:5173` without listening on this Mac's 5173.
    var forwardsPorts = true

    init(ref: RemoteAgentRef, hosts: RemoteHostStore?, ports: BrowserPortForwarder) {
        self.ref = ref
        self.hosts = hosts
        self.ports = ports
    }

    private var connection: RemoteHostStore.Connection? { hosts?.connections.first { $0.id == ref.hostID } }

    /// The host's name as Settings has it now: the address field's chip, "Start on build-01".
    var hostName: String { connection?.config.name ?? "the host" }

    /// Who holds this page's ports (one per page: a thread's).
    var owner: BrowserPortForwarder.Owner {
        BrowserPortForwarder.Owner(id: "\(ref.hostID.uuidString)/\(ref.agentID.rawValue)", hostName: hostName)
    }

    /// The host carries Browser tunnels, dev servers and Start now.
    var isServed: Bool { connection?.supportsBrowser == true }

    /// The connection to the host is up (observed: a page asks its host again when it comes back).
    var isConnected: Bool { connection?.phase == .connected }

    // MARK: Ports

    /// Forwards the port `url` names on the host, when it names one there (a `localhost`,
    /// `127.0.0.1` or `[::1]` URL: any other is on the web and loads from this Mac as any page
    /// does). Nil when it is forwarded, or needs no forward; else why not, and nothing should load.
    func forward(_ url: URL) -> BrowserPortForwarder.Refusal? {
        guard forwardsPorts, let port = BrowserTunnelTarget.port(of: url) else { return nil }
        return ports.claim(port: port, hostPort: hostPorts[port], owner: owner, slot: connection?.hubSlot ?? emptySlot, agent: ref.agentID)
    }

    /// The page is gone: its ports go with it.
    func release() {
        ports.release(owner)
    }

    /// Whether `port` answers on the host, through the tunnel.
    func answers(port: Int) async -> Bool {
        guard let hub = connection?.hubSlot.hub else { return false }
        return await hub.probe(agentID: ref.agentID, port: hostPorts[port] ?? port) == .reachable
    }

    // MARK: The host's dev servers

    /// The dev servers the thread's folder on the host offers; nil when the host can't say now.
    func devServers() async -> [DevServer]? {
        guard let client = connection?.browserClient, connection?.supportsBrowser == true else { return nil }
        return try? await client.devServers(agentID: ref.agentID)
    }

    /// Runs `server`'s command in a new terminal pane of the thread's layout on the host.
    func start(_ server: DevServer) async throws {
        guard let client = connection?.browserClient, connection?.supportsBrowser == true else {
            throw RemoteHostClientError.rejected(code: "not_sent", message: "\(hostName) is not connected. Reconnect and try again.")
        }
        try await client.openTerminal(agentID: ref.agentID, cwd: server.directory, command: server.command)
    }

    // MARK: What the address field says

    /// The host chip: the host's name while the page is on its loopback (or nothing is open, so
    /// ":5173" means a port there), "This Mac" for a page on the web.
    func chip(for url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return hostName }
        return BrowserTunnelTarget.port(of: url) == nil ? "This Mac" : hostName
    }
}

/// What the pane says when something stops a page (a port that cannot be forwarded).
struct BrowserNotice: Equatable {
    var message: String
}
