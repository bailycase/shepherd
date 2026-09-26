import Foundation
import Testing
import ShepherdProtocol

/// canvas.json v3: typed where Shepherd reads it, every other key kept as it came.
@Suite("Design index")
struct DesignIndexTests {
    static func object(_ json: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    static func reencoded(_ json: String) throws -> NSDictionary {
        let index = try DesignIndex.decode(Data(json.utf8))
        return try #require(JSONSerialization.jsonObject(with: index.encoded()) as? NSDictionary)
    }

    /// Each document decodes and encodes back to the same JSON, keys this build doesn't name
    /// included, at every level.
    @Test(arguments: [
        // A new canvas, as claude.ai makes one.
        #"{"v":3,"createdOnFiles":{"v":1,"at":"2026-09-14T18:20:00Z"},"title":"Spring Menu Poster","launch":{"view":"canvas"},"pages":[],"boards":{"Main.dc.html":{"x":0,"y":0,"w":880,"h":560}},"order":["Main.dc.html"],"notes":{},"designSystems":[]}"#,
        // Unknown keys on the index, a board, the launch, a page, a note and a system record.
        #"{"v":3,"attachments":{"a1":{"name":"brief.pdf"}},"future":[1,true,null],"title":"T","launch":{"view":"focused","file":"Main.dc.html","zoom":2},"pages":[{"id":"p1","name":"One","color":"blue"}],"boards":{"Main.dc.html":{"x":-80.5,"y":120,"w":390,"h":844,"title":"A · phone","page":"p1","is_interactive":true,"expand":"fill","frameless":true,"radius":24,"guides":[{"kind":"columns","count":12,"gutter":24,"margin":80}],"print":"flow","paper":"a4"}},"order":["Main.dc.html"],"notes":{"n1":{"x":0,"y":-300,"text":"Flows","kind":"title1","maxW":1840,"bold":true},"d1":{"kind":"pen","points":[[0,0],[4,5]],"stroke":"red"}},"designSystems":[{"title":"Acme","namespace":"acme-web","artifact":"https://example.invalid/a","version":null,"copiedAt":"2026-09-20T00:00:00Z"}]}"#,
        // Known keys with shapes this build doesn't expect stay as they came.
        #"{"v":3,"title":7,"launch":"canvas","pages":[{"name":"no id"}],"boards":{},"order":[],"notes":[],"designSystems":{"odd":true}}"#,
        // Absent optional keys stay absent.
        #"{"v":3,"boards":{},"order":[]}"#,
    ])
    func anIndexRoundTripsWithEveryKey(_ json: String) throws {
        #expect(try Self.reencoded(json) == Self.object(json))
    }

    /// The real canvas the Design tool's boards were drawn on (172 boards, pages, notes).
    @Test func theShepherdCanvasRoundTrips() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Designs/canvas.json")
        let data = try Data(contentsOf: url)
        let index = try DesignIndex.decode(data)
        #expect(index.boards.count == 172)
        #expect(index.order.count == 172)
        #expect(index.pages?.count == 8)
        #expect(index.extra["attachments"] != nil && index.extra["createdOnFiles"] != nil)
        let original = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let again = try #require(JSONSerialization.jsonObject(with: index.encoded()) as? NSDictionary)
        #expect(again == original)
        #expect(index.problems().isEmpty)
    }

