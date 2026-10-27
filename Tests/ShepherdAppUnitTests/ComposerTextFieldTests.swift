import AppKit
import SwiftUI
import Testing
@testable import ShepherdApp

/// The composer's AppKit field as an assistive client sees it: AXValue and AXConfirm reach the
/// draft and the Return handler without a field editor.
@Suite("Composer text field accessibility")
@MainActor
struct ComposerTextFieldTests {
    @Test func axValueReachesTheDraftWithoutAFieldEditor() {
        let field = ComposerTextField.Field()
        field.cell = ComposerTextField.Cell(textCell: "")
        var published = 0
        field.editor.changedText = { published += 1 }
        field.setAccessibilityValue("dictated words")
        #expect(field.stringValue == "dictated words")
        #expect(published == 1)
    }

    @Test func axConfirmIsTheReturnKey() {
        let field = ComposerTextField.Field()
        var pressed: EventModifiers?
        field.editor.keys[.return] = { press in pressed = press.modifiers; return .handled }
        #expect(field.accessibilityPerformConfirm())
        #expect(pressed == [])
        field.isEnabled = false
        pressed = nil
        _ = field.accessibilityPerformConfirm()
        #expect(pressed == nil)
    }
}
