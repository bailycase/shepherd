import CoreGraphics
import Testing
@testable import DesignSurfaceKit

/// The page zoom a live board draws at for each canvas zoom: never below 1 (WebKit's minimum font
/// size would swell small text), and a whole number so the page is exactly the board's size.
@Suite struct DesignRenderScaleTests {
    @Test(arguments: [
        (0.05, 1), (0.1, 1), (0.17, 1), (0.5, 1), (0.99, 1), (1, 1),
        (1.01, 2), (1.37, 2), (2, 2),
        (2.01, 4), (3, 4), (4, 4),
    ] as [(CGFloat, CGFloat)])
    func aZoomDrawsAtAWholeRenderScale(_ zoom: CGFloat, _ scale: CGFloat) {
        #expect(DesignBoardView.renderScale(for: zoom) == scale)
    }

    @Test(arguments: [0, -1, .infinity, .nan] as [CGFloat])
    func aZoomThatIsNoZoomDrawsAtTheBoardsSize(_ zoom: CGFloat) {
        #expect(DesignBoardView.renderScale(for: zoom) == 1)
    }
}
