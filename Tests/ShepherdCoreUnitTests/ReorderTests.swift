import Testing
import ShepherdCore

/// Sidebar drag-and-drop draws its drop line above the target row; the move must land there
/// whichever direction the row travels.
@Suite("Reordering")
struct ReorderTests {
    private struct Row: Identifiable, Equatable { let id: String }
    private let rows = ["a", "b", "c", "d"].map(Row.init)

    @Test(arguments: [
        ("a", "c", "bacd"),   // down: lands just above c, not below it
        ("d", "b", "adbc"),   // up
        ("b", "c", "abcd"),   // already directly above: no change in order
        ("a", "d", "bcad"),
    ])
    func movedRowLandsDirectlyAboveTheTarget(id: String, target: String, expected: String) throws {
        let moved = try #require(rows.moving(id, before: target))
        #expect(moved.map(\.id).joined() == expected)
    }

    @Test func missingOrSameElementsAreRejected() {
        #expect(rows.moving("a", before: "a") == nil)
        #expect(rows.moving("x", before: "a") == nil)
        #expect(rows.moving("a", before: "x") == nil)
    }

    /// A drop line under the last row moves the row to the end; the last row stays put.
    @Test(arguments: [("a", "bcda"), ("c", "abdc")])
    func noTargetMovesTheRowLast(id: String, expected: String) throws {
        let moved = try #require(rows.moving(id, before: String?.none))
        #expect(moved.map(\.id).joined() == expected)
    }

    @Test func movingTheLastRowLastOrAMissingOneIsNoMove() {
        #expect(rows.moving("d", before: String?.none) == nil)
        #expect(rows.moving("x", before: String?.none) == nil)
    }
}
