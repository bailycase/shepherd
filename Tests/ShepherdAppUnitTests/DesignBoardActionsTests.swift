import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestKit
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The canvas's own changes and asks (docs/designs.md › Board actions): the actions over a board
/// picked whole, a board dragged (written once, where it lands), Duplicate, Variations and
/// another direction as messages carrying a view record, Present and its Play links (in-project
/// only), and pages with their notes.
@Suite("Design board actions")
@MainActor
struct DesignBoardActionsTests {
    private static func path(_ raw: String) -> DesignPath { DesignPath(raw)! }
    private static let a = path("A.dc.html"), b = path("B.dc.html"), phone = path("A-phone.dc.html"), system = path("Tokens.dc.html")

    /// Two pages: Flows (A, B, the phone, a title and a sticky, a drawing) and System (one board,
    /// its title). B is interactive.
    private static func index() throws -> DesignIndex {
        try DesignIndex.decode(Data("""
        {"v":3,"title":"Checkout","pages":[{"id":"flows","name":"Flows"},{"id":"system","name":"System"}],
         "boards":{
          "A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"title":"A · Funnel first","page":"flows"},
          "B.dc.html":{"x":1360,"y":0,"w":1280,"h":800,"title":"B · Step table","page":"flows","is_interactive":true},
          "A-phone.dc.html":{"x":0,"y":920,"w":390,"h":844,"title":"A · phone"},
          "Tokens.dc.html":{"x":0,"y":0,"w":1280,"h":800,"page":"system"}},
         "order":["A.dc.html","B.dc.html","A-phone.dc.html","Tokens.dc.html"],
         "notes":{"t1":{"kind":"title1","x":0,"y":-300,"text":"Checkout flows","w":240,"maxW":2600,"page":"flows"},
                  "s1":{"kind":"sticky","x":520,"y":1000,"text":"Total above the fold"},
                  "d1":{"kind":"pen","points":[[0,0],[4,5]],"page":"flows"},
                  "t2":{"kind":"title1","x":0,"y":-300,"text":"System","page":"system"}}}
        """.utf8))
    }

    /// Stands in for the server: keeps the index, moves its revision with each write, and records
    /// what the canvas asked.
    final class CanvasHost {
        var index: DesignIndex
        var revision: UInt64 = 1
        var patches: [(patch: JSONValue, base: UInt64?)] = []
        var duplicates: [(path: DesignPath, base: UInt64?)] = []
        var asked: [(text: String, record: DesignViewRecord)] = []
        var reports: [String] = []
        var hasAgent = true
        /// Revisions the next writes find the design at instead, as if the agent wrote meanwhile.
        var agentWrites = 0

        init(_ index: DesignIndex) { self.index = index }

        var snapshot: DesignSnapshot {
            DesignSnapshot(designID: DesignID(), revision: revision, index: index,
                           boards: Dictionary(uniqueKeysWithValues: index.boards.keys.map { ($0, "sha-\($0.rawValue)") }))
        }

        func actions() -> DesignCanvasActions {
            DesignCanvasActions(
                snapshot: { [self] _ in snapshot },
                duplicate: { [self] _, path, base in
                    duplicates.append((path, base))
                    let copy = DesignIndex.duplicatePath(for: path, taken: Set(index.boards.keys))!
                    index = index.duplicating(path, as: copy)!
                    revision += 1
                    return DesignDuplicate(path: copy, result: DesignWriteResult(revision: revision, changed: true, title: nil, boardCount: index.boards.count))
                },
                updateIndex: { [self] _, patch, base in
                    patches.append((patch, base))
                    if agentWrites > 0 {
                        agentWrites -= 1
                        revision += 1
                        throw DesignStoreError.stale(base: base ?? 0, current: revision)
                    }
                    index = try index.merging(patch)
                    revision += 1
                    return DesignWriteResult(revision: revision, changed: true, title: nil, boardCount: index.boards.count)
                },
                ask: { [self] _, text, record in
                    guard hasAgent else { return false }
                    asked.append((text, record))
                    return true
                },
                report: { [self] in reports.append($0) })
        }
    }

    private func screen(_ host: CanvasHost) async -> DesignScreenModel {
        let screen = DesignScreenModel(designID: DesignID(), host: nil, snapshot: { _ in host.snapshot }, source: { _, _ in "" },
                                       actions: host.actions())
        await screen.refresh()
        screen.resized(CGSize(width: 1200, height: 800))
        return screen
    }

    // MARK: Pages and notes

