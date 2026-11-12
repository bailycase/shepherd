import Foundation
import ShepherdCore
import ShepherdProtocol

/// Who wrote in a working tree, and when: the evidence a turn's own files are cut by
/// (`TurnAttribution`). In memory only, behind `ChangesService.writers`; every append is O(1)
/// and no git runs under its lock. Nothing is persisted: no turn spans a relaunch, so a record
/// settled before one keeps the files it was cut to.
struct WriterLog {
    /// One agent's turn, from the start of its baseline to the end of its end capture.
    struct Window: Equatable {
        var agent: AgentID
        var turn: UUID
        var cwd: String
        var interval: TurnAttribution.Interval
        /// What the turn's record was cut from, once it settled: a late writer re-cuts it.
        var settled: Settled?
    }

    struct Settled: Equatable {
        var startTree: String
        /// The working tree when the turn ended, whatever else wrote in it.
        var realEnd: String
        /// The paths of the files the record owns now. It only shrinks.
        var own: Set<String>
        /// `WriterLog.sequence` when it was cut: nothing newer, nothing to redo.
        var sequence: Int
    }

    /// An `edit` or `write` call, from its start to its end, as the host read the events.
    struct Call: Equatable {
        var id: String
        var agent: AgentID
        /// The turn it ran in, when the agent's turn was open.
        var turn: UUID?
        var cwd: String
        /// As pi received it, resolved against `cwd` only when it is classified.
        var path: String
        /// Its start already carries the lead.
        var interval: TurnAttribution.Interval
        /// Nil until it ends.
        var ok: Bool?
    }

    /// Shepherd writing files for the person: an Undo, a Redo, a Revert, a Save. Or, as a tree
    /// event, running something that rewrites a whole working tree under them: a branch switch,
    /// an update from the base, a commit that runs hooks.
    struct Span: Equatable {
        var id: UUID
        /// Absolute. None for a tree event.
        var paths: [String]
        /// The folder whose working tree a tree event rewrites; nil for a write of `paths`.
        var tree: String? = nil
        var interval: TurnAttribution.Interval
    }

    static let windowCap = 256
    static let callCap = 4_096
    static let spanCap = 512
    static let lostCap = 64
    /// How long a closed item stays when nothing open or undoable could still be judged by it, ms.
    static let keep: Double = 3_600_000

    private(set) var windows: [Window] = []
    private(set) var calls: [Call] = []
    private(set) var spans: [Span] = []
    /// Stretches an eviction forced out of the log while a turn could still need them.
    private(set) var lost: [TurnAttribution.Interval] = []
    private(set) var sequence = 0
    private var prompts: [AgentID: Double] = [:]

    // MARK: Appends

    /// The host is about to hand `agent` a prompt: the turn it starts begins here.
    mutating func promptSent(_ agent: AgentID, at time: Double) { prompts[agent] = time }

    mutating func promptDiscarded(_ agent: AgentID) { prompts[agent] = nil }

    /// A turn started. Returns its interval.
    @discardableResult
    mutating func openWindow(agent: AgentID, turn: UUID, cwd: String, receivedAt time: Double) -> TurnAttribution.Interval {
        let interval = TurnAttribution.Interval(start: TurnAttribution.windowStart(promptedAt: prompts.removeValue(forKey: agent), receivedAt: time))
        windows.append(Window(agent: agent, turn: turn, cwd: cwd, interval: interval))
        sequence += 1
        trim()
        return interval
    }

    /// An edit or write call started. Returns its interval.
    @discardableResult
    mutating func startCall(id: String, agent: AgentID, cwd: String, path: String, receivedAt time: Double) -> TurnAttribution.Interval {
        let interval = TurnAttribution.Interval(start: time - TurnAttribution.lead)
        let turn = windows.last { $0.agent == agent && $0.interval.end == nil }?.turn
        calls.append(Call(id: id, agent: agent, turn: turn, cwd: cwd, path: path, interval: interval))
        sequence += 1
        trim()
        return interval
    }

    mutating func endCall(id: String, agent: AgentID, ok: Bool, at time: Double) {
        guard let index = calls.lastIndex(where: { $0.id == id && $0.agent == agent && $0.interval.end == nil }) else { return }
        calls[index].interval.end = max(time, calls[index].interval.start)
        calls[index].ok = ok
    }

    /// Shepherd is about to write `paths` (absolute) for the person, or to rewrite the working
    /// tree of `tree`. Returns its interval.
    @discardableResult
    mutating func beginSpan(_ id: UUID, paths: [String], tree: String? = nil, at time: Double) -> TurnAttribution.Interval {
        let interval = TurnAttribution.Interval(start: time)
        spans.append(Span(id: id, paths: paths, tree: tree, interval: interval))
        sequence += 1
        trim()
        return interval
    }

