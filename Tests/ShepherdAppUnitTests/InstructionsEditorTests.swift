import AppKit
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Markdown source editor behind Settings ▸ Instructions and the subagent form.
@Suite("Instructions editor")
@MainActor
struct InstructionsEditorTests {
    /// Writing Tools' "compose" affordance for an empty view is a child window that outlived
    /// the editor and floated over every later Settings page; the editor opts out.
    @Test func writingToolsStayOff() {
        for (project, plain) in [(false, false), (true, false), (true, true)] {
            let view = InstructionsEditor.makeTextView(project: project, plain: plain)
            #expect(view.writingToolsBehavior == .none)
            #expect(!view.isRichText)
        }
    }

    private func editor(_ text: String, saved: String) -> (InstructionsTextView, InstructionsEditor.Coordinator) {
        let editor = InstructionsEditor(text: .constant(text), saved: saved, accessibilityLabel: "Instructions")
        let coordinator = editor.makeCoordinator()
        let view = InstructionsEditor.makeTextView(project: false, plain: false)
        view.string = text
        view.textStorage?.delegate = coordinator
        view.delegate = coordinator
        coordinator.restyle(view, saved: saved)
        return (view, coordinator)
    }

    private func settle(_ coordinator: InstructionsEditor.Coordinator) async {
        while let diffing = coordinator.diffing { await diffing.value }
    }

    private func isHeading(_ view: InstructionsTextView, at location: Int) -> Bool {
        let font = view.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        return font?.fontDescriptor.symbolicTraits.contains(.bold) == true || font?.fontName.contains("SemiBold") == true
    }

    /// Typing restyles the edited line only, and the tint's diff runs off the main actor.
    @Test func typingRestylesTheEditedLineAndTintsAsynchronously() async {
        let lines = (0..<1000).map { "line \($0)" }
        let saved = lines.joined(separator: "\n") + "\n"
        let (view, coordinator) = editor(saved, saved: saved)
        #expect(coordinator.diffRuns == 0)
        let start = (saved as NSString).range(of: "line 500").location
        view.setSelectedRange(NSRange(location: start, length: 0))
        view.insertText("# ", replacementRange: NSRange(location: start, length: 0))
        #expect(view.string.contains("# line 500"))
        #expect(isHeading(view, at: start + 2))
        #expect(!isHeading(view, at: 0))
        await settle(coordinator)
        #expect(view.changedLines == [500])
        #expect(coordinator.diffRuns == 1)
    }

    /// A diff superseded by newer typing never lands; the newest text's does.
    @Test func aStaleDiffNeverLands() async {
        let saved = "a\nb\nc\n"
        let (view, coordinator) = editor(saved, saved: saved)
        view.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        view.insertText("y", replacementRange: NSRange(location: 4, length: 0))
        await settle(coordinator)
        #expect(view.string == "xa\nby\nc\n")
        #expect(view.changedLines == [0, 1])
    }

    /// Composing with an input method leaves the marked text's attributes alone until it commits.
    @Test func markedTextWaitsForCommit() async {
        let (view, coordinator) = editor("", saved: "")
        view.setMarkedText("#", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(view.hasMarkedText())
        let marked = view.textStorage?.attributes(at: 0, effectiveRange: nil)
        coordinator.restyle(view, saved: "")
        #expect(view.textStorage?.attributes(at: 0, effectiveRange: nil).count == marked?.count)
        view.unmarkText()
        view.insertText(" Title", replacementRange: NSRange(location: 1, length: 0))
        #expect(!view.hasMarkedText())
        #expect(isHeading(view, at: 2))
        await settle(coordinator)
        #expect(view.changedLines == [0])
    }

    /// Undo puts the saved text back: styled again, and nothing tinted.
    @Test func undoRestoresStylingAndTint() async {
        let saved = "# Title\nbody\n"
        let (view, coordinator) = editor(saved, saved: saved)
        let undo = view.undoManager!
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        view.insertText("more ", replacementRange: NSRange(location: 8, length: 0))
        undo.endUndoGrouping()
        await settle(coordinator)
        #expect(view.changedLines == [1])
        undo.undo()
        #expect(view.string == saved)
        await settle(coordinator)
        #expect(view.changedLines.isEmpty)
        #expect(isHeading(view, at: 2))
    }
}
