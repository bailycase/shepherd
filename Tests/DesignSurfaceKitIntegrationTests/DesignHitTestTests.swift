import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import WebKit
@testable import DesignSurfaceKit

/// The canvas's selection against the real runtime: the bridge names the element under a point
/// as view-state.md numbers the board, with where it is drawn and what it is.
@MainActor
@Suite(.mainActorExclusive)
struct DesignHitTestTests {
    /// The centre of the element `selector` picks, in the board's points.
    func centre(_ harness: BoardHarness, _ view: DesignBoardView, _ selector: String) async throws -> (CGPoint, CGRect) {
        let value = try await harness.page(view, """
            const r = document.querySelector(\(String(reflecting: selector))).getBoundingClientRect();
            return [r.left, r.top, r.width, r.height];
            """)
        let box = try #require(value as? [Double])
        let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        return (CGPoint(x: rect.midX, y: rect.midY), rect)
    }

    @Test func aHitNamesTheElementUnderThePointAsTheTemplateNumbersIt() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()
        let board = try #require(DesignPath("Main.dc.html"))

        let (point, rect) = try await centre(harness, view, "#title")
        let title = try #require(await view.hitTest(at: point))
        #expect(title.tid == 3 && title.path == [1, 0])
        #expect(title.id(on: board)?.description == "Main.dc.html#3:1/0")
        #expect(title.rect == rect)
        #expect(title.kind == .text && title.label == "{{title}}" && title.noun == "text")
        #expect(title.tag == "text · {{title}}")

        // One template node however many times a loop draws it; the ring goes on the one hit.
        let (second, secondRect) = try await centre(harness, view, ".row[data-index='1']")
        let row = try #require(await view.hitTest(at: second))
        #expect(row.tid == 5 && row.path == [1, 1, 0] && row.rect == secondRect)
        #expect(row.label == "{{item.label}} · {{$index}}")

        let (button, _) = try await centre(harness, view, "#count")
        let hitButton = try #require(await view.hitTest(at: button))
        #expect(hitButton.tid == 12 && hitButton.noun == "button" && hitButton.kind == .text)

        // Inside an import, the <dc-import> is the element.
        let (card, cardRect) = try await centre(harness, view, "div.card[data-dc-owner]")
        let hitCard = try #require(await view.hitTest(at: card))
        #expect(hitCard.tid == 11 && hitCard.path == [1, 4, 0])
        #expect(hitCard.noun == "component" && hitCard.name == "Card" && hitCard.tag == "component · Card")
        #expect(hitCard.rect == cardRect, "the import's own drawing, not every card the loop drew")

        // The root, where nothing inside it is drawn: a filled container reads as a card.
        let root = try #require(await view.hitTest(at: CGPoint(x: 395, y: 295)))
        #expect(root.tid == 2 && root.path == [1] && root.kind == .shape && root.noun == "card")
    }

    /// A selection is found again after the board re-renders, where it is drawn now.
    @Test func anElementIsFoundAgainAfterALiveReload() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()
        let before = try #require(await view.element(tid: 3))
        var source = try harness.source("Main.dc.html")
        source = source.replacingOccurrences(of: "<h1 id=\"title\" style=\"margin: 0; font-size: 20px\">",
                                             with: "<h1 id=\"title\" style=\"margin: 0; font-size: 40px\">")
        try await view.replaceSource(source)
        let after = try #require(await view.element(tid: 3))
        #expect(after.path == before.path && after.rect.height > before.rect.height)
        #expect(await view.element(tid: 9) == nil, "a node its sc-if doesn't draw isn't found")
        #expect(await view.element(tid: 999) == nil)
    }

    /// Every element the runtime can find on a golden board carries the path the golden
    /// numbering gives it, and a hit anywhere on the board names one of them.
    @Test(arguments: DesignBoardViewTests.goldenBoards)
    func everyHitOnAGoldenBoardIsAGoldenElement(_ name: String) async throws {
        let source = try String(contentsOf: BoardHarness.designs.appendingPathComponent("boards/\(name)"), encoding: .utf8)
        let data = try Data(contentsOf: BoardHarness.designs.appendingPathComponent("element-ids.json"))
        let boards = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["boards"] as? [String: [String]])
        var golden: [Int: [Int]] = [:]
        for entry in try #require(boards[name]) {
            let parts = try #require(entry.split(separator: " ").first).split(separator: ":")
            golden[try #require(Int(parts[0]))] = try parts[1].split(separator: "/").map { try #require(Int($0)) }
        }

        let harness = try BoardHarness(files: [name: source])
        let size = CGSize(width: 1600, height: 1200)
        let view = try harness.view(name, size: size)
        try await view.load()

        let tids = Set(try await harness.stamped(view).compactMap { Int($0.split(separator: " ")[0]) })
        var found = 0
        for tid in tids.sorted() {
            guard let hit = await view.element(tid: tid) else { continue }
            #expect(hit.path == golden[tid], "\(name): tid \(tid)")
            found += 1
        }
        #expect(found > 0)

        var hits = 0
        for y in stride(from: 10.0, to: size.height, by: 90) {
            for x in stride(from: 10.0, to: size.width, by: 90) {
                guard let hit = await view.hitTest(at: CGPoint(x: x, y: y)) else { continue }
                #expect(hit.path == golden[hit.tid], "\(name): hit at \(x),\(y) named \(hit.tid):\(hit.path)")
                hits += 1
            }
        }
        #expect(hits > 0)
    }
}
