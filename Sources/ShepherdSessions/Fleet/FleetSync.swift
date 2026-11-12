import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Fleet's sync engine on one Mac (`fleet.sync.v1`): the store, the materializer that keeps this
/// Mac's real state and the store the same, the watcher, and a session over each peer link that
/// moves ops and blobs. Automatic: there is no push step and no "sync now".
///
/// Every Mac pushes what its peers lack over its own outbound link to each (a hello with the two
/// version vectors, then the missing ops, then live ops as they appear) and fetches the blobs it
/// needs over the same link. Ops are relayed verbatim by whoever holds them, so a Mac that was
/// asleep catches up from any Mac that is awake. All state belongs to the server queue.
final class FleetSync: @unchecked Sendable {
    /// A notice about what the first sync replaced stays on the sync line this long.
    static let noticeLifetime: TimeInterval = 24 * 3600
    /// A write that failed (pi held its lock) is tried again after this.
    static let retryDelay: TimeInterval = 5

    let store: FleetStore
    private let queue: DispatchQueue
    private let directory: URL
    private let materializer: FleetMaterializer
    private let name: () -> String
    private let clock: @Sendable () -> Date
    private var watcher: FleetWatcher?
    private var sessions: [UUID: Session] = [:]
    private var fetching: Set<String> = []
    private var started = false
    private var stopped = false
    private var retrying = false
    private var noticeURL: URL { directory.appendingPathComponent("notice.json") }
    private var notice: (text: String, at: Double)?

    /// Server queue: sync status changed (what Settings ▸ Fleet's line draws).
    var onChange: (() -> Void)?

    private final class Session: @unchecked Sendable {
        let peer: UUID
        let client: RemoteHostClient
        /// What the peer holds, as far as we know: its answers and what it sent us.
        var peerVector = FleetVersionVector()
        var helloed = false
        var running = false
        var again = false
        init(peer: UUID, client: RemoteHostClient) {
            self.peer = peer
            self.client = client
        }
    }

    init(queue: DispatchQueue, directory: URL, mac: UUID, name: @escaping () -> String,
         clock: @escaping @Sendable () -> Date = Date.init) throws {
        self.queue = queue
        self.directory = directory
        self.name = name
        self.clock = clock
        store = try FleetStore(directory: directory, mac: mac, clock: clock)
        materializer = FleetMaterializer(store: store, directory: directory, clock: clock)
        if let data = try? Data(contentsOf: noticeURL),
           let saved = try? JSONDecoder().decode(SavedNotice.self, from: data) { notice = (saved.text, saved.at) }
    }

    private struct SavedNotice: Codable {
        var text: String
        var at: Double
    }

    // MARK: Lifecycle (server queue)

    /// Adds a kind of unit. Before `start`, or after it: a source that comes later (the app's
    /// settings) is scanned as soon as it is added.
    func add(_ source: FleetUnitSource) {
        materializer.add(source)
        for file in source.watchedFiles { watcher?.watch(file: file) }
        watcher?.watch(trees: materializer.watchedTrees)
        if started { localChanged() }
    }

    /// Reads this Mac's state into the store (a first sync seeds it) and applies what the store holds.
    func start() {
        guard !started else { return }
        started = true
        stopped = false
        let watcher = FleetWatcher(queue: queue) { [weak self] in self?.localChanged() }
        self.watcher = watcher
        for file in materializer.watchedFiles { watcher.watch(file: file) }
        watcher.watch(trees: materializer.watchedTrees)
        localChanged()
    }

    /// Fleet turned off, or the host is stopping: no scanning, no sessions, nothing served. `start` begins again.
    func stop() {
        started = false
        stopped = true
        watcher?.stop()
        watcher = nil
        sessions = [:]
    }

    // MARK: Local changes (server queue)

    /// Something may have changed here (a save, the watcher, the app's settings): turn it into
    /// ops, apply what the store holds, and tell the peers.
    func localChanged() {
        guard started, !stopped else { return }
        let emitted = materializer.scan(name: name())
        // A folder that came into being with this pass (a dev folder just linked) is watched from now.
        watcher?.watch(trees: materializer.watchedTrees)
        applyStore()
        if !emitted.isEmpty { pumpAll() }
        fetchMissing()
        onChange?()
    }

