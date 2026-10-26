import AppKit
import Foundation
import SwiftUI
import ShepherdUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Files viewer word wrap and Markdown preview", .mainActorExclusive)
@MainActor
struct FilesViewerWrapAndPreviewTests {

    // MARK: - Helpers

    private func editor(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView, !text.isEditable, text.isSelectable { return text }
        for child in view.subviews {
            if let found = editor(in: child) { return found }
        }
        return nil
    }

    /// An exit test attaches the accessibility client before asking for SwiftUI's rendered text.
    private func containsText(_ substring: String, in view: NSView) -> Bool {
        AccessibilityNode.all(under: view).contains {
            // Check rendered text, not a scroll view's or window's accessibility summary.
            ($0.role == NSAccessibility.Role.staticText.rawValue || $0.role == "AXHeading")
                && ($0.label?.contains(substring) == true || $0.value?.contains(substring) == true)
        }
    }

    private func toggleMarkdownPreview(in view: NSView) throws {
        let control = try #require(ControlPress.controls(in: view).first { $0.label == "Markdown preview" })
        #expect(control.isEnabled)
        #expect(control.node.press())
    }

    /// The used rect height from the layout manager — the actual content height,
    /// not the frame (which may include blank space).
    private func usedContentHeight(_ text: NSTextView) -> CGFloat {
        guard let layout = text.layoutManager, let container = text.textContainer else { return text.frame.height }
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height
    }

