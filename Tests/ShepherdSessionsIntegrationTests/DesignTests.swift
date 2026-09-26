import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Every design mutation on `SessionServer`: the files in `designs/<id>/` change through
/// `DesignStore` on its own queue, the record commits and broadcasts once, and a refused change
/// leaves files, revision, state and observers as they were.
@Suite("Designs", .integrationTimeLimit)
struct DesignTests {
    // MARK: Helpers

    static func board(root: String = #"<div style="width: 390px; height: 844px">Hi</div>"#, size: (Int, Int) = (390, 844),
                      extra: String = "") -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Board</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>body{margin:0}</style></helmet>
        \(root)\(extra)
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":\(size.0),"height":\(size.1)}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    }

    static func path(_ raw: String) throws -> DesignPath { try DesignPath.validate(raw) }

    /// A server with one space holding one agent, and a design in that space.
    private func serverWithDesign(sourceLocation: SourceLocation = #_sourceLocation) async throws
        -> (h: ScratchServer, design: Design, agent: Agent) {
        let h = try ScratchServer.fresh()
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let design = Design(name: "Checkout funnel", spaceID: space.id, createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (h, try #require(h.server.state.designs.first, sourceLocation: sourceLocation), worker.agent)
    }

    /// The committed state after one mutation: on disk and broadcast exactly once.
    @discardableResult
    private func committed(_ h: ScratchServer, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ShepherdState {
        await drainMainQueue()
        let state = h.server.state
        #expect(try h.persisted() == state.persisted, "state.json matches memory", sourceLocation: sourceLocation)
        #expect(h.broadcasts.current == [state], "one broadcast of the committed state", sourceLocation: sourceLocation)
        h.broadcasts.withValue { $0.removeAll() }
        return state
    }

    /// Live state after one change: broadcast exactly once, state.json untouched.
    @discardableResult
    private func broadcastLive(_ h: ScratchServer, onDisk: Data?, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ShepherdState {
        await drainMainQueue()
        let state = h.server.state
        #expect((try? Data(contentsOf: h.stateURL)) == onDisk, "live state is not written", sourceLocation: sourceLocation)
        #expect(h.broadcasts.current == [state], "one broadcast of the live state", sourceLocation: sourceLocation)
        h.broadcasts.withValue { $0.removeAll() }
        return state
    }

    /// Everything a refused change must leave alone.
    private struct Untouched {
        let state: ShepherdState
        let stateFile: Data?
        let project: [String: Data]
        let revision: String?

        init(_ h: ScratchServer, _ id: DesignID) throws {
            state = h.server.state
            stateFile = try? Data(contentsOf: h.stateURL)
            project = DesignTests.contents(of: h.server.designs.projectFolder(for: id))
            revision = try? String(contentsOf: #require(h.server.designs.folder(for: id)).appendingPathComponent("revision"), encoding: .utf8)
        }
    }

    private func expectUntouched(_ before: Untouched, _ h: ScratchServer, _ id: DesignID,
                                 sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await drainMainQueue()
        let after = try Untouched(h, id)
        #expect(after.state == before.state, sourceLocation: sourceLocation)
        #expect(after.stateFile == before.stateFile, sourceLocation: sourceLocation)
        #expect(after.project == before.project, "the design's files", sourceLocation: sourceLocation)
        #expect(after.revision == before.revision, sourceLocation: sourceLocation)
        #expect(h.broadcasts.current.isEmpty, sourceLocation: sourceLocation)
    }

    /// Every file under `folder`, by relative path.
    static func contents(of folder: URL?) -> [String: Data] {
        guard let folder, let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [:] }
        var files: [String: Data] = [:]
        let root = folder.resolvingSymlinksInPath().path + "/"
        while let url = walker.nextObject() as? URL {
            if let data = try? Data(contentsOf: url), !url.hasDirectoryPath {
                files[String(url.resolvingSymlinksInPath().path.dropFirst(root.count))] = data
            }
        }
        return files
    }

    // MARK: Create

    @Test func creatingADesignMakesItsFolderAndItsRecord() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))
        let design = Design(name: "  Checkout funnel ", spaceID: space.id, systemNamespace: "acme-web", createdAt: 1_000)

        let snapshot = try await h.server.createDesign(design)

        #expect(snapshot.revision == 0 && snapshot.boards.isEmpty)
        #expect(snapshot.index.title == "Checkout funnel" && snapshot.index.boards.isEmpty)
        #expect(snapshot.index.extra["createdOnFiles"] == .object(["v": .number(1), "at": .string("1970-01-01T00:00:01Z")]))
        let state = try await committed(h)
        var expected = design
        expected.name = "Checkout funnel"
        expected.boardCount = 0
        #expect(state.designs == [expected])
        #expect(try h.persisted().designs.first?.boardCount == nil, "the count is never written")
        let project = try #require(h.server.designs.projectFolder(for: design.id))
        #expect(try DesignIndex.decode(Data(contentsOf: project.appendingPathComponent("canvas.json"))) == snapshot.index)
        #expect(project.path.hasPrefix(h.dir.appendingPathComponent("designs").path), "designs live in the support directory")
    }

    enum BadCreate: String, CaseIterable, Sendable { case unknownSpace, unknownAgent, sameID, noName }

    @Test(arguments: BadCreate.allCases)
    func aDesignThatCantBeMadeLeavesNothingBehind(_ bad: BadCreate) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))
        let existing = Design(name: "Existing", spaceID: space.id, createdAt: 1)
        _ = try await h.server.createDesign(existing)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let before = h.server.state
        let onDisk = try? Data(contentsOf: h.stateURL)

