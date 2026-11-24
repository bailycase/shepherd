import Testing
@testable import ShepherdUI

/// The Changes pane's file rows: how many show before "Show N more", and the current file never hiding.
struct FileRowsTests {
    private static let items = (1...7).map { SHFileStrip.Item(id: "f\($0)", path: "dir/f\($0).swift", status: .modified, added: $0, removed: 0) }

    @Test(arguments: [
        (nil as String?, false, 3),
        ("f1", false, 3),
        ("f3", false, 3),
        ("f4", false, 7),
        ("f7", false, 7),
        ("f1", true, 7),
        ("gone", false, 3),
    ])
    func theFirstFewShowUntilOpenedOrTheCurrentFileIsBelowThem(selection: String?, opened: Bool, count: Int) {
        #expect(SHFileRows.shown(Self.items, selection: selection, opened: opened).count == count)
    }

    @Test func fewFilesNeverHideAny() {
        let two = Array(Self.items.prefix(2))
        #expect(SHFileRows.shown(two, selection: "f2", opened: false).count == 2)
    }
}
