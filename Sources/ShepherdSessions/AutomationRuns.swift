import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The runs of each automation, kept by the server so a remote client can read how the last
/// ones went after their agents are gone (`automation-runs.json` in the support directory,
/// newest `limit` per automation). A run opens when an automation gains an agent and closes
/// when it loses it; in between it follows the agent's status. Confined to the server queue,
/// except `openRuns`; writes go to disk off it, in order.
final class AutomationRunLog: @unchecked Sendable {
    static let limit = 30

    private struct File: Codable {
        var version = 1
        var runs: [String: [AutomationRun]] = [:]
    }

    let url: URL
    /// Oldest first, by automation.
    private(set) var runs: [AutomationID: [AutomationRun]] = [:]
    private let writes = DispatchQueue(label: "shepherd.automation-runs", qos: .utility)
    private let openLock = NSLock()
    private var published: [AutomationID: AutomationRun] = [:]

    init(url: URL) {
        self.url = url
        reload()
    }

    /// Startup rereads under workspace ownership, including a retry after another owner stopped.
    func reload() {
        runs = [:]
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            runs = Dictionary(uniqueKeysWithValues: file.runs.map { (AutomationID(rawValue: $0.key), $0.value) })
        }
        publish()
    }

    /// Each automation's run still open (its agent exists), from any thread without waiting
    /// for the server queue. Published before the state that moved it is broadcast, so a GUI
    /// adopting that state finds its run here.
    var openRuns: [AutomationID: AutomationRun] {
        openLock.withLock { published }
    }

    /// The automation's runs, oldest first, as a client sees them: a run's agent only while
    /// that agent still exists in `state`.
    func runs(for automationID: AutomationID, in state: ShepherdState) -> [AutomationRun] {
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
        var next = runs
        for automation in new.automations {
            let previous = before[automation.id]?.agentID
            var list = next[automation.id] ?? []
            if previous != automation.agentID {
                if let previous, let index = list.lastIndex(where: { $0.agentID == previous && $0.endedAt == nil }) {
                    let status = old.agents.first { $0.id == previous }?.status
                    list[index] = Self.closed(list[index], status: status, at: time, result: nil)
                }
                if let agentID = automation.agentID {
                    let status = new.agents.first { $0.id == agentID }?.status ?? .idle
                    list.append(Self.following(AutomationRun(startedAt: time, result: .running, agentID: agentID),
                                               status: status, at: time))
                }
            } else if let agentID = automation.agentID,
                      let index = list.lastIndex(where: { $0.agentID == agentID && $0.endedAt == nil }),
                      let status = new.agents.first(where: { $0.id == agentID })?.status {
                list[index] = Self.following(list[index], status: status, at: time)
            }
            list = Self.recordTriggered(automation, list: list, old: old, new: new, at: time)
            next[automation.id] = Array(list.suffix(Self.limit))
        }
        let kept = Set(new.automations.map(\.id))
        for id in next.keys where !kept.contains(id) { next[id] = nil }
        next = next.filter { !$0.value.isEmpty }
        guard next != runs else { return }
        runs = next
        publish()
        save()
    }

    /// Triggered runs: a thread an automation started (`Agent.automationOrigin`) opens a run
    /// when it appears and closes when it goes; a run delivered to an existing thread
    /// (`openThreadRun`) closes when that thread settles. Both follow their thread's status and
    /// turn unread when it settles or asks.
    static func recordTriggered(_ automation: Automation, list: [AutomationRun], old: ShepherdState, new: ShepherdState,
                                at time: Double) -> [AutomationRun] {
        var list = list
        let agents = Dictionary(new.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let before = Dictionary(old.agents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A Project automation's run is a Project task: it follows the task, whose worker may not exist yet.
        let tasks = automation.projectID.map { id in
            Dictionary((new.projects.first { $0.id == id }?.tasks ?? []).map { ($0.workerAgentID, $0) }, uniquingKeysWith: { _, b in b })
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
        for agent in new.agents where agent.automationOrigin?.automationID == automation.id {
            guard before[agent.id]?.automationOrigin == nil,
                  !list.contains(where: { $0.agentID == agent.id }) else { continue }
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
        var list = runs[automationID] ?? []
        list.append(AutomationRun(startedAt: now.timeIntervalSince1970, result: .running, agentID: agentID,
                                  trigger: trigger, triggerURL: triggerURL))
        runs[automationID] = Array(list.suffix(Self.limit))
        publish()
        save()
    }

    /// A run that never started (its thread or worktree couldn't be made).
    func recordFailure(_ automationID: AutomationID, trigger: String?, triggerURL: String?, message: String, now: Date = Date()) {
        let time = now.timeIntervalSince1970
        var list = runs[automationID] ?? []
        list.append(AutomationRun(startedAt: time, endedAt: time, result: .failed, trigger: trigger, triggerURL: triggerURL,
                                  unread: true, failure: String(message.prefix(500))))
        runs[automationID] = Array(list.suffix(Self.limit))
        publish()
        save()
    }

    /// Clears unread dots: one run, or every run of a thread the user opened. True when any changed.
    @discardableResult
    func markRead(runID: UUID? = nil, agentID: AgentID? = nil) -> Bool {
        var changed = false
        for (id, list) in runs {
            runs[id] = list.map { run in
                guard run.unread, run.id == runID || (agentID != nil && run.agentID == agentID) else { return run }
                changed = true
                var run = run
                run.unread = false
                return run
            }
        }
        if changed { save() }
        return changed
    }

    /// The pull request a run's thread opened.
    func setPullRequest(agentID: AgentID, url: String) {
        var changed = false
        for (id, list) in runs {
            runs[id] = list.map { run in
                guard run.agentID == agentID, run.pullRequestURL != url else { return run }
                changed = true
                var run = run
                run.pullRequestURL = url
                return run
            }
        }
        if changed { save() }
    }

    /// Closes every run still open: the host is starting, and their agents died with the last
    /// launch. A run that had finished its turn stays finished; any other was interrupted.
    /// Threads in `keeping` (triggered runs, which outlive a relaunch) stay linked to their run.
    func closeOpenRuns(keeping: Set<AgentID> = [], now: Date = Date()) {
        let time = now.timeIntervalSince1970
        var changed = false
        for (id, list) in runs {
            runs[id] = list.map { run in
                guard run.endedAt == nil else { return run }
                changed = true
                var closed = Self.closed(run, status: nil, at: time, result: run.settledAt == nil ? .interrupted : .finished)
                if let agentID = run.agentID, keeping.contains(agentID) { closed.agentID = agentID }
                return closed
            }
        }
        if changed {
            publish()
            save()
        }
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
            if let run = list.last, run.endedAt == nil { open[id] = run }
        }
        openLock.withLock { published = open }
    }

    private func save() {
        let file = File(runs: Dictionary(uniqueKeysWithValues: runs.map { ($0.key.rawValue, $0.value) }))
        let url = url
        writes.async {
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
