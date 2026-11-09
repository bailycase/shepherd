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
            // Each width SwiftUI asks (the column's, the window's minimum) is measured once per edit, in two samples.
            let measured = counts["layout.composerFieldMeasured", default: 0]
            #expect(measured <= 4, "\"\(letter)\" measured the field \(measured) times: \(counts)")
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
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
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
        #expect(letters["layout.composerFieldInvalidated", default: 0] == 0, "five letters on one line invalidated the field's size: \(letters)")

        SHRenderProbe.start()
        #expect(SHReturnKey.insertLineBreak(in: editor))
        try await thread.settle()
        let broken = SHRenderProbe.stop()
        #expect(broken["layout.composerFieldInvalidated", default: 0] == 1, "a new line is a new height: \(broken)")
    }

    /// SwiftUI places the field on whole points, so the width it placed is not always the width it proposed.
    @Test(arguments: [400.0, 400.5, 400.25, 333.33, 517.7])
    func aSameHeightKeystrokeInvalidatesNoSizeAtAFractionalWidth(width: CGFloat) async throws {
        final class Draft { var text = "" }
        let draft = Draft()
        let window = OffscreenWindow(size: CGSize(width: 900, height: 300))
        defer { window.close() }
        window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message",
                                      label: "Message", focus: .constant(true), attach: { _ in })
            .frame(width: width))
        try await eventuallyOnMain("the native composer editor to focus") { window.window.firstResponder is ComposerTextField.Editor }
        let editor = try #require(window.window.firstResponder as? ComposerTextField.Editor)
        func type(_ text: String) {
            editor.insertText(text, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
            window.layout()
        }
        type("A line of the draft")
        window.layout()

        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }
        for letter in "hello" { type(String(letter)) }
        let counts = SHRenderProbe.stop()
        #expect(counts["layout.composerFieldInvalidated", default: 0] == 0, "five letters on one line at \(width) pt invalidated the field's size: \(counts)")
        #expect(draft.text == "A line of the draft" + "hello")
    }

    /// Asking again for the same words at the same width measures nothing; new words or a new width measure once.
    @Test func aWidthIsMeasuredOncePerEdit() async throws {
        let thread = ComposerThread(focused: true, animated: false)
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = String(repeating: "The quick brown fox jumps over the lazy dog.\n", count: 1_500)
        try await thread.settle()
        let field = try #require(thread.field)
        thread.type("!")
        try await thread.settle()
        let width = field.alignmentRect(forFrame: field.frame).width
        func measures(_ asks: Int, at width: CGFloat) -> Int {
            SHRenderProbe.start()
            for _ in 0..<asks { _ = field.fittingHeight(width: width) }
            return SHRenderProbe.stop()["layout.composerFieldMeasured", default: 0]
        }
        #expect(measures(5, at: width) == 0, "the width the edit measured is answered from its measure")
        #expect(measures(5, at: width / 2) == 2, "a new width is measured once, in the two samples that decide its height")
        thread.type("!")
        try await thread.settle()
        #expect(measures(5, at: width) == 0, "the edit that follows measured the width again")
        #expect(measures(5, at: width / 2) == 2, "...and the other width is new words' to measure")
    }

    /// A sample of the words decides the height, and it is the height the cell gives the whole draft: the draft's
    /// first lines are the sample's, and the cell stops at the field's eight. The field is made as the thread's composer
    /// makes it, with its line spacing, which a skill chip's attributes carry into the cell.
    @Test func theFieldsHeightIsTheCellsForTheWholeDraft() async throws {
        let lineSpacing = max(0, SHTextStyle.body.lineSpacing - 1)
        final class Draft { var text = "" }
        func lines(_ count: Int, _ line: String = "A line of the draft, long enough to wrap in a narrow column of the composer.") -> String {
            Array(repeating: line, count: count).joined(separator: "\n")
        }
        let cjk = "这是一个很长的句子，用来检查换行与高度的计算是否正确，" + String(repeating: "输入", count: 40)
        let drafts: [(name: String, text: String)] = [
            ("empty", ""), ("one line", "A line of the draft."), ("three lines", lines(3)), ("eight lines", lines(8)),
            ("nine lines", lines(9)), ("thirty lines", lines(30)), ("a 64 KB draft", lines(900)),
            ("a 3,000-character paragraph", String(repeating: "word ", count: 600)),
            ("a skill and ten lines", "fix /skill:debug now\n" + lines(10)),
            ("a skill in a long paragraph", "fix /skill:debug now " + String(repeating: "word ", count: 900)),
            ("a skill after the first sample", lines(40) + "\nthen run /skill:debug now"),
            ("cjk lines", (1...12).map { _ in cjk }.joined(separator: "\n")),
            ("a cjk skill and ten lines", "修复 /skill:debug 然后\n" + lines(10, cjk)),
            ("lines of nothing wide", String(repeating: "\u{200B}", count: 3_000) + String(repeating: "\n", count: 10) + "end"),
        ]
        let editing = Draft(), idle = Draft()
        let editingWindow = OffscreenWindow(size: CGSize(width: 900, height: 300))
        let idleWindow = OffscreenWindow(size: CGSize(width: 900, height: 300))
        defer { editingWindow.close(); idleWindow.close() }
        func show(_ window: OffscreenWindow, _ draft: Draft, focused: Bool) {
            window.show(ComposerTextField(text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message",
                                          label: "Message", focus: .constant(focused), attach: { _ in }, lineSpacing: lineSpacing))
        }
        func composerField(in window: OffscreenWindow) -> ComposerTextField.Field? {
            func walk(_ view: NSView) -> ComposerTextField.Field? {
                if let field = view as? ComposerTextField.Field { return field }
                for sub in view.subviews { if let field = walk(sub) { return field } }
                return nil
            }
            return walk(window.host)
        }
        show(editingWindow, editing, focused: true)
        try await eventuallyOnMain("the native composer editor to focus") { editingWindow.window.firstResponder is ComposerTextField.Editor }
        show(idleWindow, idle, focused: false)
        let field = try #require(composerField(in: editingWindow))
        let reference = try #require(composerField(in: idleWindow))
        SHRenderProbe.start()
        defer { SHRenderProbe.stop() }

        for draft in drafts {
            editing.text = draft.text
            show(editingWindow, editing, focused: true)
            idle.text = draft.text
            show(idleWindow, idle, focused: false)
            #expect(field.currentEditor() != nil, "\(draft.name): the field is editing")
            #expect(reference.currentEditor() == nil, "\(draft.name): the reference is idle")
            for width in [300.0, 790.0] {
                let whole = reference.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
                field.lastMeasuredCharacters = 0
                #expect(field.fittingHeight(width: width) == whole, "\(draft.name) at \(width) pt")
                if draft.name.hasPrefix("lines of nothing") {
                    #expect(field.lastMeasuredCharacters > SHComposerFit.firstSample, "the sample grew past its first \(SHComposerFit.firstSample) characters")
                }
            }
        }
    }

    /// The drafts a field holds, by the name a failure reports.
    private static let heldDrafts: [String: String] = [
        "a chip first and three lines": "fix /skill:debug now\nLine 1 of the draft\nLine 2 of the draft\nLine 3 of the draft",
        "a chip first and thirty lines": "fix /skill:debug now\n" + (1...30).map { "Line \($0) of the draft" }.joined(separator: "\n"),
        "a chip after the first sample": String(repeating: "A line of the draft, long enough to wrap in a narrow column.\n", count: 60)
            + "then run /skill:debug now",
        "three plain lines": "Line 1 of the draft\nLine 2 of the draft\nLine 3 of the draft",
    ]

    /// A focused field is as tall as the idle one for the draft it holds, a skill chip set in code included: the
    /// editor draws the chip's lines with the composer's line spacing, and the measure does the same.
    @Test(arguments: ["a chip first and three lines", "a chip first and thirty lines", "a chip after the first sample", "three plain lines"])
    func aFocusedFieldIsAsTallAsAnIdleOne(name: String) async throws {
        let draft = try #require(Self.heldDrafts[name])
        let focused = ComposerThread(focused: true, animated: false)
        let idle = ComposerThread(focused: false, animated: false)
        defer { focused.close(); idle.close() }
        try await focused.waitUntilReady()
        try await idle.waitUntilReady()
        let empty = try #require(focused.field).frame.height
        focused.store.draft = draft
        idle.store.draft = draft
        try await focused.settle()
        try await idle.settle()
        let editing = try #require(focused.field), resting = try #require(idle.field)
        #expect(editing.currentEditor() != nil, "the focused field is editing")
        #expect(resting.currentEditor() == nil, "the idle field is not")
        #expect(editing.frame.height > empty, "the draft grew the field")
        #expect(editing.frame.height == resting.frame.height, "focused \(editing.frame.height) pt, idle \(resting.frame.height) pt")
    }

    /// Words typed in are plain text in the editor, a skill's name among them: the field is as tall as the same
    /// lines without a skill's name, not as tall as chips would make them.
    @Test func aTypedSkillNameIsMeasuredAsTheEditorHoldsIt() async throws {
        func fieldHeight(typing line: String) async throws -> CGFloat {
            let thread = ComposerThread(focused: true, animated: false)
            defer { thread.close() }
            try await thread.waitUntilReady()
            let editor = try #require(thread.focusedEditor)
            for n in 1...4 {
                if n > 1 { #expect(SHReturnKey.insertLineBreak(in: editor)) }
                thread.type(line)
            }
            try await thread.settle()
            let field = try #require(thread.field)
            #expect(field.currentEditor() != nil, "\"\(line)\": the field is editing")
            return field.frame.height
        }
        let skill = try await fieldHeight(typing: "fix /skill:debug now")
        let plain = try await fieldHeight(typing: "fix skill:debug now")
        #expect(skill == plain, "typed skill names \(skill) pt, the same lines without them \(plain) pt")
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
