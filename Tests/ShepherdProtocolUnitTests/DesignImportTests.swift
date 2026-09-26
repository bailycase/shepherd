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
        let big = [Entry("canvas.json")] + (0..<17).map { Entry("B\($0).dc.html", size: DesignImport.maxFileBytes) }
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

    @Test func aCanvasThisBuildCantReadIsRefused() {
        #expect(throws: (any Error).self) { try DesignImport.index(Data(#"{"v":2,"boards":{}}"#.utf8), fallbackTitle: "x") }
        #expect(throws: (any Error).self) { try DesignImport.index(Data("not json".utf8), fallbackTitle: "x") }
    }
}