    @Test func aCanvasWithPagesShowsOnePagesBoardsAndNotes() async throws {
        let host = CanvasHost(try Self.index())
        let screen = await screen(host)
        #expect(screen.pages.map(\.name) == ["Flows", "System"])
        #expect(screen.page == "flows" && screen.pageName == "Flows")
        #expect(screen.boards.map(\.id) == ["A.dc.html", "B.dc.html", "A-phone.dc.html"], "a board naming no page is on the first")
        #expect(screen.notes.map(\.id) == ["s1", "t1"], "titles and stickies; drawings aren't drawn")
        #expect(screen.notes.first { $0.id == "t1" }?.width == 2600)
        #expect(screen.notes.first { $0.id == "s1" }?.kind == .sticky)

        screen.select("A.dc.html")
        screen.showPage("system")
        #expect(screen.boards.map(\.id) == ["Tokens.dc.html"])
        #expect(screen.notes.map(\.text) == ["System"])
        #expect(screen.picks.isEmpty, "what was selected on the page left goes")
        let record = try #require(screen.viewRecord)
        #expect(record.isValid && record.page == "system" && record.pageName == "System")
        #expect(record.visibleBoards == ["Tokens.dc.html"])
    }

    @Test func aCanvasWithoutPagesShowsEveryBoardAndNoPage() async throws {
        var index = try Self.index()
        index.pages = []
        let screen = await screen(CanvasHost(index))
        #expect(screen.page == nil && screen.pages.isEmpty)
        #expect(screen.boards.count == 4)
        #expect(screen.viewRecord?.page == nil && screen.viewRecord?.pageName == nil)
    }

    // MARK: The actions bar

    @Test func theActionsFloatOverTheBoardPickedWholeLast() async throws {
        let screen = await screen(CanvasHost(try Self.index()))
        #expect(screen.actionsBoard == nil)
        screen.select("A.dc.html")
        #expect(screen.actionsBoard == Self.a)
        let element = DesignElementPick(board: Self.b, id: DesignElementID(board: "B.dc.html", tid: 3, path: [1, 0])!,
                                        rect: CGRect(x: 0, y: 0, width: 10, height: 10), kind: .shape, label: nil, tag: "card")
        screen.setSelection([.init(board: Self.a), .init(board: Self.b, element: element)])
        #expect(screen.actionsBoard == nil, "an element picked last has its tag, not the board's actions")
        screen.select("B.dc.html")
        #expect(screen.isInteractive(Self.b) && !screen.isInteractive(Self.a))
        screen.present(Self.b)
        #expect(screen.actionsBoard == nil, "nothing floats over a presented board")
    }

    // MARK: Moving a board

    /// A drag moves the board as it goes and writes nothing; where it lands is written once, as
    /// whole canvas points, at the revision the canvas read.
    @Test func aDragWritesOnceWhereTheBoardLands() async throws {
        let host = CanvasHost(try Self.index())
        let screen = await screen(host)
        for step in 1...8 {
            screen.move(NWBoardMove(board: "A.dc.html", offset: CGSize(width: Double(step) * 10.3, height: -Double(step)), ended: false))
        }
        #expect(host.patches.isEmpty, "nothing is written while dragging")
        #expect(screen.boards.first { $0.id == "A.dc.html" }?.frame.origin == CGPoint(x: 82.4, y: -8))
        #expect(screen.boards.first { $0.id == "B.dc.html" }?.frame.origin == CGPoint(x: 1360, y: 0), "only the dragged board moves")

        let write = screen.move(NWBoardMove(board: "A.dc.html", offset: CGSize(width: 90.6, height: -9.4), ended: true))
        #expect(screen.boards.first { $0.id == "A.dc.html" }?.frame.origin == CGPoint(x: 91, y: -9), "it stays where it landed")
        await write?.value
        #expect(host.index.boards[Self.a]?.x == 91 && screen.movedTo.isEmpty)
        #expect(host.patches.count == 1 && screen.moveWrites == 1)
        #expect(host.patches.first?.base == 1)
        #expect(host.patches.first?.patch == .object(["boards": .object(["A.dc.html": .object(["x": .number(91), "y": .number(-9)])])]))
        #expect(host.index.boards[Self.a]?.y == -9 && host.index.boards[Self.a]?.title == "A · Funnel first", "the rest of its entry stays")
        #expect(screen.boards.first { $0.id == "A.dc.html" }?.frame.origin == CGPoint(x: 91, y: -9))
    }

