import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The runs of each automation, kept by the server so a remote client can read how the last
/// ones went after their agents are gone (`automation-runs.json` in the support directory,
/// newest `limit` per automation). A run opens when an automation gains an agent and closes
/// when it loses it, or when its pi stops on its own (the agent stays); in between it follows the
/// agent's status. Confined to the server queue,
/// except `openRuns` and `problem`; writes go to disk off it, in order.
///
/// Only a missing file means no history. A file that can't be read (`damage`) is not rewritten:
/// every change is refused and the host starts no run (a run couldn't be recorded, and the live
/// count that gates the next one comes from here) until a re-read is clean again. The check is a
/// read before an atomic rename, not a conditional replace, so an outside editor that saves
/// between the two can still be overwritten.
final class AutomationRunLog: @unchecked Sendable {
    static let limit = 30

    fileprivate struct File: Codable {
        var version = 1
        var runs: [String: [AutomationRun]] = [:]
    }

    let url: URL
    /// Oldest first, by automation.
    private(set) var runs: [AutomationID: [AutomationRun]] = [:]
    private let writes = DispatchQueue(label: "shepherd.automation-runs", qos: .utility)
    private let openLock = NSLock()
    private var published: [AutomationID: AutomationRun] = [:]
    private var publishedProblem: String?
    /// Damage the queued writer saw, taken over by the next `refresh` (guarded by `openLock`).
    private var writerDamage: AutomationFileDamage?
    /// Why the file can't be read; changes are refused while it is set.
    private var damage: AutomationFileDamage?
    /// The history when the file went bad, written back if the file is then removed. Nil when it
    /// was bad from the start.
    private var lastGood: [AutomationID: [AutomationRun]]?
    /// After every change, on the server queue (`startLocalListener`: this Mac's app reads the runs again).
    var changed: () -> Void = {}

    init(url: URL) {
        self.url = url
        reload()
    }

    /// Startup rereads under workspace ownership, including a retry after another owner stopped.
    func reload() {
        runs = [:]
        damage = nil
        lastGood = nil
        switch PersistedFile<File>.load(from: url) {
        case .loaded(let file): runs = file.history
        case .missing: break
        case .damaged(let original, let error): setDamage(AutomationFileDamage("run history", at: url, original: original, error: error))
        }
        publishProblem()
        publish()
    }

    /// Why the file can't be read, in words to show a person, from any thread. It says the file is
    /// untouched and how to fix it; the log re-reads the file on its own once that's done.
    var problem: String? {
        openLock.withLock { publishedProblem }
    }

    /// The same, after reading the file again (server queue): damage that came up while the host
    /// ran shows here, and so does a repair. `reading: false` reads only while it is damaged, for
    /// the page's frequent reads; a write, a start or a trigger check always reads.
    func recheck(reading: Bool = true) -> String? {
        _ = refresh(reading: reading)
        return problem
    }

    /// Each automation's latest run while it is open, or ended unsettled with its agent kept (its
    /// pi stopped on its own, its thread stays), from any thread without waiting for the server
    /// queue. Published before the state that moved it is broadcast, so a GUI adopting that state
    /// finds its run here.
    var openRuns: [AutomationID: AutomationRun] {
        openLock.withLock { published }
    }

    /// The automation's runs, oldest first, as a client sees them: a run's agent only while
    /// that agent still exists in `state`.
    func runs(for automationID: AutomationID, in state: ShepherdState) -> [AutomationRun] {
        _ = refresh(reading: false)
        let agents = Set(state.agents.map(\.id))
        return (runs[automationID] ?? []).map { run in
            var run = run
            if let agentID = run.agentID, !agents.contains(agentID) { run.agentID = nil }
            return run
        }
    }

