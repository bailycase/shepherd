import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import DesignSurfaceKit
@testable import ShepherdApp

/// Export and Attach to a thread end to end (DZExport; docs/designs.md › Export): a real server,
/// boards rendered off screen by the renderer, and the files written where a save panel would
/// point (a scratch folder here). A ZIP holds the pages, tokens.css, the uploads and the canvas
/// as a project folder that imports again; a PDF has a page per board; attached boards wait in
/// the thread's composer.
@Suite("Design export", .mainActorExclusive)
@MainActor
struct DesignExportFlowTests {
    /// A board with an upload, an imported board and a link to A: what a standalone page has to
    /// carry along.
    static let hero = """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Hero</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>:root{--accent:#4f46e5;--space-6:24px}body{margin:0}</style></helmet>
        <div style="width: 400px; height: 300px; box-sizing: border-box; padding: var(--space-6); color: var(--accent)">
        <img src="/_blob/logo" alt="logo" style="width: 40px; height: 40px">
        <dc-import name="Badge" hint-size="100px,20px"></dc-import>
        <a id="to-a" href="A.dc.html">A</a>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """

    static let badge = """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Badge</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <span style="display: block; width: 100px; height: 20px">Badge</span>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":100,"height":20}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """

    /// A PNG's first bytes: the upload's content doesn't matter, only that it travels.
    static let logo = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private struct Workspace {
        let app: AppHarness
        let vm: ShepherdViewModel
        let design: Design
        let thread: AgentFixture
        let out: URL
    }

