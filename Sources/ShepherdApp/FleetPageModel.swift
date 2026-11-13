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
    }

    /// Send work here: the choice for `hostID`.
    func choose(_ choice: FleetSendWeight, for hostID: UUID) {
        setWeight(choice, hostID)
        recompute()
    }
}
