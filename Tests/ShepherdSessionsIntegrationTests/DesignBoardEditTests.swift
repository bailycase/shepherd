import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// `board_edit` (docs/designs.md › The design agent): edits applied to the board's text as the
/// store holds it now, on the store's queue, then written as any board write is.
@Suite("Design board edits on the host", .integrationTimeLimit)
struct DesignBoardEditStoreTests {
    static let a = try! DesignPath.validate("A.dc.html")
    static let b = try! DesignPath.validate("B.dc.html")

    /// A board with `lines` paragraphs `<p>line-N</p>`, one per line.
    static func board(lines: Int = 3, head: String = DesignBoardCheck.supportScript) -> String {
        let paragraphs = (1...lines).map { "<p>line-\($0)</p>" }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Board</title>\(head)</head>
        <body>
        <x-dc>
        <helmet><style>body{margin:0}</style></helmet>
        <div style="width: 390px; height: 844px">
        \(paragraphs)
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":390,"height":844}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    private func serverWithDesign() async throws -> (h: ScratchServer, design: Design) {
        let h = try ScratchServer.fresh()
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([Fixture.agent(in: space)], space: space))
        let design = Design(name: "Checkout funnel", createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (h, design)
    }

    private func files(_ h: ScratchServer, _ design: Design) -> [String: Data] {
        DesignTests.contents(of: h.server.designs.projectFolder(for: design.id))
    }

