#if canImport(AppKit)
import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import ShepherdUI

/// The focused composer card's line and ring are layers on the Mac. At rest they draw what the shapes
/// they replaced drew (the iPhone and iPad client still draws those), corners included: SwiftUI's rounded
/// rectangles have continuous corners, and the ring's is inset by minus its width, which grows its radius by it.
@Suite("Composer focus layers")
@MainActor
struct ComposerFocusLayersTests {
    private static let card = CGRect(x: 0, y: 0, width: 120, height: 60)
    private static let density: CGFloat = 4
    /// The most coverage (of 255) one pixel may differ by. The two draw the same curve; a circular corner where the shape's
    /// is continuous differs by 98 on the line and 192 on the ring, a ring radius three points short by more.
    private static let tolerance = 8

    /// What `draw` fills of a bitmap of `size` points, one coverage value (0...255) per pixel, four pixels to the point.
    private static func coverage(of size: CGSize, _ draw: (CGContext) -> Void) -> [Int] {
        let width = Int(size.width * density), height = Int(size.height * density)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return [] }
        context.scaleBy(x: density, y: density)
        draw(context)
        return (0..<width * height).map { Int(data.load(fromByteOffset: $0 * 4 + 3, as: UInt8.self)) }
    }

    /// The largest difference in coverage between the layer's drawing of `part` over `frame` and what `shape` fills there.
    private static func largestDifference(of part: SHComposerFocusView.Part, from shape: CGPath, in frame: CGRect) -> Int {
        let view = SHComposerFocusView(part: part)
        view.frame = frame
        view.update(focused: true, color: CGColor(gray: 0, alpha: 1), rest: CGColor(gray: 0, alpha: 1), hairline: SH.hairline(1), fades: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let layer = coverage(of: frame.size) { view.drawn.render(in: $0) }
        let drawn = coverage(of: frame.size) { context in
            context.addPath(shape)
            context.fillPath()
        }
        #expect(layer.count == drawn.count && layer.contains { $0 > 0 }, "the layer drew something")
        return zip(layer, drawn).map { abs($0 - $1) }.max() ?? .max
    }

    @Test func theRingDrawsWhatTheShapeItReplacedDrew() {
        let ring = SHComposerMetrics.focusRing
        let frame = CGRect(origin: .zero, size: Self.card.insetBy(dx: -ring, dy: -ring).size)
        // The shape was behind the card: a rounded rectangle of the card's radius and the ring's width, inset by minus the ring's width.
        let was = RoundedRectangle(cornerRadius: SH.Radius.m + ring).inset(by: -ring)
            .path(in: CGRect(origin: CGPoint(x: ring, y: ring), size: Self.card.size)).cgPath
        #expect(Self.largestDifference(of: .ring, from: was, in: frame) <= Self.tolerance)
    }

    @Test func theLineDrawsWhatTheCardsBorderDrew() {
        // `shBorder`: the card's rounded rectangle inset by half a hairline, stroked a hairline wide.
        let width = SH.hairline(1)
        let was = RoundedRectangle(cornerRadius: SH.Radius.m).inset(by: width / 2).path(in: Self.card)
            .strokedPath(StrokeStyle(lineWidth: width)).cgPath
        #expect(Self.largestDifference(of: .line, from: was, in: Self.card) <= Self.tolerance)
    }
}
#endif
