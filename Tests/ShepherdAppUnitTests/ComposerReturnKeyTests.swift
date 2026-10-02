import SwiftUI
import Testing
@testable import ShepherdApp

/// What a Return press does in the composer's field, decided apart from the field: ⇧↩ and ⌥↩ add
/// a line even with a menu open, ↩ chooses the open menu's row or sends, ⌘↩ (the rebindable
/// `alternateSend`) sends the other way, and an input method that is composing keeps its ↩.
@Suite("Composer return key")
struct ComposerReturnKeyTests {
    struct Press: Sendable {
        var modifiers: EventModifiers = []
        var alternate = KeyChord(key: "return", command: true)
        var menuOpen = false
        var composing = false
        var expected: ComposerReturnKey
        var name: String
    }

    static let table: [Press] = [
        Press(expected: .send(.primary), name: "↩ sends"),
        Press(modifiers: [.shift], expected: .lineBreak, name: "⇧↩ adds a line"),
        Press(modifiers: [.option], expected: .lineBreak, name: "⌥↩ adds a line"),
        Press(modifiers: [.shift, .option], expected: .lineBreak, name: "⇧⌥↩ adds a line"),
        Press(modifiers: [.command], expected: .send(.alternate), name: "⌘↩ sends the other way"),
        Press(modifiers: [.command], alternate: KeyChord(key: "return", command: true, option: true), expected: .send(.primary),
              name: "⌘↩ is a plain send once alternateSend moved to ⌥⌘↩"),
        Press(modifiers: [.command, .option], alternate: KeyChord(key: "return", command: true, option: true), expected: .system,
              name: "⌥⌘↩ is the system's even when alternateSend is bound to it (the key monitor takes it first)"),
        Press(modifiers: [.control], expected: .send(.primary), name: "⌃↩ sends"),
        Press(modifiers: [.shift, .command], expected: .system, name: "⇧⌘↩ is the system's"),
        Press(menuOpen: true, expected: .choose, name: "↩ with a menu open chooses its row"),
        Press(modifiers: [.command], menuOpen: true, expected: .choose, name: "⌘↩ with a menu open chooses its row"),
        Press(modifiers: [.shift], menuOpen: true, expected: .lineBreak, name: "⇧↩ with a menu open adds a line, which closes it"),
        Press(modifiers: [.option], menuOpen: true, expected: .lineBreak, name: "⌥↩ with a menu open adds a line"),
        Press(composing: true, expected: .system, name: "↩ while an input method composes commits its text"),
        Press(modifiers: [.shift], composing: true, expected: .system, name: "⇧↩ while an input method composes is the input method's"),
        Press(menuOpen: true, composing: true, expected: .system, name: "↩ over a menu while composing is the input method's"),
    ]

    @Test(arguments: table)
    func aReturnPressDoesWhatTheComposerSays(press: Press) {
        let action = ComposerReturnKey.action(modifiers: press.modifiers, alternate: press.alternate, menuOpen: press.menuOpen,
                                              composing: press.composing)
        #expect(action == press.expected, "\(press.name)")
    }

    /// Only a line break touches the draft: it never sends, chooses, or leaves the field.
    @Test func onlyAPlainReturnSends() {
        let sends = Self.table.filter { if case .send = $0.expected { true } else { false } }
        #expect(sends.allSatisfy { $0.modifiers.isDisjoint(with: [.shift, .option]) && !$0.menuOpen && !$0.composing })
    }
}