    /// Records what moved between two committed states: runs that started (an automation
    /// gained an agent), ended (it lost one), or changed state, and forgets the runs of removed
    /// automations. Saves when anything changed.
    func record(from old: ShepherdState, to new: ShepherdState, now: Date = Date()) {
        guard !old.automations.isEmpty || !new.automations.isEmpty else { return }
        let time = now.timeIntervalSince1970
        let before = Dictionary(old.automations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldAgents = Dictionary(old.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let agents = Dictionary(new.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var triggered: [AutomationID: [Agent]] = [:]
        for agent in new.agents {
            if let origin = agent.automationOrigin, oldAgents[agent.id]?.automationOrigin == nil {
                triggered[origin.automationID, default: []].append(agent)
            }
        }
        guard refresh(reading: false) else { return }
        var next = runs
        for automation in new.automations {
            let previous = before[automation.id]?.agentID
            var list = next[automation.id] ?? []
            if previous != automation.agentID {
                if let previous, let index = list.lastIndex(where: { $0.agentID == previous }) {
                    if list[index].endedAt == nil {
                        list[index] = Self.closed(list[index], status: oldAgents[previous]?.status, at: time, result: nil)
                    } else {
                        // Its pi stopped on its own and it ended then: only the thread it kept goes now.
                        list[index].agentID = nil
                    }
                }
                if let agentID = automation.agentID {
                    let status = agents[agentID]?.status ?? .idle
                    list.append(Self.following(AutomationRun(startedAt: time, result: .running, agentID: agentID),
                                               status: status, at: time))
                }
            } else if let agentID = automation.agentID,
                      let index = list.lastIndex(where: { $0.agentID == agentID && $0.endedAt == nil }),
                      let status = agents[agentID]?.status {
                list[index] = Self.following(list[index], status: status, at: time)
            }
            list = Self.recordTriggered(automation, list: list, before: oldAgents, agents: agents,
                                        triggered: triggered[automation.id] ?? [], projects: new.projects, at: time)
            next[automation.id] = Array(list.suffix(Self.limit))
        }
        let kept = Set(new.automations.map(\.id))
        for id in next.keys where !kept.contains(id) { next[id] = nil }
        next = next.filter { !$0.value.isEmpty }
        guard next != runs else { return }
        commit(next)
    }

    /// Triggered runs: a thread an automation started (`Agent.automationOrigin`) opens a run
    /// when it appears and closes when it goes; a run delivered to an existing thread
    /// (`openThreadRun`) closes when that thread settles. Both follow their thread's status and
    /// turn unread when it settles or asks.
    private static func recordTriggered(_ automation: Automation, list: [AutomationRun], before: [AgentID: Agent],
                                        agents: [AgentID: Agent], triggered: [Agent], projects: [Project],
                                        at time: Double) -> [AutomationRun] {
        var list = list
        // A Project automation's run is a Project task: it follows the task, whose worker may not exist yet.
        let tasks = automation.projectID.map { id in
            Dictionary((projects.first { $0.id == id }?.tasks ?? []).map { ($0.workerAgentID, $0) }, uniquingKeysWith: { _, b in b })
        } ?? [:]
        for index in list.indices where list[index].endedAt == nil {
            guard let agentID = list[index].agentID, agentID != automation.agentID else { continue }
            if let task = tasks[agentID] {
                let previous = list[index]
                var run = previous
                switch task.phase {
                case .queued, .reserved, .running, .unknown: run.result = .running
                case .waiting: run.result = .needsYou
                case .settled, .resolved:
                    run.result = .finished
                    run.settledAt = run.settledAt ?? time
                    run.endedAt = time
                case .failed:
                    run.result = .failed
                    run.failure = task.error
                    run.endedAt = time
                }
                if run.result != previous.result, run.result == .finished || run.result == .needsYou || run.result == .failed { run.unread = true }
                list[index] = run
                continue
            }
            guard let agent = agents[agentID] else {
                list[index] = closed(list[index], status: before[agentID]?.status, at: time, result: nil)
                continue
            }
            let previous = list[index]
            var run = following(previous, status: agent.status, at: time)
            // A turn that ended in an error (the model refused, a sign-in expired) is a failed run, not a finished one.
            if run.result == .finished, let failure = agent.lastFailure {
                run.result = .failed
                run.failure = String(failure.prefix(500))
            }
            if run.result != previous.result, run.result == .finished || run.result == .needsYou || run.result == .failed { run.unread = true }
            // A run delivered to an existing thread ends with that thread's turn; the thread stays.
            if agent.automationOrigin?.automationID != automation.id, run.result == .finished {
                run.endedAt = time
            }
            list[index] = run
        }
        for agent in triggered {
            guard !list.contains(where: { $0.agentID == agent.id }) else { continue }
            let origin = agent.automationOrigin
            list.append(following(AutomationRun(startedAt: time, result: .running, agentID: agent.id,
                                                trigger: origin?.trigger, triggerURL: origin?.triggerURL),
                                  status: agent.status, at: time))
        }
        return list
    }

    /// A run delivered to an existing thread (a `.thread` destination) opens here; it closes when
    /// the thread's turn settles.
    func openThreadRun(_ automationID: AutomationID, agentID: AgentID, trigger: String?, triggerURL: String?, now: Date = Date()) {
        guard refresh(reading: false) else { return }
        var next = runs
        var list = next[automationID] ?? []
        list.append(AutomationRun(startedAt: now.timeIntervalSince1970, result: .running, agentID: agentID,
                                  trigger: trigger, triggerURL: triggerURL))
        next[automationID] = Array(list.suffix(Self.limit))
        commit(next)
    }

    /// The agent's pi stopped on its own: each run of it that had not settled ends as failed with
    /// `failure`. The agent stays (`agentID` is kept, so the run still opens its thread), and
    /// neither Run now nor a trigger waits on a run that is over. A run that already settled
    /// stays finished. True when a run changed.
    @discardableResult
    func agentStopped(_ agentID: AgentID, failure: String, now: Date = Date()) -> Bool {
        let time = now.timeIntervalSince1970
        guard refresh(reading: false) else { return false }
        var changed = false
        var next = runs
        for (id, list) in next {
            next[id] = list.map { run in
                guard run.agentID == agentID, run.endedAt == nil, run.settledAt == nil else { return run }
                changed = true
                var run = run
                run.result = .failed
                run.failure = String(failure.prefix(500))
                run.endedAt = time
                run.unread = true
                return run
            }
        }
        return changed && commit(next)
    }

    /// A run that never started (its thread or worktree couldn't be made).
    func recordFailure(_ automationID: AutomationID, trigger: String?, triggerURL: String?, message: String, now: Date = Date()) {
        guard refresh(reading: false) else { return }
        let time = now.timeIntervalSince1970
        var next = runs
        var list = next[automationID] ?? []
        list.append(AutomationRun(startedAt: time, endedAt: time, result: .failed, trigger: trigger, triggerURL: triggerURL,
                                  unread: true, failure: String(message.prefix(500))))
        next[automationID] = Array(list.suffix(Self.limit))
        commit(next)
    }

    /// Clears unread dots: one run, or every run of a thread the user opened. True when any changed.
    @discardableResult
    func markRead(runID: UUID? = nil, agentID: AgentID? = nil) -> Bool {
        guard refresh(reading: false) else { return false }
        var changed = false
        var next = runs
        for (id, list) in next {
            next[id] = list.map { run in
                guard run.unread, run.id == runID || (agentID != nil && run.agentID == agentID) else { return run }
                changed = true
                var run = run
                run.unread = false
                return run
            }
        }
        return changed && commit(next)
    }

    /// The pull request a run's thread opened.
    func setPullRequest(agentID: AgentID, url: String) {
        guard refresh(reading: false) else { return }
        var changed = false
        var next = runs
        for (id, list) in next {
            next[id] = list.map { run in
                guard run.agentID == agentID, run.pullRequestURL != url else { return run }
                changed = true
                var run = run
                run.pullRequestURL = url
                return run
            }
        }
        if changed { commit(next) }
    }

    /// Closes every run still open: the host is starting, and their agents died with the last
    /// launch. A run that had finished its turn stays finished; any other was interrupted.
    /// Threads in `keeping` (triggered runs, which outlive a relaunch) stay linked to their run.
    func closeOpenRuns(keeping: Set<AgentID> = [], now: Date = Date()) {
        guard refresh(reading: false) else { return }
        let time = now.timeIntervalSince1970
        var changed = false
        var next = runs
        for (id, list) in next {
            next[id] = list.map { run in
                guard run.endedAt == nil else { return run }
                changed = true
                var closed = Self.closed(run, status: nil, at: time, result: run.settledAt == nil ? .interrupted : .finished)
                if let agentID = run.agentID, keeping.contains(agentID) { closed.agentID = agentID }
                return closed
            }
        }
        if changed { commit(next) }
    }

    /// Waits for every write queued so far (the server stopping, and tests).
    func flush() {
        writes.sync {}
    }

    /// An open run following its agent's status.
    static func following(_ run: AutomationRun, status: AgentStatus, at time: Double) -> AutomationRun {
        var run = run
        switch status {
        case .working: run.result = .running
        case .blocked: run.result = .needsYou
        case .done:
            run.result = .finished
            if run.settledAt == nil { run.settledAt = time }
        case .idle:
            // pi starting reports idle before its first turn; after one, idle is still finished.
            run.result = run.settledAt == nil ? .running : .finished
        }
        return run
    }

    /// A run whose agent went away: finished if its agent had finished its turn, else stopped
    /// (or `result`, when the caller knows better).
    static func closed(_ run: AutomationRun, status: AgentStatus?, at time: Double, result: AutomationRunResult?) -> AutomationRun {
        var run = run
        run.endedAt = time
        run.agentID = nil
        if let result {
            run.result = result
        } else {
            let finished = status == .done || (status == .idle && run.settledAt != nil)
            run.result = finished ? .finished : .stopped
        }
        return run
    }

    private func publish() {
        var open: [AutomationID: AutomationRun] = [:]
        for (id, list) in runs {
            // An ended run that never settled and keeps its agent is one whose pi stopped on its own
            // (`agentStopped`): published so the GUI sees the thread is over, not starting.
            if let run = list.last, run.endedAt == nil || (run.agentID != nil && run.settledAt == nil) { open[id] = run }
        }
        openLock.withLock { published = open }
    }

    /// Takes `next` as the history and saves it. False, with nothing changed, while the file is
    /// damaged: the disk is checked first because it can go bad while the host runs. Callers build
    /// `next` after `refresh(reading: false)`, so a repair is taken over before a change lands on it.
    @discardableResult
    private func commit(_ next: [AutomationID: [AutomationRun]]) -> Bool {
        guard refresh(reading: true) else { return false }
        runs = next
        publish()
        save()
        return true
    }

    /// Whether the file is readable. While damaged, reads it again and recovers once it is clean:
    /// a file that reads takes over, and a removed one gets the last good history back. When
    /// healthy it reads only if `reading`, and otherwise trusts what is in memory (a save may not
    /// have landed yet).
    private func refresh(reading: Bool) -> Bool {
        if let seen = openLock.withLock({ () -> AutomationFileDamage? in defer { writerDamage = nil }; return writerDamage }), damage == nil {
            lastGood = runs
            setDamage(seen)
        }
        guard damage != nil || reading else { return true }
        switch PersistedFile<File>.load(from: url) {
        case .loaded(let file):
            guard damage != nil else { return true }
            runs = file.history
        case .missing:
            guard damage != nil else { return true }
            runs = lastGood ?? [:]
            if lastGood != nil { writeAll() }
        case .damaged(let original, let error):
            if damage == nil { lastGood = runs }
            setDamage(AutomationFileDamage("run history", at: url, original: original, error: error))
            return false
        }
        ShepherdLog.info("Automation run history recovered: \(url.path)")
        damage = nil
        lastGood = nil
        publish()
        publishProblem()
        changed()
        return true
    }

    private func setDamage(_ new: AutomationFileDamage) {
        guard new != damage else { return }
        ShepherdLog.error("Automation run history unreadable and left untouched: \(new)")
        damage = new
        publishProblem()
        changed()
    }

    private func publishProblem() {
        let text = damage.map {
            "\($0). Shepherd left the file as it is, so nothing starts and no run is recorded until it reads cleanly. "
                + "Fix the JSON, restore a backup, or move the file aside to start with no history; Shepherd checks again on its own."
        }
        openLock.withLock { publishedProblem = text }
    }

    private func save() {
        changed()
        writeAll()
    }

    private func writeAll() {
        let file = File(runs: Dictionary(uniqueKeysWithValues: runs.map { ($0.key.rawValue, $0.value) }))
        let url = url
        writes.async { [self] in
            // The file can go bad after the change was accepted, before this write runs. The log
            // learns of it here, so the next change recovers from a restore instead of overwriting it.
            if case .damaged(let original, let error) = PersistedFile<File>.load(from: url) {
                ShepherdLog.warning("automation runs not saved: the file is unreadable and was not rewritten")
                openLock.withLock { writerDamage = AutomationFileDamage("run history", at: url, original: original, error: error) }
                return
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(file).write(to: url, options: .atomic)
            } catch {
                ShepherdLog.warning("automation runs not saved: \(error)")
            }
        }
    }
}

extension AutomationRunLog.File {
    var history: [AutomationID: [AutomationRun]] {
        Dictionary(uniqueKeysWithValues: runs.map { (AutomationID(rawValue: $0.key), $0.value) })
    }

    /// Every file this app wrote has `runs` (empty is `{}`), so an object without it is some other
    /// file, not no history. Older files may omit `version`; a present null is damage, not an omission.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.contains(.version) ? c.decode(Int.self, forKey: .version) : 1
        runs = try c.decode([String: [AutomationRun]].self, forKey: .runs)
    }
}
