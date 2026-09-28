import AppKit
import ShepherdProtocol
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Instruction editor identity", .mainActorExclusive)
@MainActor
struct InstructionsEditorIdentityTests {
    @Test func switchingEqualDocumentsDoesNotCarryUndoIntoTheNewDocument() async throws {
        let state = EditorState()
        let window = OffscreenWindow(size: CGSize(width: 600, height: 400))
        defer { window.close() }
        window.show(EditorFixture(state: state))
        func editor(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(editor).first
        }
        let first = try #require(editor(window.host))
        _ = window.window.makeFirstResponder(first)
        first.insertText("old document", replacementRange: NSRange(location: 0, length: 0))
        first.insertText("", replacementRange: NSRange(location: 0, length: first.string.utf16.count))
        #expect(first.string.isEmpty)
        state.file = .appendSystem
        try await eventuallyOnMain("new instruction document to mount") {
            window.layout()
            return editor(window.host) !== first
        }
        let second = try #require(editor(window.host))
        second.undoManager?.undo()
        #expect(second.string.isEmpty)
        #expect(state.text.isEmpty)
    }
}

@MainActor @Observable
private final class EditorState {
    var file = InstructionFile.agents
    var text = ""
}

private struct EditorFixture: View {
    @Bindable var state: EditorState
    var body: some View {
        InstructionsEditor(text: $state.text, saved: "", accessibilityLabel: "Instructions")
            .id(InstructionsModel.DraftKey(machine: .local, file: state.file))
    }
}
