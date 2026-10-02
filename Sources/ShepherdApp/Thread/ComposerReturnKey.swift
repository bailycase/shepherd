import SwiftUI
import ShepherdUI

/// What a Return press does in the composer's field, decided apart from the field (docs/design/
/// composer.md › Keyboard): ⇧↩ and ⌥↩ add a line (`NWReturnKey`), ↩ chooses the open menu's
/// highlighted row or else sends (queues while pi works), and ⌘↩, the rebindable `alternateSend`,
/// sends the other way. An input method that is composing keeps its ↩.
enum ComposerReturnKey: Equatable {
    /// Adds a line at the caret; sends and chooses nothing.
    case lineBreak
    /// Chooses the highlighted row of the open slash, sign-in or @ menu (nothing when it has none).
    case choose
    case send(ComposerSendKey)
    /// Not the composer's: the system's.
    case system

    /// `alternate` is the chord bound to `alternateSend`; `menuOpen` is whether a menu that lists
    /// rows over the card has the keyboard's ↩; `composing` is whether an input method has marked text.
    static func action(modifiers: EventModifiers, alternate: KeyChord, menuOpen: Bool, composing: Bool) -> ComposerReturnKey {
        switch NWReturnKey.action(modifiers: modifiers, composing: composing) {
        case .lineBreak: .lineBreak
        case .system: .system
        case .submit:
            if menuOpen { .choose }
            else if alternate.matches(key: .return, modifiers: modifiers) { .send(.alternate) }
            else { .send(.primary) }
        }
    }
}
