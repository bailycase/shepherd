import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdRemote

/// The iPad Design tool's pure rules: the one live web view the plan allows on iOS (the board a
/// tap asks about first, then the selected board, then the one nearest the middle), and designs
/// among the threads in the sidebar's Recents.
@Suite("Design on iPad")
struct DesignTouchPlanTests {
    private static func path(_ raw: String) -> DesignPath { DesignPath(raw)! }
    private static let paths = (0..<6).map { path("Board\($0).dc.html") }

    // MARK: Live views

    @Test func oneBoardIsLiveTheSelectedOneBeforeTheVisibleOnes() {
        let wanted = DesignTouchLivePlan.wanted(visible: Self.paths, selected: Self.paths[4], zoom: 0.5)
        #expect(wanted == [Self.paths[4]])
        #expect(DesignTouchLivePlan.wanted(visible: Self.paths, selected: nil, zoom: 0.5) == [Self.paths[0]])
    }

    /// A tap on another board needs that board live to name what is under it.
    @Test func theBoardATapAsksAboutTakesTheViewFromTheSelectedOne() {
        let wanted = DesignTouchLivePlan.wanted(visible: Self.paths, selected: Self.paths[4], asked: Self.paths[2], zoom: 0.5)
        #expect(wanted == [Self.paths[2]])
    }

    @Test(arguments: [(CGFloat(0.2), [0]), (0.05, []), (0.25, [0])])
    func belowTheThresholdBoardsDrawFromSnapshots(zoom: CGFloat, live: [Int]) {
        let wanted = DesignTouchLivePlan.wanted(visible: Self.paths, selected: Self.paths[0], zoom: zoom)
        #expect(wanted == live.map { Self.paths[$0] })
    }

    @Test func aNewBoardTakesTheViewOfTheOneNoLongerWanted() {
        let assignment = DesignTouchLivePlan.assign(slots: [Self.paths[0]: 3], wanted: [Self.paths[1]])
        #expect(assignment == DesignTouchLivePlan.Assignment(evict: [Self.paths[0]], create: [Self.paths[1]]))
        #expect(DesignTouchLivePlan.assign(slots: [Self.paths[0]: 3], wanted: [Self.paths[0]])
                == DesignTouchLivePlan.Assignment(evict: [], create: []))
    }

    /// Panning across the canvas moves the one view along and never holds two.
    @Test func panningKeepsOneLiveViewAndMovesIt() {
        var slots: [DesignPath: UInt64] = [:]
        for (stamp, start) in (0..<5).enumerated() {
            let wanted = DesignTouchLivePlan.wanted(visible: Array(Self.paths[start...]), selected: nil, zoom: 1)
            for path in wanted where slots[path] != nil { slots[path] = UInt64(stamp + 1) }
            let assignment = DesignTouchLivePlan.assign(slots: slots, wanted: wanted)
            for path in assignment.evict { slots.removeValue(forKey: path) }
            for path in assignment.create { slots[path] = UInt64(stamp + 1) }
            #expect(slots.count <= DesignTouchLivePlan.liveCap)
            #expect(Set(slots.keys) == [Self.paths[start]])
        }
    }

    // MARK: Recents

    private struct Design: Equatable, Sendable {
        var name: String
        var at: Double
    }

    private static func thread(_ id: String, at: Double?, status: AgentStatus = .idle) -> FleetThreadRow {
        FleetThreadRow(ref: FleetRef(host: UUID(uuidString: "5E0A0000-0000-4000-8000-000000000001")!, agent: AgentID(rawValue: id)),
                       title: id, status: status, detail: "", activity: nil, clock: at.map { .ago($0) }, hostName: "Studio",
                       hostTag: nil, worktree: false, offline: false)
    }

    private static func names(_ entries: [DesignRecents.Entry<Design>]) -> [String] {
        entries.map { entry in
            switch entry {
            case .thread(let row): row.title
            case .design(let design): design.name
            }
        }
    }

    @Test func designsGoAmongTheThreadsByWhenEachLastMoved() {
        let threads = [Self.thread("running", at: nil, status: .working), Self.thread("new", at: 900),
                       Self.thread("older", at: 500), Self.thread("oldest", at: 100)]
        let designs = [Design(name: "funnel", at: 700), Design(name: "settings", at: 50), Design(name: "fresh", at: 2_000)]
        let merged = DesignRecents.merge(threads: threads, designs: designs) { $0.at }
        #expect(Self.names(merged) == ["running", "fresh", "new", "funnel", "older", "oldest", "settings"])
    }

    @Test func aRunningThreadKeepsItsPlaceBeforeEveryDesign() {
        let merged = DesignRecents.merge(threads: [Self.thread("running", at: 10, status: .working)],
                                         designs: [Design(name: "funnel", at: 5_000)]) { $0.at }
        #expect(Self.names(merged) == ["running", "funnel"])
    }

    @Test func designsKeepTheirOrderWhenTheyMovedTogether() {
        let merged = DesignRecents.merge(threads: [], designs: [Design(name: "a", at: 10), Design(name: "b", at: 10)]) { $0.at }
        #expect(Self.names(merged) == ["a", "b"])
    }
}
