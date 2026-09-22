import AppKit
import Testing
@testable import ShepherdApp

/// The navigation keyDown fast path bypasses the main menu, so a matching
/// mistake here would either swallow ordinary keystrokes or steal chords
/// from the terminal. These tests pin the pure classifier and the physical
/// digit mapping it relies on.
@Suite("Navigation key fast path")
@MainActor
struct NavigationKeyTests {
    private let next = ShortcutAction.nextAgent.defaultChord // ⌘↓
    private let previous = ShortcutAction.previousAgent.defaultChord // ⌘↑

    private func classify(
        digit: Int? = nil,
        chord: KeyChord? = nil,
        modifiers: NSEvent.ModifierFlags = []
    ) -> ShepherdViewModel.NavigationKeyAction? {
        ShepherdViewModel.navigationKeyAction(
            digit: digit,
            chord: chord,
            modifiers: modifiers,
            next: next,
            previous: previous
        )
    }

    // MARK: Digit families

    @Test func commandDigitIsAgentJump() {
        #expect(classify(digit: 3, modifiers: .command) == .agentDigit(3))
    }

    @Test func controlShiftDigitIsMachineJump() {
        #expect(classify(digit: 2, modifiers: [.control, .shift]) == .machineJump(2))
    }

    /// ⌃1–9 selected shells; with shells gone it is terminal input again.
    @Test func controlDigitFallsThroughToTheTerminal() {
        #expect(classify(digit: 5, modifiers: [.control]) == nil)
    }

    /// A bare digit is terminal input; extra modifiers make it a different
    /// chord. Neither may be consumed.
    @Test func digitsWithOtherModifiersFallThrough() {
        #expect(classify(digit: 1) == nil)
        #expect(classify(digit: 1, modifiers: [.command, .option]) == nil)
        #expect(classify(digit: 1, modifiers: [.command, .shift]) == nil)
        #expect(classify(digit: 1, modifiers: [.control, .shift, .option]) == nil)
    }

    // MARK: Adjacent agent chords

    @Test func nextAndPreviousChordsMatch() {
        #expect(classify(chord: next, modifiers: .command) == .adjacentAgent(1))
        #expect(classify(chord: previous, modifiers: .command) == .adjacentAgent(-1))
    }

    /// Plain arrows and other chords are terminal input and fall through.
    @Test func unrelatedChordsFallThrough() {
        #expect(classify(chord: KeyChord(key: "down")) == nil)
        #expect(classify(chord: KeyChord(key: "down", command: true, shift: true)) == nil)
        #expect(classify(chord: KeyChord(key: "a", command: true), modifiers: .command) == nil)
        #expect(classify() == nil)
    }

    // MARK: Physical digit mapping

    @Test func digitKeyCodesMapToDigitRow() {
        // ANSI digit-row key codes 1–9.
        let expected: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        ]
        for (code, digit) in expected {
            #expect(KeyChord.digit(keyCode: code) == digit)
        }
        #expect(KeyChord.digit(keyCode: 29) == nil) // 0 — no family uses it
        #expect(KeyChord.digit(keyCode: 125) == nil) // ↓
        #expect(KeyChord.digit(keyCode: 0) == nil) // a
    }

    /// The badge reveal and the fast path share this conversion.
    @Test func chordModifierFlagsRoundTrip() {
        #expect(KeyChord(key: "1", control: true).modifierFlags == [.control])
        #expect(
            KeyChord(key: "d", command: true, shift: true, option: true, control: true).modifierFlags
                == [.command, .shift, .option, .control]
        )
        #expect(KeyChord(key: "x").modifierFlags == [])
    }
}
