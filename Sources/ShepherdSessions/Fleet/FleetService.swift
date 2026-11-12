import Foundation
import ShepherdProtocol
import ShepherdRemote

/// How the server knows the connection a fleet request arrived on.
struct FleetCaller: Sendable {
    /// The connection (its fd), so a code window opened on it closes with it.
    var connection: Int32
    /// This Mac's own app, on `host.sock`.
    var isLocal: Bool
    /// It said `hello` and passed.
    var authenticated: Bool
    /// It authenticated with a peer's token: that Mac.
    var peerHostID: UUID?
    /// Where the connection came from, as text.
    var observedHost: String?
    /// It authenticated with a device's own token: that device (`FleetDevices`).
    var deviceID: UUID?
    /// What the client called itself in `hello`.
    var clientName: String?

    /// What it may do in the fleet, by how it authenticated.
    var access: FleetAccess { isLocal ? .local : peerHostID != nil ? .member : deviceID != nil ? .device : .shared }

    /// Authenticated with the shared remote token: a legacy Mac or a phone.
    var viaSharedToken: Bool { authenticated && access == .shared }
}

/// The host's part of a fleet: who this Mac is, which Macs it is paired with, a link to each, and
/// the code window while it is joining. Runs only in the host, only while Settings ▸ Experiments ▸
/// Fleet is on. Every piece of state belongs to the server queue: requests and callbacks hop onto
/// it, and nothing waits on it (docs/rules.md, Server concurrency).
///
/// Slice 1 holds links and pairs Macs; nothing syncs or dispatches over them yet.
///
/// The service exists whenever the host runs, but **membership** (links, pairing Macs, Join a fleet,
/// the peer tokens) is on only while Fleet is. Client devices don't need membership: with it off the
/// service still advertises while the listener is open, takes devices by code, keeps `devices.json`
/// and answers the app's device actions, so a phone pairs with a Fleet-off Mac the same way.
final class FleetService: @unchecked Sendable {
    /// The server queue.
    private let queue: DispatchQueue
    private let directory: URL
    let identity: FleetIdentity
    /// Settings and content the Macs hold the same (`fleet.sync.v1`).
    let syncEngine: FleetSync
    private var name: String
    private let build: String?
    private let discovery: FleetDiscovery?
    private let clock: @Sendable () -> Date

    /// Server queue: something the app draws changed.
    var onChange: (() -> Void)?
    /// Server queue: `hostID` left the fleet, so any connection that authenticated as it must end.
    var onPeerRemoved: ((UUID) -> Void)?
    /// Server queue: a device was revoked (here or on another Mac), so any connection of it must end.
    var onDeviceRevoked: ((UUID) -> Void)?
    /// Server queue: the shared token was retired, so the connections that used it must end.
    var onSharedTokenRetired: (() -> Void)?

    private var peers: FleetPeers
    /// Pressure samples and readiness reports: this Mac's and each peer's (`FleetPressure`).
    let pressure: FleetPressure
    /// The content index of this Mac's repositories and the manifests the Macs hold of each other (`fleet.snapshot.v1`).
    let index: FleetIndexService
    private var devices: FleetDevices
    private var join: (window: FleetJoinWindow, owner: Int32)?
    /// The code window of Add a device: the same kind of window as `join`, shown on the Mac that takes the device.
    private var deviceCode: (window: FleetJoinWindow, owner: Int32)?
    /// The connections each device has open now (their fds).
    private var deviceConnections: [UUID: Set<Int32>] = [:]
    private var listenerPort: UInt16?
    private var links: [UUID: Link] = [:]
    private var brokering = false
    private var stopped = false
    /// Settings ▸ Experiments ▸ Fleet is on: this host holds links and pairs Macs.
    private(set) var membership: Bool

    /// A link answers a quiet peer this often, so a connection that died silently (a sleeping
    /// Mac, a dropped Wi-Fi) is noticed and made again.
    static let keepAliveInterval: Duration = .seconds(30)
    /// Introductions wait this long for the links they go over.
    static let introductionPatience: Duration = .seconds(15)
    /// Unauthenticated fleet requests one connection may send.
    static let unauthenticatedRequestLimit = 12

    private final class Link {
        let hostID: UUID
        var client: RemoteHostClient?
        var phase: FleetPeerStatus.Link = .connecting
        var lastSeen: Double?
        var task: Task<Void, Never>?

        init(hostID: UUID) { self.hostID = hostID }
    }

    init(queue: DispatchQueue, directory: URL, name: String, build: String?, advertises: Bool = true, membership: Bool = true,
         clock: @escaping @Sendable () -> Date = Date.init, pressure: FleetPressure? = nil) throws {
        self.queue = queue
        self.membership = membership
        self.directory = directory
        self.name = name
        self.build = build
        self.clock = clock
        identity = try FleetIdentity.loadOrCreate(in: directory, now: clock())
        peers = try FleetPeers.load(from: directory)
        devices = try FleetDevices.load(from: directory)
        discovery = advertises ? FleetDiscovery() : nil
        self.pressure = pressure ?? FleetPressure(queue: queue, clock: clock)
        index = FleetIndexService(queue: queue, directory: directory.appendingPathComponent("index", isDirectory: true), clock: clock)
        syncEngine = try FleetSync(queue: queue, directory: directory.appendingPathComponent("store", isDirectory: true),
                             mac: identity.hostID, name: { name }, clock: clock)
        syncEngine.onChange = { [weak self] in self?.changed() }
        index.onChange = { [weak self] in self?.onChange?() }
        self.pressure.linkConnected = { [weak self] in self?.links.values.contains { $0.phase == .connected } == true }
        self.pressure.pushTargets = { [weak self] in self?.links.values.compactMap { $0.phase == .connected ? $0.client : nil } ?? [] }
    }

    var hostID: UUID { identity.hostID }

