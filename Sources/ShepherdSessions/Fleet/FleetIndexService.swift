import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The host's content indexing (slice 4b): a `FleetContentIndex` for each space's checkout, the manifest each repository
/// makes of them, a stream of those manifests to every peer Mac, and what the peers sent back, kept on disk.
///
/// It indexes only while Fleet is on and at least one Mac is paired (`setActive`): a host with nobody to tell has no reason
/// to read a repository's files. Manifests go over the same peer links as everything else, and only to a Mac (a
/// `FleetAccess.member` connection): a phone or the shared token is never offered `fleet.snapshot.v1`.
/// Everything here but the indexes themselves belongs to the server queue; each index has its own utility queue and reports
/// back by hopping.
final class FleetIndexService: @unchecked Sendable {
    /// What the host tells the service about its spaces. All on the server queue.
    struct Host {
        var spaces: () -> [Space]
        /// A space's own changes to what stays home (`fleet.snapshotExcludes.<spaceID>`); none until Settings sets them (slice 4c).
        var overrides: (SpaceID) -> FleetExclusions.Overrides = { _ in FleetExclusions.Overrides() }
    }

    private final class Root {
        let space: SpaceID
        var name: String
        var repo: String
        let index: FleetContentIndex
        var state: FleetContentIndex.State = .loading
        var files = 0
        /// Its contributions are being moved to another repository's manifest, or taken out of this one's.
        var moving = false
        var removing = false
        init(space: SpaceID, name: String, repo: String, index: FleetContentIndex) {
            (self.space, self.name, self.repo, self.index) = (space, name, repo, index)
        }
    }

    private struct PeerRepo {
        var acked: (generation: UInt64, seq: UInt64)?
        var probed = false
        var forceFull = false
        /// Fulls refused in a row; two and the repository is left alone until the link comes up again.
        var refused = 0
        var pending: [FleetRepoManifestUpdate] = []
    }

    private final class Session {
        let peer: UUID
        let client: RemoteHostClient
        var repos: [String: PeerRepo] = [:]
        var running = false
        var again = false
        init(peer: UUID, client: RemoteHostClient) { (self.peer, self.client) = (peer, client) }
    }

    private let queue: DispatchQueue
    private let directory: URL
    private let clock: @Sendable () -> Date
    private let persistQueue = DispatchQueue(label: "shepherd.fleet.index.persist", qos: .utility)
    /// Set once by the host; indexing that was waiting for it starts.
    var host: Host? { didSet { reconcile() } }
    /// Server queue: what the app draws of the index changed.
    var onChange: (() -> Void)?
    /// Tests: how each index classifies files, how often it checks itself, and how long changes wait to be sent.
    var classifier: FleetGitClassifier = .git
    var verifyInterval: TimeInterval = 300
    var pushDelay: TimeInterval = 0.1
    var eventLatency: TimeInterval = 0.05

    private(set) var isActive = false
    private var roots: [String: Root] = [:]
    private var manifests: [String: FleetLocalManifest] = [:]
    private var peerCopies: FleetPeerManifests
    private var sessions: [UUID: Session] = [:]
    private var pushScheduled = false
    private var saveScheduled = false
    private var notifyScheduled = false
    private var timer: DispatchSourceTimer?

    private var rootsDirectory: URL { directory.appendingPathComponent("roots", isDirectory: true) }
    private var peersDirectory: URL { directory.appendingPathComponent("peers", isDirectory: true) }

    init(queue: DispatchQueue, directory: URL, clock: @escaping @Sendable () -> Date = Date.init) {
        self.queue = queue
        self.directory = directory
        self.clock = clock
        peerCopies = FleetPeerManifests.load(from: directory.appendingPathComponent("peers", isDirectory: true))
    }

    // MARK: Lifecycle (server queue)

