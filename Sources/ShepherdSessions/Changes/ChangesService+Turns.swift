import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Last turn (ChangesLastTurn) and the "Edited N files" card: when pi starts a run the host
// snapshots the agent's working tree, when the run settles it snapshots it again, and the
// turn's changes are the diff between the two trees, less what Shepherd wrote for the person.
// Where another agent's turn, its edit or write, or its subagent, shared the working tree during
// the run, the changes are cut to the files the turn's own edit and write calls (and its own
// subagents) named and no other call or subagent named (TurnAttribution, WriterLog): the cut
// becomes the turn's `endTree`, so the card, Last turn, the counts, Undo and Redo all agree.
// Undo writes the start tree's version of exactly those files back into the working tree (Redo
// the end tree's), refusing when any of them changed since, or when a late writer turns out to
// have shared one.

/// One recorded turn: its public face and the trees it runs between.
struct TurnRecord: Codable, Hashable, Sendable {
    var turn: ChangesTurn
    /// The directory the turn ran in.
    var cwd: String
    var startTree: String?
    var endTree: String?
    /// A durable, bounded journal: never accept an arbitrary post-failure snapshot as safe.
    var recovery: Recovery?

    struct Recovery: Codable, Hashable, Sendable {
        var redo: Bool
        var completed: [String] = []
        var inFlight: String?
    }
}

/// Every agent's recent turns, in memory and in `turns.json` in the changes directory, so the
/// cards and their Undo survive a relaunch.
final class TurnStore: @unchecked Sendable {
    private typealias Records = [String: [TurnRecord]]
    private typealias Snapshot = (records: Records, dirty: [String: Int])
    private let url: URL
    private let lock = NSLock()
    private var records: Records?
    private var deferredPrune: Set<String>?
    private var dirty: [String: Int] = [:]
    private var revision = 0
    private var damage: ChangesError?
    // A snapshot taken before damage was detected must not overwrite a later repair.
    private var generation = 0
    private let io = DispatchQueue(label: "shepherd.changes.turns", qos: .utility)
    private var writeScheduled = false
    /// Installed before serving threads. Reads committed IDs without waiting for the server queue.
    var liveAgentIDs: @Sendable () -> [AgentID] = { [] }
    /// Installed before serving threads. Called on `io`, outside the record lock.
    var onAvailabilityChanged: (@Sendable (Set<AgentID>) -> Void)?
    /// Per-instance test seam, installed before use. Runs on `io`, outside the record lock.
    var beforeWrite: (@Sendable ([String: [TurnRecord]]) throws -> Void)?

    init(url: URL) {
        self.url = url
        // Host construction, before the server queue serves turn events or thread snapshots.
        switch PersistedFile<Records>.load(from: url) {
        case .loaded(var restored):
            // Only startup can say a running turn was interrupted by a quit.
            for key in restored.keys {
                for i in restored[key]!.indices where restored[key]![i].turn.state == .running {
                    restored[key]![i].turn.state = .unavailable
                    restored[key]![i].turn.reason = "Shepherd quit before this turn ended."
                }
            }
            records = restored
        case .missing: records = [:]
        case .damaged(_, let error):
            let problem = readProblem(error)
            damage = problem
            ShepherdLog.error(problem.message)
        }
    }

    private func readProblem(_ error: any Error) -> ChangesError {
        let detail: String
        switch error {
        case DecodingError.dataCorrupted(let context), DecodingError.typeMismatch(_, let context),
             DecodingError.valueNotFound(_, let context), DecodingError.keyNotFound(_, let context):
            detail = context.debugDescription
        default:
            detail = error.localizedDescription
        }
        return ChangesError(ChangesError.unavailable, "Undo/Redo history can't be read.\n\(url.path)\n\(detail)\nOn the host Mac, fix the file's permissions if access was denied, or restore a known-good backup. As a last resort, delete this file to drop Undo/Redo history for past turns. This leaves the working tree untouched. Then refresh Changes; no restart is needed.")
    }

