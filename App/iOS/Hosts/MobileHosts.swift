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
    /// Membership-only observers (Files retention) need not scan stores on status pushes.
    private(set) var agentIDs: Set<AgentID> = []
    /// A new value for every connection that finishes its handshake; nil while none is live.
    /// Work tied to one connection (a thread's poll loop) keys on it.
    fileprivate(set) var session: UUID?
    /// Retargeting or replacing credentials invalidates Project drafts' cached authority.
    fileprivate(set) var projectBinding = UUID()
    fileprivate(set) var capabilities: Set<String> = []
    /// When this device's connection to it last ended (saved apart from the record).
    fileprivate(set) var lastSeen: Date?
    /// The Mac's fleet host id, as its `helloOk` said, kept across launches (`MobileHosts.fleetIDKey`): how the Fleet screen
    /// finds this pairing among the fleet's Macs while the Mac is away. nil until it has said.
    fileprivate(set) var fleetID: UUID?

    @ObservationIgnored fileprivate(set) var client: RemoteHostClient? {
        didSet { tunnelSlot.hub = client?.tunnels }
    }
    /// The connection's Browser tunnels, for a page's forwarded ports (`BrowserPagePorts`): filled
    /// with each new client, emptied when it goes, so a connection to a held port with no host resets.
    @ObservationIgnored let tunnelSlot = BrowserTunnelHubSlot()
    @ObservationIgnored fileprivate var attempt = UUID()
    @ObservationIgnored fileprivate var connectTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var retryTask: Task<Void, Never>?
    @ObservationIgnored fileprivate var backoff = RemoteReconnectBackoff()
    @ObservationIgnored fileprivate var stateRevision = 0
    /// The host pushed a change to a design this device watches (`designs.v1`): its files'
    /// revision, its comments' revision, or both. Set by `HostDesignLibraries`, which hands it to
    /// the iPhone's and the iPad's designs alike.
    @ObservationIgnored var onDesignChanged: ((DesignID, UInt64?, UInt64?) -> Void)?
    /// The host's design systems changed (`design.systems.v1`). Set by `HostDesignLibraries`.
    @ObservationIgnored var onDesignSystemsChanged: (() -> Void)?
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
        guard self.state != state else { return }
        self.state = state
        let ids = Set(state.agents.map(\.id))
        if agentIDs != ids { agentIDs = ids }
    }
}

// Lives beside the host so the portable checks that compile this file without ShepherdUI
// have it too.
extension MobileHost {
    /// The host's state as thread lists read it. Home, the sidebar, Search, New thread and the
    /// widgets all list from this.
    var threadState: ShepherdState { state }
}

/// Every host the phone knows, each with its own `RemoteHostClient`, connected while the app is
/// in the foreground and reconnecting with backoff (1, 2, 4… up to 30 s) when one drops or cannot
/// be reached. A host that refuses the token or speaks another protocol waits for Edit or Retry.
/// Records are saved in preferences (`shepherd.ios.hosts`), tokens through `HostTokens` (the
/// Keychain). The first client's single saved host migrates on first launch, without a token: there is no token shared by every
/// client any more, so it pairs again with a code (and so does a host whose saved token was that one: the Mac says so, `RemoteHostFailure`).
@MainActor
@Observable
final class MobileHosts {
    static let recordsKey = "shepherd.ios.hosts"
    /// The first client's one host (`{name, host, port}`).
    static let legacyKey = "shepherd.ios.host"
    /// When each host's connection last ended, by id (seconds since 1970): "Last seen" for a host
    /// the phone cannot reach now. Apart from the records, which hold only what the user entered.
    static let lastSeenKey = "shepherd.ios.hosts.lastSeen"
    /// Each host's fleet host id, by id.
    static let fleetIDKey = "shepherd.ios.hosts.fleetID"

    private(set) var hosts: [MobileHost] = []

    /// A pairing link opened from Messages, AirDrop or Files (`shepherd://fleet/join?…`): Add a Mac fills it in, then clears it.
    var incomingPairingLink: String?

    /// What this device tells a Mac of a fleet about itself when it pairs.
    struct DeviceDescription: Equatable {
        var name: String
        var kind: FleetDeviceKind

        static let phone = DeviceDescription(name: "iPhone", kind: .iphone)
    }

