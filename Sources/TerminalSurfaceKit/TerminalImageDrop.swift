import AppKit
import Foundation
import UniformTypeIdentifiers

/// Turns a drag into file paths the terminal can reference.
///
/// Dragging a file from Finder carries a file URL, which is already a path.
/// Dragging a *screenshot* — from the macOS screenshot thumbnail, a browser,
/// or Preview — usually carries only raw image data with no file behind it, so
/// there is no path to type into the terminal and the drop silently does
/// nothing. Those are written to a temp file first and that path is used.
///
/// The terminal can only ever receive text, so an image has to become a path
/// on disk somewhere; doing it here keeps that detail out of the pane.
public enum TerminalImageDrop {
    /// Drag types worth accepting. `image` covers PNG/TIFF/JPEG and friends.
    public static let acceptedTypes: [UTType] = [.fileURL, .image]

    /// Longest edge kept for a dropped raster image.
    ///
    /// Resizing happens where the image *enters* Shepherd, because an oversized
    /// screenshot is not a one-off cost: the agent harness writes it into the
    /// session transcript, and every later load re-emits it. A 5 MB drop
    /// becomes permanent weight on that conversation. OpenAI caps at 2000px
    /// and Anthropic does for many-image requests, so anything larger is also
    /// bytes no provider will look at.
    public static let maxDimension = 2000

    /// JPEG quality for re-encoded photographic images.
    private static let jpegQuality = 0.9

