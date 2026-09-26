import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Importing a Claude Design folder (`SessionServer.importDesign`): the folder's canvas and
/// project files become a new design's, read only from the folder, by `DesignImport`'s rules; a
/// refused folder leaves nothing behind. And what an export reads back (`designExportFiles`).
@Suite("Design import", .integrationTimeLimit)
struct DesignImportIntegrationTests {
    static let designs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Designs", isDirectory: true)

    /// A Claude Design folder in a scratch directory: the fixture canvas (Shepherd's own
    /// canvas.json, with its unknown keys) and its boards under `project/`, an upload, and what
    /// an import leaves behind (a runtime, a hidden file, an export's page).
    static func canvasFolder() throws -> URL {
        let folder = try makeScratchDirectory("canvas")
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("ds/acme"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: designs.appendingPathComponent("canvas.json"), to: project.appendingPathComponent("canvas.json"))
        for name in try FileManager.default.contentsOfDirectory(atPath: designs.appendingPathComponent("boards").path) {
            try FileManager.default.copyItem(at: designs.appendingPathComponent("boards/\(name)"), to: project.appendingPathComponent(name))
        }
        try Data("{}".utf8).write(to: project.appendingPathComponent("ds/acme/tokens.json"))
        try Data("not Shepherd's".utf8).write(to: project.appendingPathComponent("support.js"))
        try Data("x".utf8).write(to: project.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: folder.appendingPathComponent("assets/f1.woff2"))
        try Data("<html></html>".utf8).write(to: folder.appendingPathComponent("Minimal.html"))
        return folder
    }

    private func server() async throws -> (ScratchServer, Space) {
        let h = try ScratchServer.fresh()
        let space = Fixture.space()
        try await h.seed(ShepherdState(spaces: [space]))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (h, space)
    }

    @Test func importingTheFixtureCanvasMakesADesignWithItsFilesAndEveryKey() async throws {
        let (h, space) = try await server()
        defer { h.stop() }
        let source = try Self.canvasFolder()
        let before = DesignTests.contents(of: source)

        let design = try await h.server.importDesign(from: source, spaceID: space.id)

        let index = try DesignIndex.decode(Data(contentsOf: Self.designs.appendingPathComponent("canvas.json")))
        #expect(design.name == index.title && design.spaceID == space.id && design.agentID == nil)
        #expect(design.boardCount == index.boards.count)
        await drainMainQueue()
        #expect(h.server.state.designs == [design])
        #expect(try h.persisted().designs.map(\.id) == [design.id])
        #expect(h.broadcasts.current == [h.server.state], "one broadcast of the new design")

        let folder = try #require(h.server.designs.folder(for: design.id))
        let copied = DesignTests.contents(of: folder)
        let boards = try FileManager.default.contentsOfDirectory(atPath: Self.designs.appendingPathComponent("boards").path)
        var expected: Set<String> = ["project/canvas.json", "project/ds/acme/tokens.json", "assets/f1.woff2", "revision"]
        for name in boards { expected.insert("project/\(name)") }
        #expect(Set(copied.keys) == expected, "the canvas, its boards, its systems and uploads; no runtime, hidden file or page")
        #expect(copied["project/canvas.json"] == before["project/canvas.json"], "canvas.json byte for byte, every key kept")
        for name in boards { #expect(copied["project/\(name)"] == before["project/\(name)"]) }
        #expect(DesignTests.contents(of: source) == before, "the folder is only read")

        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.revision == 0 && snapshot.boards.count == boards.count)
        #expect(snapshot.index.extra["attachments"] != nil && snapshot.index.extra["createdOnFiles"] != nil)
    }

