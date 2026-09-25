import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The runs of each automation, kept by the server so a remote client can read how the last
/// ones went after their agents are gone (`automation-runs.json` in the support directory,
/// newest `limit` per automation). A run opens when an automation gains an agent and closes
/// when it loses it; in between it follows the agent's status. Confined to the server queue;
/// writes go to disk off it, in order.
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

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            runs = Dictionary(uniqueKeysWithValues: file.runs.map { (AutomationID(rawValue: $0.key), $0.value) })
        }
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
            next[automation.id] = Array(list.suffix(Self.limit))
        }
        let kept = Set(new.automations.map(\.id))
        for id in next.keys where !kept.contains(id) { next[id] = nil }
        next = next.filter { !$0.value.isEmpty }
        guard next != runs else { return }
        runs = next
        save()
    }

    /// Closes every run still open: the host is starting, and their agents died with the last
    /// launch. A run that had finished its turn stays finished; any other was interrupted.
    func closeOpenRuns(now: Date = Date()) {
        let time = now.timeIntervalSince1970
        var changed = false
        for (id, list) in runs {
            runs[id] = list.map { run in
                guard run.endedAt == nil else { return run }
                changed = true
                return Self.closed(run, status: nil, at: time, result: run.settledAt == nil ? .interrupted : .finished)
            }
        }
        if changed { save() }
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
