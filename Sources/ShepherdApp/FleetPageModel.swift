import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The Fleet page, its sidebar row and its palette row (FleetA, FleetSidebar): the host's
/// snapshot and the Send work here weights turned into plain values once per change
/// (`FleetPagePresentation`), never in a view's body.
@MainActor
@Observable
final class FleetPageModel {
    private(set) var page = FleetPage.empty
    /// The dispatches this Mac sent, as cards: kept apart from `page`, which moves with every sample, so a thread that draws them is
    /// redrawn only when a dispatch changes.
    private(set) var dispatchCards: [FleetDispatchCard] = []
    /// The moves of this Mac's threads (FleetMove), live or failed: a thread that moves draws its own card from them.
    private(set) var moves: [FleetDispatchRecord] = []
    /// The moves of a remote host's threads, read from that host while one is going (`ShepherdViewModel.watchRemoteMoves`).
    var remoteMoves: [UUID: [FleetDispatchRecord]] = [:]
    /// Failed or cancelled moves the person has dismissed.
    var dismissedMoves: Set<UUID> = []
    /// Bumped whenever the snapshot or a weight changes what a move menu says; a header that reads it is redrawn then, and not before.
    private(set) var menuRevision = 0
    @ObservationIgnored private var menus: [MenuKey: FleetMoveMenu?] = [:]
    private struct MenuKey: Hashable { var host: UUID; var repoKey: String?; var repoName: String }

    /// The move menu of a thread on `host`, kept until the snapshot or a weight changes: a header asks for it on every redraw.
    func moveMenu(from host: UUID, repoKey: String?, repoName: String) -> FleetMoveMenu? {
        _ = menuRevision
        let key = MenuKey(host: host, repoKey: repoKey, repoName: repoName)
        if let cached = menus[key] { return cached }
        let made = FleetMoveMenu.make(snapshot: snapshot, currentHostID: host, repoKey: repoKey, repoName: repoName, weight: weight,
                                      batteryCountsHalf: batteryCountsHalf(), snapshotAge: max(0, now().timeIntervalSince(snapshotAt)))
        menus[key] = .some(made)
        return made
    }

    /// A move picked from a menu or the palette while the thread works: the sheet asks before it stops the turn.
    var moveAsk: FleetMoveAsk?
    @ObservationIgnored var remoteMoveWatchers: [UUID: Task<Void, Never>] = [:]

    /// The weight chosen for a Mac (`AppSettings.fleetWeight(of:)`).
    @ObservationIgnored var weight: (UUID) -> FleetSendWeight = { _ in .normal }
    /// Writes a Mac's weight (`AppSettings.setFleetWeight`).
    @ObservationIgnored var setWeight: (FleetSendWeight, UUID) -> Void = { _, _ in }
    /// Settings ▸ Fleet ▸ Auto dispatch, given how many other Macs are paired (`AppSettings.autoDispatch(pairedMacs:)`).
    @ObservationIgnored var autoDispatch: (Int) -> Bool = { $0 > 0 }
    /// Settings ▸ Fleet ▸ On battery.
    @ObservationIgnored var batteryCountsHalf: () -> Bool = { true }
    /// Settings ▸ Fleet ▸ At most per thread.
    @ObservationIgnored var threadCap: () -> Int = { HostSettings.fleetThreadCapDefault }
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private(set) var snapshot = FleetSnapshot()
    @ObservationIgnored private(set) var snapshotAt = Date()

    init() {}

    /// The host answered with `snapshot`.
    func update(_ snapshot: FleetSnapshot) {
        self.snapshot = snapshot
        snapshotAt = now()
        recompute()
    }

    /// Derives the page again: a weight changed, or time passed.
    func recompute() {
        let next = FleetPagePresentation.make(snapshot: snapshot, weight: weight, snapshotAge: max(0, now().timeIntervalSince(snapshotAt)),
                                              batteryCountsHalf: batteryCountsHalf(), autoDispatch: autoDispatch(snapshot.peers.count),
                                              threadCap: threadCap())
        if next != page { page = next }
        if next.dispatchCards != dispatchCards { dispatchCards = next.dispatchCards }
        menus = [:]
        menuRevision &+= 1
        let moving = snapshot.dispatches.filter { $0.kind == .move && $0.move != nil }
        if moving != moves { moves = moving }
    }

    /// Send work here: the choice for `hostID`.
    func choose(_ choice: FleetSendWeight, for hostID: UUID) {
        setWeight(choice, hostID)
        recompute()
    }
}

/// A move waiting for the person to say what happens to the turn (FleetMove's "It's running a command", as a sheet for the menu and the palette).
struct FleetMoveAsk: Identifiable, Equatable {
    let row: SidebarRowID
    let target: UUID
    let host: String
    let facts: FleetMoveConfirm
    var id: UUID { target }
}