    /// Only `io` reads or replaces the file after startup. Turn events never wait for disk.
    private func recheck() throws {
        let restored: Records?
        switch PersistedFile<Records>.load(from: url) {
        case .loaded(let value): restored = value
        case .missing: restored = nil
        case .damaged(_, let error):
            let problem = readProblem(error)
            let affected = lock.withLock { () -> Records? in
                defer { damage = problem }
                guard damage == nil else { return nil }
                generation += 1
                writeScheduled = false
                return records ?? [:]
            }
            if let affected {
                ShepherdLog.error(problem.message)
                onAvailabilityChanged?(Set(affected.keys.map(AgentID.init(rawValue:))))
            }
            throw problem
        }
        let changed = lock.withLock { () -> (Records, Records)? in
            guard damage != nil else { return nil }
            let previous = records
            damage = nil
            if var restored {
                // Use the repaired file except where this host owns newer, live state. A backup
                // may predate an interrupted Undo even when its checkpoints reached disk.
                var retain = Set(dirty.keys)
                for (key, list) in previous ?? [:] where list.last?.turn.state == .running || list.last?.recovery != nil {
                    retain.insert(key)
                }
                for key in retain where restored[key] != previous?[key] {
                    restored[key] = previous?[key]
                    markDirty(key)
                }
                // A running record from the repaired file does not belong to a live capture.
                for key in restored.keys where !retain.contains(key) {
                    for i in restored[key]!.indices where restored[key]![i].turn.state == .running {
                        restored[key]![i].turn.state = .unavailable
                        restored[key]![i].turn.reason = "Shepherd couldn’t recover the end of this turn."
                        markDirty(key)
                    }
                }
                records = restored
                if let deferredPrune {
                    // The startup set can miss agents created while the file was damaged.
                    pruneLocked(keeping: deferredPrune.union(liveAgentIDs().map(\.rawValue)))
                }
                if !dirty.isEmpty { scheduleWrite() }
            } else {
                // Deleting damaged history is an explicit repair, not a request to restore it.
                records = [:]
                dirty = [:]
            }
            deferredPrune = nil
            return (previous ?? [:], records ?? [:])
        }
        if let (previous, current) = changed {
            onAvailabilityChanged?(Set(previous.keys.map(AgentID.init(rawValue:))).union(current.keys.map(AgentID.init(rawValue:))))
        }
    }

    func all(_ agentID: AgentID) -> [TurnRecord] {
        lock.withLock { records?[agentID.rawValue] ?? [] }
    }

    /// A review or Undo/Redo needs to distinguish no turns from unreadable history.
    func history(_ agentID: AgentID) throws -> (records: [TurnRecord], generation: Int) {
        try io.sync {
            try recheck()
            return lock.withLock { (records?[agentID.rawValue] ?? [], generation) }
        }
    }

    func latest(_ agentID: AgentID) -> TurnRecord? { all(agentID).last }

    func record(_ agentID: AgentID, _ id: UUID) -> TurnRecord? { all(agentID).first { $0.turn.id == id } }

    /// Keep staging captures in a live cache even during damage, but never save over it.
    @discardableResult
    func update<T>(_ agentID: AgentID, _ body: (inout [TurnRecord]) -> T) -> T? {
        lock.withLock {
            guard records != nil else { return nil }
            let result = updateLocked(agentID, body)
            scheduleWrite()
            return result
        }
    }

    /// Caller holds `lock` and has records.
    private func updateLocked<T>(_ agentID: AgentID, _ body: (inout [TurnRecord]) -> T) -> T {
        let key = agentID.rawValue
        var list = records?[key] ?? []
        let result = body(&list)
        if list != (records?[key] ?? []) {
            records?[key] = list.isEmpty ? nil : list
            markDirty(key)
        }
        return result
    }

    /// A save clears only the mutations it actually captured; a turn can advance during I/O.
    private func markDirty(_ key: String) {
        revision += 1
        dirty[key] = revision
    }

    private func snapshot() -> Snapshot { (records ?? [:], dirty) }

    /// Drops a deleted agent's records, and saves only when it had any.
    func remove(_ agentID: AgentID) {
        lock.withLock {
            deferredPrune?.remove(agentID.rawValue)
            guard records?.removeValue(forKey: agentID.rawValue) != nil else { return }
            markDirty(agentID.rawValue)
            scheduleWrite()
        }
    }

    /// Forgets every agent not in `agents` (deleted while Shepherd was not running).
    func prune(keeping agents: Set<AgentID>) {
        let keep = Set(agents.map(\.rawValue))
        lock.withLock {
            guard records != nil else {
                deferredPrune = keep
                return
            }
            pruneLocked(keeping: keep)
            if !dirty.isEmpty { scheduleWrite() }
        }
    }

