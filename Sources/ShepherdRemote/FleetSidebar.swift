import Foundation
import ShepherdCore
import ShepherdProtocol

// The Mac sidebar's thread groups for the iPhone and iPad (docs/design/sidebar.md): Needs you, Working, Done, Pinned and
// Recents, from `FleetModel`'s rows. Pins and what has been seen are this device's own view state, as they are each Mac's:
// never sent to a host.

/// A pinned thread as its row draws it: waiting on you (its reason), or any other state.
public enum FleetPinnedRow: Identifiable, Equatable, Sendable {
    case thread(FleetThreadRow)
    case attention(FleetAttention)

    public var ref: FleetRef {
        switch self {
        case .thread(let row): row.ref
        case .attention(let item): item.ref
        }
    }

    public var id: FleetRef { ref }
}

/// The groups, each thread in one of them.
public struct FleetSidebarGroups: Equatable, Sendable {
    /// Unpinned questions and blocked threads.
    public var needsYou: [FleetAttention] = []
    /// Unpinned threads running on a connected host.
    public var working: [FleetThreadRow] = []
    /// Unpinned finished threads whose completion this device has not seen.
    public var done: [FleetThreadRow] = []
    /// Pinned threads in pin order, oldest pin first, whatever their state.
    public var pinned: [FleetPinnedRow] = []
    /// The rest, designs' rows included.
    public var recents: [FleetThreadRow] = []

    public init() {}
}

/// Pins, observed completions and what was seen. Activity changes, including on reconnect, are not proof of completion.
/// Only pins persist. A relaunch observes existing Done threads anew; exact host completion chronology is unavailable.
public struct FleetSidebarState: Equatable, Sendable {
    struct Record: Equatable, Sendable {
        var finished: Bool
        var generation: Int
        var completedAt: Double?
    }

    public private(set) var pins: [FleetRef]
    private var records: [FleetRef: Record] = [:]
    private var generation = 0
    private var endpoints: [UUID: String] = [:]
    private var seen: [FleetRef: Int] = [:]
    /// The thread opened last, and the completion it showed while open.
    private var reading: FleetRef?
    private var readingGeneration: Int?
    private var selected: FleetRef?

    public init(pins: [FleetRef] = []) {
        var unique: [FleetRef] = []
        for pin in pins where !unique.contains(pin) { unique.append(pin) }
        self.pins = unique
    }

    public func isPinned(_ ref: FleetRef) -> Bool { pins.contains(ref) }

    /// Pinning again moves nothing; unpinning then pinning puts it last, as on the Mac.
    public mutating func pin(_ ref: FleetRef) {
        if !pins.contains(ref) { pins.append(ref) }
    }

    public mutating func unpin(_ ref: FleetRef) {
        pins.removeAll { $0 == ref }
    }

    /// Follows the hosts' pushed state. A pin goes when its host is no longer configured, or when a connected host no longer
    /// has its thread; never for a host that is offline or not reached yet. `sessions` is each connected host's connection id.
    public mutating func reconcile(_ hosts: [FleetHost], sessions _: [UUID: UUID]) {
        let configured = Set(hosts.map(\.id))
        pins.removeAll { !configured.contains($0.host) }
        records = records.filter { configured.contains($0.key.host) }
        seen = seen.filter { configured.contains($0.key.host) }
        endpoints = endpoints.filter { configured.contains($0.key) }
        for host in hosts {
            let endpoint = "\(host.address):\(host.port)"
            if let old = endpoints[host.id], old != endpoint {
                records = records.filter { $0.key.host != host.id }
                seen = seen.filter { $0.key.host != host.id }
                if reading?.host == host.id { readingGeneration = nil }
            }
            endpoints[host.id] = endpoint
        }
        for host in hosts where host.phase.isConnected {
            let live = Set(host.state.agents.map { FleetRef(host: host.id, agent: $0.id) })
            pins.removeAll { $0.host == host.id && !live.contains($0) }
            records = records.filter { $0.key.host != host.id || live.contains($0.key) }
            seen = seen.filter { $0.key.host != host.id || live.contains($0.key) }
            for agent in host.state.agents {
                observe(FleetRef(host: host.id, agent: agent.id), finished: agent.status == .done,
                        activity: agent.lastActiveAt)
            }
        }
        if let reading, reading == selected, let record = records[reading], record.finished {
            readingGeneration = record.generation
        }
    }