    /// Fleet is on and a Mac is paired (or isn't any more).
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        if on {
            reconcile()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + verifyInterval, repeating: verifyInterval, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.verifyAll() }
            timer.resume()
            self.timer = timer
            for session in sessions.values { pump(session) }
        } else {
            timer?.cancel()
            timer = nil
            // Each index saves where it got to before this returns (a scan in progress ends at its next directory), so what
            // the next start replays from is on disk.
            for root in roots.values {
                root.index.requestStop()
                root.index.queue.sync { [index = root.index] in index.stop() }
            }
            roots = [:]
            manifests = [:]
        }
        notify()
    }

    func stop() {
        setActive(false)
        sessions = [:]
        flushSaves(wait: true)
    }

    /// The spaces changed (or the service started): index the checkouts that need it, drop the rest.
    func reconcile() {
        guard isActive, let host = host?.spaces() else { return }
        var wanted: [String: (space: Space, repo: String)] = [:]
        for space in host where FleetSpacesSource.syncs(space) {
            let expanded = (space.path as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let real = FleetContentIndex.realPath(expanded)
            if wanted[real] == nil { wanted[real] = (space, FleetSnapshotProtocol.repoName(key: space.repoKey, space: space.id.rawValue)) }
        }
        for (path, root) in roots where wanted[path] == nil && !root.removing { erase(root, at: path) }
        for (path, entry) in wanted {
            let rules = FleetExclusions(overrides: self.host?.overrides(entry.space.id) ?? FleetExclusions.Overrides())
            if let root = roots[path] {
                guard !root.removing else { continue }
                root.name = entry.space.name
                if root.repo != entry.repo, !root.moving { move(root, to: entry.repo) }
                root.index.queue.async { [index = root.index] in index.setExclusions(rules) }
            } else {
                add(path: path, space: entry.space, repo: entry.repo, rules: rules)
            }
        }
        notify()
    }

    private func add(path: String, space: Space, repo: String, rules: FleetExclusions) {
        let name = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let index = FleetContentIndex(root: path, storage: rootsDirectory.appendingPathComponent(name, isDirectory: true), exclusions: rules,
                                      classifier: classifier, latency: eventLatency, clock: clock)
        let root = Root(space: space.id, name: space.name, repo: repo, index: index)
        roots[path] = root
        index.onDelta = { [weak self, weak root, weak index] added, removed in
            let files = index?.entries.count ?? 0
            self?.queue.async { if let root { self?.applied(added, removed, files: files, to: root) } }
        }
        index.onState = { [weak self, weak root, weak index] in
            guard let index else { return }
            let (state, files) = (index.state, index.entries.count)
            self?.queue.async { if let root { root.state = state; root.files = files; self?.notify() } }
        }
        index.onDrift = { reason in ShepherdLog.info("fleet index \(path): \(reason)") }
        index.queue.async { index.start() }
    }

    /// A root's repository (its origin) became known or changed: what it holds belongs to the new one. The change is made
    /// where the index's own deltas are, in order, so none is counted for the wrong manifest.
    private func move(_ root: Root, to repo: String) {
        root.moving = true
        root.index.queue.async { [weak self, index = root.index] in
            let hashes = index.allHashes
            self?.queue.async {
                guard let self else { return }
                self.manifests[root.repo]?.remove(hashes)
                self.manifest(for: repo).add(hashes)
                root.repo = repo
                root.moving = false
                self.schedulePush()
                self.reconcile()
            }
        }
    }

    /// A space's checkout is no longer one this host indexes: its hashes leave the manifest and its index is deleted.
    private func erase(_ root: Root, at path: String) {
        root.removing = true
        root.index.queue.async { [weak self, index = root.index] in
            let hashes = index.allHashes
            index.erase()
            self?.queue.async {
                guard let self else { return }
                self.manifests[root.repo]?.remove(hashes)
                if self.roots[path] === root { self.roots[path] = nil }
                self.schedulePush()
                self.notify()
                self.reconcile()
            }
        }
    }

    private func manifest(for repo: String) -> FleetLocalManifest {
        if let existing = manifests[repo] { return existing }
        let created = FleetLocalManifest(repo: repo)
        manifests[repo] = created
        return created
    }

    private func applied(_ added: [FleetHash], _ removed: [FleetHash], files: Int, to root: Root) {
        guard isActive, roots.values.contains(where: { $0 === root }) else { return }
        root.files = files
        let manifest = manifest(for: root.repo)
        manifest.remove(removed)
        manifest.add(added)
        schedulePush()
    }

    private func verifyAll() {
        for root in roots.values { root.index.queue.async { [index = root.index] in index.verify(reclassifying: true) } }
    }

    // MARK: Status

    func status() -> FleetIndexStatus? {
        guard isActive else { return nil }
        // A folder that isn't a git checkout has nothing to index and nothing to say.
        let repos = roots.values.filter { $0.state != .notGit }.sorted { ($0.name, $0.repo) < ($1.name, $1.repo) }.map {
            FleetIndexStatus.Repo(repo: $0.repo, name: $0.name, files: $0.files, ready: $0.state == .ready, tooLarge: $0.state == .tooLarge)
        }
        return FleetIndexStatus(indexing: roots.values.contains { $0.state == .loading || $0.state == .scanning }, repos: repos)
    }

    private func notify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.notifyScheduled = false
            self?.onChange?()
        }
    }

    // MARK: Sending (server queue)

    /// A link to `peer` came up: it is told where each manifest stands, and sent whatever it lacks.
    func linkUp(peer: UUID, client: RemoteHostClient) {
        guard client.capabilities.contains(RemoteProtocol.fleetSnapshotCapability) else { return }
        let session = Session(peer: peer, client: client)
        sessions[peer] = session
        pump(session)
    }

    func linkDown(peer: UUID) { sessions[peer] = nil }

    /// A peer left the fleet: what it sent goes, in memory and on disk.
    func forget(peer: UUID) {
        sessions[peer] = nil
        peerCopies.forget(peer)
        FleetPeerManifests.erase(peer, in: peersDirectory)
    }

    private func schedulePush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        queue.asyncAfter(deadline: .now() + pushDelay) { [weak self] in
            guard let self else { return }
            self.pushScheduled = false
            guard self.isActive else { return }
            for manifest in self.manifests.values { manifest.flush() }
            for session in self.sessions.values { self.pump(session) }
        }
    }

    private func pump(_ session: Session) {
        guard isActive else { return }
        if session.running { session.again = true; return }
        session.running = true
        Task { [weak self] in
            while let self {
                guard let step = await self.onQueue({ self.next(for: session) }) else { return }
                let ack = try? await session.client.fleetRepoManifest(step)
                await self.onQueue { self.acked(ack, to: step, in: session) }
                if ack == nil { return }
            }
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }

    /// The next message this peer needs, or nil when it has everything (which ends the pump).
    private func next(for session: Session) -> FleetRepoManifestUpdate? {
        guard isActive, sessions[session.peer] === session else { session.running = false; return nil }
        for repo in manifests.keys.sorted() {
            guard let manifest = manifests[repo], manifest.manifest.count > 0 || manifest.seq > 0 else { continue }
            var state = session.repos[repo] ?? PeerRepo()
            defer { session.repos[repo] = state }
            if state.refused >= 2 { continue }
            if state.pending.isEmpty {
                if !state.probed {
                    state.probed = true
                    return manifest.headUpdate()
                }
                if state.forceFull || state.acked == nil {
                    state.pending = manifest.fullUpdates()
                    state.forceFull = false
                } else if let acked = state.acked, acked.generation != manifest.generation || acked.seq != manifest.seq {
                    state.pending = manifest.updates(after: acked) ?? manifest.fullUpdates()
                }
            }
            if !state.pending.isEmpty { return state.pending.removeFirst() }
        }
        session.running = false
        if session.again {
            session.again = false
            pump(session)
        }
        return nil
    }

    private func acked(_ ack: FleetRepoManifestAck?, to step: FleetRepoManifestUpdate, in session: Session) {
        guard let ack else {
            // The link failed: the next one starts with a probe again.
            session.running = false
            session.repos = [:]
            return
        }
        guard sessions[session.peer] === session else { return }
        var state = session.repos[step.repo] ?? PeerRepo()
        defer { session.repos[step.repo] = state }
        if ack.resend {
            let wasFull = step.kind == .full
            state.pending = []
            state.acked = nil
            state.forceFull = true
            if wasFull { state.refused += 1 } else { resyncRequested(step.repo) }
            return
        }
        switch step.kind {
        case .full:
            if step.part == step.parts - 1 { state.acked = (ack.generation, ack.seq); state.refused = 0 }
        case .delta:
            if ack.generation == step.generation, ack.seq == step.seq { state.acked = (ack.generation, ack.seq) } else { state.pending = []; state.forceFull = true }
        case .head:
            state.acked = (ack.generation, ack.seq)
        }
    }

    /// A peer's copy didn't line up with what this Mac announced. Whatever the cause, the indexes behind that manifest are
    /// looked at again: a sample of them against the disk, and a rescan if they were wrong.
    private func resyncRequested(_ repo: String) {
        for root in roots.values where root.repo == repo { root.index.queue.async { [index = root.index] in index.verify(sample: 256) } }
    }

    // MARK: Receiving (server queue)

    /// A peer's step of one of its manifests.
    func received(_ update: FleetRepoManifestUpdate, from peer: UUID) -> FleetRepoManifestAck {
        let ack = peerCopies.receive(update, from: peer)
        scheduleSave()
        return ack
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.saveScheduled = false
            self?.flushSaves()
        }
    }

    /// Writes the copies that changed, off the server queue; `wait` for the host that is stopping, which has to leave them on disk.
    private func flushSaves(wait: Bool = false) {
        guard let job = peerCopies.takeSave(to: peersDirectory) else { return }
        if wait { persistQueue.sync(execute: job) } else { persistQueue.async(execute: job) }
    }

    // MARK: Reading (server queue)

    /// What `peer` holds of `repo`, as it last told this Mac.
    func manifest(of peer: UUID, repo: String) -> FleetManifest? { peerCopies.manifest(of: peer, repo: repo) }

    func peerHead(of peer: UUID, repo: String) -> FleetManifestHead? { peerCopies.copy(of: peer, repo: repo)?.head }

    func peerRepos(_ peer: UUID) -> [String] { peerCopies.repos(of: peer) }

    /// What this Mac holds of `repo`, as of the last flush.
    func localManifest(repo: String) -> FleetManifest? { manifests[repo]?.manifest }

    func localHead(repo: String) -> FleetManifestHead? { manifests[repo]?.head }

    /// Tests: the index of the checkout at `path`.
    func index(at path: String) -> FleetContentIndex? {
        roots[FleetContentIndex.realPath(path)]?.index
    }
}