    /// Caller holds `lock`.
    private func pruneLocked(keeping keep: Set<String>) {
        let removed = records?.keys.filter { !keep.contains($0) } ?? []
        for key in removed {
            records?[key] = nil
            markDirty(key)
        }
    }

    /// Caller holds `lock`. All physical writes run on `io`.
    private func scheduleWrite() {
        guard damage == nil, !writeScheduled else { return }
        writeScheduled = true
        let generation = self.generation
        io.async {
            let snapshot = self.lock.withLock { () -> Snapshot? in
                guard generation == self.generation else { return nil }
                self.writeScheduled = false
                return self.snapshot()
            }
            if let snapshot { try? self.write(snapshot, generation: generation) }
        }
    }

    private func write(_ snapshot: Snapshot, generation: Int) throws {
        try beforeWrite?(snapshot.records)
        let data = try JSONEncoder().encode(snapshot.records)
        try recheck()
        try lock.withLock { try checkGeneration(generation) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lock.withLock {
            for (key, written) in snapshot.dirty where dirty[key] == written { dirty[key] = nil }
        }
    }

    /// Caller holds `lock`.
    private func checkGeneration(_ expected: Int) throws {
        if let damage { throw damage }
        guard generation == expected else {
            throw ChangesError(ChangesError.unavailable, "Undo/Redo history changed on disk. Refresh Changes and try again.")
        }
    }

    /// Stage the journal before the next working-tree mutation. Earlier saves still finish first;
    /// no record lock is held while waiting for `io`.
    func updateAndCheckpoint(_ agentID: AgentID, generation expected: Int? = nil, _ body: (inout [TurnRecord]) -> Void) throws {
        let generation = try lock.withLock {
            try checkGeneration(expected ?? self.generation)
            updateLocked(agentID, body)
            return self.generation
        }
        try io.sync {
            let snapshot = try lock.withLock {
                try checkGeneration(generation)
                return self.snapshot()
            }
            try write(snapshot, generation: generation)
        }
    }

    /// Drop the journal only after the final state is durable. A failed write leaves it retryable.
    func finishOperation(_ agentID: AgentID, turnID: UUID, generation: Int, state: ChangesTurn.State) throws {
        try io.sync {
            func finish(_ records: inout [TurnRecord]) {
                guard let i = records.firstIndex(where: { $0.turn.id == turnID }) else { return }
                records[i].turn.state = state
                records[i].turn.reason = nil
                records[i].recovery = nil
            }
            var snapshot = try lock.withLock {
                try checkGeneration(generation)
                return self.snapshot()
            }
            let key = agentID.rawValue
            if var list = snapshot.records[key] {
                finish(&list)
                snapshot.records[key] = list
            }
            try write(snapshot, generation: generation)
            lock.withLock {
                // Other captures may have staged changes while the final write was in flight.
                if var list = records?[key] {
                    finish(&list)
                    records?[key] = list
                }
            }
        }
    }

    /// Waits for pending saves (tests, and the server's stop).
    func flush() { io.sync {} }

    /// The turns as clients see them: Undo only on the last turn, once it has ended and changed
    /// something; Redo only on the last turn, once undone. Damage leaves the cards in place.
    func published(_ agentID: AgentID) -> [ChangesTurn] {
        let (list, available) = lock.withLock { (records?[agentID.rawValue] ?? [], damage == nil) }
        return Self.published(list, available: available)
    }

    static func published(_ records: [TurnRecord], available: Bool = true) -> [ChangesTurn] {
        records.enumerated().map { index, record in
            var turn = record.turn
            let last = index == records.count - 1
            turn.canUndo = available && last && turn.state == .ready && turn.fileCount > 0
            turn.canRedo = available && last && turn.state == .undone
            return turn
        }
    }

    /// Keeps the newest turn and the recent ones that changed files, at most `ChangesLimits.turns`.
    static func pruned(_ records: [TurnRecord]) -> [TurnRecord] {
        let kept = records.enumerated().filter { $0.offset == records.count - 1 || $0.element.turn.fileCount > 0 || $0.element.turn.state == .running }
        return Array(kept.map(\.element).suffix(ChangesLimits.turns))
    }
}

extension ChangesService {
    /// One serial queue per agent: its captures, Undo and Redo happen in order.
    func captureQueue(_ agentID: AgentID) -> DispatchQueue {
        captureQueues.withValue { queues in
            if let queue = queues[agentID] { return queue }
            let queue = DispatchQueue(label: "shepherd.changes.turn", qos: .userInitiated)
            queues[agentID] = queue
            return queue
        }
    }

