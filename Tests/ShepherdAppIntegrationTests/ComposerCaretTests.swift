import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The composer's field with its caret kept (⌫ at the start of the words takes the last chip
/// back): a draft replaced from outside the field (a mention chosen, a command picked) still
/// leaves the caret at its end, as it did before the caret was kept.
@Suite("Composer caret", .mainActorExclusive)
@MainActor
struct ComposerCaretTests {
    @Test func hiddenComposerStylesWaitForRevealWithoutReplacingTheDraft() async throws {
        let window = OffscreenWindow()
        defer { window.close() }
        let container = NSView(frame: window.host.bounds)
        window.window.contentView = container
        let field = ComposerTextField.Field(frame: container.bounds)
        container.addSubview(field)
        let light = ComposerTextField.Style(appearance: .light, scale: 1, text: .sh.textPrimary,
            placeholderColor: .sh.textTertiary, caret: .sh.textPrimary, placeholder: "Light", lineSpacing: 0)
        var dark = light
        dark.appearance = .dark
        dark.scale = 1.3
        dark.placeholder = "Dark"
        field.updateStyle(light)
        field.stringValue = "Keep this draft"
        let original = try #require(field.placeholderAttributedString)
        field.updateStyle(light)
        #expect(field.placeholderAttributedString === original, "An unchanged update must not allocate another attributed placeholder")
        container.isHidden = true
        window.window.appearance = NSAppearance(named: .darkAqua)
        field.updateStyle(dark)
        #expect(field.placeholderAttributedString === original)
        container.isHidden = false
        try await eventuallyOnMain("pending style applied on native reveal") { field.placeholderAttributedString?.string == "Dark" }
        #expect(field.placeholderAttributedString?.string == "Dark")
        #expect(field.stringValue == "Keep this draft")
        let reference = ComposerTextField.Field(frame: container.bounds)
        reference.stringValue = field.stringValue
        reference.updateStyle(dark)
        #expect(field.intrinsicContentSize.height == reference.intrinsicContentSize.height)
        #expect(field.font?.pointSize == SHTextStyle.body.size * dark.scale)
    }