    mutating func endSpan(_ id: UUID, at time: Double) {
        guard let index = spans.lastIndex(where: { $0.id == id && $0.interval.end == nil }) else { return }
        spans[index].interval.end = max(time, spans[index].interval.start)
    }

    /// The turn's end capture finished (or it never began): the window closes, and so does any
    /// call of the turn that never reported its end.
    mutating func closeWindow(turn: UUID, at time: Double) {
        guard let index = windows.lastIndex(where: { $0.turn == turn }) else { return }
        if windows[index].interval.end == nil {
            windows[index].interval.end = max(time, windows[index].interval.start)
            sequence += 1
        }
        for i in calls.indices where calls[i].turn == turn && calls[i].interval.end == nil {
            calls[i].interval.end = max(time, calls[i].interval.start)
        }
    }

    /// The agent is gone, or its pi exited: whatever it had open ends now. Windows and calls
    /// stay in the log: a deleted agent's leftover edits keep another agent's overlapping turn shared.
    mutating func agentEnded(_ agent: AgentID, at time: Double) {
        prompts[agent] = nil
        for i in windows.indices where windows[i].agent == agent && windows[i].interval.end == nil {
            windows[i].interval.end = max(time, windows[i].interval.start)
            sequence += 1
        }
        for i in calls.indices where calls[i].agent == agent && calls[i].interval.end == nil {
            calls[i].interval.end = max(time, calls[i].interval.start)
        }
    }

    /// The turn's record was cut from the log as it stood at `settled.sequence`.
    mutating func settle(turn: UUID, _ settled: Settled) {
        guard let index = windows.lastIndex(where: { $0.turn == turn }) else { return }
        windows[index].settled = settled
    }

    // MARK: Questions

    /// The agents whose latest turn is settled and overlaps `interval`: a writer that arrived
    /// late may have mixed their files. By time only; the working tree is not looked at.
    func affectedAgents(by interval: TurnAttribution.Interval, excluding agent: AgentID?, now: Double) -> [AgentID] {
        var seen: Set<AgentID> = []
        var affected: [AgentID] = []
        for window in windows.reversed() where seen.insert(window.agent).inserted {
            if window.agent != agent, window.settled != nil, window.interval.overlaps(interval, now: now) { affected.append(window.agent) }
        }
        return affected
    }

    // MARK: Bounds

    /// Each agent's latest turn (the only one Undo can reach) and every open one.
    private func protected() -> [TurnAttribution.Interval] {
        var seen: Set<AgentID> = []
        var kept: [TurnAttribution.Interval] = []
        for window in windows.reversed() where seen.insert(window.agent).inserted || window.interval.end == nil {
            kept.append(window.interval)
        }
        return kept
    }

    private static func evict<Item>(_ items: inout [Item], cap: Int, protected: [TurnAttribution.Interval], lost: inout [TurnAttribution.Interval],
                                    interval: (Item) -> TurnAttribution.Interval) {
        while items.count > cap {
            let forever = Double.greatestFiniteMagnitude
            if let index = items.firstIndex(where: { item in !protected.contains { $0.overlaps(interval(item), now: forever) } }) {
                items.remove(at: index)
            } else {
                // Nothing is safe to drop: the turns it could judge treat every file as other.
                lost.append(interval(items.removeFirst()))
                if lost.count > lostCap { lost.removeFirst() }
            }
        }
    }

    private mutating func trim() {
        guard windows.count > Self.windowCap || calls.count > Self.callCap || spans.count > Self.spanCap else { return }
        let protected = protected()
        Self.evict(&windows, cap: Self.windowCap, protected: protected, lost: &lost) { $0.interval }
        Self.evict(&calls, cap: Self.callCap, protected: protected, lost: &lost) { $0.interval }
        Self.evict(&spans, cap: Self.spanCap, protected: protected, lost: &lost) { $0.interval }
    }

    /// Drops what ended over an hour ago and before every open and undoable turn began.
    mutating func prune(now: Double) {
        let protected = protected()
        let horizon = min(now - Self.keep, protected.map(\.start).min() ?? .greatestFiniteMagnitude)
        func stale(_ interval: TurnAttribution.Interval) -> Bool { interval.end.map { $0 < horizon } ?? false }
        windows.removeAll { stale($0.interval) }
        calls.removeAll { stale($0.interval) }
        spans.removeAll { stale($0.interval) }
        lost.removeAll { stale($0) }
    }
}

// MARK: - The service's side

extension ChangesService {
    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    /// Server queue. The host is about to prompt `agentID`: the turn it starts begins now,
    /// before any write the prompt can cause.
    func promptSent(agentID: AgentID, at time: Double = ChangesService.nowMs()) {
        writers.withValue { $0.promptSent(agentID, at: time) }
    }