    /// How many agents hold a capture queue (tests).
    var captureQueueCount: Int { captureQueues.withValue { $0.count } }

    /// Drops what the engine holds for agents that were deleted: their turn records, prepared
    /// baseline and capture queue. Each goes on the agent's own capture queue, behind any capture
    /// still running for it, and the queue is the last thing to go.
    public func forget(_ agents: Set<AgentID>) {
        for agent in agents {
            captureQueue(agent).async { [self] in
                turnStore.remove(agent)
                preparedTurns.withValue { $0[agent] = nil }
                // Nothing is left to re-cut, and a re-cut would queue work for an agent that is gone.
                writers.withValue { $0.forget(agent) }
                captureQueues.withValue { $0[agent] = nil }
            }
        }
    }

    func publish(_ agentID: AgentID) {
        onTurnsChanged?(agentID, turnStore.published(agentID))
    }

    /// The agent's recent turns, oldest first.
    public func turns(agentID: AgentID) -> [ChangesTurn] {
        turnStore.published(agentID)
    }

    /// Forgets the turns of agents that no longer exist.
    public func pruneTurns(keeping agents: Set<AgentID>) {
        turnStore.prune(keeping: agents)
    }

    // MARK: Turn events (server queue; the work happens on the agent's capture queue)

    /// Capture before a host prompt can write. No turn is created until pi actually starts it.
    func prepareTurn(agentID: AgentID, completion: @escaping () -> Void) {
        let context = agentContext(agentID)
        promptSent(agentID: agentID)
        captureQueue(agentID).async { [self] in
            defer { completion() }
            guard let context else { return }
            let baseline = Result { try snapshot(repository(context.cwd)).tree }
            preparedTurns.withValue { $0[agentID] = (context.cwd, baseline) }
        }
    }

    /// pi started a run: record a turn and snapshot its baseline. A second start before the run
    /// settles (a retry) belongs to the same turn.
    func turnStarted(agentID: AgentID, at time: Double = Date().timeIntervalSince1970 * 1000) {
        guard let context = agentContext(agentID) else { return }
        let id = UUID()
        let started = turnStore.update(agentID) { records in
            if let last = records.last, last.turn.state == .running, last.turn.endedAt == nil { return false }
            records.append(TurnRecord(turn: ChangesTurn(id: id, startedAt: time, state: .running), cwd: context.cwd))
            return true
        }
        guard started != false else { return }
        // Even a turn we can't record can write into another turn's working tree.
        let window = writers.withValue { log -> TurnAttribution.Interval? in
            if started == nil, log.windows.contains(where: { $0.agent == agentID && $0.interval.end == nil }) { return nil }
            return log.openWindow(agent: agentID, turn: id, cwd: context.cwd, receivedAt: time)
        }
        if let window { reclassifyAffected(by: window, excluding: agentID, now: time) }
        guard started == true else {
            preparedTurns.withValue { $0[agentID] = nil }
            return
        }
        captureQueue(agentID).async { [self] in
            do {
                let repository = try repository(context.cwd)
                let prepared = preparedTurns.withValue { $0.removeValue(forKey: agentID) }
                let tree = try prepared.flatMap { $0.cwd == context.cwd ? $0.tree : nil }?.get() ?? snapshot(repository).tree
                turnStore.update(agentID) { records in
                    guard let i = records.firstIndex(where: { $0.turn.id == id }) else { return }
                    records[i].startTree = tree
                }
            } catch let error as ChangesError where error.code == ChangesError.notARepository {
                // No repository, no turns to show.
                turnStore.update(agentID) { $0.removeAll { $0.turn.id == id } }
                writers.withValue { $0.closeWindow(turn: id, at: Self.nowMs()) }
            } catch {
                writers.withValue { $0.closeWindow(turn: id, at: Self.nowMs()) }
                turnStore.update(agentID) { records in
                    guard let i = records.firstIndex(where: { $0.turn.id == id }) else { return }
                    records[i].turn.state = .unavailable
                    records[i].turn.reason = "Shepherd couldn’t record where this turn started: \(error)"
                }
            }
            publish(agentID)
        }
    }

