import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Moving a thread to another Mac (FleetMove): what the header chip, the thread's menu and the palette offer, and what they ask. The host
// that runs the thread does the move (`RemoteAgentAction.moveToMac`); this reads the fleet snapshot for the menu and the move's record for
// the card.

/// What the header draws of where the thread runs and where it can go.
struct FleetMoveHeader: Equatable {
    var chip: FleetMoveChip
    var menu: FleetMoveMenu
    /// A move of this thread is going or waits: the chip opens nothing.
    var busy: Bool
}

@MainActor
extension ShepherdViewModel {
    /// A thread as the move needs it: where it runs, by that Mac's fleet id, and what it asks of its host.
    struct MoveSubject {
        let ref: RemoteAgentRef
        let agent: Agent
        /// The thread's Mac, by its fleet id.
        let hostID: UUID
        let isLocal: Bool
        let space: Space?
        let capable: Bool
    }

    /// The threads the host moves: ordinary ones, not an automation's run, a design's agent or a project's thread (the host refuses those).
    static func movable(_ agent: Agent, in state: ShepherdState) -> Bool {
        state.isSidebarThread(agent) && !state.automations.contains { $0.agentID == agent.id }
            && !state.isProjectWorker(agent.id) && !state.isProjectCoordinator(agent) && agent.movedTo == nil
    }

    func moveSubject(_ row: SidebarRowID) -> MoveSubject? {
        switch row {
        case .local(let id):
            guard let agent = state.agents.first(where: { $0.id == id }), let host = localHost, let hostID = thisFleetID else { return nil }
            return MoveSubject(ref: RemoteAgentRef(hostID: host.id, agentID: id), agent: agent, hostID: hostID, isLocal: true,
                               space: state.spaces.first { $0.id == agent.spaceID }, capable: host.supportsFleetMove && Self.movable(agent, in: state))
        case .remote(let ref):
            guard let connection = remoteHosts.allConnections.first(where: { $0.id == ref.hostID }),
                  let agent = connection.state.agents.first(where: { $0.id == ref.agentID }), let hostID = connection.fleetID else { return nil }
            return MoveSubject(ref: ref, agent: agent, hostID: hostID, isLocal: false,
                               space: connection.state.spaces.first { $0.id == agent.spaceID }, capable: connection.supportsFleetMove && Self.movable(agent, in: connection.state))
        case .design, .remoteDesign:
            return nil
        }
    }

    /// The chip and menu of a thread's header; nil where the thread can't move: no other Mac in the fleet, a host that can't move threads, or
    /// a thread that isn't an ordinary one.
    func fleetMoveHeader(for row: SidebarRowID) -> FleetMoveHeader? {
        guard let subject = moveSubject(row), subject.capable, subject.agent.movedTo == nil else { return nil }
        guard let menu = fleetPage.moveMenu(from: subject.hostID, repoKey: subject.space?.repoKey, repoName: subject.space?.name ?? "this folder") else { return nil }
        let chip = FleetMoveChip.make(host: menu.here.name, tone: menu.here.tone, movedFrom: subject.agent.movedFrom, thisFleetID: thisFleetID)
        return FleetMoveHeader(chip: chip, menu: menu, busy: moveCard(for: subject.agent.id, on: subject.ref.hostID) != nil)
    }

    /// The card of the move of `agent` that is going, waits, or failed (and wasn't dismissed).
    func moveCard(for agent: AgentID, on host: UUID? = nil) -> FleetMoveCard? {
        let records = host == localHost?.id || host == nil ? fleetPage.moves : (fleetPage.remoteMoves[host ?? UUID()] ?? [])
        return records.filter { $0.move?.agentID == agent && !fleetPage.dismissedMoves.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }.lazy.compactMap { FleetMoveCard.make($0) }.first
    }

    /// Move to a Mac: the host stops the turn (now, or when it ends), sends the conversation and the worktree and starts the thread there.
    func moveThread(_ row: SidebarRowID, to target: UUID, when: FleetMoveRequest.When = .now) {
        guard let subject = moveSubject(row), subject.capable else { return }
        let request = FleetMoveRequest(agentID: subject.ref.agentID, host: target.uuidString, when: when)
        Task {
            do {
                try await remoteHosts.agentAction(subject.ref, action: .moveToMac(request))
                if subject.isLocal { await fleet.refresh() } else { watchRemoteMoves(on: subject.ref.hostID) }
                followMove(of: subject.ref.agentID)
            } catch {
                fail("Couldn’t move the thread", error)
            }
        }
    }

    /// A move picked from a menu or the palette: asks first while a turn runs, otherwise goes.
    func requestFleetMove(_ row: SidebarRowID, to target: FleetMoveMenu.Target) {
        guard let subject = moveSubject(row), subject.capable else { return }
        guard subject.agent.status == .working || subject.agent.status == .blocked else { return moveThread(row, to: target.id) }
        let store: NativeThreadStore
        switch row {
        case .local(let id): store = threadStores.store(for: id)
        case .remote(let ref): store = remoteThreadStores.store(for: ref)
        default: return
        }
        let call = FleetMoveConfirm.runningCall(in: (store.liveRow ?? store.rows.last)?.presentation?.items ?? [])
        fleetPage.moveAsk = FleetMoveAsk(row: row, target: target.id, host: target.name, facts: FleetMoveConfirm.make(running: call, host: target.name))
    }

    /// The thread on screen: "Move to Mac mini" in the palette.
    func movePaletteTargets() -> [(row: SidebarRowID, target: FleetMoveMenu.Target)] {
        guard let row = selectedSidebarRow, let header = fleetMoveHeader(for: row), !header.busy else { return [] }
        return header.menu.targets.filter(\.enabled).map { (row, $0) }
    }

    /// Cancel on a move that waits for the end of the turn.
    func cancelMove(_ id: UUID) {
        fleetPage.dismissedMoves.insert(id)
        Task { await fleet.cancelDispatch(id) }
    }

    func dismissMove(_ id: UUID) {
        fleetPage.dismissedMoves.insert(id)
    }

    /// A remote host's moves while one is going: its fleet read once a second until none is live. This Mac's own come with its snapshot.
    func watchRemoteMoves(on host: UUID) {
        guard fleetPage.remoteMoveWatchers[host] == nil else { return }
        fleetPage.remoteMoveWatchers[host] = Task { [weak self] in
            defer { self?.fleetPage.remoteMoveWatchers[host] = nil }
            var quiet = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let snapshot = try? await self.remoteHosts.fleetRead(hostID: host) {
                    let moves = snapshot.dispatches.filter { $0.kind == .move && $0.move != nil }
                    if moves != (self.fleetPage.remoteMoves[host] ?? []) { self.fleetPage.remoteMoves[host] = moves }
                    quiet = moves.contains { $0.state.isLive } ? 0 : quiet + 1
                } else {
                    quiet += 1
                }
                if quiet >= 2 { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The thread moved to a row of another host: the person who is looking at it follows it there. Stops when they look elsewhere.
    func followMove(of agent: AgentID) {
        Task { [weak self] in
            for _ in 0..<1200 {
                guard let self, case .local(agent)? = self.selectedSidebarRow else { return }
                if !self.state.agents.contains(where: { $0.id == agent }),
                   let connection = self.remoteHosts.allConnections.first(where: { $0.state.agents.contains { $0.id == agent } && $0.id != self.localHost?.id }) {
                    self.selectSidebarRow(.remote(RemoteAgentRef(hostID: connection.id, agentID: agent)))
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}
