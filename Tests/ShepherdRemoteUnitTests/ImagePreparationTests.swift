import Foundation
import CoreGraphics
import ImageIO
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Images on their way into a send: clamped, re-encoded, and within the protocol's limits.
@Suite("Image preparation")
struct ImagePreparationTests {
    @Test func aMessageHasRoomForFourImages() {
        #expect([0, 3, 4, 6].map(NativeImagePreparation.room) == [4, 1, 0, 0])
    }

    @Test func aLargeImageIsClampedTo2000PointsAndStaysPNG() throws {
        let png = try #require(Self.png(width: 2400, height: 1200))
        let image = try NativeImagePreparation.prepare(png, name: "Screenshot.png")
        #expect(image.mimeType == "image/png")
        #expect(image.name == "Screenshot.png")
        #expect(image.data.count <= NativeImage.maxBytes)
        #expect(Self.size(image.data) == [2000, 1000])
    }

    @Test func aJPEGStaysAJPEG() throws {
        let jpeg = try #require(Self.encode(width: 300, height: 200, type: "public.jpeg"))
        let image = try NativeImagePreparation.prepare(jpeg, name: "photo.jpeg")
        #expect(image.mimeType == "image/jpeg")
        #expect(image.name == "photo.jpg")
        #expect(Self.size(image.data) == [300, 200])
    }

    @Test func somethingThatIsNotAnImageIsRefused() {
        #expect(throws: NativeImagePreparation.Failure.unreadable("notes.txt")) {
            try NativeImagePreparation.prepare(Data("hello".utf8), name: "notes.txt")
        }
    }

    private static func png(width: Int, height: Int) -> Data? { encode(width: width, height: height, type: "public.png") }

    private static func encode(width: Int, height: Int, type: String) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func size(_ data: Data) -> [Int] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        return [properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0]
    }
}
