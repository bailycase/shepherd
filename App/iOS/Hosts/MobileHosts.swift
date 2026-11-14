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
    /// Which fleet this device learned the Mac from (`FleetFollowPlan.group`), kept across launches (`MobileHosts.fleetGroupKey`); nil for a
    /// Mac the user added themselves.
    fileprivate(set) var fleetGroup: UUID?
    /// The index in `record.routes` of the route the live connection runs on.
    @ObservationIgnored fileprivate(set) var routeIndex: Int?
    /// Reading the fleet is under way (and, when set, wanted again once it ends).
    @ObservationIgnored fileprivate var following = false
    @ObservationIgnored fileprivate var followAgain = false
    /// Looking at the routes before the one in use.
    @ObservationIgnored fileprivate var recheck: Task<Void, Never>?
    /// Refusals of the token still to be retried: a Mac the fleet just added may not have taken this device in yet.
    @ObservationIgnored fileprivate var tokenGrace = 0

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
    /// Each host's fleet group (`FleetFollowPlan.group`), by id: the Macs this device learned from one fleet, which it keeps in step with it.
    static let fleetGroupKey = "shepherd.ios.hosts.fleetGroup"
    /// The fleet Macs (by their fleet id) the user forgot: they are not added again when the fleet lists them.
    static let fleetIgnoredKey = "shepherd.ios.hosts.fleetIgnored"

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
    static let clientCapabilities = RemoteProtocol.clientCapabilities + [RemoteProtocol.nativeThreadPreviewCapability, RemoteProtocol.fleetFollowCapability]

    /// Where the phone keeps its preferences: the hosts' records here, and Settings' own
    /// (`SettingsStore`).
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let tokens: HostTokens
    @ObservationIgnored private let clientName: String
    @ObservationIgnored private let device: DeviceDescription
    @ObservationIgnored private let makeClient: () -> RemoteHostClient
    /// Asks whether the Mac `host:port` is the one at the other end (its fleet id), without a token.
    @ObservationIgnored private let probe: (String, UInt16) async -> UUID?
    /// The fleet Macs the user forgot, by fleet id.
    @ObservationIgnored private var ignoredFleetIDs: Set<UUID> = []
    /// What each connected host last said its fleet holds (its Macs' fleet ids), by saved id: a Mac that left the fleet says a smaller one.
    @ObservationIgnored private var fleetViews: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private let pause: (Duration) async throws -> Void
    @ObservationIgnored private(set) var foreground = false
    /// Called when a host transitions to `.connected`: PushManager renews, a Browser page takes its ports again.
    @ObservationIgnored var onHostConnected: ((MobileHost) -> Void)?
    /// A host's connection ended (it dropped, the app went to the background, Retry, Forget).
    @ObservationIgnored var onHostDisconnected: ((MobileHost) -> Void)?
    /// The fleet no longer has a Mac and it was dropped (its record and token are gone): the app clears what it kept for it.
    @ObservationIgnored var onFleetLeft: ((UUID) -> Void)?
    /// The app came to the foreground or left it (`setForeground`).
    @ObservationIgnored var onForegroundChanged: ((Bool) -> Void)?
    /// A thread a host watches for this device moved (`native.revisions.v1`): a hint to read
    /// again, never content. One app-level owner (`ThreadRevisionHints`) sets it.
    @ObservationIgnored var onNativeThreadChanged: ((MobileHost, AgentID) -> Void)?

    init(defaults: UserDefaults = .standard, tokens: HostTokens = .keychain, clientName: String = "Shepherd iOS",
         device: DeviceDescription = .phone,
         makeClient: @escaping () -> RemoteHostClient = { RemoteHostClient() },
         pause: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         probe: @escaping (String, UInt16) async -> UUID? = { await RemoteHostClient.fleetProbe(host: $0, port: $1)?.hostID }) {
        self.probe = probe
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
        let groups = defaults.dictionary(forKey: Self.fleetGroupKey) as? [String: String] ?? [:]
        for host in hosts { host.fleetGroup = groups[host.id.uuidString].flatMap(UUID.init(uuidString:)) }
        ignoredFleetIDs = Set((defaults.stringArray(forKey: Self.fleetIgnoredKey) ?? []).compactMap(UUID.init(uuidString:)))
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
        var found = [(fleetID: answered.identity.hostID, name: answered.result.name, address: address, port: port)]
        for member in answered.result.members {
            guard let host = member.host else { continue }
            found.append((member.hostID, member.name, host, member.port))
        }
        var ids: [UUID] = []
        for mac in found {
            ignoredFleetIDs.remove(mac.fleetID)
            if let existing = hosts.first(where: { $0.fleetID == mac.fleetID }) ?? hosts.first(where: { $0.record.address == mac.address && $0.record.port == mac.port }) {
                try tokens.save(identity.token, existing.id)
                existing.fleetID = mac.fleetID
                if foreground { retry(existing.id) }
                ids.append(existing.id)
            } else if let entry = try? RemoteHostEntry(name: mac.name, address: mac.address, port: String(mac.port), token: identity.token) {
                let id = try add(entry)
                host(id)?.fleetID = mac.fleetID
                ids.append(id)
            }
        }
        // The Macs one pairing brought are one fleet, which a later read of it keeps them in step with.
        let group = ids.lazy.compactMap { self.host($0)?.fleetGroup }.first ?? UUID()
        for id in ids { host(id)?.fleetGroup = group }
        persistFleetIDs()
        persistFleetGroups()
        defaults.set(ignoredFleetIDs.map(\.uuidString).sorted(), forKey: Self.fleetIgnoredKey)
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
        let retargeted = record.address != entry.address || record.port != entry.port
        let moved = retargeted || entry.token != nil
        // An address the user typed is the one way to reach it; the fleet lists the others again when it next reads it.
        if retargeted { record.routes = [RemoteHostRoute(host: entry.address, port: entry.port)] }
        if host.record != record { host.record = record }
        persist()
        if retargeted, host.fleetID != nil {
            // Whatever answers there may not be the Mac it was: its id is learned again at the next connection.
            host.fleetID = nil
            persistFleetIDs()
        }
        if moved {
            host.projectBinding = UUID()
            var state = host.state
            state.projects = []
            host.adopt(state)
            retry(id)
        }
    }

    /// Disconnects, deletes the token, and drops the host with its last known state. A Mac of a fleet that the user forgets is not
    /// added again when the fleet lists it.
    func forget(_ id: UUID) throws {
        if let host = host(id), let fleetID = host.fleetID, host.fleetGroup != nil {
            ignoredFleetIDs.insert(fleetID)
            defaults.set(ignoredFleetIDs.map(\.uuidString).sorted(), forKey: Self.fleetIgnoredKey)
        }
        try drop(id)
    }

    private func drop(_ id: UUID) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        try tokens.remove(id)
        let host = hosts.remove(at: index)
        disconnect(host)
        fleetViews[id] = nil
        persist()
        persistLastSeen()
        persistFleetIDs()
        persistFleetGroups()
    }

    private func persistFleetGroups() {
        defaults.set(Dictionary(uniqueKeysWithValues: hosts.compactMap { host in host.fleetGroup.map { (host.id.uuidString, $0.uuidString) } }),
                     forKey: Self.fleetGroupKey)
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

    // MARK: The fleet

    /// This device's own token, nil while there is no identity yet or the Keychain can't be read.
    private func deviceToken() -> String? {
        guard let saved = try? tokens.readDevice(), let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: Data(saved.utf8)) else { return nil }
        return identity.token
    }

    /// Keeps the saved Macs in step with the fleet the connected host `host` is in (`RemoteProtocol.fleetFollowCapability`): reads its Macs
    /// and their routes, and applies what changed. Runs when a host connects and again when it says the fleet changed; a host that
    /// doesn't offer it, or that this device reaches with a token it wasn't given by a fleet, is left as it is.
    private func follow(_ host: MobileHost) {
        guard host.supports(RemoteProtocol.fleetFollowCapability), host.supports(RemoteProtocol.fleetViewCapability),
              let client = host.connectedClient, let token = deviceToken(), (try? tokens.read(host.id)) == token else { return }
        guard !host.following else {
            host.followAgain = true
            return
        }
        host.following = true
        let attempt = host.attempt
        Task { [weak self, weak host] in
            defer { host?.following = false }
            while let self, let host, host.attempt == attempt {
                host.followAgain = false
                // A Mac with Fleet off, or one that fails this read, changes nothing; the next connection or push reads again.
                if let members = try? await client.fleetRead().snapshot.members, host.attempt == attempt { self.reconcile(from: host, members) }
                guard host.followAgain else { return }
            }
        }
    }

    private func reconcile(from source: MobileHost, _ members: [FleetViewMember]) {
        guard let token = deviceToken() else { return }
        let saved = hosts.map {
            FleetFollowSaved(id: $0.id, fleetID: $0.fleetID, name: $0.record.name, routes: $0.record.routes, group: $0.fleetGroup,
                             ownsToken: (try? tokens.read($0.id)) == token)
        }
        // A Mac that hasn't said yet what its fleet holds might hold the bigger half of a split: it is waited for, not removed.
        let awaiting = Set(hosts.filter { $0 !== source && ($0.phase == .connecting || ($0.phase == .connected && $0.supports(RemoteProtocol.fleetFollowCapability) && fleetViews[$0.id] == nil)) }.map(\.id))
        let view = Set(members.map(\.hostID))
        let heard = source.phase == .connected && fleetViews[source.id] != view
        if source.phase == .connected { fleetViews[source.id] = view }
        defer { if heard { refollow(except: source) } }
        guard let plan = FleetFollow.plan(source: source.id, members: members, saved: saved, ignored: ignoredFleetIDs, views: fleetViews, awaiting: awaiting) else { return }
        for id in plan.remove {
            guard (try? drop(id)) != nil else { continue }
            onFleetLeft?(id)
        }
        for change in plan.update {
            guard let host = host(change.id) else { continue }
            let routed = host.record.routes != change.routes
            var record = host.record
            record.name = change.name
            record.routes = change.routes
            if host.record != record { host.record = record }
            host.fleetGroup = change.group
            // A Mac that couldn't be reached by what was saved is tried by what the fleet says now.
            if routed, foreground, !host.phase.isConnected { retry(host.id) }
        }
        for member in plan.add {
            let record = RemoteHostRecord(name: member.name, routes: FleetFollow.routes(of: member))
            guard (try? tokens.save(token, record.id)) != nil else { continue }
            let host = MobileHost(record: record)
            host.fleetID = member.hostID
            host.fleetGroup = plan.group
            host.tokenGrace = 5
            hosts.append(host)
            connect(host)
        }
        source.fleetGroup = plan.group
        persist()
        persistFleetIDs()
        persistFleetGroups()
    }

    /// What a Mac says of its fleet is what the others are weighed against, so each connected one reads it again when one of them says
    /// something new or can't be reached.
    private func refollow(except host: MobileHost) {
        for other in hosts where other !== host && other.phase == .connected { follow(other) }
    }

    /// The network changed (the app's path monitor says so): a host carried by a later route than its first looks at the earlier ones and
    /// moves to the first that answers as the Mac it should be; a host that is down tries again now rather than at the end of its backoff.
    /// Nothing runs while the app is in the background.
    func networkChanged() {
        guard foreground else { return }
        for host in hosts {
            switch host.phase {
            case .connected:
                guard let carried = host.routeIndex, carried > 0, host.recheck == nil else { continue }
                let attempt = host.attempt, expected = host.fleetID, earlier = host.record.routes[..<carried]
                host.recheck = Task { [weak self, weak host] in
                    for route in earlier {
                        guard let answered = await self?.probe(route.host, route.port), expected == nil || answered == expected else { continue }
                        guard let self, let host, !Task.isCancelled, host.attempt == attempt else { return }
                        self.retry(host.id)
                        return
                    }
                    host?.recheck = nil
                }
            case .failed(let failure) where failure.retries:
                retry(host.id)
            case .failed, .disconnected, .connecting:
                break
            }
        }
    }

    // MARK: Connections

    /// The app came to the foreground (connect every host) or went to the background (drop
    /// every socket: iOS would suspend them anyway, and the agents keep running on the host).
    func setForeground(_ active: Bool) {
        guard active != foreground else { return }
        foreground = active
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
        host.recheck?.cancel()
        host.recheck = nil
        host.routeIndex = nil
        fleetViews[host.id] = nil
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

    /// Connects to the first of the host's routes that answers (`RemoteHostRecord.routes`, in order). A refused token or another
    /// protocol fails the same way on every route, so it ends the round; any other failure goes on to the next route.
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
        host.set(.connecting)
        let revision = host.stateRevision
        let record = host.record
        // A Mac of a fleet is asked who it is before the token is sent, so a stale route that now leads to another Mac never gets it.
        let expecting = host.fleetID != nil && token == deviceToken() ? host.fleetID : nil
        host.connectTask = Task { [weak self, weak host] in
            var failure: RemoteHostFailure?
            for (index, route) in record.routes.enumerated() {
                guard let self, let host, !Task.isCancelled, host.attempt == attempt else { return }
                let client = self.makeClient(for: host, attempt: attempt)
                host.client = client
                do {
                    let state = try await client.connect(host: route.host, port: route.port, token: token, clientName: self.clientName,
                                                         capabilities: Self.clientCapabilities, expectingHostID: expecting)
                    guard !Task.isCancelled, host.attempt == attempt else {
                        client.disconnect()
                        return
                    }
                    // A push can land before the handshake's own fetch resumes here.
                    if host.stateRevision == revision { host.adopt(state) }
                    if host.capabilities != client.capabilities { host.capabilities = client.capabilities }
                    host.session = UUID()
                    host.routeIndex = index
                    if let fleetID = client.hostID, host.fleetID != fleetID {
                        host.fleetID = fleetID
                        self.persistFleetIDs()
                    }
                    host.set(.connected)
                    host.backoff.reset()
                    host.tokenGrace = 0
                    self.onHostConnected?(host)
                    self.follow(host)
                    return
                } catch {
                    client.disconnect()
                    guard !Task.isCancelled, host.attempt == attempt else { return }
                    failure = RemoteHostFailure(error)
                    if failure?.retries == false { break }
                }
            }
            guard let self, let host, !Task.isCancelled, let failure else { return }
            self.failed(host, failure, attempt: attempt)
        }
    }

    /// A client for one connection of `host`, with the host's pushes handled for it.
    private func makeClient(for host: MobileHost, attempt: UUID) -> RemoteHostClient {
        let client = makeClient()
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
        client.onFleetViewChanged = { [weak self, weak host] in
            MainActor.assumeIsolated {
                guard let self, let host, host.attempt == attempt, host.phase == .connected else { return }
                self.follow(host)
            }
        }
        client.onDisconnected = { [weak self, weak host] reason in
            MainActor.assumeIsolated {
                guard let self, let host, host.attempt == attempt else { return }
                self.failed(host, RemoteHostFailure(disconnect: reason), attempt: attempt)
            }
        }
        return client
    }

    private func failed(_ host: MobileHost, _ failure: RemoteHostFailure, attempt: UUID) {
        guard host.attempt == attempt else { return }
        let firstFailure = host.backoff.upcoming == host.backoff.initial
        disconnect(host)
        host.set(.failed(failure))
        // Macs that were waiting for this one to say what its fleet holds weigh it as gone.
        if firstFailure { refollow(except: host) }
        // A Mac the fleet just added may not have taken this device in yet: its first refusals are tried again.
        let retried = failure.retries || ((failure.kind == .tokenRefused || failure.kind == .sharedTokenRetired) && host.tokenGrace > 0)
        if !failure.retries && retried { host.tokenGrace -= 1 }
        guard foreground, retried else { return }
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
