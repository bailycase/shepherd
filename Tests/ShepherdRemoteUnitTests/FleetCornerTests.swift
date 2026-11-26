import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The sidebar's Fleet corner (FleetCornerFull, FleetCornerMin, FleetCornerMany, FleetCornerManyMin): which Macs it lists, what each says and what
/// the minimized line reads, from the real page derivation over fixture Macs.
@Suite("Fleet corner")
struct FleetCornerTests {
    typealias P = FleetPagePresentationTests
    static let gib = P.gib

    static func sample(cpu: Double, working: Int) -> FleetPressureSample {
        FleetPressureSample(cpuUtilization: cpu, cpuCount: 12, totalMemoryBytes: 64 * gib, availableMemoryBytes: 41 * gib, activeAgents: working)
    }

    /// `count` Macs: This Mac busy with 3 threads, then a Mac mini with room, then `sleeping` asleep Macs, then ones that have room.
    static func fleet(count: Int, sleeping: Int = 0, lacking: (index: Int, kind: FleetMissingTool.Kind)? = nil,
                      waitingOn: Int? = nil) -> (snapshot: FleetSnapshot, ids: [UUID]) {
        let ids = (0..<count).map { _ in UUID() }
        var peers: [FleetPeerStatus] = []
        var macs = [FleetMacState(hostID: ids[0], sample: sample(cpu: 0.72, working: 3), sampleAge: 1,
                                  readiness: FleetReadinessReport(model: "MacBook Pro", chip: "M4 Pro"))]
        for index in 1..<count {
            let asleep = index > 1 && index <= 1 + sleeping
            let name = index == 1 ? "Mac mini" : index == 2 ? "Mac Studio" : "build-\(String(format: "%02d", index))"
            peers.append(FleetPeerStatus(hostID: ids[index], name: name, pairedAt: 1, link: asleep ? .offline : .connected, lastSeen: asleep ? 1 : nil))
            let missing = lacking?.index == index ? [FleetMissingTool(kind: lacking!.kind)] : []
            macs.append(FleetMacState(hostID: ids[index], sample: asleep ? nil : sample(cpu: index == 1 ? 0.05 : 0.45, working: 0),
                                      sampleAge: asleep ? nil : 1, readiness: FleetReadinessReport(model: "Mac mini", chip: "M4 Pro", missing: missing)))
        }
        var snapshot = FleetSnapshot(enabled: true, hostID: ids[0], name: "MacBook Pro", port: 7434, peers: peers, macs: macs)
        if let waitingOn {
            snapshot.dispatches = [FleetDispatchRecord(parentHostID: ids[0], parentHostName: "MacBook Pro", targetHostID: ids[waitingOn],
                                                       targetHostName: "Mac Studio", state: .waitingWake, title: "Profile cold launch", task: "",
                                                       repoKey: "github.com/acme/web", createdAt: 1)]
        }
        return (snapshot, ids)
    }

    static func corner(_ snapshot: FleetSnapshot) -> FleetCorner {
        FleetCorner.make(FleetPagePresentation.make(snapshot: snapshot, weight: { _ in .normal }, locale: P.en, calendar: P.utc))!
    }

    // MARK: Every Mac listed

    @Test func threeMacsListedOneRowEach() {
        let (snapshot, ids) = Self.fleet(count: 3, sleeping: 1)
        let corner = Self.corner(snapshot)
        #expect(corner.rows.map(\.name) == ["This Mac", "mini", "studio"])
        #expect(corner.rows.map(\.id) == ids)
        #expect(corner.rows.map(\.state) == ["3 running", "Room", "Asleep"])
        #expect(corner.rows.map(\.dot) == [.awake, .awake, .asleep])
        #expect(corner.rows.map(\.gauge) == [.warn, .active, .tertiary], "amber while busy, blue with room, only the track while asleep")
        #expect(corner.rows[2].load == 0)
        #expect(corner.headline == "3 Macs")
        #expect(corner.summary == "2 of 3 Macs awake")
        #expect(corner.more == nil && !corner.alert && !corner.folded)
    }

    @Test func allAwakeSaysHowManyMacs() {
        #expect(Self.corner(Self.fleet(count: 3).snapshot).headline == "3 Macs")
        #expect(Self.corner(Self.fleet(count: 3).snapshot).summary == "3 Macs awake")
        #expect(Self.corner(Self.fleet(count: 1).snapshot).headline == "just this Mac")
        #expect(Self.corner(Self.fleet(count: 1).snapshot).summary == "Just this Mac")
    }

