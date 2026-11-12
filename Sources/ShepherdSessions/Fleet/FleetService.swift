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

    /// Authenticated with the shared remote token: a legacy Mac or a phone.
    var viaSharedToken: Bool { authenticated && !isLocal && peerHostID == nil }
}

/// The host's part of a fleet: who this Mac is, which Macs it is paired with, a link to each, and
/// the code window while it is joining. Runs only in the host, only while Settings ▸ Experiments ▸
/// Fleet is on. Every piece of state belongs to the server queue: requests and callbacks hop onto
/// it, and nothing waits on it (docs/rules.md, Server concurrency).
///
/// Slice 1 holds links and pairs Macs; nothing syncs or dispatches over them yet.
final class FleetService: @unchecked Sendable {
    /// The server queue.
    private let queue: DispatchQueue
    private let directory: URL
    let identity: FleetIdentity
    private var name: String
    private let build: String?
    private let discovery: FleetDiscovery?
    private let clock: @Sendable () -> Date

    /// Server queue: something the app draws changed.
    var onChange: (() -> Void)?
    /// Server queue: `hostID` left the fleet, so any connection that authenticated as it must end.
    var onPeerRemoved: ((UUID) -> Void)?

    private var peers: FleetPeers
    /// Pressure samples and readiness reports: this Mac's and each peer's (`FleetPressure`).
    let pressure: FleetPressure
    private var join: (window: FleetJoinWindow, owner: Int32)?
    private var listenerPort: UInt16?
    private var links: [UUID: Link] = [:]
    private var brokering = false
    private var stopped = false

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

    init(queue: DispatchQueue, directory: URL, name: String, build: String?, advertises: Bool = true,
         clock: @escaping @Sendable () -> Date = Date.init, pressure: FleetPressure? = nil) throws {
        self.queue = queue
        self.directory = directory
        self.name = name
        self.build = build
        self.clock = clock
        identity = try FleetIdentity.loadOrCreate(in: directory, now: clock())
        peers = try FleetPeers.load(from: directory)
        discovery = advertises ? FleetDiscovery() : nil
        self.pressure = pressure ?? FleetPressure(queue: queue, clock: clock)
        self.pressure.linkConnected = { [weak self] in self?.links.values.contains { $0.phase == .connected } == true }
        self.pressure.pushTargets = { [weak self] in self?.links.values.compactMap { $0.phase == .connected ? $0.client : nil } ?? [] }
    }

    var hostID: UUID { identity.hostID }

    private var nowMilliseconds: Double { (clock().timeIntervalSince1970 * 1000).rounded() }

    // MARK: - Lifecycle (server queue)

    /// Opens a link to every Mac this host is paired with.
    func start() {
        for record in peers.members where record.isLinkable { startLink(record.hostID) }
        advertise()
        changed()
    }

    /// Ends every link, the advertisement and the code window. Saved state stays.
    func stop() {
        stopped = true
        join = nil
        for id in Array(links.keys) { stopLink(id) }
        pressure.stop()
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

    private func changed() { onChange?() }

    /// A connection of the server closed.
    func connectionClosed(_ connection: Int32) {
        pressure.connectionClosed(connection)
        if join?.owner == connection {
            join = nil
            changed()
        }
    }

    // MARK: - Authentication (server queue)

    /// The Mac whose peer token this is.
    func authenticate(token: String) -> UUID? { peers.authenticate(token: token) }

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
        switch request {
        case .fleetIdentify(let id):
            reply(.fleetIdentity(id: id, hostID: identity.hostID, name: name, build: build, fleetEnabled: true))
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
            guard let from = caller.peerHostID else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet reports its load.")) }
            pressure.received(sample, from: from)
            reply(.ok(id: id))
        case .fleetReadiness(let id, let report):
            guard let from = caller.peerHostID else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet reports its readiness.")) }
            pressure.received(report, from: from)
            reply(.ok(id: id))
        case .fleetPressureNow(let id):
            guard caller.peerHostID != nil else { return reply(Self.refusal(id, FleetProtocol.Code.forbidden, "Only a Mac in the fleet asks for a sample.")) }
            Task { [pressure] in
                let (sample, readiness) = await pressure.sampleNow()
                reply(.fleetPressureSample(id: id, sample: sample, readiness: readiness))
            }
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

    static func refusal(_ id: Int, _ code: String, _ message: String) -> RemoteReply {
        .error(id: id, code: code, message: message)
    }

    // MARK: Joining: the Mac showing the code

    private func pair(id: Int, code: String, from: FleetIntroduction, caller: FleetCaller) -> RemoteReply {
        guard var window = join?.window else {
            return Self.refusal(id, FleetProtocol.Code.notJoining, "That Mac isn't waiting for a code. Open Join a fleet on it.")
        }
        let owner = join?.owner ?? caller.connection
        switch window.attempt(code, now: clock()) {
        case .accepted:
            join = nil
        case .wrong(let left):
            join = (window, owner)
            changed()
            return Self.refusal(id, FleetProtocol.Code.badCode, left == 1 ? "That code isn't right. One try left." : "That code isn't right. \(left) tries left.")
        case .lockedOut:
            join = nil
            changed()
            return Self.refusal(id, FleetProtocol.Code.lockedOut, "Too many wrong codes. Open Join a fleet again for a new one.")
        case .expired:
            join = nil
            changed()
            return Self.refusal(id, FleetProtocol.Code.codeExpired, "That code expired. Open Join a fleet again for a new one.")
        }
        changed()
        return adopt(id: id, from: from, caller: caller)
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
        guard !brokering, !stopped else { return }
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
        let statuses = peers.members.map(status(of:)).sorted { ($0.pairedAt, $0.name) < ($1.pairedAt, $1.name) }
        let window = join.map {
            FleetJoinStatus(expiresAt: (($0.window.expiresAt).timeIntervalSince1970 * 1000).rounded(), attemptsLeft: $0.window.attemptsLeft)
        }
        return FleetSnapshot(enabled: true, hostID: identity.hostID, name: name, build: build, addresses: FleetAddresses.local(),
                             port: listenerPort, advertising: discovery?.isAdvertising ?? false, peers: statuses, join: window,
                             macs: pressure.macs(thisMac: identity.hostID, peerIDs: statuses.map(\.hostID)))
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
        guard !stopped, peers.record(hostID)?.isLinkable == true else { return }
        stopLink(hostID)
        let link = Link(hostID: hostID)
        links[hostID] = link
        link.task = Task { [weak self] in await self?.run(link) }
    }

    /// Ends the link to `hostID`. `closing: false` leaves its connection open for the caller to
    /// close once it has said what it has to.
    private func stopLink(_ hostID: UUID, closing: Bool = true) {
        guard let link = links.removeValue(forKey: hostID) else { return }
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
        guard !stopped, links[link.hostID] === link, let record = peers.record(link.hostID), record.isLinkable else { return nil }
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
        changed()
        brokerPending()
        return true
    }

    private func lost(_ link: Link) {
        guard links[link.hostID] === link else { return }
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
