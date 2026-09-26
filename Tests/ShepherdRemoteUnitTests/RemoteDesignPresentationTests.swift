import CoreGraphics
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("A host's designs on the phone")
struct RemoteDesignPresentationTests {
    static let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let build = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let space = Space(id: SpaceID(rawValue: "s1"), name: "dashboard-web", path: "/src/dashboard-web")
    static let agent = AgentID(rawValue: "designer")
    static let phone = DesignPath("A-phone.dc.html")!
    static let wide = DesignPath("A.dc.html")!

    /// Noon on Monday 22 September 2025, UTC.
    static let now = Date(timeIntervalSince1970: 1_758_542_400)
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func ms(_ secondsAgo: Double) -> Double { (now.timeIntervalSince1970 - secondsAgo) * 1000 }

    static func design(_ id: String, _ name: String, system: String? = "acme-web", agent: AgentID? = nil, edited: Double,
                       boards: Int = 4, buildsSystem: Bool = false) -> Design {
        Design(id: DesignID(rawValue: id), name: name, spaceID: space.id, agentID: agent, systemNamespace: system, createdAt: 0,
               lastActiveAt: edited, boardCount: boards, buildsSystem: buildsSystem)
    }

    static func summary(_ design: Design, boards: Int = 4) -> RemoteDesignSummary {
        RemoteDesignSummary(design: design, revision: 3, boardCount: boards, openComments: 0,
                            firstBoard: RemoteDesignFirstBoard(path: wide, sha256: String(repeating: "a", count: 64), width: 1280, height: 800))
    }

    static func system(_ namespace: String, title: String, builtIn: Bool = false, sources: [String] = []) -> DesignSystemSummary {
        DesignSystemSummary(info: DesignSystemInfo(namespace: namespace, title: title, createdAt: 0, spaceID: space.id, sources: sources),
                            builtIn: builtIn)
    }

    // MARK: Words

    @Test(arguments: [
        (10.0, "now"), (120, "2m"), (3_599, "59m"), (3 * 3_600, "3h"),
        (13 * 3_600, "yesterday"), (3 * 86_400, "Fri"), (30 * 86_400, "Aug 23"),
    ] as [(Double, String)])
    func anAgeIsShort(_ secondsAgo: Double, _ text: String) {
        #expect(RemoteDesignPresentation.age(Self.ms(secondsAgo), now: Self.now, calendar: Self.utc) == text)
    }

