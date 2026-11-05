import AppKit
import Foundation
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A skill in the draft ("/skill:debug") is one inline chip in the composer's field: the draft
/// stays plain text, ⌫ after the chip takes the whole skill, and the caret never lands inside it.
@Suite("Composer skill chip", .mainActorExclusive)
@MainActor
struct ComposerSkillChipTests {
    @Test func aSkillIsOneChipThatDeletesWhole() async throws {
        final class Draft { var text = "" }
        let draft = Draft()
        let window = OffscreenWindow(size: CGSize(width: 500, height: 200))
        defer { window.close() }
        func render() {
            window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message",
                                          label: "Message", focus: .constant(true), attach: { _ in }))
        }
        render()
        try await eventuallyOnMain("the native composer editor to focus") { window.window.firstResponder is ComposerTextField.Editor }
        let editor = try #require(window.window.firstResponder as? ComposerTextField.Editor)

        draft.text = "fix the login bug /skill:debug "
        render()
        try await eventuallyOnMain("the skill to become a chip") { editor.string == "fix the login bug \u{FFFC} " }
        #expect(editor.textStorage?.attribute(.attachment, at: 18, effectiveRange: nil) is SHSkillChipAttachment)

        // Typing after the chip keeps the skill and adds plain words.
        editor.insertText("and add a test", replacementRange: editor.selectedRange())
        #expect(draft.text == "fix the login bug /skill:debug and add a test")
        #expect(!(editor.textStorage?.attribute(.attachment, at: 21, effectiveRange: nil) is NSTextAttachment), "typed words are not chips")

        // The caret right after the chip: ⌫ takes the whole skill.
        editor.setSelectedRange(NSRange(location: 19, length: 0))
        editor.deleteBackward(nil)
        #expect(draft.text == "fix the login bug  and add a test")
        #expect(editor.string == draft.text)
    }

    /// A draft kept with a skill (a relaunch, a restored send) shows its chip once the field takes the keyboard.
    @Test func aChipSurvivesTheFieldTakingTheKeyboard() async throws {
        final class Draft { var text = "fix /skill:debug now"; var focused = false }
        let draft = Draft()
        let window = OffscreenWindow(size: CGSize(width: 500, height: 200))
        defer { window.close() }
        func render() {
            window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message",
                                          label: "Message", focus: Binding(get: { draft.focused }, set: { draft.focused = $0 }),
                                          attach: { _ in }))
        }
        render()
        draft.focused = true
        render()
        try await eventuallyOnMain("the native composer editor to focus") { window.window.firstResponder is ComposerTextField.Editor }
        let editor = try #require(window.window.firstResponder as? ComposerTextField.Editor)
        #expect(editor.string == "fix \u{FFFC} now")
        #expect(draft.text == "fix /skill:debug now")
    }

    @Test func rangesMapAcrossAChip() throws {
        let font = NSFont.systemFont(ofSize: 13)
        func chips(_ text: String) -> NSAttributedString? {
            SHSkillChips.attributed(text, tokens: ComposerSkillToken.ranges(in: text), name: ComposerSkillToken.name, attributes: [.font: font])
        }
        let shown = try #require(chips("a /skill:debug b"))
        #expect(shown.string == "a \u{FFFC} b")
        #expect(SHSkillChips.text(of: shown) == "a /skill:debug b")
        #expect(SHSkillChips.draftRange(NSRange(location: 3, length: 2), in: shown) == NSRange(location: 14, length: 2))
        #expect(SHSkillChips.fieldRange(NSRange(location: 16, length: 0), in: shown) == NSRange(location: 5, length: 0))
        // A draft offset inside the token lands after the chip.
        #expect(SHSkillChips.fieldRange(NSRange(location: 6, length: 0), in: shown) == NSRange(location: 3, length: 0))
        #expect(chips("costs $5 and/or /tmp") == nil)
    }
}
