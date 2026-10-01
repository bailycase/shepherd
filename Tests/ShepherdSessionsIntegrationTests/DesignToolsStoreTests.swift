import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The design agent's batch tools on the host (docs/designs.md › The design agent): reports after
/// every write, token enforcement, `boards_edit`, `board_search`, the usage index, and
/// checkpoints, against a real server and design store.
@Suite("Design agent tools on the host", .integrationTimeLimit)
struct DesignToolsStoreTests {
    static let a = try! DesignPath.validate("A.dc.html")
    static let b = try! DesignPath.validate("B.dc.html")
    static let c = try! DesignPath.validate("C.dc.html")
    static let card = try! DesignPath.validate("Card.dc.html")

    /// A 390×844 board holding `body`.
    static func board(_ body: String, size: (Int, Int) = (390, 844)) -> String {
        DesignTests.board(root: #"<div style="width: \#(size.0)px; height: \#(size.1)px">\#(body)</div>"#, size: size)
    }

    /// A board with `n` chips, one per line.
    static func chips(_ n: Int = 2) -> String {
        board((1...n).map { #"<p class="chip">Pay now \#($0)</p>"# }.joined(separator: "\n"))
    }

    func serverWithDesign() async throws -> (h: ScratchServer, design: Design) {
        let h = try ScratchServer.fresh()
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([Fixture.agent(in: space)], space: space))
        let design = Design(name: "Checkout funnel", createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (h, design)
    }

    /// Writes `boards` and gives each a frame on the canvas.
    @discardableResult
    func draw(_ h: ScratchServer, _ design: Design, _ boards: [DesignPath: String]) async throws -> UInt64 {
        let written = try await h.server.writeDesignBoards(design.id, sources: boards)
        var frames: [String: JSONValue] = [:]
        for (index, path) in boards.keys.sorted().enumerated() {
            frames[path.rawValue] = .object(["x": .number(Double(index * 500)), "y": .number(0), "w": .number(390), "h": .number(844),
                                             "title": .string(path.stem)])
        }
        let result = try await h.server.updateDesignIndex(design.id, patch: .object(["boards": .object(frames)]))
        return max(written.result.revision, result.revision)
    }

    func files(_ h: ScratchServer, _ design: Design) -> [String: Data] {
        DesignTests.contents(of: h.server.designs.projectFolder(for: design.id))
    }

    func revision(_ h: ScratchServer, _ design: Design) async throws -> UInt64 {
        try await h.server.designSnapshot(design.id).revision
    }

    /// Installs a small system in the design: two colors, two spacings and a radius.
    func installSystem(_ h: ScratchServer, _ design: Design) async throws {
        let tokens: JSONValue = .object([
            "format": .string(DesignSystemTokens.format), "name": .string("acme"),
            "colors": .array([.object(["name": .string("--accent"), "value": .string("#3056d3")]),
                              .object(["name": .string("--ink"), "value": .string("#1c2330")])]),
            "spacing": .array([.object(["name": .string("--space-3"), "px": .number(12)]),
                               .object(["name": .string("--space-4"), "px": .number(16)])]),
            "radii": .array([.object(["name": .string("--radius-md"), "px": .number(8)])]),
        ])
        _ = try await h.server.writeDesignSystem(DesignSystemWrite(namespace: "acme", tokens: tokens, install: true), for: design.id)
    }

    // MARK: Reports

    @Test func aBoardWriteReportsWhatItLeftBehind() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let source = Self.chips()
        let result = try await h.server.writeDesignBoard(design.id, path: Self.a, source: source)
        let report = try #require(result.report)
        #expect(report.created && report.bytes == source.utf8.count && report.delta == nil && report.diff == nil)
        #expect(report.roots == 1 && report.imbalance == nil && report.missingImports.isEmpty)
        #expect(report.root == .init(width: 390, height: 844) && report.preview == report.root && report.frame == nil)
        #expect(report.tokenSource == nil, "a design with no system has no tokens to hold a board to")
        #expect(!report.hasProblem)
    }

    @Test func aRewriteReportsTheSizeChangeADiffAndTheFrame() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        try await draw(h, design, [Self.a: Self.chips()])
        let result = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.chips(3))
        let report = try #require(result.report)
        #expect(!report.created && report.delta == Self.chips(3).utf8.count - Self.chips().utf8.count)
        // The last chip shared its line with the root's end tag, so that line changes too.
        #expect(report.diff?.added == 2 && report.diff?.removed == 1 && report.diff?.lines.contains { $0.contains("Pay now 3") } == true)
        #expect(report.frame == .init(width: 390, height: 844), "the board's frame in canvas.json")
    }