    /// Writes what the store decided onto this Mac, and keeps what it replaced.
    private func applyStore() {
        let result = materializer.materialize(name: name())
        if !result.notices.isEmpty {
            let saved = SavedNotice(text: Self.notice(for: result.notices), at: (clock().timeIntervalSince1970 * 1000).rounded())
            notice = (saved.text, saved.at)
            if let data = try? JSONEncoder().encode(saved) { FleetStore.write(data, to: noticeURL) }
        }
        if result.failed, !retrying {
            retrying = true
            queue.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                guard let self else { return }
                self.retrying = false
                self.localChanged()
            }
        }
    }

    /// "Replaced AGENTS.md with Mac mini's. The old copy is in its history."
    static func notice(for replaced: [FleetMaterializer.Notice]) -> String {
        let from = replaced.first.map { $0.from.isEmpty ? "another Mac's" : "\($0.from)'s" } ?? "another Mac's"
        if replaced.count == 1, let unit = replaced.first?.unit {
            return "Replaced \(label(unit)) with \(from). The old copy is in its history."
        }
        return "Replaced \(replaced.count) copies on this Mac with \(from). The old ones are in their history."
    }

    private static func label(_ unit: String) -> String {
        switch FleetUnit.kind(of: unit) {
        case "instruction": FleetUnit.name(of: unit) ?? unit
        case "skill", "skillstate": "the \(FleetUnit.skillParts(of: unit)?.name ?? unit) skill"
        case "extension", "extmeta": "the \(FleetUnit.name(of: unit)?.split(separator: "/").first.map(String.init) ?? unit) extension"
        default: "the \(FleetUnit.name(of: unit) ?? unit) setting"
        }
    }

    // MARK: Links (server queue)

    /// The link to `peer` came up: say what this Mac holds, and send what it lacks.
    func linkUp(peer: UUID, client: RemoteHostClient) {
        guard !stopped, client.capabilities.contains(RemoteProtocol.fleetSyncCapability) else { return }
        let session = Session(peer: peer, client: client)
        sessions[peer] = session
        pump(session)
        onChange?()
    }

    func linkDown(peer: UUID) {
        guard sessions.removeValue(forKey: peer) != nil else { return }
        onChange?()
    }

    private func pumpAll(except peer: UUID? = nil) {
        for session in sessions.values where session.peer != peer { pump(session) }
    }

    private func pump(_ session: Session) {
        guard sessions[session.peer] === session else { return }
        if session.running {
            session.again = true
            return
        }
        session.running = true
        Task { await self.run(session) }
    }

    private func run(_ session: Session) async {
        let failed = Flag()
        repeat {
            await hop { session.again = false }
            do {
                if await hop({ !session.helloed }) {
                    let ours = await hop { self.store.vector }
                    let theirs = try await session.client.fleetSyncState(.hello(vector: ours))
                    await hop {
                        session.peerVector = Self.merged(session.peerVector, theirs)
                        session.helloed = true
                    }
                }
                try await push(to: session)
                await fetchMissingNow()
            } catch {
                failed.set()
                await hop { session.again = false }
            }
        } while await hop({ session.again && self.sessions[session.peer] === session })
        await hop {
            session.running = false
            // A failed hello is tried again at the next link; a link that works is one session.
            if failed.isSet { session.helloed = false }
            self.onChange?()
        }
    }

    private final class Flag: @unchecked Sendable {
        private(set) var isSet = false
        func set() { isSet = true }
    }

    /// Sends the ops the peer lacks until it holds them all.
    private func push(to session: Session) async throws {
        while true {
            guard let batch = await hop({ () -> [FleetOp]? in
                guard self.sessions[session.peer] === session else { return nil }
                let ops = self.store.ops(after: session.peerVector)
                return ops.isEmpty ? nil : ops
            }) else { return }
            let theirs = try await session.client.fleetSyncState(batch.count == 1 ? .op(batch[0]) : .ops(batch))
            let progressed = await hop { () -> Bool in
                let before = session.peerVector
                session.peerVector = Self.merged(session.peerVector, theirs)
                return session.peerVector != before
            }
            guard progressed else { return }
        }
    }

    static func merged(_ a: FleetVersionVector, _ b: FleetVersionVector) -> FleetVersionVector {
        var result = a
        for (mac, seq) in b.seqs where seq > result[mac] { result[mac] = seq }
        return result
    }

    // MARK: Serving a peer (server queue)

    /// Answers a sync request that arrived from `peer` on a connection authenticated as it.
    func serve(_ request: FleetSyncRequest, from peer: UUID) -> Result<FleetSyncReply, FleetSyncRefusal> {
        guard !stopped else { return .failure(FleetSyncRefusal(code: FleetProtocol.Code.off, message: "Fleet is off.")) }
        switch request {
        case .hello(let vector):
            if let session = sessions[peer] {
                session.peerVector = Self.merged(session.peerVector, vector)
                if !store.vector.seqs.allSatisfy({ session.peerVector[$0.key] >= $0.value }) { pump(session) }
            }
            return .success(.state(vector: store.vector))
        case .ops(let ops):
            take(ops, from: peer)
            return .success(.state(vector: store.vector))
        case .op(let op):
            take([op], from: peer)
            return .success(.state(vector: store.vector))
        case .blob(let hash, let offset):
            guard let chunk = store.blobChunk(hash, offset: offset, length: FleetSyncProtocol.blobChunkBytes) else {
                return .failure(FleetSyncRefusal(code: FleetSyncProtocol.Code.notFound, message: "That blob isn't here."))
            }
            return .success(.blob(hash: hash, offset: offset, total: chunk.total, data: chunk.data))
        }
    }

    private func take(_ ops: [FleetOp], from peer: UUID) {
        var stored = false
        for op in ops {
            switch store.receive(op) {
            case .stored:
                stored = true
                sessions[peer]?.peerVector[op.mac] = max(sessions[peer]?.peerVector[op.mac] ?? 0, op.seq)
            case .duplicate:
                sessions[peer]?.peerVector[op.mac] = max(sessions[peer]?.peerVector[op.mac] ?? 0, op.seq)
            case .gap, .invalid:
                break
            }
        }
        guard stored else { return }
        applyStore()
        pumpAll(except: peer)
        fetchMissing()
        onChange?()
    }

    // MARK: Blobs (server queue)

    private func fetchMissing() {
        guard !stopped, !store.missingBlobs().isEmpty, !sessions.isEmpty else { return }
        Task { await self.fetchMissingNow() }
    }

    /// Fetches each blob the store's winners need from the first connected peer that has it.
    private func fetchMissingNow() async {
        let wanted = await hop { () -> [(hash: String, size: Int, clients: [RemoteHostClient])] in
            let clients = self.sessions.values.map(\.client)
            let missing = self.store.missingBlobs().filter { !self.fetching.contains($0.hash) }
            for blob in missing { self.fetching.insert(blob.hash) }
            return missing.map { ($0.hash, $0.size, clients) }
        }
        var arrived = false
        for blob in wanted {
            for client in blob.clients {
                guard let data = try? await client.fleetBlob(hash: blob.hash, size: blob.size) else { continue }
                if await hop({ self.store.putBlob(data, named: blob.hash) }) { arrived = true; break }
            }
            await hop { self.fetching.remove(blob.hash) }
        }
        if arrived { await hop { self.localChanged() } }
    }

    // MARK: Status (server queue)

    /// Where sync stands with each paired Mac. `peers`: every Mac, oldest pairing first, and whether its link is up.
    func status(peers: [(hostID: UUID, name: String, connected: Bool)]) -> FleetSyncStatus {
        let rows = peers.map { peer -> FleetSyncStatus.Peer in
            guard peer.connected, let session = sessions[peer.hostID] else { return .init(hostID: peer.hostID, name: peer.name, state: .offline) }
            let current = session.helloed && !session.running && session.peerVector == store.vector && store.missingBlobs().isEmpty
            return .init(hostID: peer.hostID, name: peer.name, state: current ? .inSync : .catchingUp)
        }
        let now = clock().timeIntervalSince1970 * 1000
        let text = notice.flatMap { now - $0.at < Self.noticeLifetime * 1000 ? $0.text : nil }
        return FleetSyncStatus(peers: rows, notice: text)
    }

    // MARK: Queue hop

    private func hop<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }
}

/// A sync request this Mac refuses, for the error reply.
struct FleetSyncRefusal: Error, Equatable {
    var code: String
    var message: String
}
