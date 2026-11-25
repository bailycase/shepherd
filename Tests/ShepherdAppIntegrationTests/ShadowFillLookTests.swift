import AppKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing

/// The lift's shadows are cast by Core Animation from a path set at layout (`SHShadowFill`), where SwiftUI's `.shadow` drew them
/// offscreen from the fill's alpha. Both must draw the same pixels: the card, its two shadows, its place on the window.
@Suite("Lift shadow look", .mainActorExclusive)
@MainActor
struct ShadowFillLookTests {
    private static let size = CGSize(width: 240, height: 180)

    /// `shLift` as it was drawn before: two fills of the shape, each with a SwiftUI shadow.
    private struct SwiftUILift<S: Shape>: View {
        let shape: S
        var body: some View {
            ZStack {
                shape.fill(Color.sh.bgRaised).shadow(color: .sh.liftFar, radius: 10, y: 6)
                shape.fill(Color.sh.bgRaised).shadow(color: .sh.liftNear, radius: 1, y: 1)
            }
        }
    }

    private struct Board<Card: View>: View {
        @ViewBuilder let card: () -> Card
        var body: some View {
            card()
                .frame(width: 140, height: 90)
                .frame(width: ShadowFillLookTests.size.width, height: ShadowFillLookTests.size.height)
                .background(Color.sh.bgWindow)
        }
    }

    private func pixels(_ view: some View, dark: Bool) -> [UInt8] {
        let window = OffscreenWindow(size: Self.size, dark: dark, view.environment(\.colorScheme, dark ? .dark : .light))
        defer { window.close() }
        for _ in 0..<3 { ListPerf.settle(window) }
        let bitmap = window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds)!
        window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
        let count = bitmap.pixelsWide * bitmap.pixelsHigh * 4
        return Array(UnsafeBufferPointer(start: bitmap.bitmapData, count: count))
    }

    /// How far apart two renders are: the largest channel difference, and how many channel values differ by more than 1.
    private func difference(_ a: [UInt8], _ b: [UInt8]) -> (largest: Int, beyondOne: Int) {
        var largest = 0, beyond = 0
        for (x, y) in zip(a, b) {
            let d = abs(Int(x) - Int(y))
            largest = max(largest, d)
            if d > 1 { beyond += 1 }
        }
        return (largest, beyond)
    }

    @Test(arguments: [false, true])
    func aRoundedLiftDrawsTheSameShadowsSwiftUIDid(dark: Bool) {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xl)
        let before = pixels(Board { SwiftUILift(shape: shape) }, dark: dark)
        let after = pixels(Board { Color.clear.shLift(shape) }, dark: dark)
        #expect(before.count == after.count)
        let (largest, beyond) = difference(before, after)
        // Core Animation's blur and SwiftUI's differ by a level or two in a few shadow pixels (of 255).
        #expect(largest <= 4 && beyond <= before.count / 1000, "largest channel difference \(largest), \(beyond) of \(before.count) channels differ by more than 1")
    }

    /// The capsule's two round ends are anti-aliased by Core Animation's shape layer rather than SwiftUI's: a few edge pixels differ.
    @Test(arguments: [false, true])
    func aCapsuleLiftDrawsTheSameShadowsSwiftUIDid(dark: Bool) {
        let before = pixels(Board { SwiftUILift(shape: Capsule()) }, dark: dark)
        let after = pixels(Board { Color.clear.shLift(Capsule()) }, dark: dark)
        let (largest, beyond) = difference(before, after)
        #expect(largest <= 12 && beyond <= before.count / 250, "largest channel difference \(largest), \(beyond) of \(before.count) channels differ by more than 1")
    }
}
