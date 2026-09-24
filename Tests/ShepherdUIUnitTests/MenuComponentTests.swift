import CoreGraphics
import Testing
@testable import ShepherdUI

/// The composer menus' list model and sizing: what the lazy lists and the room above the
/// composer card rely on.
@Suite("Menu components")
struct MenuComponentTests {
    static let sections = [
        NWModelSection(title: "Recent", options: [NWModelOption(id: "a/one", title: "one")]),
        NWModelSection(title: "Empty", options: []),
        NWModelSection(title: "a", options: [NWModelOption(id: "a/one", title: "one"), NWModelOption(id: "a/two", title: "two", note: "1M")]),
    ]

    @Test func aModelListFlattensSectionsIntoHeadersAndNumberedModels() {
        let list = NWModelList(sections: Self.sections)
        #expect(list.rows.map(\.id) == ["#Recent", "Recent/a/one", "#a", "a/a/one", "a/a/two"])
        #expect(list.rows.map(\.position) == [nil, 0, nil, 1, 2])
        #expect(list.options.map(\.id) == ["a/one", "a/one", "a/two"])
        #expect(Set(list.rows.map(\.id)).count == list.rows.count, "a model in two sections has a row in each")
    }

    @Test func aModelListKnowsItsHeightAndWhereEachModelIs() {
        let list = NWModelList(sections: Self.sections)
        #expect(list.height == 2 * NWComposerMetrics.menuHeaderHeight + 3 * NWComposerMetrics.menuRowHeight)
        #expect(list.rowID(ofOption: 2) == "a/a/two")
        #expect(list.rowID(ofOption: 3) == nil)
        #expect(NWModelList(sections: []).height == 0)
    }

    /// The picker's list is 360pt tall at most, less when the room above the card is short, and
    /// never shorter than one row.
    @Test(arguments: [(nil, 360), (.infinity, 360), (1000, 360), (406, 360), (200, 154), (40, 28)] as [(CGFloat?, CGFloat)])
    func thePickersListFitsTheRoomItIsGiven(room: CGFloat?, list: CGFloat) {
        #expect(NWModelPicker.listMaxHeight(in: room) == list)
    }

    /// The slash menu shows eight rows at most, fewer when the room is short, and always one.
    @Test(arguments: [(nil, 8), (.infinity, 8), (1000, 8), (260, 8), (259, 7), (100, 2), (10, 1)] as [(CGFloat?, Int)])
    func theSlashMenuShowsTheRowsThatFit(room: CGFloat?, rows: Int) {
        #expect(NWSlashMenu.visibleRows(in: room) == rows)
    }
}
