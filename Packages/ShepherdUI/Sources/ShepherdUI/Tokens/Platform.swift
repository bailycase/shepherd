import SwiftUI

/// What the platform's input can do. On iOS and iPadOS there may be no pointer at all, so
/// nothing may hide behind hover there: details that show on hover on the Mac show at rest.
public enum NWPlatform {
    #if os(iOS)
    /// Details that the Mac shows while the pointer is over them (a message's time, a turn's
    /// footer, a code block's Copy, a comment's Edit and Delete) show at rest.
    public static let showsHoverDetails = true
    #else
    public static let showsHoverDetails = false
    #endif
}

extension View {
    /// On iOS, grows the hit area of a control drawn `height` (and `width`) points to the 44pt
    /// touch minimum, keeping its drawn size; on the Mac it does nothing.
    public func nwTouchTarget(height: CGFloat, width: CGFloat? = nil) -> some View {
        #if os(iOS)
        let vertical = max(0, (NW.Height.touch - height) / 2)
        let horizontal = width.map { max(0, (NW.Height.touch - $0) / 2) } ?? 0
        return padding(EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal))
            .contentShape(Rectangle())
        #else
        return self
        #endif
    }
}
