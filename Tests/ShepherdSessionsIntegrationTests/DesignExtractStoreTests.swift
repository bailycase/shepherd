import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// `board_extract` on the host (docs/designs.md › Shared pieces): a piece, its import, exact copies
/// in other boards and the piece's frame, written as one revision.
@Suite("Design extraction on the host", .integrationTimeLimit)
struct DesignExtractStoreTests {
    typealias T = DesignToolsStoreTests
    let t = DesignToolsStoreTests()
    static let card = try! DesignPath.validate("Card.dc.html")

    static let cardMarkup = """
    <div class="card" style="width: 320px; height: 120px" data-el="Card">
      <h2>Pay now</h2>
      <p>Secure &amp; fast</p>
    </div>
    """

    static func page(_ body: String) -> String {
        DesignTests.board(root: #"<main style="width: 390px; height: 844px"><h1>Checkout</h1>\#(body)</main>"#)
    }

    func workspace() async throws -> (h: ScratchServer, design: Design) {
        let (h, design) = try await t.serverWithDesign()
        try await t.draw(h, design, [T.a: Self.page(Self.cardMarkup), T.b: Self.page("<section>" + Self.cardMarkup + "</section><p>Other</p>"),
                                      T.c: Self.page("<p>No card here</p>")])
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (h, design)
    }

    func tid(_ h: ScratchServer, _ design: Design, _ board: DesignPath, _ name: String) async throws -> Int {
        let source = try await h.server.designBoard(design.id, path: board).source
        return try #require(DesignBoardTree(source: source)?.elements.first { $0.name == name }).tid
    }

    @Test func anExtractionWritesThePieceTheImportAndTheCopiesAsOneRevision() async throws {
        let (h, design) = try await workspace()
        defer { h.stop() }
        let pushes = Locked(0)
        h.server.onDesignRevision = { _ in pushes.withValue { $0 += 1 } }
        h.server.watchDesignRevisions(of: [design.id])
        let before = try await t.revision(h, design)
        let element = try await tid(h, design, T.a, "div")

        let extracted = try await h.server.extractDesignPiece(design.id, request: DesignExtractRequest(
            path: "A.dc.html", element: String(element), piece: "Card", props: [.init(name: "label", text: "Pay now")],
            frame: .init(x: 0, y: 2_000, title: "Card"), copies: ["B.dc.html", "C.dc.html"]))

        #expect(extracted.result.changed && extracted.result.revision == before + 1 && extracted.piece == "Card.dc.html")
        #expect(extracted.importTag == #"<dc-import name="Card" hint-size="320px,120px" label="Pay now"></dc-import>"#)
        #expect(extracted.boards.map(\.path) == ["B.dc.html"] && extracted.boards.first?.count == 1)
        #expect(extracted.skipped.isEmpty && extracted.warnings.isEmpty)

        let a = try await h.server.designBoard(design.id, path: T.a).source
        let b = try await h.server.designBoard(design.id, path: T.b).source
        #expect(a.contains(extracted.importTag) && !a.contains("<h2>"))
        #expect(b.contains(extracted.importTag) && b.contains("<p>Other</p>"))
        #expect(try await h.server.designBoard(design.id, path: T.c).source.contains("No card here"), "C had no copy and is untouched")
        let piece = try await h.server.designBoard(design.id, path: Self.card).source
        #expect(piece.contains("<h2>{{ label }}</h2>") && piece.contains(#"label: this.props.label ?? "Pay now""#))

        // One frame for the piece, in canvas.json, in the same revision.
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.revision == before + 1)
        let frame = try #require(snapshot.index.boards[Self.card])
        #expect(frame.x == 0 && frame.y == 2_000 && frame.w == 320 && frame.h == 120 && frame.title == "Card")
        #expect(snapshot.index.order.last == Self.card)

        // What the agent is told: the piece's report and the source's, with the import's board existing now.
        #expect(extracted.pieceReport?.created == true && extracted.pieceReport?.roots == 1 && extracted.pieceReport?.imbalance == nil)
        #expect(extracted.pieceReport?.frame == .init(width: 320, height: 120))
        #expect(extracted.sourceReport?.missingImports.isEmpty == true && extracted.sourceReport?.delta ?? 0 < 0)
        #expect(extracted.boards.first?.report?.missingImports.isEmpty == true)

        #expect(try await h.server.designVersions(design.id, path: T.a).count == 1)
        #expect(try await h.server.designVersions(design.id, path: T.b).count == 1)
        await drainMainQueue()
        #expect(h.broadcasts.current.count == 1, "one broadcast")
        try await eventually("the live reload push") { pushes.current == 1 }

        // The usage index has both importers, and "used in 2 boards" is its label.
        let usage = try await h.server.designUsage(design.id)
        #expect(usage.importers[Self.card] == [T.a, T.b] && usage.label(for: Self.card) == "used in 2 boards")
    }

