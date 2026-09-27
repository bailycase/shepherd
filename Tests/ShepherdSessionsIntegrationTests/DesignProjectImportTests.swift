import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Importing a Claude Design project from a ZIP or a folder (`prepareDesignImport`, then
/// `finishDesignImport`): checked before anything lands, staged, and moved into Designs whole
/// with its design system; a refusal or a cancel leaves nothing behind.
@Suite("Design project import", .integrationTimeLimit)
struct DesignProjectImportTests {
    static let canvas = #"""
    {"v":3,"title":"Checkout funnel","createdOnFiles":{"at":"2026-09-20T10:00:00Z","v":1},
     "pages":[{"id":"dash","name":"Dashboard"},{"id":"mobile","name":"Mobile"}],
     "boards":{"Funnel.dc.html":{"x":0,"y":0,"w":390,"h":844,"title":"Funnel — desktop","page":"dash"},
               "boards/Steps.dc.html":{"x":470,"y":0,"w":390,"h":844,"title":"Step table","page":"mobile"}},
     "order":["Funnel.dc.html","boards/Steps.dc.html"],
     "designSystems":[{"title":"Checkout DS","namespace":"checkout-ds","artifact":"a1"}]}
    """#
    static let tokens = ##"{"format":"shepherd-tokens/1","name":"Checkout DS","namespace":"checkout-ds","colors":[{"name":"--accent","value":"#4f46e5"}]}"##

    /// A Claude Design export as a ZIP: one folder holding `project/` with its canvas, two
    /// boards, its design system, a support.js and a hidden file an import leaves behind.
    static func projectZip(extra: [TestZip.Entry] = [], canvas: String = canvas, steps: String = DesignTests.board()) -> [TestZip.Entry] {
        [.folder("checkout-funnel/"), .folder("checkout-funnel/project/"),
         .file("checkout-funnel/project/canvas.json", canvas),
         .file("checkout-funnel/project/Funnel.dc.html", DesignTests.board()),
         .file("checkout-funnel/project/boards/Steps.dc.html", steps),
         .file("checkout-funnel/project/ds/checkout-ds/tokens.json", tokens),
         .file("checkout-funnel/project/ds/checkout-ds/tokens.css", ":root { --accent: #4f46e5; }\n"),
         .file("checkout-funnel/project/support.js", "not Shepherd's"),
         .file("checkout-funnel/project/.DS_Store", "x")] + extra
    }

    private func write(_ entries: [TestZip.Entry], name: String = "checkout-funnel.zip") throws -> URL {
        let url = try makeScratchDirectory("zip").appendingPathComponent(name)
        try TestZip.make(entries).write(to: url)
        return url
    }

    /// Nothing but the designs the test made: no staging, no unpacked ZIP.
    private func leftovers(_ h: ScratchServer) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: h.server.designs.directory.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    @Test func aZipBecomesADesignWithItsBoardsAndItsDesignSystem() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let zip = try write(Self.projectZip())
        let progress = Locked<[DesignImportProgress]>([])

        let preview = try await h.server.prepareDesignImport(from: zip) { step in progress.withValue { $0.append(step) } }

        #expect(preview.file == "checkout-funnel.zip" && preview.title == "Checkout funnel")
        #expect(preview.boards == 2 && preview.pages == 2 && preview.unreadable.isEmpty)
        #expect(preview.systems == [DesignImportPreview.System(namespace: "checkout-ds", title: "Checkout DS")])
        #expect(progress.current.first == .checking(file: "checkout-funnel.zip"))
        #expect(progress.current.last == .boards(done: 2, of: 2, title: "Checkout funnel", system: "Checkout DS"))
        #expect(h.server.state.designs.isEmpty, "nothing is in Designs until it finishes")

        let design = try await h.server.finishDesignImport(preview)

        #expect(design.name == "Checkout funnel" && design.systemNamespace == "checkout-ds" && design.boardCount == 2)
        #expect(design.importedFrom?.file == "checkout-funnel.zip")
        #expect(design.importedFrom?.stamp == #"{"at":"2026-09-20T10:00:00Z","v":1}"#)
        #expect(h.server.state.designs == [design])
        let folder = try #require(h.server.designs.folder(for: design.id))
        let files = Set(DesignTests.contents(of: folder).keys)
        #expect(files == ["project/canvas.json", "project/Funnel.dc.html", "project/boards/Steps.dc.html",
                          "project/ds/checkout-ds/tokens.json", "project/ds/checkout-ds/tokens.css", "revision"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("project/canvas.json")) == Data(Self.canvas.utf8), "byte for byte")
        let system = try #require(await h.server.designSystemSummaries().first { $0.info.namespace == "checkout-ds" })
        #expect(system.info.title == "Checkout DS" && system.info.cameWith == design.id)
        #expect(leftovers(h).isEmpty)
    }

    /// A folder exported by Shepherd, zipped by the Finder's own tool, imports the same way.
    @Test func aZipMadeByDittoImports() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let source = try DesignImportIntegrationTests.canvasFolder()
        let zip = try makeScratchDirectory("ditto").appendingPathComponent("Shepherd.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let design = try await h.server.importDesign(from: zip)

        let index = try DesignIndex.decode(Data(contentsOf: DesignImportIntegrationTests.designs.appendingPathComponent("canvas.json")))
        #expect(design.name == index.title)
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.boards.count == 5)
        #expect(leftovers(h).isEmpty)
    }

    enum BadProject: String, CaseIterable, Sendable {
        case notAProject, zipSlip, absolutePath, linkInZip, oversize, fileOversize, linkOutsideInABoard, notAZip
    }

    /// Every refusal names its reason and leaves nothing: no design, no staging, no unpacked files.
    @Test(arguments: BadProject.allCases)
    func aProjectThatCantBecomeADesignLeavesNothingBehind(_ bad: BadProject) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let source: URL
        switch bad {
        case .notAProject: source = try write([.file("checkout/readme.txt", "hi")])
        case .zipSlip: source = try write(Self.projectZip(extra: [.file("checkout-funnel/../../evil.dc.html", "x")]))
        case .absolutePath: source = try write(Self.projectZip(extra: [.file("/tmp/evil.dc.html", "x")]))
        case .linkInZip: source = try write(Self.projectZip(extra: [.link("checkout-funnel/project/logo.svg", to: "/Users/sam/logo.svg")]))
        case .oversize: source = try write(Self.projectZip(extra: (0..<70).map { TestZip.Entry("checkout-funnel/project/v\($0).mp4", claimedSize: 16_000_000) }))
        case .fileOversize: source = try write(Self.projectZip(extra: [TestZip.Entry("checkout-funnel/project/hero.mp4", claimedSize: 40_000_000)]))
        case .linkOutsideInABoard:
            source = try write(Self.projectZip(steps: DesignTests.board(extra: #"<img src="../../shared/logo.svg">"#)))
        case .notAZip:
            source = try makeScratchDirectory("plain").appendingPathComponent("notes.zip")
            try Data("not a zip".utf8).write(to: source)
        }

        let failure = await #expect(throws: DesignImportFailure.self) { try await h.server.prepareDesignImport(from: source) }

        switch bad {
        case .notAProject, .notAZip: #expect(failure == .notAProject)
        case .zipSlip, .absolutePath: #expect(failure?.listedLinks.first?.target == "outside the project")
        case .linkInZip: #expect(failure == .linksOutside([DesignImportLink(board: "checkout-funnel/project/logo.svg", target: "a link")]))
        case .oversize: if case .tooLarge = failure {} else { Issue.record("expected tooLarge, got \(String(describing: failure))") }
        case .fileOversize: if case .fileTooLarge = failure {} else { Issue.record("expected fileTooLarge, got \(String(describing: failure))") }
        case .linkOutsideInABoard:
            #expect(failure == .linksOutside([DesignImportLink(board: "boards/Steps.dc.html", target: "../../shared/logo.svg")]))
        }
        await drainMainQueue()
        #expect(h.server.state.designs.isEmpty)
        #expect(leftovers(h).isEmpty, "no staging and nothing unpacked is left")
        #expect(await h.server.designSystemSummaries().isEmpty)
    }

    /// A board that can't be read is the viewer's choice: finishing without it refused, Cancel
    /// import leaves nothing, and "Import the other 1" leaves that board out on purpose.
    @Test func anUnreadableBoardWaitsForTheViewersChoice() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let zip = try write(Self.projectZip(steps: "  \n"))

        let preview = try await h.server.prepareDesignImport(from: zip)
        #expect(preview.unreadable == [DesignImportUnreadable(path: "boards/Steps.dc.html", title: "Step table", reason: "is empty")])
        #expect(preview.boards == 1)
        await #expect(throws: DesignImportFailure.unreadableBoards(preview.unreadable, readable: 1)) {
            try await h.server.finishDesignImport(preview)
        }
        await h.server.cancelDesignImport(preview.id)
        #expect(leftovers(h).isEmpty && h.server.state.designs.isEmpty)

        let again = try await h.server.prepareDesignImport(from: zip)
        let design = try await h.server.finishDesignImport(again, skippingUnreadable: true)
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.index.boards.keys.map(\.rawValue) == ["Funnel.dc.html"])
        #expect(snapshot.index.order.map(\.rawValue) == ["Funnel.dc.html"])
        #expect(snapshot.index.extra["createdOnFiles"] != nil, "every other key kept")
        #expect(leftovers(h).isEmpty)
    }

    /// Importing the same project again makes a separate copy under the next free number; it
    /// never merges, and the design system it already has is used rather than added twice.
    @Test func importingTheSameProjectAgainMakesASeparateCopy() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let zip = try write(Self.projectZip())
        let first = try await h.server.importDesign(from: zip)

        let preview = try await h.server.prepareDesignImport(from: zip)
        let origin = try #require(first.importedFrom)
        #expect(preview.origin.isSameProject(as: origin))
        #expect(preview.systems.first?.existing == "checkout-ds", "the system it already has")
        let name = DesignNaming.importName(preview.title, taken: h.server.state.designs.map(\.name))
        #expect(name == "Checkout funnel 2")
        let copy = try await h.server.finishDesignImport(preview, name: name)

        #expect(copy.id != first.id && copy.name == "Checkout funnel 2")
        #expect(h.server.state.designs.map(\.name) == ["Checkout funnel", "Checkout funnel 2"])
        #expect(try await h.server.designSnapshot(copy.id).index.title == "Checkout funnel 2")
        #expect(try await h.server.designSnapshot(first.id).index.title == "Checkout funnel", "the two don't affect each other")
        #expect(await h.server.designSystemSummaries().map(\.info.namespace) == ["checkout-ds"], "one system, not two")
    }

    /// Quitting with an import waiting on a choice puts it away.
    @Test func quittingPutsAWaitingImportAway() async throws {
        let h = try ScratchServer.fresh()
        let zip = try write(Self.projectZip(steps: ""))
        _ = try await h.server.prepareDesignImport(from: zip)
        #expect(!leftovers(h).isEmpty)
        h.stop(keepFiles: true)
        #expect(leftovers(h).isEmpty)
        try? FileManager.default.removeItem(at: h.dir)
    }
}
