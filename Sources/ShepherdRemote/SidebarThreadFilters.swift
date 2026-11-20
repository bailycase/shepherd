import Foundation

/// Transient Activity criteria, shared by Mac and mobile. Status chips are alternatives;
/// checkout criteria and the host further narrow the result.
public struct SidebarThreadFilters: Equatable, Sendable {
    public enum Chip: String, CaseIterable, Identifiable, Sendable {
        case running = "Running"
        case needsYou = "Needs you"
        case hasChanges = "Has changes"
        case worktree = "Worktree"

        public var id: Self { self }
    }

    public struct Host: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var chips: Set<Chip> = []
    public var host: UUID?
    public var isActive: Bool { !chips.isEmpty || host != nil }

    public init(chips: Set<Chip> = [], host: UUID? = nil) {
        self.chips = chips
        self.host = host
    }

    public mutating func toggle(_ chip: Chip) {
        if !chips.insert(chip).inserted { chips.remove(chip) }
    }

    public func available(on hosts: [UUID]) -> Self {
        var filters = self
        if let host, hosts.count < 2 || !hosts.contains(host) { filters.host = nil }
        return filters
    }

    public func matches(host rowHost: UUID, running: Bool, needsYou: Bool, hasChanges: Bool, worktree: Bool) -> Bool {
        guard host == nil || host == rowHost else { return false }
        if chips.contains(.running) || chips.contains(.needsYou) {
            guard (chips.contains(.running) && running) || (chips.contains(.needsYou) && needsYou) else { return false }
        }
        return (!chips.contains(.hasChanges) || hasChanges) && (!chips.contains(.worktree) || worktree)
    }
}

extension FleetModel {
    /// The hosts the host picker offers: only those that are connected, so one connected host among offline ones has no picker.
    public var filterHosts: [SidebarThreadFilters.Host] {
        hosts.filter { $0.phase.isConnected }.map { .init(id: $0.id, name: $0.name) }
    }
}
