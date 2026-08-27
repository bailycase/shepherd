import Foundation
import ShepherdCore
import ShepherdProtocol

/// Live pi-subagents child runs per agent — the sidebar's subagent rows.
///
/// Pure value logic, separated from the view model for tests. Rows are
/// ephemeral display state: pi-subagents owns the runs; Shepherd only mirrors
/// the extension's publishes and enforces row lifecycle so nothing stale can
/// stick in the UI:
///   - a publish replaces the agent's rows wholesale (the extension always
///     sends its full projection),
///   - terminal rows expire after `terminalTTL` even if no publish follows,
///   - an agent whose extension has gone quiet (`staleAfter` without any
///     publish) loses all its rows — a killed pi can't strand "running" rows,
///   - `clear(agent:)` serves the hard cases (process exit, agent deletion).
struct ChildRuns {
    /// Terminal rows linger this long so a finished lane stays readable
    /// (`done`) until the batch resolves; the extension's parent-turn sweep
    /// usually clears them sooner.
    var terminalTTL: TimeInterval = 300
    /// No publish for this long means the publisher is gone (it refreshes
    /// every 45s while runs are active); drop every row for that agent.
    var staleAfter: TimeInterval = 120

    private struct ChildKey: Hashable {
        let agentID: AgentID
        let runID: String
    }

    private(set) var rows: [AgentID: [ChildRun]] = [:]
    private var publishedAt: [AgentID: Date] = [:]
    private var terminalSince: [ChildKey: Date] = [:]

    mutating func apply(agentID: AgentID, children: [ChildRun], now: Date = Date()) {
        publishedAt[agentID] = now
        // Track when each row first went terminal, keyed by agent and row id;
        // the TTL runs from that moment, not from the publish that repeats it.
        var seen = Set<ChildKey>()
        for child in children where child.isTerminal {
            let key = ChildKey(agentID: agentID, runID: child.id)
            seen.insert(key)
            if terminalSince[key] == nil { terminalSince[key] = now }
        }
        for key in Array(terminalSince.keys) where key.agentID == agentID && !seen.contains(key) {
            // Row disappeared or came back live (resume): forget the mark.
            terminalSince.removeValue(forKey: key)
        }
        let kept = children.filter { child in
            let key = ChildKey(agentID: agentID, runID: child.id)
            guard child.isTerminal, let since = terminalSince[key] else { return true }
            return now.timeIntervalSince(since) < terminalTTL
        }
        if kept.isEmpty {
            rows.removeValue(forKey: agentID)
            publishedAt.removeValue(forKey: agentID)
            for key in Array(terminalSince.keys) where key.agentID == agentID {
                terminalSince.removeValue(forKey: key)
            }
        } else {
            rows[agentID] = kept
        }
    }

    /// Drop expired terminal rows and rows from stale publishers. Returns
    /// true when anything changed (the caller re-renders).
    mutating func sweep(now: Date = Date()) -> Bool {
        var changed = false
        let agentIDs = Set(rows.keys).union(publishedAt.keys)
        for agentID in agentIDs {
            if let last = publishedAt[agentID], now.timeIntervalSince(last) > staleAfter {
                if rows.removeValue(forKey: agentID) != nil { changed = true }
                publishedAt.removeValue(forKey: agentID)
                for key in Array(terminalSince.keys) where key.agentID == agentID {
                    terminalSince.removeValue(forKey: key)
                }
                continue
            }
            guard let children = rows[agentID] else { continue }
            let kept = children.filter { child in
                let key = ChildKey(agentID: agentID, runID: child.id)
                guard child.isTerminal, let since = terminalSince[key] else { return true }
                return now.timeIntervalSince(since) < terminalTTL
            }
            if kept.count != children.count {
                if kept.isEmpty {
                    rows.removeValue(forKey: agentID)
                    publishedAt.removeValue(forKey: agentID)
                    for key in Array(terminalSince.keys) where key.agentID == agentID {
                        terminalSince.removeValue(forKey: key)
                    }
                } else {
                    rows[agentID] = kept
                    let keptKeys = Set(kept.map { ChildKey(agentID: agentID, runID: $0.id) })
                    for key in Array(terminalSince.keys) where key.agentID == agentID && !keptKeys.contains(key) {
                        terminalSince.removeValue(forKey: key)
                    }
                }
                changed = true
            }
        }
        return changed
    }

    mutating func clear(agent agentID: AgentID) {
        rows.removeValue(forKey: agentID)
        publishedAt.removeValue(forKey: agentID)
        for key in Array(terminalSince.keys) where key.agentID == agentID {
            terminalSince.removeValue(forKey: key)
        }
    }

    func children(of agentID: AgentID) -> [ChildRun] {
        rows[agentID] ?? []
    }

    /// Children needing attention, fleet-wide — feeds the waiting rollup.
    var attentionCount: Int {
        rows.values.reduce(0) { $0 + $1.count(where: \.needsAttention) }
    }
}
