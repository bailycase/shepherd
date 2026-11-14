import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The branch names dispatches have chosen and not yet made (`FleetDispatch.claimedBranches`).
final class FleetBranchClaims: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    /// Chooses a name with `pick` (given the names already claimed) and claims it, as one step.
    func claim(_ pick: (Set<String>) -> String) -> String {
        lock.withLock {
            let name = pick(names)
            names.insert(name)
            return name
        }
    }

    func release(_ name: String) { lock.withLock { _ = names.remove(name) } }
}

/// A number read from any thread.
final class FleetCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A dispatch the host refused, with the code a thread (or the log) reads.
struct FleetDispatchRefusal: Error, Equatable {
    var code: String
    var message: String
    var detail: String?
}

/// What the dispatch engine needs of the server that hosts it: the threads, the settings, and how to
/// start, stop and message a thread. Closures, so the engine holds no reference to the server.
struct FleetDispatchHost: @unchecked Sendable {
    /// The workspace as the server holds it (any thread).
    var state: @Sendable () -> ShepherdState = { ShepherdState() }
    /// The fleet policy settings the app last reported (`fleetThreadsCanSend`, `fleetThreadCap`, the weights).
    var settings: @Sendable () -> HostSettings? = { nil }
    /// Delivers `text` to a thread as a task (`pushMessage`): false when its pi isn't connected.
    var wakeParent: @Sendable (AgentID, String) async -> Bool = { _, _ in false }
    /// Starts a thread the way a remote client's create does (`onRemoteCreateAgent`).
    var createThread: @Sendable (RemoteCreateAgentRequest) async -> Result<AgentID, RemoteCreateAgentError> = { _ in
        .failure(RemoteCreateAgentError("host cannot create threads"))
    }
    /// Stops a thread's turn, as Stop does (server queue).
    var stopThread: @Sendable (AgentID) -> Void = { _ in }
    /// Sends a message into a thread's queue; false when it can't take one.
    var messageThread: @Sendable (AgentID, String, NativeThreadDelivery) async -> Bool = { _, _, _ in false }
    /// What a thread last said and what it is doing (server queue); nil when it is gone.
    var threadFacts: @Sendable (AgentID) -> FleetThreadFacts? = { _ in nil }
    /// The folders that may hold a checkout of a repository: this Mac's spaces, the main checkout of each thread's worktree, what the
    /// content index reads and where spaces were bound before (server queue).
    var repoPlaces: @Sendable () -> [FleetRepoFinder.Place] = { [] }
    /// Puts a checkout in the workspace as a space (server queue): the one already at that path, else a new one. Nil when it couldn't.
    var bindSpace: @Sendable (FleetSpaceBinding) -> Space? = { _ in nil }
}

/// A checkout a dispatch is to work in, as a space (`FleetDispatchHost.bindSpace`).
struct FleetSpaceBinding: Sendable {
    /// The fleet's space for the repository, when the sender named one: the checkout binds to it, so it is one space on every Mac.
    var id: SpaceID?
    var name: String
    var path: String
    var repoKey: String
    var worktreeBase: String?
}

/// A dispatched thread as the host that runs it reads it.
struct FleetThreadFacts: Sendable {
    var status: AgentStatus
    var waitingOn: String?
    /// The text of the thread's last assistant message.
    var lastText: String?
    var worktree: String?
}

/// Dispatch (`fleet.dispatch.v1`): a thread on this Mac sends work to another, which makes a fresh
/// worktree at the pinned commit and runs a thread there; the result comes back as a task for the
/// parent. Every piece of state belongs to the server queue. One engine plays both sides: the sender's
/// records (`dispatches.json`) and the receiver's (`dispatches-inbound.json`, the idempotency index).
///
/// A dispatch to this very Mac is the same path with the link replaced by a direct call, so Auto can
/// keep work here when no other Mac has more room. Nothing here re-sends by itself after a restart
/// (docs/rules.md, Features that act on their own): unplaced records come back held.
final class FleetDispatch: @unchecked Sendable {
    /// What a restart does to a record: the held ones stay held, `heldRestart` explains why.
    struct Inbound: Codable, Hashable {
        var record: FleetDispatchRecord
        /// The thread's next idle is a result to send back.
        var expectsResult = true
        /// The thread has worked since the dispatch started or was last messaged.
        var startedWorking = false
        /// What the sender hasn't been told of.
        var unsent = false
        /// The Mac's own folder for the thread's worktree, for reading branch facts.
        var worktree: String?
        var acceptedAt: Double = 0
        /// The folder a clone for this dispatch is being made in (made by it, so it is the one thing a restart may remove).
        var cloneDirectory: String?
    }

    let queue: DispatchQueue
    let hostID: UUID
    let clock: @Sendable () -> Date
    var host = FleetDispatchHost()
    /// This Mac's name as other Macs see it.
    var hostName: () -> String = { "This Mac" }
    /// The paired Macs: id, name, whether the link is up.
    var peers: () -> [(hostID: UUID, name: String, connected: Bool)] = { [] }
    /// The connected link to a Mac.
    var client: (UUID) -> RemoteHostClient? = { _ in nil }
    var pressure: FleetPressure
    /// Server queue: the Fleet page should read again.
    var onChange: (() -> Void)?
    /// Server queue: a thread that was there to fix something on the Mac `hostID` ended (`FleetDispatchRecord.fixes`).
    var onFixEnded: ((UUID) -> Void)?
    /// Fix dispatches whose end has been told of.
    var fixesEnded: Set<UUID> = []