    private var nowMilliseconds: Double { (clock().timeIntervalSince1970 * 1000).rounded() }

    // MARK: - Lifecycle (server queue)

    /// Opens a link to every Mac this host is paired with.
    func start() {
        if membership {
            syncEngine.start()
            for record in peers.members where record.isLinkable { startLink(record.hostID) }
        }
        advertise()
        changed()
    }

    /// Fleet was switched on or off. Off ends the links and the Join window and keeps the pairings and
    /// the devices; on opens the links again. Advertising and devices go on either way.
    func setMembership(_ on: Bool) {
        guard on != membership else { return }
        membership = on
        if on {
            syncEngine.start()
            for record in peers.members where record.isLinkable { startLink(record.hostID) }
        } else {
            join = nil
            for id in Array(links.keys) { stopLink(id) }
            // No peer to sample for, and no Fleet page to show.
            pressure.reset()
            syncEngine.stop()
        }
        updateIndexing()
        changed()
    }

    /// Ends every link, the advertisement and the code window. Saved state stays.
    func stop() {
        stopped = true
        index.stop()
        join = nil
        deviceCode = nil
        for id in Array(links.keys) { stopLink(id) }
        pressure.stop()
        syncEngine.stop()
        discovery?.stop()
    }

    /// The host's listener opened on `port`, or closed (nil).
    func listenerChanged(_ port: UInt16?) {
        guard port != listenerPort else { return }
        listenerPort = port
        advertise()
        changed()
    }

    private func advertise() {
        guard let discovery else { return }
        if let listenerPort, !stopped {
            discovery.advertise(name: name, hostID: identity.hostID, build: build, port: listenerPort)
        } else {
            discovery.stop()
        }
    }

    private func changed() {
        updateIndexing()
        onChange?()
    }

    /// The content index reads repositories only while Fleet is on and a Mac is paired: nobody else would use it.
    private func updateIndexing() {
        index.setActive(membership && !stopped && !peers.members.isEmpty)
    }

    /// A connection of the server closed.
    func connectionClosed(_ connection: Int32) {
        pressure.connectionClosed(connection)
        if join?.owner == connection {
            join = nil
            changed()
        }
        if deviceCode?.owner == connection {
            deviceCode = nil
            changed()
        }
        for (deviceID, fds) in deviceConnections where fds.contains(connection) {
            deviceConnections[deviceID]?.remove(connection)
            if deviceConnections[deviceID]?.isEmpty == true {
                deviceConnections[deviceID] = nil
                var updated = devices
                if let index = updated.devices.firstIndex(where: { $0.deviceID == deviceID }), !updated.devices[index].isRevoked {
                    updated.devices[index].lastSeen = nowMilliseconds
                    if (try? updated.save(to: directory)) != nil { devices = updated }
                }
                changed()
            }
        }
    }

    // MARK: - Authentication (server queue)

    /// The Mac whose peer token this is.
    func authenticate(token: String) -> UUID? { membership ? peers.authenticate(token: token) : nil }

    /// The device whose own token this is.
    func authenticateDevice(token: String) -> UUID? { devices.authenticate(token: token) }

    /// A device connected on `connection` with its own token: it is no longer waited for on the shared one.
    func deviceAuthenticated(_ deviceID: UUID, connection: Int32, clientName: String, from host: String?) {
        deviceConnections[deviceID, default: []].insert(connection)
        var updated = devices
        if updated.switched(name: String(clientName.prefix(100)), host: host), (try? updated.save(to: directory)) != nil { devices = updated }
        changed()
    }

    /// Whether the shared token is retired: it is refused until Fleet is turned off, which
    /// puts everything back as it was.
    var sharedTokenRetired: Bool { devices.sharedTokenRetired }

    /// A client connected with the shared token: it is waited for until it has a token of its own.
    func sharedTokenUsed(clientName: String, host: String?) {
        guard !devices.sharedTokenRetired else { return }
        let now = nowMilliseconds
        let key = FleetDevices.key(name: clientName, host: host)
        let recent = devices.legacy.first { $0.id == key }.map { now - $0.lastSeen < 3_600_000 } ?? false
        guard !recent else { return }
        var updated = devices
        updated.sighted(name: String(clientName.prefix(100)), host: host, now: now)
        if (try? updated.save(to: directory)) != nil {
            devices = updated
            changed()
        }
    }

    /// A Mac connected with its token from `host`: where to reach it if its address changed.
    func peerAuthenticated(_ hostID: UUID, from host: String?) {
        guard let host, var record = peers.record(hostID), !record.revoked, let current = record.addresses.first,
              current.host != host else { return }
        record.reached(at: FleetAddress(host: host, port: current.port))
        if (try? save(record)) != nil { changed() }
    }

    // MARK: - Requests (server queue)

