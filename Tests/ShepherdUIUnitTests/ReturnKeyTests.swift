import SwiftUI
import Testing
@testable import ShepherdUI

/// What ↩ means in a field whose Return submits (`NWReturnKey`): ⇧↩ and ⌥↩ add a line, a chord
/// that carries ⌘ or ⌃ is not theirs to take, and an input method that is composing keeps ↩.
@Suite("Return key")
struct ReturnKeyTests {
    @Test(arguments: [
        (EventModifiers([]), NWReturnKey.Action.submit),
        ([.shift], .lineBreak),
        ([.option], .lineBreak),
        ([.shift, .option], .lineBreak),
        ([.command], .submit),
        ([.control], .submit),
        ([.command, .control], .submit),
        ([.shift, .command], .system),
        ([.option, .command], .system),
        ([.shift, .control], .system),
        ([.shift, .option, .command], .system),
    ] as [(EventModifiers, NWReturnKey.Action)])
    func aReturnPressMeansWhatItsModifiersSay(modifiers: EventModifiers, expected: NWReturnKey.Action) {
        #expect(NWReturnKey.action(modifiers: modifiers) == expected)
    }

    @Test(arguments: [
        EventModifiers([]), [.shift], [.option], [.command], [.control], [.shift, .command],
    ] as [EventModifiers])
    func anInputMethodThatIsComposingKeepsReturn(modifiers: EventModifiers) {
        #expect(NWReturnKey.action(modifiers: modifiers, composing: true) == .system)
    }
}