    let directory: URL
    var outbound: [UUID: FleetDispatchRecord] = [:]
    var inbound: [UUID: Inbound] = [:]
    /// Branches chosen for dispatches whose worktree isn't made yet. `prepare` runs off the queue, so two dispatches
    /// of one title would both see the name free; the claim is made under this lock and held until the thread exists.
    let claimedBranches = FleetBranchClaims()
    /// Dispatches a create is on its way for (never twice at once).
    var sending: Set<UUID> = []
    var delivering: Set<UUID> = []
    var placing: Set<UUID> = []
    /// Threads the person started whose first placement is under way (`dispatchUserThread`): one that stays here is dropped.
    var firstPlacements: Set<UUID> = []
    /// Pushes to the sending Mac on their way (never twice at once).
    var pushing: Set<UUID> = []
    /// Tool calls waiting on a placement that is under way, answered together.
    var waiters: [UUID: [(Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void]] = [:]
    var timer: DispatchSourceTimer?
    var stopped = false
    /// The content index (`fleet.snapshot.v1`): the sender's source of a snapshot, and where the receiver looks for files it already holds.
    var indexService: FleetIndexService?
    /// What the sender worked out for each dispatch whose snapshot is on its way (in memory: nothing resumes it after a restart).
    var snapshots: [UUID: FleetSnapshotSender.Built] = [:]
    /// Where each dispatch was pinned (the checkout it is read from).
    var pins: [UUID: FleetDispatchGit.Pin] = [:]
    var transferring: Set<UUID> = []
    /// Receiver: the pieces of each snapshot that is arriving.
    var snapshotsIn: [UUID: SnapshotIn] = [:]
    /// Tests: what the receiver did to build each worktree, and a way to change a content on the wire.
    var applyStats: [UUID: FleetSnapshotApply.Stats] = [:]
    var senderLog: [UUID: (phases: [String], git: [String])] = [:]
    var wire: (@Sendable (FleetBlobChunk) async throws -> FleetBlobChunk)?
    /// Tests: where a snapshot warns and where it is refused.
    var caps: (warn: UInt64, refuse: UInt64) = (FleetSnapshotCap.warnAbove, FleetSnapshotCap.refuseAbove)
    /// How long each snapshot took on this Mac as the sender: working it out and pushing it (milliseconds).
    var timings: [UUID: (build: Int, transfer: Int)] = [:]
    /// When the sending record was last written for progress (progress is saved at most twice a second).
    var progressSavedAt: Double = 0
    /// The spare of each repository and what dispatches sent this Mac (`<directory>/spares`, `<directory>/snapshot-blobs`).
    let spares: FleetSpares
    let blobs: FleetSnapshotBlobs
    /// Finds a checkout of a repository this Mac already has, and keeps which it chose (slice 4f).
    let finder: FleetRepoFinder
    /// Receiver: the clone running for each dispatch, so Stop can end it, and the ones started (tests).
    var clones: [UUID: FleetRepoClone] = [:]
    var cloneCount = 0
    /// Receiver: when each clone's progress was last pushed (at most twice a second).
    var clonePushedAt: [UUID: Double] = [:]
    /// Where a clone goes first: `~/Developer`, when it is there. Tests point it at a scratch folder.
    var developerFolder: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer", isDirectory: true)
    /// Sender: dispatches that carry the repository itself, because the target couldn't clone it from origin.
    var repoBundles: Set<UUID> = []
    /// Dispatches whose repository was asked for again and whose new create the target hasn't answered yet: a second telling of the failure
    /// that caused it (the push and the answer to a status question both bring it) is the same one, already answered.
    var awaitingRepository: Set<UUID> = []
    /// Dispatches whose target has the repository but lacks the commit: the bundle is only what it lacks, not the whole repository.
    var incrementalBundles: Set<UUID> = []
    private let reservedCount = FleetCounter()
    /// Told whenever the count of promised places changes (the host reads it for its samples).
    var reservedSink: FleetCounter?

    static let outboundFile = "dispatches.json"
    static let inboundFile = "dispatches-inbound.json"
    /// Finished records kept, newest first.
    static let keptFinished = 100
    /// While anything waits, the engine looks again this often.
    static let evaluateInterval: TimeInterval = 3
    /// The longest a title is kept.
    static let titleLimit = 120

    init(queue: DispatchQueue, directory: URL, hostID: UUID, pressure: FleetPressure, clock: @escaping @Sendable () -> Date = Date.init) {
        self.queue = queue
        self.directory = directory
        self.hostID = hostID
        self.pressure = pressure
        self.clock = clock
        spares = FleetSpares(directory: directory.appendingPathComponent("spares", isDirectory: true))
        blobs = FleetSnapshotBlobs(directory: directory.appendingPathComponent("snapshot-blobs", isDirectory: true))
        finder = FleetRepoFinder(directory: directory, clock: clock)
    }

    /// The receiver's state for one snapshot that is arriving.
    final class SnapshotIn: @unchecked Sendable {
        let header: FleetSnapshotHeader
        var space: Space?
        let requestedBranch: String?
        let began = ContinuousClock.now
        var parts: [Int: FleetSnapshotPart] = [:]
        /// Where the repository comes from, when this Mac has no checkout of it yet (`space` is nil until it has one).
        var repo: FleetRepoSource?
        /// Everything is in, and the build waits for a checkout (a clone that is running or a bundle to clone from).
        var pendingBuild = false
        /// Looking for a checkout this Mac already has is over.
        var lookedUp = false
        var manifest: FleetSnapshotManifest?
        /// The contents still missing, once the manifest is whole; nil before. `needOrder` is the order they are asked for.
        var needs: Set<FleetHash>?
        var needOrder: [FleetHash] = []
        var computing = false
        var building = false
        /// Milliseconds since the create arrived at each step of the arrival (parts whole, contents worked out, contents in), for the log.
        var events: [String] = []
        func mark(_ name: String) { events.append("\(name) \(Int((ContinuousClock.now - began) / .milliseconds(1)))") }
        /// The branch name, chosen while the snapshot is still arriving (its git calls then overlap the transfer).
        var branch: Task<String, Never>?
        init(header: FleetSnapshotHeader, space: Space?, requestedBranch: String?) { (self.header, self.space, self.requestedBranch) = (header, space, requestedBranch) }

        /// Parts held, counted from the first with none missing.
        var held: Int {
            var count = 0
            while parts[count] != nil { count += 1 }
            return count
        }
    }

    var now: Double { (clock().timeIntervalSince1970 * 1000).rounded() }

    /// Places this host has promised dispatches that haven't started yet (`FleetPressureSample.reserved`): readable from any thread.
    var reserved: Int { reservedCount.value }

    // MARK: Persistence

    /// Loads the records, and makes a restart safe (Q9): nothing unplaced resumes, running work is
    /// re-followed (`reconcile`), nothing is ever sent again by itself.
    func load() {
        if let data = try? Data(contentsOf: directory.appendingPathComponent(Self.outboundFile)),
           let saved = try? JSONDecoder().decode([FleetDispatchRecord].self, from: data) {
            outbound = Dictionary(saved.map { ($0.id, $0) }) { first, _ in first }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(Self.inboundFile)),
           let saved = try? JSONDecoder().decode([Inbound].self, from: data) {
            inbound = Dictionary(saved.map { ($0.record.id, $0) }) { first, _ in first }
        }
        // A fix that ended before this host started is not news.
        fixesEnded = Set(outbound.values.filter { !$0.fixes.isEmpty && Self.fixEnded.contains($0.state) }.map(\.id))
        var changed = false
        for (id, record) in outbound {
            switch record.state {
            case .placing, .waitingRoom, .waitingWake, .heldLimit:
                outbound[id]?.state = .heldRestart
                outbound[id]?.updatedAt = now
                changed = true
            default: break
            }
        }
        // A create that was still being made when the host went down has no thread to follow.
        for (id, entry) in inbound where entry.record.state == .preparing {
            // A clone that was running has left a folder this host made for it: it goes, and nothing is bound to it.
            if let folder = entry.cloneDirectory { FleetDispatch.discardClone(folder) }
            inbound[id]?.cloneDirectory = nil
            inbound[id]?.record.clone = nil
            inbound[id]?.record.state = .failed
            inbound[id]?.record.failure = FleetDispatchCode.snapshotFailed
            inbound[id]?.record.failureDetail = "restarted"
            inbound[id]?.unsent = true
            changed = true
        }
        if changed { save() }
        updateReserved()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        prune()
        notifyFixesEnded()
        if let data = try? encoder.encode(outbound.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }) {
            FleetStore.write(data, to: directory.appendingPathComponent(Self.outboundFile))
        }
        if let data = try? encoder.encode(inbound.values.sorted { ($0.record.createdAt, $0.record.id.uuidString) < ($1.record.createdAt, $1.record.id.uuidString) }) {
            FleetStore.write(data, to: directory.appendingPathComponent(Self.inboundFile))
        }
        updateReserved()
        onChange?()
    }