    @Test func aReentrantBindingRenderCannotOverwriteTheNativeEditBeingPublished() async throws {
        final class Draft {
            var text = ""
            var renders = 0
            var reenter = false
            var valueDuringRender: String?
            var editorDuringRender: String?
        }
        let draft = Draft()
        let window = OffscreenWindow(size: CGSize(width: 500, height: 200))
        defer { window.close() }
        func render() {
            draft.renders += 1
            window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { value in
                if draft.reenter {
                    // Observation notifies during willSet, while its getter still returns
                    // the old value. Force that render synchronously on every supported OS.
                    render()
                    draft.valueDuringRender = draft.text
                    draft.editorDuringRender = (window.window.firstResponder as? NSTextView)?.string
                }
                draft.text = value
            }), placeholder: "Render \(draft.renders)", label: "Message", focus: .constant(true), attach: { _ in }))
        }
        render()
        try await eventuallyOnMain("the native composer editor to focus") {
            window.window.firstResponder is ComposerTextField.Editor
        }
        let editor = try #require(window.window.firstResponder as? ComposerTextField.Editor)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("hello", forType: .string)
        editor.pasteboard = { clipboard }
        draft.reenter = true
        editor.paste(nil)
        #expect(draft.valueDuringRender == "", "the reentrant render really saw the pre-publication value")
        #expect(draft.editorDuringRender == "hello")
        #expect(editor.string == "hello")
        #expect(draft.text == "hello")
        #expect(window.window.firstResponder === editor)

        // A genuine replacement after native publication is still applied normally.
        draft.reenter = false
        draft.text = "External replacement"
        render()
        try await eventuallyOnMain("the external draft to replace native text") { editor.string == draft.text }
        #expect(editor.selectedRange() == NSRange(location: draft.text.utf16.count, length: 0))
    }

    /// ⇧↩ and ⌥↩ reach the field through `SHReturnKey.insertLineBreak(in:)`, the call the composer's
    /// key handler makes with the field editor holding the keyboard. Nothing here posts a key event.
    /// A SwiftUI field editor answers ↩ and ⇧↩ (`insertNewline:`) with no line at all, so the
    /// handler adds the line itself, at the caret or over a selection, and never sends.
    @Test(arguments: [0, 5])
    func aLineBreakReplacesTheSelectionAtTheCaretAndKeepsTheDraftUnsent(selectionLength: Int) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        vm.focusedPaneID = agents[0].piPane.id
        let store = vm.threadStores.store(for: agents[0].agent.id)
        store.draft = "beforeafter"
        var found: NSTextView?
        try await eventuallyOnMain("the composer field to mount") {
            ListPerf.settle(window)
            found = window.window.firstResponder as? NSTextView
            return found?.string == "beforeafter"
        }
        let editor = try #require(found)
        let sent = store.sentCount
        editor.setSelectedRange(NSRange(location: 6, length: selectionLength))

        #expect(SHReturnKey.insertLineBreak(in: editor))

        let expected = selectionLength == 0 ? "before\nafter" : "before\n"
        try await eventuallyOnMain("the line break to reach the draft") {
            ListPerf.settle(window)
            return store.draft == expected
        }
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0), "the caret follows the line")
        #expect(store.sentCount == sent)
    }

    /// An input method with marked text owns ↩ (it commits the composition): no line is added.
    @Test func anInputMethodComposingHoldsTheLineBreakBack() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        vm.focusedPaneID = agents[0].piPane.id
        var found: NSTextView?
        try await eventuallyOnMain("the composer to take the keyboard") {
            ListPerf.settle(window)
            found = (window.window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
            return found != nil
        }
        let editor = try #require(found)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        let before = editor.string

        #expect(!SHReturnKey.insertLineBreak(in: editor))
        #expect(editor.string == before)
    }

    /// The New thread page's field gets the same line: the prompt takes it at the caret, and
    /// nothing starts.
    @Test func aLineBreakOnTheNewThreadPageIsInThePromptAndStartsNothing() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: ShepherdState(spaces: [space]))
        vm.openNewThread()
        let draft = vm.newThread
        draft.prompt = "beforeafter"
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), NewThreadPage(vm: vm, chrome: PageHeaderChrome()))
        defer { window.close() }
        var found: NSTextView?
        try await eventuallyOnMain("the page's field to take the keyboard") {
            window.layout()
            found = window.window.firstResponder as? NSTextView
            return found?.string == "beforeafter"
        }
        let editor = try #require(found)
        editor.setSelectedRange(NSRange(location: 6, length: 0))

        #expect(SHReturnKey.insertLineBreak(in: editor))

        try await eventuallyOnMain("the line break to reach the prompt") {
            window.layout()
            return draft.prompt == "before\nafter"
        }
        #expect(!draft.starting && vm.state.agents.isEmpty, "a line break never starts the thread")
    }

    /// The field publishes its words as a native string and its caret as UTF-16 offsets of the
    /// draft (a chip spans its whole token), so a key converts nothing to `String.Index`.
    @Test func typingKeepsTheDraftNativeAndTheCaretAsOffsets() async throws {
        final class Draft { var text = "" }
        let draft = Draft()
        let caret = ComposerCaret()
        let window = OffscreenWindow(size: CGSize(width: 500, height: 200))
        defer { window.close() }
        func render() {
            window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }), caret: caret,
                                          placeholder: "Message", label: "Message", focus: .constant(true), attach: { _ in }))
        }
        render()
        try await eventuallyOnMain("the native composer editor to focus") { window.window.firstResponder is ComposerTextField.Editor }
        let editor = try #require(window.window.firstResponder as? ComposerTextField.Editor)

        editor.insertText("héllo wörld", replacementRange: editor.selectedRange())
        #expect(draft.text == "héllo wörld")
        #expect(draft.text.isContiguousUTF8)
        #expect(caret.range == NSRange(location: 11, length: 0))

        editor.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(caret.range == NSRange(location: 2, length: 0))

        draft.text = "fix /skill:debug now"
        render()
        try await eventuallyOnMain("the skill to become a chip") { editor.string == "fix \u{FFFC} now" }
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(caret.range == NSRange(location: 16, length: 0), "the caret after the chip sits after its whole token")
        editor.setSelectedRange(NSRange(location: 4, length: 1))
        #expect(caret.range == NSRange(location: 4, length: 12), "a selected chip spans its token")
    }

    /// A caret written to `ComposerCaret` (not by the field) moves the editor on the next update,
    /// across a chip, and never past the words the editor holds.
    @Test func aCaretSetOutsideTheFieldMovesTheEditorThere() async throws {
        final class Draft { var text = "" }
        let draft = Draft()
        let caret = ComposerCaret()
        let window = OffscreenWindow(size: CGSize(width: 500, height: 200))
        defer { window.close() }
        func render() {
            window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }), caret: caret,
                                          placeholder: "Message", label: "Message", focus: .constant(true), attach: { _ in }))
        }
        render()
        try await eventuallyOnMain("the native composer editor to focus") { window.window.firstResponder is ComposerTextField.Editor }
        let editor = try #require(window.window.firstResponder as? ComposerTextField.Editor)
        draft.text = "fix /skill:debug naïve 日本語"
        render()
        try await eventuallyOnMain("the skill to become a chip") { editor.string == "fix \u{FFFC} naïve 日本語" }
        let words = (editor.string as NSString).length

        caret.range = NSRange(location: 16, length: 0)
        render()
        try await eventuallyOnMain("the editor to move past the chip") { editor.selectedRange() == NSRange(location: 5, length: 0) }

        caret.range = NSRange(location: 400, length: 0)
        render()
        try await eventuallyOnMain("the editor to stop at the end of its words") {
            editor.selectedRange() == NSRange(location: words, length: 0)
        }
    }

    /// A draft replaced while the field is not editing leaves no caret: the offsets the field wrote
    /// belong to the draft it replaced.
    @Test func aDraftReplacedWhileTheFieldIsNotEditingForgetsTheCaret() async throws {
        final class Draft { var text = "" }
        let draft = Draft()
        let caret = ComposerCaret()
        let window = OffscreenWindow(size: CGSize(width: 500, height: 200))
        defer { window.close() }
        func render() {
            window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }), caret: caret,
                                          placeholder: "Message", label: "Message", focus: .constant(false), attach: { _ in }))
        }
        draft.text = "héllo wörld"
        render()
        caret.range = NSRange(location: 3, length: 0)
        render()
        #expect(caret.range == NSRange(location: 3, length: 0), "the same draft keeps its caret")

        draft.text = "ok"
        render()
        #expect(caret.range == nil)
    }

    /// ⌫ at the start of the words takes the last chip back, reading the caret the field wrote;
    /// anywhere else it deletes a character.
    @Test(arguments: [(0, true), (5, false)] as [(Int, Bool)])
    func backspaceTakesTheLastChipBackOnlyAtTheStartOfTheWords(caretAt: Int, takesBack: Bool) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        vm.focusedPaneID = agents[0].piPane.id
        var found: ComposerTextField.Editor?
        try await eventuallyOnMain("the composer to take the keyboard") {
            ListPerf.settle(window)
            found = window.window.firstResponder as? ComposerTextField.Editor
            return found != nil
        }
        let editor = try #require(found)
        let store = vm.threadStores.store(for: agents[0].agent.id)
        let piece = try #require(DesignReference(string: "shepherd-design-ref://local/d1/A.dc.html#2:0/1@4"))
        #expect(store.attach(reference: NativeAttachedReference(reference: piece, label: "A")))

        editor.insertText("héllo", replacementRange: NSRange(location: NSNotFound, length: 0))
        ListPerf.settle(window)
        #expect(store.draft == "héllo")
        editor.setSelectedRange(NSRange(location: caretAt, length: 0))

        let delete = try #require(editor.keys[.delete])
        let result = delete(ComposerTextField.Press(modifiers: [], editor: editor))
        #expect(result == (takesBack ? .handled : .ignored))
        #expect(store.attachedReferences.isEmpty == takesBack)
    }

    /// The composer's body no longer reads the draft; the field's host does, so words that arrive
    /// from outside (a terminal command's text, a restored draft) still reach the focused editor.
    @Test func wordsAddedFromOutsideReachTheField() async throws {
        let thread = ComposerThread(focused: true)
        defer { thread.close() }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the field to take the keyboard") { thread.focusedEditor?.isFieldEditor == true }
        let editor = try #require(thread.focusedEditor)

        thread.store.draft = "hello"
        try await eventuallyOnMain("the field to show the first words") { editor.string == "hello" }
        try await thread.settle()
        thread.store.draft = "hello world"
        try await eventuallyOnMain("the field to show the words added from outside") { editor.string == "hello world" }
        #expect(editor.selectedRange() == NSRange(location: 11, length: 0), "the caret follows them to the end")
    }

    @Test func aDraftReplacedFromOutsideTheFieldLeavesTheCaretAtItsEnd() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        vm.focusedPaneID = agents[0].piPane.id
        var found: NSTextView?
        try await eventuallyOnMain("the composer to take the keyboard") {
            ListPerf.settle(window)
            found = (window.window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
            return found != nil
        }
        let editor = try #require(found)
        let store = vm.threadStores.store(for: agents[0].agent.id)

        editor.insertText("Match the funnel in @fun", replacementRange: NSRange(location: NSNotFound, length: 0))
        ListPerf.settle(window)
        #expect(store.draft == "Match the funnel in @fun")
        #expect(editor.selectedRange() == NSRange(location: 24, length: 0))

        let chosen = "Match the funnel in @Checkout funnel dashboard › A · Funnel first › "
        store.draft = chosen
        try await eventuallyOnMain("the field to show the chosen words") {
            ListPerf.settle(window)
            return editor.string == chosen
        }
        #expect(editor.selectedRange() == NSRange(location: (chosen as NSString).length, length: 0))

        // The caret moved to the start, then the draft shortened under it: still a caret the field can hold.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        ListPerf.settle(window)
        store.draft = "Match"
        try await eventuallyOnMain("the field to show the shorter draft") {
            ListPerf.settle(window)
            return editor.string == "Match"
        }
        #expect(NSMaxRange(editor.selectedRange()) <= 5)
    }
}
