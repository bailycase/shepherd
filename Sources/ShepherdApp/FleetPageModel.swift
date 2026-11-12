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

    /// The weight chosen for a Mac (`AppSettings.fleetWeight(of:)`).
    @ObservationIgnored var weight: (UUID) -> FleetSendWeight = { _ in .normal }
    /// Writes a Mac's weight (`AppSettings.setFleetWeight`).
    @ObservationIgnored var setWeight: (FleetSendWeight, UUID) -> Void = { _, _ in }
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private var snapshot = FleetSnapshot()
    @ObservationIgnored private var snapshotAt = Date()

    init() {}

    /// The host answered with `snapshot`.
    func update(_ snapshot: FleetSnapshot) {
        self.snapshot = snapshot
        snapshotAt = now()
        recompute()
    }

    /// Derives the page again: a weight changed, or time passed.
    func recompute() {
        let next = FleetPagePresentation.make(snapshot: snapshot, weight: weight, snapshotAge: max(0, now().timeIntervalSince(snapshotAt)))
        if next != page { page = next }
    }

    /// Send work here: the choice for `hostID`.
    func choose(_ choice: FleetSendWeight, for hostID: UUID) {
        setWeight(choice, hostID)
        recompute()
    }
}