    /// A thread that was there to fix something on a Mac (`FleetDispatchRecord.fixes`) has ended, however it did: the Mac is asked to look at
    /// itself again, once per dispatch. A record that had already ended when this host started is not news.
    private func notifyFixesEnded() {
        for (id, record) in outbound where !record.fixes.isEmpty && Self.fixEnded.contains(record.state) && !fixesEnded.contains(id) {
            fixesEnded.insert(id)
            if let target = record.targetHostID { onFixEnded?(target) }
        }
    }

    private static let fixEnded: Set<FleetDispatchState> = [.delivering, .done, .failed, .cancelled]

    private func prune() {
        // A clone is something a dispatch that is still preparing is doing.
        for (id, record) in outbound where record.clone != nil && record.state != .preparing { outbound[id]?.clone = nil }
        func trim<T>(_ items: inout [UUID: T], finished: (T) -> Bool, order: (T) -> Double) {
            let done = items.filter { finished($0.value) }.sorted { order($0.value) > order($1.value) }
            for (id, _) in done.dropFirst(Self.keptFinished) { items[id] = nil }
        }
        trim(&outbound, finished: { !$0.state.isLive }, order: \.updatedAt)
        trim(&inbound, finished: { !$0.record.state.isLive && !$0.unsent }, order: { $0.record.updatedAt })
    }

    private func updateReserved() {
        let cutoff = now - FleetDispatchProtocol.reservationLifetime * 1000
        let count = inbound.values.filter { entry in
            entry.record.state == .preparing || (entry.record.state == .running && !entry.startedWorking && entry.acceptedAt > cutoff)
        }.count
        reservedCount.value = count
        reservedSink?.value = count
    }

    // MARK: Reading (server queue)

