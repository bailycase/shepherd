import Testing
@testable import ShepherdSessions

/// Settings ▸ Advanced ▸ Open files in lists text editors, not every app Launch Services says can open text.
@Suite("Editor list")
struct EditorOpenerTests {
    private func info(_ types: [[String: Any]]) -> [String: Any] { ["CFBundleDocumentTypes": types] }

    @Test func anEditorOfPlainTextOrTxtIsAnEditor() {
        // Zed, TextEdit, and an editor that names only extensions (Trae, VS Code forks).
        #expect(EditorOpener.isTextEditor(info([["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.folder", "public.plain-text"]]])))
        #expect(EditorOpener.isTextEditor(info([["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.text"]]])))
        #expect(EditorOpener.isTextEditor(info([["CFBundleTypeRole": "Editor", "CFBundleTypeExtensions": ["md", "txt"]]])))
    }

    @Test func aViewerASpreadsheetOrAnAppWithoutTypesIsNot() {
        // Chrome views text; Numbers edits CSV, which is plain text; Notes edits only its data.
        #expect(!EditorOpener.isTextEditor(info([["CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.text"]]])))
        #expect(!EditorOpener.isTextEditor(info([["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.comma-separated-values-text", "public.plain-text"]]])))
        #expect(!EditorOpener.isTextEditor(info([["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.data"]]])))
        #expect(!EditorOpener.isTextEditor(nil))
    }
}
