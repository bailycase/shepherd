import CoreGraphics
import Testing
@testable import ShepherdUI

/// The composer menus' list model and sizing: what the lazy lists and the room above the
/// composer card rely on.
@Suite("Menu components")
struct MenuComponentTests {
    static let sections = [
        SHModelSection(title: "Recent", options: [SHModelOption(id: "a/one", title: "one")]),
        SHModelSection(title: "Empty", options: []),
        SHModelSection(title: "a", options: [SHModelOption(id: "a/one", title: "one"), SHModelOption(id: "a/two", title: "two", note: "1M")]),
    ]

    @Test func aModelListFlattensSectionsIntoHeadersAndNumberedModels() {
        let list = SHModelList(sections: Self.sections)
        #expect(list.rows.map(\.id) == ["#Recent", "Recent/a/one", "#a", "a/a/one", "a/a/two"])
        #expect(list.rows.map(\.position) == [nil, 0, nil, 1, 2])
        #expect(list.options.map(\.id) == ["a/one", "a/one", "a/two"])
        #expect(Set(list.rows.map(\.id)).count == list.rows.count, "a model in two sections has a row in each")
    }

    @Test func aModelListKnowsItsHeightAndWhereEachModelIs() {
        let list = SHModelList(sections: Self.sections)
        #expect(list.height == 2 * (SHComposerMetrics.menuHeaderHeight + SHComposerMetrics.modelSectionGap) + 3 * SHComposerMetrics.modelRowHeight)
        #expect(list.rowID(ofOption: 2) == "a/a/two")
        #expect(list.rowID(ofOption: 3) == nil)
        #expect(SHModelList(sections: []).height == 0)
    }

    /// The picker's list is 360pt tall at most, less when the room above the card is short (its search row and the
    /// list's insets), and never shorter than one row.
    @Test(arguments: [nil, .infinity, 1000, 420, 200, 40] as [CGFloat?])
    @MainActor func thePickersListFitsTheRoomItIsGiven(room: CGFloat?) {
        let chrome = SHComposerMetrics.modelSearchHeight + 2 * SHComposerMetrics.modelListInset
        let expected = max(SHComposerMetrics.modelRowHeight, min(SHComposerMetrics.modelPickerMaxHeight, (room ?? .infinity) - chrome))
        #expect(SHModelPicker.listMaxHeight(in: room) == expected)
        #expect(SHModelPicker.listMaxHeight(in: nil) == SHComposerMetrics.modelPickerMaxHeight)
    }

    /// The slash menu shows eight rows at most, fewer when the room is short, and always one.
    @Test(arguments: [nil, .infinity, 1000, 324, 323, 120, 10] as [CGFloat?])
    @MainActor func theSlashMenuShowsTheRowsThatFit(room: CGFloat?) {
        let rowRoom = (room ?? .infinity) - SHComposerMetrics.menuHeaderHeight - 2 * SH.Space.s
        let fit = rowRoom.isFinite ? Int((rowRoom / SHComposerMetrics.slashRowHeight).rounded(.down)) : SHComposerMetrics.menuMaxRows
        #expect(SHSlashMenu.visibleRows(in: room) == max(1, min(SHComposerMetrics.menuMaxRows, fit)))
    }
}

/// The composer's sizes (SHDesignTool › Chat composer): the chips' words show only at the
/// regular size with room for them.
@Suite("Composer sizes")
struct ComposerSizeTests {
    @Test(arguments: [(SHComposerSize.regular, false, true), (.regular, true, false), (.compact, false, false), (.compact, true, false)])
    func theChipsDropTheirWordsWhenCompactOrShortOfRoom(size: SHComposerSize, short: Bool, words: Bool) {
        #expect(size.showsChipWords(short: short) == words)
    }
}
