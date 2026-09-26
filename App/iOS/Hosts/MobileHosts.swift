import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One host the phone knows, and its live connection. Views observe the record, the phase, the
/// pushed state and `session`; the transport under them is unobserved.
@MainActor
@Observable
final class MobileHost: Identifiable {
    let id: UUID
    fileprivate(set) var record: RemoteHostRecord
    fileprivate(set) var phase: RemoteHostPhase = .disconnected
    /// The host's last pushed state. It stays after a disconnect, so lists show the last known
    /// agents dimmed until the host is back.
    fileprivate(set) var state = ShepherdState()
    /// A new value for every connection that finishes its handshake; nil while none is live.
    /// Work tied to one connection (a thread's poll loop) keys on it.
    fileprivate(set) var session: UUID?
    fileprivate(set) var capabilities: Set<String> = []
    /// When this device's connection to it last ended (saved apart from the record).
    fileprivate(set) var lastSeen: Date?

    @ObservationIgnored fileprivate(set) var client: RemoteHostClient?
    @ObservationIgnored fileprivate var attempt = UUID()
    @ObservationIgnored fileprivate var connectTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var retryTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var backoff = RemoteReconnectBackoff()
    @ObservationIgnored fileprivate var stateRevision = 0
    /// The host pushed a change to a design this device watches (`designs.v1`): its files'
    /// revision, its comments' revision, or both. Set by the designs' store.
    @ObservationIgnored var onDesignChanged: ((DesignID, UInt64?, UInt64?) -> Void)?

    init(record: RemoteHostRecord) {
        id = record.id
        self.record = record
    }

    var name: String { record.name }

    /// The client, while connected.
    var connectedClient: RemoteHostClient? { phase == .connected ? client : nil }

    func supports(_ capability: String) -> Bool { capabilities.contains(capability) }

    func agent(_ id: AgentID) -> Agent? { state.agents.first { $0.id == id } }

    fileprivate func set(_ phase: RemoteHostPhase) {
        if self.phase != phase { self.phase = phase }
    }

    fileprivate func adopt(_ state: ShepherdState) {
        if self.state != state { self.state = state }
    }
}

/// Every host the phone knows, each with its own `RemoteHostClient`, connected while the app is
/// in the foreground and reconnecting with backoff (1, 2, 4… up to 30 s) when one drops or cannot
/// be reached. A host that refuses the token or speaks another protocol waits for Edit or Retry.
/// Records are saved in preferences (`shepherd.ios.hosts`), tokens through `HostTokens` (the
/// Keychain). The first client's single saved host migrates on first launch.
@MainActor
@Observable
final class MobileHosts {
    static let recordsKey = "shepherd.ios.hosts"
    /// The first client's one host (`{name, host, port}`).
    static let legacyKey = "shepherd.ios.host"
    /// The migrated host whose token has not moved yet: the Keychain refuses reads while the
    /// device is locked, and the app can launch then, so the move is retried until it lands.
    static let legacyTokenKey = "shepherd.ios.host.pendingToken"
    /// When each host's connection last ended, by id (seconds since 1970): "Last seen" for a host
    /// the phone cannot reach now. Apart from the records, which hold only what the user entered.
    static let lastSeenKey = "shepherd.ios.hosts.lastSeen"

    private(set) var hosts: [MobileHost] = []

    /// Where the phone keeps its preferences: the hosts' records here, and Settings' own
    /// (`SettingsStore`).
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let tokens: HostTokens
    @ObservationIgnored private let clientName: String
    @ObservationIgnored private let makeClient: () -> RemoteHostClient
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private(set) var foreground = false