    /// The user message that started the run: the card's turn and its "after “…”".
    func turnMessage(agentID: AgentID, timestamp: Double?, text: String) {
        let changed = turnStore.update(agentID) { records in
            guard let i = records.indices.last, records[i].turn.state == .running, records[i].turn.endedAt == nil, records[i].turn.messageTimestamp == nil,
                  records[i].turn.prompt == nil else { return false }
            records[i].turn.messageTimestamp = timestamp
            records[i].turn.prompt = ChangesParse.promptLine(text)
            return true
        }
        if changed == true { captureQueue(agentID).async { [self] in publish(agentID) } }
    }

    /// pi's run settled: snapshot the working tree again and count what the turn changed.
    func turnSettled(agentID: AgentID, at time: Double = Date().timeIntervalSince1970 * 1000,
                     completion: @escaping () -> Void = {}) {
        let id = turnStore.update(agentID) { records -> UUID? in
            guard let i = records.indices.last, records[i].turn.state == .running, records[i].turn.endedAt == nil else { return nil }
            records[i].turn.endedAt = time
            return records[i].turn.id
        }
        let recordedID = id ?? nil
        let windowID = recordedID ?? writers.withValue { $0.windows.last { $0.agent == agentID && $0.interval.end == nil }?.turn }
        // Even a duplicate settle waits behind the original capture before releasing delivery.
        captureQueue(agentID).async { [self] in
            defer { completion() }
            guard let id = recordedID, let record = turnStore.record(agentID, id) else {
                if let windowID { writers.withValue { $0.closeWindow(turn: windowID, at: Self.nowMs()) } }
                return
            }
            do {
                guard let start = record.startTree else {
                    throw ChangesError(ChangesError.unavailable, record.turn.reason ?? "Shepherd couldn’t record where this turn started.")
                }
                let repository = try repository(record.cwd)
                let end = try snapshot(repository).tree
                // The window ends with the end capture: a write that lands in it is in the diff.
                writers.withValue { $0.closeWindow(turn: id, at: Self.nowMs()) }
                let changed = try files(repository, ChangesRevision(old: start, new: end), ChangesOptions())
                let cut = try separate(turnID: id, repository: repository, start: start, end: end, changed: changed)
                turnStore.update(agentID) { records in
                    guard let i = records.firstIndex(where: { $0.turn.id == id }) else { return }
                    cut.apply(to: &records[i])
                    records[i].turn.state = .ready
                    records = TurnStore.pruned(records)
                }
                writers.withValue { log in
                    log.settle(turn: id, .init(startTree: start, realEnd: end, own: cut.own, sequence: cut.sequence))
                    log.prune(now: Self.nowMs())
                }
                // A writer that arrived while this was being cut found no settled turn to flag.
                if writers.withValue({ $0.sequence }) != cut.sequence { queueReclassify(agentID) }
            } catch {
                writers.withValue { $0.closeWindow(turn: id, at: Self.nowMs()) }
                turnStore.update(agentID) { records in
                    guard let i = records.firstIndex(where: { $0.turn.id == id }) else { return }
                    records[i].turn.state = .unavailable
                    records[i].turn.reason = records[i].turn.reason ?? String(describing: error)
                }
            }
            publish(agentID)
        }
    }

    // MARK: Attribution

    /// A turn's changed files cut to its own: the tree that has only those files at their end
    /// state, the list and counts of them, and what the cut was made from.
    struct TurnCut {
        var endTree: String
        var files: [ChangesFile]
        /// The `path` of each file kept.
        var own: Set<String>
        var evidence: TurnAttribution.Evidence
        /// `WriterLog.sequence` when the log was read.
        var sequence: Int

        func apply(to record: inout TurnRecord) {
            record.endTree = endTree
            record.turn.files = Array(files.prefix(ChangesLimits.turnFiles))
            record.turn.fileCount = files.count
            record.turn.added = files.reduce(0) { $0 + $1.added }
            record.turn.removed = files.reduce(0) { $0 + $1.removed }
        }
    }

    /// What a failed cut says: like a failed end capture, and the real end is never shown.
    static let separationFailure = "Shepherd couldn’t separate this turn’s files from what other threads changed in this folder."