    @Test func aPieceWithNoFrameIsNoCanvasBoardButStillImports() async throws {
        let (h, design) = try await workspace()
        defer { h.stop() }
        let extracted = try await h.server.extractDesignPiece(design.id, request: DesignExtractRequest(
            path: "A.dc.html", element: String(try await tid(h, design, T.a, "div")), piece: "Card.dc.html"))
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.index.boards[Self.card] == nil && snapshot.boards[Self.card] != nil, "a board file the canvas doesn't list")
        #expect(extracted.pieceReport?.frame == nil)
        #expect(try await h.server.designUsage(design.id).importers[Self.card] == [T.a])
    }

    @Test func aFrameWithNoPlaceGoesBelowTheLowestBoard() async throws {
        let (h, design) = try await workspace()
        defer { h.stop() }
        _ = try await h.server.extractDesignPiece(design.id, request: DesignExtractRequest(
            path: "A.dc.html", element: String(try await tid(h, design, T.a, "div")), piece: "Card", frame: .init(page: nil)))
        let index = try await h.server.designSnapshot(design.id).index
        let lowest = index.boards.filter { $0.key != Self.card }.map { $0.value.y + $0.value.h }.max() ?? 0
        #expect(index.boards[Self.card]?.y == lowest + 120 && index.boards[Self.card]?.x == 0 && index.boards[Self.card]?.title == "Card")
    }

    @Test func allCopiesLooksInEveryOtherBoard() async throws {
        let (h, design) = try await workspace()
        defer { h.stop() }
        let extracted = try await h.server.extractDesignPiece(design.id, request: DesignExtractRequest(
            path: "A.dc.html", element: String(try await tid(h, design, T.a, "div")), piece: "Card", allCopies: true))
        #expect(extracted.boards.map(\.path) == ["B.dc.html"])
    }

    @Test func aCheckpointCanBeSavedFirstAndRestoredToUndoTheExtraction() async throws {
        let (h, design) = try await workspace()
        defer { h.stop() }
        let original = try await h.server.designBoard(design.id, path: T.a).source
        let extracted = try await h.server.extractDesignPiece(design.id, request: DesignExtractRequest(
            path: "A.dc.html", element: String(try await tid(h, design, T.a, "div")), piece: "Card", frame: .init(y: 2_000), checkpoint: "before extract"))
        #expect(extracted.checkpoint?.name == "before extract")
        let restored = try await h.server.designCheckpoint(design.id, request: DesignCheckpointRequest(action: .restore, name: "before extract"))
        #expect(restored.removed == ["Card.dc.html"] && restored.restored == ["A.dc.html"])
        #expect(try await h.server.designBoard(design.id, path: T.a).source == original)
        #expect(try await h.server.designSnapshot(design.id).index.boards[Self.card] == nil)
    }

    @Test func aBadExtractionIsRefusedAndChangesNothing() async throws {
        let (h, design) = try await workspace()
        defer { h.stop() }
        let project = t.files(h, design), at = try await t.revision(h, design)
        let element = String(try await tid(h, design, T.a, "div"))
        let root = String(try await tid(h, design, T.a, "main"))
        let cases: [(String, DesignExtractRequest, String)] = [
            ("the root", DesignExtractRequest(path: "A.dc.html", element: root, piece: "Card"), "invalid_extract"),
            ("a name a board has", DesignExtractRequest(path: "A.dc.html", element: element, piece: "B"), "invalid_extract"),
            ("a name that differs only in case", DesignExtractRequest(path: "A.dc.html", element: element, piece: "b"), "invalid_extract"),
            ("a prop's text that isn't there", DesignExtractRequest(path: "A.dc.html", element: element, piece: "Card", props: [.init(name: "x", text: "nope")]), "invalid_extract"),
            ("a piece beside no board", DesignExtractRequest(path: "A.dc.html", element: element, piece: "../Card"), "invalid_extract"),
            ("no such board", DesignExtractRequest(path: "Gone.dc.html", element: element, piece: "Card"), "no_such_board"),
            ("a path outside the grammar", DesignExtractRequest(path: "../A.dc.html", element: element, piece: "Card"), "invalid_path"),
            ("a bad checkpoint", DesignExtractRequest(path: "A.dc.html", element: element, piece: "Card", checkpoint: "../x"), "invalid_checkpoint"),
            ("a stale base", DesignExtractRequest(path: "A.dc.html", element: element, piece: "Card", baseRevision: 0), "stale_revision"),
            ("a frame the canvas refuses", DesignExtractRequest(path: "A.dc.html", element: element, piece: "Card", frame: .init(x: 0, y: 0, w: 5, h: 5)), "invalid_index"),
        ]
        for (what, request, code) in cases {
            do {
                _ = try await h.server.extractDesignPiece(design.id, request: request)
                Issue.record("\(what) was accepted")
            } catch let error as DesignStoreError {
                #expect(error.code == code, "\(what): \(error)")
            }
        }
        #expect(t.files(h, design) == project)
        #expect(try await t.revision(h, design) == at)
        #expect(try await h.server.designCheckpoint(design.id, request: DesignCheckpointRequest(action: .list)).checkpoints.isEmpty)
    }

    @Test func anExtractionFromABoardWithUnbalancedTagsIsRefusedWithTheLine() async throws {
        let (h, design) = try await workspace()
        defer { h.stop() }
        _ = try await h.server.writeDesignBoard(design.id, path: T.c, source: Self.page("<section><span>Total</section>" + Self.cardMarkup))
        let element = String(try await tid(h, design, T.c, "div"))
        do {
            _ = try await h.server.extractDesignPiece(design.id, request: DesignExtractRequest(path: "C.dc.html", element: element, piece: "Card"))
            Issue.record("extracted from a board whose tags don't balance")
        } catch let error as DesignStoreError {
            #expect(error.code == "invalid_extract" && error.description.contains("<span>") && error.description.contains("Fix that first"))
        }
    }

    @Test func theSocketAnswersAnExtractionAndRefusesAnotherAgent() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Checkout funnel")
        drawer.agent.designID = designID
        let stranger = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([drawer, stranger], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Checkout funnel", agentID: drawer.agent.id, createdAt: 1_000))
        _ = try await h.server.writeDesignBoards(designID, sources: [T.a: Self.page(Self.cardMarkup)])
        let source = try await h.server.designBoard(designID, path: T.a).source
        let element = try #require(DesignBoardTree(source: source)?.elements.first { $0.name == "div" }).tid
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.designExtract(id: 1, agentID: stranger.agent.id, designID: designID, request: DesignExtractRequest(path: "A.dc.html", element: "\(element)", piece: "Card")))
        guard case .error(1, "not_your_design", _) = try await agent.reply() else { Issue.record("another agent was served"); return }
        try agent.send(.designExtract(id: 2, agentID: drawer.agent.id, designID: designID, request: DesignExtractRequest(path: "A.dc.html", element: "\(element)", piece: "Card")))
        guard case .designExtracted(2, let result) = try await agent.reply() else { Issue.record("no extraction"); return }
        #expect(result.piece == "Card.dc.html" && result.result.changed)
        try agent.send(.designExtract(id: 3, agentID: drawer.agent.id, designID: designID, request: DesignExtractRequest(path: "A.dc.html", element: "\(element)", piece: "Card")))
        guard case .error(3, "invalid_extract", let why) = try await agent.reply() else { Issue.record("a second extraction was served"); return }
        #expect(why.contains("already has the name Card"), "the first one made it: \(why)")
    }
}