    init(defaults: UserDefaults = .standard, tokens: HostTokens = .keychain, clientName: String = "Shepherd iOS",
         makeClient: @escaping () -> RemoteHostClient = { RemoteHostClient() },
         pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.defaults = defaults
        self.tokens = tokens
        self.clientName = clientName
        self.makeClient = makeClient
        self.pause = pause
        var records = RemoteHostRecord.decodeList(defaults.data(forKey: Self.recordsKey))
        if records.isEmpty, let legacy = RemoteHostRecord.migrating(legacy: defaults.data(forKey: Self.legacyKey), id: UUID()) {
            records = [legacy]
            defaults.set(RemoteHostRecord.encodeList(records), forKey: Self.recordsKey)
            defaults.set(legacy.id.uuidString, forKey: Self.legacyTokenKey)
        }
        defaults.removeObject(forKey: Self.legacyKey)
        hosts = records.map(MobileHost.init)
        let seen = defaults.dictionary(forKey: Self.lastSeenKey) as? [String: Double] ?? [:]
        for host in hosts { host.lastSeen = seen[host.id.uuidString].map(Date.init(timeIntervalSince1970:)) }
        moveLegacyToken()
    }

    /// Moves the first client's token to its migrated host. A read or save that fails (a locked
    /// device) leaves it pending for the next foreground; a missing token ends the move.
    private func moveLegacyToken() {
        guard let pending = defaults.string(forKey: Self.legacyTokenKey) else { return }
        guard let id = UUID(uuidString: pending), host(id) != nil else {
            defaults.removeObject(forKey: Self.legacyTokenKey)
            return
        }
        do {
            if let token = try tokens.readLegacy(), !token.isEmpty, try tokens.read(id) == nil {
                try tokens.save(token, id)
            }
            try? tokens.removeLegacy()
            defaults.removeObject(forKey: Self.legacyTokenKey)
        } catch {
            return
        }
    }

    // MARK: Reading

    func host(_ id: UUID) -> MobileHost? { hosts.first { $0.id == id } }

    func agent(_ ref: AgentRef) -> Agent? { host(ref.host)?.agent(ref.agent) }

    /// The saved token, for a form editing the host.
    func token(for id: UUID) throws -> String? { try tokens.read(id) }

    // MARK: Editing

    /// Adds a host (its entry must carry a token) and connects to it while in the foreground.
    @discardableResult
    func add(_ entry: RemoteHostEntry) throws -> UUID {
        guard let token = entry.token else { throw RemoteHostEntry.Problem.token }
        let record = RemoteHostRecord(name: entry.name, address: entry.address, port: entry.port)
        try tokens.save(token, record.id)
        let host = MobileHost(record: record)
        hosts.append(host)
        persist()
        connect(host)
        return record.id
    }

    /// Changes a host's name, address or port, and its token when the entry carries one. A new
    /// address, port or token reconnects; a new name alone does not.
    func edit(_ id: UUID, _ entry: RemoteHostEntry) throws {
        guard let host = host(id) else { return }
        if let token = entry.token { try tokens.save(token, id) }
        var record = host.record
        record.name = entry.name
        let moved = record.address != entry.address || record.port != entry.port || entry.token != nil
        record.address = entry.address
        record.port = entry.port
        if host.record != record { host.record = record }
        persist()
        if moved { retry(id) }
    }

