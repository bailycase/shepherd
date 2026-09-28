import CoreGraphics
import Testing
@testable import DesignSurfaceKit

struct DesignRenderLimitsTests {
    @Test func tallDocumentsFitButUnsafeNativeAllocationsAreRefused() {
        for height in [8001.0, 10000] {
            let size = CGSize(width: 816, height: height)
            #expect(DesignRenderLimits.accepts(size))
            #expect(DesignRenderLimits.pixels(size, scale: 2)?.height == Int(height * 2))
        }
        #expect(DesignRenderLimits.accepts(CGSize(width: 794, height: 112300)), "100 A4 pages still lay out for PDF")
        #expect(DesignRenderLimits.pixels(CGSize(width: 794, height: 112300), scale: 2) == nil, "PDF-sized layout isn't one huge bitmap")
        for size in [CGSize(width: 1e100, height: 300), CGSize(width: CGFloat.infinity, height: 300),
                     CGSize(width: 8000, height: 100000), CGSize(width: -1, height: 300)] {
            #expect(!DesignRenderLimits.accepts(size))
            #expect(DesignRenderLimits.pixels(size, scale: 2) == nil)
        }
        #expect(DesignRenderLimits.pixels(CGSize(width: 400, height: 300), scale: .infinity) == nil)
    }
}