        var design = Design(name: "New", spaceID: space.id, createdAt: 1)
        let expected: SessionServerError
        switch bad {
        case .unknownSpace:
            design.spaceID = SpaceID()
            expected = .noSuchSpace(design.spaceID)
        case .unknownAgent:
            let agentID = AgentID()
            design.agentID = agentID
            expected = .noSuchAgent(agentID)
        case .sameID:
            design.id = existing.id
            expected = .conflict("design \(existing.id) already exists")
        case .noName:
            design.name = "  "
            expected = .conflict("a design needs a name")
        }
        let error = await #expect(throws: SessionServerError.self) { _ = try await h.server.createDesign(design) }
        #expect(error?.description == expected.description)
        await drainMainQueue()
        #expect(h.server.state == before)
        #expect((try? Data(contentsOf: h.stateURL)) == onDisk)
        #expect(h.broadcasts.current.isEmpty)
        let folders = try FileManager.default.contentsOfDirectory(atPath: h.dir.appendingPathComponent("designs").path)
        #expect(folders == [existing.id.rawValue], "only the existing design's folder")
    }

    // MARK: Boards

    @Test func writingABoardStoresItAndMovesTheDesignUpRecents() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let onDisk = try? Data(contentsOf: h.stateURL)
        let source = Self.board()
        let main = try Self.path("Main.dc.html")

        let result = try await h.server.writeDesignBoard(design.id, path: main, source: source, baseRevision: 0)

        #expect(result.changed && result.revision == 1 && result.warnings.isEmpty)
        let state = try await broadcastLive(h, onDisk: onDisk)
        let record = try #require(state.designs.first)
        #expect(record.lastActiveAt > design.lastActiveAt)
        #expect(record.boardCount == 0, "a board no index lists is not counted")
        let sha = try #require(result.sha256)
        let read = try await h.server.designBoard(design.id, path: main)
        #expect(read == DesignBoardSource(path: main, source: source, sha256: sha, revision: 1))
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.boards == [main: sha], "every board file shows, listed or not")
        #expect(snapshot.revision == 1)
    }

    /// A rewrite replaces the file in one rename: a reader holding the old file still reads the
    /// old board whole, and nothing but the board is left in the folder.
    @Test func aRewriteReplacesTheBoardAtomically() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let main = try Self.path("flows/Main.dc.html")
        let first = Self.board(root: #"<div style="width: 390px; height: 844px">First</div>"#)
        let second = Self.board(root: #"<div style="width: 390px; height: 844px">Second</div>"#)
        _ = try await h.server.writeDesignBoard(design.id, path: main, source: first)
        let url = try #require(h.server.designs.projectFolder(for: design.id)).appendingPathComponent(main.rawValue)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }

        _ = try await h.server.writeDesignBoard(design.id, path: main, source: second, baseRevision: 1)

        #expect(try reader.readToEnd() == Data(first.utf8), "the old file was replaced, not rewritten in place")
        #expect(try Data(contentsOf: url) == Data(second.utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(names == ["Main.dc.html"], "no temporary file is left")
    }

    @Test func aStaleRevisionIsRefused() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let main = try Self.path("Main.dc.html")
        _ = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board(), baseRevision: 0)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let before = try Untouched(h, design.id)

        let rewrite = Self.board(root: #"<div style="width: 390px; height: 844px">Again</div>"#)
        await #expect(throws: DesignStoreError.stale(base: 0, current: 1)) {
            try await h.server.writeDesignBoard(design.id, path: main, source: rewrite, baseRevision: 0)
        }
        await #expect(throws: DesignStoreError.stale(base: 0, current: 1)) {
            try await h.server.updateDesignIndex(design.id, patch: .object(["title": .string("Other")]), baseRevision: 0)
        }
        try await expectUntouched(before, h, design.id)
    }

    struct BadBoard: Sendable, CustomTestStringConvertible {
        let name: String
        let source: String
        let error: DesignStoreError
        var testDescription: String { name }
    }

    @Test(arguments: [
        BadBoard(name: "an iframe", source: board(extra: "<iframe src=\"x\"></iframe>"), error: .refused(.forbiddenTag("iframe"))),
        BadBoard(name: "a data: URI", source: board(extra: "<img src=\"data:image/png;base64,AA\">"), error: .refused(.dataURI)),
        BadBoard(name: "no support.js", source: board().replacingOccurrences(of: "./support.js", with: "support.js"),
                 error: .refused(.missingSupportScript)),
        BadBoard(name: "a root unlike $preview", source: board(size: (1280, 800)),
                 error: .refused(.sizeMismatch(root: .init(width: 390, height: 844), preview: .init(width: 1280, height: 800)))),
    ])
    func aBadBoardIsRefused(_ bad: BadBoard) async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let before = try Untouched(h, design.id)
        await #expect(throws: bad.error) {
            try await h.server.writeDesignBoard(design.id, path: try Self.path("Main.dc.html"), source: bad.source)
        }
        try await expectUntouched(before, h, design.id)
    }

    @Test func aBoardWhoseNameDiffersOnlyInCaseIsRefused() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        _ = try await h.server.writeDesignBoard(design.id, path: try Self.path("Cart.dc.html"), source: Self.board())
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let before = try Untouched(h, design.id)
        await #expect(throws: DesignStoreError.nameTaken(try Self.path("flows/cart.dc.html"), by: try Self.path("Cart.dc.html"))) {
            try await h.server.writeDesignBoard(design.id, path: try Self.path("flows/cart.dc.html"), source: Self.board())
        }
        try await expectUntouched(before, h, design.id)
    }

    @Test func aBoardIsNeverWrittenThroughALinkedFolder() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let outside = try makeScratchDirectory("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let project = try #require(h.server.designs.projectFolder(for: design.id))
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("linked"), withDestinationURL: outside)
        let path = try Self.path("linked/Board.dc.html")

        await #expect(throws: DesignStoreError.invalidPath(path.rawValue, .parentReference)) {
            try await h.server.writeDesignBoard(design.id, path: path, source: Self.board())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func writingWhatTheBoardAlreadyHoldsChangesNothing() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let main = try Self.path("Main.dc.html")
        _ = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board())
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let before = try Untouched(h, design.id)

        let again = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board(), baseRevision: 1)

        #expect(!again.changed && again.revision == 1)
        try await expectUntouched(before, h, design.id)
    }

    @Test func aDesignNoRecordNamesCantBeWrittenOrRead() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let id = DesignID()
        await #expect(throws: SessionServerError.self) {
            try await h.server.writeDesignBoard(id, path: try Self.path("Main.dc.html"), source: Self.board())
        }
        await #expect(throws: SessionServerError.self) { try await h.server.designSnapshot(id) }
        #expect(!FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("designs").path))
    }

    @Test func readingABoardThatIsntThereIsRefused() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let missing = try Self.path("Missing.dc.html")
        await #expect(throws: DesignStoreError.noSuchBoard(missing)) { try await h.server.designBoard(design.id, path: missing) }
    }

    // MARK: Index

    @Test func anIndexUpdateListsBoardsAndCountsThem() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let a = try Self.path("A.dc.html"), b = try Self.path("A-phone.dc.html")
        _ = try await h.server.writeDesignBoard(design.id, path: a, source: Self.board())
        _ = try await h.server.writeDesignBoard(design.id, path: b, source: Self.board())
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let onDisk = try? Data(contentsOf: h.stateURL)

        let patch = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"boards":{"A.dc.html":{"x":0,"y":0,"w":390,"h":844,"title":"A · Funnel first"},
                   "A-phone.dc.html":{"x":470,"y":0,"w":390,"h":844,"title":"A · phone"}},
         "notes":{"t1":{"x":0,"y":-300,"text":"Checkout","kind":"title1","maxW":860}}}
        """#.utf8))
        let result = try await h.server.updateDesignIndex(design.id, patch: patch, baseRevision: 2)

        #expect(result.changed && result.revision == 3 && result.boardCount == 2)
        let state = try await broadcastLive(h, onDisk: onDisk)
        #expect(state.designs.first?.boardCount == 2)
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.index.order == [b, a], "added boards join order by path")
        #expect(snapshot.index.boards[a]?.title == "A · Funnel first")
        #expect(snapshot.index.extra["createdOnFiles"] != nil, "keys the update doesn't name stay")
    }

    @Test func anIndexEntryNeedsItsBoardFile() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let before = try Untouched(h, design.id)
        let patch = JSONValue.object(["boards": .object(["Ghost.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(400), "h": .number(400)])])])
        await #expect(throws: DesignStoreError.missingBoardFile(try Self.path("Ghost.dc.html"))) {
            try await h.server.updateDesignIndex(design.id, patch: patch)
        }
        await #expect(throws: DesignStoreError.invalidIndex(["order lists each board once"])) {
            try await h.server.updateDesignIndex(design.id, patch: .object(["order": .array([.string("Ghost.dc.html")])]))
        }
        try await expectUntouched(before, h, design.id)
    }

    @Test func removingABoardFromTheIndexRemovesItsFile() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        let a = try Self.path("A.dc.html")
        _ = try await h.server.writeDesignBoard(design.id, path: a, source: Self.board())
        _ = try await h.server.updateDesignIndex(design.id, patch: .object(["boards": .object([
            "A.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844)])])]))

        let result = try await h.server.updateDesignIndex(design.id, patch: .object(["boards": .object(["A.dc.html": .null])]))

        #expect(result.boardCount == 0)
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.boards.isEmpty && snapshot.index.order.isEmpty)
        let url = try #require(h.server.designs.projectFolder(for: design.id)).appendingPathComponent(a.rawValue)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aNewTitleRenamesTheDesign() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        _ = try await h.server.updateDesignIndex(design.id, patch: .object(["title": .string("Checkout v2")]))
        let state = try await committed(h)
        #expect(state.designs.first?.name == "Checkout v2")
    }

    // MARK: Record

    @Test func renamingADesignRenamesItsCanvas() async throws {
        let (h, design, _) = try await serverWithDesign()
        defer { h.stop() }
        try await h.server.renameDesign(design.id, to: " Onboarding ")
        let state = try await committed(h)
        #expect(state.designs.first?.name == "Onboarding")
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.index.title == "Onboarding" && snapshot.revision == 1)
        await #expect(throws: SessionServerError.self) { try await h.server.renameDesign(DesignID(), to: "x") }
    }

    @Test func settingADesignsAgentRecordsIt() async throws {
        let (h, design, agent) = try await serverWithDesign()
        defer { h.stop() }
        try await h.server.setDesignAgent(design.id, agentID: agent.id)
        #expect(try await committed(h).designs.first?.agentID == agent.id)
        try await h.server.setDesignAgent(design.id, agentID: agent.id)
        await drainMainQueue()
        #expect(h.broadcasts.current.isEmpty, "the same agent again changes nothing")
        let before = h.server.state
        await #expect(throws: SessionServerError.self) { try await h.server.setDesignAgent(design.id, agentID: AgentID()) }
        #expect(h.server.state == before)
        try await h.server.setDesignAgent(design.id, agentID: nil)
        #expect(try await committed(h).designs.first?.agentID == nil)
    }

    @Test func deletingADesignRemovesItsFolderAndFreesItsAgent() async throws {
        let (h, design, agent) = try await serverWithDesign()
        defer { h.stop() }
        var drawing = agent
        drawing.designID = design.id
        try await h.server.updateAgent(drawing)
        try await h.server.setDesignAgent(design.id, agentID: agent.id)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }

        try await h.server.deleteDesign(design.id)

        let state = try await committed(h)
        #expect(state.designs.isEmpty)
        #expect(state.agents.first?.designID == nil, "the agent stays, drawing nothing")
        #expect(!FileManager.default.fileExists(atPath: try #require(h.server.designs.folder(for: design.id)).path))
        let again = await #expect(throws: SessionServerError.self) { try await h.server.deleteDesign(design.id) }
        #expect(again?.description == SessionServerError.noSuchDesign(design.id).description)
    }

    @Test func deletingADesignsAgentKeepsTheDesign() async throws {
        let (h, design, agent) = try await serverWithDesign()
        defer { h.stop() }
        try await h.server.setDesignAgent(design.id, agentID: agent.id)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }

        try await h.server.deleteAgent(agent.id)

        let state = try await committed(h)
        #expect(state.designs.map(\.id) == [design.id])
        #expect(state.designs.first?.agentID == nil, "opening it starts a fresh agent")
    }

    @Test func deletingADesignsSpaceKeepsTheDesign() async throws {
        let (h, design, agent) = try await serverWithDesign()
        defer { h.stop() }
        try await h.server.setDesignAgent(design.id, agentID: agent.id)
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }

        try await h.server.deleteSpace(design.spaceID)

        let state = try await committed(h)
        #expect(state.agents.isEmpty && state.spaces.isEmpty)
        #expect(state.designs.map(\.id) == [design.id] && state.designs.first?.agentID == nil)
        #expect(try await h.server.designSnapshot(design.id).index.title == "Checkout funnel", "its files stay")
    }

    // MARK: Relaunch

    @Test func aRelaunchKeepsTheRevisionAndCountsBoards() async throws {
        let (first, design, _) = try await serverWithDesign()
        let a = try Self.path("A.dc.html")
        _ = try await first.server.writeDesignBoard(design.id, path: a, source: Self.board())
        _ = try await first.server.updateDesignIndex(design.id, patch: .object(["boards": .object([
            "A.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844)])])]))
        first.stop(keepFiles: true)

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        try await eventually("the board count to be read") { h.server.state.designs.first?.boardCount == 1 }
        #expect(try h.persisted().designs.first?.boardCount == nil)
        #expect(try await h.server.designSnapshot(design.id).revision == 2)
        await #expect(throws: DesignStoreError.stale(base: 0, current: 2)) {
            try await h.server.writeDesignBoard(design.id, path: a, source: Self.board(root: #"<div style="width: 390px; height: 844px">x</div>"#), baseRevision: 0)
        }
    }

    /// Startup forgets a design whose folder is gone and clears references to what no longer
    /// exists: an agent's design, a design's agent.
    @Test func startupClearsDanglingDesigns() async throws {
        let first = try ScratchServer.fresh()
        let space = Fixture.space()
        var worker = Fixture.agent(in: space)
        let kept = Design(name: "Kept", spaceID: space.id, createdAt: 1)
        let lost = Design(name: "Lost", spaceID: space.id, createdAt: 1)
        try await first.server.putState(Fixture.workspace([worker], space: space))
        _ = try await first.server.createDesign(kept)
        _ = try await first.server.createDesign(lost)
        worker.agent.designID = lost.id
        try await first.server.updateAgent(worker.agent)
        // A design whose agent is gone (state.json edited, or the agent removed while stopped).
        var orphan = try #require(first.server.state.designs.first { $0.id == kept.id })
        orphan.agentID = AgentID()
        var state = first.server.state
        state.designs[0] = orphan
        try await first.server.putState(state)
        try FileManager.default.removeItem(at: try #require(first.server.designs.folder(for: lost.id)))
        first.stop(keepFiles: true)

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        let restored = h.server.state
        #expect(restored.designs.map(\.id) == [kept.id])
        #expect(restored.designs.first?.agentID == nil)
        #expect(restored.agents.first?.designID == nil)
        #expect(try h.persisted().designs.map(\.id) == [kept.id], "the cleared state is written")
    }
}