    @Test func aDragThatEndsWhereItBeganWritesNothing() async throws {
        let host = CanvasHost(try Self.index())
        let screen = await screen(host)
        screen.move(NWBoardMove(board: "A.dc.html", offset: CGSize(width: 40, height: 0), ended: false))
        #expect(screen.move(NWBoardMove(board: "A.dc.html", offset: CGSize(width: 0.2, height: -0.3), ended: true)) == nil)
        #expect(host.patches.isEmpty && screen.moving == nil)
    }

    /// The agent wrote while the board was held: the move is refused as stale, read again and
    /// written once more.
    @Test func aStaleMoveIsReadAgainAndWrittenOnceMore() async throws {
        let host = CanvasHost(try Self.index())
        let screen = await screen(host)
        host.agentWrites = 1
        await screen.move(NWBoardMove(board: "B.dc.html", offset: CGSize(width: 0, height: 200), ended: true))?.value
        #expect(host.index.boards[Self.b]?.y == 200)
        #expect(host.patches.map(\.base) == [1, 2])
        #expect(host.reports.isEmpty)
    }

    // MARK: Duplicate, Variations, another direction

    @Test func duplicateAddsOneBoardAndPicksIt() async throws {
        let host = CanvasHost(try Self.index())
        let screen = await screen(host)
        screen.select("A.dc.html")
        await screen.duplicate(Self.a)?.value
        #expect(host.duplicates.map(\.path) == [Self.a] && host.duplicates.first?.base == 1)
        #expect(screen.boards.map(\.id) == ["A.dc.html", "A-copy.dc.html", "B.dc.html", "A-phone.dc.html"])
        #expect(screen.picks == [.init(board: Self.path("A-copy.dc.html"))])
        #expect(screen.actionsBoard == Self.path("A-copy.dc.html"))
    }

    /// Variations and another direction are fixed words; the board goes in the record, as data.
    @Test func variationsAndAnotherDirectionAskTheAgentWithTheBoardInTheRecord() async throws {
        let host = CanvasHost(try Self.index())
        let screen = await screen(host)
        screen.select("B.dc.html")
        await screen.askForVariations(of: Self.a)?.value
        await screen.askForAnotherDirection()?.value
        #expect(host.asked.map(\.text) == [DesignScreenModel.variationsMessage, DesignScreenModel.anotherDirectionMessage])
        let variations = try #require(host.asked.first?.record)
        #expect(variations.isValid && variations.selectedBoards == ["A.dc.html"] && variations.selected.isEmpty)
        #expect(variations.page == "flows")
        let direction = try #require(host.asked.last?.record)
        #expect(direction.isValid && direction.selectedBoards.isEmpty)
        #expect(screen.picks == [.init(board: Self.b)], "asking leaves the selection as it was")

        host.hasAgent = false
        await screen.askForAnotherDirection()?.value
        #expect(host.reports.count == 1, "a design without an agent says so")
    }

    // MARK: Present and Play

    @Test func presentShowsThePickedBoardFocusedAndAgainGoesBack() async throws {
        let screen = await screen(CanvasHost(try Self.index()))
        #expect(screen.canPresent)
        screen.select("B.dc.html")
        screen.togglePresent()
        #expect(screen.presented == Self.b)
        let record = try #require(screen.viewRecord)
        #expect(record.isValid && record.mode == .focused && record.visibleBoards == ["B.dc.html"] && record.selectedBoards.isEmpty)
        screen.togglePresent()
        #expect(screen.presented == nil && screen.viewRecord?.mode == .canvas)
        screen.clearSelection()
        screen.togglePresent()
        #expect(screen.presented != nil, "with nothing picked, a board on screen")
    }

    /// A presented board's link to another board of the design moves Play there; a link to a board
    /// the design doesn't list, or from a board that isn't presented, moves nothing.
    @Test func aPlayLinkMovesOnlyBetweenTheDesignsBoards() async throws {
        let screen = await screen(CanvasHost(try Self.index()))
        screen.present(Self.a)
        screen.follow(link: Self.b, from: Self.a)
        #expect(screen.presented == Self.b)
        screen.follow(link: Self.path("Missing.dc.html"), from: Self.b)
        #expect(screen.presented == Self.b)
        screen.follow(link: Self.phone, from: Self.a)
        #expect(screen.presented == Self.b, "only the presented board's links count")
        screen.follow(link: Self.system, from: Self.b)
        #expect(screen.presented == Self.system, "a board on another page is still the design's")
        let record = try #require(screen.viewRecord)
        #expect(record.isValid && record.page == "system" && record.pageName == "System", "the record names the presented board's page")
        screen.showPage("system")
        #expect(screen.presented == nil, "another page closes the presented board")
        #expect(DesignScreenModel.playTarget(Self.path("Missing.dc.html"), in: try Self.index()) == nil)
    }
}