    /// Where dropped image data is materialized.
    static var dropDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-drops", isDirectory: true)
    }

    /// Formats that can be handed to tools as-is. Anything else (notably the
    /// TIFF that macOS screenshot drags carry) is re-encoded as PNG, since
    /// most image consumers do not read TIFF.
    private static let passthroughTypes: Set<UTType> = [.png, .jpeg, .gif]

    /// Item providers for a drag pasteboard, for `resolve`. File URLs win;
    /// otherwise the raw image data (screenshot drags) is wrapped so
    /// `materializeImage` can write it out.
    static func providers(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map { url in
                let provider = NSItemProvider()
                provider.suggestedName = url.lastPathComponent
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
                ) { completion in
                    completion(url.dataRepresentation, nil)
                    return nil
                }
                return provider
            }
        }
        for case let type? in (pasteboard.types ?? []).map({ UTType($0.rawValue) })
        where type.conforms(to: .image) {
            guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier))
            else { continue }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: type.identifier, visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
            return [provider]
        }
        return []
    }

    /// Resolve every provider to a file path, materializing image data when
    /// there is no file behind it. Order is preserved; unusable items are
    /// dropped.
    public static func resolve(_ providers: [NSItemProvider]) async -> [URL] {
        pruneOldDrops()
        var urls: [URL] = []
        for provider in providers {
            if let url = await fileURL(from: provider) {
                // An oversized image file is resized into the drop directory
                // and the copy is referenced instead, so oversized screenshots
                // don't get persisted into history — the user's original file
                // is never modified.
                urls.append(shrinkIfOversized(url) ?? url)
            } else if let url = await materializeImage(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: File URLs

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        let identifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                // Providers hand back either an NSURL or the URL's bytes.
                switch item {
                case let url as URL:
                    continuation.resume(returning: url.isFileURL ? url : nil)
                case let data as Data:
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                    continuation.resume(returning: url?.isFileURL == true ? url : nil)
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Resize an oversized image file into the drop directory, returning the
    /// replacement path. Returns nil when the file is not an oversized raster
    /// image, so the original is used untouched.
    private static func shrinkIfOversized(_ url: URL) -> URL? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              type.conforms(to: .image),
              type != .svg,
              let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data),
              resizedDimensions(width: rep.pixelsWide, height: rep.pixelsHigh) != nil
        else { return nil }

        let (encoded, encodedType) = normalize(data, type: type)
        guard encoded.count < data.count else { return nil }

        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = encodedType.preferredFilenameExtension ?? "png"
        let destination = dropDirectory
            .appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)")
        do {
            try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
            try encoded.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: Raw image data

    private static func materializeImage(from provider: NSItemProvider) async -> URL? {
        guard let type = imageType(of: provider),
              let data = await data(from: provider, type: type) else { return nil }

        let (encoded, encodedType) = normalize(data, type: type)
        guard !encoded.isEmpty else { return nil }

        let name = filename(for: provider, type: encodedType)
        let destination = dropDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
            try encoded.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    /// The provider's most specific image type, preferring formats that need
    /// no re-encoding.
    private static func imageType(of provider: NSItemProvider) -> UTType? {
        let offered = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if let direct = offered.first(where: { passthroughTypes.contains($0) }) {
            return direct
        }
        return offered.first { $0.conforms(to: .image) }
    }

    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// Downscale past `maxDimension` and re-encode into a format tools can
    /// actually read.
    ///
    /// JPEG sources stay JPEG (quality 90), everything else
    /// becomes PNG — notably the TIFF that macOS screenshot drags carry, which
    /// most image consumers cannot read.
    static func normalize(_ data: Data, type: UTType) -> (Data, UTType) {
        guard let source = NSBitmapImageRep(data: data) else {
            // Undecodable: pass through rather than lose the drop.
            return (data, type)
        }

        let isJPEG = getResizedOutputType(type) == .jpeg
        let outputType: UTType = isJPEG ? .jpeg : .png
        let properties: [NSBitmapImageRep.PropertyKey: Any] =
            isJPEG ? [.compressionFactor: jpegQuality] : [:]

        // `pixelsWide/High` is the true raster size; `size` is in points and
        // reports half on Retina captures.
        let width = source.pixelsWide
        let height = source.pixelsHigh
        guard let target = resizedDimensions(width: width, height: height) else {
            // Within budget. Still re-encode when the format is unreadable
            // (TIFF), otherwise keep the original bytes untouched.
            if passthroughTypes.contains(type) { return (data, type) }
            guard let encoded = source.representation(using: isJPEG ? .jpeg : .png, properties: properties) else {
                return (data, type)
            }
            return (encoded, outputType)
        }

        let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: target.width,
            pixelsHigh: target.height,
            bitsPerSample: 8,
            samplesPerPixel: isJPEG ? 3 : 4,
            hasAlpha: !isJPEG,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let resized else { return (data, type) }
        resized.size = NSSize(width: target.width, height: target.height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: resized) else { return (data, type) }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: target.width, height: target.height))
        context.flushGraphics()

        guard let encoded = resized.representation(using: isJPEG ? .jpeg : .png, properties: properties) else {
            return (data, type)
        }
        return (encoded, outputType)
    }

    /// JPEG in, JPEG out; anything else becomes PNG.
    private static func getResizedOutputType(_ type: UTType) -> UTType {
        type == .jpeg ? .jpeg : .png
    }

    /// Target size preserving aspect ratio, or nil when already within budget.
    static func resizedDimensions(
        width: Int, height: Int, maxDimension: Int = TerminalImageDrop.maxDimension
    ) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        guard width > maxDimension || height > maxDimension else { return nil }
        let scale = min(Double(maxDimension) / Double(width), Double(maxDimension) / Double(height))
        return (
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }

    private static func filename(for provider: NSItemProvider, type: UTType) -> String {
        let ext = type.preferredFilenameExtension ?? "png"
        // A screenshot drag usually suggests no name at all.
        let stem = provider.suggestedName.map { suggested -> String in
            let base = (suggested as NSString).deletingPathExtension
            let cleaned = base.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? "image" : cleaned
        } ?? "image"
        // Unique suffix: dropping the same screenshot twice must not collide
        // with a file a tool may still be reading.
        return "\(stem)-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
    }

    // MARK: Housekeeping

    /// Dropped images are ours forever otherwise. Anything older than a day is
    /// well past the turn that referenced it.
    private static func pruneOldDrops() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dropDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
