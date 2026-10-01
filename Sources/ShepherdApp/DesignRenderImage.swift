import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The picture `board_render` hands a design agent, kept small: it goes into pi's session and is
/// re-sent whenever the conversation loads (docs/rules.md › Dropped images), and the extension socket's
/// frames stop at 1 MiB. The longest edge is at most 1600 px and the file about 350 KB: a PNG when
/// it fits (a board is flat color and crisp text, which PNG keeps), else a JPEG that steps its
/// quality down, then the picture shrinks.
enum DesignRenderImage {
    static let maxEdge = 1600
    static let maxBytes = 350_000
    static let jpegQualities: [Double] = [0.85, 0.75, 0.65, 0.5]
    static let shrinkStep = 0.75
    static let maxShrinks = 5

    struct Encoded: Equatable {
        var data: Data
        var mimeType: String
        var width: Int
        var height: Int

        var isPNG: Bool { mimeType == "image/png" }
    }

    /// The image within the caps, or nil when it can't be encoded at all.
    static func encode(_ image: CGImage, maxEdge: Int = maxEdge, maxBytes: Int = maxBytes) -> Encoded? {
        var (width, height) = BrowserImageClamp.size(width: image.width, height: image.height, maxEdge: maxEdge)
        var current: CGImage? = BrowserImageClamp.resized(image, width: width, height: height)
        for _ in 0...maxShrinks {
            guard let candidate = current else { return nil }
            if let png = png(candidate), png.count <= maxBytes {
                return Encoded(data: png, mimeType: "image/png", width: candidate.width, height: candidate.height)
            }
            for quality in jpegQualities {
                guard let data = BrowserImageClamp.jpeg(candidate, quality: quality) else { return nil }
                if data.count <= maxBytes { return Encoded(data: data, mimeType: "image/jpeg", width: candidate.width, height: candidate.height) }
            }
            width = max(1, Int((Double(width) * shrinkStep).rounded()))
            height = max(1, Int((Double(height) * shrinkStep).rounded()))
            current = BrowserImageClamp.resized(candidate, width: width, height: height)
        }
        return nil
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// "41 KB", "1.2 MB".
    static func size(_ bytes: Int) -> String {
        bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : "\(max(1, (bytes + 500) / 1_000)) KB"
    }
}

/// One board render at a time: the next waits for the one drawing, in the order asked, so a helper
/// asking for a dozen pictures never holds more than one off-screen web view.
@MainActor
final class DesignRenderQueue {
    private var running = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// How many renders wait for their turn (tests).
    var waitingCount: Int { waiting.count }

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if running {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running = true
        }
        // The next in line inherits `running`, so nobody slips in between.
        defer {
            if waiting.isEmpty { running = false } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }
}