    @Test func aTileSaysItsSystemBoardsAndAgeOrThatItIsDrawing() {
        let edited = Self.ms(120)
        #expect(RemoteDesignPresentation.tileDetail(system: "acme-web", boards: 4, drawing: false, edited: edited, now: Self.now)
            .hasPrefix("acme-web · 4 boards · "))
        #expect(RemoteDesignPresentation.tileDetail(system: nil, boards: 1, drawing: false, edited: edited, now: Self.now)
            .hasPrefix("1 board · "))
        #expect(RemoteDesignPresentation.tileDetail(system: "acme-web", boards: 2, drawing: true, edited: edited, now: Self.now)
            == "drawing · 2 boards")
        #expect(RemoteDesignPresentation.recentsDetail(boards: 4) == "design · 4 boards")
        #expect(RemoteDesignPresentation.recentsDetail(boards: nil) == "design")
        #expect(RemoteDesignPresentation.searchDetail(system: "acme-web", boards: 4) == "acme-web · 4 boards")
    }

    @Test func aSystemNamesWhereItWasReadFrom() {
        #expect(RemoteDesignPresentation.systemSource(Self.system("acme-web", title: "acme-web", sources: ["web/static/tokens.css"]),
                                                      project: "dashboard-web") == "dashboard-web · tokens.css")
        #expect(RemoteDesignPresentation.systemSource(Self.system("night-watch", title: "Night Watch", builtIn: true), project: nil)
            == "shepherd · ShepherdUI Tokens")
    }

    // MARK: The model

    @Test func designsListNewestFirstAcrossHostsWithTheirHostsNamed() {
        let studio = RemoteDesignsModel.Host(id: Self.studio, name: "Studio", listing: RemoteDesignListing(designs: [
            Self.summary(Self.design("d1", "Checkout funnel dashboard", edited: Self.ms(120))),
            Self.summary(Self.design("d2", "Events explorer", edited: Self.ms(86_400)), boards: 3),
        ], systems: [
            Self.system("night-watch", title: "Night Watch", builtIn: true),
            Self.system("acme-web", title: "acme-web", sources: ["tokens.css"]),
        ]), state: ShepherdState(spaces: [Self.space]))
        let build = RemoteDesignsModel.Host(id: Self.build, name: "build-01", listing: RemoteDesignListing(designs: [
            Self.summary(Self.design("d3", "Settings redesign", system: "night-watch", edited: Self.ms(3_600)), boards: 6),
        ], systems: []), state: ShepherdState())
        let model = RemoteDesignsModel(hosts: [studio, build], now: Self.now)
        #expect(model.available)
        #expect(model.tiles.map(\.name) == ["Checkout funnel dashboard", "Settings redesign", "Events explorer"])
        #expect(model.tiles.map(\.hostTag) == ["Studio", "build-01", "Studio"])
        #expect(model.tiles[1].ref == HostDesignRef(host: Self.build, design: DesignID(rawValue: "d3")))
        #expect(model.count == "3")
        // The host's own systems first, then Night Watch.
        #expect(model.systems.map(\.name) == ["acme-web", "Night Watch"])
        #expect(model.systemsSummary == "2 · acme-web, Night Watch")
    }

    @Test func aDesignWhoseAgentWorksIsDrawingAndASystemBuildIsNoTile() {
        let working = Agent(id: Self.agent, name: "Onboarding flow", spaceID: Self.space.id, tabID: TabID(rawValue: "t"), status: .working,
                            nameIsFinal: true, designID: DesignID(rawValue: "d1"))
        let drawn = Self.design("d1", "Onboarding flow", agent: Self.agent, edited: Self.ms(60), boards: 2)
        let build = Self.design("d2", "acme-web system", edited: Self.ms(30), buildsSystem: true)
        let host = RemoteDesignsModel.Host(id: Self.studio, name: "Studio",
                                           listing: RemoteDesignListing(designs: [Self.summary(drawn, boards: 2), Self.summary(build)], systems: []),
                                           state: ShepherdState(spaces: [Self.space], agents: [working], designs: [drawn, build]))
        let model = RemoteDesignsModel(hosts: [host], now: Self.now)
        #expect(model.tiles.map(\.name) == ["Onboarding flow"])
        #expect(model.tiles.first?.detail == "drawing · 2 boards")
        #expect(model.tiles.first?.drawing == true)
        #expect(model.tiles.first?.hostTag == nil)
        #expect(model.systemsSummary == nil)
    }

    @Test func noHostServingDesignsIsNoDesigns() {
        let model = RemoteDesignsModel(hosts: [], now: Self.now)
        #expect(!model.available)
        #expect(model.count == nil)
    }

    // MARK: A board

    @Test func boardsGoInTheCanvasOrderThenTheRest() {
        let other = DesignPath("B.dc.html")!
        let index = DesignIndex(title: "Checkout", boards: [
            Self.wide: DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "A · Funnel first"),
            Self.phone: DesignIndex.Board(x: 0, y: 0, w: 390, h: 844, title: " "),
            other: DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800),
        ], order: [Self.phone, Self.wide])
        #expect(RemoteDesignPresentation.boards(index) == [Self.phone, Self.wide, other])
        #expect(RemoteDesignPresentation.label(Self.wide, in: index) == "A · Funnel first")
        #expect(RemoteDesignPresentation.label(Self.phone, in: index) == "A-phone")
        #expect(RemoteDesignPresentation.size(index.boards[Self.phone]!) == "390 × 844")
    }

    @Test(arguments: [
        (CGSize(width: 390, height: 844), CGSize(width: 390, height: 600), 600.0 / 844),
        (CGSize(width: 1280, height: 800), CGSize(width: 390, height: 600), 390.0 / 1280),
        (CGSize(width: 200, height: 100), CGSize(width: 390, height: 600), 1.0),
        (CGSize.zero, CGSize(width: 390, height: 600), 1.0),
    ] as [(CGSize, CGSize, Double)])
    func aBoardFitsItsSpaceAndNeverGrows(_ board: CGSize, _ space: CGSize, _ scale: Double) {
        #expect(abs(RemoteDesignPresentation.fit(board, in: space) - scale) < 0.0001)
    }

    @Test func aTileFitsAWideBoardAcrossAndAPhoneBoardDown() {
        let tile = CGSize(width: 170, height: 110)
        #expect(abs(RemoteDesignPresentation.tileScale(CGSize(width: 1280, height: 800), in: tile) - 170.0 / 1280) < 0.0001)
        #expect(abs(RemoteDesignPresentation.tileScale(CGSize(width: 390, height: 844), in: tile) - 110.0 / 844) < 0.0001)
    }

    @Test func aZoomAndAPanStayInBounds() {
        #expect(RemoteDesignPresentation.clampZoom(0.5) == 1)
        #expect(RemoteDesignPresentation.clampZoom(9) == 4)
        #expect(RemoteDesignPresentation.clampZoom(.nan) == 1)
        let space = CGSize(width: 300, height: 600)
        #expect(RemoteDesignPresentation.clampPan(CGSize(width: 500, height: -500), content: CGSize(width: 600, height: 700), space: space)
            == CGSize(width: 150, height: -50))
        #expect(RemoteDesignPresentation.clampPan(CGSize(width: 40, height: 40), content: CGSize(width: 200, height: 400), space: space)
            == .zero)
    }

    // MARK: Comments

    static func comment(_ number: Int, board: DesignPath = phone, resolved: Bool = false, replies: [DesignCommentReply] = [],
                        target: String? = "Steps list") -> DesignComment {
        DesignComment(number: number, board: board, tid: 5, path: [1, 0], label: "Steps", target: target, text: "Thicker bars",
                      createdAt: ms(30), replies: replies, resolvedAt: resolved ? ms(10) : nil)
    }

    @Test func aBoardsPinsAreItsOpenCommentsInOrder() {
        let comments = DesignComments(revision: 2, comments: [
            Self.comment(2), Self.comment(1), Self.comment(3, resolved: true), Self.comment(4, board: Self.wide),
        ])
        #expect(RemoteDesignPresentation.pins(comments, board: Self.phone).map(\.number) == [1, 2])
        #expect(RemoteDesignPresentation.pins(nil, board: Self.phone).isEmpty)
    }

    @Test func aCommentSaysWhoAndWhatAndWhileTheAgentUpdatesIt() {
        let open = Self.comment(2)
        #expect(RemoteDesignPresentation.target(open) == "Steps list")
        #expect(RemoteDesignPresentation.target(Self.comment(1, target: nil)) == "Steps")
        #expect(RemoteDesignPresentation.meta(.user, at: Self.ms(5), now: Self.now) == "You · now")
        #expect(RemoteDesignPresentation.meta(.agent, at: Self.ms(60), now: Self.now) == "Design agent · 1m")
        #expect(RemoteDesignPresentation.updating(open, agentWorking: true, board: "A · phone") == "Design agent is updating A · phone")
        #expect(RemoteDesignPresentation.updating(open, agentWorking: false, board: "A · phone") == nil)
        let answered = Self.comment(2, replies: [DesignCommentReply(author: .agent, text: "Done on A and A · phone.", createdAt: Self.ms(20))])
        #expect(RemoteDesignPresentation.updating(answered, agentWorking: true, board: "A · phone") == nil)
        #expect(RemoteDesignPresentation.answer(answered)?.text == "Done on A and A · phone.")
    }

    @Test func theViewRecordNamesTheBoardOnScreenAndThePickedElement() {
        let bare = RemoteDesignPresentation.viewRecord(board: Self.phone, picked: nil, kind: nil, label: nil)
        #expect(bare.visibleBoards == ["A-phone.dc.html"])
        #expect(bare.selected.isEmpty)
        #expect(bare.isValid)
        let element = DesignElementID(board: Self.phone.viewName, tid: 5, path: [1, 0])!
        let picked = RemoteDesignPresentation.viewRecord(board: Self.phone, picked: element, kind: .shape, label: "Steps")
        #expect(picked.selectedBoards == ["A-phone.dc.html"])
        #expect(picked.selected == [element])
        #expect(picked.selection.first?.label == "Steps")
        #expect(picked.isValid)
    }
}
