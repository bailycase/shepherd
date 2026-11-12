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
            return state.isSidebarThread(agent) && !state.automations.contains { $0.agentID == id }
        case .remote(let ref):
            guard let state = remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.state,
                  let agent = state.agents.first(where: { $0.id == ref.agentID }) else { return false }
            return state.isSidebarThread(agent) && !state.automations.contains { $0.agentID == ref.agentID }
        case .design, .remoteDesign:
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

    /// Pin or Unpin in a space's menu: move it between Pinned and its ordinary place in Spaces.
    func togglePinSpace(_ space: SpaceID) {
        var next = spacePins
        next.toggle(space)
        spacePins = next
    }

    /// Whether a thread's pushes are muted on its host (`Agent.pushMuted`); nil where its host takes no Mute
    /// (`pushMuteCapability`) or the row is no thread.
    func pushMuted(_ row: SidebarRowID) -> Bool? {
        let takesMute = { (host: UUID) in self.remoteHosts.allConnections.first { $0.id == host }?.supportsPushMute == true }
        switch row {
        case .local(let id):
            if let ref = localRef(id), !takesMute(ref.hostID) { return nil }
            return state.agents.first { $0.id == id }?.pushMuted
        case .remote(let ref):
            guard takesMute(ref.hostID) else { return nil }
            return remoteHosts.allConnections.first { $0.id == ref.hostID }?.state.agents.first { $0.id == ref.agentID }?.pushMuted
        case .design, .remoteDesign:
            return nil
        }
    }

    /// Mute or Unmute Notifications: the thread's host keeps it, so every phone agrees.
    func togglePushMuted(_ row: SidebarRowID) {
        guard let muted = pushMuted(row) else { return }
        let hosts = remoteHosts, title = "Couldn’t change the thread’s notifications"
        switch row {
        case .local(let id):
            let ref = localRef(id)
            enqueuePersistence("thread mute", failureTitle: title) {
                guard let ref else { throw BackgroundHostClient.HostStarting() }
                try await hosts.agentAction(ref, action: .mutePushes(!muted))
            }
        case .remote(let ref):
            Task {
                do { try await hosts.agentAction(ref, action: .mutePushes(!muted)) } catch { fail(title, error) }
            }
        case .design, .remoteDesign:
            break
        }
    }

    func togglePin(_ row: SidebarRowID) {
        if isPinned(row) { unpinThread(row) } else { pinThread(row) }
    }

    /// Forgets the pins of threads that are gone: deleted on This Mac or on their host, or of a
    /// host no longer configured. Nothing is forgotten before the workspace has been adopted, or
    /// of a host that has sent its threads.
    func pruneSidebarPins() {
        // As a client, nothing is pruned until the host has sent its workspace.
        if localHost?.phase != .connected { return }
        if didAdopt {
            var spaces = spacePins
            if spaces.prune(keeping: Set(state.spaces.filter { !$0.hidden }.map(\.id))) { spacePins = spaces }
        }
        guard didAdopt, !sidebarPins.isEmpty else { return }
        // As a client, This Mac's threads are the host's: never prune them against the app's
        // filtered copy, nor before the host has sent its workspace.
        var localAgents = Set(state.agents.map(\.id))
        if let host = localHost {
            localAgents.formUnion(host.state.agents.map(\.id))
        }
        var hostAgents: [UUID: Set<AgentID>] = [:]
        for connection in remoteHosts.connections where connection.phase == .connected {
            hostAgents[connection.id] = Set(connection.state.agents.map(\.id))
        }
        var next = sidebarPins
        if next.prune(localAgents: localAgents, configuredHosts: Set(remoteHosts.connections.map(\.id)),
                      hostAgents: hostAgents) {
            sidebarPins = next
        }
    }
}
