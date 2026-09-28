import Testing
@testable import ShepherdSessions

@Suite("Terminal grid bounds")
struct TerminalGridTests {
    @Test(arguments: [
        (80, 24, true), (1, 1, true), (1024, 256, true), (512, 512, true),
        (0, 24, false), (-1, 24, false), (80, 0, false), (80, -1, false),
        (1025, 1, false), (1, 1025, false), (1024, 257, false),
        (65_536, 1, false), (1, 65_536, false), (65_535, 65_535, false),
        (Int.max, Int.max, false), (Int.min, 24, false),
    ])
    func terminalGridsAreBoundedBeforeAllocation(cols: Int, rows: Int, accepted: Bool) {
        #expect(TerminalGrid.isValid(cols: cols, rows: rows) == accepted)
    }
}
