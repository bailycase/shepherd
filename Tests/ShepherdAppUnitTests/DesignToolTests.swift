import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestKit
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The Design tool's pure rules: which boards get a live view and which views make room, the
/// Designs page's cards, the canvas's boards from a canvas.json, the sidebar's Designs
/// destination and design rows, and the experiment's switch.
@Suite("Design tool")
@MainActor
struct DesignToolTests {
    private static func path(_ raw: String) -> DesignPath { DesignPath(raw)! }
    private static let paths = (0..<12).map { path("Board\($0).dc.html") }

    // MARK: Live views

    @Test func theSelectedBoardComesFirstThenTheVisibleOnesUpToTheCap() {
        let wanted = DesignLivePlan.wanted(visible: Array(Self.paths.prefix(8)), selected: Self.paths[9], zoom: 0.5)
        #expect(wanted == [Self.paths[9]] + Array(Self.paths.prefix(DesignLivePlan.liveCap - 1)))
        #expect(wanted.count == DesignLivePlan.liveCap)
    }

    /// Too small to read: snapshots, though the selected board stays live a while longer.
    @Test(arguments: [(CGFloat(0.2), 1), (0.05, 0), (0.25, 5)])
    func belowTheThresholdBoardsDrawFromSnapshots(zoom: CGFloat, live: Int) {
        let wanted = DesignLivePlan.wanted(visible: Self.paths, selected: Self.paths[0], zoom: zoom)
        #expect(wanted.count == live)
    }

    @Test func aCapOfNoneMakesEveryBoardASnapshot() {
        #expect(DesignLivePlan.wanted(visible: Self.paths, selected: Self.paths[0], zoom: 1, cap: 0).isEmpty)
    }

    @Test func boardsKeepTheirViewsAndNewOnesTakeFreeSlots() {
        let slots: [DesignPath: UInt64] = [Self.paths[0]: 1, Self.paths[1]: 1]
        let assignment = DesignLivePlan.assign(slots: slots, wanted: [Self.paths[0], Self.paths[2]])
        #expect(assignment == DesignLivePlan.Assignment(evict: [], create: [Self.paths[2]]))
    }

    @Test func aFullSetGivesUpTheLeastRecentlyWantedViewsFirst() {
        let slots: [DesignPath: UInt64] = [Self.paths[0]: 5, Self.paths[1]: 2, Self.paths[2]: 9, Self.paths[3]: 1, Self.paths[4]: 7]
        let assignment = DesignLivePlan.assign(slots: slots, wanted: [Self.paths[2], Self.paths[5], Self.paths[6]])
        #expect(assignment.create == [Self.paths[5], Self.paths[6]])
        #expect(assignment.evict == [Self.paths[3], Self.paths[1]])
    }

    /// Panning across a wide canvas keeps the views at the cap and moves them along with the view.
    @Test func panningRecyclesViewsWithinTheCap() {
        var slots: [DesignPath: UInt64] = [:]
        var created = 0
        for (stamp, start) in stride(from: 0, to: 8, by: 1).enumerated() {
            let visible = Array(Self.paths[start..<min(start + 4, Self.paths.count)])
            let wanted = DesignLivePlan.wanted(visible: visible, selected: nil, zoom: 1)
            for path in wanted where slots[path] != nil { slots[path] = UInt64(stamp + 1) }
            let assignment = DesignLivePlan.assign(slots: slots, wanted: wanted)
            for path in assignment.evict { slots.removeValue(forKey: path) }
            for path in assignment.create { slots[path] = UInt64(stamp + 1) }
            created += assignment.create.count
            #expect(slots.count <= DesignLivePlan.liveCap)
            #expect(Set(wanted).isSubset(of: slots.keys))
        }
        #expect(created == 11, "each board gets a view once as the view passes over it")
        #expect(slots[Self.paths[0]] == nil, "the first boards' views went to the later ones")
    }

    // MARK: The Designs page

    private static let web = Space(name: "acme-web", path: "/tmp/acme-web")
    private static let app = Space(name: "shepherd", path: "/tmp/shepherd")
    private static let now = Date(timeIntervalSince1970: 1_790_215_200)

    private func design(_ name: String, space: Space = web, edited: Double, boards: Int? = 4, system: String? = nil) -> Design {
        Design(name: name, spaceID: space.id, systemNamespace: system, createdAt: 1_000,
               lastActiveAt: (Self.now.timeIntervalSince1970 - edited) * 1000, boardCount: boards)
    }

