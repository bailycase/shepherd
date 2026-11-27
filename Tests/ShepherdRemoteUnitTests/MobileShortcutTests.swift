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
            "h", .space, .tab, "n", "w", "`", "[", "]", "3", "4",
            // Minimize, Settings, Quit and Print.
            "m", ",", "q", "p",
            // Standard editing and document movement (including the iPadOS Escape alias).
            "a", "b", "c", "f", "i", "u", "v", "x", "z", ".",
            .upArrow, .downArrow, .leftArrow, .rightArrow, .delete,
        ]
        let reserved = commandKeys.map { KeyboardShortcut($0) } + [
            .cancelAction, .defaultAction,
            KeyboardShortcut(.tab, modifiers: [.command, .shift]),
            KeyboardShortcut("z", modifiers: [.command, .shift]),
            KeyboardShortcut("v", modifiers: [.command, .shift, .option]),
            KeyboardShortcut("s", modifiers: [.command, .control]),
        ]
        if action == .newThread {
            // The File menu replaces the system New Window command for this one chord.
            #expect(action.shortcut == KeyboardShortcut("n"))
        } else {
            #expect(!reserved.contains(action.shortcut))
        }
    }

    @Test func newWindowUsesOptionCommandN() {
        #expect(MobileShortcut.newWindow.shortcut == KeyboardShortcut("n", modifiers: [.command, .option]))
    }

    @Test(arguments: [(MobileShortcut.newThread, "⌘N"), (.newWindow, "⌥⌘N"), (.toggleSidebar, "⇧⌘S"), (.search, "⌘K")])
    func chordsReadAsTheMacShowsThem(action: MobileShortcut, display: String) {
        #expect(action.display == display)
    }
}
