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

    /// A keystroke in a long draft lays out the draft's first lines, not the draft: the field is as tall as
    /// its eight lines need.
    @Test func aKeystrokeMeasuresOnlyTheFirstLines() async throws {
        let thread = ComposerThread(focused: true, animated: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 1_500)
        try await thread.settle()
        let field = try #require(thread.field)

        for letter in "hello" {
            field.lastMeasuredCharacters = 0
            SHRenderProbe.start()
            thread.type(String(letter))
            try await thread.settle()
            let counts = SHRenderProbe.stop()
            let measured = counts["layout.composerFieldMeasured", default: 0]
            #expect(measured <= 2, "\"\(letter)\" measured the field \(measured) times: \(counts)")
            #expect(field.lastMeasuredCharacters <= 8_192, "\"\(letter)\" measured \(field.lastMeasuredCharacters) characters")
        }
        #expect(thread.store.draft.hasSuffix("dog.\nhello"))
    }

    @Test func aPasteMeasuresOnlyTheLinesTheFieldShows() async throws {
        let thread = ComposerThread(focused: true, animated: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        let field = try #require(thread.field)
        let empty = thread.composerInset
        let paste = String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 11_000)

        field.lastMeasuredCharacters = 0
        thread.type(paste)
        try await thread.settle()
        #expect(thread.store.draft == paste)
        #expect(field.lastMeasuredCharacters <= 8_192, "the paste measured \(field.lastMeasuredCharacters) characters")
        #expect(thread.composerInset > empty, "the field grew to show the pasted lines")
    }

    /// The field's size changes with its height, not with its words: a keystroke that keeps the height
    /// asks nothing to measure the field again.
    @Test func aSameHeightKeystrokeInvalidatesNoSize() async throws {
        let thread = ComposerThread(focused: true, animated: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.type("A line of the draft")
        try await thread.settle()
        let editor = try #require(thread.focusedEditor)

        SHRenderProbe.start()
        for letter in "hello" {
            thread.type(String(letter))
            try await thread.settle()
        }
        let letters = SHRenderProbe.stop()
        print("composerFieldInvalidated per same-height key: \(letters["layout.composerFieldInvalidated", default: 0]) in 5, composerControlsMinimum: \(letters["layout.composerControlsMinimum", default: 0])")
        #expect(letters["layout.composerFieldInvalidated", default: 0] == 0, "five letters on one line invalidated the field's size: \(letters)")

        SHRenderProbe.start()
        #expect(SHReturnKey.insertLineBreak(in: editor))
        try await thread.settle()
        let broken = SHRenderProbe.stop()
        #expect(broken["layout.composerFieldInvalidated", default: 0] == 1, "a new line is a new height: \(broken)")
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