    /// Serves one fleet request. `reply` may be called now or later, from any thread.
    func serve(_ request: RemoteRequest, from caller: FleetCaller, reply: @escaping @Sendable (RemoteReply) -> Void) {
        // Pairing Macs, removing them and joining are a member's: with Fleet off they are refused, as they always were.
        switch request {
        case .fleetPair(let id, _, _), .fleetEstablish(let id, _), .fleetIntroduce(let id, _), .fleetRevoke(let id, _, _), .fleetSync(let id, _),
             .fleetPressure(let id, _), .fleetReadiness(let id, _), .fleetPressureNow(let id), .fleetRepoManifest(let id, _):
            guard membership else { return reply(Self.off(id)) }
        case .fleetAction(let id, let action) where !action.isDeviceAction:
            guard membership else { return reply(Self.off(id)) }
        default: break
        }
        switch request {
        case .fleetIdentify(let id):
            reply(.fleetIdentity(id: id, hostID: identity.hostID, name: name, build: build, fleetEnabled: membership))
        case .fleetPair(let id, let code, let from):
            guard !caller.authenticated else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Pair before saying hello.")) }
            reply(pair(id: id, code: code, from: from, caller: caller))
        case .fleetEstablish(let id, let from):
            guard caller.viaSharedToken else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Establishing needs the shared token.")) }
            reply(establish(id: id, from: from, caller: caller))
        case .fleetIntroduce(let id, let introduction):
            guard caller.peerHostID != nil else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet introduces another.")) }
            reply(introduced(id: id, introduction, by: caller.peerHostID))
        case .fleetRevoke(let id, let hostID, let at):
            guard let from = caller.peerHostID else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet removes another.")) }
            revoked(hostID, at: at, heardFrom: from)
            reply(.ok(id: id))
        case .fleetPressure(let id, let sample):
            guard caller.access == .member, let from = caller.peerHostID else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet reports its load.")) }
            pressure.received(sample, from: from)
            reply(.ok(id: id))
        case .fleetReadiness(let id, let report):
            guard caller.access == .member, let from = caller.peerHostID else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet reports its readiness.")) }
            pressure.received(report, from: from)
            reply(.ok(id: id))
        case .fleetPressureNow(let id):
            guard caller.access == .member else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet asks for a sample.")) }
            Task { [pressure] in
                let (sample, readiness) = await pressure.sampleNow()
                reply(.fleetPressureSample(id: id, sample: sample, readiness: readiness))
            }
        case .fleetRepoManifest(let id, let update):
            // Members only, like every fleet store: a device or the shared token is never told what a Mac holds of a repository.
            guard caller.access == .member, let from = caller.peerHostID else {
                return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet sends manifests."))
            }
            guard update.isValid else { return reply(Self.refusal(id, FleetSnapshotProtocol.Code.invalid, "That manifest step is malformed.")) }
            reply(.fleetRepoManifestAck(id: id, ack: index.received(update, from: from)))
        case .fleetSync(let id, let request):
            // Members only: a client device or the shared token never reads or writes the fleet's store.
            guard caller.access == .member, let from = caller.peerHostID else {
                return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet syncs."))
            }
            switch syncEngine.serve(request, from: from) {
            case .success(let answer): reply(.fleetSyncReply(id: id, reply: answer))
            case .failure(let refusal): reply(Self.refusal(id, refusal.code, refusal.message))
            }
        case .fleetPairDevice(let id, let code, let device):
            guard !caller.authenticated else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Pair before saying hello.")) }
            // Before the code is tried: a device whose identity was revoked pairs again as a new one with the same code.
            if devices.record(device.deviceID)?.isRevoked == true {
                return reply(Self.refusal(id, FleetProtocol.Code.deviceRevoked, "That device was removed from the fleet. Pairing again makes it a new one."))
            }
            if let refusal = judge(\.deviceCode, code: code, id: id, caller: caller, screen: "Add a device",
                                   notOpen: "That Mac isn't showing a code. Open Add a device on it.") {
                return reply(refusal)
            }
            takeDevice(id: id, device, caller: caller, reply: reply)
        case .fleetEnrollDevice(let id, let device):
            guard caller.access == .shared else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a client on the shared token is given a token of its own.")) }
            takeDevice(id: id, device, caller: caller, reply: reply)
        case .fleetSyncDevices(let id, let entries):
            guard caller.access == .member else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet syncs devices.")) }
            mergeDevices(entries, from: caller.peerHostID)
            reply(.fleetDevices(id: id, result: FleetDevicesResult(hostID: identity.hostID, name: name, devices: devices.entries)))
        case .fleetRead(let id):
            guard caller.isLocal else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only this Mac's app reads its fleet.")) }
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .fleetAction(let id, let action):
            guard caller.isLocal else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only this Mac's app changes its fleet.")) }
            perform(action, id: id, caller: caller, reply: reply)
        default:
            break
        }
    }

    static func off(_ id: Int) -> RemoteReply {
        refusal(id, FleetProtocol.Code.off, "Enable Fleet in Settings ▸ Experiments.")
    }

    static func refusal(_ id: Int, _ code: String, _ message: String) -> RemoteReply {
        .error(id: id, code: code, message: message)
    }

    // MARK: Joining: the Mac showing the code

    private func pair(id: Int, code: String, from: FleetIntroduction, caller: FleetCaller) -> RemoteReply {
        if let refusal = judge(\.join, code: code, id: id, caller: caller, screen: "Join a fleet",
                               notOpen: "That Mac isn't waiting for a code. Open Join a fleet on it.") {
            return refusal
        }
        return adopt(id: id, from: from, caller: caller)
    }

    /// Judges a code tried against the window in `slot`: a refusal to send back, or nil when the code
    /// was right (the window is spent). A wrong try, a lockout and an expiry say how to get a new code.
    private func judge(_ slot: ReferenceWritableKeyPath<FleetService, (window: FleetJoinWindow, owner: Int32)?>, code: String, id: Int,
                       caller: FleetCaller, screen: String, notOpen: String) -> RemoteReply? {
        guard var window = self[keyPath: slot]?.window else {
            return Self.refusal(id, FleetProtocol.Code.notJoining, notOpen)
        }
        let owner = self[keyPath: slot]?.owner ?? caller.connection
        switch window.attempt(code, now: clock()) {
        case .accepted:
            self[keyPath: slot] = nil
            changed()
            return nil
        case .wrong(let left):
            self[keyPath: slot] = (window, owner)
            changed()
            return Self.refusal(id, FleetProtocol.Code.badCode, left == 1 ? "That code isn't right. One try left." : "That code isn't right. \(left) tries left.")
        case .lockedOut:
            self[keyPath: slot] = nil
            changed()
            return Self.refusal(id, FleetProtocol.Code.lockedOut, "Too many wrong codes. Open \(screen) again for a new one.")
        case .expired:
            self[keyPath: slot] = nil
            changed()
            return Self.refusal(id, FleetProtocol.Code.codeExpired, "That code expired. Open \(screen) again for a new one.")
        }
    }

