import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The question dock's keys as the Mac reads them, and what the dock draws from each asker's
/// presentation.
@Suite("Question dock keys")
@MainActor
struct QuestionDockKeysTests {
    static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    struct KeyCase: Sendable, CustomTestStringConvertible {
        var characters: String
        var keyCode: UInt16
        var modifiers: UInt
        var key: NativeQuestionKey?
        var testDescription: String { "\(characters.debugDescription) \(modifiers) → \(String(describing: key))" }

        init(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ key: NativeQuestionKey?) {
            self.characters = characters
            self.keyCode = keyCode
            self.modifiers = modifiers.rawValue
            self.key = key
        }
    }

    nonisolated static let keyCases: [KeyCase] = [
        KeyCase("1", 18, [], .number(1)),
        KeyCase("9", 25, [], .number(9)),
        KeyCase("0", 29, [], nil),
        KeyCase("\r", 36, [], .answer),
        KeyCase("\u{3}", 76, [], .answer),
        KeyCase("\u{1b}", 53, [], .escape),
        KeyCase("a", 0, [], nil),
        // ⌘1–9 select agents, ⇧↩ breaks a line, ⌥ and ⌃ belong to someone else.
        KeyCase("1", 18, .command, nil),
        KeyCase("\r", 36, .shift, nil),
        KeyCase("1", 18, .option, nil),
        KeyCase("\u{1b}", 53, .control, nil),
    ]

    @Test(arguments: keyCases)
    func onlyPlainNumbersReturnAndEscapeAreTheDocks(_ c: KeyCase) {
        let event = Self.key(c.characters, keyCode: c.keyCode, modifiers: NSEvent.ModifierFlags(rawValue: c.modifiers))
        #expect(QuestionKeyMonitor.key(event) == c.key)
    }

    @Test func aKeyFromAnotherWindowIsNotTheDocks() {
        let monitor = QuestionKeyMonitor()
        monitor.perform = { _, _ in true }
        #expect(!monitor.handle(Self.key("1", keyCode: 18)), "no window yet")
    }

    @Test func tooltipsSpellTheDocksKeys() {
        let keys = KeybindingsStore.shared.questionKeys
        #expect(keys == NWQuestionDockKeys(answer: KeybindingsStore.shared.sendDisplay, hide: "Esc"))
    }

    @Test func pisSelectDrawsItsOptionsWithoutANoteOrSomethingElse() {
        let prompt = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "d", kind: .select, title: "Pick", options: ["A (Recommended)\nwhy", "B\nwhy"]))
        let content = QuestionDock.content(prompt, count: 2)
        #expect(content.asker == .agent)
        #expect(content.count == 2)
        #expect(content.kind == .choice)
        #expect(content.options == [NWQuestionDockOption(number: 1, title: "A", detail: "why", recommended: true),
                                    NWQuestionDockOption(number: 2, title: "B", detail: "why")])
        #expect(!content.takesNote && !content.takesOther && content.otherNumber == nil)
        #expect(content.showsAnswer)
        #expect(content.notice == nil)
    }

    @Test(arguments: [
        (NativeThreadDialog(id: "t", kind: .confirm, title: "Q", timeout: 1000), String?.some("The agent may stop waiting for this answer")),
        (NativeThreadDialog(id: "e", kind: .confirm, title: "Q", timeout: 1000, unavailable: "external-editor"),
         "An external editor is open · finish it before answering here"),
        (NativeThreadDialog(id: "p", kind: .select, title: "Q", unavailable: "payload-limit"), "This question is too large to show here"),
        (NativeThreadDialog(id: "n", kind: .input, title: "Q"), nil),
    ])
    func theFooterSaysWhyAQuestionMayNotWait(dialog: NativeThreadDialog, notice: String?) {
        #expect(QuestionDock.content(NativeQuestionPrompt(dialog: dialog)).notice == notice)
    }

    @Test func aSubagentsQuestionIsNamedAndTakesANoteAndSomethingElse() {
        let content = QuestionDock.content(NativeQuestionPrompt(runID: "r", name: "reviewer", question: "Q", options: ["A\nwhy", "B\nwhy"]))
        #expect(content.asker == .subagent("reviewer"))
        #expect(content.takesNote && content.takesOther)
        #expect(content.otherNumber == 3)
    }
}
