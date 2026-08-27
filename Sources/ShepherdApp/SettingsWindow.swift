import AppKit
import SwiftUI

/// Opening and styling the Settings window.
///
/// Settings is an ordinary `Window` scene rather than SwiftUI's `Settings`
/// scene: that scene forces its own title-bar material and content inset, so
/// its header can never take a theme color — which is the whole point here.
/// The cost is that ⌘, and the app-menu item must be wired by hand, which the
/// command below does.
@MainActor
enum SettingsWindow {
    static let sceneID = "shepherd-settings"

}

/// The app-menu Settings item. Lives in a view so it can use `openWindow`,
/// which is the supported way to show a `Window` scene.
struct SettingsCommandButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: SettingsWindow.sceneID)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Applies Shepherd's window chrome to whatever window hosts this view.
///
/// The Settings window is created by SwiftUI, so it cannot be configured at
/// construction like the main window. Reaching it from inside its own content
/// view keeps the styling independent of how Settings was opened (⌘,, the app
/// menu, or the titlebar button).
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { apply(to: view.window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view.window)
    }

    /// Same contract as the main window: the title bar paints nothing and the
    /// content runs edge to edge beneath the traffic lights, so the strip
    /// above the categories belongs to the theme.
    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(ThemeManager.shared.current.workspaceBg)
        window.toolbar = nil
    }
}
