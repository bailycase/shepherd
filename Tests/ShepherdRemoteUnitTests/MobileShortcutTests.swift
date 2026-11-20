import SwiftUI
import Testing
import ShepherdRemote

struct MobileShortcutTests {
    @Test func appChordsAreUnique() {
        let chords = MobileShortcut.allCases.map(\.shortcut)
        #expect(Set(chords).count == chords.count)
    }

    @Test(arguments: MobileShortcut.allCases)
    func appChordsLeaveSystemShortcutsAlone(action: MobileShortcut) {
        let commandKeys: [KeyEquivalent] = [
            // iPadOS Home, search, app switcher, new/close window navigation and screenshots.
            "h", .space, .tab, "w", "`", "[", "]", "3", "4",
            // Standard editing and document movement (including the iPadOS Escape alias).
            "a", "b", "c", "f", "i", "u", "v", "x", "z", ".",
            .upArrow, .downArrow, .leftArrow, .rightArrow, .delete,
        ]
        let reserved = commandKeys.map { KeyboardShortcut($0) } + [
            .cancelAction, .defaultAction,
            KeyboardShortcut(.tab, modifiers: [.command, .shift]),
            KeyboardShortcut("z", modifiers: [.command, .shift]),
            KeyboardShortcut("v", modifiers: [.command, .shift, .option]),
        ]
        #expect(!reserved.contains(action.shortcut))
    }
}