    /// Count of line fragment rects the layout manager produces for a given logical line.
    private func fragmentCount(for logicalLine: Int, in text: NSTextView) -> Int {
        guard let layout = text.layoutManager, let storage = text.textStorage else { return 0 }
        // Find the character range for this logical line
        let string = storage.string as NSString
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        var currentLine = 0
        var searchStart = 0
        while currentLine < logicalLine && searchStart < string.length {
            string.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: searchStart, length: 0))
            searchStart = lineEnd
            currentLine += 1
        }
        if searchStart >= string.length && logicalLine > currentLine { return 0 }
        string.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: searchStart, length: 0))
        let charRange = NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
        guard charRange.length > 0 else { return 1 }
        let glyphRange = layout.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        // Count distinct line fragment rects
        var fragments = 0
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in
            fragments += 1
        }
        return max(1, fragments)
    }

    // MARK: - Word wrap

    @Test func wordWrapTogglesTextContainerTracking() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let longLine = String(repeating: "abcdefghij ", count: 50) // ~550 chars
        let file = root.appendingPathComponent("wide.txt")
        try (longLine + "\nshort\n").write(to: file, atomically: true, encoding: .utf8)

        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)

        let saved = AppSettings.shared.filesWordWrap
        defer { AppSettings.shared.filesWordWrap = saved }
        AppSettings.shared.filesWordWrap = false

        let window = OffscreenWindow(size: CGSize(width: 400, height: 300), dark: false,
                                     FilesTab(model: model))
        defer { window.close() }

        try await eventuallyOnMain("code view appears unwrapped") {
            window.layout()
            guard let text = editor(in: window.host) else { return false }
            return text.string.hasPrefix("abcdefghij") && text.textContainer?.widthTracksTextView == false
        }

        let text = try #require(editor(in: window.host))
        #expect(text.isHorizontallyResizable, "unwrapped text is horizontally resizable")
        // Unwrapped: the long line should be a single fragment
        #expect(fragmentCount(for: 0, in: text) == 1, "unwrapped long line is one fragment")
        let unwrappedContentHeight = usedContentHeight(text)

        // Toggle wrap ON
        AppSettings.shared.filesWordWrap = true

        try await eventuallyOnMain("code view switches to wrapped") {
            window.layout()
            guard let text = editor(in: window.host) else { return false }
            return text.textContainer?.widthTracksTextView == true && !text.isHorizontallyResizable
        }

        // Wrapped: the long line must now produce multiple fragments
        let wrappedFragments = fragmentCount(for: 0, in: text)
        #expect(wrappedFragments > 1, "wrapped long line produces \(wrappedFragments) fragments, expected >1")
        // Content height must increase when lines wrap
        let wrappedContentHeight = usedContentHeight(text)
        #expect(wrappedContentHeight > unwrappedContentHeight,
                "wrapped content (\(wrappedContentHeight)) taller than unwrapped (\(unwrappedContentHeight))")
        // Width must be constrained to the scroll view
        let scroll = try #require(text.enclosingScrollView)
        #expect(abs(text.frame.width - scroll.contentSize.width) < 2,
                "wrapped text width matches scroll view")
    }

    @Test func wordWrapPreservesLogicalLineNumbersAndSelection() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lines.swift")
        let source = "let a = 1\nlet b = 2\nlet c = 3\n"
        try source.write(to: file, atomically: true, encoding: .utf8)

        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)

        let saved = AppSettings.shared.filesWordWrap
        defer { AppSettings.shared.filesWordWrap = saved }
        AppSettings.shared.filesWordWrap = true

        let window = OffscreenWindow(size: CGSize(width: 500, height: 300), dark: true,
                                     FilesTab(model: model))
        defer { window.close() }

        try await eventuallyOnMain("wrapped source loads") {
            window.layout()
            guard let text = editor(in: window.host) else { return false }
            return text.string == source
        }

        let text = try #require(editor(in: window.host))
        #expect(text.string == source, "source text unchanged by wrapping")
        text.setSelectedRange(NSRange(location: 0, length: source.utf16.count))
        #expect(text.selectedRange().length == source.utf16.count, "full-text selection works")
        #expect(text.usesFindBar, "find bar available in wrap mode")
        #expect(text.textContainerInset.width > SH.Space.m, "gutter inset present")
    }

    @Test func wordWrapResizeReflowsMeasurably() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reflow.txt")
        // Long enough that even wide windows wrap, and narrow windows wrap much more
        let longLine = String(repeating: "word ", count: 200) // ~1000 chars
        try (longLine + "\n").write(to: file, atomically: true, encoding: .utf8)

        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)

        let saved = AppSettings.shared.filesWordWrap
        defer { AppSettings.shared.filesWordWrap = saved }
        AppSettings.shared.filesWordWrap = true

        // Start narrow
        let window = OffscreenWindow(size: CGSize(width: 400, height: 600), dark: false,
                                     FilesTab(model: model))
        defer { window.close() }

        try await eventuallyOnMain("wrapped content loads") {
            window.layout()
            guard let text = editor(in: window.host) else { return false }
            return text.string.hasPrefix("word") && text.textContainer?.widthTracksTextView == true
        }

        let text = try #require(editor(in: window.host))
        let narrowFragments = fragmentCount(for: 0, in: text)
        let narrowUsedHeight = usedContentHeight(text)
        #expect(narrowFragments > 1, "narrow window wraps the long line into \(narrowFragments) fragments")

        // Widen — fewer fragments, shorter content
        window.window.setContentSize(CGSize(width: 900, height: 600))
        window.layout()
        try await eventuallyOnMain("text reflows to wider width") {
            window.layout()
            return true
        }
        let wideFragments = fragmentCount(for: 0, in: text)
        let wideUsedHeight = usedContentHeight(text)
        #expect(wideFragments < narrowFragments,
                "wider window: \(wideFragments) fragments < narrow \(narrowFragments)")
        #expect(wideUsedHeight < narrowUsedHeight,
                "wider window: used height \(wideUsedHeight) < narrow \(narrowUsedHeight)")

        // Narrow again — must grow back
        window.window.setContentSize(CGSize(width: 400, height: 600))
        window.layout()
        try await eventuallyOnMain("text reflows back to narrow") {
            window.layout()
            return true
        }
        let backNarrowFragments = fragmentCount(for: 0, in: text)
        let backNarrowHeight = usedContentHeight(text)
        #expect(backNarrowFragments > wideFragments,
                "re-narrowed: \(backNarrowFragments) fragments > wide \(wideFragments)")
        #expect(backNarrowHeight > wideUsedHeight,
                "re-narrowed: used height \(backNarrowHeight) > wide \(wideUsedHeight)")
        // Text unchanged through all resizes
        #expect(text.string.hasPrefix("word"))
    }

    // MARK: - Markdown preview

    @Test func markdownPreviewShowsRenderedContent() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self().markdownPreviewShowsRenderedContentScenario() }
        }
    }

    private func markdownPreviewShowsRenderedContentScenario() async throws {
        AccessibilityNode.enable()
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("README.md")
        try "# Hello World\n\nSome **bold** paragraph.\n".write(to: file, atomically: true, encoding: .utf8)

        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)

        let savedPreview = AppSettings.shared.filesMarkdownPreview
        defer { AppSettings.shared.filesMarkdownPreview = savedPreview }

        // Source mode: NSTextView with raw markdown
        AppSettings.shared.filesMarkdownPreview = false
        let window = OffscreenWindow(size: CGSize(width: 600, height: 400), dark: false,
                                     FilesTab(model: model))
        defer { window.close() }

        try await eventuallyOnMain("source mode shows raw markdown") {
            window.layout()
            return editor(in: window.host)?.string.contains("# Hello World") == true
        }

        // Press the real toolbar control, not just its preference.
        try toggleMarkdownPreview(in: window.host)
        #expect(AppSettings.shared.filesMarkdownPreview)
        try await eventuallyOnMain("preview renders heading text") {
            window.layout()
            // Code editor must be absent AND rendered content must appear
            return editor(in: window.host) == nil
                && containsText("Hello World", in: window.host)
        }
        // The rendered text should also contain the paragraph
        #expect(containsText("bold", in: window.host) || containsText("paragraph", in: window.host),
                "preview renders paragraph content")

        // Switch back through the same control.
        try toggleMarkdownPreview(in: window.host)
        #expect(!AppSettings.shared.filesMarkdownPreview)
        try await eventuallyOnMain("source mode restores raw markdown") {
            window.layout()
            return editor(in: window.host)?.string.contains("# Hello World") == true
        }
    }

    @Test func markdownPreviewUpdatesAcrossFiles() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self().markdownPreviewUpdatesAcrossFilesScenario() }
        }
    }

    private func markdownPreviewUpdatesAcrossFilesScenario() async throws {
        AccessibilityNode.enable()
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let md1 = root.appendingPathComponent("one.md")
        let md2 = root.appendingPathComponent("two.md")
        try "# First File\n\nAlpha content.\n".write(to: md1, atomically: true, encoding: .utf8)
        try "# Second File\n\nBeta content.\n".write(to: md2, atomically: true, encoding: .utf8)

        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        let savedPreview = AppSettings.shared.filesMarkdownPreview
        defer { AppSettings.shared.filesMarkdownPreview = savedPreview }
        AppSettings.shared.filesMarkdownPreview = true

        await model.select(path: md1.path)
        let window = OffscreenWindow(size: CGSize(width: 600, height: 400), dark: true,
                                     FilesTab(model: model))
        defer { window.close() }

        try await eventuallyOnMain("first file rendered") {
            window.layout()
            return editor(in: window.host) == nil
                && containsText("First File", in: window.host)
        }
        #expect(containsText("Alpha", in: window.host), "first file body visible")
        // Second file's content must NOT be present yet
        #expect(!containsText("Second File", in: window.host), "second file not leaked")

        // Switch to second file
        await model.select(path: md2.path)
        try await eventuallyOnMain("second file rendered with correct content") {
            window.layout()
            return containsText("Second File", in: window.host)
                && containsText("Beta", in: window.host)
                && !containsText("First File", in: window.host)
                && !containsText("Alpha", in: window.host)
        }
        // First file's content should be gone
        #expect(!containsText("First File", in: window.host), "first file content cleared")
        #expect(!containsText("Alpha", in: window.host), "first file body cleared")
    }

    @Test func markdownPreviewIgnoredForNonMarkdownFiles() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("code.swift")
        try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)

        let savedPreview = AppSettings.shared.filesMarkdownPreview
        defer { AppSettings.shared.filesMarkdownPreview = savedPreview }
        AppSettings.shared.filesMarkdownPreview = true

        let window = OffscreenWindow(size: CGSize(width: 600, height: 400), dark: false,
                                     FilesTab(model: model))
        defer { window.close() }

        try await eventuallyOnMain("non-md file uses code view despite preview on") {
            window.layout()
            return editor(in: window.host)?.string.contains("let x = 1") == true
        }
    }

    @Test func rapidMarkdownFileSwitch() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self().rapidMarkdownFileSwitchScenario() }
        }
    }

    private func rapidMarkdownFileSwitchScenario() async throws {
        AccessibilityNode.enable()
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Create several markdown files
        for i in 1...5 {
            let file = root.appendingPathComponent("file\(i).md")
            try "# Title \(i)\n\nBody of file \(i).\n".write(to: file, atomically: true, encoding: .utf8)
        }

        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()

        let savedPreview = AppSettings.shared.filesMarkdownPreview
        defer { AppSettings.shared.filesMarkdownPreview = savedPreview }
        AppSettings.shared.filesMarkdownPreview = true

        let window = OffscreenWindow(size: CGSize(width: 600, height: 400), dark: false,
                                     FilesTab(model: model))
        defer { window.close() }

        // Rapidly switch through files without waiting for each to finish rendering
        for i in 1...5 {
            await model.select(path: root.appendingPathComponent("file\(i).md").path)
            window.layout()
        }

        // The last file (file5) must be what ends up rendered — not a stale earlier file
        try await eventuallyOnMain("last file wins after rapid switching") {
            window.layout()
            return containsText("Title 5", in: window.host)
                && containsText("Body of file 5", in: window.host)
        }
        // No stale content from earlier files
        #expect(!containsText("Title 1", in: window.host), "stale file 1 not shown")
        #expect(!containsText("Title 3", in: window.host), "stale file 3 not shown")
    }

    @Test func markdownRefreshUpdatesPreview() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self().markdownRefreshUpdatesPreviewScenario() }
        }
    }

    private func markdownRefreshUpdatesPreviewScenario() async throws {
        AccessibilityNode.enable()
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("doc.md")
        try "# Original\n\nFirst version.\n".write(to: file, atomically: true, encoding: .utf8)

        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)

        let savedPreview = AppSettings.shared.filesMarkdownPreview
        defer { AppSettings.shared.filesMarkdownPreview = savedPreview }
        AppSettings.shared.filesMarkdownPreview = true

        let window = OffscreenWindow(size: CGSize(width: 600, height: 400), dark: false,
                                     FilesTab(model: model))
        defer { window.close() }

        try await eventuallyOnMain("original content rendered") {
            window.layout()
            return containsText("Original", in: window.host)
        }

        // Overwrite the file on disk, then refresh
        try "# Updated\n\nSecond version.\n".write(to: file, atomically: true, encoding: .utf8)
        await model.refresh()

        // Selectable SwiftUI text can leave hidden peers in AppKit's AX tree after an
        // update; assert the new heading/body, not the absence of those hidden peers.
        try await eventuallyOnMain("refreshed content rendered") {
            window.layout()
            return containsText("Updated", in: window.host)
                && containsText("Second version", in: window.host)
        }
    }

    // MARK: - Persistence

    @Test func settingsPersistedViaUserDefaults() {
        let defaults = UserDefaults.standard

        let savedWrap = AppSettings.shared.filesWordWrap
        let savedPreview = AppSettings.shared.filesMarkdownPreview
        defer {
            AppSettings.shared.filesWordWrap = savedWrap
            AppSettings.shared.filesMarkdownPreview = savedPreview
        }

        AppSettings.shared.filesWordWrap = true
        #expect(defaults.bool(forKey: "shepherd.files.wordWrap") == true)
        AppSettings.shared.filesWordWrap = false
        #expect(defaults.bool(forKey: "shepherd.files.wordWrap") == false)

        AppSettings.shared.filesMarkdownPreview = true
        #expect(defaults.bool(forKey: "shepherd.files.markdownPreview") == true)
        AppSettings.shared.filesMarkdownPreview = false
        #expect(defaults.bool(forKey: "shepherd.files.markdownPreview") == false)
    }
}