    @Test func anEditChangesOnlyWhatItNamesKeepsTheOldVersionAndBroadcastsOnce() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let before = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board())
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let pushes = Locked(0)
        h.server.onDesignRevision = { _ in pushes.withValue { $0 += 1 } }
        h.server.watchDesignRevisions(of: [design.id])

        let edited = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [
            DesignBoardEdit(find: "<p>line-2</p>", replace: "<p>second</p>"),
            DesignBoardEdit(find: "<p>line-", replace: "<p>row-", all: true),
        ], baseRevision: before.revision)

        #expect(edited.result.changed && edited.result.created == false && edited.result.revision == before.revision + 1)
        #expect(edited.replaced == [1, 2])
        let source = try await h.server.designBoard(design.id, path: Self.a).source
        #expect(source == Self.board().replacingOccurrences(of: "<p>line-2</p>", with: "<p>second</p>")
            .replacingOccurrences(of: "<p>line-", with: "<p>row-"))
        #expect(edited.result.sha256 == DesignStore.sha256(Data(source.utf8)))
        #expect(try await h.server.designVersions(design.id, path: Self.a).map(\.sha256) == [DesignStore.sha256(Data(Self.board().utf8))],
                "what the edit replaced is the board's next version")

        await drainMainQueue()
        #expect(h.broadcasts.current.count == 1, "one broadcast")
        try await eventually("the edit's live reload") { pushes.current == 1 }
        await drainMainQueue()
        #expect(pushes.current == 1, "one push, for one write")
        #expect(h.server.state.designs.first?.lastActiveAt ?? 0 > 1_000, "an edit moves the design up Recents")
    }

    @Test func anEditThatChangesNothingKeepsTheRevisionAndPushesNothing() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let written = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board())
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let edited = try await h.server.editDesignBoard(design.id, path: Self.a,
                                                        edits: [DesignBoardEdit(find: "<p>line-1</p>", replace: "<p>line-1</p>")])
        #expect(!edited.result.changed && edited.result.revision == written.revision && edited.replaced == [1])
        #expect(try await h.server.designVersions(design.id, path: Self.a).isEmpty)
        await drainMainQueue()
        #expect(h.broadcasts.current.isEmpty)
    }

    @Test(arguments: [
        ("a find that matches nothing", [DesignBoardEdit(find: "<p>line-1</p>", replace: "x"), DesignBoardEdit(find: "<p>zzz</p>", replace: "y")], "edit_not_found"),
        ("a find that matches several times", [DesignBoardEdit(find: "<p>line-1</p>", replace: "x"), DesignBoardEdit(find: "<p>line-", replace: "y")], "edit_ambiguous"),
        ("an empty find", [DesignBoardEdit(find: "", replace: "y")], "invalid_edit"),
        ("no edits", [], "invalid_edit"),
    ] as [(String, [DesignBoardEdit], String)])
    func aFailedEditChangesNothing(_ why: String, _ edits: [DesignBoardEdit], _ code: String) async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board())
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board(lines: 4))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let project = files(h, design), snapshot = try await h.server.designSnapshot(design.id)
        let versions = try await h.server.designVersions(design.id, path: Self.a)

        do {
            _ = try await h.server.editDesignBoard(design.id, path: Self.a, edits: edits)
            Issue.record("\(why) was applied")
        } catch let error as DesignStoreError {
            #expect(error.code == code, "\(why): \(error)")
            #expect(error.description.contains("nothing was changed"), "\(why): \(error)")
        }
        await drainMainQueue()
        #expect(files(h, design) == project, "\(why): the files")
        #expect(try await h.server.designSnapshot(design.id) == snapshot, "\(why): the revision")
        #expect(try await h.server.designVersions(design.id, path: Self.a) == versions, "\(why): the versions")
        #expect(h.broadcasts.current.isEmpty, "\(why): no broadcast")
    }

    @Test func anEditOfAMissingBoardOrAStaleRevisionIsRefused() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let written = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board())
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board(lines: 4))
        let project = files(h, design)
        await #expect(throws: DesignStoreError.noSuchBoard(Self.b)) {
            try await h.server.editDesignBoard(design.id, path: Self.b, edits: [DesignBoardEdit(find: "a", replace: "b")])
        }
        let now = try await h.server.designSnapshot(design.id)
        await #expect(throws: DesignStoreError.stale(base: written.revision, current: now.revision)) {
            try await h.server.editDesignBoard(design.id, path: Self.a, edits: [DesignBoardEdit(find: "<p>line-1</p>", replace: "x")],
                                               baseRevision: written.revision)
        }
        await #expect(throws: SessionServerError.self) {
            try await h.server.editDesignBoard(DesignID(), path: Self.a, edits: [DesignBoardEdit(find: "a", replace: "b")])
        }
        #expect(files(h, design) == project)
    }

    /// The edit's result passes through the checks a whole-board write does, and is refused whole.
    @Test(arguments: [
        ("takes the support script out", DesignBoardEdit(find: DesignBoardCheck.supportScript, replace: ""), "missing_support_script"),
        ("adds an iframe", DesignBoardEdit(find: "<p>line-1</p>", replace: "<iframe src=\"https://example.com\"></iframe>"), "forbidden_tag"),
        ("adds a data URI", DesignBoardEdit(find: "<p>line-1</p>", replace: "<img src=\"data:image/png;base64,AAAA\">"), "data_uri"),
        ("resizes the root only", DesignBoardEdit(find: "width: 390px; height: 844px", replace: "width: 400px; height: 844px"), "size_mismatch"),
    ] as [(String, DesignBoardEdit, String)])
    func aResultTheBoardChecksRefuseIsRefusedWhole(_ what: String, _ edit: DesignBoardEdit, _ code: String) async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board())
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let project = files(h, design), snapshot = try await h.server.designSnapshot(design.id)
        do {
            _ = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [DesignBoardEdit(find: "<p>line-3</p>", replace: "<p>3</p>"), edit])
            Issue.record("an edit that \(what) was written")
        } catch let error as DesignStoreError {
            #expect(error.code == code, "\(what): \(error)")
            #expect(error.description.contains("the edited A.dc.html can't be written"), "\(what): \(error)")
        }
        await drainMainQueue()
        #expect(files(h, design) == project && h.broadcasts.current.isEmpty, "\(what): nothing changed")
        #expect(try await h.server.designSnapshot(design.id) == snapshot)
    }

    @Test func anEditWarnsAsABoardWriteDoes() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board())
        let edited = try await h.server.editDesignBoard(design.id, path: Self.a, edits: [
            DesignBoardEdit(find: "renderVals() { return {}; }", replace: "renderVals() { document.body.innerHTML = 'x'; return {}; }"),
        ])
        #expect(edited.result.warnings == [.innerHTML])
    }

    /// Two edits to one board in flight together each apply to what the other left: they
    /// serialize on the store's queue, read, edit and write in one step, and neither is lost.
    @Test func concurrentEditsToOneBoardSerializeAndNeitherIsLost() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let count = 24
        let written = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board(lines: count))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 1...count {
                group.addTask {
                    _ = try await h.server.editDesignBoard(design.id, path: Self.a,
                                                           edits: [DesignBoardEdit(find: "<p>line-\(n)</p>", replace: "<p>done-\(n)</p>")])
                }
            }
            try await group.waitForAll()
        }

        let source = try await h.server.designBoard(design.id, path: Self.a).source
        for n in 1...count {
            #expect(source.contains("<p>done-\(n)</p>") && !source.contains("<p>line-\(n)</p>"), "edit \(n) was lost")
        }
        #expect(try await h.server.designSnapshot(design.id).revision == written.revision + UInt64(count), "one revision each")
        #expect(try await h.server.designVersions(design.id, path: Self.a).count == DesignBoardVersion.kept, "the newest \(DesignBoardVersion.kept) kept")
        await drainMainQueue()
        #expect(h.broadcasts.current.count == count, "one broadcast per edit")
    }

    /// An edit and a whole-board write to another board race without harm.
    @Test func editsToOneBoardAndWritesToAnotherDoNotDisturbEachOther() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        _ = try await h.server.writeDesignBoard(design.id, path: Self.a, source: Self.board(lines: 8))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 1...8 {
                group.addTask {
                    _ = try await h.server.editDesignBoard(design.id, path: Self.a,
                                                           edits: [DesignBoardEdit(find: "<p>line-\(n)</p>", replace: "<p>done-\(n)</p>")])
                }
                group.addTask {
                    _ = try await h.server.writeDesignBoard(design.id, path: Self.b, source: Self.board(lines: n))
                }
            }
            try await group.waitForAll()
        }
        let source = try await h.server.designBoard(design.id, path: Self.a).source
        #expect((1...8).allSatisfy { source.contains("<p>done-\($0)</p>") })
        let other = try await h.server.designBoard(design.id, path: Self.b).source
        #expect(other.contains("<p>line-1</p>"), "B is one of the boards written")
    }
}

