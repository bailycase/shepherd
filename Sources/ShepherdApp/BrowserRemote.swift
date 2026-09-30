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
    /// Where an agent on the host may take this page (`BrowserViewerPolicy`); tests give it a
    /// resolver that never asks the network.
    var policy: BrowserViewerPolicy
    /// The page this claim drives, set as the session is made.
    weak var session: BrowserSession?

    // The agent on the host drives this page (docs/browser.md › Remote).
    private(set) var claimant: BrowserDriveClaimant
    /// The connection the claim was made on: a claim dies with its connection.
    private var claimClient: RemoteHostClient?
    private var releaseTask: Task<Void, Never>?

    init(ref: RemoteAgentRef, hosts: RemoteHostStore?, ports: BrowserPortForwarder,
         policy: BrowserViewerPolicy = BrowserViewerPolicy(),
         claimant: BrowserDriveClaimant = BrowserDriveClaimant()) {
        self.ref = ref
        self.hosts = hosts
        self.ports = ports
        self.policy = policy
        self.claimant = claimant
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
    func forward(_ url: URL, limit: Int? = nil) -> BrowserPortForwarder.Refusal? {
        guard forwardsPorts, let port = BrowserTunnelTarget.port(of: url) else { return nil }
        if let limit {
            let held = ports.ports(of: owner)
            if !held.contains(port), held.count >= limit { return .tooMany(port: port, limit: limit) }
        }
        return ports.claim(port: port, hostPort: hostPorts[port], owner: owner, slot: connection?.hubSlot ?? emptySlot, agent: ref.agentID)
    }

    /// The page is gone: its ports go with it, and the agent's browser goes back to the host.
    func release() {
        releaseTask?.cancel()
        releaseTask = nil
        if claimant.holds { claimClient?.browserRelease(agentID: ref.agentID) }
        claimClient = nil
        _ = claimant.connection(up: false)
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

    // MARK: The agent drives this page

    /// The connection, when the host offers the agent this page (`browser.drive.v1`).
    var driveClient: RemoteHostClient? {
        guard let client = connection?.browserClient, client.drivesBrowser else { return nil }
        return client
    }

    /// This viewer holds the claim on `client`'s connection, so a request it carries is this page's
    /// to run.
    func drives(for client: RemoteHostClient) -> Bool {
        claimant.holds && claimClient === client
    }

    /// The Browser tab came on screen: the agent's browser is claimed.
    func paneShown() {
        releaseTask?.cancel()
        releaseTask = nil
        syncDriveConnection()
        apply(claimant.tabShown())
    }

    /// The tab went out of sight: the claim stays for a little (`BrowserDriveLimits`), then goes
    /// back to the host.
    func paneHidden() {
        claimant.tabHidden(now: Date())
        guard let deadline = claimant.releaseDeadline else { return }
        releaseTask?.cancel()
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.05))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.claimant.release(now: Date()))
        }
    }

    /// The connection came up, changed or went: a claim does not survive it, and a tab on screen
    /// claims again on the new one.
    func syncDriveConnection() {
        let client = driveClient
        if let claimClient, claimClient !== client {
            self.claimClient = nil
            _ = claimant.connection(up: false)
        }
        apply(claimant.connection(up: client != nil))
    }

    /// The host says this Mac no longer owns the agent's browser (`BrowserDriveEnd`).
    func driveEnded(reason: String) {
        claimant.ended(reason: reason)
        claimClient = nil
        session?.abandonQueued()
        if reason == BrowserDriveEnd.superseded { session?.notice = BrowserNotice(message: Self.supersededMessage) }
    }

    static let supersededMessage = "Another Mac is showing this thread’s browser to the agent now. Show this tab again to take it back."

    private func apply(_ action: BrowserDriveClaimant.Action?) {
        switch action {
        case .claim?:
            claim()
        case .release?:
            if let claimClient, claimClient === driveClient { claimClient.browserRelease(agentID: ref.agentID) }
            claimClient = nil
        case nil:
            break
        }
    }

    private func claim() {
        guard let client = driveClient else {
            claimant.claimFailed(code: "unsupported")
            return
        }
        claimClient = client
        let agentID = ref.agentID
        Task { @MainActor [weak self] in
            do {
                let address = try await client.browserClaim(agentID: agentID)
                guard let self, self.claimClient === client else { return }
                if self.claimant.claimed() { self.claimed(adopting: address) }
            } catch {
                guard let self, self.claimClient === client else { return }
                var code = "failed"
                if case RemoteHostClientError.rejected(let rejected, _) = error { code = rejected }
                self.claimant.claimFailed(code: code)
                if code == BrowserDriveEnd.superseded { self.session?.notice = BrowserNotice(message: Self.supersededMessage) }
                self.claimClient = nil
            }
        }
    }

    /// The claim stands. The agent has the page (a Take over from before is over), and a tab with
    /// nothing open opens the page the agent left on the host, through the tunnel, when it is one
    /// this Mac may open (cookies are not carried over).
    private func claimed(adopting address: String?) {
        guard let session else { return }
        if session.notice?.message == Self.supersededMessage { session.dismissNotice() }
        session.handBack()
        guard !session.hasPage, let address, BrowserDriveURL.offered(address) != nil, let url = URL(string: address) else { return }
        Task { @MainActor [weak self] in
            guard let self, let session = self.session, !session.hasPage else { return }
            if case .refused = await self.policy.verdict(for: url) { return }
            if !session.hasPage { session.load(url) }
        }
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