    /// Capture queue. Cuts the turn's `changed` files (start to the real end) to its own, from the
    /// writer log as it stands. `previous` is the cut already made: a re-cut only takes files away.
    func separate(turnID: UUID, repository: Repository, start: String, end: String, changed: [ChangesFile],
                  previous: Set<String>? = nil) throws -> TurnCut {
        let now = Self.nowMs()
        let log = writers.withValue { $0 }
        var evidence = TurnAttribution.Evidence()
        if let window = log.windows.last(where: { $0.turn == turnID }) {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            let root = repository.root
            var trees: [String: Bool] = [:]
            evidence = TurnAttribution.evidence(
                window: window, log: log, now: now,
                sameTree: { cwd in
                    if let known = trees[cwd] { return known }
                    let same = (try? self.repository(cwd))?.key == repository.key
                    trees[cwd] = same
                    return same
                },
                relative: { path, cwd in
                    TurnAttribution.relativePath(path, cwd: cwd, home: home, root: root, realParent: Self.realPath)
                },
                savedPath: { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : nil })
        }
        var own = TurnAttribution.classify(changed: changed.map(TurnAttribution.Change.init), evidence: evidence).own
        if let previous { own.formIntersection(previous) }
        let kept = changed.filter { own.contains($0.path) }
        if kept.count == changed.count {
            return TurnCut(endTree: end, files: changed, own: own, evidence: evidence, sequence: log.sequence)
        }
        guard !kept.isEmpty else {
            return TurnCut(endTree: start, files: [], own: [], evidence: evidence, sequence: log.sequence)
        }
        do {
            let paths = Set(kept.flatMap { TurnAttribution.Change($0).paths })
            let tree = try ownTree(repository, start: start, end: end, own: paths)
            let files = try files(repository, ChangesRevision(old: start, new: tree), ChangesOptions())
            return TurnCut(endTree: tree, files: files, own: own, evidence: evidence, sequence: log.sequence)
        } catch {
            throw ChangesError(ChangesError.unavailable, Self.separationFailure)
        }
    }

    /// The `start` tree with `own` paths at their `end` state, built in a scratch index: the
    /// user's is never read for writing, and only objects reach the repository.
    func ownTree(_ repository: Repository, start: String, end: String, own: Set<String>) throws -> String {
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let scratch = indexDirectory.appendingPathComponent(repository.key + ".own-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try ChangesGit.checked(["read-tree", start], in: repository.root, index: scratch.path)
        let raw = try ChangesGit.checked(["diff", "--no-ext-diff", "--raw", "--no-abbrev", "--no-renames", "-z", start, end],
                                         in: repository.root).stdout
        let info = TurnAttribution.indexInfo(rawDiff: raw, own: own)
        if !info.isEmpty {
            _ = try ChangesGit.checked(["update-index", "--replace", "-z", "--index-info"], in: repository.root, index: scratch.path, input: info)
        }
        return try ChangesGit.checked(["write-tree"], in: repository.root, index: scratch.path).trimmed
    }

    /// `path` with its folder's symlinks resolved as far as the folder exists.
    static func realPath(_ path: String) -> String {
        var existing = path
        var tail: [String] = []
        while !existing.isEmpty {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return tail.reversed().reduce(String(cString: resolved)) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
            }
            guard existing != "/" else { break }
            tail.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return path
    }

    /// What a re-cut took away from a turn.
    struct Shrink {
        var dropped: Set<String>
        var evidence: TurnAttribution.Evidence
    }

    /// Capture queue. Re-cuts the agent's latest turn when a writer was logged since it was cut.
    /// The files only shrink; the record and the card follow. Returns what it dropped. A cut that
    /// cannot be made leaves the turn unavailable, as a failed end capture does.
    @discardableResult
    func reclassify(agentID: AgentID) throws -> Shrink? {
        guard let record = turnStore.latest(agentID), record.turn.state == .ready, let start = record.startTree else { return nil }
        let id = record.turn.id
        let (settled, sequence) = writers.withValue { log in (log.windows.last { $0.turn == id }?.settled, log.sequence) }
        guard let settled, settled.sequence != sequence else { return nil }
        do {
            let repository = try repository(record.cwd)
            let changed = try files(repository, ChangesRevision(old: start, new: settled.realEnd), ChangesOptions())
            let cut = try separate(turnID: id, repository: repository, start: start, end: settled.realEnd, changed: changed, previous: settled.own)
            var next = settled
            next.own = cut.own
            next.sequence = cut.sequence
            writers.withValue { $0.settle(turn: id, next) }
            guard cut.own != settled.own else { return nil }
            turnStore.update(agentID) { records in
                guard let i = records.firstIndex(where: { $0.turn.id == id }), records[i].turn.state == .ready else { return }
                cut.apply(to: &records[i])
            }
            publish(agentID)
            return Shrink(dropped: settled.own.subtracting(cut.own), evidence: cut.evidence)
        } catch {
            turnStore.update(agentID) { records in
                guard let i = records.firstIndex(where: { $0.turn.id == id }) else { return }
                records[i].endTree = nil
                records[i].turn.state = .unavailable
                records[i].turn.reason = Self.separationFailure
                records[i].turn.files = []
                records[i].turn.fileCount = 0
                records[i].turn.added = 0
                records[i].turn.removed = 0
            }
            publish(agentID)
            throw error
        }
    }

    func reclassifyQuietly(agentID: AgentID) {
        _ = try? reclassify(agentID: agentID)
    }

    /// The refusal for an Undo whose files a late writer turned out to share.
    func refusal(for shrink: Shrink) -> ChangesError {
        let dropped = shrink.dropped.sorted()
        let edited = dropped.filter { shrink.evidence.foreign[$0] != nil }
        let notice: String
        if let first = edited.first {
            let more = edited.count > 1 ? " and \(edited.count - 1) more" : ""
            notice = "\(threadLabel(shrink.evidence.foreign[first])) also edited \((first as NSString).lastPathComponent)\(more) during this turn."
        } else {
            notice = "\(threadLabel(shrink.evidence.partner)) was also working in this folder during this turn."
        }
        return ChangesError(ChangesError.invalid, "Didn’t undo: \(notice) Nothing was touched.", files: dropped)
    }

    /// An agent as the refusal names it: its thread's title in quotes, cut at 40 characters.
    private func threadLabel(_ agent: AgentID?) -> String {
        guard let agent, let name = agentName(agent)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "another thread"
        }
        return "“\(name.count > 40 ? String(name.prefix(40)) + "…" : name)”"
    }

