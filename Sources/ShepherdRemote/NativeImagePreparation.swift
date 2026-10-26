import Foundation
import ImageIO
import UniformTypeIdentifiers
import ShepherdProtocol

/// An image on its way into a `send`, sized to the protocol's limits the way the Mac's drop is
/// (docs/rules.md › Status and startup): the longest edge clamped to
/// `maxEdge`, a photo (JPEG or HEIC) sent as JPEG and everything else re-encoded as PNG, and at most
/// `NativeImage.maxBytes`. pi writes an attached image into its session, so an oversized photo
/// would be sent again on every later load of the conversation.
public enum NativeImagePreparation {
    public static let maxEdge = 2000

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Not an image ImageIO can read.
        case unreadable(String)
        /// Still over the limit once resized (and, for a photo, recompressed).
        case tooLarge(String)
        /// The message already carries `NativeImage.maxPerSend` images.
        case full

        public var description: String {
            switch self {
            case .unreadable(let name): "\(name) isn't an image Shepherd can send."
            case .tooLarge(let name): "\(name) is still too large after resizing."
            case .full: "A message carries at most \(NativeImage.maxPerSend) images."
            }
        }
    }

    /// A photo (JPEG, or the HEIC a camera takes) goes as a JPEG; PNG would only bloat it.
    public static func sendsAsJPEG(_ type: UTType) -> Bool {
        type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    /// How many more images a message holding `count` can take.
    public static func room(_ count: Int) -> Int { max(0, NativeImage.maxPerSend - count) }

    /// `data` resized and encoded for a send. A tighter byte budget accounts for the remote
    /// frame, including its text and other images. Keep PNG when it fits; otherwise try JPEG
    /// quality levels, then smaller dimensions.
    public static func prepare(_ data: Data, name: String, maxEdge: Int = maxEdge, maxBytes: Int = NativeImage.maxBytes) throws -> NativeImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else { throw Failure.unreadable(name) }
        let jpeg = UTType(type).map(sendsAsJPEG) == true
        let limit = min(maxBytes, NativeImage.maxBytes)
        let base = (name as NSString).deletingPathExtension.isEmpty ? "Image" : (name as NSString).deletingPathExtension
        var edge = min(maxEdge, longestEdge(source) ?? maxEdge)
        guard limit > 0 else { throw Failure.tooLarge(name) }
        while edge > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable(name) }
            if !jpeg, let png = encode(image, as: .png), png.count <= limit {
                return NativeImage(mimeType: "image/png", data: png, name: base + ".png")
            }
            for quality in [0.85, 0.7, 0.5, 0.35] {
                if let data = encode(image, as: .jpeg, quality: quality), data.count <= limit {
                    return NativeImage(mimeType: "image/jpeg", data: data, name: base + ".jpg")
                }
            }
            edge /= 2
        }
        throw Failure.tooLarge(name)
    }

    private static func longestEdge(_ source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return max(width, height)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
