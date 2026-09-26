import CoreGraphics
import Foundation
import ShepherdProtocol
import Testing
@testable import DesignSurfaceKit

/// What the bridge's hit test reports, as the canvas takes it: checked against the view record's
/// grammar, and named as view-state.md numbers the board.
@Suite struct DesignHitTests {
    static func answer(tid: Any = 5, path: Any = [1, 1, 0], x: Any = 10, y: Any = 20, width: Any = 200, height: Any = 40,
                       kind: Any = "shape", label: Any? = "Checkout funnel", name: Any? = nil, noun: Any = "card") -> [String: Any] {
        var object: [String: Any] = ["tid": tid, "path": path, "x": x, "y": y, "width": width, "height": height, "kind": kind, "noun": noun]
        object["label"] = label
        object["name"] = name
        return object
    }

    @Test func anAnswerInsideTheGrammarIsAHit() throws {
        let hit = try #require(DesignHit(bridge: Self.answer(name: "Checkout funnel")))
        #expect(hit.tid == 5 && hit.path == [1, 1, 0])
        #expect(hit.rect == CGRect(x: 10, y: 20, width: 200, height: 40))
        #expect(hit.kind == .shape && hit.noun == "card")
        #expect(hit.tag == "card · Checkout funnel")
        #expect(hit.id(on: try #require(DesignPath("flows/Cart.dc.html")))?.description == "flows%2FCart.dc.html#5:1/1/0")
    }

    nonisolated(unsafe) static let malformed: [String: [String: Any]] = [
        "a tid past 9999": answer(tid: 10_000),
        "a negative tid": answer(tid: -1),
        "a fractional tid": answer(tid: 1.5),
        "a tid that is a string": answer(tid: "5"),
        "an empty path": answer(path: [Int]()),
        "a path of ten": answer(path: Array(repeating: 0, count: 10)),
        "an index past 99": answer(path: [1, 100]),
        "a path of strings": answer(path: ["1"]),
        "a negative width": answer(width: -1),
        "an endless rect": answer(x: Double.infinity),
        "a rect far off the board": answer(y: 200_000),
        "no rect": ["tid": 5, "path": [1]],
    ]

    @Test(arguments: malformed.keys.sorted())
    func anAnswerOutsideTheGrammarIsNoHit(_ why: String) {
        #expect(DesignHit(bridge: Self.malformed[why]) == nil, "\(why)")
    }

    @Test func nothingIsNoHit() {
        #expect(DesignHit(bridge: nil) == nil)
        #expect(DesignHit(bridge: NSNull()) == nil)
        #expect(DesignHit(bridge: "5:1/1/0") == nil)
    }

    @Test func wordsAreCheckedAndClipped() throws {
        let long = String(repeating: "Checkout ", count: 20)
        let hit = try #require(DesignHit(bridge: Self.answer(kind: "blob", label: "  Checkout\n funnel ", name: long, noun: "<b>")))
        #expect(hit.kind == .other)
        #expect(hit.label == "Checkout funnel")
        #expect((hit.name?.count ?? 0) <= DesignHit.maxName)
        #expect(hit.noun == "element")
        #expect(try #require(DesignHit(bridge: Self.answer(label: nil))).tag == "card")
        #expect(try #require(DesignHit(bridge: Self.answer(label: "{{title}}", noun: "text"))).tag == "text · {{title}}")
    }

    /// Every element of every golden board the grammar can name comes back as the id the golden
    /// numbering gives it.
    @Test(arguments: ["Minimal.dc.html", "Edges.dc.html", "DZStart.dc.html", "NWDesignTool.dc.html", "ThreadRichContent.dc.html"])
    func aHitOnAGoldenElementIsNamedAsTheGoldenFileNumbersIt(_ name: String) throws {
        let designs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Designs")
        let data = try Data(contentsOf: designs.appendingPathComponent("element-ids.json"))
        let boards = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["boards"] as? [String: [String]])
        let board = try #require(DesignPath(name))
        var named = 0
        for entry in try #require(boards[name]) {
            let numbering = String(try #require(entry.split(separator: " ").first))
            let parts = numbering.split(separator: ":")
            let tid = try #require(Int(parts[0]))
            let path = try parts[1].split(separator: "/").map { try #require(Int($0)) }
            let hit = DesignHit(bridge: Self.answer(tid: tid, path: path))
            if path.count > DesignElementID.maxPathLength || path.contains(where: { $0 > DesignElementID.maxChildIndex }) {
                #expect(hit == nil, "\(name) \(entry)")
                continue
            }
            #expect(hit?.id(on: board)?.description == "\(board.viewName)#\(numbering)", "\(name) \(entry)")
            named += 1
        }
        #expect(named > 0)
    }
}
