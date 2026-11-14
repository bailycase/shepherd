import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Dispatches in the app's threads: what a thread draws of them (`FleetThreadSurface`) and what their buttons do. The host holds the
// records and does the sending; this only reads its snapshot and asks it to act.

@MainActor
extension ShepherdViewModel {
    /// Wires the buttons on dispatch cards. Called once, as the view model is made.
    func configureFleetThreadActions() {
        let actions = fleetThreadActions
        actions.card = { [weak self] action, card in self?.perform(action, on: card) }
        actions.openResult = { [weak self] card in self?.openDispatchedThread(card) }
        actions.reviewResult = { [weak self] card in self?.reviewDispatchedThread(card) }
        actions.openSender = { [weak self] from in self?.openSender(of: from) }
        actions.cancelMove = { [weak self] in self?.cancelMove($0) }
        actions.dismissMove = { [weak self] in self?.dismissMove($0) }
        actions.retryHost = { [weak self] in
            guard let self, let selected = self.selectedRemoteAgent else { return }
            self.remoteHosts.reconnect(id: selected.hostID)
        }
    }

    /// A pairing link opened from Finder, Messages or AirDrop (`FleetPairingLink`): Settings ▸ Fleet opens Add a Mac with it filled in.
    /// Only this app's own edition's scheme reaches here; the sheet says why a link it can't use isn't one.
    func openFleetLink(_ url: URL) {
        fleet.receive(link: url)
        settingsSection = .fleet
        showSettings = true
    }

    /// This Mac's own fleet host id, once its host has said it.
    var thisFleetID: UUID? { fleetPage.snapshot.hostID }

    /// What a thread draws of dispatches: where it came from if it was sent, and the cards of what it sent. Nil for a thread with neither
    /// (an ordinary thread), so it reads nothing.
    func fleetSurface(for agent: Agent, onRemote remoteName: String? = nil, hostID: UUID? = nil) -> FleetThreadSurface? {
        let cards = remoteName == nil ? fleetPage.dispatchCards.filter { $0.parentAgentID == agent.id } : []
        let move = moveCard(for: agent.id, on: hostID)
        guard agent.dispatchedFrom != nil || !cards.isEmpty || move != nil else { return nil }
        var surface = FleetThreadSurface(cards: cards, parent: agent.id, actions: fleetThreadActions)
        surface.move = move
        if let from = agent.dispatchedFrom {
            var sentBy = FleetSentBy(from, host: remoteName ?? "This Mac", viewer: thisFleetID)
            sentBy.senderOpens = senderRow(of: from) != nil
            surface.sentBy = sentBy
            surface.dispatched = from
            // The Mac that sent it knows whether its dispatch is going; any other reads the thread's own state.
            if let card = fleetPage.dispatchCards.first(where: { $0.id == from.dispatchID }) {
                surface.goesBack = from.agentID != nil && [.preparing, .running].contains(card.state)
            } else {
                surface.goesBack = from.agentID != nil && (agent.status == .working || agent.status == .blocked)
            }
        }
        return surface
    }

    /// The row of the thread that sent a dispatched thread, when it is one this Mac can open.
    func senderRow(of from: DispatchedFrom) -> SidebarRowID? {
        guard let sender = from.agentID else { return nil }
        if from.hostID == thisFleetID { return state.agents.contains { $0.id == sender } ? .local(sender) : nil }
        guard let connection = remoteHosts.allConnections.first(where: { $0.fleetID == from.hostID }),
              connection.state.agents.contains(where: { $0.id == sender }) else { return nil }
        return .remote(RemoteAgentRef(hostID: connection.id, agentID: sender))
    }

    func openSender(of from: DispatchedFrom) {
        if let row = senderRow(of: from) { selectSidebarRow(row) }
    }

    /// The thread a dispatch runs as, on whichever Mac runs it.
    func dispatchedRow(of card: FleetDispatchCard) -> SidebarRowID? {
        guard let target = card.targetHostID, let agent = card.remoteAgentID else { return nil }
        if target == thisFleetID { return .local(agent) }
        return remoteHosts.allConnections.first { $0.fleetID == target }.map { .remote(RemoteAgentRef(hostID: $0.id, agentID: agent)) }
    }

    func openDispatchedThread(_ card: FleetDispatchCard) {
        if let row = dispatchedRow(of: card) { selectSidebarRow(row) }
    }

    func reviewDispatchedThread(_ card: FleetDispatchCard) {
        switch dispatchedRow(of: card) {
        case .local(let id)?: openReview(agentID: id, path: nil)
        case .remote(let ref)?: openRemoteReview(ref, path: nil)
        default: break
        }
    }

    /// A button on a dispatch card.
    func perform(_ action: FleetCardAction, on card: FleetDispatchCard) {
        switch action {
        case .open: openDispatchedThread(card)
        case .stop, .cancel: Task { await fleet.cancelDispatch(card.id) }
        case .runHere, .runHereNow: Task { await fleet.retryDispatch(card.id, host: thisFleetID) }
        case .tryAgain, .send: Task { await fleet.retryDispatch(card.id, host: nil) }
        case .sendTo(let id, _): Task { await fleet.retryDispatch(card.id, host: id) }
        case .openOthers:
            // The thread's other dispatches that are on a Mac: the first one.
            let others = fleetPage.dispatchCards.filter {
                $0.parentAgentID == card.parentAgentID && $0.id != card.id && $0.layout == .row && $0.remoteAgentID != nil
            }
            if let first = others.first { openDispatchedThread(first) }
        }
    }
}

