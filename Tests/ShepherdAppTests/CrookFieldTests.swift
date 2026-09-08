import Foundation
import Testing
@testable import ShepherdApp

/// The launch overlay's ASCII render shades a precomputed distance field of
/// the crook. These pin the geometry: known on-path points are inside the
/// stroke, empty regions are far outside, and the arc-length parameter runs
/// from the staff's foot to the hook's tip (the traveling pulse depends on
/// that direction).
@Suite("Crook ASCII field")
struct CrookFieldTests {
    let field = CrookField.make(cols: 46, rows: 44)

    /// Map a point in the source 1024 grid to a cell index.
    private func cell(x: Double, y: Double) -> CrookField.Cell {
        let i = Int((x - 150) / 540 * 46)
        let j = Int((y - 80) / 860 * 44)
        return field.cells[j * 46 + i]
    }

    @Test func strokeCellsAreInside() {
        #expect(cell(x: 547.2, y: 600).d < 1)   // staff midline
        #expect(cell(x: 384, y: 163.2).d < 1)   // top of the hook
        #expect(cell(x: 320, y: 438.4).d < 1)   // hook tip
    }

    @Test func emptyRegionsAreOutside() {
        #expect(cell(x: 200, y: 850).d > 2.2)   // bottom-left, past stray halo
        #expect(cell(x: 380, y: 700).d > 2.2)   // inside the hook's mouth, below curl
    }

    @Test func arcLengthRunsFootToHookTip() {
        let foot = cell(x: 547.2, y: 830)
        let mid = cell(x: 547.2, y: 500)
        let tip = cell(x: 320, y: 438.4)
        #expect(foot.s < 0.1)
        #expect(mid.s > foot.s)
        #expect(tip.s > 0.9)
    }
}
