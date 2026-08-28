import Foundation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

/// Sidebar selection target for an agent on a remote host.
struct RemoteAgentRef: Hashable {
    var hostID: UUID
    var agentID: AgentID
}

/// Configured remote Shepherd hosts (persisted in UserDefaults as JSON) and
/// one live connection per host. The remote host runs the full Shepherd app;
/// this store is the MacBook-side viewer: it adopts pushed state for the
/// sidebar and bridges attached panes' terminals over the wire.
///
/// Reconnects with backoff while a host is unreachable — a laptop that slept
/// picks its hosts back up without any UI action.
@MainActor
final class RemoteHostStore: ObservableObject {
    struct HostConfig: Codable, Hashable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var host: String
        var port: UInt16
        var token: String
    }

    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @MainActor
    final class Connection: ObservableObject, Identifiable {
        /// Editable in Settings; the store reconnects after a change.
        @Published fileprivate(set) var config: HostConfig
        @Published var phase: Phase = .disconnected
        @Published var state = ShepherdState()
        fileprivate var stateGeneration = 0
        fileprivate var client: RemoteHostClient?
        fileprivate var reconnectTask: Task<Void, Never>?
        fileprivate var reconnectDelay: Duration = .seconds(1)
        /// Panes attached through this connection, keyed by the host-side
        /// session id. Weak-held by the pane views' lifetime: detach removes.
        fileprivate var panes: [SessionID: RemotePaneSession] = [:]

        let id: UUID

        init(config: HostConfig) {
            self.config = config
            self.id = config.id
        }

        func pane(for sessionID: SessionID) -> RemotePaneSession? {
            panes[sessionID]
        }
    }

    static let defaultsKey = "shepherd.remote.hosts"

    @Published private(set) var connections: [Connection] = []

    private let defaults: UserDefaults

    var hosts: [HostConfig] {
        connections.map(\.config)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let configs = try? JSONDecoder().decode([HostConfig].self, from: data) {
            connections = configs.map(Connection.init)
        }
        for connection in connections {
            connect(connection)
        }
    }

    func addHost(name: String, host: String, port: UInt16, token: String) {
        let config = HostConfig(name: name, host: host, port: port, token: token)
        let connection = Connection(config: config)
        connections.append(connection)
        persist()
        connect(connection)
    }

    /// Update a host's config and reconnect with the new values.
    func updateHost(id: UUID, name: String, host: String, port: UInt16, token: String) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        var config = connection.config
        config.name = name
        config.host = host
        config.port = port
        config.token = token
        connection.config = config
        persist()
        reconnect(id: id)
    }

    func removeHost(id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let connection = connections.remove(at: index)
        connection.reconnectTask?.cancel()
        connection.client?.disconnect()
        connection.client = nil
        for pane in connection.panes.values {
            pane.phase = .failed("host removed")
        }
        connection.panes.removeAll()
        persist()
    }

    func reconnect(id: UUID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        connection.reconnectTask?.cancel()
        for pane in connection.panes.values {
            pane.detach()
            pane.phase = .failed("reconnecting")
        }
        connection.panes.removeAll()
        let oldClient = connection.client
        connection.client = nil
        oldClient?.disconnect()
        connection.reconnectDelay = .seconds(1)
        connect(connection)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(connections.map(\.config)) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Connection lifecycle

    private func connect(_ connection: Connection) {
        guard connections.contains(where: { $0 === connection }) else { return }
        connection.phase = .connecting
        connection.reconnectTask = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            let client = RemoteHostClient()
            self.wire(client: client, to: connection)
            connection.client = client
            let stateGeneration = connection.stateGeneration
            do {
                let state = try await client.connect(
                    host: connection.config.host,
                    port: connection.config.port,
                    token: connection.config.token,
                    clientName: Host.current().localizedName ?? "shepherd"
                )
                guard !Task.isCancelled,
                      connection.client === client,
                      self.connections.contains(where: { $0 === connection }) else {
                    client.disconnect()
                    return
                }
                if connection.stateGeneration == stateGeneration {
                    connection.state = state
                }
                connection.phase = .connected
                connection.reconnectDelay = .seconds(1)
            } catch {
                if connection.client === client {
                    connection.client = nil
                }
                client.disconnect()
                guard !Task.isCancelled else { return }
                connection.phase = .failed(String(describing: error))
                self.scheduleReconnect(connection)
            }
        }
    }

    private func wire(client: RemoteHostClient, to connection: Connection) {
        let clientID = ObjectIdentifier(client)
        client.onStateChanged = { [weak connection] state in
            guard let connection,
                  connection.client.map(ObjectIdentifier.init) == clientID else { return }
            let liveSessionIDs = Set(state.tabs.flatMap { $0.layout.leaves.compactMap(\.sessionID) })
            for sessionID in Array(connection.panes.keys) where !liveSessionIDs.contains(sessionID) {
                connection.panes.removeValue(forKey: sessionID)?.detach()
            }
            connection.stateGeneration &+= 1
            connection.state = state
        }
        client.onOutput = { [weak connection] sessionID, data in
            guard let connection,
                  connection.client.map(ObjectIdentifier.init) == clientID else { return }
            connection.panes[sessionID]?.receive(data)
        }
        client.onSessionExited = { [weak connection] sessionID, code in
            guard let connection,
                  connection.client.map(ObjectIdentifier.init) == clientID,
                  let pane = connection.panes.removeValue(forKey: sessionID) else { return }
            pane.phase = .exited(code)
        }
        client.onDisconnected = { [weak self, weak connection] reason in
            guard let self, let connection,
                  connection.client.map(ObjectIdentifier.init) == clientID else { return }
            if case .connecting = connection.phase { return }
            connection.client = nil
            for pane in connection.panes.values {
                pane.phase = .failed("disconnected: \(reason)")
            }
            connection.panes.removeAll()
            if self.connections.contains(where: { $0 === connection }) {
                connection.phase = .failed(reason)
                self.scheduleReconnect(connection)
            }
        }
    }

    private func scheduleReconnect(_ connection: Connection) {
        let delay = connection.reconnectDelay
        // Exponential backoff, capped at 30s. Reset on successful connect.
        connection.reconnectDelay = min(.seconds(30), delay * 2)
        connection.reconnectTask = Task { [weak self, weak connection] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let connection else { return }
            self.connect(connection)
        }
    }

    // MARK: - Remote mutations

    /// List a directory on a host (remote pickers). Empty path = host home.
    func listDir(hostID: UUID, path: String) async throws -> RemoteHostClient.DirListing {
        guard let client = connections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.listDir(path: path)
    }

    /// The host's pi model ids and default (remote model picker).
    func listModels(hostID: UUID) async throws -> (models: [String], defaultModel: String?) {
        guard let client = connections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.listModels()
    }

    /// Create a space on a host from a host-side directory path.
    func addSpace(hostID: UUID, path: String) async throws -> SpaceID {
        guard let client = connections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.addSpace(path: path)
    }

    /// Create an agent on a host; it appears in the sidebar via state push.
    @discardableResult
    func createAgent(
        hostID: UUID,
        spaceID: SpaceID,
        cwd: String?,
        model: String?,
        thinking: ThinkingLevel?,
        initialPrompt: String?
    ) async throws -> AgentID {
        guard let client = connections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.createAgent(
            spaceID: spaceID,
            cwd: cwd,
            model: model,
            thinking: thinking,
            initialPrompt: initialPrompt
        )
    }

    // MARK: - Remote panes

    func updateAppearance(_ terminal: ShepherdTheme.Terminal) {
        for pane in connections.flatMap({ $0.panes.values }) {
            pane.terminal.updateAppearance(terminal)
        }
    }

    func updateSurfaceConfiguration() {
        for pane in connections.flatMap({ $0.panes.values }) {
            pane.terminal.updateConfiguration(
                fontSize: AppSettings.shared.terminalFontSize,
                fontFamily: AppSettings.shared.resolvedTerminalFontFamily,
                extraUnbinds: KeybindingsStore.shared.customGhosttyUnbinds
            )
        }
    }

    func openPane(hostID: UUID, agentID: AgentID, relativeTo paneID: PaneID, axis: SplitAxis) async throws -> PaneID {
        guard let client = connections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        return try await client.openPane(agentID: agentID, relativeTo: paneID, axis: axis)
    }

    func closePane(hostID: UUID, agentID: AgentID, paneID: PaneID) async throws {
        guard let client = connections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        try await client.closePane(agentID: agentID, paneID: paneID)
    }

    func resizePaneSplit(hostID: UUID, agentID: AgentID, split: PaneNode, ratio: Double) async throws {
        guard let client = connections.first(where: { $0.id == hostID })?.client else {
            throw RemoteHostClientError.disconnected
        }
        try await client.resizePaneSplit(agentID: agentID, split: split, ratio: ratio)
    }

    /// The pane session for a remote agent's terminal, creating and attaching
    /// on first use. Returns nil while the host is not connected.
    func paneSession(
        connection: Connection,
        sessionID: SessionID
    ) -> RemotePaneSession? {
        guard let client = connection.client else { return nil }
        if let existing = connection.panes[sessionID] {
            return existing
        }
        let pane = RemotePaneSession(sessionID: sessionID, client: client)
        connection.panes[sessionID] = pane
        pane.start()
        return pane
    }

    /// Detach a pane's stream (view went away; the host session keeps running).
    func closePane(connection: Connection, sessionID: SessionID) {
        guard let pane = connection.panes.removeValue(forKey: sessionID) else { return }
        pane.detach()
    }

    func closePanes(connection: Connection, sessionIDs: [SessionID]) {
        for sessionID in sessionIDs {
            closePane(connection: connection, sessionID: sessionID)
        }
    }
}