    /// The Design tool on, a plain thread, and the checkout design (A, B, C, A · phone) plus Hero,
    /// which uses an upload and imports the unlisted Badge.
    private func workspace() async throws -> Workspace {
        let app = try AppHarness()
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        let thread = Fixture.agent("Fix the login redirect", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [thread]))
        vm.designNetwork = .none
        let out = try makeScratchDirectory("out")
        vm.designAttachDirectory = out.appendingPathComponent("drops", isDirectory: true)
        let design = Design(name: "Checkout", spaceID: space.id, createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: design.id, on: app.server, perRow: 3)
        let hero = try DesignPath.validate("Hero.dc.html")
        _ = try await app.server.writeDesignBoards(design.id, sources: [hero: Self.hero, try DesignPath.validate("Badge.dc.html"): Self.badge])
        _ = try await app.server.updateDesignIndex(design.id, patch: .object(["boards": .object([
            "Hero.dc.html": .object(["x": .number(0), "y": .number(2000), "w": .number(400), "h": .number(300), "title": .string("Hero")]),
        ])]))
        let assets = try #require(app.server.designs.folder(for: design.id)).appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Self.logo.write(to: assets.appendingPathComponent("logo.png"))
        try await eventuallyOnMain("the design to load") { vm.state.designs.count == 1 }
        return Workspace(app: app, vm: vm, design: design, thread: thread, out: out)
    }

    private func model(_ w: Workspace, ticking boards: [String], format: DesignExportFormat) async throws -> DesignExportModel {
        let screen = w.vm.designScreen(w.design.id)
        await screen.refresh()
        w.vm.openDesignExport(w.design.id)
        let model = try #require(w.vm.designExport)
        for row in model.selection.rows { model.selection.setTicked(row.path, boards.contains(row.path.rawValue)) }
        model.format = format
        return model
    }

    /// Every file under `folder`, by path.
    private func files(_ folder: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let root = folder.resolvingSymlinksInPath().path + "/"
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, let data = try? Data(contentsOf: url) else { continue }
            found[String(url.resolvingSymlinksInPath().path.dropFirst(root.count))] = data
        }
        return found
    }

    private func unzip(_ zip: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    // MARK: The sheet

    @Test func theSheetOpensTickedFromTheCanvasSelectionOrWithEveryBoard() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let screen = w.vm.designScreen(w.design.id)
        await screen.refresh()

        w.vm.openDesignExport(w.design.id)
        var model = try #require(w.vm.designExport)
        #expect(model.selection.count == 5 && model.selection.exportTitle == "Export 5 boards", "nothing selected: every board")
        #expect(model.threads.map(\.id) == [w.thread.agent.id], "a design's own agent is no thread to attach to")
        w.vm.closeDesignExport()
        #expect(w.vm.designExport == nil)

        screen.setSelection([.init(board: try DesignPath.validate("A-phone.dc.html")), .init(board: try DesignPath.validate("A.dc.html"))])
        w.vm.openDesignExport(w.design.id)
        model = try #require(w.vm.designExport)
        #expect(model.selection.boards.map(\.rawValue) == ["A.dc.html", "A-phone.dc.html"])
        #expect(model.exportTitle == "Export 2 boards" && model.format == .html)
    }

    // MARK: Formats

    @Test func aZipHoldsThePagesTokensUploadsAndTheCanvasAsAProjectFolder() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let model = try await model(w, ticking: ["A.dc.html", "Hero.dc.html"], format: .zip)
        let zip = w.out.appendingPathComponent("Checkout.zip")

        await w.vm.exportDesign(model, to: zip)

        #expect(w.vm.remoteActionError == nil)
        #expect(w.vm.designExport == nil, "the sheet goes once the export is written")
        let unzipped = w.out.appendingPathComponent("unzipped")
        try unzip(zip, into: unzipped)
        let written = files(unzipped.appendingPathComponent("Checkout"))
        #expect(Set(written.keys) == ["A.html", "Hero.html", "tokens.css", "assets/logo.png",
                                      "project/canvas.json", "project/A.dc.html", "project/Hero.dc.html", "project/Badge.dc.html"])
        let hero = String(decoding: try #require(written["Hero.html"]), as: UTF8.self)
        #expect(hero.contains(#"src="assets/logo.png""#) && hero.contains(#"href="A.html""#) && hero.contains(">Badge</span>"))
        #expect(!hero.localizedCaseInsensitiveContains("<script") && !hero.contains("data-dc-"))
        #expect(written["assets/logo.png"] == Self.logo)
        let tokens = String(decoding: try #require(written["tokens.css"]), as: UTF8.self)
        #expect(tokens.contains("--accent: #4f46e5;") && tokens.contains("--space-6: 24px;"))
        let index = try DesignIndex.decode(try #require(written["project/canvas.json"]))
        #expect(Set(index.boards.keys.map(\.rawValue)) == ["A.dc.html", "Hero.dc.html"] && index.title == "Checkout")
        #expect(written["project/Hero.dc.html"] == Data(Self.hero.utf8), "the board's source as written")

        // The folder is a Claude Design folder again.
        let space = try #require(w.vm.state.spaces.first)
        let imported = try await w.app.server.importDesign(from: unzipped.appendingPathComponent("Checkout"), spaceID: space.id)
        let snapshot = try await w.app.server.designSnapshot(imported.id)
        #expect(snapshot.index.boards.count == 2 && snapshot.boards.count == 3)
    }

    @Test func aPdfHasAPagePerTickedBoardAtItsFramesSize() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let model = try await model(w, ticking: ["A.dc.html", "B.dc.html", "A-phone.dc.html"], format: .pdf)
        let pdf = w.out.appendingPathComponent("Checkout.pdf")

        await w.vm.exportDesign(model, to: pdf)

        #expect(w.vm.remoteActionError == nil)
        let pages = try #require(DesignPDF.pages(try Data(contentsOf: pdf)))
        #expect(pages == [CGSize(width: 960, height: 600), CGSize(width: 960, height: 600), CGSize(width: 292.5, height: 633)],
                "a page per board, in canvas order, at 96 px to the inch")
    }

    @Test func pagesAndImagesAreAFilePerBoard() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let pages = try await model(w, ticking: ["A.dc.html", "Hero.dc.html"], format: .html)
        let folder = w.out.appendingPathComponent("Checkout")
        await w.vm.exportDesign(pages, to: folder)
        let written = files(folder)
        #expect(Set(written.keys) == ["A.html", "Hero.html"])
        let hero = String(decoding: try #require(written["Hero.html"]), as: UTF8.self)
        #expect(hero.contains("src=\"data:image/png;base64,\(Self.logo.base64EncodedString())\""), "a standalone page inlines its uploads")

        let image = try await model(w, ticking: ["A.dc.html"], format: .png)
        let png = w.out.appendingPathComponent("A@2x.png")
        await w.vm.exportDesign(image, to: png)
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: png)))
        #expect(rep.pixelsWide == 2560 && rep.pixelsHigh == 1600, "@2x")
        #expect(w.vm.remoteActionError == nil)
    }

    // MARK: Attach to a thread

    @Test func attachedBoardsWaitInTheThreadsComposerAsPagesAndATokensNote() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let model = try await model(w, ticking: ["Hero.dc.html"], format: .html)

        w.vm.attachDesignExport(model, to: w.thread.agent.id)

        let store = w.vm.threadStores.store(for: w.thread.agent.id)
        try await eventuallyOnMain("the boards to wait in the thread's composer") { !store.attachedFiles.isEmpty }
        #expect(store.attachedFiles.map(\.name) == ["Hero.html", "tokens.css"])
        #expect(w.vm.designExport == nil && w.vm.selectedAgentID == w.thread.agent.id, "the thread opens")
        for file in store.attachedFiles {
            #expect(file.path.hasPrefix(w.out.appendingPathComponent("drops").path), "written in the drop folder")
        }
        let page = try String(contentsOfFile: store.attachedFiles[0].path, encoding: .utf8)
        #expect(page.contains("data:image/png;base64,") && !page.localizedCaseInsensitiveContains("<script"))
        let note = try String(contentsOfFile: store.attachedFiles[1].path, encoding: .utf8)
        #expect(note.contains("--accent: #4f46e5;") && note.contains("--space-6: 24px;"), "the tokens Hero uses")
    }
}
