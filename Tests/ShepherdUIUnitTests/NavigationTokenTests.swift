import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

@Suite("Navigation measures")
struct NavigationTokenTests {
    @Test(arguments: [(SHDensity.compact, 22.0), (.standard, 28.0), (.comfortable, 36.0)])
    func rowDensitiesAreTheBoardsHeights(_ density: SHDensity, height: Double) {
        #expect(density.baseRowHeight == CGFloat(height))
    }

    @Test func thePaletteSitsOneTwelveDownAtItsDesignedWidth() {
        let row = SHPaletteMetrics.rowHeight
        let placement = SHPaletteMetrics.placement(in: CGSize(width: 1440, height: 900), rowHeight: row)
        #expect(placement.top == 112)
        #expect(placement.width == 680)
        #expect(placement.maxListHeight == row * 14)
    }

    /// In a short window the list gives way so the card never runs off the bottom; in a narrow
    /// one the card keeps a margin on each side.
    @Test func thePaletteIsCappedByTheWindow() {
        let short = SHPaletteMetrics.placement(in: CGSize(width: 720, height: 600), rowHeight: 28)
        let cardBottom = short.top + SHPaletteMetrics.chrome + short.maxListHeight
        #expect(cardBottom <= 600 - SHPaletteMetrics.margin)
        #expect(short.width == 680)

        let narrow = SHPaletteMetrics.placement(in: CGSize(width: 500, height: 600), rowHeight: 28)
        #expect(narrow.width == 500 - 2 * SHPaletteMetrics.margin)
    }

    @Test func aTinyWindowStillLeavesRoomForOneRow() {
        let tiny = SHPaletteMetrics.placement(in: CGSize(width: 100, height: 80), rowHeight: 28)
        #expect(tiny.maxListHeight == 28)
        #expect(tiny.width >= 0)
    }
}

@Suite("Place menu")
struct PlaceMenuTests {
    @Test func aSearchMatchesAProjectsPathAsWellAsItsName() {
        let section = SHPlaceSection(id: "local", title: "This Mac", options: [
            SHPlaceOption(id: "a", section: "local", title: "payments", path: "~/Developer/payments"),
            SHPlaceOption(id: "b", section: "local", title: "homelab", path: "~/src/homelab"),
        ])
        #expect(SHPlaceMenu<EmptyView>.visible([section], query: "Developer", expanded: []).flatMap(\.options).map(\.id) == ["a"])
        #expect(SHPlaceMenu<EmptyView>.visible([section], query: "lab", expanded: []).flatMap(\.options).map(\.id) == ["b"])
    }

    @Test(arguments: [("auto", "mini", "Picks the Mac with room"), ("a", "asleep", "Asleep"), ("b", "most", "Has room"), ("c", "some", "Has room"),
                      ("d", "little", "Little room"), ("e", "full", "No room")])
    func aMacsWordIsTheBoards(id: String, roomWord: String, word: String) {
        let row = SHFleetPlaceRow(id: id, title: "Mac", detail: "", room: 0.5, roomWord: roomWord, tone: .quiet, isCurrent: false)
        #expect(row.menuWord == word)
    }
}
