import SwiftUI
#if os(macOS)
import AppKit
#endif

// A file row's "Open in <app> ▾" (OpenInD, OpenInD2): while the pointer is over a file the agent read or changed, a split
// button opens it in the app its type opens in, and the chevron lists the other apps that open it. A pick opens the file
// there and becomes the default for its type. The row's own click still opens the file in Shepherd. The Mac only, and only
// where the agent's files are on this Mac (`shProseFileRoot` set) and the app supplies `shOpenIn`.

#if os(macOS)
/// An app a file can open in: its bundle identifier, name and icon (menu-sized).
public struct SHOpenInApp: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let icon: NSImage?

    public init(id: String, name: String, icon: NSImage?) {
        self.id = id
        self.name = name
        self.icon = icon
    }
}

/// Where a file opens: its app, and what a pick from the menu becomes the default for (".md files").
public struct SHOpenInTarget: Equatable {
    public let app: SHOpenInApp
    public let scope: String

    public init(app: SHOpenInApp, scope: String) {
        self.app = app
        self.scope = scope
    }
}

/// What the Open in button does, supplied by the app.
public struct SHOpenIn: Equatable {
    /// The app `open(url, nil)` uses, and the scope a pick sets.
    public var target: (URL) -> SHOpenInTarget
    /// Every app that opens `url`, the menu's list.
    public var choices: (URL) -> [SHOpenInApp]
    /// Open `url` in its type's app (nil), or in the app with this id, which becomes its type's default.
    public var open: (URL, String?) -> Void
    /// Choose an app that isn't listed; it opens the file and becomes the default.
    public var other: (URL) -> Void
    private let id = UUID()

    public init(target: @escaping (URL) -> SHOpenInTarget, choices: @escaping (URL) -> [SHOpenInApp],
                open: @escaping (URL, String?) -> Void, other: @escaping (URL) -> Void) {
        self.target = target; self.choices = choices; self.open = open; self.other = other
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

extension EnvironmentValues {
    /// nil where files open nowhere but Shepherd (previews, a remote host's thread).
    @Entry public var shOpenIn: SHOpenIn? = nil
    /// Previews only: the row path drawn as if the pointer were over it.
    @Entry var shOpenInHoverPath: String? = nil
}

/// The split button: "Open in Zed" opens the file, the chevron lists the apps.
struct SHOpenInButton: View {
    let url: URL
    let actions: SHOpenIn

    var body: some View {
        let sh = Color.sh
        let target = actions.target(url)
        HStack(spacing: 0) {
            Button { actions.open(url, nil) } label: {
                HStack(spacing: SH.Space.xs) {
                    icon(target.app)
                    Text("Open in \(target.app.name)").lineLimit(1)
                }
                .font(.sh(.caption, weight: .medium))
                .foregroundStyle(sh.textPrimary)
                .padding(.horizontal, SH.Space.m)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url.path)
            .accessibilityLabel("Open \(url.lastPathComponent) in \(target.app.name)")
            SHHairline(.vertical, color: sh.lineStrong)
            Menu {
                Section("Open \(url.lastPathComponent) in") {
                    ForEach(actions.choices(url)) { app in
                        Toggle(isOn: Binding(get: { app.id == target.app.id }, set: { _ in actions.open(url, app.id) })) {
                            Label { Text(app.name) } icon: { icon(app) }
                        }
                    }
                }
                Divider()
                Button("Other App…") { actions.other(url) }
                Divider()
                Text("Your pick opens the file and becomes the default for \(target.scope).")
            } label: {
                Image(systemName: "chevron.down")
                    .font(.sh(.micro, weight: .semibold))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: SHOpenInMetrics.chevronWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Choose an app for \(url.lastPathComponent)")
        }
        .frame(height: SHOpenInMetrics.height)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(sh.lineStrong, radius: SH.Radius.s)
        .fixedSize()
    }

    @ViewBuilder private func icon(_ app: SHOpenInApp) -> some View {
        if let image = app.icon {
            Image(nsImage: image).resizable().frame(width: SHOpenInMetrics.icon, height: SHOpenInMetrics.icon)
        }
    }
}

/// Shows the button over a file row's trailing edge while the pointer is over it, `trailing` in from the row's end (past
/// its stat). `width` is the button's, for the row to keep its path clear of; 0 while it isn't shown.
struct SHOpenInOverlay: ViewModifier {
    let path: String?
    let hovering: Bool
    let trailing: CGFloat
    @Binding var width: CGFloat
    @Environment(\.shOpenIn) private var actions
    @Environment(\.shProseFileRoot) private var root
    @Environment(\.shOpenInHoverPath) private var previewPath

    func body(content: Content) -> some View {
        content.overlay(alignment: .trailing) {
            if hovering || (previewPath != nil && previewPath == path),
               let actions, let path, let url = SHOpenIn.resolve(path, root: root) {
                SHOpenInButton(url: url, actions: actions)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    .onDisappear { width = 0 }
                    .padding(.trailing, trailing)
            }
        }
    }
}

extension SHOpenIn {
    /// The file a row names, on this device: nil where the agent's files aren't here (`root` nil), for a folder, and for a
    /// file that is gone. A relative path is the agent's (against its folder) or a recorded turn's (against the repository's
    /// top level, a folder above it), so the nearest folder up to the repository's top that holds it wins.
    public static func resolve(_ path: String, root: URL?, fileManager: FileManager = .default) -> URL? {
        guard let root, !path.isEmpty else { return nil }
        func file(_ url: URL) -> URL? {
            var directory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue ? url : nil
        }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return file(URL(fileURLWithPath: expanded).standardizedFileURL) }
        // The agent's folder, then each folder above it up to the repository's top (`.git` a folder, or a file in a worktree);
        // outside a repository, only the agent's folder.
        var folders = [root.standardizedFileURL]
        var top: URL? = nil
        var folder = folders[0]
        while true {
            if fileManager.fileExists(atPath: folder.appending(path: ".git").path) { top = folder; break }
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            guard folder.path != "/", parent.path != folder.path else { break }
            folder = parent
            folders.append(folder)
        }
        if top == nil { folders = [folders[0]] }
        return folders.lazy.compactMap { file($0.appending(path: expanded).standardizedFileURL) }.first
    }
}
#endif

extension View {
    /// A file row's Open in button while `hovering` (see `SHOpenInOverlay`); nothing on iOS.
    func shOpenIn(_ path: String?, hovering: Bool, trailing: CGFloat, width: Binding<CGFloat>) -> some View {
        #if os(macOS)
        modifier(SHOpenInOverlay(path: path, hovering: hovering, trailing: trailing, width: width))
        #else
        self
        #endif
    }
}

/// The Open in button (OpenInD): 22pt, a 14pt app icon, the chevron's 18pt segment; its menu's icons at the menu's 16pt.
public enum SHOpenInMetrics {
    public static let height: CGFloat = 22
    public static let icon: CGFloat = 14
    public static let menuIcon: CGFloat = 16
    public static let chevronWidth: CGFloat = 18
}
