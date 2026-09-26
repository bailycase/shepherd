import Foundation
import ShepherdCore
import ShepherdProtocol

// Last turn (ChangesLastTurn) and the "Edited N files" card: when pi starts a run the host
// snapshots the agent's working tree, when the run settles it snapshots it again, and the
// turn's changes are the diff between the two trees. Undo writes the start tree's version of
// exactly those files back into the working tree (Redo the end tree's), refusing when any of
// them changed since.

/// One recorded turn: its public face and the trees it runs between.
struct TurnRecord: Codable, Hashable, Sendable {
    var turn: ChangesTurn
    /// The directory the turn ran in.
    var cwd: String
    var startTree: String?
    var endTree: String?
}

/// Every agent's recent turns, in memory and in `turns.json` in the changes directory, so the
/// cards and their Undo survive a relaunch.
final class TurnStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var records: [String: [TurnRecord]]?
    private let io = DispatchQueue(label: "shepherd.changes.turns", qos: .utility)
    private var writeScheduled = false

    init(url: URL) { self.url = url }

    private func loaded() -> [String: [TurnRecord]] {
        if let records { return records }
        var loaded = (try? JSONDecoder().decode([String: [TurnRecord]].self, from: Data(contentsOf: url))) ?? [:]
        // A turn still running when Shepherd quit never saw its end.
        for key in loaded.keys {
            for i in loaded[key]!.indices where loaded[key]![i].turn.state == .running {
                loaded[key]![i].turn.state = .unavailable
                loaded[key]![i].turn.reason = "Shepherd quit before this turn ended."
            }
        }
        records = loaded
        return loaded
    }

    func all(_ agentID: AgentID) -> [TurnRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loaded()[agentID.rawValue] ?? []
    }

    func latest(_ agentID: AgentID) -> TurnRecord? { all(agentID).last }

    func record(_ agentID: AgentID, _ id: UUID) -> TurnRecord? { all(agentID).first { $0.turn.id == id } }

    /// Changes an agent's records in one step and schedules a save.
    @discardableResult
    func update<T>(_ agentID: AgentID, _ body: (inout [TurnRecord]) -> T) -> T {
        lock.lock()
        var all = loaded()
        var list = all[agentID.rawValue] ?? []
        let result = body(&list)
        all[agentID.rawValue] = list.isEmpty ? nil : list
        records = all
        let schedule = !writeScheduled
        writeScheduled = true
        lock.unlock()
        if schedule { io.async { self.save() } }
        return result
    }

    /// Forgets every agent not in `agents` (deleted while Shepherd was not running).
    func prune(keeping agents: Set<AgentID>) {
        let keep = Set(agents.map(\.rawValue))
        lock.lock()
        var all = loaded()
        let before = all.count
        all = all.filter { keep.contains($0.key) }
        records = all
        let changed = all.count != before
        lock.unlock()
        if changed { io.async { self.save() } }
    }

    private func save() {
        lock.lock()
        writeScheduled = false
        let snapshot = records ?? [:]
        lock.unlock()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    /// Waits for pending saves (tests, and the server's stop).
    func flush() { io.sync {} }

    /// The turns as clients see them: Undo only on the last turn, once it has ended and changed
    /// something; Redo only on the last turn, once undone.
    func published(_ agentID: AgentID) -> [ChangesTurn] {
        Self.published(all(agentID))
    }

    static func published(_ records: [TurnRecord]) -> [ChangesTurn] {
        records.enumerated().map { index, record in
            var turn = record.turn
            let last = index == records.count - 1
            turn.canUndo = last && turn.state == .ready && turn.fileCount > 0
            turn.canRedo = last && turn.state == .undone
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

    /// pi started a run: record a turn and snapshot its baseline. A second start before the run
    /// settles (a retry) belongs to the same turn.
    func turnStarted(agentID: AgentID, at time: Double = Date().timeIntervalSince1970 * 1000) {
        guard let context = agentContext(agentID) else { return }
        let id = UUID()
        let started: Bool = turnStore.update(agentID) { records in
            if let last = records.last, last.turn.state == .running { return false }
            records.append(TurnRecord(turn: ChangesTurn(id: id, startedAt: time, state: .running), cwd: context.cwd))
            return true
        }
        guard started else { return }
        captureQueue(agentID).async { [self] in
            do {
                let repository = try repository(context.cwd)
                let tree = try snapshot(repository).tree
                turnStore.update(agentID) { records in
                    guard let i = records.firstIndex(where: { $0.turn.id == id }) else { return }
                    records[i].startTree = tree
                }
            } catch let error as ChangesError where error.code == ChangesError.notARepository {
                // No repository, no turns to show.
                turnStore.update(agentID) { $0.removeAll { $0.turn.id == id } }
            } catch {
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
        let changed: Bool = turnStore.update(agentID) { records in
            guard let i = records.indices.last, records[i].turn.state == .running, records[i].turn.messageTimestamp == nil,
                  records[i].turn.prompt == nil else { return false }
            records[i].turn.messageTimestamp = timestamp
            records[i].turn.prompt = ChangesParse.promptLine(text)
            return true
        }
        if changed { captureQueue(agentID).async { [self] in publish(agentID) } }
    }

    /// pi's run settled: snapshot the working tree again and count what the turn changed.
    func turnSettled(agentID: AgentID, at time: Double = Date().timeIntervalSince1970 * 1000) {
        let id: UUID? = turnStore.update(agentID) { records in
            guard let i = records.indices.last, records[i].turn.state == .running else { return nil }
            records[i].turn.endedAt = time
            return records[i].turn.id
        }
        guard let id else { return }
        captureQueue(agentID).async { [self] in
            guard let record = turnStore.record(agentID, id) else { return }
            do {
                guard let start = record.startTree else {
                    throw ChangesError(ChangesError.unavailable, record.turn.reason ?? "Shepherd couldn’t record where this turn started.")
                }
                let repository = try repository(record.cwd)
                let end = try snapshot(repository).tree
                let files = try files(repository, ChangesRevision(old: start, new: end), ChangesOptions())
                turnStore.update(agentID) { records in
                    guard let i = records.firstIndex(where: { $0.turn.id == id }) else { return }
                    records[i].endTree = end
                    records[i].turn.state = .ready
                    records[i].turn.files = Array(files.prefix(ChangesLimits.turnFiles))
                    records[i].turn.fileCount = files.count
                    records[i].turn.added = files.reduce(0) { $0 + $1.added }
                    records[i].turn.removed = files.reduce(0) { $0 + $1.removed }
                    records = TurnStore.pruned(records)
                }
            } catch {
                turnStore.update(agentID) { records in
                    guard let i = records.firstIndex(where: { $0.turn.id == id }) else { return }
                    records[i].turn.state = .unavailable
                    records[i].turn.reason = records[i].turn.reason ?? String(describing: error)
                }
            }
            publish(agentID)
        }
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
        guard let record = turnStore.latest(agentID), record.turn.id == turnID else {
            throw ChangesError(ChangesError.invalid, redo ? "Redo is gone once another turn starts." : "Only the last turn can be undone.")
        }
        guard record.turn.state == (redo ? .undone : .ready) else {
            throw ChangesError(ChangesError.invalid, redo ? "There is nothing to redo." : "This turn can’t be undone.")
        }
        let repository = try repository(record.cwd)
        guard let start = record.startTree, let end = record.endTree, exists(start, in: repository), exists(end, in: repository) else {
            throw ChangesError(ChangesError.unavailable, "The turn’s snapshots are no longer available.")
        }
        let entries = ChangesParse.nameStatus(try ChangesGit.checked(["diff", "--no-ext-diff", "--name-status", "--no-renames", "-z", start, end],
                                                                     in: repository.root).stdout)
        guard !entries.isEmpty else { throw ChangesError(ChangesError.invalid, "The turn changed no files.") }
        let (from, to) = redo ? (start, end) : (end, start)
        let paths = entries.map(\.path)
        let current = try snapshot(repository).tree
        let changed = try ChangesGit.checked(["diff", "--no-ext-diff", "--name-only", "--no-renames", "-z", from, current, "--"] + paths,
                                             in: repository.root, literalPaths: true)
            .stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard changed.isEmpty else {
            let names = changed.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let more = changed.count > 3 ? " and \(changed.count - 3) more" : ""
            throw ChangesError(ChangesError.changedSince,
                               "\(names)\(more) changed after the \(redo ? "undo" : "turn"), so Shepherd left the files as they are.",
                               files: changed)
        }
        // Files the target tree has come back from it; files it lacks go to the Trash.
        let absent: Set<Character> = redo ? ["D"] : ["A"]
        let restore = entries.filter { !absent.contains($0.status) }.map(\.path)
        let remove = entries.filter { absent.contains($0.status) }.map(\.path)
        if !restore.isEmpty { try restoreFiles(repository, from: to, paths: restore) }
        let root = URL(fileURLWithPath: repository.root, isDirectory: true)
        for path in remove {
            let url = root.appendingPathComponent(path)
            guard (try? url.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil else { continue }
            try trash(url)
        }
        turnStore.update(agentID) { records in
            guard let i = records.firstIndex(where: { $0.turn.id == turnID }) else { return }
            records[i].turn.state = redo ? .ready : .undone
        }
        publish(agentID)
        guard let turn = turnStore.published(agentID).last else { throw ChangesError(ChangesError.unavailable, "The turn is gone.") }
        return turn
    }

    /// Writes `paths` from `tree` into the working tree (`git restore --worktree`, through a
    /// throwaway index so the user's is never read for writing), with git's own filters and modes.
    private func restoreFiles(_ repository: Repository, from tree: String, paths: [String]) throws {
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let scratch = indexDirectory.appendingPathComponent(repository.key + ".restore")
        try? FileManager.default.removeItem(at: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try ChangesGit.checked(["read-tree", tree], in: repository.root, index: scratch.path)
        _ = try ChangesGit.checked(["restore", "--source=\(tree)", "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul"],
                                   in: repository.root, index: scratch.path, literalPaths: true,
                                   input: Data(paths.joined(separator: "\0").utf8))
    }
}