    @Test func cardsAreMostRecentlyEditedFirstWithTheirSystemAndCounts() {
        let old = design("Onboarding", space: Self.app, edited: 3 * 3600, boards: 1)
        let new = design("Checkout funnel dashboard", edited: 7200)
        let model = DesignsPageModel.make(designs: [old, new], spaces: [Self.web, Self.app], firstBoards: [:], filter: "",
                                          selection: new.id, now: Self.now)
        #expect(model.cards.map(\.name) == ["Checkout funnel dashboard", "Onboarding"])
        #expect(model.cards.map(\.system) == ["acme-web", "shepherd"])
        #expect(model.cards.map(\.detail) == ["4 boards", "1 board"])
        #expect(model.cards.map(\.edited) == ["edited 2h ago", "edited 3h ago"])
        #expect(model.cards.map(\.selected) == [true, false])
        #expect(model.systems == [DesignsPageModel.System(name: "acme-web", count: "1 design"),
                                  DesignsPageModel.System(name: "shepherd", count: "1 design")])
    }

    @Test func aDesignsOwnSystemWinsOverItsProject() {
        let model = DesignsPageModel.make(designs: [design("A", edited: 60, system: "night-watch"), design("B", edited: 120)],
                                          spaces: [Self.web], firstBoards: [:], filter: "", selection: nil, now: Self.now)
        #expect(model.cards.map(\.system) == ["night-watch", "acme-web"])
        #expect(model.systems.map(\.name) == ["night-watch", "acme-web"])
    }

    @Test(arguments: [("checkout", ["Checkout funnel dashboard"]), ("SHEPHERD", ["Onboarding"]), ("  ", ["Checkout funnel dashboard", "Onboarding"]),
                      ("nothing", [])])
    func theFilterMatchesNamesAndSystems(filter: String, names: [String]) {
        let model = DesignsPageModel.make(designs: [design("Checkout funnel dashboard", edited: 60),
                                                    design("Onboarding", space: Self.app, edited: 120)],
                                          spaces: [Self.web, Self.app], firstBoards: [:], filter: filter, selection: nil, now: Self.now)
        #expect(model.cards.map(\.name) == names)
        #expect(model.noMatch == names.isEmpty)
    }

    @Test func cardsComeInRowsOfFour() {
        let designs = (0..<9).map { design("Design \($0)", edited: Double($0) * 60) }
        let model = DesignsPageModel.make(designs: designs, spaces: [Self.web], firstBoards: [:], filter: "", selection: nil, now: Self.now)
        #expect(model.rows.map(\.count) == [4, 4, 1])
    }

    @Test func aCardDrawsItsFirstBoardAsItWasLastRead() {
        let desktop = design("Desktop", edited: 60), phone = design("Phone", edited: 120), none = design("Nothing yet", edited: 180, boards: 0)
        let model = DesignsPageModel.make(designs: [desktop, phone, none], spaces: [Self.web],
                                          firstBoards: [desktop.id: .init(size: CGSize(width: 1280, height: 800), version: 3),
                                                        phone.id: .init(size: CGSize(width: 390, height: 844), version: 1)],
                                          filter: "", selection: nil, now: Self.now)
        #expect(model.cards.map(\.board) == [.desktop, .phone, .none])
        #expect(model.cards.map(\.thumbnail) == [3, 1, 0])
        #expect(model.cards.last?.detail == "0 boards")
    }

    // MARK: The canvas

    private static func index() throws -> DesignIndex {
        try DesignIndex.decode(Data("""
        {"v":3,"title":"Checkout","boards":{
          "A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"title":"A · Funnel first"},
          "B.dc.html":{"x":1360,"y":0,"w":1280,"h":800,"title":"  "},
          "A-phone.dc.html":{"x":0,"y":920,"w":390,"h":844,"title":"A · phone"}},
         "order":["B.dc.html","A.dc.html"]}
        """.utf8))
    }

    @Test func theCanvasDrawsTheIndexsBoardsBackToFront() throws {
        let boards = DesignScreenModel.boards(try Self.index(), selection: Self.path("A.dc.html"), tokens: [Self.path("B.dc.html"): 4])
        // Listed boards in their order, then any the order leaves out.
        #expect(boards.map(\.id) == ["B.dc.html", "A.dc.html", "A-phone.dc.html"])
        #expect(boards.map(\.title) == ["B", "A · Funnel first", "A · phone"], "a blank title reads as the file's stem")
        #expect(boards.map(\.size) == ["1280 × 800", "1280 × 800", "390 × 844"])
        #expect(boards.map(\.isSelected) == [false, true, false])
        #expect(boards.map(\.content) == [4, 0, 0])
        #expect(boards[2].frame == CGRect(x: 0, y: 920, width: 390, height: 844))
    }

    @Test func theBoardsOnScreenAreNearestTheMiddleFirst() throws {
        let boards = DesignScreenModel.boards(try Self.index(), selection: nil, tokens: [:])
        let viewport = NWCanvasViewport(offset: .zero, zoom: 0.5)
        // The view's middle is canvas (1600, 400): inside B.
        let visible = DesignScreenModel.visible(boards, viewport: viewport, size: CGSize(width: 1600, height: 800))
        #expect(visible.map(\.rawValue) == ["B.dc.html", "A.dc.html", "A-phone.dc.html"])
    }

    // MARK: The sidebar

    private func sidebar(designs: Bool) -> (SidebarSource, Agent, Design) {
        var drawer = Fixture.agent("Checkout funnel dashboard", in: Self.web).agent
        let design = Design(name: "Checkout funnel dashboard", spaceID: Self.web.id, agentID: drawer.id, createdAt: 1_000,
                            lastActiveAt: 55, boardCount: 4)
        drawer.designID = design.id
        drawer.lastActiveAt = 60
        var others: [Agent] = []
        for index in 0..<10 {
            var agent = Fixture.agent("thread \(index)", in: Self.web).agent
            agent.lastActiveAt = Double(100 - index * 10)
            others.append(agent)
        }
        let state = ShepherdState(spaces: [Self.web], agents: [drawer] + others, designs: [design])
        return (SidebarSource(local: state, designs: designs), drawer, design)
    }

    @Test func aDesignIsARecentsRowWithTheNibAndItsBoardCountAndItsAgentIsNot() {
        let (source, drawer, design) = sidebar(designs: true)
        let lists = SidebarDerivation.lists(source)
        let row = try? #require(lists.recents.first { $0.id == .design(design.id) })
        #expect(row?.leading == .glyph("pencil.tip", attention: false))
        #expect(row?.accessory == .text("4 boards"))
        #expect(row?.accessibilityLabel == "Checkout funnel dashboard, design, 4 boards")
        #expect(!lists.all.contains { $0.id == .local(drawer.id) })
        // By the design's own last change, among the threads.
        #expect(lists.recents.firstIndex { $0.id == .design(design.id) } == 5)
    }

    @Test func withTheToolOffDesignsHaveNoRowsAndTheirAgentsStillDont() {
        let (source, drawer, _) = sidebar(designs: false)
        let lists = SidebarDerivation.lists(source)
        #expect(!lists.all.contains { if case .design = $0.id { true } else { false } })
        #expect(!lists.all.contains { $0.id == .local(drawer.id) })
        #expect(lists.recents.count == 10)
    }

    @Test func designsTakeNoDigit() {
        let (source, _, design) = sidebar(designs: true)
        let lists = SidebarDerivation.lists(source)
        #expect(lists.shortcutRows.count == 10)
        #expect(!lists.shortcutRows.contains { $0.id == .design(design.id) })
        let presented = lists.presented(selected: .design(design.id), shortcuts: true)
        let designRow = presented.recents.first { $0.id == .design(design.id) }
        #expect(designRow?.selected == true)
        #expect(designRow?.accessory == .text("4 boards"))
        #expect(presented.recents.compactMap { if case .shortcut(let key) = $0.accessory { key } else { nil } }
                == (1...9).map { "⌘\($0)" })
    }

    @Test func theDesignsDestinationSitsBetweenNewThreadAndAutomationsWhileTheToolIsOn() {
        let off = SidebarDerivation.destinations(shown: nil, moreOpen: false, offlineHosts: 0, newThreadChord: "⌘N")
        #expect(off.map(\.title) == ["New thread", "Automations", "More"])
        for shown in [MainDestination.designs, .newDesign] {
            let on = SidebarDerivation.destinations(shown: shown, moreOpen: false, offlineHosts: 0, newThreadChord: "⌘N", designs: true)
            #expect(on.map(\.title) == ["New thread", "Designs", "Automations", "More"])
            #expect(on[1].icon == .symbol("pencil.tip"))
            #expect(on.map(\.selected) == [false, true, false, false])
        }
    }

    // MARK: The experiment

    @Test func theDesignToolIsOffUntilTurnedOnAndAResetTurnsItOff() {
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        #expect(!settings.designToolEnabled)
        settings.designToolEnabled = true
        #expect(AppSettings(store: defaults).designToolEnabled)
        settings.resetToDefaults()
        #expect(!settings.designToolEnabled)
        #expect(!AppSettings(store: defaults).designToolEnabled)
    }
}
