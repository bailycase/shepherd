import CoreGraphics
import Foundation
import Testing
@testable import ShepherdApp

/// The picture `board_render` hands an agent: capped in pixels and bytes, a PNG when it fits.
@Suite("Design render images")
struct DesignRenderImageTests {
    /// A deterministic image: flat color, or a pattern no codec squeezes much.
    static func image(_ width: Int, _ height: Int, noisy: Bool) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        if noisy {
            var state: UInt32 = 0x9E3779B9
            for i in stride(from: 0, to: bytes.count, by: 4) {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[i] = UInt8(truncatingIfNeeded: state >> 24)
                bytes[i + 1] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[i + 2] = UInt8(truncatingIfNeeded: state >> 8)
            }
        } else {
            for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = 240; bytes[i + 1] = 246; bytes[i + 2] = 255 }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test func aFlatBoardStaysAPNGAtItsOwnSize() throws {
        let encoded = try #require(DesignRenderImage.encode(Self.image(390, 844, noisy: false)))
        #expect(encoded.isPNG && encoded.mimeType == "image/png" && encoded.width == 390 && encoded.height == 844)
        #expect(encoded.data.count <= DesignRenderImage.maxBytes && encoded.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func aTallBoardIsReducedToTheLongestEdgeKeepingItsProportions() throws {
        let encoded = try #require(DesignRenderImage.encode(Self.image(400, 4_000, noisy: false)))
        #expect(encoded.height == DesignRenderImage.maxEdge && encoded.width == 160)
    }

    @Test func aPhotographicBoardFallsBackToAJPEGWithinTheByteCap() throws {
        let encoded = try #require(DesignRenderImage.encode(Self.image(1_200, 800, noisy: true)))
        #expect(!encoded.isPNG && encoded.mimeType == "image/jpeg" && encoded.data.starts(with: [0xFF, 0xD8]))
        #expect(encoded.data.count <= DesignRenderImage.maxBytes)
        #expect(encoded.width <= 1_200 && encoded.width > 0)
    }

    @Test func whenNoQualityFitsThePictureShrinksUntilItDoes() throws {
        let encoded = try #require(DesignRenderImage.encode(Self.image(1_200, 800, noisy: true), maxBytes: 30_000))
        #expect(encoded.data.count <= 30_000 && encoded.width < 1_200 && encoded.height < 800)
        #expect(Double(encoded.width) / Double(encoded.height) - 1.5 < 0.05, "the proportions hold")
    }

    @Test func aCapNothingCanMeetGivesNoPicture() {
        #expect(DesignRenderImage.encode(Self.image(1_200, 800, noisy: true), maxBytes: 10) == nil)
    }

    @Test(arguments: [(500, "1 KB"), (41_000, "41 KB"), (1_234_567, "1.2 MB")])
    func sizesReadShort(_ bytes: Int, _ words: String) {
        #expect(DesignRenderImage.size(bytes) == words)
    }

    @MainActor
    @Test func aFailureInOneRenderDoesNotStopTheNext() async throws {
        struct Boom: Error {}
        let queue = DesignRenderQueue()
        await #expect(throws: Boom.self) { try await queue.run { throw Boom() } }
        #expect(await queue.run { 7 } == 7)
    }
}