    /// The prepared turn was dropped: no turn starts from this prompt.
    func promptDiscarded(agentID: AgentID) {
        writers.withValue { $0.promptDiscarded(agentID) }
    }

    /// Server queue: pi began an `edit` or `write` of `path` for `agentID`.
    func callStarted(agentID: AgentID, callID: String, path: String, at time: Double = ChangesService.nowMs()) {
        guard let cwd = agentContext(agentID)?.cwd else { return }
        let interval = writers.withValue { $0.startCall(id: callID, agent: agentID, cwd: cwd, path: path, receivedAt: time) }
        reclassifyAffected(by: interval, excluding: agentID, now: time)
    }

    /// Server queue: the call ended. A call pi stopped has not succeeded.
    func callEnded(agentID: AgentID, callID: String, ok: Bool, at time: Double = ChangesService.nowMs()) {
        writers.withValue { $0.endCall(id: callID, agent: agentID, ok: ok, at: time) }
    }

    /// Server queue: the agent's pi exited, or the agent was deleted. Its log entries stay.
    func agentEnded(_ agentID: AgentID, at time: Double = ChangesService.nowMs()) {
        writers.withValue { $0.agentEnded(agentID, at: time) }
    }

    /// Shepherd is about to write `paths` (relative to `repository`) for the person; close the
    /// returned span with `endWrite` once the last one is written.
    func beginWrite(_ repository: Repository, paths: [String]) -> UUID {
        beginSpan(UUID(), paths: paths.map { repository.root + "/" + $0 })
    }

    /// The same for `paths` as the writer names them (absolute, through any symlink): this Mac's
    /// app saving or reverting a file, or a paired device's Save. A path counts where git sees it
    /// (its folder resolved) and, when it is a symlink, where the write lands.
    @discardableResult
    func beginWrite(_ id: UUID = UUID(), absolute paths: [String]) -> UUID {
        beginSpan(id, paths: paths.flatMap(Self.spanPaths))
    }

    /// Shepherd is about to run something for the person that rewrites the working tree of `cwd`
    /// (a branch switch, an update from the base, an abort, a commit that runs hooks). A turn that
    /// ran there meanwhile can't tell its files from the operation's: it is shared, and owns only
    /// the files its own edit and write calls named. Close it with `endWrite`.
    @discardableResult
    func beginTreeEvent(_ id: UUID = UUID(), cwd: String) -> UUID {
        beginSpan(id, paths: [], tree: cwd)
    }

    private func beginSpan(_ id: UUID, paths: [String], tree: String? = nil) -> UUID {
        let time = Self.nowMs()
        let interval = writers.withValue { $0.beginSpan(id, paths: paths, tree: tree, at: time) }
        reclassifyAffected(by: interval, excluding: nil, now: time)
        return id
    }

    private static func spanPaths(_ path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        let parent = Self.realPath((path as NSString).deletingLastPathComponent)
        let beside = parent == "/" ? "/" + name : parent + "/" + name
        let through = Self.realPath(path)
        return through == beside ? [beside] : [beside, through]
    }

    /// Server's `changesWriteBegan` from this Mac's app: `paths` it is about to write, or none
    /// for a tree event in the agent's working tree. `id` is the app's. The tree is the agent's
    /// own, as the app's branch actions and commits run in it; one that ran in another
    /// repository would need to name it.
    func personWriteBegan(_ id: UUID, agentID: AgentID, paths: [String]?) throws {
        guard let paths else {
            beginTreeEvent(id, cwd: try context(agentID, cwd: nil).cwd)
            return
        }
        guard !paths.isEmpty, paths.count <= Self.personWritePaths,
              paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
            throw ChangesError(ChangesError.invalid, "Not files of this Mac.")
        }
        beginWrite(id, absolute: paths)
    }

    /// Most files one write the app reports may name.
    static let personWritePaths = 64

    func endWrite(_ id: UUID) {
        let time = Self.nowMs()
        writers.withValue { $0.endSpan(id, at: time) }
    }

    /// Queues a re-cut for each agent whose settled turn the new item overlaps in time. The
    /// work runs on the agent's capture queue, once however many writers arrive meanwhile.
    func reclassifyAffected(by interval: TurnAttribution.Interval, excluding agent: AgentID?, now: Double) {
        for affected in writers.withValue({ $0.affectedAgents(by: interval, excluding: agent, now: now) }) {
            queueReclassify(affected)
        }
    }

    func queueReclassify(_ agentID: AgentID) {
        guard reclassifying.withValue({ $0.insert(agentID).inserted }) else { return }
        captureQueue(agentID).async { [self] in
            reclassifying.withValue { $0.remove(agentID) }
            reclassifyQuietly(agentID: agentID)
        }
    }
}
