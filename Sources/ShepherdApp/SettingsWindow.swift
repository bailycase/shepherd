import AppKit
import SwiftUI
import ShepherdUI

/// The app-menu Settings item. Settings is an in-window surface, so the
/// command toggles view state rather than opening a second scene.
struct SettingsCommandButton: View {
    var vm: ShepherdViewModel

    var body: some View {
        Button(vm.showSettings ? "Back to App" : "Settings…") { vm.showSettings.toggle() }
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
    ///
    /// Since Settings moved in-window, the hosting window here IS the main
    /// window. Never set `isMovableByWindowBackground` on it: the ghostty
    /// surface reports `mouseDownCanMoveWindow`, so background-dragging turns
    /// every text-selection drag inside a terminal into a window move.
    /// Dragging belongs exclusively to the explicit WindowDragGesture strips
    /// (traffic lights, headers); `false` pins that contract.
    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(Color.sh.bgBase)
        window.toolbar = nil
    }
}
