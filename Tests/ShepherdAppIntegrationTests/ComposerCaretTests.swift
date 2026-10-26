import AppKit
import Foundation
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The composer's field with its selection bound (⌫ at the start of the words takes the last
/// chip back): a draft replaced from outside the field (a mention chosen, a command picked)
/// still leaves the caret at its end, as it did before the selection was bound.
@Suite("Composer caret", .mainActorExclusive)
@MainActor
struct ComposerCaretTests {
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