    @Test func aCanvasFolderItselfImportsAndAnUntitledOneIsNamedAfterIt() async throws {
        let (h, space) = try await server()
        defer { h.stop() }
        let parent = try makeScratchDirectory("menu")
        let source = parent.appendingPathComponent("Spring menu", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"v":3,"boards":{"Minimal.dc.html":{"x":0,"y":0,"w":400,"h":300}},"order":["Minimal.dc.html"],"guides":{"kept":true}}"#.utf8)
            .write(to: source.appendingPathComponent("canvas.json"))
        try FileManager.default.copyItem(at: Self.designs.appendingPathComponent("boards/Minimal.dc.html"),
                                         to: source.appendingPathComponent("Minimal.dc.html"))

        let design = try await h.server.importDesign(from: source, spaceID: space.id)

        #expect(design.name == "Spring menu")
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.index.title == "Spring menu")
        #expect(snapshot.index.extra["guides"] == .object(["kept": .bool(true)]))
        #expect(Set(snapshot.boards.keys) == [try DesignPath.validate("Minimal.dc.html")])
    }

    enum BadFolder: String, CaseIterable, Sendable { case link, linkedProject, noCanvas, badName, unreadableCanvas, unknownSpace }

    @Test(arguments: BadFolder.allCases)
    func aFolderThatCantBecomeADesignLeavesNothingBehind(_ bad: BadFolder) async throws {
        let (h, space) = try await server()
        defer { h.stop() }
        let source = try Self.canvasFolder()
        let project = source.appendingPathComponent("project")
        var spaceID = space.id
        switch bad {
        case .link:
            let outside = try makeScratchDirectory("outside")
            try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
            try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("B.dc.html"),
                                                       withDestinationURL: outside.appendingPathComponent("secret.txt"))
        case .linkedProject:
            let real = source.appendingPathComponent("real")
            try FileManager.default.moveItem(at: project, to: real)
            try FileManager.default.createSymbolicLink(at: project, withDestinationURL: real)
        case .noCanvas:
            try FileManager.default.removeItem(at: project.appendingPathComponent("canvas.json"))
        case .badName:
            try Data("x".utf8).write(to: project.appendingPathComponent("My Board.dc.html"))
        case .unreadableCanvas:
            try Data(#"{"v":2}"#.utf8).write(to: project.appendingPathComponent("canvas.json"))
        case .unknownSpace:
            spaceID = SpaceID()
        }
        let designsFolder = h.server.designs.directory
        let before = (try? FileManager.default.contentsOfDirectory(atPath: designsFolder.path)) ?? []

        await #expect(throws: (any Error).self) { try await h.server.importDesign(from: source, spaceID: spaceID) }

        await drainMainQueue()
        #expect(h.server.state.designs.isEmpty)
        #expect(h.broadcasts.current.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: designsFolder.path)) ?? []) == before, "no folder, no staging left")
    }

    @Test func anExportReadsItsBoardsTheirImportsTheProjectsFilesAndTheirUploads() async throws {
        let (h, space) = try await server()
        defer { h.stop() }
        let source = try Self.canvasFolder()
        let project = source.appendingPathComponent("project")
        try Data(DesignTests.board(root: #"<div style="width: 390px; height: 844px"><img src="/_blob/f1"><dc-import name="Minimal"></dc-import></div>"#).utf8)
            .write(to: project.appendingPathComponent("Card.dc.html"))
        let design = try await h.server.importDesign(from: source, spaceID: space.id)
        let card = try DesignPath.validate("Card.dc.html")

        let files = try await h.server.designExportFiles(design.id, boards: [card])

        #expect(files.boards == [card])
        #expect(files.members == [card, try DesignPath.validate("Minimal.dc.html")])
        #expect(Set(files.sources.keys) == Set(files.members))
        #expect(files.assets["f1"] == DesignExportFiles.Asset(name: "f1.woff2", data: Data([0, 1, 2])))
        #expect(Set(files.support.keys) == ["ds/acme/tokens.json"])
        await #expect(throws: DesignStoreError.noSuchBoard(try DesignPath.validate("Gone.dc.html"))) {
            try await h.server.designExportFiles(design.id, boards: [try DesignPath.validate("Gone.dc.html")])
        }
    }

    /// Opt-in: imports a real canvas (`SHEPHERD_DESIGN_CANVAS`, a folder holding
    /// `project/canvas.json`) and checks every file of its project came across byte for byte.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_DESIGN_CANVAS"] != nil, "set SHEPHERD_DESIGN_CANVAS to a design folder"))
    func aRealCanvasImportsWhole() async throws {
        let (h, space) = try await server()
        defer { h.stop() }
        let real = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SHEPHERD_DESIGN_CANVAS"]), isDirectory: true)
        let source = try makeScratchDirectory("real")
        try FileManager.default.copyItem(at: real.appendingPathComponent("project"), to: source.appendingPathComponent("project"))
        let design = try await h.server.importDesign(from: source, spaceID: space.id)
        let original = DesignTests.contents(of: source.appendingPathComponent("project")).filter { !$0.key.hasPrefix(".") && $0.key != "support.js" }
        let copied = DesignTests.contents(of: h.server.designs.projectFolder(for: design.id))
        #expect(copied == original)
        let snapshot = try await h.server.designSnapshot(design.id)
        print("Imported \(design.name): \(snapshot.index.boards.count) boards listed, \(snapshot.boards.count) board files")
    }
}
