/// Whether a window can open another beside it (iPadSplitView). SwiftUI's
/// `supportsMultipleWindows` says yes on both of iPhone Duo's displays, but the system opens
/// windows only on its inner display held upright, where the window is regular width and wider
/// than tall: folded shut (compact) or held sideways, a new window replaces the one showing
/// instead (measured on the iOS 27.1 simulator, where UIKit's own "new window" item hides the
/// same way). Without a hinge, `supportsMultipleWindows` decides.
public enum WindowAvailability {
    public static func canOpenWindows(supportsMultipleWindows: Bool, hinge: Bool, regularWidth: Bool, tallWindow: Bool) -> Bool {
        supportsMultipleWindows && (!hinge || (regularWidth && !tallWindow))
    }
}
