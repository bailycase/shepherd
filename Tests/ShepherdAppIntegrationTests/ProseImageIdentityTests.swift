import AppKit
import ImageIO
import ShepherdTestSupport
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import ShepherdUI

@Suite("Prose image identity", .mainActorExclusive)
@MainActor
struct ProseImageIdentityTests {
    @Test func changingToACachedSourceReplacesTheDisplayedPixels() async throws {
        let folder = try makeScratchDirectory("prose-images")
        func image(_ name: String, blue: Bool) throws -> URL {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let pixels = try #require(rep.bitmapData)
            for y in 0..<32 { for x in 0..<32 {
                let offset = y * rep.bytesPerRow + x * 4
                pixels[offset] = blue ? 0 : 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = blue ? 255 : 0
                pixels[offset + 3] = 255
            } }
            let url = folder.appendingPathComponent(name)
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
            return url
        }
        let first = try image("first.png", blue: false), second = try image("second.png", blue: true)
        _ = await NWProseThumbnails.load(second, pixels: 32)
        let state = SourceState(source: first.path)
        let window = OffscreenWindow(size: CGSize(width: 100, height: 100),
                                     ImageFixture(state: state).environment(\.nwProseFileRoot, folder))
        defer { window.close() }
        func coloredPixels(blue: Bool) -> Int {
            window.layout()
            guard let bitmap = window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds) else { return 0 }
            window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
            guard let image = bitmap.cgImage,
                  let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (0..<(image.width * image.height)).count { index in
                let red = pixels[index * 4], b = pixels[index * 4 + 2]
                return blue ? b > 200 && red < 40 : red > 200 && b < 40
            }
        }
        try await eventuallyOnMain("first image to draw red") { coloredPixels(blue: false) > 100 }
        state.source = second.path
        try await eventuallyOnMain("cached second image to replace the first pixels") { coloredPixels(blue: true) > 100 }
        #expect(coloredPixels(blue: false) == 0)
    }
}

@MainActor @Observable
private final class SourceState {
    var source: String
    init(source: String) { self.source = source }
}

private struct ImageFixture: View {
    let state: SourceState
    var body: some View {
        NWProseImageView(image: NWProseImage(alt: "image", source: state.source))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
