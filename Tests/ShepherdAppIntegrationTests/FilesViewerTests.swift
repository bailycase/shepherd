import AppKit
import Foundation
import SwiftUI
import ShepherdUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Files viewer", .mainActorExclusive)
@MainActor
struct FilesViewerTests {
    private func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, text.usesFindBar, text.isSelectable { return text }
        for child in view.subviews {
            if let found = editor(in: child) { return found }
        }
        return nil
    }

    private func colorCount(_ text: NSTextView) -> Int {
        guard let storage = text.textStorage else { return 0 }
        var colors: Set<String> = []
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let color = value as? NSColor { colors.insert(color.usingColorSpace(.deviceRGB)?.description ?? color.description) }
        }
        return colors.count
    }

    @Test func sourceIsHighlightedSelectableAndSearchableAndRefreshes() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Example.swift")
        let first = "// A real file\nlet title = \"Hello\"\nprint(title)\n"
        try first.write(to: file, atomically: true, encoding: .utf8)
        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)
        let window = OffscreenWindow(size: CGSize(width: 820, height: 600), dark: true, FilesTab(model: model))
        defer { window.close() }
        try await eventuallyOnMain("source text and tree-sitter colors") {
            window.layout()
            guard let text = editor(in: window.host) else { return false }
            return text.string == first && colorCount(text) > 1
        }
        let text = try #require(editor(in: window.host))
        #expect(text.usesFindBar && text.isIncrementalSearchingEnabled)
        #expect(text.isEditable && text.isSelectable, "a local text file edits")
        text.setSelectedRange(NSRange(location: 0, length: first.utf16.count))
        #expect(text.selectedRange().length == first.utf16.count, "selection spans multiple lines")
        #expect(text.textContainerInset.width > SH.Space.m, "the source reserves a line-number gutter")
        #expect(text.frame.width >= text.enclosingScrollView!.contentSize.width)
        #expect(text.frame.height >= text.enclosingScrollView!.contentSize.height)
        window.window.makeFirstResponder(text)
        let find = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(text.performKeyEquivalent(with: find))
        try await eventuallyOnMain("native Find bar opens") { text.enclosingScrollView?.isFindBarVisible == true }
        let second = "// Still four lines\nlet title = \"World\"\nprint(title)\n"
        try second.write(to: file, atomically: true, encoding: .utf8)
        await model.refresh()
        try await eventuallyOnMain("same-path, same-line-count refresh") {
            window.layout()
            guard let refreshed = editor(in: window.host) else { return false }
            return refreshed.string == second && colorCount(refreshed) > 1
        }
        #expect(editor(in: window.host) === text, "refresh updates the native viewer in place")

        let oldScale = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = oldScale }
        let oldFont = try #require(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        ThemeStore.shared.textScale = oldScale * 1.3
        try await eventuallyOnMain("text scale applies to the mounted viewer") {
            window.layout()
            guard let font = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return false }
            return font.pointSize > oldFont.pointSize
        }
        #expect(text.visibleRect.minX == 0,
                "theme/scale updates must preserve the initial horizontal scroll position")
    }

    /// Typing reaches the model, the tab shows it unsaved, and the Save chord in the editor writes the file.
    @Test func typingMarksTheFileUnsavedAndTheSaveChordWritesIt() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Example.swift")
        try "let a = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)
        let window = OffscreenWindow(size: CGSize(width: 820, height: 600), dark: true, FilesTab(model: model))
        defer { window.close() }
        try await eventuallyOnMain("the editor shows the file") {
            window.layout()
            return editor(in: window.host)?.string == "let a = 1\n"
        }
        let text = try #require(editor(in: window.host))
        window.window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 9, length: 0))
        text.insertText("2", replacementRange: text.selectedRange())
        #expect(model.edits[file.path]?.text == "let a = 12\n")
        #expect(model.edits[file.path]?.isDirty == true)
        let chord = KeybindingsStore.shared.chord(for: .saveProjectFile)
        let save = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.window.windowNumber, context: nil,
            characters: chord.key, charactersIgnoringModifiers: chord.key, isARepeat: false, keyCode: 1))
        #expect(text.performKeyEquivalent(with: save))
        try await eventuallyOnMain("the save lands on disk") {
            (try? String(contentsOf: file, encoding: .utf8)) == "let a = 12\n" && model.edits[file.path]?.isDirty == false
        }
        #expect(text.string == "let a = 12\n", "a save leaves the editor's text and caret alone")
    }
}