    /// An existing paired host (legacy token) becoming a peer: the same exchange, the token in
    /// place of the code.
    private func establish(id: Int, from: FleetIntroduction, caller: FleetCaller) -> RemoteReply {
        adopt(id: id, from: from, caller: caller)
    }

    /// Makes the token this host presents to `from`, stores `from`'s hash, and answers with the
    /// hash of its own.
    private func adopt(id: Int, from: FleetIntroduction, caller: FleetCaller) -> RemoteReply {
        guard Self.valid(from), from.hostID != identity.hostID else {
            return Self.refusal(id, FleetProtocol.Code.invalid, "That introduction isn't valid.")
        }
        guard let host = caller.observedHost else {
            return Self.refusal(id, FleetProtocol.Code.unreachable, "This Mac couldn't tell where the request came from.")
        }
        let token = FleetProtocol.makeToken()
        let record = FleetPeerRecord(hostID: from.hostID, name: Self.cleaned(from.name), addresses: [FleetAddress(host: host, port: from.port)],
                                     myToken: token, peerTokenHash: from.myTokenHash, pairedAt: nowMilliseconds)
        do { try save(record) } catch {
            ShepherdLog.error("fleet: could not save a peer: \(error)")
            return Self.refusal(id, "save_failed", "This Mac couldn't save the pairing.")
        }
        startLink(record.hostID)
        changed()
        return .fleetPaired(id: id, hostID: identity.hostID, name: name, myTokenHash: FleetProtocol.hash(token))
    }

    static func valid(_ intro: FleetIntroduction) -> Bool {
        intro.port > 0 && isHash(intro.myTokenHash) && !cleaned(intro.name).isEmpty
    }

