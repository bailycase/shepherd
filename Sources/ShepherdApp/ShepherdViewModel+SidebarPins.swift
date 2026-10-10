import Foundation
import ShepherdCore

/// Pinned threads (Sidebar › Pinned): pinning and unpinning, where each is offered, and keeping
/// the pins tidy. The pins themselves are `sidebarPins`, view state of this Mac.
@MainActor
extension ShepherdViewModel {
    func isPinned(_ row: SidebarRowID) -> Bool {
        PinnedThread(row).map(sidebarPins.contains) ?? false
    }

    /// Whether a row is a thread that can be pinned: one of This Mac's or a host's, never an
    /// automation's run (its agent is replaced by the next run) or a design.
    func canPin(_ row: SidebarRowID) -> Bool {
        switch row {
        case .local(let id):
            guard let agent = state.agents.first(where: { $0.id == id }) else { return false }
            return state.isOrdinaryThread(agent) && !state.automations.contains { $0.agentID == id }
        case .remote(let ref):
            guard let state = remoteHosts.connections.first(where: { $0.id == ref.hostID })?.state,
                  let agent = state.agents.first(where: { $0.id == ref.agentID }) else { return false }
            return state.isOrdinaryThread(agent) && !state.automations.contains { $0.agentID == ref.agentID }
        case .design:
            return false
        }
    }

    /// Whether the thread options menu and the palette offer Pin for a row: the Activity sidebar
    /// is what draws pins, so the project tree offers none.
    func offersPin(for row: SidebarRowID) -> Bool {
        sidebarStyle == .activity && canPin(row)
    }

    /// The thread on screen, when it can be pinned from the header and the palette.
    var pinTarget: SidebarRowID? {
        guard let row = selectedSidebarRow, offersPin(for: row) else { return nil }
        return row
    }

    func pinThread(_ row: SidebarRowID) {
        guard canPin(row), let thread = PinnedThread(row) else { return }
        var next = sidebarPins
        if next.pin(thread) { sidebarPins = next }
    }

    func unpinThread(_ row: SidebarRowID) {
        guard let thread = PinnedThread(row) else { return }
        var next = sidebarPins
        if next.unpin(thread) { sidebarPins = next }
    }

    func togglePin(_ row: SidebarRowID) {
        if isPinned(row) { unpinThread(row) } else { pinThread(row) }
    }

    /// Forgets the pins of threads that are gone: deleted on This Mac or on their host, or of a
    /// host no longer configured. Nothing is forgotten before the workspace has been adopted, or
    /// of a host that has sent its threads.
    func pruneSidebarPins() {
        guard didAdopt, !sidebarPins.isEmpty else { return }
        var hostAgents: [UUID: Set<AgentID>] = [:]
        for connection in remoteHosts.connections where connection.phase == .connected {
            hostAgents[connection.id] = Set(connection.state.agents.map(\.id))
        }
        var next = sidebarPins
        if next.prune(localAgents: Set(state.agents.map(\.id)), configuredHosts: Set(remoteHosts.connections.map(\.id)),
                      hostAgents: hostAgents) {
            sidebarPins = next
        }
    }
}
