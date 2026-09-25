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