    /// Disconnects, deletes the token, and drops the host with its last known state.
    func forget(_ id: UUID) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        try tokens.remove(id)
        if defaults.string(forKey: Self.legacyTokenKey) == id.uuidString {
            try? tokens.removeLegacy()
            defaults.removeObject(forKey: Self.legacyTokenKey)
        }
        let host = hosts.remove(at: index)
        disconnect(host)
        persist()
        persistLastSeen()
    }

    private func persist() {
        defaults.set(RemoteHostRecord.encodeList(hosts.map(\.record)), forKey: Self.recordsKey)
    }

    private func persistLastSeen() {
        let seen = Dictionary(uniqueKeysWithValues: hosts.compactMap { host in
            host.lastSeen.map { (host.id.uuidString, $0.timeIntervalSince1970) }
        })
        defaults.set(seen, forKey: Self.lastSeenKey)
    }

    // MARK: Connections

    /// The app came to the foreground (connect every host) or went to the background (drop
    /// every socket: iOS would suspend them anyway, and the agents keep running on the host).
    func setForeground(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
        if active { moveLegacyToken() }
        for host in hosts {
            if active { retry(host.id) } else { disconnect(host) }
        }
    }

    /// Reconnects now, with the backoff reset.
    func retry(_ id: UUID) {
        guard let host = host(id) else { return }
        disconnect(host)
        host.backoff.reset()
        connect(host)
    }

    func retryAll() {
        for host in hosts where !host.phase.isConnected { retry(host.id) }
    }

    /// Drops the host's connection and any pending retry; it stays disconnected until `retry`.
    func disconnect(_ id: UUID) {
        if let host = host(id) { disconnect(host) }
    }

    private func disconnect(_ host: MobileHost) {
        host.attempt = UUID()
        host.connectTask?.cancel()
        host.connectTask = nil
        host.retryTask?.cancel()
        host.retryTask = nil
        let client = host.client
        host.client = nil
        client?.disconnect()
        if host.session != nil { host.session = nil }
        // A connection ending (it dropped, or the app went to the background) is when the host
        // was last seen.
        if host.phase == .connected {
            host.lastSeen = Date()
            persistLastSeen()
        }
        host.set(.disconnected)
    }

    private func connect(_ host: MobileHost) {
        guard foreground, hosts.contains(where: { $0 === host }) else { return }
        let token: String
        do {
            guard let saved = try tokens.read(host.id), !saved.isEmpty else {
                host.set(.failed(RemoteHostFailure(kind: .tokenMissing, detail: "no token saved")))
                return
            }
            token = saved
        } catch {
            host.set(.failed(RemoteHostFailure(kind: .tokenUnreadable, detail: error.localizedDescription)))
            return
        }
        let attempt = UUID()
        host.attempt = attempt
        let client = makeClient()
        host.client = client
        host.set(.connecting)
        let revision = host.stateRevision
        let record = host.record
        // The client calls back on the main queue.
        client.onStateChanged = { [weak host] state in
            MainActor.assumeIsolated {
                guard let host, host.attempt == attempt else { return }
                host.stateRevision &+= 1
                host.adopt(state)
            }
        }
        // A host turning an experiment on or off (the Design tool) says so without reconnecting.
        client.onCapabilitiesChanged = { [weak host] capabilities in
            MainActor.assumeIsolated {
                guard let host, host.attempt == attempt, host.phase == .connected, host.capabilities != capabilities else { return }
                host.capabilities = capabilities
            }
        }
        client.onDesignChanged = { [weak host] design, revision, comments in
            MainActor.assumeIsolated {
                guard let host, host.attempt == attempt else { return }
                host.onDesignChanged?(design, revision, comments)
            }
        }
        client.onDisconnected = { [weak self, weak host] reason in
            MainActor.assumeIsolated {
                guard let self, let host, host.attempt == attempt else { return }
                self.failed(host, RemoteHostFailure(disconnect: reason), attempt: attempt)
            }
        }
        host.connectTask = Task { [weak self, weak host] in
            do {
                let state = try await client.connect(host: record.address, port: record.port, token: token, clientName: self?.clientName ?? "Shepherd iOS")
                guard let host, !Task.isCancelled, host.attempt == attempt else {
                    client.disconnect()
                    return
                }
                // A push can land before the handshake's own fetch resumes here.
                if host.stateRevision == revision { host.adopt(state) }
                if host.capabilities != client.capabilities { host.capabilities = client.capabilities }
                host.session = UUID()
                host.set(.connected)
                host.backoff.reset()
            } catch {
                client.disconnect()
                guard !Task.isCancelled, let self, let host else { return }
                self.failed(host, RemoteHostFailure(error), attempt: attempt)
            }
        }
    }

    private func failed(_ host: MobileHost, _ failure: RemoteHostFailure, attempt: UUID) {
        guard host.attempt == attempt else { return }
        disconnect(host)
        host.set(.failed(failure))
        guard foreground, failure.retries else { return }
        let retryAttempt = host.attempt
        let delay = host.backoff.next()
        let pause = self.pause
        host.retryTask = Task { [weak self, weak host] in
            do { try await pause(delay) } catch { return }
            guard !Task.isCancelled, let self, let host, host.attempt == retryAttempt else { return }
            self.connect(host)
        }
    }
}
