import AppKit
import SwiftUI

extension EnvironmentValues {
    /// False while the main window cannot be seen (covered, minimized, on another Space, the app
    /// hidden, or ordered out). `MainWindowRoutes` publishes it for the Window scene's content;
    /// anywhere else it stays true.
    @Entry var mainWindowVisible = true
}

/// Reports whether the window hosting it can be seen: once it is in a window, and again each time
/// AppKit changes that window's occlusion. A window partly showing counts as visible.
struct WindowOcclusionReader: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) { view.changed = changed }

    final class ReaderView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            // Never during the view update that mounted this: the report writes state.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            changed(window.occlusionState.contains(.visible))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        /// Behind the whole root view: never the target of a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
