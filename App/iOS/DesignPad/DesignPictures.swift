import Foundation
import ImageIO
import ShepherdRemote
import UIKit
import UniformTypeIdentifiers

/// Finished board pictures on this device's disk (Caches, so the system may clear them), shared by the
/// iPad canvas, the Designs cards and the iPhone's board tiles. A board's picture is read back
/// by its content and never drawn again while its file, tweaks and size are the same.
enum DesignPictures {
    static let cache = BoardPictureCache(
        directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("ShepherdBoardPictures", isDirectory: true))

    /// What drew the picture: a new build of the app draws every board again, as its runtime may have changed.
    static let renderer: String = {
        let info = Bundle.main.infoDictionary
        return "1." + ((info?["CFBundleShortVersionString"] as? String) ?? "0") + "." + ((info?["CFBundleVersion"] as? String) ?? "0")
    }()

    @MainActor static var scale: Int { max(1, Int((DesignRenderAnchor.window?.screen.scale ?? 2).rounded())) }

    @MainActor
    static func key(content: String, props: String? = nil, dependencies: String = "", board: CGSize, width: CGFloat) -> BoardPictureKey {
        BoardPictureKey(content: content, props: props, dependencies: dependencies, board: board, width: Int(width.rounded()), scale: scale,
                        renderer: renderer)
    }

    /// The kept picture, decoded off the main thread; nil when none is kept or it does not decode (then it is forgotten).
    static func load(_ key: BoardPictureKey) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let data = cache.data(for: key) else { return nil }
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
                cache.remove(key)
                return nil
            }
            return image
        }.value
    }

    /// Keeps a drawn picture, encoded off the main thread.
    static func save(_ image: CGImage, as key: BoardPictureKey) {
        Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            cache.store(data as Data, for: key)
        }
    }
}
