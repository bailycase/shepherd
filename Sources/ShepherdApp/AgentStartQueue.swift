import Foundation
import ShepherdCore

/// The order restored agents' pi processes start in, when a launch brings back many at once.
///
/// Thirty pi processes booting together each take several times longer than one alone, so the
/// agent on screen would come up last among equals. Instead the agents the user is looking at
/// start at once, "ahead" of the queue, and the rest wait until those serve (or `aheadHold`
/// passes), then start `limit` at a time, each holding its slot until its pi serves, exits, or
/// `slotTimeout` passes. Selecting an agent that is still waiting starts it ahead at once.
/// Every agent still starts. `TerminalSessionStore` drives it; this is the bookkeeping, pure so
/// it can be tested without processes.
struct AgentStartQueue {
    /// Background starts under way at once: half the cores (2 to 8), so a burst leaves the rest
    /// to the app and the agent on screen, while a pi that mostly waits on the network at boot
    /// does not hold the queue up.
    static let limit = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
    /// How long background starts wait for the agents ahead of them to serve.
    static let aheadHold: Duration = .seconds(2)
    /// How long a background start holds its slot while its pi boots.
    static let slotTimeout: Duration = .seconds(5)

    let limit: Int
    /// Waiting to start, in start order.
    private(set) var waiting: [AgentID] = []
    /// Background starts under way, each holding a slot.
    private(set) var running: Set<AgentID> = []
    /// Started ahead of the queue and still booting: background starts wait for them.
    private(set) var ahead: Set<AgentID> = []
    /// To start ahead as soon as they are queued (on screen before their start was asked for).
    private(set) var wanted: Set<AgentID> = []
    /// Every agent whose start has begun, ahead or in the background.
    private(set) var started: Set<AgentID> = []

    init(limit: Int = AgentStartQueue.limit) {
        self.limit = limit
    }

    /// Queues `id`'s start. True when it is wanted on screen: the caller starts it now, ahead.
    mutating func enqueue(_ id: AgentID) -> Bool {
        guard !started.contains(id), !waiting.contains(id) else { return false }
        if wanted.remove(id) != nil {
            begin(id, ahead: true)
            return true
        }
        waiting.append(id)
        return false
    }

    /// `id` is on screen. True when it was waiting: the caller starts it now, ahead of the rest.
    /// An agent not queued yet starts ahead once it is; one already started is left alone.
    mutating func startAhead(_ id: AgentID) -> Bool {
        guard !started.contains(id) else { return false }
        guard let index = waiting.firstIndex(of: id) else {
            wanted.insert(id)
            return false
        }
        waiting.remove(at: index)
        begin(id, ahead: true)
        return true
    }

    /// `id`'s start is over (its pi serves, never spawned, or its time ran out: `slotTimeout`,
    /// or `aheadHold` for one ahead): it frees its slot, or stops holding the queue.
    mutating func finished(_ id: AgentID) {
        running.remove(id)
        ahead.remove(id)
    }

    /// The background starts to begin now, in order, as slots allow while nothing is ahead.
    mutating func next() -> [AgentID] {
        guard ahead.isEmpty else { return [] }
        var begun: [AgentID] = []
        while running.count < limit, !waiting.isEmpty {
            let id = waiting.removeFirst()
            begin(id, ahead: false)
            begun.append(id)
        }
        return begun
    }

    private mutating func begin(_ id: AgentID, ahead isAhead: Bool) {
        started.insert(id)
        if isAhead { ahead.insert(id) } else { running.insert(id) }
    }
}