    /// The identity this device presents to every Mac it is paired with. Kept in the Keychain.
    struct DeviceIdentity: Codable, Equatable {
        var id: UUID
        var token: String
    }

    /// What the phone tells a host it reads: the client's list, and previews of idle threads
    /// (`nativeThreadPreviewCapability`), so Home reads a thread without starting its pi.
    static let clientCapabilities = RemoteProtocol.clientCapabilities + [RemoteProtocol.nativeThreadPreviewCapability]

    /// Where the phone keeps its preferences: the hosts' records here, and Settings' own
    /// (`SettingsStore`).
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let tokens: HostTokens
    @ObservationIgnored private let clientName: String
    @ObservationIgnored private let device: DeviceDescription
    @ObservationIgnored private let makeClient: () -> RemoteHostClient
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private(set) var foreground = false
    /// Called when a host transitions to `.connected`: PushManager renews, a Browser page takes its ports again.
    @ObservationIgnored var onHostConnected: ((MobileHost) -> Void)?
    /// A host's connection ended (it dropped, the app went to the background, Retry, Forget).
    @ObservationIgnored var onHostDisconnected: ((MobileHost) -> Void)?
    /// The app came to the foreground or left it (`setForeground`).
    @ObservationIgnored var onForegroundChanged: ((Bool) -> Void)?
    /// A thread a host watches for this device moved (`native.revisions.v1`): a hint to read
    /// again, never content. One app-level owner (`ThreadRevisionHints`) sets it.
    @ObservationIgnored var onNativeThreadChanged: ((MobileHost, AgentID) -> Void)?

    init(defaults: UserDefaults = .standard, tokens: HostTokens = .keychain, clientName: String = "Shepherd iOS",
         device: DeviceDescription = .phone,
         makeClient: @escaping () -> RemoteHostClient = { RemoteHostClient() },
         pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.defaults = defaults
        self.tokens = tokens
        self.clientName = clientName
        self.device = device
        self.makeClient = makeClient
        self.pause = pause
        var records = RemoteHostRecord.decodeList(defaults.data(forKey: Self.recordsKey))
        if records.isEmpty, let legacy = RemoteHostRecord.migrating(legacy: defaults.data(forKey: Self.legacyKey), id: UUID()) {
            records = [legacy]
            defaults.set(RemoteHostRecord.encodeList(records), forKey: Self.recordsKey)
        }
        defaults.removeObject(forKey: Self.legacyKey)
        hosts = records.map(MobileHost.init)
        let seen = defaults.dictionary(forKey: Self.lastSeenKey) as? [String: Double] ?? [:]
        for host in hosts { host.lastSeen = seen[host.id.uuidString].map(Date.init(timeIntervalSince1970:)) }
        let fleetIDs = defaults.dictionary(forKey: Self.fleetIDKey) as? [String: String] ?? [:]
        for host in hosts { host.fleetID = fleetIDs[host.id.uuidString].flatMap(UUID.init(uuidString:)) }
    }

    // MARK: Reading

    func host(_ id: UUID) -> MobileHost? { hosts.first { $0.id == id } }

    func agent(_ ref: AgentRef) -> Agent? { host(ref.host)?.agent(ref.agent) }

    /// The saved token, for a form editing the host.
    func token(for id: UUID) throws -> String? { try tokens.read(id) }

    // MARK: Pairing