    @Test func workWaitingForASleepingMacReadsWaitingNotAsleep() {
        let (snapshot, _) = Self.fleet(count: 3, sleeping: 1, waitingOn: 2)
        #expect(Self.corner(snapshot).rows.map(\.state) == ["3 running", "Room", "1 waiting"])
    }

    @Test func aMacThatLacksATool_everyThreadNeedsCannotTakeWorkAndRaisesTheAlert() {
        let (snapshot, _) = Self.fleet(count: 3, lacking: (2, .xcode))
        let corner = Self.corner(snapshot)
        #expect(corner.rows[2].state == "No Xcode" && corner.rows[2].dot == .blocked && corner.rows[2].load == 0)
        #expect(corner.alert)
        #expect(Self.corner(Self.fleet(count: 3, lacking: (2, .git)).snapshot).rows[2].state == "No git")
        // An MCP server's command is no gate: the thread starts without it.
        #expect(!Self.corner(Self.fleet(count: 3, lacking: (2, .binary)).snapshot).alert)
    }

    // MARK: Many Macs

    @Test func manyMacsListOnlyTheOnesThatMatterNow() {
        // This Mac, Auto's next (the mini), a Mac that work waits for, a Mac that can't take work, and the rest folded.
        let (snapshot, ids) = Self.fleet(count: 12, sleeping: 2, lacking: (4, .xcode), waitingOn: 2)
        let corner = Self.corner(snapshot)
        #expect(corner.folded)
        #expect(corner.rows.map(\.id) == [ids[0], ids[1], ids[2], ids[4]], "\(corner.rows.map(\.name)) \(corner.rows.map(\.state))")
        #expect(corner.rows.map(\.state) == ["3 running", "Next", "1 waiting", "No Xcode"])
        #expect(corner.rows[3].name == "build-04")
        #expect(corner.more?.text == "8 more, 1 asleep")
        #expect(corner.headline == "12 Macs" && corner.alert)
    }

    @Test func theFoldedRowCountsTheSleepingMacsItHides() {
        // Studio (asleep, waited for) shows; the other asleep Mac is folded in.
        let (snapshot, ids) = Self.fleet(count: 12, sleeping: 3, waitingOn: 2)
        let corner = Self.corner(snapshot)
        #expect(corner.rows.map(\.id) == [ids[0], ids[1], ids[2]], "\(corner.rows.map(\.name)) \(corner.rows.map(\.state))")
        #expect(corner.more == FleetCorner.More(count: 9, asleep: 2, text: "9 more, 2 asleep"))
    }

    @Test func theMinimizedLineCountsTheMacsWithRoom() {
        let (snapshot, _) = Self.fleet(count: 12)
        let corner = Self.corner(snapshot)
        #expect(corner.summary == "12 Macs, 11 with room", "\(corner.summary)")
        // With one Mac lacking Xcode, it doesn't count.
        #expect(Self.corner(Self.fleet(count: 12, lacking: (5, .xcode)).snapshot).summary == "12 Macs, 10 with room")
    }

    @Test func fiveMacsAreStillListedOneByOne() {
        let corner = Self.corner(Self.fleet(count: FleetCorner.listsEveryMacUpTo).snapshot)
        #expect(!corner.folded && corner.rows.count == FleetCorner.listsEveryMacUpTo && corner.more == nil)
    }

    @Test func theCornerNeverListsMoreThanItsRowLimit() {
        // Every Mac but This Mac lacks Xcode: all matter, but the corner stops at its limit and folds the rest.
        var (snapshot, _) = Self.fleet(count: 12)
        for index in snapshot.macs.indices.dropFirst() { snapshot.macs[index].readiness?.missing = [FleetMissingTool(kind: .xcode)] }
        let corner = Self.corner(snapshot)
        #expect(corner.rows.count == FleetCorner.rowLimit)
        #expect(corner.more?.count == 12 - FleetCorner.rowLimit)
    }

    @Test func aMacWithRoomCountsItsWorkingThreads() {
        var card = Self.corner(Self.fleet(count: 3).snapshot).rows.count == 3 ? FleetPagePresentation.make(snapshot: Self.fleet(count: 3).snapshot, weight: { _ in .normal }).cards[1] : nil
        #expect(card != nil)
        card?.working = 2
        #expect(card.map { FleetCorner.state($0, next: false) } == "2 running")
        #expect(card.map { FleetCorner.state($0, next: true) } == "Next")
        card?.working = 0
        #expect(card.map { FleetCorner.state($0, next: false) } == "Room")
    }

    @Test func noMacMeansNoCorner() {
        #expect(FleetCorner.make(.empty) == nil)
    }
}
