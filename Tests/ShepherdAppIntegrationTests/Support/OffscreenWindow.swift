import AppKit
import SwiftUI

/// A real window for views that need AppKit layout (Ghostty surfaces, scroll views). It sits
/// far off every screen, borderless, ordered to the back: it never becomes key, never
/// activates the app, and never takes the user's focus. With `deckHosting` its hosting view sizes nothing around it and has no safe
/// area of its own, as the workspace's layouts do (`DeckHost`); otherwise the window measures the whole view tree at its minimum and
/// ideal sizes after changes, as a scene's root does, which a layout's lazy stacks answer by re-estimating their rows.
@MainActor
final class OffscreenWindow {
    let window: NSWindow
    let host: NSHostingView<AnyView>

    init(size: CGSize = CGSize(width: 900, height: 600), dark: Bool? = nil, deckHosting: Bool = false, _ view: some View = EmptyView()) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let dark { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        host = NSHostingView(rootView: AnyView(view))
        if deckHosting {
            host.sizingOptions = []
            host.safeAreaRegions = []
        }
        host.appearance = window.appearance
        window.contentView = host
        window.orderBack(nil)
        layout()
    }

    func show(_ view: some View) {
        host.rootView = AnyView(view)
        layout()
    }

    func layout() {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}