    @Test func boardFieldsReadTyped() throws {
        let index = try DesignIndex.decode(Data(#"{"v":3,"boards":{"A.dc.html":{"x":1,"y":2,"w":390,"h":844,"title":"A · phone","page":"ios","is_interactive":true}},"order":["A.dc.html"]}"#.utf8))
        let path = try #require(DesignPath("A.dc.html"))
        let board = try #require(index.boards[path])
        #expect(board == DesignIndex.Board(x: 1, y: 2, w: 390, h: 844, title: "A · phone", page: "ios", isInteractive: true))
    }

    @Test(arguments: [
        #"{"v":2,"boards":{},"order":[]}"#,
        #"{"boards":{},"order":[]}"#,
        #"[]"#,
        #"{"v":3,"boards":{"../x.dc.html":{"x":0,"y":0,"w":100,"h":100}},"order":[]}"#,
        #"{"v":3,"boards":{"A.dc.html":{"x":0,"y":0,"w":"wide","h":100}},"order":[]}"#,
        #"{"v":3,"boards":{},"order":["/A.dc.html"]}"#,
    ])
    func anUnreadableIndexIsRefused(_ json: String) {
        #expect(throws: (any Error).self) { try DesignIndex.decode(Data(json.utf8)) }
    }

    @Test func aNewIndexIsStampedAndEmpty() throws {
        let index = DesignIndex.new(title: "Checkout", at: Date(timeIntervalSince1970: 0))
        let json = try #require(JSONSerialization.jsonObject(with: index.encoded()) as? NSDictionary)
        #expect(json == (try Self.object(#"{"v":3,"createdOnFiles":{"v":1,"at":"1970-01-01T00:00:00Z"},"title":"Checkout","launch":{"view":"canvas"},"pages":[],"boards":{},"order":[],"notes":{},"designSystems":[]}"#)))
    }

    // MARK: Order

    @Test func inSyncDropsStrayOrderAndAppendsUnlistedBoards() throws {
        let index = try DesignIndex.decode(Data(#"{"v":3,"boards":{"B.dc.html":{"x":0,"y":0,"w":100,"h":100},"A.dc.html":{"x":0,"y":0,"w":100,"h":100},"C.dc.html":{"x":0,"y":0,"w":100,"h":100}},"order":["C.dc.html","Gone.dc.html","C.dc.html"]}"#.utf8))
        #expect(index.inSync().order.map(\.rawValue) == ["C.dc.html", "A.dc.html", "B.dc.html"])
    }

    // MARK: Merging a canvas update

    static let base = #"{"v":3,"title":"Checkout","keep":{"me":1},"launch":{"view":"canvas"},"pages":[],"boards":{"A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"frameless":true},"B.dc.html":{"x":1360,"y":0,"w":390,"h":844}},"order":["A.dc.html","B.dc.html"],"notes":{"t":{"x":0,"y":-300,"text":"Flows","kind":"title1"}},"designSystems":[]}"#

    struct Merge: Sendable, CustomTestStringConvertible {
        let name: String
        let patch: String
        let expected: String
        var testDescription: String { name }
    }

    @Test(arguments: [
        Merge(name: "a new board joins the end of order",
              patch: #"{"boards":{"C.dc.html":{"x":0,"y":920,"w":1280,"h":800}}}"#,
              expected: #"{"v":3,"title":"Checkout","keep":{"me":1},"launch":{"view":"canvas"},"pages":[],"boards":{"A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"frameless":true},"B.dc.html":{"x":1360,"y":0,"w":390,"h":844},"C.dc.html":{"x":0,"y":920,"w":1280,"h":800}},"order":["A.dc.html","B.dc.html","C.dc.html"],"notes":{"t":{"x":0,"y":-300,"text":"Flows","kind":"title1"}},"designSystems":[]}"#),
        Merge(name: "a move merges into the entry and keeps its other keys",
              patch: #"{"boards":{"A.dc.html":{"x":80,"y":40}}}"#,
              expected: #"{"v":3,"title":"Checkout","keep":{"me":1},"launch":{"view":"canvas"},"pages":[],"boards":{"A.dc.html":{"x":80,"y":40,"w":1280,"h":800,"frameless":true},"B.dc.html":{"x":1360,"y":0,"w":390,"h":844}},"order":["A.dc.html","B.dc.html"],"notes":{"t":{"x":0,"y":-300,"text":"Flows","kind":"title1"}},"designSystems":[]}"#),
        Merge(name: "null removes a board from boards and order",
              patch: #"{"boards":{"A.dc.html":null}}"#,
              expected: #"{"v":3,"title":"Checkout","keep":{"me":1},"launch":{"view":"canvas"},"pages":[],"boards":{"B.dc.html":{"x":1360,"y":0,"w":390,"h":844}},"order":["B.dc.html"],"notes":{"t":{"x":0,"y":-300,"text":"Flows","kind":"title1"}},"designSystems":[]}"#),
        Merge(name: "an order replaces the order",
              patch: #"{"order":["B.dc.html","A.dc.html"]}"#,
              expected: #"{"v":3,"title":"Checkout","keep":{"me":1},"launch":{"view":"canvas"},"pages":[],"boards":{"A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"frameless":true},"B.dc.html":{"x":1360,"y":0,"w":390,"h":844}},"order":["B.dc.html","A.dc.html"],"notes":{"t":{"x":0,"y":-300,"text":"Flows","kind":"title1"}},"designSystems":[]}"#),
        Merge(name: "title, notes and pages change; unknown keys stay",
              patch: #"{"title":"Checkout v2","notes":{"t":null,"s":{"x":0,"y":900,"text":"Why","w":240}},"pages":[{"id":"web","name":"Web"}]}"#,
              expected: #"{"v":3,"title":"Checkout v2","keep":{"me":1},"launch":{"view":"canvas"},"pages":[{"id":"web","name":"Web"}],"boards":{"A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"frameless":true},"B.dc.html":{"x":1360,"y":0,"w":390,"h":844}},"order":["A.dc.html","B.dc.html"],"notes":{"s":{"x":0,"y":900,"text":"Why","w":240}},"designSystems":[]}"#),
    ])
    func aCanvasUpdateMergesKeysAndKeepsTheRest(_ merge: Merge) throws {
        let index = try DesignIndex.decode(Data(Self.base.utf8))
        let merged = try index.merging(JSONDecoder().decode(JSONValue.self, from: Data(merge.patch.utf8)))
        let json = try #require(JSONSerialization.jsonObject(with: merged.encoded()) as? NSDictionary)
        #expect(json == (try Self.object(merge.expected)))
        #expect(merged.order == merged.inSync().order, "order and boards stay in step")
    }

    @Test func aCanvasUpdateThatBreaksTheFormatIsRefused() throws {
        let index = try DesignIndex.decode(Data(Self.base.utf8))
        #expect(throws: (any Error).self) { try index.merging(.string("nope")) }
        #expect(throws: (any Error).self) { try index.merging(.object(["boards": .object(["../x.dc.html": .object([:])])])) }
    }

    // MARK: Problems

    @Test(arguments: [
        (#"{"boards":{"A.dc.html":{"x":0,"y":0,"w":20,"h":100}}}"#, "A.dc.html: w and h are 40–8000"),
        (#"{"boards":{"a.dc.html":{"x":0,"y":0,"w":100,"h":100}}}"#, "a.dc.html and A.dc.html share the name a"),
        (#"{"order":["A.dc.html","A.dc.html"]}"#, "order lists each board once"),
        (#"{"pages":[{"id":"bad id","name":"x"}]}"#, "page id \"bad id\" is [A-Za-z0-9_-]{1,40}"),
        (#"{"pages":[{"id":"p","name":"x"},{"id":"p","name":"y"}]}"#, "page ids are unique"),
        (#"{"notes":{"no/te":{"x":0,"y":0,"text":"x"}}}"#, "note id \"no/te\" is [A-Za-z0-9_-]{1,40}"),
        (#"{"designSystems":[{"namespace":"Acme Web"}]}"#, "design system folder \"Acme Web\" is [a-z0-9][a-z0-9_-]{0,63}"),
    ])
    func aBrokenIndexNamesItsProblem(_ patch: String, _ problem: String) throws {
        let index = try DesignIndex.decode(Data(#"{"v":3,"boards":{"A.dc.html":{"x":0,"y":0,"w":100,"h":100}},"order":["A.dc.html"]}"#.utf8))
        let merged = try index.merging(JSONDecoder().decode(JSONValue.self, from: Data(patch.utf8)))
        #expect(merged.problems().contains(problem), "\(merged.problems())")
    }
}
