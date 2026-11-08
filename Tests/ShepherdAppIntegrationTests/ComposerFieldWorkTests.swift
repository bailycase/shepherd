import AppKit
import Foundation
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// What the composer's field copies out of its editor or cell (`text.composerFieldCopied`), and the
/// paths on which its update still compares the whole draft. A long draft pays for every copy.
@Suite("Composer field work", .serialized, .mainActorExclusive)
@MainActor
struct ComposerFieldWorkTests {
    @Test func aKeystrokeCopiesTheFieldsWordsOnce() async throws {
        let thread = ComposerThread(focused: true, animated: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 1_500)
        try await thread.settle()
        let editor = try #require(thread.focusedEditor as? ComposerTextField.Editor)
        #expect(editor.string == thread.store.draft, "the field shows the long draft")

        for letter in "hello" {
            SHRenderProbe.start()
            thread.type(String(letter))
            try await thread.settle()
            let counts = SHRenderProbe.stop()
            #expect(counts["text.composerFieldCopied"] == 1, "\"\(letter)\" copied the field's words \(counts["text.composerFieldCopied", default: 0]) times: \(counts)")
        }
        #expect(thread.store.draft.hasSuffix("dog.\nhello"))
    }

    @Test func aPublishedDraftIsNewOnlyWhenItsWordsChange() {
        let field = ComposerTextField.Field(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        field.publish("fix /skill:debug now")
        #expect(field.revision == 1)
        field.publish("fix /skill:debug now")
        #expect(field.revision == 1, "the same words are not a new draft")
        field.publish("fix /skill:debug nowx")
        #expect(field.revision == 2)
        #expect(field.published == "fix /skill:debug nowx")
        #expect(!field.trustsPublished, "a field that is not editing has no editor to trust")
    }

    /// Every update that does not trust the field's last published words compares them as it always did.
    @Test func aFieldEditedBehindItsBindingIsRestoredFromTheBinding() async throws {
        final class Draft { var text = "hello" }
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
        editor.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        #expect(draft.text == "hello!")

        // Characters that change without a didChangeText: nothing published them.
        editor.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        draft.text = "hello!"
        render()
        try await eventuallyOnMain("the binding's words to replace what the field holds") { editor.string == "hello!" }
    }

    /// A field that is not editing reads its cell on every update, as it always did.
    @Test func anIdleFieldReadsItsCellOnEachUpdate() async throws {
        final class Draft { var text = "fix /skill:debug now" }
        let draft = Draft()
        let window = OffscreenWindow(size: CGSize(width: 500, height: 200))
        defer { window.close() }
        func render() {
            window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message",
                                          label: "Message", focus: .constant(false), attach: { _ in }))
        }
        render()
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        render()
        #expect(SHRenderProbe.count("text.composerFieldCopied") == 1, "an idle update compares the cell once: \(SHRenderProbe.counts)")
    }
}
