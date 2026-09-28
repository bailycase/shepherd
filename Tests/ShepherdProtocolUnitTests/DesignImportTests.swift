import Foundation
import Testing
import ShepherdProtocol

/// Importing a Claude Design folder: which files a new design takes, the path rules they pass,
/// and the canvas it keeps.
@Suite("Design import")
struct DesignImportTests {
    typealias Entry = DesignImport.Entry

    @Test func aProjectFolderIsTakenWhole() throws {
        let plan = try DesignImport.plan([
            Entry("canvas.json", size: 10), Entry("A.dc.html", size: 20), Entry("flows", .directory),
            Entry("flows/Cart.dc.html", size: 30), Entry("ds", .directory), Entry("ds/acme/tokens.json", size: 5),
            Entry(".DS_Store", size: 1), Entry("support.js", size: 99), Entry("flows/support.js", size: 99),
        ])
        #expect(plan.index == "canvas.json")
        #expect(plan.files == [
            "canvas.json": "project/canvas.json", "A.dc.html": "project/A.dc.html",
            "flows/Cart.dc.html": "project/flows/Cart.dc.html", "ds/acme/tokens.json": "project/ds/acme/tokens.json",
        ])
        #expect(plan.totalBytes == 65)
    }

    @Test func aFolderHoldingAProjectTakesItAndItsUploadsAndLeavesTheRest() throws {
        let plan = try DesignImport.plan([
            Entry("project", .directory), Entry("project/canvas.json", size: 1), Entry("project/A.dc.html", size: 1),
            Entry("assets", .directory), Entry("assets/f1.woff2", size: 1), Entry("assets/.hidden", size: 1),
            Entry("A.html", size: 1), Entry("tokens.css", size: 1), Entry("elsewhere", .symlink),
        ])
        #expect(plan.index == "project/canvas.json")
        #expect(plan.files == ["project/canvas.json": "project/canvas.json", "project/A.dc.html": "project/A.dc.html",
                               "assets/f1.woff2": "assets/f1.woff2"])
    }

    static let deep = Array(repeating: "d", count: 17).joined(separator: "/") + "/A.dc.html"
    static let refusals: [(entries: [Entry], problem: DesignImport.Problem)] = [
        ([Entry("A.dc.html")], DesignImport.Problem.noCanvas),
        ([Entry("canvas.json", .symlink)], .link("canvas.json")),
        ([Entry("project", .symlink)], .link("project")),
        ([Entry("canvas.json"), Entry("A.dc.html", .symlink)], .link("A.dc.html")),
        ([Entry("canvas.json"), Entry("flows", .symlink)], .link("flows")),
        ([Entry("project/canvas.json"), Entry("assets/x.png", .symlink)], .link("assets/x.png")),
        ([Entry("project/canvas.json"), Entry("assets", .symlink)], .link("assets")),
        ([Entry("canvas.json"), Entry("pipe", .other)], .notAFile("pipe")),
        ([Entry("canvas.json"), Entry("My Board.dc.html")], .badName("My Board.dc.html")),
        ([Entry("canvas.json"), Entry("a/../b.dc.html")], .badName("a/../b.dc.html")),
        ([Entry("canvas.json"), Entry("-x/b.dc.html")], .badName("-x/b.dc.html")),
        ([Entry("project/canvas.json"), Entry("assets/deep/x.png")], .badName("assets/deep/x.png")),
        ([Entry("project/canvas.json"), Entry("assets/a b.png")], .badName("assets/a b.png")),
        ([Entry("canvas.json"), Entry("A.dc.html", size: DesignImport.maxFileBytes + 1)], .tooLarge("A.dc.html")),
        ([Entry("canvas.json"), Entry(deep)], .tooDeep(deep)),
    ]

    @Test(arguments: refusals)
    func aFolderBreakingThePathRulesIsRefused(_ entries: [Entry], _ problem: DesignImport.Problem) {
        #expect(throws: problem) { try DesignImport.plan(entries) }
    }

    @Test func sizeAndCountAreCapped() {
        let many = [Entry("canvas.json")] + (0..<DesignImport.maxFiles).map { Entry("B\($0).dc.html") }
        #expect(throws: DesignImport.Problem.tooManyFiles) { try DesignImport.plan(many) }
        // A project up to 1 GB (ImportFailed), past it refused.
        let fits = [Entry("canvas.json")] + (0..<59).map { Entry("B\($0).dc.html", size: DesignImport.maxFileBytes) }
        #expect(throws: Never.self) { try DesignImport.plan(fits) }
        let big = [Entry("canvas.json")] + (0..<60).map { Entry("B\($0).dc.html", size: DesignImport.maxFileBytes) }
        #expect(throws: DesignImport.Problem.tooMuch) { try DesignImport.plan(big) }
    }

    @Test func importKeepsUnknownKeys() throws {
        let titled = Data(#"{"v":3,"title":"Menu","boards":{"A.dc.html":{"x":0,"y":0,"w":400,"h":300,"frameless":true}},"order":["A.dc.html"],"attachments":{"a":[1]},"createdOnFiles":{"v":1}}"#.utf8)
        let kept = try DesignImport.index(titled, fallbackTitle: "project")
        #expect(kept.data == titled)
        #expect(kept.index.title == "Menu")

        let untitled = Data(#"{"v":3,"boards":{"A.dc.html":{"x":0,"y":0,"w":400,"h":300,"frameless":true}},"order":["A.dc.html"],"attachments":{"a":[1]},"notes":{"n":{"kind":"pen","points":[1,2]}}}"#.utf8)
        let named = try DesignImport.index(untitled, fallbackTitle: "Spring menu")
        #expect(named.index.title == "Spring menu")
        let json = try #require(try JSONSerialization.jsonObject(with: named.data) as? [String: Any])
        #expect(json["title"] as? String == "Spring menu")
        #expect((json["attachments"] as? [String: Any])?["a"] as? [Int] == [1])
        #expect(((json["boards"] as? [String: Any])?["A.dc.html"] as? [String: Any])?["frameless"] as? Bool == true)
        #expect(((json["notes"] as? [String: Any])?["n"] as? [String: Any])?["points"] as? [Int] == [1, 2])
    }

    @Test(arguments: [8001, 10000])
    func tallLegacyFlowDocumentsKeepTheirGeometryAndUnknownKeys(height: Int) throws {
        let data = Data("""
            {"v":3,"title":"Tall","boards":{"Report.dc.html":{"x":0,"y":0,"w":816,"h":\(height),"print":"flow","custom":{"kept":true}}},"order":["Report.dc.html"]}
            """.utf8)
        let decoded = try DesignIndex.decode(data)
        let imported = try DesignImport.index(data, fallbackTitle: "unused")
        let path = DesignPath("Report.dc.html")!
        #expect(decoded.boards[path]?.h == Double(height))
        #expect(imported.data == data)
        #expect(imported.index.boards[path]?.extra["custom"] == .object(["kept": .bool(true)]))
        #expect(try decoded.merging(.object(["title": .string("Renamed")])).boards[path]?.h == Double(height))
    }

    @Test func unsafeGeometryIsRefusedWithoutTerminatingTheHost() async {
        await #expect(processExitsWith: .success) {
            for geometry in ["\"x\":0,\"y\":0,\"w\":1e100,\"h\":300",
                             "\"x\":1e100,\"y\":0,\"w\":400,\"h\":300",
                             "\"x\":0,\"y\":0,\"w\":-1,\"h\":300"] {
                let data = Data("{\"v\":3,\"title\":\"Unsafe\",\"boards\":{\"A.dc.html\":{\(geometry)}}}".utf8)
                #expect(throws: (any Error).self) { try DesignImport.index(data, fallbackTitle: "Unsafe") }
            }
            for width in [1e100, Double.infinity, -Double.infinity, Double.nan] {
                let path = DesignPath("A.dc.html")!
                let index = DesignIndex(title: "Unsafe", boards: [path: .init(x: 0, y: 0, w: width, h: 300)])
                #expect(!DesignExportSelection(index: index, selected: []).rows[0].size.isEmpty)
                let size = DesignBoardCheck.Size(width: width, height: 300)
                #expect(!size.description.isEmpty)
                let source = """
                <script src="./support.js"></script>
                <x-dc><div style="width: \(width)px; height: 300px"></div></x-dc>
                <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300}}'></script>
                """
                do {
                    _ = try DesignBoardCheck.check(source)
                    Issue.record("oversized root should mismatch preview")
                } catch let error as DesignBoardCheck.Refusal {
                    #expect(error.code == "size_mismatch")
                    #expect(!error.description.isEmpty)
                } catch {
                    Issue.record("Unexpected refusal: \(error)")
                }
            }
        }
    }

    @Test func aCanvasThisBuildCantReadIsRefused() {
        #expect(throws: (any Error).self) { try DesignImport.index(Data(#"{"v":2,"boards":{}}"#.utf8), fallbackTitle: "x") }
        #expect(throws: (any Error).self) { try DesignImport.index(Data("not json".utf8), fallbackTitle: "x") }
    }
}
