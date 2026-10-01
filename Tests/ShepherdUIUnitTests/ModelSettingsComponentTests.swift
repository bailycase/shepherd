import Foundation
import Testing
@testable import ShepherdUI

/// The model-settings popover's keyboard walk, its segmented rows, and its one bolt.
@Suite("Model settings components")
struct ModelSettingsComponentTests {
    typealias Stop = NWModelSettingsStops.Stop

    // MARK: Keyboard

    /// ↑↓ visit every choice top to bottom: each model, All models…, each level, each speed.
    @Test func theArrowKeysVisitEveryChoiceTopToBottom() {
        let stops = NWModelSettingsStops(models: 2, thinking: 4, speeds: 2)
        #expect(stops.count == 9)
        let visited = (0..<stops.count).compactMap(stops.stop(at:))
        #expect(visited == [.model(0), .model(1), .allModels, .thinking(0), .thinking(1), .thinking(2), .thinking(3), .speed(0), .speed(1)])
        #expect(visited.map(stops.index(of:)) == Array(0..<9), "a stop and its index are each other's inverse")
        #expect(stops.stop(at: -1) == nil && stops.stop(at: 9) == nil)
    }

    /// A model with no thinking, or no raised tier, has no stops for them.
    @Test(arguments: [
        (1, 0, 0, [Stop.model(0), .allModels]),
        (1, 4, 0, [.model(0), .allModels, .thinking(0), .thinking(1), .thinking(2), .thinking(3)]),
        (0, 0, 2, [.allModels, .speed(0), .speed(1)]),
    ] as [(Int, Int, Int, [Stop])])
    func onlyWhatTheModelOffersHasAStop(models: Int, thinking: Int, speeds: Int, expected: [Stop]) {
        let stops = NWModelSettingsStops(models: models, thinking: thinking, speeds: speeds)
        #expect((0..<stops.count).compactMap(stops.stop(at:)) == expected)
    }

    /// ↑ at the top and ↓ at the bottom stay where they are.
    @Test(arguments: [(0, -1, 0), (0, 1, 1), (5, 1, 5), (4, 1, 5), (5, -1, 4), (9, 1, 5)] as [(Int, Int, Int)])
    func theArrowKeysStopAtTheEnds(from: Int, step: Int, to: Int) {
        #expect(NWModelSettingsStops(models: 1, thinking: 2, speeds: 2).moved(from, by: step) == to)
    }

    // MARK: Segments

    /// Up to four segments share a row; more wrap onto balanced rows, so no title is cut.
    @Test(arguments: [
        (0, []), (1, [0..<1]), (2, [0..<2]), (4, [0..<4]),
        (5, [0..<3, 3..<5]), (6, [0..<3, 3..<6]), (7, [0..<4, 4..<7]), (8, [0..<4, 4..<8]),
    ] as [(Int, [Range<Int>])])
    func segmentsWrapOntoBalancedRows(count: Int, rows: [Range<Int>]) {
        #expect(NWModelSettingsSegments.rows(of: count) == rows)
    }

    // MARK: One bolt

    /// Fast is a filled bolt, never the outline `bolt` an automation wears.
    @Test func theFastBoltIsFilled() {
        #expect(NWFastBolt.symbol == "bolt.fill")
    }

    /// Every bolt in the composer's components and the screens that draw its controls goes through
    /// `NWFastBolt`: no other file names the symbol, so the glyph, its weight and its colour
    /// cannot drift apart again.
    @Test func noOtherComposerFileDrawsItsOwnBolt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = ["Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer", "Sources/ShepherdApp/Thread"]
        var files = try folders.flatMap { folder in
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
        }
        files.append(root.appendingPathComponent("Sources/ShepherdApp/NewThreadPage.swift"))
        let swift = files.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "FastBolt.swift" }
        try #require(swift.count > 10, "the composer's files were found")
        for file in swift {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("\"bolt"), "\(file.lastPathComponent) draws a bolt of its own")
        }
    }
}
