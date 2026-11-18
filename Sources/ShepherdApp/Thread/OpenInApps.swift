import AppKit
import ShepherdSessions
import ShepherdUI
import UniformTypeIdentifiers

/// A file row's Open in (OpenInD, OpenInD2): the app a file's type opens in (its pick, else Settings ▸ Advanced's editor, else
/// the file's own default app), the apps its menu lists, and a pick that opens the file and becomes its type's default.
extension SHOpenIn {
    @MainActor static let app = SHOpenIn(
        target: { url in
            let settings = AppSettings.shared
            let app = EditorOpener.application(for: url, editor: settings.editor(for: url)).flatMap(OpenInApps.app)
                ?? SHOpenInApp(id: "", name: "Default App", icon: nil)
            return SHOpenInTarget(app: app, scope: OpenInApps.scope(of: url))
        },
        choices: { url in
            // The app it opens in now heads the list when the list lacks it (an app chosen with Other App…).
            let list = OpenInApps.choices(for: url)
            guard let current = EditorOpener.application(for: url, editor: AppSettings.shared.editor(for: url)).flatMap(OpenInApps.app),
                  !list.contains(where: { $0.id == current.id }) else { return list }
            return [current] + list
        },
        open: OpenInApps.open,
        other: OpenInApps.chooseOther)
}

@MainActor enum OpenInApps {
    /// Apps by bundle path, and each file type's list. Read again after Shepherd comes back to the front, when an app may have
    /// been installed or removed.
    private static var apps: [URL: SHOpenInApp] = [:]
    private static var choices: [String: [SHOpenInApp]] = [:]
    private static var observer: (any NSObjectProtocol)?

    static func app(_ bundle: URL) -> SHOpenInApp? {
        watchForReturn()
        if let app = apps[bundle] { return app }
        guard let id = Bundle(url: bundle)?.bundleIdentifier else { return nil }
        // Menus draw an image at its own size: a copy at the button's icon size.
        let icon = NSWorkspace.shared.icon(forFile: bundle.path).copy() as? NSImage
        icon?.size = NSSize(width: SHOpenInMetrics.menuIcon, height: SHOpenInMetrics.menuIcon)
        let app = SHOpenInApp(id: id, name: EditorOpener.name(of: bundle), icon: icon)
        apps[bundle] = app
        return app
    }

    static func choices(for url: URL) -> [SHOpenInApp] {
        watchForReturn()
        let type = AppSettings.fileType(of: url)
        if let list = choices[type] { return list }
        let list = EditorOpener.applications(toOpen: url).compactMap(app)
        choices[type] = list
        return list
    }

    /// ".md files", or "files named Makefile" for a file without an extension.
    static func scope(of url: URL) -> String {
        url.pathExtension.isEmpty ? "files named \(url.lastPathComponent)" : ".\(url.pathExtension.lowercased()) files"
    }

    /// Opens `url` in its type's app, or in `id`'s, which becomes the type's default.
    static func open(_ url: URL, _ id: String?) {
        let settings = AppSettings.shared
        if let id, !id.isEmpty { settings.editorsByType[AppSettings.fileType(of: url)] = id }
        ShepherdViewModel.openInEditor(url, editor: settings.editor(for: url))
    }

    /// Other App…: any app, chosen in a panel; it opens the file and becomes the type's default.
    static func chooseOther(_ url: URL) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Open"
        panel.message = "Choose an app for \(scope(of: url))"
        guard panel.runModal() == .OK, let app = panel.url, let id = Bundle(url: app)?.bundleIdentifier else { return }
        choices[AppSettings.fileType(of: url)] = nil
        open(url, id)
    }

    private static func watchForReturn() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                apps = [:]
                choices = [:]
            }
        }
    }
}