    /// The Dispatches log: this Mac's sent dispatches, newest first, without their text.
    func log() -> [FleetDispatchRecord] {
        outbound.values.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }.map(\.summary)
    }

    func record(_ id: UUID) -> FleetDispatchRecord? { outbound[id] }

    /// The dispatch `key` names for `agentID`, as the extension asked (a UUID or the tool call's own id).
    func dispatch(forKey key: String, agent agentID: AgentID) -> FleetDispatchRecord? {
        let id = Self.identifier(key: key, agent: agentID)
        guard let record = outbound[id], record.parentAgentID == agentID else { return nil }
        return record
    }

    /// The id a thread's `key` stands for: the key itself when it is a UUID, otherwise a stable id made from
    /// the thread and the key, so a retried tool call names the dispatch it already made and no thread can
    /// name another's.
    static func identifier(key: String, agent: AgentID) -> UUID {
        if let uuid = UUID(uuidString: key.trimmingCharacters(in: .whitespacesAndNewlines)) { return uuid }
        let digest = SHA256.hash(data: Data("fleet-dispatch:\(agent.rawValue):\(key)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Lifecycle

    func start() {
        stopped = false
        load()
        scheduleEvaluation()
        reconcile()
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        // A clone that is running ends and takes its folder with it.
        for job in clones.values { job.cancel() }
    }

    /// The links changed or a sample came in: look at everything that waits.
    func linkChanged() {
        guard !stopped else { return }
        evaluate()
        reconcile()
        pushPending()
    }

    private var hasWork: Bool {
        outbound.values.contains { [.waitingRoom, .waitingWake, .heldLimit, .delivering, .preparing, .running].contains($0.state) }
            || inbound.values.contains { $0.unsent || $0.record.state == .delivering }
    }

    func scheduleEvaluation() {
        guard !stopped, timer == nil, hasWork else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.evaluateInterval, repeating: Self.evaluateInterval, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.evaluate()
            self.pushPending()
            if !self.hasWork { self.timer?.cancel(); self.timer = nil }
        }
        timer = source
        source.resume()
    }

    /// Looks again at every record that waits: a Mac with room, a Mac that woke, a place under the cap,
    /// a result for a parent whose pi is back. Never re-sends a record the person has to decide on
    /// (`heldRestart`).
    func evaluate() {
        guard !stopped else { return }
        let waiting = outbound.values.sorted { $0.createdAt < $1.createdAt }
        for record in waiting {
            switch record.state {
            case .waitingRoom:
                if !placing.contains(record.id) { place(record.id, completion: nil) }
            case .waitingWake:
                if let target = record.targetHostID, isConnected(target) { send(record.id, completion: nil) }
            case .heldLimit:
                if canStart(record) { place(record.id, completion: nil) }
            case .delivering:
                deliverResult(record.id)
            default: break
            }
        }
        scheduleEvaluation()
    }

    func isConnected(_ hostID: UUID) -> Bool {
        hostID == self.hostID || peers().contains { $0.hostID == hostID && $0.connected }
    }

    // MARK: Sending (server queue)

    /// A thread's `fleet_dispatch`. Answers once the dispatch is placed and the target has taken it (or
    /// was found unable to), or at once when it waits or is held.
    func dispatch(from agentID: AgentID, key: String?, task: String, title: String?, host named: String?, model: String?, thinking: String?,
                  reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        guard host.settings()?.fleetThreadsCanSend == true else {
            return reply(.failure(.init(code: FleetDispatchCode.sendOff, message: "Threads can't send work to other Macs. Turn on Settings ▸ Fleet ▸ Threads can send work.")))
        }
        let id = key.map { Self.identifier(key: $0, agent: agentID) } ?? UUID()
        if let existing = outbound[id] {
            guard existing.parentAgentID == agentID else {
                return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That dispatch id belongs to another thread.")))
            }
            return reply(.success(existing))
        }
        if placing.contains(id) { waiters[id, default: []].append(reply); return }
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty, trimmedTask.utf8.count <= FleetDispatchProtocol.maxTaskBytes else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "The task is empty or longer than \(FleetDispatchProtocol.maxTaskBytes / 1024) KiB.")))
        }
        let state = host.state()
        guard let agent = state.agents.first(where: { $0.id == agentID }), let space = state.spaces.first(where: { $0.id == agent.spaceID }) else {
            return reply(.failure(.init(code: FleetDispatchCode.repoMissing, message: "This thread's project isn't a repository another Mac can find.")))
        }
        let cwd = state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd ?? space.path
        placing.insert(id)
        waiters[id, default: []].append(reply)
        let (spaceID, folder, known) = (space.id, space.path, space.repoKey)
        // The snapshot will need the commit's tree: it starts being listed the moment the commit is known, while the dispatch is placed.
        let prefetching = indexService != nil && (host.settings()?.fleetUncommitted ?? .sendThem) == .sendThem
        Task.detached { [weak self] in
            let pinned = FleetDispatchGit.pin(cwd: (cwd as NSString).expandingTildeInPath, prefetchingTree: prefetching)
            let origin = FleetDispatchGit.origin(cwd: (folder as NSString).expandingTildeInPath)
            // A repository with no origin is named by its first commit: another Mac can't clone it, so it is sent the repository itself.
            let key = known ?? FleetRepoKeys.localKey(folder: (folder as NSString).expandingTildeInPath)
            self?.queue.async {
                guard let self else { return }
                let waiting = self.waiters.removeValue(forKey: id) ?? []
                func answer(_ result: Result<FleetDispatchRecord, FleetDispatchRefusal>) { for done in waiting { done(result) } }
                guard let repoKey = key else {
                    self.placing.remove(id)
                    return answer(.failure(.init(code: FleetDispatchCode.repoMissing, message: "This thread's project has no origin remote and no commits, so no other Mac can find its repository.")))
                }
                switch pinned {
                case .failure:
                    self.placing.remove(id)
                    answer(.failure(.init(code: FleetDispatchCode.repoMissing, message: "This thread's folder isn't a git checkout.")))
                case .success(let pin):
                    self.pins[id] = pin
                    var record = FleetDispatchRecord(
                        id: id, parentAgentID: agentID, parentHostID: self.hostID, parentHostName: self.hostName(), parentTitle: agent.name,
                        requestedHost: FleetPlacement.isAuto(named) ? nil : named?.trimmingCharacters(in: .whitespacesAndNewlines),
                        state: .placing, title: Self.title(title, task: trimmedTask), task: trimmedTask, repoKey: repoKey,
                        commitSHA: pin.sha, subdir: pin.subdir, model: model?.fleetNonEmpty, thinking: thinking?.fleetNonEmpty,
                        spaceID: spaceID, origin: origin, createdAt: self.now)
                    record.updatedAt = record.createdAt
                    self.outbound[id] = record
                    self.save()
                    self.waiters[id] = waiting
                    if self.canStart(record) {
                        self.place(id) { [weak self] result in self?.finishPlacement(id, result) }
                    } else {
                        self.outbound[id]?.state = .heldLimit
                        self.outbound[id]?.updatedAt = self.now
                        self.save()
                        self.finishPlacement(id, .success(self.outbound[id] ?? record))
                    }
                }
            }
        }
    }

    private func finishPlacement(_ id: UUID, _ result: Result<FleetDispatchRecord, FleetDispatchRefusal>) {
        placing.remove(id)
        let waiting = waiters.removeValue(forKey: id) ?? []
        for done in waiting { done(result) }
        scheduleEvaluation()
    }

    /// A title for the log and the branch: the one given, else the task's first line.
    static func title(_ given: String?, task: String) -> String {
        let source = given?.trimmingCharacters(in: .whitespacesAndNewlines).fleetNonEmpty
            ?? task.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Dispatch"
        let flat = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= titleLimit ? flat : String(flat.prefix(titleLimit - 1)) + "…"
    }

    /// Room under the thread's cap for one more dispatch.
    func canStart(_ record: FleetDispatchRecord) -> Bool {
        guard let parent = record.parentAgentID else { return true }
        let cap = host.settings()?.fleetThreadCap ?? HostSettings.fleetThreadCapDefault
        let live = outbound.values.filter { $0.parentAgentID == parent && $0.id != record.id && $0.state.countsAgainstCap }.count
        return live < cap
    }

    // MARK: Placement

    /// Decides where `id` goes, with a fresh sample of this Mac and of any peer whose newest is stale
    /// (`fleetPressureNow`), then sends it. `completion` hears the outcome once the target answered or
    /// the dispatch settled into waiting or refusal.
    func place(_ id: UUID, completion: ((Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void)?) {
        guard outbound[id] != nil else { return completion?(.failure(.init(code: FleetDispatchCode.invalid, message: "No such dispatch."))) ?? () }
        guard !placing.contains(id) || completion != nil else { return }
        placing.insert(id)
        let stale = peers().filter { peer in
            guard peer.connected else { return false }
            let state = pressure.macs(thisMac: hostID, peerIDs: [peer.hostID]).first { $0.hostID == peer.hostID }
            // A peer whose report lists something missing is asked too: it looks again before it answers, and the tool may be installed now.
            if let readiness = state?.readiness, !readiness.missing.isEmpty || readiness.noXcode { return true }
            return state?.sampleAge.map { $0 > FleetRoom.staleAfter / 2 } ?? true
        }
        let asks = stale.compactMap { peer in client(peer.hostID).map { (peer.hostID, $0) } }
        Task.detached { [weak self, pressure] in
            _ = await pressure.sampleNow()
            var fresh: [(UUID, FleetPressureSample, FleetReadinessReport?)] = []
            for (peerID, link) in asks {
                if let answer = try? await link.fleetPressureNow() { fresh.append((peerID, answer.sample, answer.readiness)) }
            }
            self?.queue.async {
                guard let self else { return }
                for (peerID, sample, readiness) in fresh {
                    self.pressure.received(sample, from: peerID)
                    if let readiness { self.pressure.received(readiness, from: peerID) }
                }
                self.placing.remove(id)
                self.decide(id, completion: completion)
            }
        }
    }

    private func decide(_ id: UUID, completion: ((Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void)?) {
        guard var record = outbound[id] else { return }
        guard [.placing, .waitingRoom, .heldLimit].contains(record.state) else { return completion?(.success(record)) ?? () }
        let macs = placementMacs(for: record)
        let batteryHalf = host.settings()?.fleetBatteryCountsHalf ?? true
        let outcome = FleetPlacement.place(host: record.requestedHost, macs: macs, needsXcode: needsXcode(record),
                                           provider: FleetPlacement.provider(ofModel: record.model), batteryCountsHalf: batteryHalf)
        switch outcome {
        case .place(let target, let reasons):
            // A thread the person started that stays on this Mac isn't a dispatch: the app starts it itself.
            if record.kind == .userThread, target == hostID, firstPlacements.remove(id) != nil {
                outbound[id] = nil
                save()
                return completion?(.failure(.init(code: Self.keptHere, message: "It stays on this Mac."))) ?? ()
            }
            record.targetHostID = target
            record.targetHostName = macs.first { $0.hostID == target }?.name
            record.reasonCodes = reasons
            // What the target lacks of MCP servers doesn't stop it: the thread starts without them, and the sender is told which.
            record.without = macs.first { $0.hostID == target }?.withoutCommands ?? []
            record.state = .preparing
            record.updatedAt = now
            outbound[id] = record
            save()
            send(id, completion: completion)
        case .waitForRoom:
            record.state = .waitingRoom
            record.targetHostID = nil
            record.targetHostName = nil
            record.updatedAt = now
            outbound[id] = record
            save()
            completion?(.success(record))
        case .waitForWake(let target, let reasons):
            record.targetHostID = target
            record.targetHostName = macs.first { $0.hostID == target }?.name
            record.reasonCodes = reasons
            record.state = .waitingWake
            record.updatedAt = now
            outbound[id] = record
            save()
            completion?(.success(record))
        case .refuse(let code, let detail):
            record.state = .failed
            record.failure = code
            record.failureDetail = detail
            record.updatedAt = now
            outbound[id] = record
            save()
            completion?(.failure(Self.refusal(code, detail)))
        }
    }

    /// Whether this dispatch's repository has an Xcode project at its top level (here: it is the sending Mac's checkout that is looked at),
    /// the only reason a Mac without Xcode is refused.
    func needsXcode(_ record: FleetDispatchRecord) -> Bool {
        let spaces = host.state().spaces.filter { $0.id == record.spaceID || (!record.repoKey.isEmpty && $0.repoKey == record.repoKey) }
        return FleetReadiness.needsXcode(spaces: spaces.map { ($0.name, $0.path) })
    }

    /// Every Mac as placement sees it: this Mac and each paired one.
    func placementMacs(for record: FleetDispatchRecord) -> [FleetPlacement.Mac] {
        let settings = host.settings()
        let states = pressure.macs(thisMac: hostID, peerIDs: peers().map(\.hostID))
        func weight(_ id: UUID) -> FleetSendWeight { settings?.fleetWeights[FleetSendWeight.settingKey(hostID: id)] ?? .normal }
        func inFlight(_ id: UUID) -> Int {
            outbound.values.filter { $0.targetHostID == id && $0.state == .preparing }.count
        }
        var macs: [FleetPlacement.Mac] = []
        let local = states.first { $0.hostID == hostID }
        macs.append(FleetPlacement.Mac(
            hostID: hostID, name: hostName(), isLocal: true, connected: true, hasRepo: true,
            lacks: ((local?.readiness ?? pressure.localReadiness)?.lacks ?? []) + ((local?.check ?? pressure.localCheck?.report)?.lacks ?? []),
            sample: local?.sample, sampleAge: local?.sampleAge, weight: weight(hostID), inFlight: inFlight(hostID)))
        for peer in peers() {
            let state = states.first { $0.hostID == peer.hostID }
            let readiness = state?.readiness
            // A Mac that hasn't said what it holds isn't known to have the repo; one that says so with no keys
            // (an older build) has none this dispatch can name.
            let hasRepo: Bool? = readiness.map { $0.repoKeys.contains(record.repoKey) }
            macs.append(FleetPlacement.Mac(
                hostID: peer.hostID, name: peer.name, isLocal: false, connected: peer.connected, hasRepo: hasRepo,
                lacks: (readiness?.lacks ?? []) + (state?.check?.lacks ?? []), sample: state?.sample, sampleAge: state?.sampleAge,
                weight: weight(peer.hostID), inFlight: inFlight(peer.hostID)))
        }
        return macs
    }

    static func refusal(_ code: String, _ detail: String?) -> FleetDispatchRefusal {
        let message: String = switch code {
        case FleetDispatchCode.noSuchHost: "No Mac named \(detail ?? "that") is in the fleet. fleet_hosts lists them."
        case FleetDispatchCode.repoMissing: detail.map { "\($0) doesn't have this repository." } ?? "No Mac that can take work has this repository."
        case FleetDispatchCode.cloneFailed: "That Mac couldn't clone this repository\(detail.map { ": \($0)" } ?? "")."
        case FleetDispatchCode.repoAmbiguous: "More than one folder on that Mac is this repository: \(detail ?? "")."
        case FleetDispatchCode.hostNotReady: "That Mac isn't ready: \(detail.map { $0 == "unknown" ? "it hasn't reported yet" : "\($0) isn't installed" } ?? "it can't run this work")."
        case FleetDispatchCode.commitUnreachable: "That Mac can't reach this commit from its origin."
        case FleetDispatchCode.fleetOff: "Fleet is off on that Mac, which runs an older Shepherd. Update it."
        default: detail.map { "\(code): \($0)" } ?? code
        }
        return FleetDispatchRefusal(code: code, message: message, detail: detail)
    }

    /// A branch as the form names it ("origin/x" for a remote one): its local name.
    static func localName(_ branch: String) -> String { branch.hasPrefix("origin/") ? String(branch.dropFirst("origin/".count)) : branch }

    // MARK: Create

    /// Sends `id`'s create to its target (this Mac included). The target answers at once with the record it
    /// made; what happens after comes back as pushes. An answer that never came leaves the dispatch waiting
    /// on that Mac: a retry carries the same id, so it can't start twice.
    func send(_ id: UUID, completion: ((Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void)?) {
        guard let record = outbound[id] else { return }
        guard let target = record.targetHostID, !sending.contains(id) else { return completion?(.success(record)) ?? () }
        guard isConnected(target) else {
            outbound[id]?.state = .waitingWake
            outbound[id]?.updatedAt = now
            save()
            return completion?(.success(outbound[id] ?? record)) ?? ()
        }
        sending.insert(id)
        if outbound[id]?.state != .preparing { outbound[id]?.state = .preparing; outbound[id]?.updatedAt = now; save() }
        // A dispatch from a checkout carries a snapshot of it (slice 4c): worked out once, before the create.
        if snapshots[id] == nil, wantsSnapshot(record) || repoBundles.contains(id) {
            buildSnapshot(id) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success: self.sendCreate(id, completion: completion)
                case .failure(let refusal): self.sending.remove(id); self.snapshotFailed(id, refusal, completion: completion)
                }
            }
            return
        }
        sendCreate(id, completion: completion)
    }

    /// The create itself, with the snapshot's header when there is one. `sending` holds `id`.
    func sendCreate(_ id: UUID, completion: ((Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void)?) {
        guard let record = outbound[id], let target = record.targetHostID else { sending.remove(id); return }
        // Where a Mac with no checkout gets the repository: this Mac's origin, and the space it is, so the checkout becomes that space there.
        let space = record.spaceID.flatMap { wanted in host.state().spaces.first { $0.id == wanted } }
        let repo = FleetRepoSource(origin: record.origin, spaceID: record.spaceID, name: space?.name, worktreeBase: space?.worktreeBase)
        let create = FleetDispatchCreate(
            dispatchID: id, kind: record.kind, task: record.task, title: record.title, repoKey: record.repoKey, commitSHA: record.commitSHA,
            subdir: record.subdir, branch: record.branch ?? record.start?.branch.map { record.start?.place == .existingBranch ? Self.localName($0) : $0 },
            model: record.model, thinking: record.thinking,
            from: FleetDispatchSender(hostID: hostID, hostName: hostName(), agentID: record.parentAgentID, agentTitle: record.parentTitle),
            snapshot: snapshots[id]?.header, repo: repo, start: record.start)
        let finish: @Sendable (Result<FleetDispatchRecord, Error>) -> Void = { [weak self] result in
            self?.queue.async { self?.created(id, result, completion: completion) }
        }
        if target == hostID {
            receiveCreate(create, from: hostID) { reply in
                switch reply {
                case .success(let record): finish(.success(record))
                case .failure(let refusal): finish(.failure(RemoteHostClientError.rejected(code: refusal.code, message: refusal.message)))
                }
            }
        } else if let link = client(target) {
            Task { do { finish(.success(try await link.fleetDispatchCreate(create))) } catch { finish(.failure(error)) } }
        } else {
            sending.remove(id)
            outbound[id]?.state = .waitingWake
            save()
            completion?(.success(outbound[id] ?? record))
        }
    }

    private func created(_ id: UUID, _ result: Result<FleetDispatchRecord, Error>, completion: ((Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void)?) {
        sending.remove(id)
        awaitingRepository.remove(id)
        guard var record = outbound[id] else { return }
        guard record.state == .preparing || record.state == .waitingWake else {
            // The person stopped it, or the target already reported: nothing to add.
            return completion?(.success(record)) ?? ()
        }
        switch result {
        case .success(let theirs):
            if theirs.state == .waitingRoom {
                // The target is full and kept nothing: decide again when anything changes.
                record.state = .waitingRoom
                record.targetHostID = nil
                record.targetHostName = nil
            } else {
                merge(theirs, into: &record)
            }
            record.updatedAt = now
            outbound[id] = record
            save()
            completion?(.success(record))
            // The target took the work and is waiting for the rest of the snapshot.
            if theirs.state == .preparing, snapshots[id] != nil { transfer(id) }
        case .failure(let error):
            if case RemoteHostClientError.rejected(let code, _) = error, !Self.transportCodes.contains(code) {
                let known = [FleetDispatchCode.repoMissing, FleetDispatchCode.repoAmbiguous, FleetDispatchCode.commitUnreachable, FleetDispatchCode.cloneFailed,
                             FleetDispatchCode.hostNotReady, FleetDispatchCode.snapshotTooLarge, FleetDispatchCode.snapshotMismatch,
                             FleetDispatchCode.snapshotFailed, FleetDispatchCode.invalid]
                record.state = .failed
                record.failure = known.contains(code) ? code : FleetDispatchCode.refused
                record.failureDetail = known.contains(code) ? nil : code
                record.updatedAt = now
                outbound[id] = record
                save()
                completion?(.failure(Self.refusal(record.failure ?? code, record.failureDetail)))
            } else {
                // The answer was lost, not the dispatch: it waits on that Mac and is sent again (same id) when its link is back.
                record.state = .waitingWake
                record.updatedAt = now
                outbound[id] = record
                save()
                completion?(.success(record))
            }
        }
        scheduleEvaluation()
    }

    /// Codes that say the request didn't get an answer, not that it was refused.
    static let transportCodes: Set<String> = ["not_sent", "timeout", "closed", "disconnected", "protocol"]

    /// Takes what the target says into the sender's record. A finished sender record never moves back.
    func merge(_ theirs: FleetDispatchRecord, into record: inout FleetDispatchRecord) {
        guard record.state.isLive else { return }
        // A failed clone told a second time (the push and the answer to a status question both bring it) is the same attempt, already
        // answered: the repository is on its way, and a clone from it never says this.
        // (`clone_failed` is only ever said while preparing: once the thread runs it is stale.)
        if theirs.state == .failed, [FleetDispatchCode.cloneFailed, FleetDispatchCode.commitUnreachable].contains(theirs.failure ?? ""),
           record.state != .preparing || awaitingRepository.contains(record.id) { return }
        record.remoteAgentID = theirs.remoteAgentID ?? record.remoteAgentID
        record.branch = theirs.branch ?? record.branch
        record.activity = theirs.activity ?? record.activity
        record.targetHostName = record.targetHostName ?? theirs.targetHostName
        // Where a clone on the target stands, while it is cloning.
        record.clone = theirs.state == .preparing ? theirs.clone : nil
        // The target lacks a commit no remote holds (it has the repository): the commits it lacks go as a bundle of their own, once.
        // Only for commits no remote holds: one a remote has and this Mac can't reach is no bundle's to bring.
        if theirs.state == .failed, theirs.failure == FleetDispatchCode.commitUnreachable, record.state == .preparing, canSendRepository(record),
           pins[record.id]?.unpushed == true, snapshots[record.id]?.header.bundle == nil {
            record.failure = nil
            record.failureDetail = nil
            record.updatedAt = now
            let id = record.id
            awaitingRepository.insert(id)
            queue.async { [weak self] in self?.sendRepository(id, incremental: true) }
            return
        }
        // The target couldn't clone the repository from origin: send it the repository itself, when there is a snapshot to send it with.
        if theirs.state == .failed, theirs.failure == FleetDispatchCode.cloneFailed, record.state == .preparing, canSendRepository(record) {
            record.failure = nil
            record.failureDetail = nil
            let named = record.spaceID.flatMap { wanted in host.state().spaces.first { $0.id == wanted }?.name }
            record.clone = FleetCloneProgress(name: FleetRepoClone.folderName(repoKey: record.repoKey, name: named), source: hostName(), viaBundle: true)
            record.updatedAt = now
            let id = record.id
            awaitingRepository.insert(id)
            queue.async { [weak self] in self?.sendRepository(id) }
            return
        }
        switch theirs.state {
        case .preparing: if record.state != .running { record.state = .preparing }
        case .running: record.state = .running
        case .failed:
            record.state = .failed
            // No way to send the repository: the clone's own failure is the dispatch's, with git's words.
            record.failure = theirs.failure == FleetDispatchCode.cloneFailed ? FleetDispatchCode.repoMissing : theirs.failure ?? FleetDispatchCode.refused
            record.failureDetail = theirs.failureDetail
        case .cancelled: record.state = .cancelled
        default: break
        }
        record.updatedAt = now
        if !record.state.isLive || record.state == .running { releaseSnapshot(id: record.id) }
    }

    // MARK: Following (sender, server queue)

    /// The Mac running a dispatch told us where it stands (`fleetDispatchChanged`).
    func changed(_ theirs: FleetDispatchRecord, from peer: UUID) -> Bool {
        guard var record = outbound[theirs.id], record.targetHostID == peer else { return false }
        merge(theirs, into: &record)
        outbound[record.id] = record
        save()
        return true
    }

    /// The thread finished a run (`fleetDispatchResult`): keep the result, then wake the parent with it.
    func result(_ id: UUID, text: String, facts: FleetBranchFacts?, from peer: UUID) -> Bool {
        guard var record = outbound[id], record.targetHostID == peer else { return false }
        // A dispatch that was stopped, or already failed, takes no result; the target is told it arrived.
        guard record.state.isLive else { return true }
        record.resultText = String(text.prefix(FleetDispatchProtocol.maxResultBytes))
        record.resultBranchFacts = facts
        record.state = .delivering
        record.updatedAt = now
        outbound[id] = record
        save()
        deliverResult(id)
        return true
    }

    /// Wakes the parent with the result, once. A parent whose pi isn't connected keeps the record in
    /// `delivering`; it goes when that pi next serves (`parentConnected`) or the next evaluation.
    func deliverResult(_ id: UUID) {
        guard let record = outbound[id], record.state == .delivering, !delivering.contains(id) else { return }
        guard let parent = record.parentAgentID else {
            // A thread the person started has no parent: its result is the thread.
            outbound[id]?.state = .done
            outbound[id]?.updatedAt = now
            return save()
        }
        guard host.state().agents.contains(where: { $0.id == parent }) else {
            outbound[id]?.state = .cancelled
            outbound[id]?.failureDetail = "parent_gone"
            outbound[id]?.updatedAt = now
            return save()
        }
        delivering.insert(id)
        let text = Self.resultMessage(record)
        let wake = host.wakeParent
        Task.detached { [weak self] in
            let delivered = await wake(parent, text)
            self?.queue.async {
                guard let self else { return }
                self.delivering.remove(id)
                // Stopped while it was on its way: it stays stopped, and the parent isn't woken twice.
                guard self.outbound[id]?.state == .delivering else { return }
                if delivered {
                    self.outbound[id]?.state = .done
                    self.outbound[id]?.updatedAt = self.now
                    self.save()
                } else {
                    self.scheduleEvaluation()
                }
            }
        }
    }

    /// The text a parent is woken with: the thread's last message, framed as another agent's words, and
    /// the facts of its branch.
    static func resultMessage(_ record: FleetDispatchRecord) -> String {
        let place = record.targetHostName ?? "another Mac"
        var body = "Result from \(record.title) on \(place):\n\(record.resultText ?? "")"
        if let facts = record.resultBranchFacts {
            let commits = facts.ahead == 1 ? "1 commit" : "\(facts.ahead) commits"
            body += "\n\nBranch \(facts.branch): \(commits) ahead of the start, \(facts.pushed ? "pushed to origin" : "not on origin"), "
                + "\(facts.filesChanged) files changed (+\(facts.insertions) -\(facts.deletions))."
        }
        return AgentMessageFraming.framed(from: "\(record.title) on \(place)", body)
    }

    /// A parent thread's pi connected: results held for it go now.
    func parentConnected(_ agentID: AgentID) {
        for record in outbound.values where record.parentAgentID == agentID && record.state == .delivering { deliverResult(record.id) }
    }

    // MARK: Stopping

    /// Stop or delete on a thread cancels every live dispatch it owns: the records end `cancelled` and no
    /// result wakes the thread back up. The thread there is stopped when the target is reachable.
    func cancelDispatches(ownedBy agentID: AgentID) {
        var any = false
        for record in outbound.values where record.parentAgentID == agentID && record.state.isLive {
            cancel(record.id, save: false)
            any = true
        }
        if any { save() }
    }

    /// Cancels one dispatch the sender holds and stops its thread (best effort, now or when the Mac is reachable).
    func cancel(_ id: UUID, save shouldSave: Bool = true) {
        guard var record = outbound[id], record.state.isLive else { return }
        let sent = record.targetHostID != nil && [.preparing, .running, .delivering, .waitingWake].contains(record.state)
        record.state = .cancelled
        record.updatedAt = now
        outbound[id] = record
        releaseSnapshot(id: id)
        if shouldSave { save() }
        guard sent, let target = record.targetHostID else { return }
        if target == hostID {
            queue.async { [weak self] in self?.control(id, .cancel, from: self?.hostID ?? UUID()) { _ in } }
        } else if let link = client(target) {
            Task { _ = try? await link.fleetDispatchControl(id, .cancel) }
        }
    }

    /// The thread's own `fleet_cancel`, `fleet_send` and `fleet_read` against the dispatch it names.
    func agentControl(from agentID: AgentID, key: String, _ control: FleetDispatchControl,
                      reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        guard let record = dispatch(forKey: key, agent: agentID) else {
            return reply(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "This thread has no dispatch \(key).")))
        }
        switch control {
        case .status:
            reply(.success(record))
        case .cancel:
            guard record.state.isLive else { return reply(.success(record)) }
            cancel(record.id)
            reply(.success(outbound[record.id] ?? record))
        case .message(let text, let delivery):
            guard let target = record.targetHostID, record.state == .running || record.state == .delivering || record.state == .done else {
                return reply(.failure(.init(code: "not_running", message: "That dispatch isn't running, so there is no thread to message (it is \(record.state.rawValue)).")))
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "The message is empty.")))
            }
            let send: @Sendable (Result<FleetDispatchRecord, Error>) -> Void = { [weak self] result in
                self?.queue.async {
                    guard let self else { return }
                    switch result {
                    case .success(let theirs):
                        guard var mine = self.outbound[record.id] else { return }
                        // A new run begins: the earlier result is spent and the next one is delivered when it comes.
                        mine.state = theirs.state == .running ? .running : mine.state
                        mine.remoteAgentID = theirs.remoteAgentID ?? mine.remoteAgentID
                        mine.updatedAt = self.now
                        self.outbound[mine.id] = mine
                        self.save()
                        reply(.success(mine))
                    case .failure(let error):
                        if case RemoteHostClientError.rejected(let code, let message) = error {
                            reply(.failure(.init(code: code, message: message)))
                        } else {
                            reply(.failure(.init(code: "unreachable", message: "That Mac didn't answer. Try again.")))
                        }
                    }
                }
            }
            if target == hostID {
                self.control(record.id, .message(text: text, delivery: delivery), from: hostID) { result in
                    switch result {
                    case .success(let theirs): send(.success(theirs))
                    case .failure(let refusal): send(.failure(RemoteHostClientError.rejected(code: refusal.code, message: refusal.message)))
                    }
                }
            } else if let link = client(target) {
                Task { do { send(.success(try await link.fleetDispatchControl(record.id, .message(text: text, delivery: delivery)))) } catch { send(.failure(error)) } }
            } else {
                reply(.failure(.init(code: "unreachable", message: "That Mac isn't connected right now.")))
            }
        }
    }

    // MARK: Following after a restart

    /// Asks the Mac each running dispatch is on how it stands: following is not resuming, the work lives
    /// on that Mac under its own recovery rules. A Mac that never heard of it ends a running dispatch
    /// `peer_gone` and leaves a preparing one held for the person.
    func reconcile() {
        guard !stopped else { return }
        for record in outbound.values where record.state == .preparing || record.state == .running {
            guard let target = record.targetHostID, isConnected(target), !sending.contains(record.id) else { continue }
            let id = record.id
            let finish: @Sendable (Result<FleetDispatchRecord, Error>) -> Void = { [weak self] result in
                self?.queue.async { self?.reconciled(id, result) }
            }
            if target == hostID {
                self.control(id, .status, from: hostID) { result in
                    switch result {
                    case .success(let theirs): finish(.success(theirs))
                    case .failure(let refusal): finish(.failure(RemoteHostClientError.rejected(code: refusal.code, message: refusal.message)))
                    }
                }
            } else if let link = client(target) {
                Task { do { finish(.success(try await link.fleetDispatchControl(id, .status))) } catch { finish(.failure(error)) } }
            }
        }
    }

    private func reconciled(_ id: UUID, _ result: Result<FleetDispatchRecord, Error>) {
        guard var record = outbound[id], record.state == .preparing || record.state == .running else { return }
        switch result {
        case .success(let theirs):
            merge(theirs, into: &record)
            outbound[id] = record
            save()
            // A result the Mac still holds for us comes now (it pushes it too).
            if theirs.state == .delivering || theirs.state == .done, let text = theirs.resultText {
                _ = self.result(id, text: text, facts: theirs.resultBranchFacts, from: record.targetHostID ?? hostID)
            }
        case .failure(let error):
            guard case RemoteHostClientError.rejected(let code, _) = error, code == FleetDispatchProtocol.Code.unknownDispatch else { return }
            if record.state == .running {
                record.state = .failed
                record.failure = FleetDispatchCode.peerGone
            } else {
                record.state = .heldRestart
            }
            record.updatedAt = now
            outbound[id] = record
            save()
        }
    }
}

extension FleetDispatch {
    /// Runs `body` on the server queue and returns its value to an async caller.
    func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }
}

extension String {
    var fleetNonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