    /// This device's identity: made and saved on first use, then the same for every Mac. `renew` makes a
    /// new one (the old one was revoked).
    func deviceIdentity(renew: Bool = false) throws -> DeviceIdentity {
        if !renew, let saved = try tokens.readDevice(), let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: Data(saved.utf8)) {
            return identity
        }
        let identity = DeviceIdentity(id: UUID(), token: FleetProtocol.makeToken())
        try tokens.saveDevice(String(decoding: try JSONEncoder().encode(identity), as: UTF8.self))
        return identity
    }

    private func introduction(_ identity: DeviceIdentity) -> FleetDeviceIntroduction {
        FleetDeviceIntroduction(deviceID: identity.id, name: device.name, kind: device.kind, tokenHash: FleetProtocol.hash(identity.token))
    }

    /// Pairs with the Mac at `address`:`port` using the code it shows (Add a device), then adds it and every
    /// other Mac of its fleet, each with this device's own token. `expecting` is the Mac's id hash when a QR
    /// named it; `expectingID` is the Mac's id when a pairing link named it, checked before the code is sent. Returns the ids of the hosts
    /// added or updated. Nothing but the code is typed.
    @discardableResult
    func pair(address: String, port: UInt16, code: String, expecting: String? = nil, expectingID: UUID? = nil) async throws -> [UUID] {
        var identity = try deviceIdentity()
        func attempt() async throws -> (result: FleetDevicesResult, identity: RemoteHostClient.FleetPeerIdentity) {
            try await RemoteHostClient.fleetPairDevice(host: address, port: port, code: code, device: introduction(identity), expecting: expectingID)
        }
        var answered: (result: FleetDevicesResult, identity: RemoteHostClient.FleetPeerIdentity)
        do {
            answered = try await attempt()
        } catch RemoteHostClientError.rejected(FleetProtocol.Code.deviceRevoked, _) {
            // The Mac removed this device's identity: it pairs again as a new one, with the same code.
            identity = try deviceIdentity(renew: true)
            answered = try await attempt()
        }
        if let expecting, FleetProtocol.advertisedIDHash(answered.identity.hostID) != expecting {
            // The QR named another Mac than the one that answered. Its code was spent, so say so.
            throw RemoteHostClientError.rejected(code: FleetProtocol.Code.wrongHost, message: "Another Mac answered at that address.")
        }
        var found = [(name: answered.result.name, address: address, port: port)]
        for member in answered.result.members {
            guard let host = member.host else { continue }
            found.append((member.name, host, member.port))
        }
        var ids: [UUID] = []
        for mac in found {
            if let existing = hosts.first(where: { $0.record.address == mac.address && $0.record.port == mac.port }) {
                try tokens.save(identity.token, existing.id)
                if foreground { retry(existing.id) }
                ids.append(existing.id)
            } else if let entry = try? RemoteHostEntry(name: mac.name, address: mac.address, port: String(mac.port), token: identity.token) {
                let id = try add(entry)
                ids.append(id)
            }
        }
        return ids
    }

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
        if moved {
            host.projectBinding = UUID()
            var state = host.state
            state.projects = []
            host.adopt(state)
            retry(id)
        }
    }

    /// Disconnects, deletes the token, and drops the host with its last known state.
    func forget(_ id: UUID) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        try tokens.remove(id)
        let host = hosts.remove(at: index)
        disconnect(host)
        persist()
        persistLastSeen()
        persistFleetIDs()
    }

    private func persistFleetIDs() {
        defaults.set(Dictionary(uniqueKeysWithValues: hosts.compactMap { host in host.fleetID.map { (host.id.uuidString, $0.uuidString) } }),
                     forKey: Self.fleetIDKey)
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
        onForegroundChanged?(active)
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
        onHostDisconnected?(host)
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
        client.onNativeThreadChanged = { [weak self, weak host] agentID in
            MainActor.assumeIsolated {
                guard let self, let host, host.attempt == attempt else { return }
                self.onNativeThreadChanged?(host, agentID)
            }
        }
        client.onDesignChanged = { [weak host] design, revision, comments in
            MainActor.assumeIsolated {
                guard let host, host.attempt == attempt else { return }
                host.onDesignChanged?(design, revision, comments)
            }
        }
        client.onDesignSystemsChanged = { [weak host] in
            MainActor.assumeIsolated {
                guard let host, host.attempt == attempt else { return }
                host.onDesignSystemsChanged?()
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
                let state = try await client.connect(host: record.address, port: record.port, token: token, clientName: self?.clientName ?? "Shepherd iOS",
                                                     capabilities: Self.clientCapabilities)
                guard let host, !Task.isCancelled, host.attempt == attempt else {
                    client.disconnect()
                    return
                }
                // A push can land before the handshake's own fetch resumes here.
                if host.stateRevision == revision { host.adopt(state) }
                if host.capabilities != client.capabilities { host.capabilities = client.capabilities }
                host.session = UUID()
                if let fleetID = client.hostID, host.fleetID != fleetID {
                    host.fleetID = fleetID
                    self?.persistFleetIDs()
                }
                host.set(.connected)
                host.backoff.reset()
                self?.onHostConnected?(host)
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