/// One remote pane's terminal bridge: an AppTerminalModel fed from `output`
/// frames, with input and debounced resize forwarded to the host. The remote
/// analog of TerminalSessionStore.PaneSession, without the spawn/binding
/// machinery — the host owns the session lifecycle.
@MainActor
final class RemotePaneSession: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case live
        case failed(String)
        case exited(Int32?)
    }

    let sessionID: SessionID
    let terminal: AppTerminalModel
    @Published var phase: Phase = .connecting

    private weak var client: RemoteHostClient?
    private var lastCols = 80
    private var lastRows = 24
    private var hasReportedGrid = false
    private var attachStarted = false
    /// Debounce: forward a settled grid, never per-drag-frame sizes.
    /// Per-frame reports SIGWINCH-spam the child and fill scrollback with
    /// duplicated prompts.
    private var resizeDebounce: Task<Void, Never>?
    private static let resizeSettleMs = 120

    init(sessionID: SessionID, client: RemoteHostClient) {
        self.sessionID = sessionID
        self.client = client
        self.terminal = AppTerminalModel(
            fontSize: AppSettings.shared.terminalFontSize,
            fontFamily: AppSettings.shared.resolvedTerminalFontFamily,
            terminal: ThemeManager.shared.current.terminal,
            extraUnbinds: KeybindingsStore.shared.customGhosttyUnbinds,
            acceptsFileDrops: false
        )
        terminal.onInput = { [weak self] data in
            guard let self, let client = self.client else { return }
            client.write(sessionID: self.sessionID, data: data)
        }
        terminal.onResize = { [weak self] cols, rows in
            guard let self else { return }
            self.lastCols = cols
            self.lastRows = rows
            self.hasReportedGrid = true
            if !self.attachStarted {
                // First layout before attach: attach at the real grid.
                self.attachIfNeeded()
                return
            }
            // Attach already in flight or done — sync the PTY (debounced).
            // This must run for the FIRST report too: the grace-period
            // fallback attaches at 80×24, and without this resize the host
            // PTY stayed 80×24 under a full-size surface — pi's absolute
            // cursor addressing scattered across the bigger grid (the
            // garbled-overlap bug).
            self.scheduleResize()
        }
        // Selecting a local thread unmounts this pane's view (remote panes
        // are conditional, unlike the permanently mounted local layouts);
        // returning creates a fresh, blank ghostty surface. Mirror the local
        // resync: release the replacement, then re-attach so the host
        // re-sends its screen snapshot into the new surface.
        terminal.onSurfaceReplaced = { [weak self] generation in
            guard let self else { return }
            _ = self.terminal.replaceWithReplay(Data(), generation: generation)
            guard self.attachStarted, let client = self.client else { return }
            if case .live = self.phase {
                client.detach(sessionID: self.sessionID)
                Task { [weak self] in
                    guard let self, let client = self.client else { return }
                    // detach and attach are queued in order on the client's
                    // serial queue, so the host re-registers and snapshots
                    // after dropping the old attachment.
                    try? await client.attach(
                        sessionID: self.sessionID,
                        cols: self.lastCols,
                        rows: self.lastRows
                    )
                }
            }
        }
    }

    private func scheduleResize() {
        resizeDebounce?.cancel()
        resizeDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.resizeSettleMs))
            guard !Task.isCancelled, let self, let client = self.client else { return }
            client.resize(sessionID: self.sessionID, cols: self.lastCols, rows: self.lastRows)
        }
    }

    /// Attach once a grid is known; also called with a grace fallback so a
    /// surface that never lays out still attaches at 80×24.
    func start() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: TerminalSessionStore.gridWaitNanoseconds)
            self?.attachIfNeeded()
        }
    }

    private func attachIfNeeded() {
        guard !attachStarted, let client else { return }
        attachStarted = true
        let attachCols = lastCols
        let attachRows = lastRows
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            do {
                try await client.attach(sessionID: self.sessionID, cols: attachCols, rows: attachRows)
                if case .connecting = self.phase {
                    self.phase = .live
                }
                // The surface may have laid out (or grown) while the attach
                // round-tripped; converge the PTY on the real grid.
                if self.lastCols != attachCols || self.lastRows != attachRows {
                    self.scheduleResize()
                }
            } catch {
                self.phase = .failed(String(describing: error))
            }
        }
    }

    func receive(_ data: Data) {
        terminal.feed(data)
    }

    func detach() {
        resizeDebounce?.cancel()
        client?.detach(sessionID: sessionID)
    }
}