    private mutating func observe(_ ref: FleetRef, finished: Bool, activity: Double?) {
        let previous = records[ref]
        // ponytail: observed edges only. A whole run between observations can be missed;
        // exact chronology requires a host completion record, not a last-activity heuristic.
        let completed = finished && previous?.finished != true
        if completed { generation += 1 }
        records[ref] = Record(finished: finished, generation: completed ? generation : previous?.generation ?? 0,
                              completedAt: completed ? activity : previous?.completedAt)
    }

    /// The thread on screen changed. Opening another thread marks the one read before seen (the completion it showed);
    /// opening the same one again, or leaving for a page (nil), changes nothing.
    public mutating func select(_ ref: FleetRef?) {
        selected = ref
        guard let ref, ref != reading else { return }
        if let reading, let readingGeneration { seen[reading] = readingGeneration }
        reading = ref
        readingGeneration = records[ref].flatMap { $0.finished ? $0.generation : nil }
    }

    /// Mark all seen: these threads' current completions leave Done. A later completion brings one back.
    public mutating func markSeen(_ refs: [FleetRef]) {
        for ref in refs {
            if let record = records[ref], record.finished { seen[ref] = record.generation }
        }
    }

    private func unseenCompletion(_ ref: FleetRef) -> Bool {
        guard let record = records[ref], record.finished else { return false }
        return seen[ref] != record.generation
    }

    /// Every thread in one group. Automation runs stay with the automations (`FleetModel` never makes them thread rows), a
    /// design is never pinned, and a thread on a host that is offline is never Working or Done.
    public func groups(_ model: FleetModel) -> FleetSidebarGroups {
        let pinned = Set(pins)
        var groups = FleetSidebarGroups()
        var pinnedRows: [FleetRef: FleetPinnedRow] = [:]
        for item in model.needsYou {
            if item.origin == .thread, pinned.contains(item.ref) {
                if pinnedRows[item.ref] == nil { pinnedRows[item.ref] = .attention(item) }
            } else {
                groups.needsYou.append(item)
            }
        }
        let running = Set(model.running.map(\.ref))
        for row in model.recents {
            if row.design == nil, pinned.contains(row.ref) {
                if pinnedRows[row.ref] == nil { pinnedRows[row.ref] = .thread(row) }
            } else if running.contains(row.ref) {
                groups.working.append(row)
            } else if row.design == nil, !row.offline, row.status == .done, unseenCompletion(row.ref) {
                groups.done.append(row)
            } else {
                groups.recents.append(row)
            }
        }
        groups.pinned = pins.compactMap { pinnedRows[$0] }
        groups.done.sort { a, b in
            let left = records[a.ref], right = records[b.ref]
            let leftTime = left?.completedAt ?? -1, rightTime = right?.completedAt ?? -1
            return leftTime != rightTime ? leftTime > rightTime : (left?.generation ?? 0) > (right?.generation ?? 0)
        }
        return groups
    }
}

/// What a thread's menu offers for a remote host's thread (the Mac's row menu for a connected host, `RemoteRowMenu`): each
/// action only while its host is connected and new enough, and Pin, which is this device's, always for an ordinary thread.
public struct FleetThreadAbilities: Equatable, Sendable {
    public var connected: Bool
    public var worktree: Bool
    public var rename: Bool
    public var delete: Bool
    /// Not an automation's run (the next run replaces it) or a design's agent (its design is the row).
    public var pin: Bool
    /// The spaces Move to space lists: the host's visible ones. Empty when moving is not offered (a worktree, a run, an
    /// older or offline host).
    public var moveSpaces: [Space]
    public var review: Bool
    public var finalize: Bool

    public init(agent: Agent, state: ShepherdState, connected: Bool, capabilities: Set<String>) {
        let ordinary = state.isSidebarThread(agent)
        let actions = ordinary && connected && capabilities.contains(RemoteProtocol.agentActionsCapability)
        let run = state.automations.contains { $0.agentID == agent.id }
        self.connected = connected
        worktree = agent.worktreeBranch != nil
        rename = actions
        delete = ordinary && (worktree ? connected && capabilities.contains(RemoteProtocol.worktreeActionsCapability) : actions)
        pin = ordinary && !run
        let moves = actions && capabilities.contains(RemoteProtocol.moveThreadCapability) && !worktree && !run
        moveSpaces = moves ? state.spaces.filter { !$0.hidden } : []
        review = connected && (capabilities.contains(RemoteProtocol.changesCapability)
            || capabilities.contains(RemoteProtocol.agentInspectionCapability))
        finalize = ordinary && connected && worktree && capabilities.contains(RemoteProtocol.worktreeActionsCapability)
            && capabilities.contains(RemoteProtocol.worktreeSetupCapability)
    }
}
