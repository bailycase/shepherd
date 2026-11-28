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
        #expect(list.height == 2 * (SHComposerMetrics.menuHeaderHeight + SHComposerMetrics.modelSectionGap) + 3 * SHModelList.rowHeight(SHModelOption(id: "a", title: "a")))
        #expect(list.rowID(ofOption: 2) == "a/a/two")
        #expect(list.rowID(ofOption: 3) == nil)
        #expect(SHModelList(sections: []).height == 0)
    }

    #if os(macOS)
    /// GXModel's rows size to their content: 52pt with one line of levels, one more line (17pt) for each the levels wrap to, a
    /// row with no levels just its id; the current level is the only bold one.
    @Test func aModelRowSizesToItsLevels() {
        let short = SHModelOption(id: "a", title: "claude-sonnet-4-5", subtitle: "Off, Minimal, Low, Medium, High", note: "1M")
        let long = SHModelOption(id: "b", title: "claude-opus-4-5", subtitle: "Off, Minimal, Low, Medium, High, Extra high, Max", note: "200K",
                                 currentLevel: "Medium")
        let bare = SHModelOption(id: "c", title: "model-x")
        #expect(abs(SHModelList.rowHeight(short) - 52) < 1, "\(SHModelList.rowHeight(short))")
        #expect(abs(SHModelList.rowHeight(long) - 69) < 1, "\(SHModelList.rowHeight(long))")
        #expect(SHModelList.levelLines(long) == 2 && SHModelList.levelLines(short) == 1 && SHModelList.levelLines(bare) == 0)
        #expect(SHModelList.rowHeight(bare) >= SHComposerMetrics.modelRowMinHeight && SHModelList.rowHeight(bare) < SHModelList.rowHeight(short))
        let list = SHModelList(sections: [SHModelSection(title: "Anthropic", options: [long, short, bare])])
        #expect(list.height == list.rows.reduce(0) { $0 + $1.height })
    }

    /// The levels break as CSS breaks them (the board's "…High, Extra high," over "Max"), not the way SwiftUI's Text pushes a lone last word up.
    @Test func wrappedLevelsFillEachLine() {
        let long = SHModelOption(id: "b", title: "claude-opus-4-5", subtitle: "Off, Minimal, Low, Medium, High, Extra high, Max", note: "200K")
        let text = SHModelLevelsLabel.attributed(long.subtitle ?? "", current: "Medium", color: .black)
        let width = 262.0
        let layout = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        #expect(Int((layout.height / SHModelLevelsLabel.lineHeight).rounded()) == 2)
    }
    #endif

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