/// The same tool over the extension socket, as the design extension sends it.
@Suite("Design board edits over the socket", .integrationTimeLimit)
struct DesignBoardEditSocketTests {
    private func workspace(_ h: ScratchServer) async throws -> (design: DesignID, drawer: AgentID, stranger: AgentID) {
        let space = Fixture.space()
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Checkout funnel")
        drawer.agent.designID = designID
        let stranger = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([drawer, stranger], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Checkout funnel", agentID: drawer.agent.id, createdAt: 1_000))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (designID, drawer.agent.id, stranger.agent.id)
    }

    @Test func anAgentEditsItsBoardAndGetsHowManyMatchesEachEditReplaced() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, _) = try await workspace(h)
        let agent = try ExtensionClient(path: h.socketPath)
        try agent.send(.designWriteBoard(id: 1, agentID: drawer, designID: design, path: "A.dc.html",
                                         source: DesignBoardEditStoreTests.board(), baseRevision: nil))
        guard case .designWritten(1, let written) = try await agent.reply() else { Issue.record("no write"); return }

        try agent.send(.designEditBoard(id: 2, agentID: drawer, designID: design, path: "A.dc.html", edits: [
            DesignBoardEdit(find: "<p>line-2</p>", replace: "<p>second</p>"),
            DesignBoardEdit(find: "<p>", replace: "<p class=\"t\">", all: true),
        ], baseRevision: written.revision))
        guard case .designEdited(2, let result, let replaced) = try await agent.reply() else { Issue.record("no edit result"); return }
        #expect(result.changed && result.revision == written.revision + 1 && result.created == false)
        #expect(replaced == [1, 3])

