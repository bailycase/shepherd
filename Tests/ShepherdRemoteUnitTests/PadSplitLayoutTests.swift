import CoreGraphics
import Testing
@testable import ShepherdRemote

/// The iPad split view's shape: the sidebar slides over the thread only in a window taller than
/// it is wide.
@Suite("Pad split layout")
struct PadSplitLayoutTests {
    @Test(arguments: [
        (CGSize(width: 1032, height: 1376), true),  // 13-inch iPad, portrait
        (CGSize(width: 1376, height: 1032), false), // 13-inch iPad, landscape
        (CGSize(width: 507, height: 1032), true),   // half of a landscape iPad in Split View
        (CGSize(width: 1032, height: 1032), false), // a square Stage Manager window
        (CGSize.zero, false),                       // before the first layout
    ])
    func theSidebarOverlaysOnlyATallWindow(window: CGSize, overlays: Bool) {
        #expect(PadSplitLayout.sidebarOverlays(window: window) == overlays)
    }
}