    private static func isHash(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    /// A name from another Mac: one line, bounded.
    static func cleaned(_ name: String) -> String {
        String(name.filter { !$0.isNewline }.trimmingCharacters(in: .whitespaces).prefix(100))
    }

    // MARK: Introductions

    private func introduced(id: Int, _ introduction: FleetIntroduce, by introducer: UUID?) -> RemoteReply {
        let member = introduction.member
        guard member.hostID != identity.hostID, member.port > 0, member.host?.isEmpty == false,
              introduction.theirTokenHash.map(Self.isHash) != false, !Self.cleaned(member.name).isEmpty else {
            return Self.refusal(id, FleetProtocol.Code.invalid, "That introduction isn't valid.")
        }
        let address = FleetAddress(host: member.host ?? "", port: member.port)
        var record = peers.record(member.hostID).flatMap { $0.revoked ? nil : $0 }
            ?? FleetPeerRecord(hostID: member.hostID, name: "", pairedAt: nowMilliseconds)
        if introduction.theirTokenHash == nil, record.myToken != nil, record.peerTokenHash != nil { return .ok(id: id) }
        record.name = Self.cleaned(member.name)
        record.reached(at: address)
        if record.myToken == nil { record.myToken = FleetProtocol.makeToken() }
        if let theirs = introduction.theirTokenHash { record.peerTokenHash = theirs }
        guard let myToken = record.myToken else { return Self.refusal(id, FleetProtocol.Code.invalid, "That introduction isn't valid.") }
        do { try save(record) } catch {
            ShepherdLog.error("fleet: could not save an introduction: \(error)")
            return Self.refusal(id, "save_failed", "This Mac couldn't save the introduction.")
        }
        // The member can only present its token once it has ours: the second step starts the link.
        if introduction.theirTokenHash != nil { startLink(record.hostID) }
        changed()
        return .fleetPaired(id: id, hostID: identity.hostID, name: name, myTokenHash: FleetProtocol.hash(myToken))
    }

    /// Introduces what this Mac pairing brought into the fleet to the members that don't know it
    /// (`FleetPeerRecord.introduce`), over the links this host holds. What can't go now goes when
    /// a link comes up.
    private func brokerPending() {
        guard !brokering, !stopped, membership else { return }
        let waiting = peers.members.filter { !$0.introduce.isEmpty }
        guard !waiting.isEmpty else { return }
        brokering = true
        Task { [weak self] in
            for newcomer in waiting {
                for memberID in newcomer.introduce { await self?.introduce(newcomer: newcomer.hostID, to: memberID) }
            }
            self?.queue.async { self?.brokering = false }
        }
    }

    private func introduce(newcomer newcomerID: UUID, to memberID: UUID) async {
        let ends = await sync { () -> (RemoteHostClient, RemoteHostClient, FleetMember, FleetMember)? in
            guard let newcomer = self.peers.record(newcomerID), !newcomer.revoked, let newcomerAddress = newcomer.addresses.first,
                  let member = self.peers.record(memberID), !member.revoked, let memberAddress = member.addresses.first,
                  let newcomerClient = self.links[newcomerID]?.client, let memberClient = self.links[memberID]?.client else { return nil }
            return (newcomerClient, memberClient,
                    FleetMember(hostID: newcomerID, name: newcomer.name, host: newcomerAddress.host, port: newcomerAddress.port),
                    FleetMember(hostID: memberID, name: member.name, host: memberAddress.host, port: memberAddress.port))
        }
        guard let (newcomerClient, memberClient, newcomerInfo, memberInfo) = ends else { return }
        do {
            // The member makes its token for the newcomer, the newcomer makes its own and hears
            // the member's hash, and the member hears the newcomer's: tokens never travel, only hashes.
            if let first = try await memberClient.fleetIntroduce(FleetIntroduce(member: newcomerInfo, theirTokenHash: nil)) {
                guard let second = try await newcomerClient.fleetIntroduce(FleetIntroduce(member: memberInfo, theirTokenHash: first.myTokenHash)) else { return }
                _ = try await memberClient.fleetIntroduce(FleetIntroduce(member: newcomerInfo, theirTokenHash: second.myTokenHash))
            }
            await sync {
                guard var record = self.peers.record(newcomerID) else { return }
                record.introduce.removeAll { $0 == memberID }
                try? self.save(record)
            }
        } catch {
            ShepherdLog.warning("fleet: an introduction didn't go through yet: \(error)")
        }
    }

    // MARK: Devices

    /// Takes a client device into the fleet: pairing with a code or being given its own token
    /// (`fleetPairDevice`, `fleetEnrollDevice`). The device made the token; only its hash is kept here and
    /// on every other Mac (`pushDevices`). Answers with the Macs the device can now reach.
    /// The answer waits (a few seconds at most) for the other Macs to take the device in, so the device
    /// can connect to each of them the moment it hears of them.
    private func takeDevice(id: Int, _ introduction: FleetDeviceIntroduction, caller: FleetCaller,
                            reply: @escaping @Sendable (RemoteReply) -> Void) {
        let name = Self.cleaned(introduction.name)
        guard !name.isEmpty, Self.isHash(introduction.tokenHash) else {
            return reply(Self.refusal(id, FleetProtocol.Code.invalid, "That device isn't valid."))
        }
        // A device that asks again after a lost answer is told the same thing.
        let known = devices.record(introduction.deviceID).map { !$0.isRevoked && $0.tokenHash == introduction.tokenHash } ?? false
        if !known {
            guard devices.active.count < FleetProtocol.maxDevices else {
                return reply(Self.refusal(id, "devices_full", "This fleet has as many devices as it holds. Revoke one in Settings ▸ Fleet first."))
            }
            var updated = devices
            let record = FleetDeviceRecord(deviceID: introduction.deviceID, name: name, kind: introduction.kind,
                                           tokenHash: introduction.tokenHash, pairedAt: nowMilliseconds)
            guard updated.add(record) else {
                return reply(Self.refusal(id, FleetProtocol.Code.deviceRevoked, "That device was removed from the fleet. Pairing again makes it a new one."))
            }
            if caller.access == .shared, let clientName = caller.clientName {
                updated.switched(name: clientName, host: caller.observedHost)
            }
            do { try updated.save(to: directory) } catch {
                ShepherdLog.error("fleet: could not save a device: \(error)")
                return reply(Self.refusal(id, "save_failed", "This Mac couldn't save the device."))
            }
            devices = updated
            changed()
        }
        let members = (membership ? peers.members : []).compactMap { record in
            record.addresses.first.map { FleetMember(hostID: record.hostID, name: record.name, host: $0.host, port: $0.port) }
        }
        let answer = RemoteReply.fleetDevices(id: id, result: FleetDevicesResult(hostID: identity.hostID, name: self.name, members: members))
        // Also on a repeat: the first answer may have been lost before the members heard.
        let pushes = pushDevices()
        guard !pushes.isEmpty else { return reply(answer) }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for task in pushes { await task.value } }
                group.addTask { try? await Task.sleep(for: Self.deviceSyncPatience) }
                await group.next()
                group.cancelAll()
            }
            reply(answer)
        }
    }

    /// How long a device's pairing waits for the other Macs to take it in.
    static let deviceSyncPatience: Duration = .seconds(3)

    /// Takes in the devices a member holds. What changed goes on to the other members (a revocation too),
    /// so the lists converge even when two Macs can't reach each other.
    private func mergeDevices(_ entries: [FleetDeviceEntry], from member: UUID?) {
        var updated = devices
        let merged = updated.merge(entries)
        guard merged.changed else { return }
        do { try updated.save(to: directory) } catch {
            ShepherdLog.error("fleet: could not save devices: \(error)")
            return
        }
        devices = updated
        for deviceID in merged.revoked { endDevice(deviceID) }
        pushDevices(except: member)
        changed()
    }

    /// A device was revoked: its connections end.
    private func endDevice(_ deviceID: UUID) {
        deviceConnections[deviceID] = nil
        onDeviceRevoked?(deviceID)
    }

    /// Sends this Mac's devices to the members it holds a link to (`only` that one, `except` that one) and
    /// merges what they hold. A member that isn't connected gets them when its link comes up.
    @discardableResult
    private func pushDevices(only: UUID? = nil, except: UUID? = nil) -> [Task<Void, Never>] {
        let entries = devices.entries
        var tasks: [Task<Void, Never>] = []
        for (hostID, link) in links where hostID != except && (only == nil || only == hostID) {
            guard let client = link.client else { continue }
            tasks.append(Task { [weak self] in
                guard let theirs = try? await client.fleetSyncDevices(entries) else { return }
                self?.queue.async { self?.mergeDevices(theirs.devices, from: hostID) }
            })
        }
        return tasks
    }

    // MARK: Removing

    /// `hostID` was removed from the fleet at `at`, as `from` says.
    private func revoked(_ hostID: UUID, at: Double, heardFrom from: UUID?) {
        if hostID == identity.hostID {
            // This Mac was removed: it leaves, keeping what it already synced. News older than a
            // pairing made since (a stale tombstone another Mac still holds) changes nothing.
            guard peers.members.allSatisfy({ $0.pairedAt <= at }) else { return }
            for member in peers.members { drop(member.hostID, at: at, flood: false, heardFrom: from) }
            return
        }
        drop(hostID, at: at, flood: true, heardFrom: from)
    }

    @discardableResult
    private func drop(_ hostID: UUID, at: Double, flood: Bool, heardFrom from: UUID?) -> Bool {
        var updated = peers
        guard updated.revoke(hostID, at: at) else { return false }
        do { try updated.save(to: directory) } catch { ShepherdLog.error("fleet: could not save a removal: \(error)") }
        peers = updated
        let notified = links.filter { $0.key != hostID && $0.key != from }.compactMap(\.value.client)
        let leaving = links[hostID]?.client
        if flood {
            Task {
                for client in notified { try? await client.fleetRevoke(hostID: hostID, at: at) }
                // The Mac that was removed is told too, when it is reachable: it leaves.
                try? await leaving?.fleetRevoke(hostID: hostID, at: at)
                leaving?.disconnect()
            }
        }
        stopLink(hostID, closing: !flood)
        pressure.forget(hostID)
        pressure.refresh()
        index.forget(peer: hostID)
        onPeerRemoved?(hostID)
        changed()
        return true
    }

    // MARK: Actions from this Mac's app

    private func perform(_ action: FleetAction, id: Int, caller: FleetCaller, reply: @escaping @Sendable (RemoteReply) -> Void) {
        switch action {
        case .startJoin:
            let opened = FleetJoinWindow.open(now: clock())
            join = (opened.window, caller.connection)
            let expiry = opened.window
            queue.asyncAfter(deadline: .now() + FleetProtocol.codeLifetime) { [weak self] in
                // Only the window this timer was made for.
                guard let self, self.join?.window == expiry else { return }
                self.join = nil
                self.changed()
            }
            changed()
            let expiresAt = (clock().addingTimeInterval(FleetProtocol.codeLifetime).timeIntervalSince1970 * 1000).rounded()
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot(), join: .init(code: opened.code, expiresAt: expiresAt))))
        case .stopJoin:
            if join != nil { join = nil; changed() }
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .remove(let hostID):
            guard peers.record(hostID).map({ !$0.revoked }) == true else {
                return reply(Self.refusal(id, FleetProtocol.Code.invalid, "That Mac isn't in the fleet."))
            }
            drop(hostID, at: nowMilliseconds, flood: true, heardFrom: nil)
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .pair(let host, let port, let code):
            Task { [weak self] in
                guard let self else { return }
                do {
                    let paired = try await self.pair(host: host, port: port, code: code)
                    reply(.fleetResult(id: id, result: FleetResult(snapshot: await self.sync { self.snapshot() }, paired: paired)))
                } catch {
                    reply(Self.failure(id, error))
                }
            }
        case .watching(let on):
            pressure.watch(on, connection: caller.connection)
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .reconnect(let hostID):
            guard peers.record(hostID).map({ !$0.revoked }) == true else {
                return reply(Self.refusal(id, FleetProtocol.Code.invalid, "That Mac isn't in the fleet."))
            }
            // A link that is up is left alone; one waiting out its backoff starts over now.
            if links[hostID]?.phase != .connected { startLink(hostID) }
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .startDeviceCode:
            let opened = FleetJoinWindow.open(now: clock())
            deviceCode = (opened.window, caller.connection)
            let expiry = opened.window
            queue.asyncAfter(deadline: .now() + FleetProtocol.codeLifetime) { [weak self] in
                guard let self, self.deviceCode?.window == expiry else { return }
                self.deviceCode = nil
                self.changed()
            }
            changed()
            let expiresAt = (clock().addingTimeInterval(FleetProtocol.codeLifetime).timeIntervalSince1970 * 1000).rounded()
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot(), deviceCode: .init(code: opened.code, expiresAt: expiresAt))))
        case .stopDeviceCode:
            if deviceCode != nil { deviceCode = nil; changed() }
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .revokeDevice(let deviceID):
            var updated = devices
            guard updated.revoke(deviceID, at: nowMilliseconds) else {
                return reply(Self.refusal(id, FleetProtocol.Code.invalid, "That device isn't paired."))
            }
            do { try updated.save(to: directory) } catch {
                return reply(Self.refusal(id, "save_failed", "This Mac couldn't save the change."))
            }
            devices = updated
            endDevice(deviceID)
            pushDevices()
            changed()
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .forgetLegacyClient(let key):
            var updated = devices
            if updated.forget(legacy: key), (try? updated.save(to: directory)) != nil {
                devices = updated
                changed()
            }
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .retireSharedToken:
            let waiting = devices.waiting(now: nowMilliseconds)
            guard waiting.isEmpty else {
                return reply(Self.refusal(id, "devices_waiting", waiting.count == 1
                    ? "One device hasn't been given its own token yet. Open Shepherd on it, or forget it."
                    : "\(waiting.count) devices haven't been given their own token yet. Open Shepherd on them, or forget them."))
            }
            var updated = devices
            updated.sharedTokenRetired = true
            do { try updated.save(to: directory) } catch {
                return reply(Self.refusal(id, "save_failed", "This Mac couldn't save the change."))
            }
            devices = updated
            onSharedTokenRetired?()
            changed()
            reply(.fleetResult(id: id, result: FleetResult(snapshot: snapshot())))
        case .enrollApp(let appName):
            let token = FleetProtocol.makeToken()
            let app = FleetDeviceIntroduction(deviceID: UUID(), name: appName, kind: .macApp, tokenHash: FleetProtocol.hash(token))
            takeDevice(id: id, app, caller: caller) { [weak self] answer in
                guard case .fleetDevices = answer else { return reply(answer) }
                self?.queue.async {
                    guard let self else { return }
                    reply(.fleetResult(id: id, result: FleetResult(snapshot: self.snapshot(), appToken: token)))
                }
            }
        case .adopt(let hosts):
            Task { [weak self] in
                guard let self else { return }
                var outcomes: [FleetAdoption] = []
                for legacy in hosts { outcomes.append(FleetAdoption(id: legacy.id, outcome: await self.establish(legacy))) }
                reply(.fleetResult(id: id, result: FleetResult(snapshot: await self.sync { self.snapshot() }, adopted: outcomes)))
            }
        }
    }

    private static func failure(_ id: Int, _ error: Error) -> RemoteReply {
        if let error = error as? RemoteHostClientError, case .rejected(let code, let message) = error {
            return refusal(id, code, message)
        }
        return refusal(id, FleetProtocol.Code.unreachable, "Couldn't reach that Mac.")
    }

    /// Enters `code` on the Mac at `host`:`port`, which shows it, and joins its fleet: pairs with
    /// it, then introduces it to every Mac this one is paired with.
    private func pair(host: String, port: UInt16, code: String) async throws -> FleetPeerStatus {
        let setup = await sync { () -> (token: String, port: UInt16, members: [UUID])? in
            guard let listenerPort = self.listenerPort else { return nil }
            return (FleetProtocol.makeToken(), listenerPort, self.peers.members.map(\.hostID))
        }
        guard let setup else {
            throw RemoteHostClientError.rejected(code: "listener_off", message: "This Mac isn't serving, so the other Mac couldn't reach it.")
        }
        let introduction = FleetIntroduction(hostID: identity.hostID, name: name, myTokenHash: FleetProtocol.hash(setup.token), port: setup.port)
        let (pairing, _) = try await RemoteHostClient.fleetPair(host: host, port: port, code: code, introduction: introduction)
        guard pairing.hostID != identity.hostID else {
            throw RemoteHostClientError.rejected(code: FleetProtocol.Code.invalid, message: "That is this Mac.")
        }
        let status: FleetPeerStatus = try await syncThrowing {
            let others = setup.members.filter { $0 != pairing.hostID }
            let record = FleetPeerRecord(hostID: pairing.hostID, name: Self.cleaned(pairing.name), addresses: [FleetAddress(host: host, port: port)],
                                         myToken: setup.token, peerTokenHash: pairing.myTokenHash, pairedAt: self.nowMilliseconds, introduce: others)
            try self.save(record)
            self.startLink(record.hostID)
            self.changed()
            return self.status(of: record)
        }
        // The Mac joined; its introductions go over the links, which come up in a moment.
        await waitForLink(pairing.hostID)
        await sync { self.brokerPending() }
        return status
    }

    /// A host the app already knew by address and the shared token becomes a peer: no code, the
    /// token in its place (`fleetEstablish`). A Mac that doesn't speak fleet, or has it off, is
    /// left exactly as it was.
    private func establish(_ legacy: FleetLegacyHost) async -> FleetAdoption.Outcome {
        let client = RemoteHostClient()
        defer { client.disconnect() }
        do {
            _ = try await client.connect(host: legacy.host, port: legacy.port, token: legacy.token, clientName: name,
                                         capabilities: [], fetchesState: false)
        } catch {
            if case RemoteHostClientError.rejected(let code, _) = error { return .refused(code: code) }
            return .unreachable
        }
        guard client.capabilities.contains(RemoteProtocol.fleetCapability), let peerID = client.hostID, peerID != identity.hostID else { return .notFleet }
        let known = await sync { () -> FleetPeerRecord? in self.peers.record(peerID).flatMap { $0.revoked || !$0.isLinkable ? nil : $0 } }
        if let known { return .established(hostID: known.hostID, name: known.name) }
        guard let port = await sync({ self.listenerPort }) else { return .refused(code: "listener_off") }
        let token = FleetProtocol.makeToken()
        do {
            let pairing = try await client.fleetEstablish(from: FleetIntroduction(hostID: identity.hostID, name: name,
                                                                                  myTokenHash: FleetProtocol.hash(token), port: port))
            await sync {
                let record = FleetPeerRecord(hostID: pairing.hostID, name: Self.cleaned(pairing.name),
                                             addresses: [FleetAddress(host: legacy.host, port: legacy.port)], myToken: token,
                                             peerTokenHash: pairing.myTokenHash, pairedAt: self.nowMilliseconds)
                do { try self.save(record) } catch { ShepherdLog.error("fleet: could not save a peer: \(error)"); return }
                self.startLink(record.hostID)
                self.changed()
            }
            return .established(hostID: pairing.hostID, name: Self.cleaned(pairing.name))
        } catch {
            if case RemoteHostClientError.rejected(let code, _) = error { return .refused(code: code) }
            return .unreachable
        }
    }

    // MARK: - Snapshot (server queue)

    func snapshot() -> FleetSnapshot {
        let statuses = (membership ? peers.members : []).map(status(of:)).sorted { ($0.pairedAt, $0.name) < ($1.pairedAt, $1.name) }
        let window = (membership ? join : nil).map {
            FleetJoinStatus(expiresAt: (($0.window.expiresAt).timeIntervalSince1970 * 1000).rounded(), attemptsLeft: $0.window.attemptsLeft)
        }
        let syncStatus = syncEngine.status(peers: statuses.map { ($0.hostID, $0.name, $0.link == .connected) })
        let now = nowMilliseconds
        let clients = devices.active.map {
            FleetDeviceStatus(deviceID: $0.deviceID, name: $0.name, kind: $0.kind, pairedAt: $0.pairedAt,
                              connected: deviceConnections[$0.deviceID]?.isEmpty == false, lastSeen: $0.lastSeen)
        }.sorted { ($0.pairedAt, $0.name) < ($1.pairedAt, $1.name) }
        let code = deviceCode.map {
            FleetJoinStatus(expiresAt: (($0.window.expiresAt).timeIntervalSince1970 * 1000).rounded(), attemptsLeft: $0.window.attemptsLeft)
        }
        let sharedToken = FleetSharedTokenStatus(retired: devices.sharedTokenRetired, waiting: devices.waiting(now: now).map(\.client),
                                                 switched: clients.count)
        return FleetSnapshot(enabled: membership, hostID: identity.hostID, name: name, build: build, addresses: FleetAddresses.local(),
                             port: listenerPort, advertising: discovery?.isAdvertising ?? false, peers: statuses, join: window,
                             sync: membership ? syncStatus : nil, devices: FleetDevicesSnapshot(devices: clients, code: code, sharedToken: sharedToken),
                             macs: membership ? pressure.macs(thisMac: identity.hostID, peerIDs: statuses.map(\.hostID)) : [],
                             index: membership ? index.status() : nil)
    }

    private func status(of record: FleetPeerRecord) -> FleetPeerStatus {
        let link = links[record.hostID]
        return FleetPeerStatus(hostID: record.hostID, name: record.name, kind: record.kind, host: record.addresses.first?.host,
                               port: record.addresses.first?.port, pairedAt: record.pairedAt, link: link?.phase ?? .offline, lastSeen: link?.lastSeen)
    }

    // MARK: - Persistence (server queue)

    /// Saves `record`; nothing changes in memory if the file can't be written.
    @discardableResult
    private func save(_ record: FleetPeerRecord) throws -> FleetPeers {
        var updated = peers
        updated.upsert(record)
        try updated.save(to: directory)
        peers = updated
        return updated
    }

    // MARK: - Links

    /// Starts (again) the link to `hostID`: connects with the token this host presents and holds
    /// the connection, reconnecting with backoff, until the Mac is removed or Fleet is turned off.
    private func startLink(_ hostID: UUID) {
        guard !stopped, membership, peers.record(hostID)?.isLinkable == true else { return }
        stopLink(hostID)
        let link = Link(hostID: hostID)
        links[hostID] = link
        link.task = Task { [weak self] in await self?.run(link) }
    }

    /// Ends the link to `hostID`. `closing: false` leaves its connection open for the caller to
    /// close once it has said what it has to.
    private func stopLink(_ hostID: UUID, closing: Bool = true) {
        guard let link = links.removeValue(forKey: hostID) else { return }
        syncEngine.linkDown(peer: hostID)
        index.linkDown(peer: hostID)
        link.task?.cancel()
        if closing { link.client?.disconnect() }
        link.client = nil
    }

    private func run(_ link: Link) async {
        var backoff = RemoteReconnectBackoff()
        while !Task.isCancelled {
            guard let record = await sync({ self.record(for: link) }), let token = record.myToken else { return }
            await sync { self.setPhase(.connecting, of: link) }
            var held = false
            for address in record.addresses {
                if Task.isCancelled { return }
                let client = RemoteHostClient()
                let (dropped, signal) = AsyncStream<Void>.makeStream()
                // Before connecting, so no drop can slip between the connection and the handler.
                client.onDisconnected = { _ in signal.yield(); signal.finish() }
                do {
                    _ = try await client.connect(host: address.host, port: address.port, token: token, clientName: name,
                                                 capabilities: [], expectingHostID: link.hostID, fetchesState: false)
                } catch {
                    client.disconnect()
                    continue
                }
                guard await sync({ self.established(link, client: client, at: address) }) else { client.disconnect(); return }
                held = true
                backoff.reset()
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for await _ in dropped { return } }
                    group.addTask { await Self.keepAlive(client) }
                    await group.next()
                    group.cancelAll()
                }
                client.disconnect()
                await sync { self.lost(link) }
                break
            }
            if Task.isCancelled { return }
            if !held { await sync { self.setPhase(.offline, of: link) } }
            try? await Task.sleep(for: held ? .seconds(1) : backoff.next())
        }
    }

    /// Returns when the peer stops answering.
    private static func keepAlive(_ client: RemoteHostClient) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: keepAliveInterval)
            guard !Task.isCancelled else { return }
            do { _ = try await client.fleetIdentify() } catch { return }
        }
    }

    private func record(for link: Link) -> FleetPeerRecord? {
        guard !stopped, membership, links[link.hostID] === link, let record = peers.record(link.hostID), record.isLinkable else { return nil }
        return record
    }

    private func setPhase(_ phase: FleetPeerStatus.Link, of link: Link) {
        guard links[link.hostID] === link, link.phase != phase else { return }
        link.phase = phase
        changed()
    }

    /// A link connected: false if it was replaced or stopped meanwhile.
    private func established(_ link: Link, client: RemoteHostClient, at address: FleetAddress) -> Bool {
        guard links[link.hostID] === link, !stopped else { return false }
        link.client = client
        link.phase = .connected
        link.lastSeen = nil
        if var record = peers.record(link.hostID), record.addresses.first != address {
            record.reached(at: address)
            try? save(record)
        }
        announceRemovals(over: client, to: link.hostID)
        pressure.refresh()
        pressure.greet(client)
        syncEngine.linkUp(peer: link.hostID, client: client)
        index.linkUp(peer: link.hostID, client: client)
        pushDevices(only: link.hostID)
        changed()
        brokerPending()
        return true
    }

    private func lost(_ link: Link) {
        guard links[link.hostID] === link else { return }
        syncEngine.linkDown(peer: link.hostID)
        index.linkDown(peer: link.hostID)
        link.client = nil
        link.phase = .offline
        link.lastSeen = nowMilliseconds
        pressure.refresh()
        changed()
    }

    /// A Mac that was offline when someone was removed hears of it as its link comes up.
    private func announceRemovals(over client: RemoteHostClient, to peer: UUID) {
        let removed = peers.tombstones.filter { $0.hostID != peer }.compactMap { record in record.revokedAt.map { (record.hostID, $0) } }
        guard !removed.isEmpty else { return }
        Task { for (hostID, at) in removed { try? await client.fleetRevoke(hostID: hostID, at: at) } }
    }

    /// Waits for the link to `hostID` to connect, for a while.
    private func waitForLink(_ hostID: UUID) async {
        let deadline = ContinuousClock.now + Self.introductionPatience
        while ContinuousClock.now < deadline {
            if await sync({ self.links[hostID]?.phase == .connected }) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Queue hop

    private func sync<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }

    private func syncThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    // MARK: - Tests

    /// The Macs this host is paired with, as the records hold them.
    var peerRecords: [FleetPeerRecord] { peers.peers }

    /// Whether the link to `hostID` is connected.
    func isConnected(_ hostID: UUID) -> Bool { links[hostID]?.phase == .connected }
}
