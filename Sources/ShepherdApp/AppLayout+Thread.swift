import SwiftUI

/// The thread column and its composer (NWThread and NWComposer boards). The components' own
/// sizes are `NWThreadMetrics` and `NWComposerMetrics` in ShepherdUI.
extension AppLayout {
    // Composer and its menus
    /// Space under the composer card, and the fade above it.
    static let composerBottom: CGFloat = 16
    static let composerFade: CGFloat = 48
    /// A menu opens this far above the card.
    static let menuGap: CGFloat = 8
}
