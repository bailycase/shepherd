import CoreGraphics

/// The iPad split view's shape (iPadThread, iPadPortrait boards): side by side, or the sidebar
/// sliding over the thread.
public enum PadSplitLayout {
    /// Whether the sidebar slides over the thread: a window taller than it is wide (portrait, or a
    /// narrow Split View or Stage Manager window). `window` is the window's whole size, measured
    /// with the keyboard ignored: the keyboard shortens what content has left, and taking that
    /// for the window's shape turned a portrait iPad into a landscape one the moment the composer
    /// took focus, which restyled the split view and dropped the focus again.
    public static func sidebarOverlays(window: CGSize) -> Bool {
        window.width < window.height
    }
}
