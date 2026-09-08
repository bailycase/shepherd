import AppKit
import SwiftUI

/// Opening and styling the Settings window.
///
/// Settings is an ordinary `Window` scene rather than SwiftUI's `Settings`
/// scene: that scene forces its own title-bar material and content inset, so
/// its header can never take a theme color — which is the whole point here.
/// The cost is that ⌘, and the app-menu item must be wired by hand, which the
/// command below does.
/// The app-menu Settings item. Settings is an in-window surface, so the
/// command toggles view state rather than opening a second scene.
struct SettingsCommandButton: View {
    var vm: ShepherdViewModel

    var body: some View {
        Button(vm.showSettings ? "Back to App" : "Settings…") {
            // Diagnostic: settings has been observed opening without a
            // deliberate ⌘, — record exactly which event fired this action
            // (key repeat, synthetic re-dispatch, layout oddity, menu click).
            if let event = NSApp.currentEvent {
                NSLog(
                    "Shepherd: settings toggled by event type=%ld keyCode=%d chars=%@ charsIgnoringMods=%@ mods=0x%lx repeat=%d ts=%f responder=%@",
                    event.type.rawValue,
                    event.type == .keyDown || event.type == .keyUp ? event.keyCode : -1,
                    event.type == .keyDown ? (event.characters ?? "") : "-",
                    event.type == .keyDown ? (event.charactersIgnoringModifiers ?? "") : "-",
                    event.modifierFlags.rawValue,
                    event.type == .keyDown && event.isARepeat ? 1 : 0,
                    event.timestamp,
                    String(describing: NSApp.keyWindow?.firstResponder.map { type(of: $0) })
                )
            } else {
                NSLog("Shepherd: settings toggled with no current event")
            }
            vm.showSettings.toggle()
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
        window.backgroundColor = NSColor(ThemeManager.shared.current.workspaceBg)
        window.toolbar = nil
    }
}
