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
        if let text = view as? NSTextView, !text.isEditable, text.isSelectable { return text }
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
        #expect(!text.isEditable && text.isSelectable)
        text.setSelectedRange(NSRange(location: 0, length: first.utf16.count))
        #expect(text.selectedRange().length == first.utf16.count, "selection spans multiple lines")
        #expect(text.textContainerInset.width > NW.Space.m, "the source reserves a line-number gutter")
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
}
