import AppKit
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Instruction editor identity", .mainActorExclusive)
@MainActor
struct InstructionsEditorIdentityTests {
    @Test
    func switchingEqualDocumentsDoesNotCarryUndoIntoTheNewDocument() async throws {
        let directory = try makeScratchDirectory("instruction-undo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = ScratchDefaults()
        let model = InstructionsModel(store: InstructionsStore(directory: directory),
            remoteHosts: RemoteHostStore(defaults: defaults, connects: false), defaults: defaults)
        await model.refresh()
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 800))
        defer { window.close() }
        window.show(InstructionsSettings(model: model))
        func editor(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.lazy.compactMap(editor).first
        }
        let first = try #require(editor(window.host))
        _ = window.window.makeFirstResponder(first)
        let undo = try #require(first.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        first.insertText("old document", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        first.breakUndoCoalescing()
        undo.beginUndoGrouping()
        first.insertText("", replacementRange: NSRange(location: 0, length: first.string.utf16.count))
        undo.endUndoGrouping()
        #expect(first.string.isEmpty)
        #expect(undo.canUndo, "the source document must have undo history for this regression to be meaningful")
        undo.undo()
        #expect(first.string == "old document")
        undo.redo()
        #expect(first.string.isEmpty)
        #expect(model.text(.agents, on: .local).isEmpty)
        #expect(model.text(.appendSystem, on: .local).isEmpty)
        model.file = .appendSystem
        try await eventuallyOnMain("the destination instruction file to appear") {
            window.layout()
            return editor(window.host)?.accessibilityLabel()?.contains("APPEND_SYSTEM.md") == true
        }
        let second = try #require(editor(window.host))
        #expect(model.text(.appendSystem, on: .local).isEmpty)
        second.undoManager?.undo()
        #expect(second.string.isEmpty)
        #expect(model.text(.appendSystem, on: .local).isEmpty)
        // A retained old editor must still write to its original document, not the selected tab.
        undo.undo()
        #expect(model.text(.agents, on: .local) == "old document")
        #expect(model.text(.appendSystem, on: .local).isEmpty)
        _ = window.window.makeFirstResponder(second)
        let destinationUndo = try #require(second.undoManager)
        destinationUndo.groupsByEvent = false
        destinationUndo.beginUndoGrouping()
        second.insertText("new document", replacementRange: NSRange(location: 0, length: 0))
        destinationUndo.endUndoGrouping()
        #expect(model.text(.appendSystem, on: .local) == "new document")
        #expect(destinationUndo.canUndo)
        destinationUndo.undo()
        #expect(second.string.isEmpty)
        #expect(model.text(.appendSystem, on: .local).isEmpty)
        destinationUndo.redo()
        #expect(model.text(.appendSystem, on: .local) == "new document")
        #expect(model.text(.agents, on: .local) == "old document")
    }
}