    // MARK: Undo and Redo

    /// Puts back the last turn's edits: every file it changed returns to how the turn found it —
    /// modified and deleted files restored, files it created moved to the Trash — and nothing
    /// else is touched (not the index, HEAD, refs or other files). Refused, naming the files,
    /// when any of them changed after the turn ended.
    public func undoTurn(agentID: AgentID, turnID: UUID) async throws -> ChangesTurn {
        try await onCaptureQueue(agentID) { try self.applyTurn(agentID: agentID, turnID: turnID, redo: false) }
    }

    /// Reapplies an undone turn's edits, until the next turn starts. Refused when any of its
    /// files changed after the Undo.
    public func redoTurn(agentID: AgentID, turnID: UUID) async throws -> ChangesTurn {
        try await onCaptureQueue(agentID) { try self.applyTurn(agentID: agentID, turnID: turnID, redo: true) }
    }

    private func onCaptureQueue<T>(_ agentID: AgentID, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue(agentID).async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func applyTurn(agentID: AgentID, turnID: UUID, redo: Bool) throws -> ChangesTurn {
        let history = try turnStore.history(agentID)
        guard let record = history.records.last, record.turn.id == turnID else {
            throw ChangesError(ChangesError.invalid, redo ? "Redo is gone once another turn starts." : "Only the last turn can be undone.")
        }
        guard record.turn.state == (redo ? .undone : .ready) else {
            throw ChangesError(ChangesError.invalid, redo ? "There is nothing to redo." : "This turn can’t be undone.")
        }
        // A writer the card has not heard of yet may have shared a file: re-cut first, and write nothing if it did.
        if !redo, let shrink = try reclassify(agentID: agentID) { throw refusal(for: shrink) }
        let repository = try repository(record.cwd)
        let operation = restoreLock(for: repository)
        operation.lock()
        defer { operation.unlock() }
        guard let start = record.startTree, let end = record.endTree, exists(start, in: repository), exists(end, in: repository) else {
            throw ChangesError(ChangesError.unavailable, "The turn’s snapshots are no longer available.")
        }
        let entries = ChangesParse.nameStatus(try ChangesGit.checked(["diff", "--no-ext-diff", "--name-status", "--no-renames", "-z", start, end],
                                                                     in: repository.root).stdout)
        guard !entries.isEmpty else { throw ChangesError(ChangesError.invalid, "The turn changed no files.") }
        let (from, to) = redo ? (start, end) : (end, start)
        let paths = entries.map(\.path)
        let current = try snapshot(repository).tree
        func differences(from tree: String) throws -> Set<String> {
            Set(try ChangesGit.checked(["diff", "--no-ext-diff", "--name-only", "--no-renames", "-z", tree, current, "--"] + paths,
                                       in: repository.root, literalPaths: true)
                .stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        }
        var recovery = record.recovery ?? TurnRecord.Recovery(redo: redo)
        guard recovery.redo == redo else { throw ChangesError(ChangesError.invalid, "Finish the interrupted operation first.") }
        let sourceChanges = try differences(from: from)
        let targetChanges = try differences(from: to)
        let completed = Set(recovery.completed)
        let changed = paths.filter { path in
            if completed.contains(path) { return targetChanges.contains(path) }
            if recovery.inFlight == path { return sourceChanges.contains(path) && targetChanges.contains(path) }
            return sourceChanges.contains(path)
        }
        guard changed.isEmpty else {
            let names = changed.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let more = changed.count > 3 ? " and \(changed.count - 3) more" : ""
            throw ChangesError(ChangesError.changedSince,
                               "\(names)\(more) changed after the \(redo ? "undo" : "turn"), so Shepherd left the files as they are.",
                               files: changed)
        }
        let action = redo ? "Redo" : "Undo"
        func checkpoint(_ reason: String) throws {
            try turnStore.updateAndCheckpoint(agentID, generation: history.generation) { records in
                guard let i = records.firstIndex(where: { $0.turn.id == turnID }) else { return }
                records[i].recovery = recovery
                records[i].turn.reason = reason
            }
        }
        // Each path is journaled before writing. After a crash, only exact source/target bytes
        // are accepted for the in-flight path; unrelated edits never become a recovery baseline.
        let absent: Character = redo ? "D" : "A"
        let root = URL(fileURLWithPath: repository.root, isDirectory: true)
        // Another turn that began while these files are being written must not take them for its own.
        let span = beginWrite(repository, paths: paths)
        defer { endWrite(span) }
        var mayHaveApplied = !completed.isEmpty || recovery.inFlight.map { !targetChanges.contains($0) } == true
        do {
            for entry in entries where !completed.contains(entry.path) {
                recovery.inFlight = entry.path
                try checkpoint("\(action) was interrupted. Retry \(action.lowercased()) to finish; files may be partially changed.")
                if targetChanges.contains(entry.path) {
                    mayHaveApplied = true
                    if entry.status == absent {
                        try trash(root.appendingPathComponent(entry.path))
                    } else {
                        try restoreFiles(repository, from: to, paths: [entry.path])
                    }
                }
                recovery.completed.append(entry.path)
                recovery.inFlight = nil
                try checkpoint("\(action) was interrupted. Retry \(action.lowercased()) to finish; files may be partially changed.")
            }
            try turnStore.finishOperation(agentID, turnID: turnID, generation: history.generation, state: redo ? .ready : .undone)
        } catch let error as ChangesError where error.code == ChangesError.unavailable {
            publish(agentID)
            guard mayHaveApplied else { throw error }
            throw ChangesError(error.code, "\(action) partially applied. Repair or refresh Changes, then retry \(action.lowercased()) to finish.\n\(error.message)")
        } catch {
            let reason = "\(action) partially applied. Retry \(action.lowercased()) to finish: \(error)"
            try? checkpoint(reason)
            publish(agentID)
            throw ChangesError(ChangesError.gitFailed, reason)
        }
        publish(agentID)
        guard let turn = turnStore.published(agentID).last else { throw ChangesError(ChangesError.unavailable, "The turn is gone.") }
        return turn
    }

    /// Writes `paths` from `tree` into the working tree (`git restore --worktree`, through a
    /// throwaway index so the user's is never read for writing), with git's own filters and modes.
    func restoreFiles(_ repository: Repository, from tree: String, paths: [String]) throws {
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let scratch = indexDirectory.appendingPathComponent(repository.key + ".restore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try ChangesGit.checked(["read-tree", tree], in: repository.root, index: scratch.path)
        _ = try ChangesGit.checked(["restore", "--source=\(tree)", "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul"],
                                   in: repository.root, index: scratch.path, literalPaths: true,
                                   input: Data(paths.joined(separator: "\0").utf8))
    }
}
