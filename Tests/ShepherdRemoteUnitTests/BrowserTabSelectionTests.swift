import Foundation
import Testing
import ShepherdRemote

@Suite("Browser tab selection")
struct BrowserTabSelectionTests {
    @Test func closingSelectsTheNearestRemainingTabAndReplacesTheLast() {
        let first = UUID(), second = UUID(), third = UUID(), blank = UUID()
        var tabs = BrowserTabSelection(first: first)
        let addedSecond = tabs.add(second)
        let addedThird = tabs.add(third)
        #expect(addedSecond && addedThird)
        #expect(tabs.selected == third)
        tabs.select(second)
        tabs.close(second, replacement: blank)
        #expect(tabs.ids == [first, third])
        #expect(tabs.selected == third)
        tabs.select(second)
        #expect(tabs.selected == third)
        tabs.close(third, replacement: blank)
        #expect(tabs.selected == first)
        tabs.close(first, replacement: blank)
        #expect(tabs.ids == [blank])
        #expect(tabs.selected == blank)
    }

    @Test func theNinthTabDoesNotChangeSelectionAndCloseOthersKeepsTheSelectedTab() {
        var tabs = BrowserTabSelection(first: UUID())
        for _ in 1..<8 { tabs.add(UUID()) }
        let chosen = tabs.selected
        let addedNinth = tabs.add(UUID())
        #expect(!addedNinth)
        #expect(tabs.ids.count == 8)
        #expect(tabs.selected == chosen)
        tabs.closeOthers()
        #expect(tabs.ids == [chosen])
        #expect(tabs.canAdd)
    }
}
