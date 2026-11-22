import Foundation
import ShepherdRemote
import Testing

@Suite struct ThreadRowHeightsTests {
    @Test func estimatesAndMeasurementsIncludeSpacingAndKeepASignedAnchorDelta() {
        var table = ThreadRowHeights()
        table.replace([.init(id: "a", estimate: 20), .init(id: "b", estimate: 30), .init(id: "c", estimate: 40)], spacing: 5)
        #expect(table.height == 100)
        #expect(table.offset(at: 2) == 60)
        #expect(table.measure(["a": 12, "b": 42, "c": 70], width: 480, above: 1) == -8)
        #expect(table.offset(at: 1) == 17)
        #expect(table.height == 134)
        #expect(table.width == 480)
        #expect(table.measure(["a": 22, "missing": 99], width: 480, above: 1) == 10)
    }

    @Test func theWindowUsesPrefixSumsAndDoesNotBuildOutsideHistory() {
        var table = ThreadRowHeights()
        table.replace((0..<10).map { .init(id: String($0), estimate: 20) }, spacing: 0)
        let clip = CGRect(x: 0, y: 80, width: 400, height: 20)
        #expect(table.range(for: clip, viewports: 2) == 2..<7)
        table.measure(["1": 40], width: 400, above: 4)
        #expect(table.range(for: clip, viewports: 2) == 1..<6)
        #expect(table.range(for: clip.offsetBy(dx: 0, dy: 200), viewports: 2).isEmpty)
    }

    @Test func duplicateIDsKeepBothSlotsAcrossAReplacement() {
        var table = ThreadRowHeights()
        let row = ThreadRowHeights.Row(id: "a", estimate: 20)
        table.replace([row, row], spacing: 5)
        #expect(table.index(for: "a") == 0)
        #expect(table.height == 45)
        table.measure(["a": 24], width: 400, above: 0)
        table.replace([.init(id: "older", estimate: 30), row, row], spacing: 5)
        #expect(table.index(for: "a") == 1)
        #expect(table.offset(at: 2) == 64)
        #expect(table.height == 88)
    }

    @Test func prependsKeepExistingMeasurementsAndChangedEstimatesInvalidateThem() {
        var table = ThreadRowHeights()
        table.replace([.init(id: "a", estimate: 20), .init(id: "b", estimate: 30)], spacing: 5)
        table.measure(["a": 28, "b": 42], width: 400, above: 0)
        table.replace([.init(id: "older", estimate: 40), .init(id: "a", estimate: 20), .init(id: "b", estimate: 60)], spacing: 5)
        #expect(table.index(for: "a") == 1)
        #expect(table.offset(at: 1) == 45)
        #expect(table.height(for: "a") == 28)
        #expect(table.height(for: "b") == 60)
        table.resetMeasurements(width: 500)
        #expect(table.width == 500)
        #expect(table.height(for: "a") == 20)
    }
}
