import Foundation
import ShepherdCore

// The Activity sidebar's Pinned section (Sidebar › Pinned): which threads the user pinned, as
// view state of this Mac. Plain values, so the order, persistence and pruning are testable
// without a view model.

/// A thread the Activity sidebar can pin: one of This Mac's agents, or one on a configured host
/// (its host's id is the configuration's, which survives launches).
enum PinnedThread: Hashable {
    case local(AgentID)
    case remote(RemoteAgentRef)

    /// The thread a sidebar row opens; nil for a design, which is never pinned.
    init?(_ row: SidebarRowID) {
        switch row {
        case .local(let id): self = .local(id)
        case .remote(let ref): self = .remote(ref)
        case .design: return nil
        }
    }

    var row: SidebarRowID {
        switch self {
        case .local(let id): .local(id)
        case .remote(let ref): .remote(ref)
        }
    }

    /// What a pin is kept under: "local:<agent>", or "<host>:<agent>" for a host's thread.
    var key: String {
        switch self {
        case .local(let id): "local:\(id.rawValue)"
        case .remote(let ref): "\(ref.hostID.uuidString):\(ref.agentID.rawValue)"
        }
    }

    init?(key: String) {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let head = key[..<colon]
        let agent = String(key[key.index(after: colon)...])
        guard !agent.isEmpty else { return nil }
        if head == "local" {
            self = .local(AgentID(rawValue: agent))
        } else if let host = UUID(uuidString: String(head)) {
            self = .remote(RemoteAgentRef(hostID: host, agentID: AgentID(rawValue: agent)))
        } else {
            return nil
        }
    }
}

/// The pinned threads, oldest pin first: the order the Pinned section lists them in.
struct SidebarPins: Equatable {
    private(set) var threads: [PinnedThread] = []

    init(_ threads: [PinnedThread] = []) {
        var seen = Set<PinnedThread>()
        self.threads = threads.filter { seen.insert($0).inserted }
    }

    /// The pins as stored; a key nothing reads (from another version) is dropped.
    init(keys: [String]) {
        self.init(keys.compactMap(PinnedThread.init(key:)))
    }

    var keys: [String] { threads.map(\.key) }
    var isEmpty: Bool { threads.isEmpty }

    func contains(_ thread: PinnedThread) -> Bool { threads.contains(thread) }

    /// Pins a thread after the others; false when it already was.
    @discardableResult mutating func pin(_ thread: PinnedThread) -> Bool {
        guard !contains(thread) else { return false }
        threads.append(thread)
        return true
    }

    @discardableResult mutating func unpin(_ thread: PinnedThread) -> Bool {
        guard let index = threads.firstIndex(of: thread) else { return false }
        threads.remove(at: index)
        return true
    }

    /// Pins a thread that isn't, unpins one that is; true when it is pinned now.
    @discardableResult mutating func toggle(_ thread: PinnedThread) -> Bool {
        if unpin(thread) { return false }
        pin(thread)
        return true
    }

    /// Drops the pins of threads that are gone; true when any went. A thread of This Mac's is gone
    /// when it is not in `localAgents`; a host's when the host is no longer configured, or when
    /// it has sent its threads (`hostAgents`: every host that has, this launch) and this is not
    /// among them. A host that has sent nothing yet keeps its pins, so a launch before it connects
    /// forgets none.
    @discardableResult mutating func prune(localAgents: Set<AgentID>, configuredHosts: Set<UUID>,
                                           hostAgents: [UUID: Set<AgentID>]) -> Bool {
        let before = threads.count
        threads.removeAll { thread in
            switch thread {
            case .local(let id): !localAgents.contains(id)
            case .remote(let ref):
                !configuredHosts.contains(ref.hostID) || hostAgents[ref.hostID].map { !$0.contains(ref.agentID) } ?? false
            }
        }
        return threads.count != before
    }
}

extension SidebarPins {
    /// Per-Mac view state beside the sidebar's other choices (`shepherd.sidebar.collapsedProjects`):
    /// not in state.json, never sent to another device, and not reset by Reset settings.
    static let defaultsKey = "shepherd.sidebar.pinned"

    init(defaults: UserDefaults) {
        self.init(keys: defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func save(to defaults: UserDefaults) {
        defaults.set(keys, forKey: Self.defaultsKey)
    }
}

/// The words and glyphs of pinning, in every place that offers it.
enum PinWords {
    /// The row menu's and the thread options menu's item.
    static func menuTitle(pinned: Bool) -> String { pinned ? "Unpin" : "Pin" }
    static func symbol(pinned: Bool) -> String { pinned ? "pin.slash" : "pin" }
    /// The palette's command, named for what it does now.
    static func paletteTitle(pinned: Bool) -> String { pinned ? "Unpin thread" : "Pin thread" }
}
