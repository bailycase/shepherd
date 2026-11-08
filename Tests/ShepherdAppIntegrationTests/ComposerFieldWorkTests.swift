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