        try agent.send(.designRead(id: 3, agentID: drawer, designID: design, path: "A.dc.html"))
        guard case .designBoard(3, let read) = try await agent.reply() else { Issue.record("no board"); return }
        #expect(read.source.contains("<p class=\"t\">second</p>") && read.source.contains("<p class=\"t\">line-1</p>"))
        #expect(read.sha256 == result.sha256 && read.revision == result.revision)
    }

    @Test func badEditsAreAnsweredWithTheirCodeAndTheConnectionKeepsServing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (design, drawer, stranger) = try await workspace(h)
        let agent = try ExtensionClient(path: h.socketPath)
        let board = DesignBoardEditStoreTests.board()
        try agent.send(.designWriteBoard(id: 1, agentID: drawer, designID: design, path: "A.dc.html", source: board, baseRevision: nil))
        guard case .designWritten(1, _) = try await agent.reply() else { Issue.record("no write"); return }
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let files = DesignTests.contents(of: h.server.designs.projectFolder(for: design))

        let cases: [(Int, ExtensionMessage, String)] = [
            (10, .designEditBoard(id: 10, agentID: drawer, designID: design, path: "A.dc.html",
                                  edits: [DesignBoardEdit(find: "<p>nope</p>", replace: "x")], baseRevision: nil), "edit_not_found"),
            (11, .designEditBoard(id: 11, agentID: drawer, designID: design, path: "A.dc.html",
                                  edits: [DesignBoardEdit(find: "<p>", replace: "x")], baseRevision: nil), "edit_ambiguous"),
            (12, .designEditBoard(id: 12, agentID: drawer, designID: design, path: "A.dc.html",
                                  edits: [DesignBoardEdit(find: "", replace: "x")], baseRevision: nil), "invalid_edit"),
            (13, .designEditBoard(id: 13, agentID: drawer, designID: design, path: "../escape.dc.html",
                                  edits: [DesignBoardEdit(find: "a", replace: "b")], baseRevision: nil), "invalid_path"),
            (14, .designEditBoard(id: 14, agentID: drawer, designID: design, path: "Missing.dc.html",
                                  edits: [DesignBoardEdit(find: "a", replace: "b")], baseRevision: nil), "no_such_board"),
            (15, .designEditBoard(id: 15, agentID: drawer, designID: design, path: "A.dc.html",
                                  edits: [DesignBoardEdit(find: "<p>line-1</p>", replace: "x")], baseRevision: 0), "stale_revision"),
            (16, .designEditBoard(id: 16, agentID: stranger, designID: design, path: "A.dc.html",
                                  edits: [DesignBoardEdit(find: "<p>line-1</p>", replace: "x")], baseRevision: nil), "not_your_design"),
            (17, .designEditBoard(id: 17, agentID: drawer, designID: DesignID(), path: "A.dc.html",
                                  edits: [DesignBoardEdit(find: "<p>line-1</p>", replace: "x")], baseRevision: nil), "not_your_design"),
            (18, .designEditBoard(id: 18, agentID: drawer, designID: design, path: "A.dc.html",
                                  edits: [DesignBoardEdit(find: DesignBoardCheck.supportScript, replace: "")], baseRevision: nil), "missing_support_script"),
        ]
        for (id, message, code) in cases {
            try agent.send(message)
            guard case .error(let answered, let got, let text) = try await agent.reply(), answered == id, got == code else {
                Issue.record("edit \(id) was not answered \(code)"); continue
            }
            if code.hasPrefix("edit_") { #expect(text.contains("edit 1 of 1"), "names the edit: \(text)") }
        }
        try agent.send(.designRead(id: 30, agentID: drawer, designID: design, path: nil))
        guard case .design(30, _) = try await agent.reply() else { Issue.record("the connection stopped serving"); return }
        await drainMainQueue()
        #expect(DesignTests.contents(of: h.server.designs.projectFolder(for: design)) == files, "nothing was written")
        #expect(h.broadcasts.current.isEmpty)
    }
}
