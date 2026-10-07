import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// Jump to a board (JumpInContext): what the card lists, in what order, and where its highlight
/// lands as it opens.
@Suite("Design jump")
struct DesignJumpTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let design = DesignID(rawValue: "checkout")

    private static func path(_ name: String) -> DesignPath { DesignPath(name)! }

    /// The checkout funnel's six boards in canvas order, as the board draws them.
    private static let index: DesignIndex = {
        var boards: [DesignPath: DesignIndex.Board] = [:]
        let rows: [(String, String, Double, Double)] = [
            ("A.dc.html", "A · Funnel first", 1280, 800), ("B.dc.html", "B · Step table", 1280, 800),
            ("C.dc.html", "C · Trend", 1280, 800), ("D.dc.html", "D · Funnel empty state", 1280, 800),
            ("E.dc.html", "E · Funnel by platform", 1280, 800), ("A-phone.dc.html", "A · phone", 390, 844),
        ]
        for (index, row) in rows.enumerated() {
            boards[path(row.0)] = DesignIndex.Board(x: Double(index) * 500, y: 0, w: row.2, h: row.3, title: row.1)
        }
        return DesignIndex(title: "Checkout", boards: boards, order: rows.map { path($0.0) })
    }()

    /// E 2m ago, A 10m ago, C yesterday: the board's Recent.
    private static var recents: DesignJumpRecents {
        var recents = DesignJumpRecents()
        let time = now.timeIntervalSince1970
        recents.opened(path("C.dc.html"), in: design, at: time - 26 * 3600)
        recents.opened(path("A.dc.html"), in: design, at: time - 600)
        recents.opened(path("E.dc.html"), in: design, at: time - 120)
        return recents
    }

    private func items(_ query: String = "", scope: DesignJumpScope = .thisDesign, current: String? = "A.dc.html",
                       recents: DesignJumpRecents = Self.recents, designs: [Design] = []) -> [DesignJumpItem] {
        DesignJump.items(scope: scope, query: query, index: Self.index, design: Self.design, current: current.map(Self.path),
                         recents: recents, designs: designs, now: Self.now)
    }

    @Test func recentBoardsComeFirstNewestFirstThenTheRestInCanvasOrder() {
        let rows = items()
        #expect(rows.map(\.title) == ["E · Funnel by platform", "A · Funnel first", "C · Trend",
                                      "B · Step table", "D · Funnel empty state", "A · phone"])
        #expect(rows.prefix(3).allSatisfy { $0.section == .recent })
        #expect(rows.dropFirst(3).allSatisfy { $0.section == .otherBoards })
        #expect(rows[0].meta == "1280 × 800 · opened 2m ago")
        #expect(rows[2].meta == "1280 × 800 · opened yesterday")
        #expect(rows[5].meta == "390 × 844", "an unopened board shows its size alone")
        #expect(rows[1].tag == "this board")
    }

    /// Getting back to the board you were just on takes no typing: the highlight skips the board
    /// on screen when it is the newest.
    @Test func theHighlightLandsOnTheBoardBeforeThisOne() {
        #expect(DesignJump.initialHighlight(items(current: "A.dc.html")) == 0, "E is the latest and isn't on screen")
        var recents = Self.recents
        recents.opened(Self.path("B.dc.html"), in: Self.design, at: Self.now.timeIntervalSince1970)
        let rows = items(current: "B.dc.html", recents: recents)
        #expect(rows[0].title == "B · Step table" && rows[0].tag == "this board")
        #expect(DesignJump.initialHighlight(rows) == 1)
    }

    @Test func aQueryRanksMatchesAcrossBothSections() {
        let rows = items("fun")
        #expect(rows.map(\.title) == ["E · Funnel by platform", "A · Funnel first", "D · Funnel empty state"])
        #expect(items("zzz").isEmpty)
    }

    @Test func goneBoardsLeaveRecentAndTheListRemembersAtMostItsLimit() {
        var recents = Self.recents
        recents.opened(Self.path("Gone.dc.html"), in: Self.design, at: Self.now.timeIntervalSince1970)
        #expect(!items(recents: recents).contains { $0.title == "Gone" }, "a board the design lost isn't listed")
        for index in 0..<20 {
            recents.opened(Self.path("X\(index).dc.html"), in: Self.design, at: Double(index))
        }
        #expect(recents.entries(Self.design).count == DesignJumpRecents.limit)
        #expect(recents.entries(Self.design).first?.path == "X19.dc.html")
    }

    @Test func allDesignsListsDesignsMostRecentlyEditedFirst() {
        let older = Design(name: "Onboarding", createdAt: 1, lastActiveAt: 1_000, boardCount: 1)
        let newer = Design(id: Self.design, name: "Checkout funnel dashboard", createdAt: 2,
                           lastActiveAt: (Self.now.timeIntervalSince1970 - 7200) * 1000, boardCount: 6)
        let build = Design(name: "acme-web system", createdAt: 3, lastActiveAt: 9e12, buildsSystem: true)
        let rows = items(scope: .allDesigns, designs: [older, newer, build])
        #expect(rows.map(\.title) == ["Checkout funnel dashboard", "Onboarding"], "a system build is not a design to jump to")
        #expect(rows[0].meta == "6 boards · edited 2h ago")
        #expect(rows[0].tag == "this design")
    }

    @Test func recentsSurviveARoundTrip() throws {
        let data = try JSONEncoder().encode(Self.recents)
        #expect(try JSONDecoder().decode(DesignJumpRecents.self, from: data) == Self.recents)
    }
}
