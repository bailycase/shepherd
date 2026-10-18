import AppKit
import UniformTypeIdentifiers

/// Opens a local file in the editor chosen in Settings ▸ Advanced (a bundle identifier), else the
/// file's default app, else TextEdit (a file with no default app still opens somewhere).
public enum EditorOpener {
    /// The app that opens `url`: `editor` when it is installed, else the system's choice.
    @MainActor public static func application(for url: URL, editor: String?) -> URL? {
        let workspace = NSWorkspace.shared
        return editor.flatMap { $0.isEmpty ? nil : workspace.urlForApplication(withBundleIdentifier: $0) }
            ?? workspace.urlForApplication(toOpen: url)
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
    }

    @MainActor public static func open(_ url: URL, editor: String?) async throws {
        guard let app = application(for: url, editor: editor) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Installed text editors, by display name (Settings' list, Open With). Launch Services offers every app that can open text, so
    /// this keeps those that declare themselves an Editor of plain text or source (not a browser, a spreadsheet's CSV, or a notes app
    /// that only views it), installed in an Applications folder (not a test runner's Chrome or a tool's bundled copy).
    @MainActor public static func installedEditors() -> [URL] {
        let workspace = NSWorkspace.shared
        let apps = Set(workspace.urlsForApplications(toOpen: .plainText) + workspace.urlsForApplications(toOpen: .sourceCode))
        let folders = ["/Applications/", "/System/Applications/", NSHomeDirectory() + "/Applications/"]
        return apps.filter { app in folders.contains { app.path.hasPrefix($0) } && isTextEditor(Bundle(url: app)?.infoDictionary) }
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    /// Whether an app's Info.plist claims the Editor role for plain text or source code (or `.txt`), not only for CSV or TSV.
    public static func isTextEditor(_ info: [String: Any]?) -> Bool {
        let text: Set<String> = ["public.plain-text", "public.text", "public.utf8-plain-text", "public.source-code"]
        let tables: Set<String> = ["public.comma-separated-values-text", "public.tab-separated-values-text"]
        let types = info?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return types.contains { type in
            guard type["CFBundleTypeRole"] as? String == "Editor" else { return false }
            let contents = Set(type["LSItemContentTypes"] as? [String] ?? [])
            return (!contents.isDisjoint(with: text) && contents.isDisjoint(with: tables))
                || (type["CFBundleTypeExtensions"] as? [String] ?? []).contains("txt")
        }
    }

    /// "Zed", not "Zed.app".
    public static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}
