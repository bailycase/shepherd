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

    /// The page's two views (FleetA, FleetCheck): the Macs, or what each has of what the fleet needs.
    enum Tab: Hashable { case macs, check }
    var tab = Tab.macs
    /// Check's selected row, and the Mac the panel is about (the first that needs something when nil).
    var checkRow: String?
    var checkMac: UUID?
    /// Check now is under way (the host asks every Mac to look again, each read only).
    var checking = false
    /// Why a fix couldn't start, in the host's words.
    var checkProblem: String?
    /// The fixes this Mac started for itself: a thread of its own, by item, until it ends.
    private(set) var localFixing: [String: FleetCheckFixing] = [:]

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
    /// What a person set aside for a Mac (`AppSettings.fleetCheckIgnored(on:)`), and writes it (`setFleetCheckIgnored`).
    @ObservationIgnored var checkIgnored: (UUID) -> Set<String> = { _ in [] }
    @ObservationIgnored var setCheckIgnored: (Set<String>, UUID) -> Void = { _, _ in }
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
                                              threadCap: threadCap(), checkIgnored: checkIgnored,
                                              checkFixing: snapshot.hostID.map { [$0: localFixing] } ?? [:])
        if next != page { page = next }
        if next.dispatchCards != dispatchCards { dispatchCards = next.dispatchCards }
    }

    /// Check: the Mac card's Check… opens the tab on the first thing `mac` needs.
    func openCheck(for mac: UUID) {
        tab = .check
        checkMac = mac
        checkRow = page.check.firstRow(needing: mac)
    }

    /// A row of the grid is picked: the panel is about `mac` (the first that needs something when nil).
    func selectCheck(row: String, mac: UUID?) {
        checkRow = row
        checkMac = mac
        checkProblem = nil
    }

    /// Ignore on <Mac>, or stop ignoring: the item's id in what is set aside for the Mac.
    func ignoreCheck(_ rowID: String, on mac: UUID, _ ignore: Bool) {
        var ids = checkIgnored(mac)
        if ignore { ids.insert(rowID) } else { ids.remove(rowID) }
        setCheckIgnored(ids, mac)
        recompute()
    }

    /// This Mac started a thread of its own for `items`.
    func startedLocalFix(_ agent: AgentID, title: String, items: [String]) {
        for id in items { localFixing[id] = FleetCheckFixing(agentID: agent, threadTitle: title) }
        recompute()
    }

    /// A local thread's turn ended: if it was a fix, its items are no longer being fixed. Returns whether it was.
    @discardableResult
    func endedLocalFix(_ agent: AgentID) -> Bool {
        let items = localFixing.filter { $0.value.agentID == agent }.map(\.key)
        guard !items.isEmpty else { return false }
        for id in items { localFixing[id] = nil }
        recompute()
        return true
    }

    /// Send work here: the choice for `hostID`.
    func choose(_ choice: FleetSendWeight, for hostID: UUID) {
        setWeight(choice, hostID)
        recompute()
    }
}