    @Test func anEditReportsLikeAWriteAndAnUnchangedOneReportsNoDiff() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        try await draw(h, design, [Self.a: Self.chips()])
        let edited = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [DesignBoardEdit(find: "Pay now 1", replace: "Buy now")])
        #expect(edited.result.report?.diff?.lines.count == 2 && edited.result.report?.delta == -2)
        let same = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [DesignBoardEdit(find: "Buy now", replace: "Buy now")])
        #expect(same.result.changed == false && same.result.report?.diff == nil)
    }

    @Test func aDroppedEndTagIsReportedAndTheBoardIsStillWritten() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let result = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board("<section><span>Total</section>"))
        let report = try #require(result.report)
        #expect(result.changed && report.imbalance?.kind == .unclosed && report.imbalance?.tag == "span" && report.hasProblem)
    }

    @Test func importsOfBoardsThatAreMissingAreReportedUntilTheyExist() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let importing = Self.board(#"<dc-import name="Card" hint-size="10px,10px"></dc-import>"#)
        let first = try await h.server.writeDesignBoard(design.id, path: Self.a, source: importing)
        #expect(first.report?.missingImports == ["Card"])
        _ = try await h.server.writeDesignBoard(design.id, path: Self.card, source: Self.board("<p>Card</p>"))
        let second = try await h.server.writeDesignBoard(design.id, path: Self.a, source: importing + "\n")
        #expect(second.report?.missingImports.isEmpty == true)
    }

    // MARK: Tokens

    private func styled(_ style: String) -> String { Self.board(#"<p style="\#(style)">Hi</p>"#) }

    @Test func aWriteListsOnlyTheOffSystemValuesItIntroduced() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        try await installSystem(h, design)
        let first = try await h.server.writeDesignBoard(design.id, path: Self.a, source: styled("color: #3a56d4; padding: 12px"))
        #expect(first.report?.tokenSource == "acme")
        #expect(first.report?.offSystem.map(\.value) == ["#3a56d4"], "a new board introduces what it holds that the system doesn't")

        let touched = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [DesignBoardEdit(find: ">Hi<", replace: ">Hello<")])
        #expect(touched.result.report?.offSystem.isEmpty == true, "the old #3a56d4 is not this write's")

        let added = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [
            DesignBoardEdit(find: "padding: 12px", replace: "padding: 13px; margin: 24px"),
        ])
        #expect(added.result.report?.offSystem.map(\.value) == ["13px", "24px"])
        #expect(added.result.report?.offSystem.first?.nearest == "--space-3 12px")
        #expect(try await h.server.designBoard(design.id, path: Self.a).source.contains("padding: 13px"), "warn writes it all the same")
    }

    @Test func snapReplacesWhatTheWriteIntroducedWithTokensAndReportsEach() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        try await installSystem(h, design)
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: styled("color: #3a56d4"))
        let edited = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [
            DesignBoardEdit(find: "color: #3a56d4", replace: "color: #3a56d4; padding: 13px; border-radius: 9px; background: #1d2331"),
        ], tokens: .snap)
        let source = try await h.server.designBoard(design.id, path: Self.a).source
        #expect(source.contains("color: #3a56d4; padding: var(--space-3); border-radius: var(--radius-md); background: var(--ink)"),
                "the old color stays; the new values snap")
        let report = try #require(edited.result.report)
        #expect(report.snapped.map(\.to) == ["var(--space-3)", "var(--radius-md)", "var(--ink)"])
        #expect(report.snapped.map(\.from) == ["13px", "9px", "#1d2331"] && report.offSystem.isEmpty)
    }

    @Test func strictRefusesAWriteThatIntroducesOffSystemValuesAndChangesNothing() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        try await installSystem(h, design)
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: styled("color: #3056d3"))
        let project = files(h, design), at = try await revision(h, design)
        for attempt in 0..<2 {
            do {
                if attempt == 0 {
                    _ = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [DesignBoardEdit(find: "#3056d3", replace: "#3a56d4")], tokens: .strict)
                } else {
                    _ = try await h.server.writeDesignBoard(design.id, path: Self.b, source: styled("gap: 13px"), tokens: .strict)
                }
                Issue.record("strict wrote off-system values")
            } catch let error as DesignStoreError {
                #expect(error.code == "tokens_off_system", "\(error)")
                #expect(error.description.contains("acme") && error.description.contains("Nothing was changed"))
            }
        }
        #expect(files(h, design) == project)
        #expect(try await revision(h, design) == at)
        // On-system, strict writes.
        let ok = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [DesignBoardEdit(find: "#3056d3", replace: "var(--accent)")], tokens: .strict)
        #expect(ok.result.changed)
    }

    @Test func aDesignWithNoSystemHoldsNoTokensWhateverTheMode() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        for (index, mode) in DesignTokenMode.allCases.enumerated() {
            let result = try await h.server.writeDesignBoard(design.id, path: Self.a, source: styled("color: #123456; padding: \(13 + index)px"), tokens: mode)
            #expect(result.changed && result.report?.tokenSource == nil && result.report?.offSystem.isEmpty == true)
        }
    }

    // MARK: boards_edit

    private func chipDesign(count: Int = 3) async throws -> (h: ScratchServer, design: Design, paths: [DesignPath]) {
        let (h, design) = try await serverWithDesign()
        let paths = Array([Self.a, Self.b, Self.c].prefix(count))
        try await draw(h, design, Dictionary(uniqueKeysWithValues: paths.map { ($0, Self.chips()) }))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (h, design, paths)
    }

    @Test func aBatchEditsEveryBoardAsOneRevisionOneBroadcastAndOnePush() async throws {
        let (h, design, paths) = try await chipDesign()
        defer { h.stop() }
        let pushes = Locked(0)
        h.server.onDesignRevision = { _ in pushes.withValue { $0 += 1 } }
        h.server.watchDesignRevisions(of: [design.id])
        let before = try await revision(h, design)

        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: paths.map { .init(path: $0.rawValue) }, edits: [DesignBoardEdit(find: "Pay now", replace: "Buy now", all: true)]))

        #expect(batch.boards.map(\.status) == [.edited, .edited, .edited] && batch.boards.map(\.replaced) == [[2], [2], [2]])
        #expect(batch.result.changed && batch.result.revision == before + 1 && !batch.blocked && !batch.dryRun)
        #expect(batch.boards.allSatisfy { $0.report?.diff?.added == 2 && $0.report?.created == false })
        for path in paths {
            let source = try await h.server.designBoard(design.id, path: path).source
            #expect(source.contains("Buy now 1") && !source.contains("Pay now"))
            #expect(try await h.server.designVersions(design.id, path: path).count == 1, "what the batch replaced is each board's next version")
        }
        #expect(try await revision(h, design) == before + 1)
        await drainMainQueue()
        #expect(h.broadcasts.current.count == 1, "one broadcast")
        try await eventually("the live reload push") { pushes.current == 1 }
        await drainMainQueue()
        #expect(pushes.current == 1, "one push for the whole batch")
    }

    @Test func aBatchByDefaultWritesTheBoardsThatMatchAndReportsTheRest() async throws {
        let (h, design, paths) = try await chipDesign()
        defer { h.stop() }
        let before = try await revision(h, design)
        // C holds the text twice more, so `find` without all is ambiguous there.
        _ = try await h.server.writeDesignBoard(design.id, path: Self.c, source: Self.board("<p>Total</p><p>Total</p>"))
        let base = try await revision(h, design)
        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: (paths.map(\.rawValue) + ["Missing.dc.html", "../bad.dc.html", "A.dc.html"]).map { .init(path: $0) },
            edits: [DesignBoardEdit(find: "<p>Total</p>", replace: "<p>Sum</p>")]))
        // A and B hold no "Total": no match. C holds two. Missing/bad are reported. A, named twice, is invalid the second time.
        #expect(batch.boards.map(\.status) == [.noMatch, .noMatch, .noMatch, .missing, .invalid, .invalid])
        #expect(batch.boards[0].edit == 1 && batch.boards[0].matches == 0)
        #expect(batch.boards[2].edit == 1 && batch.boards[2].matches == 2 && batch.boards[2].message?.contains("matched 2 times without all") == true)
        #expect(batch.boards[5].message == "named twice in this call")
        #expect(!batch.result.changed && batch.result.revision == base && base > before)

        // Now one matches: it is written, the others reported, in one revision.
        let some = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: paths.map { .init(path: $0.rawValue) }, edits: [DesignBoardEdit(find: "Pay now 1", replace: "Buy")]))
        #expect(some.boards.map(\.status) == [.edited, .edited, .noMatch])
        #expect(some.result.revision == base + 1)
        #expect(try await h.server.designBoard(design.id, path: Self.c).source.contains("<p>Total</p>"), "C is as it was")
    }

    @Test func atomicWritesNothingUnlessEveryBoardMatches() async throws {
        let (h, design, paths) = try await chipDesign()
        defer { h.stop() }
        _ = try await h.server.writeDesignBoard(design.id, path: Self.c, source: Self.board("<p>Total</p>"))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let project = files(h, design), at = try await revision(h, design)
        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: paths.map { .init(path: $0.rawValue) }, edits: [DesignBoardEdit(find: "Pay now 1", replace: "Buy")], atomic: true))
        #expect(batch.blocked && batch.atomic && !batch.result.changed)
        #expect(batch.boards.map(\.status) == [.wouldEdit, .wouldEdit, .noMatch], "the boards that match say what they would have done")
        #expect(batch.boards[0].report?.diff != nil)
        #expect(files(h, design) == project)
        #expect(try await revision(h, design) == at)
        await drainMainQueue()
        #expect(h.broadcasts.current.isEmpty)

        // Every board matching writes them all.
        let all = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: [Self.a, Self.b].map { .init(path: $0.rawValue) }, edits: [DesignBoardEdit(find: "Pay now 1", replace: "Buy")], atomic: true))
        #expect(!all.blocked && all.boards.map(\.status) == [.edited, .edited] && all.result.revision == at + 1)
    }

    @Test func aDryRunReportsEveryBoardAndWritesNothing() async throws {
        let (h, design, paths) = try await chipDesign()
        defer { h.stop() }
        let project = files(h, design), at = try await revision(h, design)
        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: paths.map { .init(path: $0.rawValue) } + [.init(path: "Gone.dc.html")],
            edits: [DesignBoardEdit(find: "Pay now", replace: "Buy now", all: true)], dryRun: true, checkpoint: "never saved"))
        #expect(batch.dryRun && !batch.blocked && !batch.result.changed && batch.checkpoint == nil)
        #expect(batch.boards.map(\.status) == [.wouldEdit, .wouldEdit, .wouldEdit, .missing])
        #expect(batch.boards.prefix(3).allSatisfy { $0.replaced == [2] && $0.report?.diff?.added == 2 })
        #expect(files(h, design) == project)
        #expect(try await revision(h, design) == at)
        #expect(try await h.server.designCheckpoint(design.id, request: DesignCheckpointRequest(action: .list)).checkpoints.isEmpty,
                "a dry run saves no checkpoint")
    }

    @Test func aBoardMayHaveEditsOfItsOwnInsteadOfTheSharedOnes() async throws {
        let (h, design, paths) = try await chipDesign(count: 2)
        defer { h.stop() }
        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html"), .init(path: "B.dc.html", edits: [DesignBoardEdit(find: "Pay now 2", replace: "Own")])],
            edits: [DesignBoardEdit(find: "Pay now 1", replace: "Shared")]))
        #expect(batch.boards.map(\.status) == [.edited, .edited])
        let a = try await h.server.designBoard(design.id, path: paths[0]).source
        let b = try await h.server.designBoard(design.id, path: paths[1]).source
        #expect(a.contains("Shared") && a.contains("Pay now 2"))
        #expect(b.contains("Own") && b.contains("Pay now 1"), "B's own edit replaced the shared one")
    }

    @Test func aResultTheBoardChecksRefuseIsReportedForThatBoardAlone() async throws {
        let (h, design, paths) = try await chipDesign(count: 2)
        defer { h.stop() }
        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html", edits: [DesignBoardEdit(find: "width: 390px; height: 844px", replace: "width: 400px; height: 844px")]),
                     .init(path: "B.dc.html", edits: [DesignBoardEdit(find: "Pay now 1", replace: "Ok")])]))
        #expect(batch.boards.map(\.status) == [.refused, .edited])
        #expect(batch.boards[0].message?.contains("$preview") == true && batch.boards[0].message?.contains("can't be written") == true)
        #expect(try await h.server.designBoard(design.id, path: paths[0]).source.contains("width: 390px"))
    }

    @Test func anEditThatChangesNothingIsUnchangedAndMovesNothing() async throws {
        let (h, design, paths) = try await chipDesign(count: 1)
        defer { h.stop() }
        let at = try await revision(h, design)
        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: [.init(path: paths[0].rawValue)], edits: [DesignBoardEdit(find: "Pay now 1", replace: "Pay now 1")]))
        #expect(batch.boards.map(\.status) == [.unchanged] && batch.boards[0].replaced == [1])
        #expect(!batch.result.changed)
        #expect(try await revision(h, design) == at)
        #expect(try await h.server.designVersions(design.id, path: paths[0]).isEmpty)
    }

    @Test func aBatchHoldsEachBoardToTheDesignsTokens() async throws {
        let (h, design, paths) = try await chipDesign(count: 2)
        defer { h.stop() }
        try await installSystem(h, design)
        let edit = DesignBoardEdit(find: #"<p class="chip">Pay now 1</p>"#, replace: #"<p class="chip" style="padding: 13px">Pay now 1</p>"#)
        let strict = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: paths.map { .init(path: $0.rawValue) }, edits: [edit], tokens: .strict))
        #expect(strict.boards.map(\.status) == [.refused, .refused] && strict.boards[0].message?.contains("13px") == true)
        #expect(!strict.result.changed)

        let snapped = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: paths.map { .init(path: $0.rawValue) }, edits: [edit], tokens: .snap))
        #expect(snapped.boards.map(\.status) == [.edited, .edited])
        #expect(snapped.boards.allSatisfy { $0.report?.snapped.map(\.to) == ["var(--space-3)"] })
        #expect(try await h.server.designBoard(design.id, path: paths[1]).source.contains("padding: var(--space-3)"))
    }

    @Test func snappingExistingValuesTakesInWhatWasAlreadyThere() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        try await installSystem(h, design)
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: styled("color: #3a56d4; padding: 13px"))
        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html")], tokens: .snap, snapExisting: true))
        #expect(batch.boards.map(\.status) == [.edited] && batch.boards[0].report?.snapped.count == 2)
        #expect(try await h.server.designBoard(design.id, path: Self.a).source.contains("color: var(--accent); padding: var(--space-3)"))
    }

    @Test func aBatchKeepsTheCommentsOnItsBoardsPinnedToTheirElements() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let root = #"<div data-el="Checkout funnel" style="width: 390px; height: 844px"><h2>Checkout funnel</h2><p>48,210 people</p></div>"#
        try await draw(h, design, [Self.a: DesignTests.board(root: root)])
        let comment = try await h.server.addDesignComment(design.id, draft: DesignCommentDraft(
            board: Self.a, tid: 4, path: [1, 1], text: "Show the counts.")).comment
        let before = try await h.server.designComments(design.id)

        _ = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: [.init(path: "A.dc.html")],
            edits: [DesignBoardEdit(find: "<h2>Checkout funnel</h2>", replace: "<h2>Checkout funnel</h2><h3>New</h3>")]))

        let after = try await h.server.designComments(design.id)
        let moved = try #require(after.comments.first { $0.id == comment.id })
        #expect(moved.tid == 5 && moved.path == [1, 2] && !moved.detached, "the comment found its element again")
        #expect(moved.text == "Show the counts." && after.comments.count == before.comments.count)
    }

    @Test func aBatchCanSaveACheckpointFirstButOnlyWhenThereIsSomethingToWrite() async throws {
        let (h, design, paths) = try await chipDesign()
        defer { h.stop() }
        let nothing = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: paths.map { .init(path: $0.rawValue) }, edits: [DesignBoardEdit(find: "no such text", replace: "x")], checkpoint: "before chip move"))
        #expect(nothing.checkpoint == nil)
        #expect(try await h.server.designCheckpoint(design.id, request: DesignCheckpointRequest(action: .list)).checkpoints.isEmpty)

        let batch = try await h.server.editDesignBoards(design.id, request: DesignBatchEditRequest(
            boards: paths.map { .init(path: $0.rawValue) }, edits: [DesignBoardEdit(find: "Pay now", replace: "Buy now", all: true)],
            checkpoint: "  before   chip move "))
        let saved = try #require(batch.checkpoint)
        #expect(saved.name == "before chip move" && saved.boards == 3, "saved before the write, with the boards as they were")
        // Restoring it puts the chips back.
        let restored = try await h.server.designCheckpoint(design.id, request: DesignCheckpointRequest(action: .restore, name: "before chip move"))
        #expect(restored.restored.sorted() == ["A.dc.html", "B.dc.html", "C.dc.html"])
        #expect(try await h.server.designBoard(design.id, path: Self.a).source.contains("Pay now 1"))
    }

    @Test func aBadBatchIsRefusedBeforeAnythingIsRead() async throws {
        let (h, design, paths) = try await chipDesign(count: 1)
        defer { h.stop() }
        let project = files(h, design), at = try await revision(h, design)
        let edit = DesignBoardEdit(find: "Pay", replace: "Buy")
        let requests: [(String, DesignBatchEditRequest, String)] = [
            ("no boards", DesignBatchEditRequest(boards: [], edits: [edit]), "invalid_edit"),
            ("no edits", DesignBatchEditRequest(boards: [.init(path: paths[0].rawValue)]), "invalid_edit"),
            ("too many boards", DesignBatchEditRequest(
                boards: (0...DesignBatchEditRequest.maxBoards).map { .init(path: "B\($0).dc.html") }, edits: [edit]), "invalid_edit"),
            ("a bad checkpoint name", DesignBatchEditRequest(boards: [.init(path: paths[0].rawValue)], edits: [edit], checkpoint: "../x"), "invalid_checkpoint"),
            ("a stale base", DesignBatchEditRequest(boards: [.init(path: paths[0].rawValue)], edits: [edit], baseRevision: 0), "stale_revision"),
        ]
        for (what, request, code) in requests {
            do {
                _ = try await h.server.editDesignBoards(design.id, request: request)
                Issue.record("\(what) was accepted")
            } catch let error as DesignStoreError {
                #expect(error.code == code, "\(what): \(error)")
            }
        }
        #expect(files(h, design) == project)
        #expect(try await revision(h, design) == at)
        await #expect(throws: SessionServerError.self) {
            try await h.server.editDesignBoards(DesignID(), request: DesignBatchEditRequest(boards: [.init(path: "A.dc.html")], edits: [edit]))
        }
    }

    // MARK: board_search and the usage index

    @Test func aSearchReadsTheDesignsBoardsInCanvasOrder() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        try await draw(h, design, [Self.a: Self.chips(), Self.b: Self.board(#"<div class="topbar" aria-label="Top bar">x</div>"#),
                                   Self.card: Self.board("<p>Card</p>")])
        let text = try await h.server.searchDesign(design.id, query: DesignSearchQuery(text: "Pay now"))
        #expect(text.boards.map(\.path) == ["A.dc.html"] && text.totalMatches == 2 && text.searched == 3)
        let bar = try await h.server.searchDesign(design.id, query: DesignSearchQuery(tag: "div", elementClass: "topbar"))
        #expect(bar.boards.map(\.path) == ["B.dc.html"] && bar.boards.first?.matches.first?.element?.hasPrefix("B.dc.html#") == true)
        let only = try await h.server.searchDesign(design.id, query: DesignSearchQuery(text: "p", paths: ["Card.dc.html"]))
        #expect(only.searched == 1)
    }

    @Test func aBadSearchIsRefusedWithItsCode() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        try await draw(h, design, [Self.a: Self.chips()])
        for (query, code) in [(DesignSearchQuery(), "invalid_search"), (DesignSearchQuery(text: "(", regex: true), "invalid_search"),
                              (DesignSearchQuery(text: "x", paths: ["../x.dc.html"]), "invalid_search"),
                              (DesignSearchQuery(text: "x", paths: ["Nope.dc.html"]), "no_such_board")] {
            do {
                _ = try await h.server.searchDesign(design.id, query: query)
                Issue.record("\(query) was accepted")
            } catch let error as DesignStoreError {
                #expect(error.code == code, "\(query): \(error)")
            }
        }
    }

    @Test func theUsageIndexFollowsTheDesignsRevisionsAndReadsOnlyWhatChanged() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let importing = Self.board(#"<dc-import name="Card"></dc-import>"#)
        try await draw(h, design, [Self.a: importing, Self.b: importing, Self.card: Self.board("<p>Card</p>")])
        let first = try await h.server.designUsage(design.id)
        #expect(first.importers[Self.card] == [Self.a, Self.b] && first.usedIn(Self.card) == 2 && first.missing.isEmpty)
        #expect(try await h.server.designUsage(design.id) == first, "the same revision answers the same index")
        #expect(h.server.designs.importsBySHA[design.id]?.count == 2, "A and B are one hash: read once")

        _ = try await h.server.editDesignBoard(design.id, path: Self.b, edits: [DesignBoardEdit(find: #"<dc-import name="Card"></dc-import>"#, replace: #"<dc-import name="Gone"></dc-import>"#)])
        let second = try await h.server.designUsage(design.id)
        #expect(second.importers[Self.card] == [Self.a] && second.missing == [Self.b: ["Gone"]])
        let live = Set(try await h.server.designSnapshot(design.id).boards.values)
        #expect(h.server.designs.importsBySHA[design.id].map { Set($0.keys) } == live,
                "the changed board is read again, and the hash it had is let go")
    }
}
