import Foundation
import ShepherdCore
import ShepherdProtocol

/// Ephemeral display state published by Shepherd's child runtime.
/// Each publish replaces the parent's rows. Finished transcripts remain inspectable until
/// the publisher removes them or the parent exits; stale live rows never strand the UI.
public struct ChildRuns {
    /// The publisher refreshes every five seconds while rows are visible.
    public var staleAfter: TimeInterval = 120

    public init() {}

    public private(set) var rows: [AgentID: [ChildRun]] = [:]
    private var publishedAt: [AgentID: Date] = [:]

    public mutating func apply(agentID: AgentID, children: [ChildRun], now: Date = Date()) {
        if children.isEmpty {
            clear(agent: agentID)
        } else {
            publishedAt[agentID] = now
            rows[agentID] = children
        }
    }

    /// Drop live rows from stale publishers. Finished transcripts remain inspectable.
    public mutating func sweep(now: Date = Date()) -> Bool {
        var changed = false
        for agentID in Array(publishedAt.keys) {
            guard let last = publishedAt[agentID], now.timeIntervalSince(last) > staleAfter else { continue }
            let retained = (rows[agentID] ?? []).filter {
                $0.isTerminal && !$0.needsAttention && $0.sessionFile != nil
            }
            if retained != rows[agentID] { changed = true }
            if retained.isEmpty { rows.removeValue(forKey: agentID) }
            else { rows[agentID] = retained }
            publishedAt.removeValue(forKey: agentID)
        }
        return changed
    }

    public mutating func clear(agent agentID: AgentID) {
        rows.removeValue(forKey: agentID)
        publishedAt.removeValue(forKey: agentID)
    }

    public func children(of agentID: AgentID) -> [ChildRun] {
        rows[agentID] ?? []
    }
}
